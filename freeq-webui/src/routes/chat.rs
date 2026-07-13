//! Chat page and channel action routes.

use axum::extract::{Form, Json, Path, State};
use axum::http::{header, StatusCode};
use axum::response::{IntoResponse, Response};
use chrono::Utc;
use serde::Deserialize;
use tracing::{debug, error, warn};

use crate::helpers::{canonical_channel, html_escape, session_id_from_request};
use crate::irc::render_history_row;
use crate::state::{AppState, AuthState, MemberEntry, WsState};
use crate::upstream::{fetch_channels, fetch_history, spawn_upstream_if_needed, UpstreamChannel};

#[derive(Deserialize)]
pub struct SendForm {
    msg: String,
}

#[derive(Deserialize)]
pub struct JoinForm {
    channel: String,
}

#[derive(Deserialize)]
pub struct PartForm {
    #[allow(dead_code)]
    dummy: Option<String>,
}

#[derive(Deserialize)]
pub struct TopicForm {
    topic: String,
}

#[derive(Deserialize)]
pub struct ReactForm {
    msgid: String,
    emoji: String,
}

/// Parse a `/nick <newnick>` command from the input box.
/// Returns the new nick if the message starts with a case-insensitive `/nick `
/// prefix followed by a non-empty token; returns `None` otherwise.
pub fn parse_nick_command(msg: &str) -> Option<&str> {
    if msg.len() > 6
        && msg
            .get(..6)
            .is_some_and(|p| p.eq_ignore_ascii_case("/nick "))
    {
        msg[6..].split_whitespace().next().map(str::trim)
    } else {
        None
    }
}

/// Parse a `/whois <nick>` command from the input box.
pub fn parse_whois_command(msg: &str) -> Option<&str> {
    if msg.len() > 7
        && msg
            .get(..7)
            .is_some_and(|p| p.eq_ignore_ascii_case("/whois "))
    {
        msg[7..].split_whitespace().next().map(str::trim)
    } else {
        None
    }
}

pub async fn get_channels_page(State(state): State<AppState>, req: axum::http::HeaderMap) -> Response {
    let (sid, is_new) = session_id_from_request(&req);
    let _ = state.session(&sid);

    let mut channels = fetch_channels(&state).await.unwrap_or_default();
    debug!(count = channels.len(), "fetched channel list for landing");

    let session = state.session(&sid);
    let joined: std::collections::HashSet<String> = session.joined.lock().iter().cloned().collect();
    let existing: std::collections::HashSet<String> =
        channels.iter().map(|c| c.name.to_lowercase()).collect();
    for ch in joined {
        let c = canonical_channel(&ch);
        if !existing.contains(&c.to_lowercase()) {
            channels.push(UpstreamChannel {
                name: c,
                topic: String::new(),
                members: 0,
            });
        }
    }

    let session = state.session(&sid);
    let auth = session.auth.lock().clone();
    let (login_handle, auth_did, is_authenticated) = match &auth {
        AuthState::Authenticated { handle, did, .. } => (handle.clone(), did.clone(), true),
        AuthState::Guest => (String::new(), String::new(), false),
    };
    let joined: Vec<String> = session.joined.lock().iter().cloned().collect();
    let current_nick = session.current_nick.lock().clone();

    let mut ctx = tera::Context::new();
    ctx.insert("channels", &channels);
    ctx.insert("login_handle", &login_handle);
    ctx.insert("auth_did", &auth_did);
    let login_handle_json = serde_json::to_string(&login_handle)
        .unwrap_or_else(|_| "\"\"".to_string())
        .replace('"', "&quot;");
    let auth_did_json = serde_json::to_string(&auth_did)
        .unwrap_or_else(|_| "\"\"".to_string())
        .replace('"', "&quot;");
    let current_nick_json = serde_json::to_string(&current_nick)
        .unwrap_or_else(|_| "\"\"".to_string())
        .replace('"', "&quot;");
    ctx.insert("login_handle_json", &login_handle_json);
    ctx.insert("auth_did_json", &auth_did_json);
    ctx.insert("current_nick_json", &current_nick_json);
    ctx.insert("current_nick", &current_nick);
    ctx.insert("is_authenticated", &is_authenticated);
    ctx.insert("joined_channels", &joined);

    let body = match state.tera.render("channels.html.tera", &ctx) {
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
            .insert(header::SET_COOKIE, crate::helpers::session_cookie_header(&sid));
    }
    resp
}

