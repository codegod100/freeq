//! Active freeq-av media session + per-participant VAD + radio + viz.

use std::sync::Arc;
use std::sync::atomic::AtomicU32;

use anyhow::{Context, Result};
use base64::Engine;
use base64::engine::general_purpose::STANDARD as B64;
use freeq_agent_kit::{VadConfig, VadSegmenter};
use freeq_av::{
    AvConfig, AvParticipant, AvSession, SPEAK_RATE, Speaker, broadcast_path, resample_mono,
};
use iroh_live::media::test_sources::TestPatternSource;
use tokio::sync::{Mutex, mpsc, oneshot, watch};
use tracing::{info, warn};

use crate::protocol::{ParticipantEvent, ServerMsg, SessionInfo, SessionState};
use crate::radio::{RadioHandle, start_radio};
use crate::viz::RadioViz;

/// Commands the WS/HTTP layer sends into the session manager.
pub enum SessionCmd {
    Connect {
        sfu_url: String,
        session_id: String,
        nick: String,
        instance: String,
        channel: Option<String>,
        audio_only: bool,
        reply: Option<oneshot::Sender<Result<SessionInfo, String>>>,
    },
    Disconnect {
        reply: Option<oneshot::Sender<Result<(), String>>>,
    },
    SpeakPcm {
        pcm: Vec<f32>,
        sample_rate: u32,
    },
    SpeakClear,
    PlayRadio {
        url: String,
        reply: Option<oneshot::Sender<Result<RadioStatus, String>>>,
    },
    StopRadio {
        reply: Option<oneshot::Sender<Result<(), String>>>,
    },
    Status {
        reply: Option<oneshot::Sender<StatusSnapshot>>,
    },
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct RadioStatus {
    pub playing: bool,
    pub url: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct StatusSnapshot {
    pub session: Option<SessionInfo>,
    pub radio: RadioStatus,
}

pub struct SessionManager {
    cmd_tx: mpsc::UnboundedSender<SessionCmd>,
}

impl SessionManager {
    pub fn spawn(event_tx: mpsc::UnboundedSender<ServerMsg>) -> Self {
        let (cmd_tx, cmd_rx) = mpsc::unbounded_channel();
        tokio::spawn(run_manager(cmd_rx, event_tx));
        Self { cmd_tx }
    }

    pub fn send(&self, cmd: SessionCmd) {
        let _ = self.cmd_tx.send(cmd);
    }

    pub async fn connect(
        &self,
        sfu_url: String,
        session_id: String,
        nick: String,
        instance: String,
        channel: Option<String>,
        audio_only: bool,
    ) -> Result<SessionInfo, String> {
        let (tx, rx) = oneshot::channel();
        self.send(SessionCmd::Connect {
            sfu_url,
            session_id,
            nick,
            instance,
            channel,
            audio_only,
            reply: Some(tx),
        });
        rx.await.map_err(|_| "session manager gone".to_string())?
    }

    pub async fn disconnect(&self) -> Result<(), String> {
        let (tx, rx) = oneshot::channel();
        self.send(SessionCmd::Disconnect { reply: Some(tx) });
        rx.await.map_err(|_| "session manager gone".to_string())?
    }

    pub async fn play_radio(&self, url: String) -> Result<RadioStatus, String> {
        let (tx, rx) = oneshot::channel();
        self.send(SessionCmd::PlayRadio {
            url,
            reply: Some(tx),
        });
        rx.await.map_err(|_| "session manager gone".to_string())?
    }

    pub async fn stop_radio(&self) -> Result<(), String> {
        let (tx, rx) = oneshot::channel();
        self.send(SessionCmd::StopRadio { reply: Some(tx) });
        rx.await.map_err(|_| "session manager gone".to_string())?
    }

    pub async fn status(&self) -> StatusSnapshot {
        let (tx, rx) = oneshot::channel();
        self.send(SessionCmd::Status { reply: Some(tx) });
        rx.await.unwrap_or(StatusSnapshot {
            session: None,
            radio: RadioStatus {
                playing: false,
                url: None,
                title: None,
            },
        })
    }
}

struct Live {
    info: SessionInfo,
    speaker: Speaker,
    _session_task: tokio::task::JoinHandle<()>,
    /// false when session should die
    alive: watch::Sender<bool>,
    radio: Option<RadioHandle>,
    radio_url: Option<String>,
    /// Shared video tile for radio DSP + ICY title (when !audio_only).
    viz: Option<RadioViz>,
}

async fn run_manager(
    mut cmd_rx: mpsc::UnboundedReceiver<SessionCmd>,
    event_tx: mpsc::UnboundedSender<ServerMsg>,
) {
    let live: Arc<Mutex<Option<Live>>> = Arc::new(Mutex::new(None));

    while let Some(cmd) = cmd_rx.recv().await {
        match cmd {
            SessionCmd::Connect {
                sfu_url,
                session_id,
                nick,
                instance,
                channel,
                audio_only,
                reply,
            } => {
                stop_live(&live, &event_tx, "replaced").await;

                let sfu: url::Url = match sfu_url.parse() {
                    Ok(u) => u,
                    Err(e) => {
                        let msg = format!("bad sfu_url: {e}");
                        emit(
                            &event_tx,
                            ServerMsg::Error {
                                message: msg.clone(),
                                code: Some("bad_sfu_url".into()),
                            },
                        );
                        if let Some(r) = reply {
                            let _ = r.send(Err(msg));
                        }
                        continue;
                    }
                };

                let path = broadcast_path(&session_id, &nick, &instance);
                let info = SessionInfo {
                    session_id: session_id.clone(),
                    nick: nick.clone(),
                    instance: instance.clone(),
                    sfu_url: sfu_url.clone(),
                    channel,
                    audio_only,
                    broadcast_path: path.clone(),
                };

                emit(
                    &event_tx,
                    ServerMsg::SessionState {
                        state: SessionState::Connecting,
                        session: Some(info.clone()),
                        detail: None,
                    },
                );

                let level = Arc::new(AtomicU32::new(0f32.to_bits()));
                let (speaker, push_source) = Speaker::new(level);
                let av_config = AvConfig {
                    sfu_url: sfu,
                    session_id: session_id.clone(),
                    our_broadcast: path,
                    my_nick: nick.clone(),
                    audio_only,
                };

                // Video tile for radio visualizer when not audio-only.
                let viz = if audio_only {
                    None
                } else {
                    let v = RadioViz::new("eve radio");
                    v.ensure_renderer();
                    Some(v)
                };

                let (alive_tx, alive_rx) = watch::channel(true);
                let event_tx2 = event_tx.clone();
                let info2 = info.clone();
                let viz_for_session = viz.clone();

                let session_task = tokio::spawn(async move {
                    if let Err(e) = run_av_session(
                        av_config,
                        push_source,
                        audio_only,
                        viz_for_session,
                        event_tx2.clone(),
                        alive_rx,
                    )
                    .await
                    {
                        warn!(error = %e, "av session error");
                        emit(
                            &event_tx2,
                            ServerMsg::Error {
                                message: e.to_string(),
                                code: Some("session_error".into()),
                            },
                        );
                    }
                    emit(
                        &event_tx2,
                        ServerMsg::SessionState {
                            state: SessionState::Ended,
                            session: Some(info2),
                            detail: None,
                        },
                    );
                });

                *live.lock().await = Some(Live {
                    info: info.clone(),
                    speaker,
                    _session_task: session_task,
                    alive: alive_tx,
                    radio: None,
                    radio_url: None,
                    viz,
                });

                emit(
                    &event_tx,
                    ServerMsg::SessionState {
                        state: SessionState::Connected,
                        session: Some(info.clone()),
                        detail: Some("media task started".into()),
                    },
                );
                if let Some(r) = reply {
                    let _ = r.send(Ok(info));
                }
            }
            SessionCmd::Disconnect { reply } => {
                stop_live(&live, &event_tx, "disconnect").await;
                if let Some(r) = reply {
                    let _ = r.send(Ok(()));
                }
            }
            SessionCmd::SpeakPcm { pcm, sample_rate } => {
                let g = live.lock().await;
                if let Some(l) = g.as_ref() {
                    l.speaker.enqueue(&pcm, sample_rate);
                    emit(
                        &event_tx,
                        ServerMsg::Speaking {
                            active: l.speaker.is_speaking(),
                            queue_secs: l.speaker.queued_secs(),
                        },
                    );
                } else {
                    emit(
                        &event_tx,
                        ServerMsg::Error {
                            message: "no active session".into(),
                            code: Some("no_session".into()),
                        },
                    );
                }
            }
            SessionCmd::SpeakClear => {
                let g = live.lock().await;
                if let Some(l) = g.as_ref() {
                    l.speaker.clear();
                    emit(
                        &event_tx,
                        ServerMsg::Speaking {
                            active: false,
                            queue_secs: 0.0,
                        },
                    );
                }
            }
            SessionCmd::PlayRadio { url, reply } => {
                let mut g = live.lock().await;
                let Some(l) = g.as_mut() else {
                    let msg = "no active AV session — connect first".to_string();
                    emit(
                        &event_tx,
                        ServerMsg::Error {
                            message: msg.clone(),
                            code: Some("no_session".into()),
                        },
                    );
                    if let Some(r) = reply {
                        let _ = r.send(Err(msg));
                    }
                    continue;
                };
                // Stop previous radio.
                if let Some(h) = l.radio.take() {
                    h.stop();
                }
                l.speaker.clear();
                let alive_rx = l.alive.subscribe();
                let viz = l.viz.clone();
                if l.info.audio_only {
                    warn!(
                        "radio playing on audio_only session — no video tile; reconnect with audio_only=false for viz"
                    );
                }
                match start_radio(url.clone(), l.speaker.clone(), alive_rx, viz) {
                    Ok(handle) => {
                        l.radio = Some(handle);
                        l.radio_url = Some(url.clone());
                        let st = RadioStatus {
                            playing: true,
                            url: Some(url),
                            title: None,
                        };
                        emit(
                            &event_tx,
                            ServerMsg::Radio {
                                playing: true,
                                url: st.url.clone(),
                                title: None,
                            },
                        );
                        if let Some(r) = reply {
                            let _ = r.send(Ok(st));
                        }
                    }
                    Err(e) => {
                        l.radio_url = None;
                        let msg = e.to_string();
                        emit(
                            &event_tx,
                            ServerMsg::Error {
                                message: msg.clone(),
                                code: Some("radio_start".into()),
                            },
                        );
                        if let Some(r) = reply {
                            let _ = r.send(Err(msg));
                        }
                    }
                }
            }
            SessionCmd::StopRadio { reply } => {
                let mut g = live.lock().await;
                if let Some(l) = g.as_mut() {
                    if let Some(h) = l.radio.take() {
                        h.stop();
                    }
                    l.radio_url = None;
                    l.speaker.clear();
                }
                emit(
                    &event_tx,
                    ServerMsg::Radio {
                        playing: false,
                        url: None,
                        title: None,
                    },
                );
                if let Some(r) = reply {
                    let _ = r.send(Ok(()));
                }
            }
            SessionCmd::Status { reply } => {
                let g = live.lock().await;
                let snap = match g.as_ref() {
                    Some(l) => {
                        let title = l
                            .radio
                            .as_ref()
                            .and_then(|h| h.title())
                            .or_else(|| l.viz.as_ref().map(|v| v.title()).filter(|t| !t.is_empty()));
                        StatusSnapshot {
                            session: Some(l.info.clone()),
                            radio: RadioStatus {
                                playing: l.radio.is_some(),
                                url: l.radio_url.clone(),
                                title,
                            },
                        }
                    }
                    None => StatusSnapshot {
                        session: None,
                        radio: RadioStatus {
                            playing: false,
                            url: None,
                            title: None,
                        },
                    },
                };
                if let Some(r) = reply {
                    let _ = r.send(snap.clone());
                }
                emit(
                    &event_tx,
                    ServerMsg::Status {
                        session: snap.session,
                        clients: 0,
                        radio: Some(snap.radio),
                    },
                );
            }
        }
    }
}

async fn stop_live(
    live: &Arc<Mutex<Option<Live>>>,
    event_tx: &mpsc::UnboundedSender<ServerMsg>,
    reason: &str,
) {
    let mut g = live.lock().await;
    if let Some(prev) = g.take() {
        if let Some(h) = prev.radio {
            h.stop();
        }
        if let Some(v) = prev.viz {
            v.stop();
        }
        let _ = prev.alive.send(false);
        emit(
            event_tx,
            ServerMsg::SessionState {
                state: SessionState::Ended,
                session: Some(prev.info),
                detail: Some(reason.into()),
            },
        );
    } else if reason == "disconnect" {
        emit(
            event_tx,
            ServerMsg::SessionState {
                state: SessionState::Idle,
                session: None,
                detail: None,
            },
        );
    }
}

async fn run_av_session(
    config: AvConfig,
    push_source: freeq_av::PushAudioSource,
    audio_only: bool,
    viz: Option<RadioViz>,
    event_tx: mpsc::UnboundedSender<ServerMsg>,
    mut alive: watch::Receiver<bool>,
) -> Result<()> {
    info!(
        session = %config.session_id,
        nick = %config.my_nick,
        audio_only,
        has_viz = viz.is_some(),
        "opening AvSession"
    );

    let mut session = match (audio_only, viz) {
        (false, Some(v)) => {
            let v2 = v.clone();
            AvSession::connect(config, push_source, move || v2.video_source())
        }
        (false, None) => {
            AvSession::connect(config, push_source, || TestPatternSource::new(640, 360))
        }
        (true, _) => {
            AvSession::connect(config, push_source, || TestPatternSource::new(320, 180))
        }
    };

    let mut taps = tokio::task::JoinSet::new();

    loop {
        tokio::select! {
            _ = alive.changed() => {
                if !*alive.borrow() {
                    info!("session cancel requested");
                    break;
                }
            }
            participant = session.recv() => {
                match participant {
                    Some(p) => {
                        emit(
                            &event_tx,
                            ServerMsg::Participant {
                                event: ParticipantEvent::Joined,
                                nick: p.nick.clone(),
                                path: Some(p.path.clone()),
                            },
                        );
                        let etx = event_tx.clone();
                        taps.spawn(async move {
                            pump_participant(p, etx).await;
                        });
                    }
                    None => {
                        info!("AvSession recv ended");
                        break;
                    }
                }
            }
        }
    }

    taps.abort_all();
    Ok(())
}

async fn pump_participant(mut p: AvParticipant, event_tx: mpsc::UnboundedSender<ServerMsg>) {
    let nick = p.nick.clone();
    let path = p.path.clone();
    info!(%nick, "tapping participant");

    let mut segmenter = VadSegmenter::new(VadConfig::default());

    while let Some(frame) = p.audio.recv().await {
        let rate = frame.format.sample_rate;
        let mono = if frame.format.channel_count > 1 {
            let ch = frame.format.channel_count as usize;
            let mut m = Vec::with_capacity(frame.samples.len() / ch.max(1));
            for chunk in frame.samples.chunks(ch.max(1)) {
                let s: f32 = chunk.iter().sum::<f32>() / ch.max(1) as f32;
                m.push(s);
            }
            m
        } else {
            frame.samples
        };
        let pcm16 = if rate == 16_000 {
            mono
        } else {
            resample_mono(&mono, rate, 16_000)
        };

        if let Some(utt) = segmenter.push_stats(&pcm16) {
            let duration_ms = (utt.pcm.len() as u64 * 1000 / 16_000) as u32;
            let bytes: Vec<u8> = utt.pcm.iter().flat_map(|f| f.to_le_bytes()).collect();
            emit(
                &event_tx,
                ServerMsg::Utterance {
                    nick: nick.clone(),
                    sample_rate: 16_000,
                    duration_ms,
                    voiced_samples: utt.voiced_samples as u32,
                    pcm_f32_le_b64: B64.encode(&bytes),
                },
            );
        }
    }

    emit(
        &event_tx,
        ServerMsg::Participant {
            event: ParticipantEvent::Left,
            nick,
            path: Some(path),
        },
    );
}

fn emit(tx: &mpsc::UnboundedSender<ServerMsg>, msg: ServerMsg) {
    let _ = tx.send(msg);
}

pub fn decode_pcm_f32_b64(b64: &str) -> Result<Vec<f32>> {
    let bytes = B64.decode(b64.trim()).context("base64 decode pcm")?;
    if !bytes.len().is_multiple_of(4) {
        anyhow::bail!("pcm byte length not multiple of 4");
    }
    let mut out = Vec::with_capacity(bytes.len() / 4);
    for chunk in bytes.chunks_exact(4) {
        out.push(f32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]));
    }
    Ok(out)
}

pub fn new_instance() -> String {
    let u = uuid::Uuid::new_v4();
    format!("{:08x}", (u.as_u128() & 0xffff_ffff) as u32)
}

#[allow(dead_code)]
pub fn speak_rate() -> u32 {
    SPEAK_RATE
}
