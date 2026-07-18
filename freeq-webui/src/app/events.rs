//! Session-scoped SSE stream of live IRC events.
//!
//! One EventSource per browser tab subscribes here. Events include a
//! `channel` field so the client can filter by the currently-viewed channel.
//! Channel switching is done client-side via pushState — no new SSE connection
//! is opened on navigation.

use bytes::Bytes;
use chrono::Utc;
use futures_util::StreamExt;
use http_body::Frame;
use http_body_util::StreamBody;
use topcoat::Result;
use topcoat::context::Cx;
use topcoat::router::{Body, IntoResponse, Response, route};
use tracing::debug;

use crate::app::state;
use crate::irc_render::{
    EmitInfo, MemberChange, channel_key, is_353, line_msgid, nick_key, parse_333_did,
    parse_353_channel, parse_353_members, parse_account_did, parse_batch_line,
    parse_channel_error_any, parse_member_change, parse_tagmsg_reaction, parse_topic_any,
    parse_whois_line, render_irc_line, render_member_list, should_emit_any,
};
use crate::session_util::ensure_session_id;
use crate::state::{AuthState, MemberEntry};
use crate::upstream::spawn_upstream_if_needed;

struct SseResponse(Response);

impl IntoResponse for SseResponse {
    fn into_response(self, _cx: &Cx) -> Result<Response> {
        Ok(self.0)
    }
}

fn sse_frame(event: &str, data: &str) -> Bytes {
    // SSE data lines cannot contain raw newlines; fold multi-line HTML.
    let data = data.replace('\n', "").replace('\r', "");
    Bytes::from(format!("event: {event}\ndata: {data}\n\n"))
}

