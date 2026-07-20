//! Axum HTTP + WebSocket control plane.

use std::net::SocketAddr;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use axum::Json;
use axum::Router;
use axum::extract::State;
use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::http::StatusCode;
use axum::response::IntoResponse;
use axum::routing::{get, post};
use futures_util::{SinkExt, StreamExt};
use serde::Deserialize;
use tokio::sync::{broadcast, mpsc};
use tower_http::trace::TraceLayer;
use tracing::{info, warn};

use crate::protocol::{ClientMsg, PROTOCOL_VERSION, ServerMsg};
use crate::session::{SessionCmd, SessionManager, decode_pcm_f32_b64, new_instance};

#[derive(Clone)]
struct AppState {
    sessions: Arc<SessionManager>,
    events: broadcast::Sender<String>,
    clients: Arc<AtomicUsize>,
}

pub async fn serve(
    bind: SocketAddr,
    sessions: SessionManager,
    mut event_rx: mpsc::UnboundedReceiver<ServerMsg>,
) -> anyhow::Result<()> {
    let (bcast_tx, _) = broadcast::channel::<String>(256);
    let bcast_for_pump = bcast_tx.clone();

    tokio::spawn(async move {
        while let Some(msg) = event_rx.recv().await {
            let _ = bcast_for_pump.send(msg.to_json());
        }
    });

    let state = AppState {
        sessions: Arc::new(sessions),
        events: bcast_tx,
        clients: Arc::new(AtomicUsize::new(0)),
    };

    let app = Router::new()
        .route("/health", get(|| async { "ok" }))
        .route("/ws", get(ws_upgrade))
        .route("/v1/status", get(http_status))
        .route("/v1/session/connect", post(http_connect))
        .route("/v1/session/disconnect", post(http_disconnect))
        .route("/v1/radio/play", post(http_radio_play))
        .route("/v1/radio/stop", post(http_radio_stop))
        .layer(TraceLayer::new_for_http())
        .with_state(state);

    info!(%bind, "eve-av-bridge listening (ws /ws, http /v1/*)");
    let listener = tokio::net::TcpListener::bind(bind).await?;
    axum::serve(listener, app).await?;
    Ok(())
}

// ── HTTP ────────────────────────────────────────────────────────────

async fn http_status(State(state): State<AppState>) -> impl IntoResponse {
    let snap = state.sessions.status().await;
    Json(serde_json::json!({
        "ok": true,
        "session": snap.session,
        "radio": snap.radio,
        "clients": state.clients.load(Ordering::Relaxed),
    }))
}

#[derive(Deserialize)]
struct ConnectBody {
    sfu_url: String,
    session_id: String,
    nick: String,
    #[serde(default)]
    instance: Option<String>,
    #[serde(default)]
    channel: Option<String>,
    #[serde(default)]
    audio_only: bool,
}

async fn http_connect(
    State(state): State<AppState>,
    Json(body): Json<ConnectBody>,
) -> impl IntoResponse {
    let instance = body
        .instance
        .filter(|s| !s.is_empty())
        .unwrap_or_else(new_instance);
    match state
        .sessions
        .connect(
            body.sfu_url,
            body.session_id,
            body.nick,
            instance,
            body.channel,
            body.audio_only,
        )
        .await
    {
        Ok(info) => (StatusCode::OK, Json(serde_json::json!({ "ok": true, "session": info }))).into_response(),
        Err(e) => (
            StatusCode::BAD_REQUEST,
            Json(serde_json::json!({ "ok": false, "error": e })),
        )
            .into_response(),
    }
}

async fn http_disconnect(State(state): State<AppState>) -> impl IntoResponse {
    match state.sessions.disconnect().await {
        Ok(()) => (StatusCode::OK, Json(serde_json::json!({ "ok": true }))).into_response(),
        Err(e) => (
            StatusCode::BAD_REQUEST,
            Json(serde_json::json!({ "ok": false, "error": e })),
        )
            .into_response(),
    }
}

#[derive(Deserialize)]
struct PlayBody {
    url: String,
}

async fn http_radio_play(
    State(state): State<AppState>,
    Json(body): Json<PlayBody>,
) -> impl IntoResponse {
    match state.sessions.play_radio(body.url).await {
        Ok(radio) => (StatusCode::OK, Json(serde_json::json!({ "ok": true, "radio": radio }))).into_response(),
        Err(e) => (
            StatusCode::BAD_REQUEST,
            Json(serde_json::json!({ "ok": false, "error": e })),
        )
            .into_response(),
    }
}

