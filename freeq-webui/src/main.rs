//! freeq-webui — standalone DataStar web UI for the freeq IRC server.
//!
//! This is NOT embedded in freeq-server. It's a thin proxy that:
//!   1. Serves DataStar HTML pages + SSE streams to the browser
//!   2. Opens one WebSocket per browser session to `<upstream>/irc`
//!   3. Reads metadata (channel list, history) from `<upstream>/api/v1/*`
//!
//! Module layout:
//!   - `state` — AppState, Upstream, SessionHandle
//!   - `upstream` — WS bridge, REST fetch, IRC line formatting
use std::time::Duration;

mod state;
mod upstream;

use std::net::SocketAddr;

use anyhow::{Context, Result};
use axum::extract::{Path, Query, State};
use axum::http::header;
use axum::http::HeaderValue;
use axum::http::StatusCode;
use axum::response::sse::{Event, KeepAlive, Sse};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::Router;
use chrono::Utc;
use datastar::axum::ReadSignals;
use datastar::patch_elements::PatchElements;
use datastar::patch_signals::PatchSignals;
use datastar::prelude::{ElementPatchMode, ExecuteScript};
use freeq_sdk::oauth::PreparedLogin;
use rand::Rng;
use serde::Deserialize;
use tokio::sync::broadcast;
use tokio::time::timeout;
use tower_http::cors::{Any, CorsLayer};
use tracing::{debug, error, info, trace, warn};
use url::Url;

use crate::state::{AppState, AuthState, MemberEntry, WsState};
use crate::upstream::{
    fetch_channels, fetch_history, is_903, is_904, spawn_upstream_if_needed, UpstreamHistoryMessage,
};

// ── main ────────────────────────────────────────────────────────────────

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| {
                tracing_subscriber::EnvFilter::new("debug,reqwest=info,hyper=info,tungstenite=info")
            }),
        )
        .init();

    let upstream =
        std::env::var("FREEQ_UPSTREAM").unwrap_or_else(|_| "http://127.0.0.1:8080".to_string());
    let bind = std::env::var("FREEQ_WEBUI_BIND").unwrap_or_else(|_| "127.0.0.1:8090".to_string());
    let public_url = std::env::var("FREEQ_PUBLIC_URL").ok();
    let upstream_url: Url = upstream.parse().context("FREEQ_UPSTREAM must be a URL")?;

    let state = AppState::new(upstream_url.clone(), public_url.clone())?;
    info!(upstream = %upstream_url, bind = %bind, public_url = ?public_url, "freeq-webui starting");

    let app = Router::new()
        .route("/", get(get_root))
        .route("/login", get(get_login).post(post_login))
        .route("/logout", post(post_logout))
        .route("/auth/status", get(get_auth_status))
        .route(
            "/chat",
            get(|| async {
                (StatusCode::FOUND, [("Location", "/chat/general")], "").into_response()
            }),
        )
        .route("/chat/{channel}", get(get_chat))
        .route("/chat/{channel}/events", get(get_channel_events))
        .route("/chat/{channel}/send", post(post_channel_send))
        .route("/chat/{channel}/join", post(post_channel_join))
        .route("/chat/{channel}/part", post(post_channel_part))
        .route("/chat/{channel}/topic", post(post_channel_topic))
        .route("/upload", post(post_upload))
        .route("/datastar.js", get(get_datastar_js))
        .route("/api/channels", get(get_channels))
        .route(
            "/.well-known/oauth-client-metadata",
            get(get_oauth_client_metadata),
        )
        .route("/auth/callback", get(get_auth_callback))
        .layer(
            CorsLayer::new()
                .allow_origin(Any)
                .allow_methods(Any)
                .allow_headers(Any),
        )
        .with_state(state);

    let addr: SocketAddr = bind.parse().context("FREEQ_WEBUI_BIND must be host:port")?;
    let listener = tokio::net::TcpListener::bind(addr).await?;
    info!(%addr, "listening");
    axum::serve(listener, app).await?;
    Ok(())
}

// ── Cookie helpers ──────────────────────────────────────────────────────

/// Pull the `session_id` cookie or mint a new one. Returns (id, is_new).
fn session_id_from_request(req: &axum::http::HeaderMap) -> (String, bool) {
    if let Some(v) = req.get(header::COOKIE).and_then(|h| h.to_str().ok()) {
        for part in v.split(';').map(str::trim) {
            if let Some(rest) = part.strip_prefix("session_id=") {
                if !rest.is_empty() {
                    return (rest.to_string(), false);
                }
            }
        }
    }
    let mut buf = [0u8; 16];
    rand::thread_rng().fill(&mut buf);
    (hex::encode(buf), true)
}

fn session_cookie_header(id: &str) -> HeaderValue {
    // 30 days. No Secure flag (we may be on http://localhost for dev).
    HeaderValue::from_str(&format!(
        "session_id={id}; Path=/; HttpOnly; SameSite=Lax; Max-Age=2592000"
    ))
    .expect("cookie header is always ASCII")
}

// Inline hex encoder — avoids pulling another crate for 8 lines.
mod hex {
    pub fn encode<T: AsRef<[u8]>>(data: T) -> String {
        use std::fmt::Write;
        let mut s = String::with_capacity(data.as_ref().len() * 2);
        for b in data.as_ref() {
            let _ = write!(s, "{b:02x}");
        }
        s
    }
}

fn canonical_channel(s: &str) -> String {
    if s.starts_with('#') {
        s.to_string()
    } else {
        format!("#{s}")
    }
}

// ── GET / ───────────────────────────────────────────────────────────────

async fn get_root() -> Response {
    // Default to #general on the public deployment.
    (StatusCode::FOUND, [("Location", "/chat/general")], "").into_response()
}
// ── GET /login, POST /login ──────────────────────────────────────────────

#[derive(Deserialize)]
struct LoginForm {
    identifier: String,
}

async fn get_login(State(state): State<AppState>) -> Response {
    let mut ctx = tera::Context::new();
    ctx.insert("error", "");
    match state.tera.render("login.html.tera", &ctx) {
        Ok(html) => (
            StatusCode::OK,
            [(header::CONTENT_TYPE, "text/html; charset=utf-8")],
            html,
        )
            .into_response(),
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("template error: {e}"),
        )
            .into_response(),
    }
}

