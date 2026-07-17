use std::time::Duration;

use serde::Deserialize;
use topcoat::context::Cx;
use topcoat::router::{Form, SeeOther, page, route, see_other};
use topcoat::view::view;
use topcoat::Result;
use tracing::{debug, info, warn};

use crate::app::state;
use crate::irc_render::sanitize_nick;
use crate::oauth_flow::PreparedLogin;
use crate::session_util::ensure_session_id;
use crate::state::AuthState;

#[page("/login")]
async fn login_page(cx: &Cx) -> Result {
    let _ = ensure_session_id(cx);
    view! {
        <div class="min-h-dvh flex items-center justify-center p-4">
            <div class="w-full max-w-md rounded-xl border border-[#232932] bg-[#151a22] p-6 shadow-xl">
                <h1 class="text-xl font-semibold tracking-tight">"Sign in to freeq"</h1>
                <p class="mt-2 text-sm text-zinc-400">
                    "Use your Bluesky / AT Protocol handle. Private keys never leave your PDS."
                </p>
                <form method="POST" action="/login" class="mt-6 flex flex-col gap-3">
                    <label class="text-xs uppercase tracking-wide text-zinc-500">"Handle"</label>
                    <input
                        class="rounded-lg border border-[#232932] bg-[#0e1116] px-3 py-2 text-sm outline-none focus:border-[#7ab7ff]"
                        type="text"
                        name="identifier"
                        placeholder="you.bsky.social"
                        required=(true)
                        autofocus=(true)
                        autocomplete="username"
                    >
                    <button
                        type="submit"
                        class="mt-2 rounded-lg bg-[#7ab7ff] px-3 py-2 text-sm font-semibold text-[#0e1116] hover:brightness-110"
                    >
                        "Continue with AT Protocol"
                    </button>
                </form>
                <p class="mt-4 text-center text-sm text-zinc-500">
                    <a href="/chat" class="text-[#7ab7ff] hover:underline">"Continue as guest"</a>
                </p>
            </div>
        </div>
    }
}

#[derive(Deserialize)]
struct LoginForm {
    identifier: String,
}

#[route(POST "/login")]
async fn post_login(cx: &Cx, Form(form): Form<LoginForm>) -> Result<SeeOther> {
    let handle = form.identifier.trim().to_string();
    if handle.is_empty() {
        return Ok(see_other("/login"));
    }

    let app = state(cx);
    let sid = ensure_session_id(cx);
    let session = app.session(&sid);

    if let Some(public_url) = app.public_url.clone() {
        let prepared = match PreparedLogin::for_web(&handle, &public_url).await {
            Ok(p) => p,
            Err(e) => {
                warn!(session = %sid, %handle, "web OAuth prepare failed: {e:#}");
                return Ok(see_other("/login"));
            }
        };
        let auth_url = prepared.auth_url().to_string();
        let state_param = prepared.state().to_string();
        app.pending_web_logins
            .lock()
            .insert(state_param, (sid.clone(), prepared));
        debug!(session = %sid, %handle, %auth_url, "web OAuth ready");
        return Ok(see_other(&auth_url));
    }

    // Loopback OAuth (browser + webui on same machine).
    let prepared = match PreparedLogin::new(&handle).await {
        Ok(p) => p,
        Err(e) => {
            warn!(session = %sid, %handle, "loopback OAuth prepare failed: {e:#}");
            return Ok(see_other("/login"));
        }
    };
    let auth_url = prepared.auth_url().to_string();
    {
        let mut pending = app.pending_logins.lock();
        if let Some(sender) = pending.remove(&sid) {
            let _ = sender.send(());
        }
        let (cancel_tx, mut cancel_rx) = tokio::sync::oneshot::channel();
        pending.insert(sid.clone(), cancel_tx);
        drop(pending);

        let session_for_task = session.clone();
        let pending_logins = app.pending_logins.clone();
        let session_store = app.session_store.clone();
        let sid_task = sid.clone();
        tokio::spawn(async move {
            let result = tokio::select! {
                biased;
                _ = &mut cancel_rx => {
                    let _ = pending_logins.lock().remove(&sid_task);
                    return;
                }
                result = tokio::time::timeout(Duration::from_secs(300), prepared.wait()) => result,
            };
            match result {
                Ok(Ok(oauth)) => {
                    let handle = oauth.handle.clone();
                    let did = oauth.did.clone();
                    let nick = sanitize_nick(&handle);
                    info!(session = %sid_task, %did, %handle, "OAuth login completed");
                    if let Some(store) = session_store {
                        if let Err(e) = store.save(&sid_task, &oauth) {
                            warn!(session = %sid_task, "persist session failed: {e:#}");
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
                Ok(Err(e)) => warn!(session = %sid_task, "OAuth login failed: {e:#}"),
                Err(_) => warn!(session = %sid_task, "OAuth login timed out"),
            }
            let _ = pending_logins.lock().remove(&sid_task);
        });
    }

    Ok(see_other(&auth_url))
}

#[route(POST "/logout")]
async fn post_logout(cx: &Cx) -> Result<SeeOther> {
    let app = state(cx);
    let sid = ensure_session_id(cx);
    let session = app.session(&sid);
    *session.auth.lock() = AuthState::Guest;
    session.extracted_did.lock().take();
    if let Some(store) = &app.session_store {
        let _ = store.remove(&sid);
    }
    session.request_reconnect();
    Ok(see_other("/chat"))
}
