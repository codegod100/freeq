use std::time::Duration;

use pyo3::exceptions::{PyRuntimeError, PyValueError};
use pyo3::prelude::*;
use serde_json::{Value, json};
use tokio::runtime::Runtime;
use tokio::sync::mpsc::Receiver;

use freeq_sdk::client::{self, ClientHandle, ConnectConfig};
use freeq_sdk::event::Event;

fn runtime_err(message: impl Into<String>) -> PyErr {
    PyRuntimeError::new_err(message.into())
}

fn require_handle(handle: &Option<ClientHandle>) -> PyResult<&ClientHandle> {
    handle
        .as_ref()
        .ok_or_else(|| runtime_err("client is not connected"))
}

fn require_events(events: &mut Option<Receiver<Event>>) -> PyResult<&mut Receiver<Event>> {
    events
        .as_mut()
        .ok_or_else(|| runtime_err("client is not connected"))
}

fn event_to_json(event: Event) -> Value {
    match event {
        Event::Connected => json!({"type": "connected"}),
        Event::Registered { nick } => json!({"type": "registered", "nick": nick}),
        Event::Authenticated { did } => json!({"type": "authenticated", "did": did}),
        Event::AuthFailed { reason } => json!({"type": "auth_failed", "reason": reason}),
        Event::Joined { channel, nick } => {
            json!({"type": "joined", "channel": channel, "nick": nick})
        }
        Event::Parted { channel, nick } => {
            json!({"type": "parted", "channel": channel, "nick": nick})
        }
        Event::Message {
            from,
            target,
            text,
            tags,
        } => json!({
            "type": "message",
            "from": from,
            "target": target,
            "text": text,
            "tags": tags,
        }),
        Event::TagMsg { from, target, tags } => json!({
            "type": "tagmsg",
            "from": from,
            "target": target,
            "tags": tags,
        }),
        Event::BatchStart {
            id,
            batch_type,
            target,
        } => json!({
            "type": "batch_start",
            "id": id,
            "batch_type": batch_type,
            "target": target,
        }),
        Event::BatchEnd { id } => json!({"type": "batch_end", "id": id}),
        Event::ChatHistoryTarget { nick, timestamp } => json!({
            "type": "chat_history_target",
            "nick": nick,
            "timestamp": timestamp,
        }),
        Event::Names { channel, nicks } => {
            json!({"type": "names", "channel": channel, "nicks": nicks})
        }
        Event::NamesEnd { channel } => json!({"type": "names_end", "channel": channel}),
        Event::ModeChanged {
            channel,
            mode,
            arg,
            set_by,
        } => json!({
            "type": "mode_changed",
            "channel": channel,
            "mode": mode,
            "arg": arg,
            "set_by": set_by,
        }),
        Event::Kicked {
            channel,
            nick,
            by,
            reason,
        } => json!({
            "type": "kicked",
            "channel": channel,
            "nick": nick,
            "by": by,
            "reason": reason,
        }),
        Event::AwayChanged { nick, away_msg } => json!({
            "type": "away_changed",
            "nick": nick,
            "away_msg": away_msg,
        }),
        Event::NickChanged { old_nick, new_nick } => json!({
            "type": "nick_changed",
            "old_nick": old_nick,
            "new_nick": new_nick,
        }),
        Event::Invited { channel, by } => {
            json!({"type": "invited", "channel": channel, "by": by})
        }
        Event::TopicChanged {
            channel,
            topic,
            set_by,
        } => json!({
            "type": "topic_changed",
            "channel": channel,
            "topic": topic,
            "set_by": set_by,
        }),
        Event::WhoisReply { nick, info } => {
            json!({"type": "whois_reply", "nick": nick, "info": info})
        }
        Event::ServerNotice { text } => json!({"type": "server_notice", "text": text}),
        Event::UserQuit { nick, reason } => {
            json!({"type": "user_quit", "nick": nick, "reason": reason})
        }
        Event::Disconnected { reason } => json!({"type": "disconnected", "reason": reason}),
        Event::RawLine(line) => json!({"type": "raw_line", "line": line}),
    }
}

