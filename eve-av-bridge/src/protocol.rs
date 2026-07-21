//! JSON WebSocket + HTTP control protocol for eve-av-bridge.

use serde::{Deserialize, Serialize};

use crate::session::RadioStatus;

pub const PROTOCOL_VERSION: u32 = 1;

// ── Client → bridge ─────────────────────────────────────────────────

#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ClientMsg {
    Ping {
        #[serde(default)]
        id: Option<String>,
    },
    ConnectSession {
        sfu_url: String,
        session_id: String,
        nick: String,
        #[serde(default)]
        instance: Option<String>,
        #[serde(default)]
        channel: Option<String>,
        #[serde(default)]
        audio_only: bool,
    },
    DisconnectSession,
    SpeakPcm {
        pcm_f32_le_b64: String,
        sample_rate: u32,
    },
    SpeakClear,
    /// Stream an internet radio URL into the active MoQ session.
    PlayRadio {
        url: String,
    },
    StopRadio,
    Status,
}

// ── Bridge → client ─────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ServerMsg {
    Hello {
        version: u32,
        features: Vec<String>,
    },
    Pong {
        #[serde(skip_serializing_if = "Option::is_none")]
        id: Option<String>,
    },
    Status {
        session: Option<SessionInfo>,
        clients: usize,
        #[serde(skip_serializing_if = "Option::is_none")]
        radio: Option<RadioStatus>,
    },
    SessionState {
        state: SessionState,
        #[serde(skip_serializing_if = "Option::is_none")]
        session: Option<SessionInfo>,
        #[serde(skip_serializing_if = "Option::is_none")]
        detail: Option<String>,
    },
    Participant {
        event: ParticipantEvent,
        nick: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        path: Option<String>,
    },
    Utterance {
        nick: String,
        sample_rate: u32,
        duration_ms: u32,
        voiced_samples: u32,
        pcm_f32_le_b64: String,
    },
    Speaking {
        active: bool,
        queue_secs: f32,
    },
    Radio {
        playing: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        url: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        title: Option<String>,
    },
    Error {
        message: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        code: Option<String>,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionInfo {
    pub session_id: String,
    pub nick: String,
    pub instance: String,
    pub sfu_url: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub channel: Option<String>,
    pub audio_only: bool,
    pub broadcast_path: String,
}

#[derive(Debug, Clone, Copy, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum SessionState {
    Idle,
    Connecting,
    Connected,
    Ended,
}

#[derive(Debug, Clone, Copy, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ParticipantEvent {
    Joined,
    Left,
}

impl ServerMsg {
    pub fn to_json(&self) -> String {
        serde_json::to_string(self).unwrap_or_else(|_| {
            r#"{"type":"error","message":"serialize failed"}"#.to_string()
        })
    }
}
