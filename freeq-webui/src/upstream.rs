//! Upstream WS bridge + REST client + IRC line formatting.
//!
//! The WS bridge (`run_upstream_ws`) owns the upstream connection for
//! the lifetime of the spawned task. It reads from the upstream socket
//! and broadcasts every line into the per-session `lines_tx`. It also
//! reads from the per-session `irc_rx` and forwards each command to
//! the upstream socket. When either side fails or closes, the task
//! exits — the next SSE reconnect will respawn it.

use std::sync::Arc;

use anyhow::{Context, Result};
use futures_util::{SinkExt, StreamExt};
use serde::{Deserialize, Deserializer, Serialize};
use tokio::sync::{broadcast, mpsc};
use tokio_tungstenite::tungstenite::Message as WsMessage;
use tracing::{debug, error, info, warn};
use url::Url;

use crate::state::{AppState, SessionHandle, Upstream};

/// Matches a single entry in `GET /api/v1/channels` on the upstream
/// freeq-server. The upstream returns `topic: null` for channels
/// without a topic, which we convert to an empty string so Tera
/// can render it directly (Tera 2 can't auto-serialize
/// `Option<String>` for output).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UpstreamChannel {
    pub name: String,
    pub members: u64,
    #[serde(default, deserialize_with = "null_to_empty_string")]
    pub topic: String,
}

/// serde helper: convert a JSON `null` into an empty `String`.
fn null_to_empty_string<'de, D: Deserializer<'de>>(d: D) -> Result<String, D::Error> {
    Ok(Option::<String>::deserialize(d)?.unwrap_or_default())
}

/// A single message row from `GET /api/v1/channels/{name}/history`.
/// Only fields we render in the initial server-side scrollback.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UpstreamHistoryMessage {
    pub sender: String,
    pub text: String,
    pub timestamp: i64,
}

/// Fetch recent history for a channel from the upstream REST API.
pub async fn fetch_history(
    state: &AppState,
    channel: &str,
    limit: usize,
) -> Result<Vec<UpstreamHistoryMessage>> {
    let path = format!("api/v1/channels/{}/history?limit={}", channel.trim_start_matches('#'), limit);
    let url = state.upstream.base.join(&path).context("upstream history URL invalid")?;
    let resp = state.http.get(url).send().await?;
    if !resp.status().is_success() {
        anyhow::bail!("upstream returned {}", resp.status());
    }
    let msgs: Vec<UpstreamHistoryMessage> = resp.json().await?;
    Ok(msgs)
}

/// Spawn the upstream WS task if this is the first SSE subscriber for
/// the session, or if the previous WS task has died (connection drop,
/// upstream restart). If the task is already running, just ensure we've
/// JOINed the channel.
///
/// The `ws_task` Mutex is held for the entire check-and-spawn to prevent
/// two concurrent SSE subscribers from racing into a double-spawn.
pub fn spawn_upstream_if_needed(
    sid: &str,
    session: &Arc<SessionHandle>,
    upstream: Arc<Upstream>,
    channel: &str,
) {
    let target = super::canonical_channel(channel);

    let mut task_guard = session.ws_task.lock();

    let needs_spawn = match &*task_guard {
        Some(handle) => handle.is_finished(),
        None => true,
    };

    if !needs_spawn {
        debug!(session = %sid, channel = %target, "WS task already running");
        drop(task_guard);
        let already = session.joined.lock().contains(&target);
        if !already {
            session.joined.lock().insert(target.clone());
            let tx = session.irc_tx.lock().clone();
            let _ = tx.try_send(format!("JOIN {target}\r\n"));
            debug!(session = %sid, channel = %target, "WS task running; JOINing new channel");
        } else {
            // Reconnecting to same channel — request NAMES to repopulate
            // the member panel (353 reply seeds the list).
            let tx = session.irc_tx.lock().clone();
            let _ = tx.try_send(format!("NAMES {target}\r\n"));
            debug!(session = %sid, channel = %target, "WS task running; requesting NAMES");
        }
        return;
    }

    // WS task is None or finished — (re)spawn.
    // If the previous WS task died, irc_rx was dropped with it; create
    // a fresh channel so POST handlers and the new WS task are paired.
    let irc_rx = match session.irc_rx_slot.lock().take() {
        Some(rx) => rx,
        None => {
            debug!(session = %sid, "previous WS task died; creating new irc channel");
            let (tx, rx) = mpsc::channel::<String>(256);
            *session.irc_tx.lock() = tx;
            rx
        }
    };

    // Track the current channel as joined.
    session.joined.lock().insert(target.clone());

    // Re-JOIN any other channels the session had before the WS died.
    // The initial channel is joined by run_upstream_ws; others are queued
    // and sent once the new WS task enters its select loop.
    let rejoin: Vec<String> = session
        .joined
        .lock()
        .iter()
        .filter(|c| *c != &target)
        .cloned()
        .collect();
    if !rejoin.is_empty() {
        let tx = session.irc_tx.lock().clone();
        for ch in &rejoin {
            let _ = tx.try_send(format!("JOIN {ch}\r\n"));
        }
        debug!(session = %sid, count = rejoin.len(), "re-JOINing channels from previous session");
    }

    debug!(session = %sid, channel = %target, "spawning upstream WS task");

    let lines_tx = session.lines_tx.clone();
    let ws_url = upstream.ws.clone();
    let session_id = sid.to_string();
    let target_for_task = target.clone();

    *task_guard = Some(tokio::spawn(async move {
        info!(
            session = %session_id,
            ws = %ws_url,
            channel = %target_for_task,
            "connecting to upstream /irc"
        );
        if let Err(e) = run_upstream_ws(ws_url, lines_tx, irc_rx, target_for_task).await {
            error!(session = %session_id, "upstream WS error: {e:#}");
        } else {
            info!(session = %session_id, "upstream WS closed cleanly");
        }
    }));

    // task_guard dropped here — lock released.
}

