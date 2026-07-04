//! Upstream WS bridge + REST client.

use std::sync::Arc;

use anyhow::{Context, Result};
use futures_util::{SinkExt, StreamExt};
use serde::{Deserialize, Serialize};
use tokio::sync::{broadcast, mpsc};
use tokio_tungstenite::tungstenite::Message as WsMessage;
use tracing::{debug, error, info, warn};
use url::Url;

use crate::state::{AppState, AuthState, SessionHandle, Upstream};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UpstreamChannel {
    pub name: String,
    #[serde(default, deserialize_with = "null_to_empty_string")]
    pub topic: String,
    #[serde(default)]
    pub members: u32,
}

fn null_to_empty_string<'de, D: serde::Deserializer<'de>>(d: D) -> Result<String, D::Error> {
    Ok(Option::<String>::deserialize(d)?.unwrap_or_default())
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UpstreamHistoryMessage {
    pub sender: String,
    pub text: String,
    pub timestamp: i64,
}

pub async fn fetch_history(state: &AppState, channel: &str, limit: usize) -> Result<Vec<UpstreamHistoryMessage>> {
    let encoded = channel.replace('#', "%23");
    let url = state.upstream.base.join(&format!("api/v1/channels/{encoded}/history?limit={limit}"))?;
    Ok(state.http.get(url).send().await?.json().await?)
}

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
            debug!(session = %sid, channel = %target, "JOINing new channel");
        } else {
            let tx = session.irc_tx.lock().clone();
            let _ = tx.try_send(format!("NAMES {target}\r\n"));
            debug!(session = %sid, channel = %target, "requesting NAMES");
        }
        // Check for pending login: send LOGIN if in LoggingIn state
        let login_handle = {
            let auth = session.auth.lock();
            match &*auth {
                AuthState::LoggingIn { handle } => Some(handle.clone()),
                AuthState::AwaitingOAuth { handle, .. } => Some(handle.clone()),
                _ => None,
            }
        };
        if let Some(handle) = login_handle {
            let tx = session.irc_tx.lock().clone();
            let _ = tx.try_send(format!("LOGIN {handle}\r\n"));
            info!(session = %sid, handle = %handle, "sending LOGIN over existing WS");
        }
        return;
    }

    let irc_rx = session.irc_rx_slot.lock().take();
    let irc_rx = match irc_rx {
        Some(rx) => rx,
        None => {
            drop(irc_rx); // release the lock guard
            let (tx, rx) = tokio::sync::mpsc::channel(256);
            *session.irc_tx.lock() = tx;
            *session.irc_rx_slot.lock() = Some(rx);
            session.irc_rx_slot.lock().take().expect("new channel")
        }
    };

    session.joined.lock().insert(target.clone());

    let rejoin: Vec<String> = session.joined.lock().iter()
        .filter(|c| *c != &target).cloned().collect();
    if !rejoin.is_empty() {
        let tx = session.irc_tx.lock().clone();
        for ch in &rejoin {
            let _ = tx.try_send(format!("JOIN {ch}\r\n"));
        }
        debug!(session = %sid, count = rejoin.len(), "re-JOINing channels");
    }

    debug!(session = %sid, channel = %target, "spawning upstream WS task");

    let lines_tx = session.lines_tx.clone();
    let ws_url = upstream.ws.clone();
    let session_id = sid.to_string();
    let target_for_task = target.clone();

    // Get the login handle from auth state
    let pending_login = session.auth.lock().handle().map(|h| h.to_string());
    *task_guard = Some(tokio::spawn(async move {
        info!(session = %session_id, ws = %ws_url, channel = %target_for_task, "connecting to upstream /irc");
        let result = run_upstream_ws(ws_url, lines_tx, irc_rx, target_for_task, pending_login).await;
        if let Err(e) = result {
            error!(session = %session_id, "upstream WS error: {e:#}");
        } else {
            info!(session = %session_id, "upstream WS closed cleanly");
        }
    }));
}

