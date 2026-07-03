//! Shared application state: upstream URL, per-session handles, Tera.
//!
//! `AppState` is cloned into every axum handler. The expensive bits
//! (Tera instance, upstream URL) are wrapped in `Arc` so cloning is
//! cheap. The session map is behind a `parking_lot::Mutex` — axum
//! handlers run concurrently and we need safe interior mutability.

use std::collections::{HashMap, HashSet};
use std::sync::Arc;
use std::time::Duration;

use anyhow::{Context, Result};
use parking_lot::Mutex;
use tokio::sync::{broadcast, mpsc};
use url::Url;

/// Shared state for every axum handler.
#[derive(Clone)]
pub struct AppState {
    pub upstream: Arc<Upstream>,
    /// Per-browser-session state. Keyed by session_id (random cookie).
    pub sessions: Arc<Mutex<HashMap<String, Arc<SessionHandle>>>>,
    /// HTTP client for REST calls to the upstream.
    pub http: reqwest::Client,
    /// Tera template engine. Loads `templates/*.tera` at startup.
    pub tera: Arc<tera::Tera>,
}

pub struct Upstream {
    /// Base URL of the upstream, e.g. `http://127.0.0.1:8080`.
    pub base: Url,
    /// WS URL of the upstream's `/irc` endpoint, derived from `base`.
    pub ws: Url,
}

impl Upstream {
    pub fn from_base(base: Url) -> Result<Self> {
        // freeq-server uses http↔ws, https↔wss.
        let ws_scheme = match base.scheme() {
            "https" => "wss",
            _ => "ws",
        };
        let mut ws = base.clone();
        ws.set_scheme(ws_scheme)
            .map_err(|_| anyhow::anyhow!("upstream URL has no scheme"))?;
        ws.set_path("/irc");
        Ok(Self { base, ws })
    }
}

impl AppState {
    pub fn new(upstream_base: Url) -> Result<Self> {
        let upstream = Arc::new(Upstream::from_base(upstream_base)?);
        let http = reqwest::Client::builder()
            .timeout(Duration::from_secs(10))
            .build()?;

        // Tera loads everything in templates/*.tera. We pre-parse at
        // startup so per-request cost is just the render call (not
        // parsing). Auto-escape is on by default — every {{ var }} is
        // HTML-escaped unless explicitly marked safe with | safe.
        //
        // tera 2.x doesn't have a glob loader; we walk the templates
        let mut files: Vec<(String, Option<String>)> = Vec::new();
        // it scales to a templates/ tree without changing the loader.
        let mut tera = tera::Tera::default();
        for entry in std::fs::read_dir("templates")
            .context("reading templates/ directory")?
        {
            let entry = entry?;
            let p = entry.path();
            if p.extension().and_then(|s| s.to_str()) == Some("tera") {
                let name = p
                    .file_name()
                    .and_then(|s| s.to_str())
                    .ok_or_else(|| anyhow::anyhow!("bad template filename: {p:?}"))?
                    .to_string();
                files.push((p.to_string_lossy().to_string(), Some(name)));
            }
        }
        if files.is_empty() {
            anyhow::bail!("no .tera templates found in templates/");
        }
        tera.add_template_files(files)
            .context("loading Tera templates from templates/")?;

        Ok(Self {
            upstream,
            sessions: Arc::new(Mutex::new(HashMap::new())),
            http,
            tera: Arc::new(tera),
        })
    }

    /// Get-or-create the SessionHandle for a session_id.
    pub fn session(&self, session_id: &str) -> Arc<SessionHandle> {
        let mut g = self.sessions.lock();
        g.entry(session_id.to_string())
            .or_insert_with(|| Arc::new(SessionHandle::new()))
            .clone()
    }
}

/// One entry in a channel's member list.
///
/// `nick` is the bare nick with IRC mode prefixes stripped; the bools track
/// op/halfop/voice so the UI can render the prefix separately and keep it in
/// sync with MODE changes (a bare nick is what JOIN/PART/QUIT carry, so
/// membership updates match correctly).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct MemberEntry {
    pub nick: String,
    pub op: bool,
    pub halfop: bool,
    pub voiced: bool,
}

/// Per-browser-session state.
pub struct SessionHandle {
    /// Outbound IRC lines (PRIVMSG / JOIN / etc) — fed by the form POST
    /// handler, drained by the WS task that owns the upstream connection.
    /// Wrapped in a Mutex so the sender can be replaced when the WS task
    /// is respawned after a connection drop.
    pub irc_tx: Mutex<mpsc::Sender<String>>,
    /// Inbound IRC lines — fed by the WS task, broadcast to every SSE
    /// subscriber for this session.
    pub lines_tx: broadcast::Sender<String>,
    /// Channels this session has JOINed. Avoids sending JOIN twice.
    pub joined: Mutex<HashSet<String>>,
    /// Per-channel member map (bare nick → entry). Updated on 353 NAMES,
    /// JOIN/PART/QUIT, and MODE. Keyed by canonical channel name.
    pub channel_members: Mutex<HashMap<String, HashMap<String, MemberEntry>>>,
    /// Holds the rx half until the WS task takes it on first spawn.
    pub irc_rx_slot: Mutex<Option<mpsc::Receiver<String>>>,
    /// JoinHandle of the spawned WS task. Used to detect if the task has
    /// died and needs respawning (via `is_finished()`).
    pub ws_task: Mutex<Option<tokio::task::JoinHandle<()>>>,
    /// Guards against duplicate SSE connections from the same session.
    pub sse_active: std::sync::atomic::AtomicBool,
}
impl SessionHandle {
    pub fn new() -> Self {
        let (irc_tx, irc_rx) = mpsc::channel::<String>(256);
        let (lines_tx, _) = broadcast::channel::<String>(4096);
        Self {
            irc_tx: Mutex::new(irc_tx),
            lines_tx,
            joined: Mutex::new(HashSet::new()),
            channel_members: Mutex::new(HashMap::new()),
            irc_rx_slot: Mutex::new(Some(irc_rx)),
            ws_task: Mutex::new(None),
            sse_active: std::sync::atomic::AtomicBool::new(false),
        }
    }
}
