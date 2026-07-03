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
use std::sync::atomic::Ordering;

use anyhow::{Context, Result};
use axum::extract::{Path, State};
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
use rand::Rng;
use serde::Deserialize;
use tokio::sync::broadcast;
use tower_http::cors::{Any, CorsLayer};
use tracing::{debug, error, info, trace, warn};
use url::Url;

use crate::state::{AppState, MemberEntry};
use crate::upstream::{fetch_channels, fetch_history, spawn_upstream_if_needed, UpstreamHistoryMessage};

// ── main ────────────────────────────────────────────────────────────────

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| {
                    tracing_subscriber::EnvFilter::new(
                        "debug,reqwest=info,hyper=info,tungstenite=info",
                    )
                }),
        )
        .init();

    let upstream = std::env::var("FREEQ_UPSTREAM")
        .unwrap_or_else(|_| "http://127.0.0.1:8080".to_string());
    let bind = std::env::var("FREEQ_WEBUI_BIND")
        .unwrap_or_else(|_| "127.0.0.1:8090".to_string());
    let upstream_url: Url = upstream.parse().context("FREEQ_UPSTREAM must be a URL")?;

    let state = AppState::new(upstream_url.clone())?;
    info!(upstream = %upstream_url, bind = %bind, "freeq-webui starting");

    let app = Router::new()
        .route("/", get(get_root))
        .route("/chat", get(|| async { (StatusCode::FOUND, [("Location", "/chat/general")], "").into_response() }))
        .route("/chat/{channel}", get(get_chat))
        .route("/chat/{channel}/events", get(get_channel_events))
        .route("/chat/{channel}/send", post(post_channel_send))
        .route("/chat/{channel}/join", post(post_channel_join))
        .route("/chat/{channel}/part", post(post_channel_part))
        .route("/datastar.js", get(get_datastar_js))
        .route("/api/channels", get(get_channels))
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

// ── GET /datastar.js ───────────────────────────────────────────────────

