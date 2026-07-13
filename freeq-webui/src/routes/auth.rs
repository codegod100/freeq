//! Authentication routes: login, logout, callback, status, OAuth metadata.

use std::time::Duration;

use axum::extract::{Form, Query, State};
use axum::http::{header, StatusCode};
use axum::response::{IntoResponse, Response};
use freeq_sdk::oauth::PreparedLogin;
use serde::Deserialize;
use tokio::time::timeout;
use tracing::{debug, error, info, warn};

use crate::helpers::{
    public_url_from_request, sanitize_nick, session_cookie_header, session_id_from_request,
};
use crate::state::{AppState, AuthState};

#[derive(Deserialize)]
pub struct LoginForm {
    identifier: String,
}

#[derive(Deserialize)]
pub struct CallbackParams {
    code: Option<String>,
    state: Option<String>,
    error: Option<String>,
    #[serde(rename = "error_description")]
    error_description: Option<String>,
}

pub async fn get_login(State(state): State<AppState>) -> Response {
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
/// and redirects to `/chat`.
pub fn oauth_polling_page(auth_url: &str) -> String {
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
    try {{
      const r = await fetch('/auth/status');
      const j = await r.json();
      if (j.authenticated) {{
        done = true;
        window.location.replace('/chat');
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

pub async fn post_login(
    State(state): State<AppState>,
    req: axum::http::HeaderMap,
    Form(form): Form<LoginForm>,
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

    let effective_public_url: Option<String> = match &state.public_url {
        Some(u) => Some(u.clone()),
        None => public_url_from_request(&req),
    };
    let is_web = effective_public_url.is_some();

    if is_web {
        let public_url = effective_public_url.as_ref().unwrap();
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

        state
            .pending_web_logins
            .lock()
            .insert(state_param.clone(), (sid.clone(), prepared));

        debug!(session = %sid, %handle, %state_param, %auth_url, "web OAuth authorization URL ready");

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
                    let nick = sanitize_nick(&handle);
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

pub async fn post_logout(State(state): State<AppState>, req: axum::http::HeaderMap) -> Response {
    let (sid, _) = session_id_from_request(&req);
    let session = state.session(&sid);
    *session.auth.lock() = AuthState::Guest;
    session.request_reconnect();
    if let Some(store) = &state.session_store {
        if let Err(e) = store.remove(&sid) {
            warn!(session = %sid, "failed to remove persisted session: {e:#}");
        }
    }
    let mut resp = (StatusCode::FOUND, [("Location", "/")], "").into_response();
    resp.headers_mut()
        .insert(header::SET_COOKIE, session_cookie_header(&sid));
    resp
}

pub async fn get_auth_status(State(state): State<AppState>, req: axum::http::HeaderMap) -> Response {
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

pub async fn get_oauth_client_metadata(
    State(state): State<AppState>,
    req: axum::http::HeaderMap,
) -> Response {
    let public_url = match state
        .public_url
        .clone()
        .or_else(|| public_url_from_request(&req))
    {
        Some(u) => u,
        None => {
            return (
                StatusCode::NOT_FOUND,
                "web OAuth not configured (set FREEQ_PUBLIC_URL or connect via a non-loopback host)",
            )
                .into_response();
        }
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

pub async fn get_auth_callback(
    State(state): State<AppState>,
    Query(params): Query<CallbackParams>,
) -> Response {
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

    let session = state.session(&sid);
    let handle = oauth.handle.clone();
    let did = oauth.did.clone();
    let nick = sanitize_nick(&handle);
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

    let mut resp = (StatusCode::FOUND, [("Location", "/chat")], "").into_response();
    resp.headers_mut()
        .insert(header::SET_COOKIE, session_cookie_header(&sid));
    resp
}
