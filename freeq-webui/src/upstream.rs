//! Upstream WS bridge + REST client.

use std::sync::Arc;

use anyhow::{Context, Result};
use base64::Engine;
use futures_util::{SinkExt, StreamExt};
use serde::{Deserialize, Serialize};
use tokio::sync::{broadcast, mpsc};
use tokio_tungstenite::tungstenite::Message as WsMessage;
use tracing::{debug, error, info, warn};
use url::Url;

use crate::state::{AppState, AuthState, SessionHandle, Upstream, WsState};

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

// ── AT Protocol OAuth-backed auth helpers ────────────────────────────────

/// Credentials we hand to the upstream WS task so it can run SASL.
pub struct AuthCredentials {
    pub did: String,
    pub nick: String,
    pub access_token: String,
    /// Refresh token for renewing the access token when it expires.
    pub refresh_token: Option<String>,
    /// Token endpoint URL for refresh requests.
    pub token_endpoint: String,
    /// OAuth client_id used during authorization.
    pub client_id: String,
    pub pds_url: String,
    /// DPoP key + nonce for proving possession of the access token.
    pub dpop_key: freeq_sdk::oauth::DpopKey,
    pub dpop_nonce: Option<String>,
}

pub async fn fetch_history(state: &AppState, channel: &str, limit: usize) -> Result<Vec<UpstreamHistoryMessage>> {
    let encoded = channel.replace('#', "%23");
    let url = state.upstream.base.join(&format!("api/v1/channels/{encoded}/history?limit={limit}"))?;
    Ok(state.http.get(url).send().await?.json().await?)
}