pub async fn run_upstream_ws(
    ws_url: Url,
    lines_tx: broadcast::Sender<String>,
    mut irc_rx: mpsc::Receiver<String>,
    channel: String,
    pending_login: Option<String>,
) -> Result<()> {
    use futures_util::stream::SplitStream;

    let (mut ws, _resp) = tokio_tungstenite::connect_async(ws_url.as_str())
        .await.context("WS connect failed")?;

    let nick = if let Some(ref handle) = pending_login {
        super::sanitize_nick(handle)
    } else {
        format!("webui{:x}", rand::random::<u32>())
    };
    debug!(%nick, "upstream IRC registration");
    ws.send(WsMessage::Text(format!("NICK {nick}\r\n").into())).await?;
    ws.send(WsMessage::Text("USER webui 0 * :freeq-webui\r\n".into())).await?;

    // IRCv3 capability negotiation: request account-notify to learn real DID
    ws.send(WsMessage::Text("CAP LS 302\r\n".into())).await?;
    ws.send(WsMessage::Text("CAP REQ :account-notify\r\n".into())).await?;
    ws.send(WsMessage::Text("CAP END\r\n".into())).await?;

    // Send LOGIN if there's a pending handle
    if let Some(ref handle) = pending_login {
        ws.send(WsMessage::Text(format!("LOGIN {handle}\r\n").into())).await?;
        info!(%handle, "sent LOGIN during WS registration");
    }

    ws.send(WsMessage::Text(format!("JOIN {channel}\r\n").into())).await?;

    let (mut write, mut read): (futures_util::stream::SplitSink<_, WsMessage>, SplitStream<_>) = ws.split();

    loop {
        tokio::select! {
            Some(cmd) = irc_rx.recv() => {
                debug!(dir = ">>", line = %cmd.trim_end_matches(['\r', '\n']), "upstream IRC");
                if let Err(e) = write.send(WsMessage::Text(cmd.into())).await {
                    warn!("WS write failed: {e}"); break;
                }
            }
            msg = read.next() => {
                match msg {
                    Some(Ok(WsMessage::Text(t))) => {
                        let line = t.to_string();
                        let trimmed = line.trim_end_matches(['\r', '\n']);
                        debug!(dir = "<<", line = %trimmed, "upstream IRC");
                        if let Some(token) = ping_token(trimmed) {
                            let pong = format!("PONG {token}\r\n");
                            if let Err(e) = write.send(WsMessage::Text(pong.into())).await {
                                warn!("WS write failed on PONG: {e}"); break;
                            }
                            continue;
                        }
                        // Retry with a random nick on 433 (Nickname in use)
                        if trimmed.contains(" 433 ") {
                            let fallback = format!("webui{:x}", rand::random::<u32>());
                            let _ = write.send(WsMessage::Text(format!("NICK {fallback}\r\n").into())).await;
                            info!("433 received; retrying NICK as {fallback}");
                        }
                        // Re-send LOGIN after registration completes (if nick was changed)
                        if trimmed.contains(" 001 ") {
                            if let Some(ref handle) = pending_login {
                                let _ = write.send(WsMessage::Text(format!("LOGIN {handle}\r\n").into())).await;
                                info!("001 received; re-sending LOGIN as {handle}");
                            }
                        }
                        let _ = lines_tx.send(line);
                    }
                    Some(Ok(WsMessage::Binary(_))) => {}
                    Some(Ok(WsMessage::Close(_))) | None => break,
                    Some(Ok(WsMessage::Ping(_) | WsMessage::Pong(_))) => continue,
                    Some(Ok(_)) => continue,
                    Some(Err(e)) => { warn!("WS read error: {e}"); break; }
                }
            }
        }
    }
    Ok(())
}

fn ping_token(line: &str) -> Option<&str> {
    let line = line.trim_end_matches(['\r', '\n']);
    if let Some(rest) = line.strip_prefix(':') {
        if let Some(sp) = rest.find(' ') {
            if &rest[..sp] == "PING" { return None; }
            let after = &rest[sp + 1..];
            if after.starts_with("PING ") {
                return Some(after.strip_prefix("PING ").unwrap_or(""));
            }
        }
    }
    if let Some(token) = line.strip_prefix("PING ") {
        return Some(token.trim_start_matches(':'));
    }
    None
}

pub async fn fetch_channels(state: &AppState) -> Result<Vec<UpstreamChannel>> {
    let url = state.upstream.base.join("api/v1/channels")?;
    Ok(state.http.get(url).send().await?.json().await?)
}
