//! SSE stream of live IRC events for a channel.

use bytes::Bytes;
use chrono::Utc;
use futures_util::StreamExt;
use http_body::Frame;
use http_body_util::StreamBody;
use topcoat::Result;
use topcoat::context::Cx;
use topcoat::router::{Body, IntoResponse, Response, path_param, route};
use tracing::debug;

use crate::app::state;
use crate::irc_render::{
    MemberChange, canonical_channel, is_353, line_msgid, parse_333_did, parse_account_did,
    parse_batch_line, parse_channel_error, parse_member_change, parse_tagmsg_reaction,
    parse_topic_change, parse_whois_line, render_irc_line, render_member_list, should_emit,
};
use crate::session_util::ensure_session_id;
use crate::state::{AuthState, MemberEntry};
use crate::upstream::spawn_upstream_if_needed;

#[path_param]
struct Channel(str);

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

#[route(GET "/chat/{channel}/events")]
async fn channel_events(cx: &Cx) -> Result<SseResponse> {
    let raw = path_param::<Channel>(cx);
    let channel = canonical_channel(&raw);
    let app = state(cx);
    let sid = ensure_session_id(cx);
    let session = app.session(&sid);

    debug!(session = %sid, channel = %channel, "SSE subscriber connected");

    let mut lines_rx = session.lines_tx.subscribe();
    spawn_upstream_if_needed(&app, &sid, &session, app.upstream.clone(), &channel);

    let stream = async_stream::stream! {
        yield Ok::<_, Box<dyn std::error::Error + Send + Sync>>(Frame::data(sse_frame(
            "status",
            r#""connected""#,
        )));

        // Open chathistory batch ids — suppress message pane for those
        // (scrollback already came from REST on page load).
        let mut suppress_history_batches: std::collections::HashSet<String> =
            std::collections::HashSet::new();

        loop {
            match lines_rx.recv().await {
                Ok(line) => {
                    let canon = channel.clone();

                    // Track IRCv3 BATCH so JOIN history is not re-appended.
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

                    if is_353(&line) {
                        let entries = crate::irc_render::parse_353_members(&line);
                        let member_html = {
                            let mut members = session.channel_members.lock();
                            let map = members.entry(canon.clone()).or_default();
                            for e in &entries {
                                map.insert(e.nick.clone(), e.clone());
                            }
                            render_member_list(map)
                        };
                        yield Ok(Frame::data(sse_frame("members", &member_html)));
                        continue;
                    }

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

                    if let Some(new_topic) = parse_topic_change(&line, &canon) {
                        let payload = serde_json::to_string(&new_topic).unwrap_or_else(|_| "\"\"".into());
                        yield Ok(Frame::data(sse_frame("topic", &payload)));
                    }

                    if let Some(err_text) = parse_channel_error(&line, &canon) {
                        let ts = Utc::now().format("%H:%M:%S").to_string();
                        let safe = crate::irc_render::html_escape(err_text);
                        let html = format!(
                            r#"<div class="notice"><span class="ts">{ts}</span><span class="body">{safe}</span></div>"#
                        );
                        yield Ok(Frame::data(sse_frame("message", &html)));
                    }

                    if let Some(whois_text) = parse_whois_line(&line) {
                        let ts = Utc::now().format("%H:%M:%S").to_string();
                        let safe = crate::irc_render::html_escape(&whois_text);
                        let html = format!(
                            r#"<div class="notice"><span class="ts">{ts}</span><span class="body">{safe}</span></div>"#
                        );
                        yield Ok(Frame::data(sse_frame("message", &html)));
                    }

                    if let Some(change) = parse_member_change(&line) {
                        let member_html: Option<String> = {
                            let mut members = session.channel_members.lock();
                            let map = members.entry(canon.clone()).or_default();
                            match change {
                                MemberChange::Join { channel: ch, nick }
                                    if ch.eq_ignore_ascii_case(&canon) =>
                                {
                                    map.entry(nick.clone()).or_insert_with(|| MemberEntry {
                                        nick,
                                        ..Default::default()
                                    });
                                    Some(render_member_list(map))
                                }
                                MemberChange::Part { channel: ch, nick }
                                    if ch.eq_ignore_ascii_case(&canon) =>
                                {
                                    map.remove(&nick);
                                    Some(render_member_list(map))
                                }
                                MemberChange::Quit { nick } => {
                                    map.remove(&nick);
                                    Some(render_member_list(map))
                                }
                                MemberChange::Mode { channel: ch, ops }
                                    if ch.eq_ignore_ascii_case(&canon) =>
                                {
                                    for (mode_char, adding, target) in ops {
                                        let entry = map.entry(target.clone()).or_insert_with(|| {
                                            MemberEntry {
                                                nick: target.clone(),
                                                ..Default::default()
                                            }
                                        });
                                        match mode_char {
                                            'o' => entry.op = adding,
                                            'h' => entry.halfop = adding,
                                            'v' => entry.voiced = adding,
                                            _ => {}
                                        }
                                    }
                                    Some(render_member_list(map))
                                }
                                _ => None,
                            }
                        };
                        if let Some(html) = member_html {
                            yield Ok(Frame::data(sse_frame("members", &html)));
                        }
                    }

                    // Live reactions (TAGMSG +react) — update chips via SSE.
                    if let Some((msgid, emoji, nick, added, ch)) = parse_tagmsg_reaction(&line) {
                        if ch.eq_ignore_ascii_case(&canon) {
                            let payload = serde_json::json!({
                                "msgid": msgid,
                                "emoji": emoji,
                                "nick": nick,
                                "added": added,
                            });
                            yield Ok(Frame::data(sse_frame(
                                "reaction",
                                &payload.to_string(),
                            )));
                        }
                        continue;
                    }

                    // While a chathistory batch is open, skip message pane updates.
                    // NAMES / members / topic still handled above.
                    if !suppress_history_batches.is_empty() {
                        // Also mark msgids so late unbatched dupes are skipped.
                        if let Some(mid) = line_msgid(&line) {
                            let _ = session.check_and_mark_msgid(&mid);
                        }
                        continue;
                    }

                    if should_emit(&line, &canon) {
                        // Dedup SSR history vs JOIN replay by msgid when present.
                        if let Some(mid) = line_msgid(&line) {
                            if session.check_and_mark_msgid(&mid) {
                                continue;
                            }
                        }
                        let html = render_irc_line(&line);
                        if !html.is_empty() {
                            yield Ok(Frame::data(sse_frame("message", &html)));
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