pub async fn get_chat(
    State(state): State<AppState>,
    Path(channel): Path<String>,
    req: axum::http::HeaderMap,
) -> Response {
    let channel = canonical_channel(&channel);
    let (sid, is_new) = session_id_from_request(&req);
    let _ = state.session(&sid);

    let mut channels = fetch_channels(&state).await.unwrap_or_default();
    debug!(channel = %channel, count = channels.len(), "fetched channel list");

    let session = state.session(&sid);
    let joined: std::collections::HashSet<String> = session.joined.lock().iter().cloned().collect();
    let existing: std::collections::HashSet<String> =
        channels.iter().map(|c| c.name.to_lowercase()).collect();
    for ch in joined {
        let c = canonical_channel(&ch);
        if !existing.contains(&c.to_lowercase()) {
            channels.push(UpstreamChannel {
                name: c,
                topic: String::new(),
                members: 0,
            });
        }
    }

    let local_member_count: Option<usize> =
        if channels.iter().any(|c| c.name.eq_ignore_ascii_case(&channel)) {
            Some(
                session
                    .channel_members
                    .lock()
                    .get(&canonical_channel(&channel))
                    .map(|m| m.len())
                    .unwrap_or(0),
            )
        } else {
            None
        };

    let topic = channels
        .iter()
        .find(|c| c.name.eq_ignore_ascii_case(&channel))
        .map(|c| c.topic.clone())
        .unwrap_or_default();

    let history = fetch_history(&state, &channel, 25, None)
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

    let joined: Vec<String> = session.joined.lock().iter().cloned().collect();
    let channels_json = serde_json::json!({
        "channels": &channels,
        "joined": &joined,
        "current_channel": channel,
    })
    .to_string();
    ctx.insert("channels_json", &channels_json.replace("</", "<\\/"));
    let auth = session.auth.lock().clone();
    let (login_handle, auth_did, is_authenticated) = match &auth {
        AuthState::Authenticated { handle, did, .. } => (handle.clone(), did.clone(), true),
        AuthState::Guest => (String::new(), String::new(), false),
    };
    let joined: Vec<String> = session.joined.lock().iter().cloned().collect();
    let current_nick = session.current_nick.lock().clone();
    ctx.insert("login_handle", &login_handle);
    ctx.insert("auth_did", &auth_did);
    let auth_json = serde_json::json!({
        "handle": &login_handle,
        "did": &auth_did,
        "is_authenticated": is_authenticated,
    })
    .to_string()
    .replace("</", "<\\/");
    ctx.insert("auth_json", &auth_json);
    let topic_json = serde_json::to_string(&topic)
        .unwrap_or_else(|_| "\"\"".to_string())
        .replace('"', "&quot;");
    let login_handle_json = serde_json::to_string(&login_handle)
        .unwrap_or_else(|_| "\"\"".to_string())
        .replace('"', "&quot;");
    let auth_did_json = serde_json::to_string(&auth_did)
        .unwrap_or_else(|_| "\"\"".to_string())
        .replace('"', "&quot;");
    let current_nick_json = serde_json::to_string(&current_nick)
        .unwrap_or_else(|_| "\"\"".to_string())
        .replace('"', "&quot;");
    ctx.insert("topic_json", &topic_json);
    ctx.insert("login_handle_json", &login_handle_json);
    ctx.insert("auth_did_json", &auth_did_json);
    ctx.insert("current_nick_json", &current_nick_json);
    ctx.insert("current_nick", &current_nick);
    ctx.insert("is_authenticated", &is_authenticated);
    ctx.insert("joined_channels", &joined);
    ctx.insert("show_login", &!is_authenticated);
    ctx.insert("local_member_count", &local_member_count);

    let initial_members: Vec<MemberEntry> = session
        .channel_members
        .lock()
        .get(&canonical_channel(&channel))
        .map(|m| m.values().cloned().collect())
        .unwrap_or_default();
    ctx.insert("initial_members", &initial_members);
    let initial_members_json = serde_json::to_string(&initial_members)
        .unwrap_or_else(|_| "[]".to_string());
    ctx.insert("initial_members_json", &initial_members_json);
    spawn_upstream_if_needed(&state, &sid, &session, std::sync::Arc::clone(&state.upstream), &channel);

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
        [
            (header::CONTENT_TYPE, "text/html; charset=utf-8"),
            (header::CACHE_CONTROL, "no-store, no-cache, must-revalidate"),
        ],
        body,
    )
        .into_response();
    if is_new {
        resp.headers_mut()
            .insert(header::SET_COOKIE, crate::helpers::session_cookie_header(&sid));
    }
    resp
}