/// Return an HTML page that navigates to the given `auth_url` in the
/// same tab, then polls `/auth/status` until authentication completes
/// and redirects to `/chat/general`.
fn oauth_polling_page(auth_url: &str) -> String {
    let url = auth_url.replace('\'', "%27");
    format!(
        r##"<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>freeq — sign in</title>
<style>
:root{{color-scheme:dark;--bg:#0e1116;--fg:#d6d6d6;--muted:#6b7280;--border:#232932;--c1:#7ab7ff}}
*{{box-sizing:border-box}} html,body{{height:100%;margin:0}}
body{{font:13px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace;background:var(--bg);color:var(--fg);display:flex;align-items:center;justify-content:center}}
#box{{width:100%;max-width:340px;padding:1.5rem;border:1px solid var(--border);border-radius:8px;background:#11151b;text-align:center}}
h1{{font-size:1rem;margin:0 0 0.6rem;color:var(--c1)}}
p{{margin:0;color:var(--muted);font-size:12px;line-height:1.5}}
.error{{color:#ef476f}}
a{{color:var(--c1)}}
</style>
</head>
<body>
<div id="box">
<h1>Sign in with Bluesky</h1>
<p id="status">Waiting for authorization…</p>
<p style="margin-top:1rem"><a href="{url}">Open authorization page</a></p>
</div>
<script>
(function() {{
  const url = '{url}';
  window.location.replace(url);
  const el = document.getElementById('status');
  let done = false;
  async function check() {{
    if (done) return;
    try {{
      const r = await fetch('/auth/status');
      const j = await r.json();
      if (j.authenticated) {{
        done = true;
        window.location.replace('/chat/general');
        return;
      }}
    }} catch (e) {{}}
    setTimeout(check, 1500);
  }}
  setTimeout(check, 1500);
}})();
</script>
</body>
</html>
"##,
        url = url,
    )
}
async fn post_login(
    State(state): State<AppState>,
    req: axum::http::HeaderMap,
    axum::extract::Form(form): axum::extract::Form<LoginForm>,
) -> Response {
    let handle = form.identifier.trim().to_string();
    if handle.is_empty() {
        let mut ctx = tera::Context::new();
        ctx.insert("error", "Please enter your handle");
        let html = state
            .tera
            .render("login.html.tera", &ctx)
            .unwrap_or_default();
        return (
            StatusCode::BAD_REQUEST,
            [(header::CONTENT_TYPE, "text/html; charset=utf-8")],
            html,
        )
            .into_response();
    }

    let (sid, _) = session_id_from_request(&req);
    let session = state.session(&sid);

    // Determine OAuth flow: web-based if FREEQ_PUBLIC_URL is set,
    // loopback (localhost) otherwise.
    let is_web = state.public_url.is_some();

    if is_web {
        let public_url = state.public_url.as_ref().unwrap();
        let prepared = match PreparedLogin::for_web(&handle, public_url).await {
            Ok(p) => p,
            Err(e) => {
                warn!(session = %sid, %handle, "failed to prepare web OAuth login: {e:#}");
                let mut ctx = tera::Context::new();
                ctx.insert("error", &format!("Failed to start OAuth login: {e:#}"));
                let html = state
                    .tera
                    .render("login.html.tera", &ctx)
                    .unwrap_or_default();
                return (
                    StatusCode::BAD_REQUEST,
                    [(header::CONTENT_TYPE, "text/html; charset=utf-8")],
                    html,
                )
                    .into_response();
            }
        };

        let auth_url = prepared.auth_url().to_string();
        let state_param = prepared.state().to_string();

        // Store pending login — the callback at /auth/callback will
        // look it up by state and exchange the code.
        state
            .pending_web_logins
            .lock()
            .insert(state_param.clone(), (sid.clone(), prepared));

        debug!(session = %sid, %handle, %state_param, %auth_url, "web OAuth authorization URL ready");

        // Return the same polling page — it opens the auth URL and
        // polls /auth/status until the callback completes.
        let html = oauth_polling_page(&auth_url);
        let mut resp = (
            StatusCode::OK,
            [(header::CONTENT_TYPE, "text/html; charset=utf-8")],
            html,
        )
            .into_response();
        resp.headers_mut()
            .insert(header::SET_COOKIE, session_cookie_header(&sid));
        return resp;
    }

    // ── Loopback flow (localhost) ────────────────────────────────────

    // Start a local loopback OAuth login. The browser will be sent to the
    // PDS authorization URL; after authorization, the PDS redirects back to
    // the loopback listener on this machine and we exchange the code for an
    // OAuthSession. This works for local dev where the browser and freeq-webui
    // share 127.0.0.1.
    let prepared = match PreparedLogin::new(&handle).await {
        Ok(p) => p,
        Err(e) => {
            warn!(session = %sid, %handle, "failed to prepare OAuth login: {e:#}");
            let mut ctx = tera::Context::new();
            ctx.insert("error", &format!("Failed to start OAuth login: {e:#}"));
            let html = state
                .tera
                .render("login.html.tera", &ctx)
                .unwrap_or_default();
            return (
                StatusCode::BAD_REQUEST,
                [(header::CONTENT_TYPE, "text/html; charset=utf-8")],
                html,
            )
                .into_response();
        }
    };

    let auth_url = prepared.auth_url().to_string();
    let state_param = prepared.state().to_string();

    // Cancel any previous login attempt for this session.
    {
        let mut pending = state.pending_logins.lock();
        if let Some(sender) = pending.remove(&sid) {
            let _ = sender.send(());
        }
        let (cancel_tx, mut cancel_rx) = tokio::sync::oneshot::channel();
        pending.insert(sid.clone(), cancel_tx);
        drop(pending);

        let session_for_task = session.clone();
        let pending_logins = state.pending_logins.clone();
        let session_store = state.session_store.clone();
        let sid_task = sid.clone();
        tokio::spawn(async move {
            let result = tokio::select! {
                biased;
                _ = &mut cancel_rx => {
                    debug!(session = %sid_task, "OAuth login cancelled by newer attempt");
                    let _ = pending_logins.lock().remove(&sid_task);
                    return;
                }
                result = timeout(Duration::from_secs(300), prepared.wait()) => result,
            };
            match result {
                Ok(Ok(oauth)) => {
                    let handle = oauth.handle.clone();
                    let did = oauth.did.clone();
                    let nick = crate::sanitize_nick(&handle);
                    info!(session = %sid_task, %did, %handle, "OAuth login completed; stored session");
                    if let Some(store) = session_store {
                        if let Err(e) = store.save(&sid_task, &oauth) {
                            warn!(session = %sid_task, "failed to persist session to disk: {e:#}");
                        }
                    }
                    *session_for_task.auth.lock() = AuthState::Authenticated {
                        handle,
                        did: did.clone(),
                        nick,
                        oauth,
                    };
                    session_for_task.extracted_did.lock().replace(did);
                    session_for_task.request_reconnect();
                }
                Ok(Err(e)) => {
                    warn!(session = %sid_task, "OAuth login failed: {e:#}");
                }
                Err(_) => {
                    warn!(session = %sid_task, "OAuth login timed out");
                }
            }
            let _ = pending_logins.lock().remove(&sid_task);
        });
    }

    debug!(session = %sid, %handle, %state_param, %auth_url, "loopback OAuth authorization URL ready");

    // Return a small polling page that opens the PDS auth URL and waits for
    // the loopback login to complete.
    let html = oauth_polling_page(&auth_url);
    let mut resp = (
        StatusCode::OK,
        [(header::CONTENT_TYPE, "text/html; charset=utf-8")],
        html,
    )
        .into_response();
    resp.headers_mut()
        .insert(header::SET_COOKIE, session_cookie_header(&sid));
    resp
}

async fn post_logout(State(state): State<AppState>, req: axum::http::HeaderMap) -> Response {
    let (sid, _) = session_id_from_request(&req);
    let session = state.session(&sid);
    *session.auth.lock() = AuthState::Guest;
    session.request_reconnect();
    if let Some(store) = &state.session_store {
        if let Err(e) = store.remove(&sid) {
            warn!(session = %sid, "failed to remove persisted session: {e:#}");
        }
    }
    let resp = (StatusCode::FOUND, [("Location", "/")], "").into_response();
    resp
}
async fn get_auth_status(State(state): State<AppState>, req: axum::http::HeaderMap) -> Response {
    let (sid, _) = session_id_from_request(&req);
    let session = state.session(&sid);
    let auth = session.auth.lock().clone();
    let body = serde_json::json!({
        "authenticated": auth.is_authenticated(),
        "handle": auth.handle(),
        "did": auth.did(),
    });
    let mut resp = (
        StatusCode::OK,
        [(header::CONTENT_TYPE, "application/json")],
        body.to_string(),
    )
        .into_response();
    resp.headers_mut()
        .insert(header::SET_COOKIE, session_cookie_header(&sid));
    resp
}

// ── GET /.well-known/oauth-client-metadata ────────────────────────────

/// Serves the OAuth client metadata that Bluesky's PDS fetches to
/// discover redirect URIs and client capabilities for a web-based
/// OAuth flow (used when running behind `tailscale funnel`).
async fn get_oauth_client_metadata(State(state): State<AppState>) -> Response {
    let public_url = match &state.public_url {
        Some(url) => url.clone(),
        None => return (StatusCode::NOT_FOUND, "web OAuth not configured").into_response(),
    };

    let metadata = serde_json::json!({
        "client_id": format!("{public_url}/.well-known/oauth-client-metadata"),
        "client_name": "freeq Web UI",
        "client_uri": public_url,
        "redirect_uris": [format!("{public_url}/auth/callback")],
        "grant_types": ["authorization_code", "refresh_token"],
        "response_types": ["code"],
        "token_endpoint_auth_method": "none",
        "application_type": "web",
        "dpop_bound_access_tokens": true,
        "scope": "atproto",
    });

    (
        StatusCode::OK,
        [(header::CONTENT_TYPE, "application/json")],
        metadata.to_string(),
    )
        .into_response()
}

// ── GET /auth/callback ────────────────────────────────────────────────

#[derive(Deserialize)]
struct CallbackParams {
    code: Option<String>,
    state: Option<String>,
    error: Option<String>,
    #[serde(rename = "error_description")]
    error_description: Option<String>,
}

/// Receives the OAuth redirect from Bluesky's PDS after the user
/// authorizes. Looks up the pending login by `state`, exchanges the
/// code for tokens, and updates the session's auth state.
async fn get_auth_callback(
    State(state): State<AppState>,
    Query(params): Query<CallbackParams>,
) -> Response {
    // Handle authorization errors from the PDS
    if let Some(error) = &params.error {
        let desc = params
            .error_description
            .as_deref()
            .unwrap_or("unknown error");
        warn!(%error, %desc, "OAuth callback error");
        return (StatusCode::OK, [(header::CONTENT_TYPE, "text/html; charset=utf-8")],
            format!("<html><body><h1>Authorization Failed</h1><p>{error}: {desc}</p><p><a href=\"/login\">Try again</a></p></body></html>")
        ).into_response();
    }

    let (Some(code), Some(callback_state)) = (&params.code, &params.state) else {
        return (StatusCode::BAD_REQUEST, "Missing code or state parameter").into_response();
    };

    // Find and remove the pending login
    let (sid, prepared) = match state.pending_web_logins.lock().remove(callback_state) {
        Some(v) => v,
        None => {
            warn!(state = %callback_state, "callback with unknown state");
            return (
                StatusCode::BAD_REQUEST,
                "Unknown or expired state parameter. Please try logging in again.",
            )
                .into_response();
        }
    };

    // Exchange the code for tokens
    let oauth = match prepared.handle_callback(code, callback_state).await {
        Ok(o) => o,
        Err(e) => {
            error!(%e, "OAuth token exchange failed");
            return (
                StatusCode::OK,
                [(header::CONTENT_TYPE, "text/html; charset=utf-8")],
                format!("<html><body><h1>Sign in failed</h1><p>Token exchange failed: {e:#}</p><p><a href=\"/login\">Try again</a></p></body></html>"),
            ).into_response();
        }
    };

    // Update session auth state and persist for restarts
    let session = state.session(&sid);
    let handle = oauth.handle.clone();
    let did = oauth.did.clone();
    let nick = crate::sanitize_nick(&handle);
    info!(session = %sid, %did, %handle, "OAuth web callback completed; stored session");
    if let Some(store) = &state.session_store {
        if let Err(e) = store.save(&sid, &oauth) {
            warn!(session = %sid, "failed to persist session to disk: {e:#}");
        }
    }
    *session.auth.lock() = AuthState::Authenticated {
        handle,
        did: did.clone(),
        nick,
        oauth,
    };
    session.extracted_did.lock().replace(did);
    session.request_reconnect();

    // Redirect to chat
    let mut resp = (StatusCode::FOUND, [("Location", "/chat/general")], "").into_response();
    resp.headers_mut()
        .insert(header::SET_COOKIE, session_cookie_header(&sid));
    resp
}

/// Serve the DataStar JS bundle from the binary. Loaded via `include_str!`
/// at compile time so there's no runtime file lookup; the bundle lives at
/// `static/datastar.js` (v1.0.2, downloaded from jsDelivr).
async fn get_datastar_js() -> Response {
    (
        StatusCode::OK,
        [(
            header::CONTENT_TYPE,
            "application/javascript; charset=utf-8",
        )],
        include_str!("../static/datastar.js"),
    )
        .into_response()
}

// ── GET /chat and /chat/{channel} ──────────────────────────────────────

/// Render the chat shell for a given channel. The page lists known
/// channels (fetched from the upstream) in a sidebar; clicking a
/// channel navigates to its URL. The current channel name is baked
/// into the URLs the form posts to (`/chat/{channel}/send`, etc).
async fn get_chat(
    State(state): State<AppState>,
    Path(channel): Path<String>,
    req: axum::http::HeaderMap,
) -> Response {
    // The path always has a {channel} segment now (the bare /chat
    // route is handled by the redirect lambda above).
    let channel = canonical_channel(&channel);
    let (sid, is_new) = session_id_from_request(&req);
    // Eagerly create the session so the SSE handler can find it
    // immediately when the page opens its EventSource.
    let _ = state.session(&sid);

    // Fetch the channel list from the upstream. If it fails (e.g. the
    // upstream is down), we still render the page with an empty list —
    // the chat itself works once the WS reconnects.
    let channels = fetch_channels(&state).await.unwrap_or_default();
    debug!(channel = %channel, count = channels.len(), "fetched channel list");
    let topic = channels
        .iter()
        .find(|c| c.name.eq_ignore_ascii_case(&channel))
        .map(|c| c.topic.clone())
        .unwrap_or_default();

    // Initial scrollback so channel switches show data immediately.
    let history = fetch_history(&state, &channel, 25)
        .await
        .unwrap_or_default();
    debug!(channel = %channel, count = history.len(), "fetched history");
    let initial_messages_html = history
        .iter()
        .map(render_history_row)
        .collect::<Vec<_>>()
        .join("");

    let mut ctx = tera::Context::new();
    ctx.insert("channel", &channel.trim_start_matches('#'));
    ctx.insert("topic", &topic);
    ctx.insert("channels", &channels);
    ctx.insert("initial_messages_html", &initial_messages_html);

    // Auth state for the navbar.
    let session = state.session(&sid);
    let auth = session.auth.lock().clone();
    let (login_handle, auth_did, is_authenticated) = match &auth {
        AuthState::Authenticated { handle, did, .. } => (handle.clone(), did.clone(), true),
        AuthState::Guest => (String::new(), String::new(), false),
    };
    let joined: Vec<String> = session.joined.lock().iter().cloned().collect();
    ctx.insert("login_handle", &login_handle);
    ctx.insert("auth_did", &auth_did);
    let topic_json = serde_json::to_string(&topic)
        .unwrap_or_else(|_| "\"\"".to_string())
        .replace('"', "&quot;");
    let login_handle_json = serde_json::to_string(&login_handle)
        .unwrap_or_else(|_| "\"\"".to_string())
        .replace('"', "&quot;");
    let auth_did_json = serde_json::to_string(&auth_did)
        .unwrap_or_else(|_| "\"\"".to_string())
        .replace('"', "&quot;");
    ctx.insert("topic_json", &topic_json);
    ctx.insert("login_handle_json", &login_handle_json);
    ctx.insert("auth_did_json", &auth_did_json);
    ctx.insert("is_authenticated", &is_authenticated);
    ctx.insert("joined_channels", &joined);
    ctx.insert("show_login", &!is_authenticated);
    let body = match state.tera.render("chat.html.tera", &ctx) {
        Ok(html) => html,
        Err(e) => {
            error!("tera render error: {e:#}");
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                format!("template error: {e}"),
            )
                .into_response();
        }
    };

    let mut resp = (
        StatusCode::OK,
        [(header::CONTENT_TYPE, "text/html; charset=utf-8")],
        body,
    )
        .into_response();
    if is_new {
        resp.headers_mut()
            .insert(header::SET_COOKIE, session_cookie_header(&sid));
    }
    resp
}

// ── POST /upload ──────────────────────────────────────────────────────

async fn post_upload(
    State(state): State<AppState>,
    headers: axum::http::HeaderMap,
    mut multipart: axum::extract::Multipart,
) -> Response {
    let mut file_data: Option<Vec<u8>> = None;
    let mut content_type = "application/octet-stream".to_string();
    let mut filename = "upload".to_string();
    let mut channel = String::new();
    let mut did = String::new();
    while let Ok(Some(field)) = multipart.next_field().await {
        match field.name() {
            Some("file") => {
                content_type = field
                    .content_type()
                    .unwrap_or("application/octet-stream")
                    .to_string();
                filename = field.file_name().unwrap_or("upload").to_string();
                if let Ok(bytes) = field.bytes().await {
                    file_data = Some(bytes.to_vec());
                }
            }
            Some("channel") => {
                if let Ok(v) = field.text().await {
                    channel = v;
                }
            }
            Some("did") => {
                if let Ok(v) = field.text().await {
                    did = v;
                }
            }
            _ => {}
        }
    }
    // Enrich DID from session if available; fall back to a DID extracted from
    // 333/ACCOUNT/NOTICE lines for guests.
    let (sid, _) = session_id_from_request(&headers);
    let session = state.session(&sid);
    let session_did = session
        .auth
        .lock()
        .did()
        .map(|d| d.to_string())
        .or_else(|| session.extracted_did.lock().clone())
        .unwrap_or_default();
    let effective_did = if !session_did.is_empty() && session_did.starts_with("did:") {
        session_did
    } else {
        did
    };
    let file_data = match file_data {
        Some(d) => d,
        None => return (StatusCode::BAD_REQUEST, "No file provided").into_response(),
    };
    tracing::info!(did = %effective_did, "upload proxy forwarding");
    let upstream_url = state.upstream.base.join("api/v1/upload").unwrap();
    let form = reqwest::multipart::Form::new()
        .part(
            "file",
            reqwest::multipart::Part::bytes(file_data)
                .file_name(filename)
                .mime_str(&content_type)
                .unwrap(),
        )
        .text("did", effective_did)
        .text("channel", channel);
    match state.http.post(upstream_url).multipart(form).send().await {
        Ok(r) => {
            let status = r.status();
            let body = r.text().await.unwrap_or_default();
            (status, [(header::CONTENT_TYPE, "application/json")], body).into_response()
        }
        Err(e) => (StatusCode::BAD_GATEWAY, format!("upstream: {e}")).into_response(),
    }
}

// ── GET /chat/{channel}/events ──────────────────────────────────────────

async fn get_channel_events(
    State(state): State<AppState>,
    Path(channel): Path<String>,
    req: axum::http::HeaderMap,
    axum::extract::Query(_params): axum::extract::Query<std::collections::HashMap<String, String>>,
) -> Response {
    let (sid, _is_new) = session_id_from_request(&req);
    let session = state.session(&sid);

    debug!(session = %sid, channel = %channel, "SSE subscriber connected");

    let upstream = state.upstream.clone();

    // Subscribe BEFORE we (possibly) spawn the WS task — otherwise
    // messages that arrive during the WS handshake would be lost.
    let mut lines_rx = session.lines_tx.subscribe();

    spawn_upstream_if_needed(&state, &sid, &session, upstream.clone(), &channel);

    let stream = async_stream::stream! {
        let status_patch = PatchSignals::new(r#"{"connected":true}"#);
        yield Ok::<Event, std::convert::Infallible>(status_patch.write_as_axum_sse_event());
        loop {
            match lines_rx.recv().await {
                Ok(line) => {
                    let canon = canonical_channel(&channel);
                    if is_353(&line) {
                        let entries = parse_353_members(&line);
                        debug!(session = %sid, channel = %canon, count = entries.len(), "NAMES 353 parsed");
                        let member_html = {
                            let mut members = session.channel_members.lock();
                            let map = members.entry(canon.clone()).or_default();
                            for e in &entries {
                                map.insert(e.nick.clone(), e.clone());
                            }
                            render_member_list(map)
                        };
                        let escaped = member_html.replace('\\', r"\\").replace('$', r"\$").replace('`', r"\`");
                        let js = format!("document.getElementById('member-panel').innerHTML=`{escaped}`");
                        let script = ExecuteScript::new(js);
                        yield Ok::<Event, std::convert::Infallible>(script.write_as_axum_sse_event());
                        continue;
                    }
                    // --- Extract real DID from ACCOUNT messages ---
                    if let Some(new_did) = parse_account_did(&line) {
                        *session.extracted_did.lock() = Some(new_did.clone());
                        let mut auth = session.auth.lock();
                        if let AuthState::Authenticated { ref mut did, .. } = &mut *auth {
                            *did = new_did.clone();
                            info!(session = %sid, did = %new_did, "authenticated DID updated from account-notify");
                        } else {
                            info!(session = %sid, did = %new_did, "DID extracted from account-notify");
                        }
                        continue;
                    }
                    // --- Extract full DID from 333 (topic setter) lines ---
                    if let Some(new_did) = parse_333_did(&line) {
                        *session.extracted_did.lock() = Some(new_did.clone());
                        info!(session = %sid, did = %new_did, "DID extracted from 333");
                        continue;
                    }
                    // --- live topic updates (TOPIC / 332) ---
                    if let Some(new_topic) = parse_topic_change(&line, &canon) {
                        debug!(session = %sid, channel = %canon, topic = %new_topic, "live topic update received");
                        // Custom lightweight SSE event that the page's inline
                        // EventSource handler uses to update the topic text directly,
                        let topic_event = Event::default()
                            .event("topicupdate")
                            .data(serde_json::json!(&new_topic).to_string());
                        yield Ok::<Event, std::convert::Infallible>(topic_event);
                    }
                    // --- channel error numerics (442 / 482) ---
                    if let Some(err_text) = parse_channel_error(&line, &canon) {
                        let ts = Utc::now().format("%H:%M:%S").to_string();
                        let safe = html_escape(err_text);
                        let html = format!(r#"<div class="notice"><span class="ts">{ts}</span><span class="body">{safe}</span></div>"#);
                        let patch = PatchElements::new(html).selector("#messages").mode(ElementPatchMode::Append);
                        yield Ok::<Event, std::convert::Infallible>(patch.write_as_axum_sse_event());
                        let scroll = ExecuteScript::new("document.getElementById('messages').scrollTop = 999999");
                        yield Ok::<Event, std::convert::Infallible>(scroll.write_as_axum_sse_event());
                    }
                    // --- live member tracking (JOIN/PART/QUIT/MODE) ---
                    if let Some(change) = parse_member_change(&line) {
                        let member_html: Option<String> = {
                            let mut members = session.channel_members.lock();
                            let map = members.entry(canon.clone()).or_default();
                            match change {
                                MemberChange::Join { channel, nick }
                                    if channel.eq_ignore_ascii_case(&canon) =>
                                {
                                    map.entry(nick.clone())
                                        .or_insert_with(|| MemberEntry {
                                            nick,
                                            ..Default::default()
                                        });
                                    Some(render_member_list(map))
                                }
                                MemberChange::Part { channel, nick }
                                    if channel.eq_ignore_ascii_case(&canon) =>
                                {
                                    if map.remove(&nick).is_some() {
                                        Some(render_member_list(map))
                                    } else {
                                        None
                                    }
                                }
                                MemberChange::Quit { nick } => {
                                    if map.remove(&nick).is_some() {
                                        Some(render_member_list(map))
                                    } else {
                                        None
                                    }
                                }
                                MemberChange::Mode { channel, ops }
                                    if channel.eq_ignore_ascii_case(&canon) =>
                                {
                                    let mut changed = false;
                                    for (mc, adding, target) in &ops {
                                        if let Some(e) = map.get_mut(target) {
                                            match mc {
                                                'o' if e.op != *adding => { e.op = *adding; changed = true; }
                                                'h' if e.halfop != *adding => { e.halfop = *adding; changed = true; }
                                                'v' if e.voiced != *adding => { e.voiced = *adding; changed = true; }
                                                _ => {}
                                            }
                                        }
                                    }
                                    if changed { Some(render_member_list(map)) } else { None }
                                }
                                _ => None, // event for a different channel; ignore
                            }
                        };
                        if let Some(html) = member_html {
                            debug!(session = %sid, channel = %canon, "member panel updated");
                            let escaped = html.replace('\\', "\\\\").replace('$', "\\$").replace('`', "\\`");
                            let js = format!("document.getElementById('member-panel').innerHTML=`{escaped}`");
                            let script = ExecuteScript::new(js);
                            yield Ok::<Event, std::convert::Infallible>(script.write_as_axum_sse_event());
                        }
                        // Don't fall through to generic message emission —
                        // JOIN/PART/QUIT/MODE are handled above.
                        continue;
                    }
                    // --- SASL 903 (authentication success) ---
                    if is_903(&line) {
                        info!(session = %sid, "SASL authentication successful");
                        // Push updated auth signals to the browser navbar
                        let (handle, did) = {
                            let auth = session.auth.lock();
                            match &*auth {
                                AuthState::Authenticated { handle, did, .. } =>
                                    (handle.clone(), did.clone()),
                                AuthState::Guest =>
                                    (String::new(), String::new()),
                            }
                        };
                        let signals = serde_json::json!({
                            "auth_handle": handle,
                            "auth_did": did,
                        });
                        let signal_patch = PatchSignals::new(&signals.to_string());
                        yield Ok::<Event, std::convert::Infallible>(signal_patch.write_as_axum_sse_event());
                        let script = ExecuteScript::new(
                            "document.getElementById('status').classList.add('connected')".to_string(),
                        );
                        yield Ok::<Event, std::convert::Infallible>(script.write_as_axum_sse_event());
                        continue;
                    }
                    // --- SASL 904 (authentication failure) ---
                    if is_904(&line) {
                        warn!(session = %sid, "SASL authentication failed");
                        let signals = PatchSignals::new(r#"{"auth_handle":"","auth_did":""}"#);
                        yield Ok::<Event, std::convert::Infallible>(signals.write_as_axum_sse_event());
                        continue;
                    }
                    // --- Extract DID from auth NOTICE ("authenticated as did:plc:...") ---
                    if let Some(new_did) = parse_auth_notice_did(&line) {
                        *session.extracted_did.lock() = Some(new_did.clone());
                        let mut auth = session.auth.lock();
                        if let AuthState::Authenticated { ref mut did, .. } = &mut *auth {
                            *did = new_did.clone();
                            info!(session = %sid, did = %new_did, "authenticated DID updated from NOTICE");
                        }
                        continue;
                    }
                    // --- messages (channel-filtered) ---
                    if should_emit(&line, &channel) {
                        let html = render_irc_line(&line);
                        let patch = PatchElements::new(html).selector("#messages").mode(ElementPatchMode::Append);
                        yield Ok::<Event, std::convert::Infallible>(patch.write_as_axum_sse_event());
                    } else {
                        trace!(session = %sid, line = %line.trim_end(), "line not emitted to client");
                    }
                }
                Err(broadcast::error::RecvError::Lagged(n)) => {
                    warn!(session = %sid, lagged = n, "SSE stream lagged");
                    continue;
                }
                Err(broadcast::error::RecvError::Closed) => {
                    warn!(session = %sid, "lines_tx closed — breaking SSE loop");
                    break;
                }
            }
        }
    };

    Sse::new(stream)
        .keep_alive(KeepAlive::new().interval(Duration::from_secs(15)))
        .into_response()
}

// ── POST /chat/{channel}/send ───────────────────────────────────────────

#[derive(Deserialize)]
struct SendSignals {
    msg: String,
}

#[derive(Deserialize)]
struct JoinSignals {
    channel: String,
}

#[derive(Deserialize)]
struct TopicSignals {
    topic_draft: String,
}

async fn post_channel_send(
    State(state): State<AppState>,
    Path(channel): Path<String>,
    req: axum::http::HeaderMap,
    ReadSignals(signals): ReadSignals<SendSignals>,
) -> Response {
    let (sid, _is_new) = session_id_from_request(&req);
    let session = state.session(&sid);

    let msg = signals.msg.trim();
    if msg.is_empty() {
        return (StatusCode::NO_CONTENT, "").into_response();
    }

    let target = canonical_channel(&channel);
    let auth = session.auth.lock().clone();
    let user = auth.handle().unwrap_or("guest");
    let did = auth.did().unwrap_or("");
    let ws_state = session.get_ws_state();
    let reg_phase = session.reg_phase.lock().clone();
    let is_joined = session.joined.lock().contains(&target);
    debug!(session = %sid, channel = %target, len = msg.len(), ?ws_state, reg_phase, is_joined, user, did, "send requested");

    if ws_state != WsState::Ready {
        debug!(session = %sid, channel = %target, ?ws_state, "send rejected: not ready");
        return (StatusCode::SERVICE_UNAVAILABLE, "not connected yet").into_response();
    }

    if !is_joined {
        debug!(session = %sid, channel = %target, "send rejected: not joined");
        return (StatusCode::SERVICE_UNAVAILABLE, "not joined").into_response();
    }

    let irc_tx = session.irc_tx.lock().clone();
    if let Err(e) = irc_tx.send(format!("PRIVMSG {target} :{msg}\r\n")).await {
        warn!(session = %sid, "send to upstream failed: {e}");
        return (StatusCode::SERVICE_UNAVAILABLE, "upstream WS gone").into_response();
    }

    debug!(session = %sid, channel = %target, user, did, "PRIVMSG queued to upstream; echoing to DOM");
    // server doesn't reflect a PRIVMSG back to its sender, so the
    // long-lived /events SSE never receives this line.
    let ts = Utc::now().format("%H:%M:%S").to_string();
    let safe = html_escape(&msg);
    let echo_html = format!(
        r#"<div class="msg"><span class="ts">{ts}</span><span class="body"><span class="nick n1">you</span> {safe}</span></div>"#
    );
    let echo = PatchElements::new(echo_html)
        .selector("#messages")
        .mode(ElementPatchMode::Append);
    let echo_event = echo.write_as_axum_sse_event();
    let clear = PatchSignals::new(r#"{"msg":""}"#);
    let clear_event = clear.write_as_axum_sse_event();
    let scroll = ExecuteScript::new("document.getElementById('messages').scrollTop = 999999");
    let scroll_event = scroll.write_as_axum_sse_event();
    Sse::new(async_stream::stream! {
        yield Ok::<Event, std::convert::Infallible>(echo_event);
        yield Ok::<Event, std::convert::Infallible>(scroll_event);
        yield Ok::<Event, std::convert::Infallible>(clear_event);
    })
    .into_response()
}
async fn post_channel_join(
    State(state): State<AppState>,
    Path(_path_chan): Path<String>,
    req: axum::http::HeaderMap,
    ReadSignals(signals): ReadSignals<JoinSignals>,
) -> Response {
    let (sid, _is_new) = session_id_from_request(&req);
    let session = state.session(&sid);

    let target = canonical_channel(signals.channel.trim());

    if target == "#" {
        return (StatusCode::BAD_REQUEST, "channel required").into_response();
    }

    debug!(session = %sid, channel = %target, "join requested");

    session.joined.lock().insert(target.clone());
    let irc_tx = session.irc_tx.lock().clone();
    if let Err(e) = irc_tx.send(format!("JOIN {target}\r\n")).await {
        warn!(session = %sid, "join failed: {e}");
        return (StatusCode::SERVICE_UNAVAILABLE, "upstream WS gone").into_response();
    }

    // Tell the browser to navigate to the new channel page.
    // DataStar `@post` does a fetch() which follows 302 internally
    // without navigating — we use ExecuteScript instead.
    let url = format!("/chat/{}", target.trim_start_matches('#'));
    let js = format!("window.location='{}'", url);
    let evt = ExecuteScript::new(&js);
    let event = evt.write_as_axum_sse_event();
    Sse::new(async_stream::stream! {
        yield Ok::<Event, std::convert::Infallible>(event);
    })
    .into_response()
}

/// Send `PART {channel}` over the upstream WS.
async fn post_channel_part(
    State(state): State<AppState>,
    Path(channel): Path<String>,
    req: axum::http::HeaderMap,
) -> Response {
    let (sid, _is_new) = session_id_from_request(&req);
    let session = state.session(&sid);
    let target = canonical_channel(&channel);
    debug!(session = %sid, channel = %target, "part requested");
    session.joined.lock().remove(&target);
    let irc_tx = session.irc_tx.lock().clone();
    let _ = irc_tx.send(format!("PART {target}\r\n")).await;
    let evt = ExecuteScript::new("window.location='/chat/general'");
    let event = evt.write_as_axum_sse_event();
    Sse::new(async_stream::stream! {
        yield Ok::<Event, std::convert::Infallible>(event);
    })
    .into_response()
}

async fn post_channel_topic(
    State(state): State<AppState>,
    Path(channel): Path<String>,
    req: axum::http::HeaderMap,
    ReadSignals(signals): ReadSignals<TopicSignals>,
) -> Response {
    let (sid, _is_new) = session_id_from_request(&req);
    let session = state.session(&sid);
    let target = canonical_channel(&channel);
    let text = signals.topic_draft;
    let auth = session.auth.lock().clone();
    let user = auth.handle().unwrap_or("guest");
    let did = auth.did().unwrap_or("");
    debug!(session = %sid, channel = %target, len = text.len(), user, did, text = %text, "topic change requested");

    let irc_tx = session.irc_tx.lock().clone();
    if let Err(e) = irc_tx.send(format!("TOPIC {target} :{text}\r\n")).await {
        warn!(session = %sid, user, did, "topic change failed: {e}");
        return (StatusCode::SERVICE_UNAVAILABLE, "upstream WS gone").into_response();
    }

    debug!(session = %sid, channel = %target, user, did, "TOPIC queued to upstream");

    let clear = PatchSignals::new(r#"{"editing_topic":false,"topic_draft":""}"#);
    let clear_event = clear.write_as_axum_sse_event();
    Sse::new(async_stream::stream! {
        yield Ok::<Event, std::convert::Infallible>(clear_event);
    })
    .into_response()
}

async fn get_channels(State(state): State<AppState>) -> Response {
    let url = state
        .upstream
        .base
        .join("api/v1/channels")
        .expect("upstream URL is valid");
    match state.http.get(url).send().await {
        Ok(r) => {
            let status = r.status();
            let body = r.text().await.unwrap_or_default();
            (status, [(header::CONTENT_TYPE, "application/json")], body).into_response()
        }
        Err(e) => (StatusCode::BAD_GATEWAY, format!("upstream: {e}")).into_response(),
    }
}

// ── IRC line formatting ─────────────────────────────────────────────────

fn should_emit(line: &str, current_channel: &str) -> bool {
    let line = line.trim_end_matches(['\r', '\n']);
    if line.starts_with("PING ") || line.starts_with("PONG ") {
        return false;
    }
    // Server numerics look like `:host 001 nick :welcome...`. Skip them.
    let Some(rest) = line.strip_prefix(':') else {
        return true;
    };
    let Some(sp) = rest.find(' ') else {
        return true;
    };
    let after_prefix = &rest[sp + 1..];
    let bytes = after_prefix.as_bytes();
    if bytes.len() >= 3
        && bytes[0].is_ascii_digit()
        && bytes[1].is_ascii_digit()
        && bytes[2].is_ascii_digit()
    {
        return false;
    }
    // Channel-scoped messages: only emit if the target matches the
    // channel this SSE subscriber is viewing.
    if let Some(target) = extract_irc_target(after_prefix) {
        let canon_cur = canonical_channel(current_channel);
        if !target.eq_ignore_ascii_case(&canon_cur) {
            return false;
        }
    }
    true
}

/// Extract the target channel/nick from an IRC command line (after the
/// prefix). Returns `None` for commands without a channel target.
fn extract_irc_target(after_prefix: &str) -> Option<&str> {
    // PRIVMSG #chan :msg  /  NOTICE #chan :msg  /  TOPIC #chan :new  /  etc.
    let cmd_end = after_prefix.find(' ')?;
    let command = &after_prefix[..cmd_end];
    match command {
        "PRIVMSG" | "NOTICE" | "TOPIC" | "MODE" | "KICK" | "INVITE" => {
            let rest = &after_prefix[cmd_end + 1..];
            let target_end = rest.find(' ').unwrap_or(rest.len());
            let target = &rest[..target_end];
            // Only filter if the target looks like a channel (starts with
            // # / & / + / !). Server-wide NOTICE * or PRIVMSG to a nick
            // should pass through unfiltered.
            if target.starts_with('#')
                || target.starts_with('&')
                || target.starts_with('+')
                || target.starts_with('!')
            {
                Some(target)
            } else {
                None
            }
        }
        _ => None,
    }
}
/// Render an IRC line as an HTML row with timestamp + nick color.
fn render_irc_line(line: &str) -> String {
    let line = line.trim_end_matches(['\r', '\n']);
    let ts = Utc::now().format("%H:%M:%S").to_string();
    let ts_html = format!(r#"<span class="ts">{ts}</span>"#);

    if let Some(rest) = line.strip_prefix(':') {
        if let Some(sp) = rest.find(' ') {
            let prefix = &rest[..sp];
            let cmd_and_args = &rest[sp + 1..];
            let nick = prefix.split('!').next().unwrap_or(prefix);
            let mut parts = cmd_and_args.splitn(3, ' ');
            let cmd = parts.next().unwrap_or("");

            if matches!(cmd, "PRIVMSG" | "NOTICE") {
                let _target = parts.next().unwrap_or("");
                let text = parts.next().unwrap_or("").trim_start_matches(':');
                let cls = if cmd == "NOTICE" { "notice" } else { "msg" };
                let color = nick_color_class(nick);
                let safe_text = linkify_urls(&html_escape(text));
                return format!(
                    r#"<div class="{cls}">{ts_html}<span class="body"><span class="nick {color}">{nick}</span> {safe_text}</span></div>"#
                );
            }
            if matches!(cmd, "JOIN" | "PART" | "QUIT") {
                let cls = match cmd {
                    "JOIN" => "join",
                    _ => "part",
                };
                return format!(
                    r#"<div class="{cls}">{ts_html}<span class="body">— {nick} {cmd_lower}</span></div>"#,
                    cmd_lower = cmd.to_lowercase(),
                );
            }
            let safe = html_escape(line);
            return format!(
                r#"<div class="notice">{ts_html}<span class="body">{safe}</span></div>"#
            );
        }
    }
    let safe = html_escape(line);
    format!(r#"<div class="notice">{ts_html}<span class="body">{safe}</span></div>"#)
}

/// A membership-affecting IRC event parsed from a line.
///
/// `Join`/`Part`/`Mode` carry the channel so the handler can ignore events
/// for other channels; `Quit` has no channel (it applies to every channel
/// the user was in, so the current view removes them).
enum MemberChange {
    Join {
        channel: String,
        nick: String,
    },
    Part {
        channel: String,
        nick: String,
    },
    Quit {
        nick: String,
    },
    /// `(mode_char, adding, target_nick)` — only `o`/`h`/`v` affect display.
    Mode {
        channel: String,
        ops: Vec<(char, bool, String)>,
    },
}

/// Parse an IRC line into a [`MemberChange`], if it is one. Recognizes
/// JOIN / PART / QUIT and channel MODE (user-mode changes are ignored).
fn parse_member_change(line: &str) -> Option<MemberChange> {
    let line = line.trim_end_matches(['\r', '\n']);
    let rest = line.strip_prefix(':')?;
    let sp = rest.find(' ')?;
    let prefix = &rest[..sp];
    let cmd_and_args = &rest[sp + 1..];
    let nick = prefix.split('!').next().unwrap_or(prefix).to_string();
    let mut parts = cmd_and_args.split(' ');
    let cmd = parts.next()?;
    match cmd {
        "JOIN" => {
            // `JOIN #chan` or extended `JOIN #chan account :realname`.
            // Some servers colon the channel (`JOIN :#chan`); trim it.
            let channel = parts.next()?.trim_start_matches(':').to_string();
            Some(MemberChange::Join { channel, nick })
        }
        "PART" => {
            let channel = parts.next()?.trim_start_matches(':').to_string();
            Some(MemberChange::Part { channel, nick })
        }
        "QUIT" => Some(MemberChange::Quit { nick }),
        "MODE" => {
            let channel = parts.next()?.trim_start_matches(':').to_string();
            // Only channel modes affect the nick list; a user-mode change
            // (target is a nick, not a channel) is not a member change.
            if !channel.starts_with('#') && !channel.starts_with('&') {
                return None;
            }
            let modestring = parts.next()?;
            let mut ops = Vec::new();
            let mut adding = true;
            for c in modestring.chars() {
                match c {
                    '+' => adding = true,
                    '-' => adding = false,
                    // Member modes consume one target arg each.
                    'o' | 'h' | 'v' => {
                        if let Some(target) = parts.next() {
                            ops.push((c, adding, target.to_string()));
                        }
                    }
                    // Channel modes (n, t, s, i, k, l, …) take no member
                    // target here; don't consume an arg.
                    _ => {}
                }
            }
            Some(MemberChange::Mode { channel, ops })
        }
        _ => None,
    }
}
/// Parse a live topic change (`TOPIC #chan :text`) or the RPL_TOPIC
/// numeric (`:server 332 <nick> #chan :text`) and return the new
/// topic text only if it is for the requested channel.
fn parse_topic_change(line: &str, current_channel: &str) -> Option<String> {
    let line = line.trim_end_matches(['\r', '\n']);
    let rest = line.strip_prefix(':')?;
    // Locate the trailing `:` parameter and the tokens before it.
    let colon_idx = rest.find(" :")?;
    let before = &rest[..colon_idx];
    let text = &rest[colon_idx + 2..];
    let mut tokens = before.split_whitespace();
    let _source = tokens.next()?;
    let second = tokens.next()?;
    let channel = if second.eq_ignore_ascii_case("TOPIC") {
        tokens.next()?
    } else if second == "332" {
        let _nick = tokens.next()?;
        tokens.next()?
    } else {
        return None;
    };
    if channel.eq_ignore_ascii_case(current_channel) {
        Some(text.to_string())
    } else {
        None
    }
}

/// Parse a channel-scoped error numeric (442 ERR_NOTONCHANNEL,
/// 482 ERR_CHANOPRIVSNEEDED) and return a short human-readable message
/// if it targets the channel the user is viewing.
fn parse_channel_error(line: &str, current_channel: &str) -> Option<&'static str> {
    let line = line.trim_end_matches(['\r', '\n']);
    let rest = line.strip_prefix(':')?;
    let mut tokens = rest.split_whitespace();
    let _server = tokens.next()?;
    let numeric = tokens.next()?;
    if !matches!(numeric, "442" | "482") {
        return None;
    }
    let _nick = tokens.next()?;
    let channel = tokens.next()?;
    if !channel.eq_ignore_ascii_case(current_channel) {
        return None;
    }
    match numeric {
        "442" => Some("You are not on that channel."),
        "482" => Some("You must be a channel operator to change the topic."),
        _ => None,
    }
}

/// Render the member map as an HTML list. Used by the SSE handler to
/// update `#member-panel`. Members are sorted by rank (op → halfop →
/// voiced → plain) then case-insensitively by nick; the mode prefix is
/// rendered as a separate colored span so the bare nick stays the key
/// that JOIN/PART/QUIT/MODE match against.
fn render_member_list(members: &std::collections::HashMap<String, MemberEntry>) -> String {
    if members.is_empty() {
        return r#"<div class="member empty">—</div>"#.to_string();
    }
    let mut sorted: Vec<&MemberEntry> = members.values().collect();
    sorted.sort_by(|a, b| {
        let rank = |m: &MemberEntry| match (m.op, m.halfop, m.voiced) {
            (true, _, _) => 0,
            (_, true, _) => 1,
            (_, _, true) => 2,
            _ => 3,
        };
        rank(a)
            .cmp(&rank(b))
            .then_with(|| a.nick.to_lowercase().cmp(&b.nick.to_lowercase()))
    });
    sorted
        .iter()
        .map(|m| {
            let color = nick_color_class(&m.nick);
            let safe_nick = html_escape(&m.nick);
            let pfx = if m.op {
                r#"<span class="pfx op">@</span>"#
            } else if m.halfop {
                r#"<span class="pfx halfop">%</span>"#
            } else if m.voiced {
                r#"<span class="pfx voice">+</span>"#
            } else {
                ""
            };
            format!(
                r#"<div class="member">{pfx}<span class="nick {color}">{safe_nick}</span></div>"#
            )
        })
        .collect::<Vec<_>>()
        .join("")
}

/// Check if an IRC line is a 353 (NAMES reply).
fn is_353(line: &str) -> bool {
    let line = line.trim_end_matches(['\r', '\n']);
    let Some(rest) = line.strip_prefix(':') else {
        return false;
    };
    let Some(sp) = rest.find(' ') else {
        return false;
    };
    rest[sp + 1..].starts_with("353 ")
}

/// Parse a DID from a 333 (RPL_TOPICWHOTIME) line: `:server 333 nick #chan did:plc:FULL 12345`
fn parse_333_did(line: &str) -> Option<String> {
    let line = line.trim_end_matches(['\r', '\n']);
    let rest = line.strip_prefix(':')?;
    let (_prefix, rest) = rest.split_once(' ')?;
    // rest = "333 nick #chan did:plc:xxx timestamp"
    let parts: Vec<&str> = rest.splitn(4, ' ').collect();
    // parts = ["333", "nick", "#chan", "did:plc:xxx timestamp"]
    if parts.len() < 4 || parts[0] != "333" {
        return None;
    }
    let rest2 = parts[3];
    let did = rest2.split(' ').next()?;
    if did.starts_with("did:plc:") {
        Some(did.to_string())
    } else {
        None
    }
}

/// Parse DID from auth NOTICE: `:server NOTICE nick :...authenticated as did:plc:XXX...`
fn parse_auth_notice_did(line: &str) -> Option<String> {
    let line = line.trim_end_matches(['\r', '\n']);
    if !line.contains("authenticated as did:plc:") {
        return None;
    }
    let start = line.find("did:plc:")?;
    let rest = &line[start..];
    let end = rest
        .find(|c: char| c.is_whitespace() || c == ')')
        .unwrap_or(rest.len());
    Some(rest[..end].to_string())
}

/// Parse a DID from an IRCv3 ACCOUNT message: `:nick ACCOUNT did:plc:xxx`
fn parse_account_did(line: &str) -> Option<String> {
    let line = line.trim_end_matches(['\r', '\n']);
    let (_prefix, rest) = line.strip_prefix(':')?.split_once(' ')?;
    let (cmd, did) = rest.split_once(' ')?;
    if cmd != "ACCOUNT" {
        return None;
    }
    if did == "*" {
        return None;
    } // logged out
    Some(did.to_string())
}

/// Parse nicks from a 353 (RPL_NAMREPLY) line, stripping IRC mode
/// prefixes (`@` op, `%` halfop, `+` voice, plus `~`/`&` owner/admin)
/// and dropping empty tokens (e.g. from a trailing space). Returns one
/// [`MemberEntry`] per nick with the mode flags set from its prefixes.
fn parse_353_members(line: &str) -> Vec<MemberEntry> {
    let line = line.trim_end_matches(['\r', '\n']);
    let names = match line.rfind(" :") {
        Some(i) => &line[i + 2..],
        None => return Vec::new(),
    };
    names
        .split(' ')
        .filter(|t| !t.is_empty())
        .map(|token| {
            let pfx_len = token
                .chars()
                .take_while(|c| matches!(c, '@' | '%' | '+' | '~' | '&'))
                .count();
            let nick = &token[pfx_len..];
            let pfx = &token[..pfx_len];
            MemberEntry {
                nick: nick.to_string(),
                op: pfx.contains('@') || pfx.contains('~') || pfx.contains('&'),
                halfop: pfx.contains('%'),
                voiced: pfx.contains('+'),
            }
        })
        .collect()
}
/// as live IRC lines. `sender` is a full hostmask like
/// `nick!user@host`; we display just the nick. `timestamp` is epoch
/// seconds from the server DB.
fn render_history_row(msg: &UpstreamHistoryMessage) -> String {
    let nick = msg.sender.split('!').next().unwrap_or(&msg.sender);
    let color = nick_color_class(nick);
    let ts = chrono::DateTime::<Utc>::from_timestamp(msg.timestamp, 0)
        .map(|dt| dt.format("%H:%M:%S").to_string())
        .unwrap_or_else(|| "--:--:--".to_string());
    let safe_text = html_escape(&msg.text);
    format!(
        r#"<div class="msg"><span class="ts">{ts}</span><span class="body"><span class="nick {color}">{nick}</span> {safe_text}</span></div>"#
    )
}
fn nick_color_class(nick: &str) -> &'static str {
    let mut h: u64 = 5381;
    for b in nick.bytes() {
        h = h.wrapping_mul(33).wrapping_add(b as u64);
    }
    const CLASSES: &[&str] = &["n1", "n2", "n3", "n4", "n5", "n6", "n7", "n8"];
    CLASSES[(h % 8) as usize]
}

fn html_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&#39;"),
            _ => out.push(c),
        }
    }
    out
}

/// Convert a handle into a valid IRC nick: keep only alphanumeric,
/// dots, hyphens, underscores; truncate to 20 chars.
fn sanitize_nick(handle: &str) -> String {
    let mut out = String::with_capacity(handle.len().min(20));
    for c in handle.chars() {
        if c.is_ascii_alphanumeric() || c == '.' || c == '-' || c == '_' {
            out.push(c);
        }
        if out.len() >= 20 {
            break;
        }
    }
    if out.is_empty() {
        return String::new();
    }
    // Must start with a letter.
    if !out.starts_with(|c: char| c.is_ascii_alphabetic()) {
        out.insert(0, 'u');
        out.truncate(20);
    }
    out
}

/// Wrap `https://` URLs in the already-escaped text with `<a target="_blank">`.
fn linkify_urls(escaped: &str) -> String {
    // Text is already HTML-escaped. Find https://... and wrap in <a>.
    let mut out = String::with_capacity(escaped.len() + 64);
    let mut rest = escaped;
    while let Some(pos) = rest.find("https://") {
        out.push_str(&rest[..pos]);
        let url_end = rest[pos..]
            .find(|c: char| c.is_whitespace() || c == '<')
            .unwrap_or(rest.len() - pos);
        let url = &rest[pos..pos + url_end];
        out.push_str(&format!(
            r#"<a href="{url}" target="_blank" rel="noopener">{url}</a>"#
        ));
        rest = &rest[pos + url_end..];
    }
    out.push_str(rest);
    out
}
#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    fn entry(nick: &str, op: bool, halfop: bool, voiced: bool) -> MemberEntry {
        MemberEntry {
            nick: nick.to_string(),
            op,
            halfop,
            voiced,
        }
    }

    // ── parse_353_members ───────────────────────────────────────────────────

    #[test]
    fn parse_353_strips_mode_prefixes() {
        let line = ":srv 353 me = #ch :@op +voice %half normal";
        let v = parse_353_members(line);
        let nicks: Vec<&str> = v.iter().map(|e| e.nick.as_str()).collect();
        assert_eq!(nicks, vec!["op", "voice", "half", "normal"]);
        assert!(v[0].op);
        assert!(v[1].voiced);
        assert!(v[2].halfop);
        assert!(!v[3].op && !v[3].halfop && !v[3].voiced);
    }

    #[test]
    fn parse_353_owner_admin_prefixes_map_to_op() {
        let v = parse_353_members(":srv 353 me = #ch :~owner &admin");
        assert_eq!(v[0].nick, "owner");
        assert!(v[0].op);
        assert_eq!(v[1].nick, "admin");
        assert!(v[1].op);
    }

    #[test]
    fn parse_353_drops_empty_tokens() {
        // Trailing + double spaces yield empty split tokens that must be dropped.
        let v = parse_353_members(":srv 353 me = #ch :a  b ");
        let nicks: Vec<&str> = v.iter().map(|e| e.nick.as_str()).collect();
        assert_eq!(nicks, vec!["a", "b"]);
    }

    #[test]
    fn parse_353_no_trailing_param_is_empty() {
        assert!(parse_353_members(":srv 353 me = #ch").is_empty());
        assert!(parse_353_members("not an irc line").is_empty());
    }

    // ── parse_member_change ─────────────────────────────────────────────────

    #[test]
    fn parse_join_basic() {
        let c = parse_member_change(":alice!u@h JOIN #general").unwrap();
        match c {
            MemberChange::Join { channel, nick } => {
                assert_eq!(channel, "#general");
                assert_eq!(nick, "alice");
            }
            _ => panic!("expected Join"),
        }
    }

    #[test]
    fn parse_join_extended_ignores_extra_params() {
        let c = parse_member_change(":alice!u@h JOIN #general acct :Real Name").unwrap();
        match c {
            MemberChange::Join { channel, nick } => {
                assert_eq!(channel, "#general");
                assert_eq!(nick, "alice");
            }
            _ => panic!("expected Join"),
        }
    }

    #[test]
    fn parse_part() {
        let c = parse_member_change(":bob!u@h PART #general :leaving").unwrap();
        match c {
            MemberChange::Part { channel, nick } => {
                assert_eq!(channel, "#general");
                assert_eq!(nick, "bob");
            }
            _ => panic!("expected Part"),
        }
    }

    #[test]
    fn parse_quit() {
        let c = parse_member_change(":carol!u@h QUIT :ping timeout").unwrap();
        match c {
            MemberChange::Quit { nick } => assert_eq!(nick, "carol"),
            _ => panic!("expected Quit"),
        }
    }

    #[test]
    fn parse_mode_plus_ov_consumes_two_targets() {
        let c = parse_member_change(":op!u@h MODE #ch +ov alice bob").unwrap();
        match c {
            MemberChange::Mode { channel, ops } => {
                assert_eq!(channel, "#ch");
                assert_eq!(
                    ops,
                    vec![('o', true, "alice".into()), ('v', true, "bob".into())]
                );
            }
            _ => panic!("expected Mode"),
        }
    }

    #[test]
    fn parse_mode_mixed_signs() {
        let c = parse_member_change(":op!u@h MODE #ch -o+v alice bob").unwrap();
        match c {
            MemberChange::Mode { ops, .. } => {
                assert_eq!(
                    ops,
                    vec![('o', false, "alice".into()), ('v', true, "bob".into())]
                );
            }
            _ => panic!("expected Mode"),
        }
    }

    #[test]
    fn parse_mode_channel_modes_take_no_target() {
        // +nt are channel modes with no member targets — ops stays empty.
        let c = parse_member_change(":op!u@h MODE #ch +nt").unwrap();
        match c {
            MemberChange::Mode { ops, .. } => assert!(ops.is_empty()),
            _ => panic!("expected Mode"),
        }
    }

    #[test]
    fn parse_mode_user_mode_is_not_a_member_change() {
        // Target is a nick, not a channel — not a nick-list change.
        assert!(parse_member_change(":alice!u@h MODE alice +i").is_none());
    }

    #[test]
    fn parse_non_member_command_is_none() {
        assert!(parse_member_change(":alice!u@h PRIVMSG #ch :hi").is_none());
        assert!(parse_member_change("PING :srv").is_none());
    }

    // ── render_member_list ──────────────────────────────────────────────────

    #[test]
    fn render_empty_returns_placeholder() {
        let map: HashMap<String, MemberEntry> = HashMap::new();
        assert_eq!(
            render_member_list(&map),
            r#"<div class="member empty">—</div>"#
        );
    }

    #[test]
    fn render_sorts_by_rank_then_alpha() {
        let mut map: HashMap<String, MemberEntry> = HashMap::new();
        map.insert("zoe".into(), entry("zoe", false, false, false));
        map.insert("amy".into(), entry("amy", false, false, true)); // voiced
        map.insert("bob".into(), entry("bob", true, false, false)); // op
        map.insert("cal".into(), entry("cal", false, false, false));
        let html = render_member_list(&map);
        let pos = |n: &str| html.find(n).unwrap();
        assert!(pos("bob") < pos("amy"), "op before voiced");
        assert!(pos("amy") < pos("cal"), "voiced before plain");
        assert!(pos("cal") < pos("zoe"), "plain alphabetical");
    }

    #[test]
    fn render_shows_prefix_spans_only_for_ranked() {
        let mut map: HashMap<String, MemberEntry> = HashMap::new();
        map.insert("op".into(), entry("op", true, false, false));
        map.insert("hp".into(), entry("hp", false, true, false));
        map.insert("vc".into(), entry("vc", false, false, true));
        map.insert("pl".into(), entry("pl", false, false, false));
        let html = render_member_list(&map);
        assert!(html.contains(r#"<span class="pfx op">@</span>"#));
        assert!(html.contains(r#"<span class="pfx halfop">%</span>"#));
        assert!(html.contains(r#"<span class="pfx voice">+</span>"#));
        // Exactly three prefix spans — the plain member has none.
        assert_eq!(html.matches("pfx").count(), 3);
    }

    #[test]
    fn render_escapes_nick() {
        let mut map: HashMap<String, MemberEntry> = HashMap::new();
        map.insert("a<b>&c".into(), entry("a<b>&c", false, false, false));
        let html = render_member_list(&map);
        assert!(html.contains("a&lt;b&gt;&amp;c"));
        assert!(!html.contains("a<b>&c"));
    }

    // ── should_emit / extract_irc_target ────────────────────────────────────

    #[test]
    fn should_emit_filters_privmsg_to_other_channel() {
        // PRIVMSG to #other should not emit when viewing #test
        assert!(!should_emit(":alice!u@h PRIVMSG #other :hello", "#test"));
    }

    #[test]
    fn should_emit_passes_privmsg_to_same_channel() {
        assert!(should_emit(":alice!u@h PRIVMSG #test :hello", "#test"));
    }

    #[test]
    fn should_emit_case_insensitive_channel_match() {
        assert!(should_emit(":alice!u@h PRIVMSG #TEST :hello", "#test"));
    }

    #[test]
    fn should_emit_filters_notice_to_other_channel() {
        assert!(!should_emit(":srv NOTICE #other :something", "#test"));
    }

    #[test]
    fn should_emit_passes_notice_to_same_channel() {
        assert!(should_emit(":srv NOTICE #test :welcome", "#test"));
    }

    #[test]
    fn should_emit_filters_topic_to_other_channel() {
        assert!(!should_emit(":op!u@h TOPIC #other :new topic", "#test"));
    }

    #[test]
    fn should_emit_passes_topic_to_same_channel() {
        assert!(should_emit(":op!u@h TOPIC #test :new topic", "#test"));
    }

    #[test]
    fn should_emit_passes_non_channel_scoped_message() {
        // Server notice without a channel target should pass through
        assert!(should_emit(":srv NOTICE * :Server shutting down", "#test"));
    }

    #[test]
    fn should_emit_skips_ping() {
        assert!(!should_emit("PING :server", "#test"));
    }

    #[test]
    fn should_emit_skips_numerics() {
        assert!(!should_emit(":srv 001 alice :Welcome to freeq", "#test"));
    }

    #[test]
    fn extract_target_privmsg() {
        assert_eq!(extract_irc_target("PRIVMSG #chan :hello"), Some("#chan"));
    }

    #[test]
    fn extract_target_notice_channel() {
        assert_eq!(extract_irc_target("NOTICE #chan :msg"), Some("#chan"));
    }

    #[test]
    fn extract_target_notice_star_returns_none() {
        // Server broadcast NOTICE * is not channel-scoped
        assert_eq!(extract_irc_target("NOTICE * :Server shutting down"), None);
    }

    #[test]
    fn extract_target_privmsg_nick_returns_none() {
        // PRIVMSG to a nick is not channel-scoped
        assert_eq!(extract_irc_target("PRIVMSG alice :hello"), None);
    }

    #[test]
    fn extract_target_mode() {
        assert_eq!(extract_irc_target("MODE #chan +o bob"), Some("#chan"));
    }

    #[test]
    fn extract_target_non_channel_command_returns_none() {
        assert_eq!(extract_irc_target("QUIT :bye"), None);
        assert_eq!(extract_irc_target("JOIN :#chan"), None);
        assert_eq!(extract_irc_target("PART #chan"), None);
    }

    // ── parse_topic_change ────────────────────────────────────────────────

    #[test]
    fn parse_topic_change_topic_same_channel() {
        assert_eq!(
            parse_topic_change(":op!u@h TOPIC #test :new topic", "#test"),
            Some("new topic".to_string())
        );
    }

    #[test]
    fn parse_topic_change_topic_other_channel_is_none() {
        assert_eq!(
            parse_topic_change(":op!u@h TOPIC #other :new topic", "#test"),
            None
        );
    }

    #[test]
    fn parse_topic_change_332_same_channel() {
        assert_eq!(
            parse_topic_change(":srv 332 alice #test :welcome", "#test"),
            Some("welcome".to_string())
        );
    }

    #[test]
    fn parse_topic_change_332_other_channel_is_none() {
        assert_eq!(
            parse_topic_change(":srv 332 alice #other :welcome", "#test"),
            None
        );
    }

    #[test]
    fn parse_topic_change_topic_with_colons_and_channel_in_text() {
        assert_eq!(
            parse_topic_change(":op!u@h TOPIC #test :visit #test at https://x/y", "#test"),
            Some("visit #test at https://x/y".to_string())
        );
    }
}
