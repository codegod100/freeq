//! Shared application state.

use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use anyhow::{Context, Result};
use freeq_sdk::oauth::OAuthSession;
use parking_lot::Mutex;
use tokio::sync::{broadcast, mpsc, oneshot};
use url::Url;

// ── Auth state machine ─────────────────────────────────────────────────

/// The auth state machine. Only valid states are representable.
#[derive(Clone, Debug)]
pub enum AuthState {
    /// No handle known, not authenticated.
    Guest,
    /// Fully authenticated with an AT Protocol OAuth session. The session
    /// contains the access token, DPoP key, and PDS URL needed to prove
    /// identity to the upstream IRC server via SASL `pds-oauth`.
    Authenticated {
        handle: String,
        did: String,
        nick: String,
        oauth: OAuthSession,
    },
}

impl Default for AuthState {
    fn default() -> Self { AuthState::Guest }
}

impl AuthState {
    pub fn handle(&self) -> Option<&str> {
        match self {
            AuthState::Guest => None,
            AuthState::Authenticated { handle, .. } => Some(handle),
        }
    }

    pub fn did(&self) -> Option<&str> {
        match self {
            AuthState::Authenticated { did, .. } => Some(did),
            _ => None,
        }
    }

    pub fn is_authenticated(&self) -> bool {
        matches!(self, AuthState::Authenticated { .. })
    }

}

// ── App state ──────────────────────────────────────────────────────────

#[derive(Clone)]
pub struct AppState {
    pub upstream: Arc<Upstream>,
    pub sessions: Arc<Mutex<HashMap<String, Arc<SessionHandle>>>>,
    /// In-flight loopback OAuth logins keyed by session id. The oneshot
    /// sender is used to cancel a previous login attempt when a new one
    /// is started for the same session.
    pub pending_logins: Arc<Mutex<HashMap<String, oneshot::Sender<()>>>>,
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
        Ok(Self {
            upstream,
            sessions: Arc::new(Mutex::new(HashMap::new())),
            pending_logins: Arc::new(Mutex::new(HashMap::new())),
            http,
            tera: Arc::new(tera),
        })
    }

    pub fn session(&self, session_id: &str) -> Arc<SessionHandle> {
        self.sessions.lock()
            .entry(session_id.to_string())
            .or_insert_with(|| Arc::new(SessionHandle::new()))
            .clone()
    }
}

// ── Member tracking ────────────────────────────────────────────────────

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct MemberEntry {
    pub nick: String,
    pub op: bool,
    pub halfop: bool,
    pub voiced: bool,
}

// ── Session ────────────────────────────────────────────────────────────

pub struct SessionHandle {
    pub irc_tx: Mutex<mpsc::Sender<String>>,
    pub lines_tx: broadcast::Sender<String>,
    pub joined: Mutex<HashSet<String>>,
    pub channel_members: Mutex<HashMap<String, HashMap<String, MemberEntry>>>,
    pub irc_rx_slot: Mutex<Option<mpsc::Receiver<String>>>,
    pub ws_task: Mutex<Option<tokio::task::JoinHandle<()>>>,
    /// Auth state machine — the single source of truth.
    pub auth: Mutex<AuthState>,
    /// DID extracted from 333/ACCOUNT/NOTICE before 903, used as a fallback
    /// for uploads when the user has not completed SASL auth in this session.
    pub extracted_did: Mutex<Option<String>>,
    /// Set to true when auth state changes and the upstream WS task should be
    /// respawned with the new credentials.
    pub reconnect: AtomicBool,
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
            auth: Mutex::new(AuthState::default()),
            extracted_did: Mutex::new(None),
            reconnect: AtomicBool::new(false),
        }
    }

    pub fn request_reconnect(&self) {
        self.reconnect.store(true, Ordering::SeqCst);
    }
}