#[route(GET "/events")]
async fn session_events(cx: &Cx) -> Result<SseResponse> {
    let app = state(cx);
    let sid = ensure_session_id(cx);
    let session = app.session(&sid);

    debug!(session = %sid, "Session SSE connected");

    let mut lines_rx = session.lines_tx.subscribe();
    // Spawn upstream if needed. No specific channel — the WS task rejoins
    // all previously-joined channels on reconnect.
    spawn_upstream_if_needed(&app, &sid, &session, app.upstream.clone(), "");

    let stream = async_stream::stream! {
        yield Ok::<_, Box<dyn std::error::Error + Send + Sync>>(Frame::data(sse_frame(
            "status",
            r#"{"status":"connected"}"#,
        )));

        // Open chathistory batch ids — suppress message pane for those
        // (scrollback already came from REST on page load / channel switch).
        let mut suppress_history_batches: std::collections::HashSet<String> =
            std::collections::HashSet::new();

        loop {
            match lines_rx.recv().await {
                Ok(line) => {
                    // ── BATCH tracking ──────────────────────────────────
                    if let Some((batch_id, open, batch_type)) = parse_batch_line(&line) {
                        if open {
                            let is_hist = batch_type
                                .as_deref()
                                .is_some_and(|t| t.eq_ignore_ascii_case("chathistory"));
                            if is_hist {
                                suppress_history_batches.insert(batch_id);
                            }
                        } else {
                            suppress_history_batches.remove(&batch_id);
                        }
                        continue;
                    }

                    // ── 353 NAMES — update cache, emit members event ────
                    if is_353(&line) {
                        let entries = parse_353_members(&line);
                        let ch353 = parse_353_channel(&line).unwrap_or_default();
                        let key = channel_key(&ch353);
                        let member_html = {
                            let mut members = session.channel_members.lock();
                            let map = members.entry(key).or_default();
                            for e in &entries {
                                map.insert(nick_key(&e.nick), e.clone());
                            }
                            render_member_list(map)
                        };
                        let payload = serde_json::json!({
                            "channel": ch353,
                            "html": member_html,
                        });
                        yield Ok(Frame::data(sse_frame("members", &payload.to_string())));
                        continue;
                    }

                    // ── Account-notify (DID update) ────────────────────
                    if let Some(new_did) = parse_account_did(&line) {
                        *session.extracted_did.lock() = Some(new_did.clone());
                        let mut auth = session.auth.lock();
                        if let AuthState::Authenticated { did, .. } = &mut *auth {
                            *did = new_did;
                        }
                        continue;
                    }
                    if let Some(new_did) = parse_333_did(&line) {
                        *session.extracted_did.lock() = Some(new_did);
                        continue;
                    }

                    // ── Topic changes ──────────────────────────────────
                    if let Some((ch, topic)) = parse_topic_any(&line) {
                        let payload = serde_json::json!({
                            "channel": ch,
                            "topic": topic,
                        });
                        yield Ok(Frame::data(sse_frame("topic", &payload.to_string())));
                    }

                    // ── Channel errors (442/482) ───────────────────────
                    if let Some((ch, err_text)) = parse_channel_error_any(&line) {
                        let ts = Utc::now().format("%H:%M:%S").to_string();
                        let safe = crate::irc_render::html_escape(err_text);
                        let html = format!(
                            r#"<div class="notice"><span class="ts">{ts}</span><span class="body">{safe}</span></div>"#
                        );
                        let payload = serde_json::json!({
                            "channel": ch,
                            "html": html,
                        });
                        yield Ok(Frame::data(sse_frame("message", &payload.to_string())));
                    }

                    // ── WHOIS responses (session-wide, no channel) ──────
                    if let Some(whois_text) = parse_whois_line(&line) {
                        let ts = Utc::now().format("%H:%M:%S").to_string();
                        let safe = crate::irc_render::html_escape(&whois_text);
                        let html = format!(
                            r#"<div class="notice"><span class="ts">{ts}</span><span class="body">{safe}</span></div>"#
                        );
                        let payload = serde_json::json!({ "html": html });
                        yield Ok(Frame::data(sse_frame("message", &payload.to_string())));
                    }

                    // ── Member changes (JOIN/PART/QUIT/MODE) ────────────
                    if let Some(change) = parse_member_change(&line) {
                        match change {
                            MemberChange::Join { channel: ch, nick } => {
                                let key = channel_key(&ch);
                                let member_html = {
                                    let mut members = session.channel_members.lock();
                                    let map = members.entry(key.clone()).or_default();
                                    map.entry(nick_key(&nick)).or_insert_with(|| MemberEntry {
                                        nick,
                                        ..Default::default()
                                    });
                                    render_member_list(map)
                                };
                                let payload = serde_json::json!({
                                    "channel": ch,
                                    "html": member_html,
                                });
                                yield Ok(Frame::data(sse_frame("members", &payload.to_string())));
                            }
                            MemberChange::Part { channel: ch, nick } => {
                                let key = channel_key(&ch);
                                let member_html = {
                                    let mut members = session.channel_members.lock();
                                    if let Some(map) = members.get_mut(&key) {
                                        map.remove(&nick_key(&nick));
                                        Some(render_member_list(map))
                                    } else {
                                        None
                                    }
                                };
                                if let Some(html) = member_html {
                                    let payload = serde_json::json!({
                                        "channel": ch,
                                        "html": html,
                                    });
                                    yield Ok(Frame::data(sse_frame("members", &payload.to_string())));
                                }
                            }
                            MemberChange::Quit { nick } => {
                                // Remove from all channels; emit a members
                                // update for each channel that had the nick.
                                let updates = {
                                    let mut members = session.channel_members.lock();
                                    let nk = nick_key(&nick);
                                    let mut updates = Vec::new();
                                    for (key, map) in members.iter_mut() {
                                        if map.remove(&nk).is_some() {
                                            updates.push((key.clone(), render_member_list(map)));
                                        }
                                    }
                                    updates
                                };
                                for (key, html) in updates {
                                    let payload = serde_json::json!({
                                        "channel": key,
                                        "html": html,
                                    });
                                    yield Ok(Frame::data(sse_frame("members", &payload.to_string())));
                                }
                            }
                            MemberChange::Mode { channel: ch, ops } => {
                                let key = channel_key(&ch);
                                let member_html = {
                                    let mut members = session.channel_members.lock();
                                    let map = members.entry(key.clone()).or_default();
                                    for (mode_char, adding, target) in ops {
                                        let entry = map
                                            .entry(nick_key(&target))
                                            .or_insert_with(|| MemberEntry {
                                                nick: target.clone(),
                                                ..Default::default()
                                            });
                                        match mode_char {
                                            'o' => entry.op = adding,
                                            'h' => entry.halfop = adding,
                                            'v' => entry.voiced = adding,
                                            _ => {}
                                        }
                                    }
                                    render_member_list(map)
                                };
                                let payload = serde_json::json!({
                                    "channel": ch,
                                    "html": member_html,
                                });
                                yield Ok(Frame::data(sse_frame("members", &payload.to_string())));
                            }
                        }
                    }

                    // ── Reactions (TAGMSG +react) ───────────────────────
                    if let Some((msgid, emoji, nick, added, ch)) = parse_tagmsg_reaction(&line) {
                        let payload = serde_json::json!({
                            "channel": ch,
                            "msgid": msgid,
                            "emoji": emoji,
                            "nick": nick,
                            "added": added,
                        });
                        yield Ok(Frame::data(sse_frame("reaction", &payload.to_string())));
                        continue;
                    }

                    // ── Suppress chathistory batch messages ────────────
                    if !suppress_history_batches.is_empty() {
                        if let Some(mid) = line_msgid(&line) {
                            let _ = session.check_and_mark_msgid(&mid);
                        }
                        continue;
                    }

                    // ── Regular chat messages ──────────────────────────
                    match should_emit_any(&line) {
                        EmitInfo::Skip => {}
                        EmitInfo::Session => {
                            // Session-wide (QUIT, NICK, NOTICE to nick)
                            if let Some(mid) = line_msgid(&line) {
                                if session.check_and_mark_msgid(&mid) {
                                    continue;
                                }
                            }
                            let html = render_irc_line(&line);
                            if !html.is_empty() {
                                let payload = serde_json::json!({ "html": html });
                                yield Ok(Frame::data(sse_frame("message", &payload.to_string())));
                            }
                        }
                        EmitInfo::Channel(ch) => {
                            if let Some(mid) = line_msgid(&line) {
                                if session.check_and_mark_msgid(&mid) {
                                    continue;
                                }
                            }
                            let html = render_irc_line(&line);
                            if !html.is_empty() {
                                let payload = serde_json::json!({
                                    "channel": ch,
                                    "html": html,
                                });
                                yield Ok(Frame::data(sse_frame("message", &payload.to_string())));
                            }
                        }
                    }
                }
                Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
            }
        }
    };

    let body = Body::new(StreamBody::new(stream.map(|item| item)));
    let resp = Response::builder()
        .status(200)
        .header("Content-Type", "text/event-stream")
        .header("Cache-Control", "no-cache")
        .header("Connection", "keep-alive")
        .body(body)?;
    Ok(SseResponse(resp))
}