pub fn spawn_upstream_if_needed(
    _state: &AppState,
    sid: &str,
    session: &Arc<SessionHandle>,
    upstream: Arc<Upstream>,
    channel: &str,
) {
    let target = super::canonical_channel(channel);
    let was_ready = session.get_ws_state() == WsState::Ready;
    let mut task_guard = session.ws_task.lock();

    if let Some(handle) = task_guard.take() {
        if !handle.is_finished() {
            if was_ready {
                info!(session = %sid, "aborting upstream WS task for reconnect");
            }
            handle.abort();
        }
    }

    if !was_ready {
        if let Some(handle) = &*task_guard {
            if !handle.is_finished() {
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
                return;
            }
        }
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

    // Snapshot the user's OAuth session. The DPoP proof for SASL is built
    // inside the WS task so this function stays synchronous and no
    // parking_lot MutexGuards are held across await points.
    let auth = session.auth.lock().clone();
    let auth_creds = if let AuthState::Authenticated { did, nick, oauth, .. } = &auth {
        Some(AuthCredentials {
            did: did.clone(),
            nick: nick.clone(),
            access_token: oauth.access_token.clone(),
            refresh_token: oauth.refresh_token.clone(),
            token_endpoint: oauth.token_endpoint.clone(),
            client_id: oauth.client_id.clone(),
            pds_url: oauth.pds_url.clone(),
            dpop_key: oauth.dpop_key.clone(),
            dpop_nonce: oauth.dpop_nonce.clone(),
        })
    } else {
        None
    };

    debug!(session = %sid, channel = %target, authenticated = auth_creds.is_some(), "spawning upstream WS task");

    let lines_tx = session.lines_tx.clone();
    let ws_url = upstream.ws.clone();
    let session_id = sid.to_string();
    let target_for_task = target.clone();
    let session_for_task = Arc::clone(&session);

    *task_guard = Some(tokio::spawn(async move {
        session_for_task.set_ws_state(WsState::Connecting);
        debug!(session = %session_id, "ws_state → Connecting");
        info!(session = %session_id, ws = %ws_url, channel = %target_for_task, "connecting to upstream /irc");
        let result = run_upstream_ws(
            ws_url,
            lines_tx,
            irc_rx,
            target_for_task,
            auth_creds,
            session_for_task,
            session_id.clone(),
        ).await;
        if let Err(e) = result {
            error!(session = %session_id, "upstream WS error: {e:#}");
        } else {
            info!(session = %session_id, "upstream WS closed cleanly");
        }
    }));
}

/// Server-issued SASL challenge that we echo back as `challenge_nonce`.
#[derive(serde::Deserialize)]
struct Challenge {
    #[allow(dead_code)]
    session_id: String,
    nonce: String,
    #[allow(dead_code)]
    timestamp: i64,
}

pub async fn run_upstream_ws(
    ws_url: Url,
    lines_tx: broadcast::Sender<String>,
    mut irc_rx: mpsc::Receiver<String>,
    channel: String,
    auth: Option<AuthCredentials>,
    session: Arc<SessionHandle>,
    session_id: String,
) -> Result<()> {
    use futures_util::stream::SplitStream;

    let (mut ws, _resp) = tokio_tungstenite::connect_async(ws_url.as_str())
        .await.context("WS connect failed")?;
    session.set_ws_state(WsState::Registering);
    debug!(session = %session_id, "ws_state → Registering");

    let nick = auth
        .as_ref()
        .map(|a| super::sanitize_nick(&a.nick))
        .unwrap_or_else(|| format!("webui{:x}", rand::random::<u32>()));
    debug!(session = %session_id, %nick, authenticated = auth.is_some(), "upstream IRC registration");
    ws.send(WsMessage::Text(format!("NICK {nick}\r\n").into())).await?;
    ws.send(WsMessage::Text("USER webui 0 * :freeq-webui\r\n".into())).await?;

    // IRCv3 capability negotiation: request SASL and account-notify.
    ws.send(WsMessage::Text("CAP LS 302\r\n".into())).await?;
    ws.send(WsMessage::Text("CAP REQ :sasl account-notify\r\n".into())).await?;

    let (mut write, mut read): (futures_util::stream::SplitSink<_, WsMessage>, SplitStream<_>) = ws.split();

    // Registration state machine. We hold CAP END until SASL completes (or is
    // skipped) so the server doesn't finalize registration mid-handshake.
    #[derive(Debug)]
    enum RegPhase {
        WaitCapAck,
        SaslChallenge,
        SaslResult,
        Ready,
    }
    let mut phase = RegPhase::WaitCapAck;
    let mut auth_creds = auth;
    let mut pending: Vec<String> = Vec::new();

    'bridge: loop {
        tokio::select! {
            Some(cmd) = irc_rx.recv() => {
                debug!(session = %session_id, dir = ">>", line = %cmd.trim_end_matches(['\r', '\n']), "upstream IRC");
                match phase {
                    RegPhase::Ready => {
                        if let Err(e) = write.send(WsMessage::Text(cmd)).await {
                            warn!("WS write failed: {e}"); break;
                        }
                    }
                    _ => {
                        if pending.len() < 256 {
                            pending.push(cmd);
                        } else {
                            warn!("outbound command buffer full; dropping command");
                        }
                    }
                }
            }
            msg = read.next() => {
                match msg {
                    Some(Ok(WsMessage::Text(t))) => {
                        let line = t.to_string();
                        let trimmed = line.trim_end_matches(['\r', '\n']);
                        debug!(session = %session_id, dir = "<<", line = %trimmed, "upstream IRC");

                        if let Some(token) = ping_token(trimmed) {
                            let pong = format!("PONG {token}\r\n");
                            if let Err(e) = write.send(WsMessage::Text(pong.into())).await {
                                warn!("WS write failed on PONG: {e}"); break;
                            }
                            continue;
                        }

                        // Retry with a random nick on 433 (Nickname in use).
                        if trimmed.contains(" 433 ") {
                            let fallback = format!("webui{:x}", rand::random::<u32>());
                            let _ = write.send(WsMessage::Text(format!("NICK {fallback}\r\n").into())).await;
                            info!("433 received; retrying NICK as {fallback}");
                        }

                        // State-machine driven registration.
                        match phase {
                            RegPhase::WaitCapAck => {
                                if let Some(caps) = parse_cap_ack(trimmed) {
                            if caps.iter().any(|c| c.eq_ignore_ascii_case("sasl")) {
                                        if auth_creds.is_some() {
                                            let _ = write.send(WsMessage::Text(
                                                "AUTHENTICATE ATPROTO-CHALLENGE\r\n".into(),
                                            )).await;
                                            info!("sent AUTHENTICATE ATPROTO-CHALLENGE");
                                            phase = RegPhase::SaslChallenge;
                                            continue;
                                        }
                                    }
                                    // No SASL (guest mode or server didn't ACK sasl) — finish reg.
                                    let _ = write.send(WsMessage::Text("CAP END\r\n".into())).await;
                                    let _ = write.send(WsMessage::Text(format!("JOIN {channel}\r\n").into())).await;
                                    debug!(session = %session_id, "ws_state → Ready");
                                    session.set_ws_state(WsState::Ready);
                                    phase = RegPhase::Ready;
                                    if flush_pending(&mut pending, &mut write, &session_id).await.is_err() {
                                        break 'bridge;
                                    }
                                    continue;
                                }
                                // No CAP ACK yet — but if the server sent a 001 (RPL_WELCOME)
                                // or any 00x numeric, it doesn't support CAP. Proceed as guest.
                                if trimmed.contains(" 001 ") || trimmed.contains(" 002 ") || trimmed.contains(" 003 ") || trimmed.contains(" 004 ") {
                                    info!("server sent numeric registration reply without CAP ACK — proceeding as guest");
                                    let _ = write.send(WsMessage::Text("CAP END\r\n".into())).await;
                                    let _ = write.send(WsMessage::Text(format!("JOIN {channel}\r\n").into())).await;
                                    debug!(session = %session_id, "ws_state → Ready");
                                    session.set_ws_state(WsState::Ready);
                                    phase = RegPhase::Ready;
                                    if flush_pending(&mut pending, &mut write, &session_id).await.is_err() {
                                        break 'bridge;
                                    }
                                    continue;
                                }
                            }
                            RegPhase::SaslChallenge => {
                                if let Some(challenge_b64) = parse_authenticate_challenge(trimmed) {
                                    let creds = auth_creds
                                        .as_mut()
                                        .expect("SaslChallenge without creds");

                                    let challenge: Challenge = match parse_challenge(challenge_b64) {
                                        Ok(c) => c,
                                        Err(e) => {
                                            warn!("failed to parse SASL challenge, falling back to guest: {e}");
                                            auth_creds = None;
                                            let _ = write.send(WsMessage::Text("CAP END\r\n".into())).await;
                                            let _ = write.send(WsMessage::Text(format!("JOIN {channel}\r\n").into())).await;
                                    debug!(session = %session_id, "ws_state → Ready");
                                    session.set_ws_state(WsState::Ready);
                                            phase = RegPhase::Ready;
                                            if flush_pending(&mut pending, &mut write, &session_id).await.is_err() {
                                                break 'bridge;
                                            }
                                            continue;
                                        }
                                    };

                                    let get_session_url = format!(
                                        "{}/xrpc/com.atproto.server.getSession",
                                        creds.pds_url.trim_end_matches('/')
                                    );
                                    let dpop_proof = match creds.dpop_key.proof(
                                        "GET",
                                        &get_session_url,
                                        creds.dpop_nonce.as_deref(),
                                        Some(&creds.access_token),
                                    ) {
                                        Ok(p) => p,
                                        Err(e) => {
                                            warn!("failed to build DPoP proof, falling back to guest: {e}");
                                            auth_creds = None;
                                            let _ = write.send(WsMessage::Text("CAP END\r\n".into())).await;
                                            let _ = write.send(WsMessage::Text(format!("JOIN {channel}\r\n").into())).await;
                                    debug!(session = %session_id, "ws_state → Ready");
                                    session.set_ws_state(WsState::Ready);
                                            phase = RegPhase::Ready;
                                            if flush_pending(&mut pending, &mut write, &session_id).await.is_err() {
                                                break 'bridge;
                                            }
                                            continue;
                                        }
                                    };

                                    let payload = serde_json::json!({
                                        "did": creds.did,
                                        "signature": creds.access_token,
                                        "method": "pds-oauth",
                                        "pds_url": creds.pds_url,
                                        "dpop_proof": dpop_proof,
                                        "challenge_nonce": challenge.nonce,
                                    });
                                    let encoded = base64::engine::general_purpose::URL_SAFE_NO_PAD
                                        .encode(payload.to_string().as_bytes());
                                    let _ = write.send(WsMessage::Text(
                                        format!("AUTHENTICATE {encoded}\r\n").into(),
                                    )).await;
                                    info!(did = %creds.did, "sent SASL pds-oauth response");
                                    phase = RegPhase::SaslResult;
                                    continue;
                                }
                            }
                            RegPhase::SaslResult => {
                                if is_903(trimmed) {
                                    info!("SASL authentication successful");
                                    let _ = write.send(WsMessage::Text("CAP END\r\n".into())).await;
                                    let _ = write.send(WsMessage::Text(format!("JOIN {channel}\r\n").into())).await;
                                    debug!(session = %session_id, "ws_state → Ready");
                                    session.set_ws_state(WsState::Ready);
                                    phase = RegPhase::Ready;
                                    if flush_pending(&mut pending, &mut write, &session_id).await.is_err() {
                                        break 'bridge;
                                    }
                                    continue;
                                }
                                if is_904(trimmed) || trimmed.contains(" 904 ") {
                                    // Try refreshing the OAuth token before giving up.
                                    let mut refreshed = false;
                                    if let Some(ref creds) = auth_creds {
                                        if creds.refresh_token.is_some() {
                                            let mut temp = freeq_sdk::oauth::OAuthSession {
                                                did: creds.did.clone(),
                                                handle: String::new(),
                                                access_token: creds.access_token.clone(),
                                                refresh_token: creds.refresh_token.clone(),
                                                token_endpoint: creds.token_endpoint.clone(),
                                                client_id: creds.client_id.clone(),
                                                pds_url: creds.pds_url.clone(),
                                                dpop_key: creds.dpop_key.clone(),
                                                dpop_nonce: creds.dpop_nonce.clone(),
                                            };
                                            match temp.refresh().await {
                                                Ok(()) => {
                                                    info!(session = %session_id, "token refreshed; updating session and reconnecting");
                                                    let mut guard = session.auth.lock();
                                                    if let AuthState::Authenticated { ref mut oauth, .. } = *guard {
                                                        oauth.access_token = temp.access_token.clone();
                                                        oauth.refresh_token = temp.refresh_token.clone();
                                                        oauth.dpop_nonce = temp.dpop_nonce.clone();
                                                    }
                                                    drop(guard);
                                                    session.request_reconnect();
                                                    refreshed = true;
                                                }
                                                Err(e) => {
                                                    warn!(session = %session_id, "token refresh failed: {e:#}; falling back to guest");
                                                }
                                            }
                                        }
                                    }
                                    if refreshed {
                                        break 'bridge;
                                    }
                                    warn!("SASL authentication failed; proceeding as guest");
                                    auth_creds = None;
                                    let _ = write.send(WsMessage::Text("CAP END\r\n".into())).await;
                                    let _ = write.send(WsMessage::Text(format!("JOIN {channel}\r\n").into())).await;
                                    debug!(session = %session_id, "ws_state → Ready");
                                    session.set_ws_state(WsState::Ready);
                                    phase = RegPhase::Ready;
                                    if flush_pending(&mut pending, &mut write, &session_id).await.is_err() {
                                        break 'bridge;
                                    }
                                    continue;
                                }
                                // Server may send AUTHENTICATE + during SASL; ignore and wait for 903/904.
                            }
                            RegPhase::Ready => {}
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
    debug!(session = %session_id, "ws_state → Disconnected");
    session.set_ws_state(WsState::Disconnected);
    Ok(())
}

fn parse_challenge(challenge_b64: &str) -> Result<Challenge> {
    let bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(challenge_b64)
        .context("invalid challenge base64")?;
    serde_json::from_slice(&bytes).context("invalid challenge JSON")
}

async fn flush_pending<W>(pending: &mut Vec<String>, write: &mut W, session_id: &str) -> Result<(), tokio_tungstenite::tungstenite::Error>
where
    W: futures_util::Sink<WsMessage, Error = tokio_tungstenite::tungstenite::Error> + Unpin + Send,
{
    for cmd in pending.drain(..) {
        debug!(session = %session_id, dir = ">>", line = %cmd.trim_end_matches(['\r', '\n']), "upstream IRC (flushed)");
        if let Err(e) = write.send(WsMessage::Text(cmd)).await {
            warn!("WS write failed during flush: {e}");
            return Err(e);
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

/// Parse `CAP * ACK :sasl account-notify` into the list of acknowledged caps.
fn parse_cap_ack(line: &str) -> Option<Vec<&str>> {
    let line = line.trim_end_matches(['\r', '\n']);
    // Common forms:
    //   :server CAP * ACK :sasl account-notify
    //   :server CAP nick ACK :sasl account-notify
    let mut parts = line.split_whitespace();
    let _prefix = parts.next()?;
    let cap = parts.next()?;
    let star_or_nick = parts.next()?;
    let ack = parts.next()?;
    if !cap.eq_ignore_ascii_case("CAP") { return None; }
    if star_or_nick != "*" && !star_or_nick.starts_with(':') { return None; }
    if !ack.eq_ignore_ascii_case("ACK") { return None; }
    let last = parts.next()?;
    let caps = last.strip_prefix(':').unwrap_or(last);
    Some(caps.split_whitespace().collect())
}

/// Parse the server's `AUTHENTICATE <challenge>` prompt.
fn parse_authenticate_challenge(line: &str) -> Option<&str> {
    let line = line.trim_end_matches(['\r', '\n']);
    line.strip_prefix("AUTHENTICATE ").map(|s| s.trim_start())
}

pub fn is_903(line: &str) -> bool {
    is_numeric(line, "903 ")
}

pub fn is_904(line: &str) -> bool {
    is_numeric(line, "904 ")
}

fn is_numeric(line: &str, numeric: &str) -> bool {
    let line = line.trim_end_matches(['\r', '\n']);
    if let Some(rest) = line.strip_prefix(':') {
        if let Some(sp) = rest.find(' ') {
            return rest[sp + 1..].starts_with(numeric);
        }
    }
    line.starts_with(numeric)
}

pub async fn fetch_channels(state: &AppState) -> Result<Vec<UpstreamChannel>> {
    let url = state.upstream.base.join("api/v1/channels")?;
    Ok(state.http.get(url).send().await?.json().await?)
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::net::TcpListener;
    use tokio_tungstenite::tungstenite::Message as WsMessage;

    #[tokio::test]
    async fn ws_loop_defers_outbound_until_handshake_completes() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let ws_url = Url::parse(&format!("ws://127.0.0.1:{port}/irc")).unwrap();

        let (line_tx, mut line_rx) = tokio::sync::mpsc::channel::<String>(32);
        let (server_out_tx, mut server_out_rx) = tokio::sync::mpsc::channel::<String>(32);
        let (ack_trigger_tx, ack_trigger_rx) = tokio::sync::oneshot::channel::<()>();

        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let (mut ws_write, mut ws_read) = tokio_tungstenite::accept_async(stream)
                .await
                .unwrap()
                .split();

            // Forward every incoming frame to `line_rx` and notify once the four
            // registration lines have been seen so the server can ACK caps.
            let forward = tokio::spawn(async move {
                let mut seen = 0usize;
                let mut ack_trigger_tx = Some(ack_trigger_tx);
                while let Some(Ok(msg)) = ws_read.next().await {
                    if let WsMessage::Text(t) = msg {
                        for line in t.lines() {
                            let line = line.trim().to_string();
                            if !line.is_empty() {
                                seen += 1;
                                let _ = line_tx.send(line).await;
                                if seen == 4 {
                                    if let Some(tx) = ack_trigger_tx.take() {
                                        let _ = tx.send(());
                                    }
                                }
                            }
                        }
                    }
                }
            });

            // Wait for the trigger before ACKing; this gives the test time to
            // queue a PRIVMSG before the handshake completes.
            let _ = ack_trigger_rx.await;

            // ACK the capability request. The webui will then finish registration
            // and flush any buffered user commands (CAP END, JOIN, then PRIVMSG).
            let _ = ws_write
                .send(WsMessage::Text(":server CAP * ACK :sasl account-notify\r\n".into()))
                .await;

            while let Some(line) = server_out_rx.recv().await {
                if ws_write.send(WsMessage::Text(line.into())).await.is_err() {
                    break;
                }
            }
            forward.abort();
        });

        let (lines_tx, mut lines_rx) = broadcast::channel(16);
        let (irc_tx, irc_rx) = mpsc::channel(16);
        let client = tokio::spawn(async move {
            run_upstream_ws(ws_url, lines_tx, irc_rx, "#test".to_string(), None, Arc::new(SessionHandle::new()), "test".into()).await
        });

        // Queue a user command before the handshake completes.
        irc_tx
            .send("PRIVMSG #test :hello upstream\r\n".to_string())
            .await
            .unwrap();

        // Collect lines until we see the PRIVMSG.
        let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(2);
        let mut seen = Vec::new();
        while let Ok(Some(line)) = tokio::time::timeout_at(deadline, line_rx.recv()).await {
            let trimmed = line.trim_end_matches(['\r', '\n']).to_string();
            let done = trimmed.contains("PRIVMSG") && trimmed.contains("hello upstream");
            seen.push(trimmed);
            if done {
                break;
            }
        }

        // The queued PRIVMSG must not be sent before CAP END / JOIN.
        let privmsg_pos = seen
            .iter()
            .position(|l| l.contains("PRIVMSG") && l.contains("hello upstream"))
            .expect("PRIVMSG should reach upstream");
        let cap_end_pos = seen.iter().position(|l| l == "CAP END").expect("CAP END should be sent");
        let join_pos = seen
            .iter()
            .position(|l| l.starts_with("JOIN "))
            .expect("JOIN should be sent");
        assert!(
            cap_end_pos < privmsg_pos && join_pos < privmsg_pos,
            "PRIVMSG arrived before registration finished: {seen:?}"
        );

        // Upstream -> webui still works.
        server_out_tx
            .send(":alice!a@host PRIVMSG #test :hi webui\r\n".to_string())
            .await
            .unwrap();
        let line = tokio::time::timeout(std::time::Duration::from_secs(2), lines_rx.recv())
            .await
            .expect("timed out waiting for broadcast")
            .expect("broadcast channel closed");
        assert!(line.contains("PRIVMSG") && line.contains("hi webui"));

        client.abort();
        server.abort();
    }
}