pub async fn post_channel_send(
    State(state): State<AppState>,
    Path(channel): Path<String>,
    req: axum::http::HeaderMap,
    Form(form): Form<SendForm>,
) -> Response {
    let (sid, _is_new) = session_id_from_request(&req);
    let session = state.session(&sid);

    let msg = form.msg.trim();
    if msg.is_empty() {
        return redirect_to_channel(&channel);
    }

    let target = canonical_channel(&channel);
    let ws_state = session.get_ws_state();
    let is_joined = session.joined.lock().contains(&target);
    debug!(session = %sid, channel = %target, len = msg.len(), ?ws_state, is_joined, "send requested");

    if ws_state != WsState::Ready {
        debug!(session = %sid, channel = %target, ?ws_state, "send rejected: not ready");
        return redirect_to_channel(&channel);
    }

    if let Some(new_nick) = parse_nick_command(msg) {
        let irc_tx = session.irc_tx.lock().clone();
        if irc_tx.send(format!("NICK {new_nick}\r\n")).await.is_err() {
            warn!(session = %sid, "NICK command failed");
            return redirect_to_channel(&channel);
        }
        *session.current_nick.lock() = new_nick.to_string();
        debug!(session = %sid, nick = %new_nick, "NICK queued to upstream");
        return redirect_to_channel(&channel);
    }

    if let Some(whois_nick) = parse_whois_command(msg) {
        let irc_tx = session.irc_tx.lock().clone();
        if irc_tx
            .send(format!("WHOIS {whois_nick}\r\n"))
            .await
            .is_err()
        {
            warn!(session = %sid, "WHOIS command failed");
            return redirect_to_channel(&channel);
        }
        debug!(session = %sid, nick = %whois_nick, "WHOIS queued to upstream");
        return redirect_to_channel(&channel);
    }

    if !is_joined {
        debug!(session = %sid, channel = %target, "send rejected: not joined");
        return redirect_to_channel(&channel);
    }

    let irc_tx = session.irc_tx.lock().clone();
    if irc_tx
        .send(format!("PRIVMSG {target} :{msg}\r\n"))
        .await
        .is_err()
    {
        warn!(session = %sid, "send to upstream failed");
        return redirect_to_channel(&channel);
    }
    debug!(session = %sid, channel = %target, "PRIVMSG queued to upstream");
    redirect_to_channel(&channel)
}

pub async fn post_channel_react(
    State(state): State<AppState>,
    Path(channel): Path<String>,
    req: axum::http::HeaderMap,
    Json(form): Json<ReactForm>,
) -> Response {
    let (sid, _is_new) = session_id_from_request(&req);
    let session = state.session(&sid);

    let target = canonical_channel(&channel);
    let msgid = form.msgid.trim();
    let emoji = form.emoji.trim();
    if msgid.is_empty() || emoji.is_empty() {
        return redirect_to_channel(&channel);
    }
    if emoji.len() > 32 || emoji.chars().any(|c| c.is_control() || c.is_whitespace()) {
        return redirect_to_channel(&channel);
    }
    if msgid.len() > 64
        || msgid
            .chars()
            .any(|c| !(c.is_ascii_alphanumeric() || c == '-' || c == '_'))
    {
        return redirect_to_channel(&channel);
    }

    let ws_state = session.get_ws_state();
    let is_joined = session.joined.lock().contains(&target);
    if ws_state != WsState::Ready || !is_joined {
        return redirect_to_channel(&channel);
    }

    let safe_emoji = emoji.replace('\\', "\\\\").replace(';', "\\:").replace(' ', "\\s");
    let safe_msgid = msgid.replace('\\', "\\\\").replace(';', "\\:").replace(' ', "\\s");
    let cmd = format!("@+react={safe_emoji};+reply={safe_msgid} TAGMSG {target}\r\n");

    let irc_tx = session.irc_tx.lock().clone();
    if irc_tx.send(cmd).await.is_err() {
        warn!(session = %sid, "react to upstream failed");
    } else {
        debug!(session = %sid, channel = %target, msgid, emoji, "reaction queued to upstream");
    }
    redirect_to_channel(&channel)
}

