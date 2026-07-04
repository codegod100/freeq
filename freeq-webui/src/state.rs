//! Shared application state.

use std::collections::{HashMap, HashSet};
use std::sync::Arc;
use std::time::Duration;

use anyhow::{Context, Result};
use parking_lot::Mutex;
use tokio::sync::{broadcast, mpsc};
use url::Url;

#[derive(Clone)]
pub struct AppState {
    pub upstream: Arc<Upstream>,
    pub sessions: Arc<Mutex<HashMap<String, Arc<SessionHandle>>>>,
    pub http: reqwest::Client,
    pub tera: Arc<tera::Tera>,
}

pub struct Upstream {
    pub base: Url,
    pub ws: Url,
}

impl Upstream {
    pub fn from_base(base: Url) -> Result<Self> {
        let scheme = match base.scheme() { "https" => "wss", _ => "ws" };
        let host = base.host_str().context("upstream URL missing host")?;
        let port = base.port().map(|p| format!(":{p}")).unwrap_or_default();
        let ws = Url::parse(&format!("{scheme}://{host}{port}/irc"))?;
        Ok(Self { base, ws })
    }
}

impl AppState {
    pub fn new(upstream_base: Url) -> Result<Self> {
        let upstream = Arc::new(Upstream::from_base(upstream_base)?);
        let http = reqwest::Client::builder().timeout(Duration::from_secs(10)).build()?;
        let mut tera = tera::Tera::default();
        let mut files: Vec<(String, Option<String>)> = Vec::new();
        for entry in std::fs::read_dir("templates").context("reading templates/")? {
            let entry = entry?;
            let p = entry.path();
            if p.extension().and_then(|s| s.to_str()) == Some("tera") {
                let name = p.file_name().and_then(|s| s.to_str())
                    .ok_or_else(|| anyhow::anyhow!("bad template filename: {p:?}"))?.to_string();
                files.push((p.to_string_lossy().to_string(), Some(name)));
            }
        }
        if files.is_empty() { anyhow::bail!("no .tera templates in templates/"); }
        tera.add_template_files(files).context("loading Tera templates")?;
        Ok(Self { upstream, sessions: Arc::new(Mutex::new(HashMap::new())), http, tera: Arc::new(tera) })
    }

    pub fn session(&self, session_id: &str) -> Arc<SessionHandle> {
        self.sessions.lock()
            .entry(session_id.to_string())
            .or_insert_with(|| Arc::new(SessionHandle::new()))
            .clone()
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct MemberEntry {
    pub nick: String,
    pub op: bool,
    pub halfop: bool,
    pub voiced: bool,
}

pub struct SessionHandle {
    pub irc_tx: Mutex<mpsc::Sender<String>>,
    pub lines_tx: broadcast::Sender<String>,
    pub joined: Mutex<HashSet<String>>,
    pub channel_members: Mutex<HashMap<String, HashMap<String, MemberEntry>>>,
    pub irc_rx_slot: Mutex<Option<mpsc::Receiver<String>>>,
    pub ws_task: Mutex<Option<tokio::task::JoinHandle<()>>>,
    pub pending_login_handle: Mutex<Option<String>>,
    pub login_handle: Mutex<Option<String>>,
    pub authenticated_did: Mutex<Option<String>>,
}

impl SessionHandle {
    pub fn new() -> Self {
        let (irc_tx, irc_rx) = mpsc::channel::<String>(256);
        let (lines_tx, _) = broadcast::channel::<String>(4096);
        Self {
            irc_tx: Mutex::new(irc_tx), lines_tx,
            joined: Mutex::new(HashSet::new()),
            channel_members: Mutex::new(HashMap::new()),
            irc_rx_slot: Mutex::new(Some(irc_rx)),
            ws_task: Mutex::new(None),
            pending_login_handle: Mutex::new(None),
            login_handle: Mutex::new(None),
            authenticated_did: Mutex::new(None),
        }
    }
}