#[pyclass(module = "freeq_textual._freeq", unsendable)]
pub struct FreeqClient {
    runtime: Runtime,
    config: ConnectConfig,
    handle: Option<ClientHandle>,
    events: Option<Receiver<Event>>,
}

#[pymethods]
impl FreeqClient {
    #[new]
    #[pyo3(signature = (server_addr, nick, user=None, realname=None, tls=false, tls_insecure=false, web_token=None))]
    fn new(
        server_addr: String,
        nick: String,
        user: Option<String>,
        realname: Option<String>,
        tls: bool,
        tls_insecure: bool,
        web_token: Option<String>,
    ) -> PyResult<Self> {
        if server_addr.trim().is_empty() {
            return Err(PyValueError::new_err("server_addr must not be empty"));
        }
        if nick.trim().is_empty() {
            return Err(PyValueError::new_err("nick must not be empty"));
        }

        let runtime = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .map_err(|err| runtime_err(format!("failed to build tokio runtime: {err}")))?;

        Ok(Self {
            runtime,
            config: ConnectConfig {
                server_addr,
                nick: nick.clone(),
                user: user.unwrap_or_else(|| nick.clone()),
                realname: realname.unwrap_or_else(|| "freeq Textual client".to_string()),
                tls,
                tls_insecure,
                web_token,
            },
            handle: None,
            events: None,
        })
    }

    fn connect(&mut self) -> PyResult<()> {
        if self.handle.is_some() {
            return Ok(());
        }
        let _guard = self.runtime.enter();
        let (handle, events) = client::connect(self.config.clone(), None);
        self.handle = Some(handle);
        self.events = Some(events);
        Ok(())
    }

    fn join(&self, channel: &str) -> PyResult<()> {
        let handle = require_handle(&self.handle)?;
        self.runtime
            .block_on(handle.join(channel))
            .map_err(|err| runtime_err(err.to_string()))
    }

    fn send_message(&self, target: &str, text: &str) -> PyResult<()> {
        let handle = require_handle(&self.handle)?;
        self.runtime
            .block_on(handle.privmsg(target, text))
            .map_err(|err| runtime_err(err.to_string()))
    }

    fn raw(&self, line: &str) -> PyResult<()> {
        let handle = require_handle(&self.handle)?;
        self.runtime
            .block_on(handle.raw(line))
            .map_err(|err| runtime_err(err.to_string()))
    }

    #[pyo3(signature = (message=None))]
    fn quit(&self, message: Option<String>) -> PyResult<()> {
        let handle = require_handle(&self.handle)?;
        self.runtime
            .block_on(handle.quit(message.as_deref()))
            .map_err(|err| runtime_err(err.to_string()))
    }

    #[pyo3(signature = (timeout_ms=0))]
    fn poll_event_json(&mut self, timeout_ms: u64) -> PyResult<Option<String>> {
        let receiver = require_events(&mut self.events)?;
        let next_event = if timeout_ms == 0 {
            match receiver.try_recv() {
                Ok(event) => Some(event),
                Err(tokio::sync::mpsc::error::TryRecvError::Empty) => None,
                Err(tokio::sync::mpsc::error::TryRecvError::Disconnected) => {
                    return Err(runtime_err("event channel closed"));
                }
            }
        } else {
            self.runtime
                .block_on(async {
                    tokio::time::timeout(Duration::from_millis(timeout_ms), receiver.recv()).await
                })
                .map_err(|err| runtime_err(err.to_string()))?
        };

        match next_event {
            Some(event) => serde_json::to_string(&event_to_json(event))
                .map(Some)
                .map_err(|err| runtime_err(err.to_string())),
            None => Ok(None),
        }
    }

    #[getter]
    fn nick(&self) -> String {
        self.config.nick.clone()
    }

    #[getter]
    fn server_addr(&self) -> String {
        self.config.server_addr.clone()
    }
}

#[pymodule]
fn _freeq(_py: Python<'_>, module: &Bound<'_, PyModule>) -> PyResult<()> {
    module.add_class::<FreeqClient>()?;
    Ok(())
}