/// One-shot WS bridge to the upstream. Owns the upstream connection for
/// the lifetime of this task; on any error, exits.
pub async fn run_upstream_ws(
    ws_url: Url,
    lines_tx: broadcast::Sender<String>,
    mut irc_rx: mpsc::Receiver<String>,
    channel: String,
) -> Result<()> {
    use futures_util::stream::SplitStream;

    let (mut ws, _resp) = tokio_tungstenite::connect_async(ws_url.as_str())
        .await
        .context("WS connect failed")?;

    let nick = format!("webui{:x}", rand::random::<u32>());
    debug!(%nick, "upstream IRC registration");
    ws.send(WsMessage::Text(format!("NICK {nick}\r\n").into()))
        .await?;
    ws.send(WsMessage::Text("USER webui 0 * :freeq-webui\r\n".into()))
        .await?;
    ws.send(WsMessage::Text(format!("JOIN {channel}\r\n").into()))
        .await?;
    ws.send(WsMessage::Text(format!("NAMES {channel}\r\n").into()))
        .await?;
    let (mut write, mut read): (futures_util::stream::SplitSink<_, WsMessage>, SplitStream<_>) = ws.split();

    loop {
        tokio::select! {
            Some(cmd) = irc_rx.recv() => {
                debug!(dir = ">>", line = %cmd.trim_end_matches(['\r', '\n']), "upstream IRC");
                if let Err(e) = write.send(WsMessage::Text(cmd.into())).await {
                    warn!("WS write failed: {e}");
                    break;
                }
            }
            msg = read.next() => {
                match msg {
                    Some(Ok(WsMessage::Text(t))) => {
                        let line = t.to_string();
                        let trimmed = line.trim_end_matches(['\r', '\n']);
                        debug!(dir = "<<", line = %trimmed, "upstream IRC");
                        // freeq-server sends PING with a server prefix
                        // (":irc.freeq.at PING irc.freeq.at"); `ping_token`
                        // handles both that and the bare "PING :token" form.
                        // Replying PONG is mandatory — without it the server's
                        // PING timeout closes the connection after ~30s.
                        if let Some(token) = ping_token(trimmed) {
                            debug!(token = %token, "PING received; replying PONG");
                            let pong = format!("PONG {token}\r\n");
                            if let Err(e) = write.send(WsMessage::Text(pong.into())).await {
                                warn!("WS write failed on PONG: {e}");
                                break;
                            }
                            continue;
                        }
                        let _ = lines_tx.send(line);
                    }
                    Some(Ok(WsMessage::Binary(_))) => {}
                    Some(Ok(WsMessage::Close(_))) | None => break,
                    Some(Ok(WsMessage::Ping(_) | WsMessage::Pong(_))) => continue,
                    Some(Ok(_)) => continue,
                    Some(Err(e)) => {
                        warn!("WS read error: {e}");
                        break;
                    }
                }
            }
        }
    }
    Ok(())
}

/// Extract the token to echo back in `PONG` from a server `PING` line,
/// handling both the prefixed form (`:irc.freeq.at PING irc.freeq.at`,
/// which is what freeq-server sends) and the bare form (`PING :token`).
/// Returns `None` if the line is not a PING.
fn ping_token(line: &str) -> Option<&str> {
    let line = line.trim_end_matches(['\r', '\n']);
    // Drop an optional ":prefix " server origin.
    let body = match line.strip_prefix(':') {
        Some(s) => s.split_once(' ').map(|(_, rest)| rest).unwrap_or(s),
        None => line,
    };
    body.strip_prefix("PING ").map(|t| t.trim_end())
}

/// Fetch the upstream channel list. Returns an empty list on any error.
pub async fn fetch_channels(state: &AppState) -> Result<Vec<UpstreamChannel>> {
    let url = state
        .upstream
        .base
        .join("api/v1/channels")
        .context("upstream URL invalid")?;
    let resp = state.http.get(url).send().await?;
    if !resp.status().is_success() {
        anyhow::bail!("upstream returned {}", resp.status());
    }
    let channels: Vec<UpstreamChannel> = resp.json().await?;
    Ok(channels)
}

#[cfg(test)]
mod tests {
    use super::ping_token;

    #[test]
    fn ping_token_prefixed_server_form() {
        // freeq-server sends ":irc.freeq.at PING irc.freeq.at".
        assert_eq!(ping_token(":irc.freeq.at PING irc.freeq.at"), Some("irc.freeq.at"));
        // Trailing CRLF must be stripped.
        assert_eq!(ping_token(":irc.freeq.at PING irc.freeq.at\r\n"), Some("irc.freeq.at"));
    }

    #[test]
    fn ping_token_bare_form() {
        assert_eq!(ping_token("PING :irc.freeq.at"), Some(":irc.freeq.at"));
        assert_eq!(ping_token("PING 12345"), Some("12345"));
    }

    #[test]
    fn ping_token_not_a_ping() {
        assert_eq!(ping_token(":irc.freeq.at 001 me :Welcome"), None);
        assert_eq!(ping_token("PRIVMSG #general :hi"), None);
        // A PRIVMSG whose text happens to start with "PING " must NOT match.
        assert_eq!(ping_token(":nick!u@h PRIVMSG #general :PING me"), None);
    }
}
