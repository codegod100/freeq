//! Shared application state.

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU8, Ordering};
use std::sync::Arc;
use std::time::Duration;

use anyhow::{Context, Result};
use freeq_sdk::oauth::{derive_session_key, OAuthSession, PreparedLogin};
use parking_lot::Mutex;
use tokio::sync::{broadcast, mpsc, oneshot};
use tracing::{info, warn};
use url::Url;

/// Persists authenticated OAuth sessions to disk so users stay logged in
/// across `freeq-webui` restarts.
///
/// Sessions are encrypted with AES-256-GCM using a per-session key derived
/// from a machine-local secret (stored next to the sessions) plus the
/// session_id. This keeps tokens off disk in plaintext while still letting
/// the server recover them after a restart.
#[derive(Clone)]
pub struct SessionStore {
    dir: PathBuf,
    machine_key: [u8; 32],
}

impl SessionStore {
    /// Open or create a session store at `dir`. Generates a machine key on
    /// first use and saves it with restrictive permissions.
    pub fn new(dir: PathBuf) -> Result<Self> {
        std::fs::create_dir_all(&dir).context("creating session store dir")?;
        let key_path = dir.join(".key");
        let machine_key = if key_path.exists() {
            let bytes = std::fs::read(&key_path).context("reading session key")?;
            let mut key = [0u8; 32];
            if bytes.len() != 32 {
                anyhow::bail!("session key file has wrong length: {}", bytes.len());
            }
            key.copy_from_slice(&bytes);
            key
        } else {
            let mut key = [0u8; 32];
            rand::RngCore::fill_bytes(&mut rand::thread_rng(), &mut key);
            std::fs::write(&key_path, &key).context("writing session key")?;
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                std::fs::set_permissions(&key_path, std::fs::Permissions::from_mode(0o600))
                    .context("setting session key permissions")?;
            }
            key
        };
        Ok(Self { dir, machine_key })
    }

    /// Path for a given session file. Sanitizes the session id to avoid
    /// directory traversal.
    fn session_path(&self, sid: &str) -> PathBuf {
        let safe = sid.replace(['/', '\\', '.'], "_");
        self.dir.join(format!("{safe}.bin"))
    }

    /// Derive a per-session encryption key.
    fn derive_key(&self, sid: &str) -> [u8; 32] {
        derive_session_key(&self.machine_key, sid)
    }

    /// Save an authenticated session to disk.
    pub fn save(&self, sid: &str, oauth: &OAuthSession) -> Result<()> {
        let path = self.session_path(sid);
        let key = self.derive_key(sid);
        oauth
            .save_encrypted(&path, &key)
            .context("saving session")?;
        Ok(())
    }

    /// Load an authenticated session from disk, if present.
    pub fn load(&self, sid: &str) -> Result<Option<OAuthSession>> {
        let path = self.session_path(sid);
        if !path.exists() {
            return Ok(None);
        }
        let key = self.derive_key(sid);
        let oauth = OAuthSession::load_encrypted(&path, &key).context("loading session")?;
        Ok(Some(oauth))
    }

    /// Remove a persisted session (e.g. on logout).
    pub fn remove(&self, sid: &str) -> Result<()> {
        let path = self.session_path(sid);
        if path.exists() {
            std::fs::remove_file(&path).context("removing session file")?;
        }
        Ok(())
    }
}

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
    fn default() -> Self {
        AuthState::Guest
    }
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
    /// Optional disk-backed session store. When present, authenticated
    /// OAuth sessions are encrypted and saved on login so users stay
    /// logged in across `freeq-webui` restarts.
    pub session_store: Option<SessionStore>,
    /// In-flight loopback OAuth logins keyed by session id. The oneshot
    /// sender is used to cancel a previous login attempt when a new one
    /// is started for the same session.
    pub pending_logins: Arc<Mutex<HashMap<String, oneshot::Sender<()>>>>,
    /// In-flight web-based OAuth logins keyed by state parameter.
    /// Value is (session_id, PreparedLogin). When the callback arrives
    /// at /auth/callback, we look up the state and exchange the code.
    pub pending_web_logins: Arc<Mutex<HashMap<String, (String, PreparedLogin)>>>,
    /// Public URL (origin) when running behind tailscale funnel or a
    /// reverse proxy. None means use loopback OAuth.
    pub public_url: Option<String>,
    pub http: reqwest::Client,
    pub tera: Arc<tera::Tera>,
}

pub struct Upstream {
    pub base: Url,
    pub ws: Url,
}

impl Upstream {
    pub fn from_base(base: Url) -> Result<Self> {
        let scheme = match base.scheme() {
            "https" => "wss",
            _ => "ws",
        };
        let host = base.host_str().context("upstream URL missing host")?;
        let port = base.port().map(|p| format!(":{p}")).unwrap_or_default();
        let ws = Url::parse(&format!("{scheme}://{host}{port}/irc"))?;
        Ok(Self { base, ws })
    }
}

