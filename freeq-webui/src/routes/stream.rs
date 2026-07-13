//! Plain SSE stream of upstream IRC lines for a single channel.

use std::convert::Infallible;

use axum::extract::{Path, State};
use axum::http::{header, HeaderMap};
use axum::response::sse::{Event, Sse};
use axum::response::{IntoResponse, Response};
use futures_util::Stream;
use tracing::debug;

use crate::helpers::{canonical_channel, session_id_from_request};
use crate::irc::extract_irc_target;
use crate::state::AppState;

pub async fn get_channel_stream(
    State(state): State<AppState>,
    Path(channel): Path<String>,
    headers: HeaderMap,
) -> Response {
    let (sid, _is_new) = session_id_from_request(&headers);
    let session = state.session(&sid);
    let target = canonical_channel(&channel);

    crate::upstream::spawn_upstream_if_needed(
        &state,
        &sid,
        &session,
        std::sync::Arc::clone(&state.upstream),
        &target,
    );

    let lines_tx = session.lines_tx.clone();
    let sid_for_log = sid.clone();
    let target_for_stream = target.clone();
    let stream = async_stream::stream! {
        let mut rx = lines_tx.subscribe();
        loop {
            match rx.recv().await {
                Ok(line) => {
                    if !line_relevant(&line, &target_for_stream) {
                        continue;
                    }
                    yield Ok::<Event, Infallible>(
                        Event::default().event("line").data(line)
                    );
                }
                Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => {
                    debug!(session = %sid_for_log, lagged = n, "SSE subscriber lagged");
                    continue;
                }
                Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
            }
        }
    };

    let sse: Sse<Pin<Box<dyn Stream<Item = Result<Event, Infallible>> + Send>>> = {
        let boxed: std::pin::Pin<Box<dyn Stream<Item = Result<Event, Infallible>> + Send>> =
            Box::pin(stream);
        Sse::new(boxed)
    };

    let mut resp = sse.into_response();
    resp.headers_mut().insert(
        header::CACHE_CONTROL,
        "no-cache, no-store, must-revalidate".parse().unwrap(),
    );
    resp
}

fn line_relevant(line: &str, target: &str) -> bool {
    let line = line.trim_end_matches(['\r', '\n']);
    if line.is_empty() {
        return false;
    }
    let after_tags = crate::irc::parse_irc_tags(line).1;
    let Some(rest) = after_tags.strip_prefix(':') else {
        return true;
    };
    let Some(sp) = rest.find(' ') else {
        return true;
    };
    let after_prefix = &rest[sp + 1..];
    if let Some(t) = extract_irc_target(after_prefix) {
        t.eq_ignore_ascii_case(target)
    } else {
        true
    }
}

use std::pin::Pin;