async fn http_radio_stop(State(state): State<AppState>) -> impl IntoResponse {
    match state.sessions.stop_radio().await {
        Ok(()) => (StatusCode::OK, Json(serde_json::json!({ "ok": true }))).into_response(),
        Err(e) => (
            StatusCode::BAD_REQUEST,
            Json(serde_json::json!({ "ok": false, "error": e })),
        )
            .into_response(),
    }
}

// ── WebSocket ───────────────────────────────────────────────────────

async fn ws_upgrade(ws: WebSocketUpgrade, State(state): State<AppState>) -> impl IntoResponse {
    ws.on_upgrade(move |socket| handle_socket(socket, state))
}

async fn handle_socket(socket: WebSocket, state: AppState) {
    let (mut sink, mut stream) = socket.split();
    state.clients.fetch_add(1, Ordering::Relaxed);
    info!(
        clients = state.clients.load(Ordering::Relaxed),
        "ws client connected"
    );

    let mut features = vec![
        "media".into(),
        "vad_utterances".into(),
        "speak_pcm".into(),
        "radio".into(),
        "http_v1".into(),
    ];
    if cfg!(feature = "irc-signaling") {
        features.push("irc_signaling".into());
    }

    let hello = ServerMsg::Hello {
        version: PROTOCOL_VERSION,
        features,
    };
    if sink
        .send(Message::Text(hello.to_json().into()))
        .await
        .is_err()
    {
        state.clients.fetch_sub(1, Ordering::Relaxed);
        return;
    }

    let mut bcast_rx = state.events.subscribe();

    loop {
        tokio::select! {
            msg = stream.next() => {
                match msg {
                    Some(Ok(Message::Text(text))) => {
                        if let Err(e) = handle_text(&state, &text).await {
                            let err = ServerMsg::Error {
                                message: e.to_string(),
                                code: Some("client_msg".into()),
                            };
                            let _ = sink.send(Message::Text(err.to_json().into())).await;
                        }
                    }
                    Some(Ok(Message::Ping(p))) => {
                        let _ = sink.send(Message::Pong(p)).await;
                    }
                    Some(Ok(Message::Close(_))) | None => break,
                    Some(Ok(_)) => {}
                    Some(Err(e)) => {
                        warn!(error = %e, "ws read error");
                        break;
                    }
                }
            }
            evt = bcast_rx.recv() => {
                match evt {
                    Ok(json) => {
                        if sink.send(Message::Text(json.into())).await.is_err() {
                            break;
                        }
                    }
                    Err(broadcast::error::RecvError::Lagged(n)) => {
                        warn!(skipped = n, "ws client lagged");
                    }
                    Err(broadcast::error::RecvError::Closed) => break,
                }
            }
        }
    }

    state.clients.fetch_sub(1, Ordering::Relaxed);
    info!(
        clients = state.clients.load(Ordering::Relaxed),
        "ws client disconnected"
    );
}

async fn handle_text(state: &AppState, text: &str) -> anyhow::Result<()> {
    let msg: ClientMsg = serde_json::from_str(text)?;
    match msg {
        ClientMsg::Ping { id } => {
            let _ = state.events.send(ServerMsg::Pong { id }.to_json());
        }
        ClientMsg::ConnectSession {
            sfu_url,
            session_id,
            nick,
            instance,
            channel,
            audio_only,
        } => {
            let instance = instance.filter(|s| !s.is_empty()).unwrap_or_else(new_instance);
            state.sessions.send(SessionCmd::Connect {
                sfu_url,
                session_id,
                nick,
                instance,
                channel,
                audio_only,
                reply: None,
            });
        }
        ClientMsg::DisconnectSession => {
            state.sessions.send(SessionCmd::Disconnect { reply: None });
        }
        ClientMsg::SpeakPcm {
            pcm_f32_le_b64,
            sample_rate,
        } => {
            let pcm = decode_pcm_f32_b64(&pcm_f32_le_b64)?;
            state.sessions.send(SessionCmd::SpeakPcm { pcm, sample_rate });
        }
        ClientMsg::SpeakClear => {
            state.sessions.send(SessionCmd::SpeakClear);
        }
        ClientMsg::PlayRadio { url } => {
            state.sessions.send(SessionCmd::PlayRadio { url, reply: None });
        }
        ClientMsg::StopRadio => {
            state.sessions.send(SessionCmd::StopRadio { reply: None });
        }
        ClientMsg::Status => {
            state.sessions.send(SessionCmd::Status { reply: None });
        }
    }
    Ok(())
}