impl AppState {
    pub fn new(upstream_base: Url, public_url: Option<String>) -> Result<Self> {
        let upstream = Arc::new(Upstream::from_base(upstream_base)?);
        let http = reqwest::Client::builder()
            .timeout(Duration::from_secs(10))
            .build()?;

        // Optional encrypted session persistence. Disabled if the env var is
        // explicitly empty; otherwise defaults to a local directory.
        let sessions_dir = std::env::var("FREEQ_WEBUI_SESSIONS_DIR")
            .ok()
            .filter(|s| !s.is_empty())
            .map(PathBuf::from)
            .or_else(|| Some(PathBuf::from(".dev-data/webui-sessions")));
        let session_store = sessions_dir
            .map(SessionStore::new)
            .transpose()
            .context("initializing session store")?;

        let mut tera = tera::Tera::default();
        let mut files: Vec<(String, Option<String>)> = Vec::new();
        for entry in std::fs::read_dir("templates").context("reading templates/")? {
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
            anyhow::bail!("no .tera templates in templates/");
        }
        tera.add_template_files(files)
            .context("loading Tera templates")?;
        Ok(Self {
            upstream,
            sessions: Arc::new(Mutex::new(HashMap::new())),
            session_store,
            pending_logins: Arc::new(Mutex::new(HashMap::new())),
            pending_web_logins: Arc::new(Mutex::new(HashMap::new())),
            public_url,
            http,
            tera: Arc::new(tera),
        })
    }

    /// Return an existing session, or create a new one. If a session store is
    /// configured and a persisted authenticated session exists for this id,
    /// restore it into memory so the user stays logged in across restarts.
    pub fn session(&self, session_id: &str) -> Arc<SessionHandle> {
        let mut sessions = self.sessions.lock();
        if let Some(handle) = sessions.get(session_id) {
            return handle.clone();
        }

        let handle = Arc::new(SessionHandle::new());
        if let Some(store) = &self.session_store {
            match store.load(session_id) {
                Ok(Some(oauth)) => {
                    let did = oauth.did.clone();
                    let nick = crate::sanitize_nick(&oauth.handle);
                    *handle.auth.lock() = AuthState::Authenticated {
                        handle: oauth.handle.clone(),
                        did: did.clone(),
                        nick,
                        oauth,
                    };
                    handle.extracted_did.lock().replace(did.clone());
                    handle.request_reconnect();
                    info!(session = %session_id, %did, "restored authenticated session from disk");
                }
                Ok(None) => {}
                Err(e) => {
                    warn!(session = %session_id, "failed to restore session from disk: {e:#}");
                }
            }
        }
        sessions.insert(session_id.to_string(), handle.clone());
        handle
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

/// Upstream WebSocket connection state machine.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum WsState {
    /// No WS task running, no connection.
    Disconnected = 0,
    /// WS task spawned, TCP/WebSocket handshake in progress.
    Connecting = 1,
    /// TCP connected, IRC registration (NICK/USER/CAP/SASL) in progress.
    Registering = 2,
    /// Fully registered, can send commands.
    Ready = 3,
}

impl WsState {
    pub fn from_u8(v: u8) -> Self {
        match v {
            0 => WsState::Disconnected,
            1 => WsState::Connecting,
            2 => WsState::Registering,
            3 => WsState::Ready,
            _ => WsState::Disconnected,
        }
    }
}

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
    /// Registration sub-phase while ws_state is Registering.
    /// Updated by the WS task: "WaitCapAck" → "SaslChallenge" → "SaslResult".
    /// Cleared when ws_state transitions to Ready or Disconnected.
    pub reg_phase: Mutex<String>,
    /// Upstream WebSocket connection state. Transitions are atomic:
    /// Disconnected → Connecting (on spawn) → Registering (on TCP connect)
    /// → Ready (on CAP END/JOIN) → Disconnected (on WS close/error).
    pub ws_state: AtomicU8,
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
            auth: Mutex::new(AuthState::default()),
            extracted_did: Mutex::new(None),
            reg_phase: Mutex::new(String::new()),
            ws_state: AtomicU8::new(WsState::Disconnected as u8),
        }
    }

    /// Read the current WS state.
    pub fn get_ws_state(&self) -> WsState {
        WsState::from_u8(self.ws_state.load(Ordering::SeqCst))
    }

    /// Attempt to transition from `expected` to `new`. Returns the actual
    /// state after the attempt (the new state on success, current on failure).
    pub fn transition_ws_state(&self, expected: WsState, new: WsState) -> WsState {
        let prev = self.ws_state.compare_exchange(
            expected as u8,
            new as u8,
            Ordering::SeqCst,
            Ordering::SeqCst,
        );
        match prev {
            Ok(_) => new,
            Err(actual) => WsState::from_u8(actual),
        }
    }

    /// Force-set the WS state (no CAS precondition).
    pub fn set_ws_state(&self, state: WsState) {
        self.ws_state.store(state as u8, Ordering::SeqCst);
    }

    /// Request that the WS task reconnect. If the task is in Ready state,
    /// this will cause it to break its loop and reconnect.
    pub fn request_reconnect(&self) {
        self.set_ws_state(WsState::Disconnected);
    }
}
