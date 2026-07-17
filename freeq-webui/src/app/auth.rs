use topcoat::context::Cx;
use topcoat::router::{Json, query_params, route, see_other, SeeOther};
use topcoat::Result;
use tracing::{error, info, warn};

use crate::app::state;
use crate::irc_render::sanitize_nick;
use crate::session_util::ensure_session_id;
use crate::state::AuthState;

#[derive(serde::Serialize)]
struct AuthStatus {
    authenticated: bool,
    handle: Option<String>,
    did: Option<String>,
}

#[route(GET "/auth/status")]
async fn auth_status(cx: &Cx) -> Result<Json<AuthStatus>> {
    let app = state(cx);
    let sid = ensure_session_id(cx);
    let session = app.session(&sid);
    let auth = session.auth.lock().clone();
    Ok(Json(match auth {
        AuthState::Guest => AuthStatus {
            authenticated: false,
            handle: None,
            did: None,
        },
        AuthState::Authenticated { handle, did, .. } => AuthStatus {
            authenticated: true,
            handle: Some(handle),
            did: Some(did),
        },
    }))
}

#[route(GET "/.well-known/oauth-client-metadata")]
async fn oauth_client_metadata(cx: &Cx) -> Result<Json<serde_json::Value>> {
    let app = state(cx);
    let Some(public_url) = app.public_url.as_ref() else {
        return Ok(Json(serde_json::json!({
            "error": "FREEQ_PUBLIC_URL not set"
        })));
    };
    let public_url = public_url.trim_end_matches('/');
    Ok(Json(serde_json::json!({
        "client_id": format!("{public_url}/.well-known/oauth-client-metadata"),
        "client_name": "freeq-webui",
        "client_uri": public_url,
        "redirect_uris": [format!("{public_url}/auth/callback")],
        "grant_types": ["authorization_code"],
        "response_types": ["code"],
        "application_type": "web",
        "token_endpoint_auth_method": "none",
        "dpop_bound_access_tokens": true,
        "scope": "atproto transition:generic",
    })))
}

#[query_params(error = bad_request)]
struct CallbackParams {
    code: Option<String>,
    state: Option<String>,
    error: Option<String>,
    #[serde(rename = "error_description")]
    error_description: Option<String>,
}

#[route(GET "/auth/callback")]
async fn auth_callback(cx: &Cx) -> Result<SeeOther> {
    let app = state(cx);
    let params = query_params::<CallbackParams>(cx)?;

    if let Some(error) = &params.error {
        let desc = params
            .error_description
            .as_deref()
            .unwrap_or("unknown error");
        warn!(%error, %desc, "OAuth callback error");
        return Ok(see_other("/login"));
    }

    let (Some(code), Some(callback_state)) = (params.code.as_deref(), params.state.as_deref())
    else {
        return Ok(see_other("/login"));
    };

    let (sid, prepared) = match app.pending_web_logins.lock().remove(callback_state) {
        Some(v) => v,
        None => {
            warn!(state = %callback_state, "callback with unknown state");
            return Ok(see_other("/login"));
        }
    };

    // Ensure cookie matches the session that started login.
    let cookie_sid = ensure_session_id(cx);
    let sid = if cookie_sid != sid {
        // Prefer the original sid from pending login so disk restore matches.
        sid
    } else {
        cookie_sid
    };

    let oauth = match prepared.handle_callback(code, callback_state).await {
        Ok(o) => o,
        Err(e) => {
            error!(%e, "OAuth token exchange failed");
            return Ok(see_other("/login"));
        }
    };

    let session = app.session(&sid);
    let handle = oauth.handle.clone();
    let did = oauth.did.clone();
    let nick = sanitize_nick(&handle);
    info!(session = %sid, %did, %handle, "OAuth web callback completed");
    if let Some(store) = &app.session_store {
        if let Err(e) = store.save(&sid, &oauth) {
            warn!(session = %sid, "failed to persist session: {e:#}");
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

    Ok(see_other("/chat"))
}