/// Serve the DataStar JS bundle from the binary. Loaded via `include_str!`
/// at compile time so there's no runtime file lookup; the bundle lives at
/// `static/datastar.js` (v1.0.2, downloaded from jsDelivr).
async fn get_datastar_js() -> Response {
    (
        StatusCode::OK,
        [(header::CONTENT_TYPE, "application/javascript; charset=utf-8")],
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
    let history = fetch_history(&state, &channel, 25).await.unwrap_or_default();
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

// ── GET /chat/{channel}/events ──────────────────────────────────────────

async fn get_channel_events(
    State(state): State<AppState>,
    Path(channel): Path<String>,
    req: axum::http::HeaderMap,
) -> Response {
    let (sid, _is_new) = session_id_from_request(&req);
    let session = state.session(&sid);

    // Prevent duplicate SSE connections from the same session.
    // DataStar v1.0 sometimes opens two connections to the same
    // endpoint (timing quirk with data-init on the root element);
    // rejecting the second one with 409 keeps a single stream alive.
    if session.sse_active.compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst).is_err() {
        debug!(session = %sid, channel = %channel, "SSE duplicate — sending close");
        let stream = async_stream::stream! {
            yield Ok::<Event, std::convert::Infallible>(Event::default().comment("duplicate"));
        };
        return Sse::new(stream).into_response();
    }
    debug!(session = %sid, channel = %channel, "SSE subscriber connected");

    let upstream = state.upstream.clone();

    // Subscribe BEFORE we (possibly) spawn the WS task — otherwise
    // messages that arrive during the WS handshake would be lost.
    let mut lines_rx = session.lines_tx.subscribe();

    spawn_upstream_if_needed(&sid, &session, upstream.clone(), &channel);

    // Reset sse_active on disconnect so a future reconnect works.
    // SseGuard resets the flag when the stream is dropped (HTTP close).
    let stream = async_stream::stream! {
        // Move guard into stream so it lives as long as the SSE
        // connection. Dropped when axum aborts the stream on
        // HTTP disconnect — resets sse_active for reconnects.
        let _guard = SseGuard { session: session.clone() };
        let status_patch = PatchSignals::new(r#"{"_s":"connected"}"#);
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
                    // --- live member tracking (JOIN/PART/QUIT/MODE) ---
                    // Only events for *this* channel mutate the panel; QUIT has
                    // no channel and is applied to the current view. We render
                    // only when membership actually changed to avoid spurious
                    // patches (e.g. a QUIT from someone not in this channel).
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
                    }
                    // --- messages ---
                    if should_emit(&line) {
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

    debug!(session = %sid, channel = %target, len = msg.len(), "send requested");
    trace!(session = %sid, channel = %target, msg = %msg, "send message text");

    let irc_tx = session.irc_tx.lock().clone();
    if let Err(e) = irc_tx
        .send(format!("PRIVMSG {target} :{msg}\r\n"))
        .await
    {
        warn!(session = %sid, "send to upstream failed: {e}");
        return (StatusCode::SERVICE_UNAVAILABLE, "upstream WS gone").into_response();
    }

    debug!(session = %sid, channel = %target, "PRIVMSG queued to upstream; echoing to DOM");

    // Echo the sent message back to the DOM immediately. The IRC
    // server doesn't reflect a PRIVMSG back to its sender, so the
    // long-lived /events SSE never receives this line.
    let ts = Utc::now().format("%H:%M:%S").to_string();
    let safe = html_escape(&msg);
    let echo_html = format!(r#"<div class="msg"><span class="ts">{ts}</span><span class="body"><span class="nick c1">you</span> {safe}</span></div>"#);
    let echo = PatchElements::new(echo_html).selector("#messages").mode(ElementPatchMode::Append);
    let echo_event = echo.write_as_axum_sse_event();
    let clear = PatchSignals::new(r#"{"msg":""}"#);
    let clear_event = clear.write_as_axum_sse_event();
    let scroll = ExecuteScript::new("document.getElementById('messages').scrollTop = 999999");
    let scroll_event = scroll.write_as_axum_sse_event();
    Sse::new(async_stream::stream! {
        yield Ok::<Event, std::convert::Infallible>(echo_event);
        yield Ok::<Event, std::convert::Infallible>(scroll_event);
        yield Ok::<Event, std::convert::Infallible>(clear_event);
    }).into_response()
}

// ── POST /chat/{channel}/join and /part ─────────────────────────────────

/// Send `JOIN {channel}` over the upstream WS. The DataStar join form
/// posts `{channel: "#new"}` to `/chat/_new/join`; we route the
/// `_new` literal through and use the form's `channel` signal.
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
    if let Err(e) = irc_tx
        .send(format!("JOIN {target}\r\n"))
        .await
    {
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
    }).into_response()
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
    let _ = irc_tx
        .send(format!("PART {target}\r\n"))
        .await;
    let evt = ExecuteScript::new("window.location='/chat/general'");
    let event = evt.write_as_axum_sse_event();
    Sse::new(async_stream::stream! {
        yield Ok::<Event, std::convert::Infallible>(event);
    }).into_response()
}

// ── GET /api/channels (proxied from upstream) ──────────────────────────

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
            (
                status,
                [(header::CONTENT_TYPE, "application/json")],
                body,
            )
                .into_response()
        }
        Err(e) => (StatusCode::BAD_GATEWAY, format!("upstream: {e}")).into_response(),
    }
}

// ── IRC line formatting ─────────────────────────────────────────────────

/// Decide which inbound IRC lines the browser should see.
fn should_emit(line: &str) -> bool {
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
    true
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
                let safe_text = html_escape(text);
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
    Join { channel: String, nick: String },
    Part { channel: String, nick: String },
    Quit { nick: String },
    /// `(mode_char, adding, target_nick)` — only `o`/`h`/`v` affect display.
    Mode { channel: String, ops: Vec<(char, bool, String)> },
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
    let Some(rest) = line.strip_prefix(':') else { return false };
    let Some(sp) = rest.find(' ') else { return false };
    rest[sp + 1..].starts_with("353 ")
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
                .take_while(|c| matches!(*c, '@' | '%' | '+' | '~' | '&'))
                .count();
            // Prefix chars are ASCII, so char count == byte count; safe for split_at.
            let (prefixes, nick) = token.split_at(pfx_len);
            MemberEntry {
                nick: nick.to_string(),
                op: prefixes.contains('@') || prefixes.contains('~') || prefixes.contains('&'),
                halfop: prefixes.contains('%'),
                voiced: prefixes.contains('+'),
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
    const CLASSES: &[&str] = &["c1", "c2", "c3", "c4", "c5", "c6", "c7", "c8"];
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
        assert_eq!(render_member_list(&map), r#"<div class="member empty">—</div>"#);
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
}

/// RAII guard that resets `sse_active` when dropped.
/// Used so the SSE duplicate check recovers after the browser
/// closes (or refreshes) the EventSource.
struct SseGuard {
    session: std::sync::Arc<state::SessionHandle>,
}

impl Drop for SseGuard {
    fn drop(&mut self) {
        self.session.sse_active.store(false, Ordering::SeqCst);
        tracing::debug!("SSE guard dropped — sse_active reset");
    }
}