pub async fn post_channel_unreact(
    State(state): State<AppState>,
    Path(channel): Path<String>,
    req: axum::http::HeaderMap,
    Json(form): Json<ReactForm>,
) -> Response {
    let (sid, _is_new) = session_id_from_request(&req);
    let session = state.session(&sid);

    let target = canonical_channel(&channel);
    let msgid = form.msgid.trim();
    let emoji = form.emoji.trim();
    if msgid.is_empty() || emoji.is_empty() {
        return redirect_to_channel(&channel);
    }
    if emoji.len() > 32 || emoji.chars().any(|c| c.is_control() || c.is_whitespace()) {
        return redirect_to_channel(&channel);
    }
    if msgid.len() > 64
        || msgid
            .chars()
            .any(|c| !(c.is_ascii_alphanumeric() || c == '-' || c == '_'))
    {
        return redirect_to_channel(&channel);
    }

    let ws_state = session.get_ws_state();
    let is_joined = session.joined.lock().contains(&target);
    if ws_state != WsState::Ready || !is_joined {
        return redirect_to_channel(&channel);
    }

    let safe_emoji = emoji.replace('\\', "\\\\").replace(';', "\\:").replace(' ', "\\s");
    let safe_msgid = msgid.replace('\\', "\\\\").replace(';', "\\:").replace(' ', "\\s");
    let cmd = format!("@+freeq.at/unreact={safe_emoji};+reply={safe_msgid} TAGMSG {target}\r\n");

    let irc_tx = session.irc_tx.lock().clone();
    if irc_tx.send(cmd).await.is_err() {
        warn!(session = %sid, "unreact to upstream failed");
    } else {
        debug!(session = %sid, channel = %target, msgid, emoji, "unreact queued to upstream");
    }
    redirect_to_channel(&channel)
}

pub async fn post_channel_join(
    State(state): State<AppState>,
    Path(_path_chan): Path<String>,
    req: axum::http::HeaderMap,
    Form(form): Form<JoinForm>,
) -> Response {
    let (sid, _is_new) = session_id_from_request(&req);
    let session = state.session(&sid);

    let target = canonical_channel(form.channel.trim());

    if target == "#" {
        return (StatusCode::BAD_REQUEST, "channel required").into_response();
    }

    debug!(session = %sid, channel = %target, "join requested");

    session.joined.lock().insert(target.clone());
    let irc_tx = session.irc_tx.lock().clone();
    if irc_tx.send(format!("JOIN {target}\r\n")).await.is_err() {
        warn!(session = %sid, "join failed");
        return redirect_to_channel(&_path_chan);
    }

    let url = format!("/chat/{}", target.trim_start_matches('#'));
    redirect(&url)
}

pub async fn post_channel_part(
    State(state): State<AppState>,
    Path(channel): Path<String>,
    req: axum::http::HeaderMap,
    Form(_form): Form<PartForm>,
) -> Response {
    let (sid, _is_new) = session_id_from_request(&req);
    let session = state.session(&sid);
    let target = canonical_channel(&channel);
    debug!(session = %sid, channel = %target, "part requested");
    session.joined.lock().remove(&target);
    let irc_tx = session.irc_tx.lock().clone();
    let _ = irc_tx.send(format!("PART {target}\r\n")).await;
    redirect("/chat")
}

pub async fn post_channel_topic(
    State(state): State<AppState>,
    Path(channel): Path<String>,
    req: axum::http::HeaderMap,
    Form(form): Form<TopicForm>,
) -> Response {
    let (sid, _is_new) = session_id_from_request(&req);
    let session = state.session(&sid);
    let target = canonical_channel(&channel);
    let text = form.topic;
    debug!(session = %sid, channel = %target, len = text.len(), text = %text, "topic change requested");

    let irc_tx = session.irc_tx.lock().clone();
    if irc_tx
        .send(format!("TOPIC {target} :{text}\r\n"))
        .await
        .is_err()
    {
        warn!(session = %sid, "topic change failed");
    } else {
        debug!(session = %sid, channel = %target, "TOPIC queued to upstream");
    }
    redirect_to_channel(&channel)
}

fn redirect_to_channel(channel: &str) -> Response {
    let url = format!("/chat/{}", channel.trim_start_matches('#'));
    redirect(&url)
}

fn redirect(url: &str) -> Response {
    (StatusCode::FOUND, [("Location", url)], "").into_response()
}
