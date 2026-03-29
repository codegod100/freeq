use std::time::Duration;

use pyo3::exceptions::{PyRuntimeError, PyValueError};
use pyo3::prelude::*;
use serde_json::{Value, json};
use tokio::runtime::Runtime;
use tokio::sync::mpsc::Receiver;

use freeq_auth_broker::EmbeddedBroker;
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
    current_nick: String,
    handle: Option<ClientHandle>,
    events: Option<Receiver<Event>>,
}

#[pyclass(module = "freeq_textual._freeq", unsendable)]
pub struct FreeqAuthBroker {
    runtime: Runtime,
    broker: EmbeddedBroker,
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
            current_nick: nick,
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

    fn disconnect(&mut self) -> PyResult<()> {
        if let Some(handle) = self.handle.take() {
            let _ = self.runtime.block_on(handle.quit(Some("reconnecting")));
        }
        self.events = None;
        Ok(())
    }

    fn reconnect_with_web_token(&mut self, web_token: String) -> PyResult<()> {
        self.disconnect()?;
        self.config.web_token = Some(web_token);
        self.connect()
    }

    #[pyo3(signature = (web_token=None))]
    fn set_web_token(&mut self, web_token: Option<String>) {
        self.config.web_token = web_token;
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

    fn history_latest(&self, target: &str, count: usize) -> PyResult<()> {
        let handle = require_handle(&self.handle)?;
        self.runtime
            .block_on(handle.history_latest(target, count))
            .map_err(|err| runtime_err(err.to_string()))
    }

    fn raw(&self, line: &str) -> PyResult<()> {
        let handle = require_handle(&self.handle)?;
        self.runtime
            .block_on(handle.raw(line))
            .map_err(|err| runtime_err(err.to_string()))
    }

    fn set_nick(&self, nick: &str) -> PyResult<()> {
        let handle = require_handle(&self.handle)?;
        self.runtime
            .block_on(handle.raw(&format!("NICK {nick}")))
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
        let Some(receiver) = self.events.as_mut() else {
            return Ok(None);
        };
        let (next_event, channel_closed) = if timeout_ms == 0 {
            match receiver.try_recv() {
                Ok(event) => (Some(event), false),
                Err(tokio::sync::mpsc::error::TryRecvError::Empty) => (None, false),
                Err(tokio::sync::mpsc::error::TryRecvError::Disconnected) => (None, true),
            }
        } else {
            match self
                .runtime
                .block_on(async {
                    tokio::time::timeout(Duration::from_millis(timeout_ms), receiver.recv()).await
                })
                .map_err(|err| runtime_err(err.to_string()))?
            {
                Some(event) => (Some(event), false),
                None => (None, true),
            }
        };

        if channel_closed {
            self.events = None;
        }

        match next_event {
            Some(event) => {
                match &event {
                    Event::Registered { nick } => {
                        self.current_nick = nick.clone();
                    }
                    Event::NickChanged { old_nick, new_nick } => {
                        if self.current_nick.eq_ignore_ascii_case(old_nick) {
                            self.current_nick = new_nick.clone();
                        }
                    }
                    _ => {}
                }
                serde_json::to_string(&event_to_json(event))
                .map(Some)
                .map_err(|err| runtime_err(err.to_string()))
            }
            None => Ok(None),
        }
    }

    #[getter]
    fn nick(&self) -> String {
        self.current_nick.clone()
    }

    #[getter]
    fn server_addr(&self) -> String {
        self.config.server_addr.clone()
    }
}

#[pymethods]
impl FreeqAuthBroker {
    #[new]
    #[pyo3(signature = (shared_secret, freeq_server_url=None))]
    fn new(shared_secret: String, freeq_server_url: Option<String>) -> PyResult<Self> {
        if shared_secret.trim().is_empty() {
            return Err(PyValueError::new_err("shared_secret must not be empty"));
        }

        let runtime = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .map_err(|err| runtime_err(format!("failed to build tokio runtime: {err}")))?;
        let broker = runtime
            .block_on(freeq_auth_broker::spawn_embedded_broker(
                shared_secret,
                freeq_server_url,
            ))
            .map_err(|err| runtime_err(err.to_string()))?;
        Ok(Self { runtime, broker })
    }

    #[getter]
    fn base_url(&self) -> String {
        self.broker.base_url().to_string()
    }

    fn start_login(&self, handle: &str) -> PyResult<String> {
        if handle.trim().is_empty() {
            return Err(PyValueError::new_err("handle must not be empty"));
        }
        let (session_id, url) = self.broker.start_login(handle);
        serde_json::to_string(&json!({
            "session_id": session_id,
            "url": url,
        }))
        .map_err(|err| runtime_err(err.to_string()))
    }

    fn poll_auth_result_json(&self, session_id: &str) -> PyResult<Option<String>> {
        let value = self
            .runtime
            .block_on(self.broker.poll_auth_result(session_id));
        value
            .map(|payload| serde_json::to_string(&payload).map_err(|err| runtime_err(err.to_string())))
            .transpose()
    }
}

#[pymodule]
fn _freeq(_py: Python<'_>, module: &Bound<'_, PyModule>) -> PyResult<()> {
    module.add_class::<FreeqClient>()?;
    module.add_class::<FreeqAuthBroker>()?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::event_to_json;
    use freeq_sdk::event::Event;
    use std::collections::HashMap;

    #[test]
    fn event_to_json_preserves_replay_batch_start_fields() {
        let value = event_to_json(Event::BatchStart {
            id: "hist123".to_string(),
            batch_type: "chathistory".to_string(),
            target: "#freeq".to_string(),
        });

        assert_eq!(value["type"], "batch_start");
        assert_eq!(value["id"], "hist123");
        assert_eq!(value["batch_type"], "chathistory");
        assert_eq!(value["target"], "#freeq");
    }

    #[test]
    fn event_to_json_preserves_batched_message_tags() {
        let mut tags = HashMap::new();
        tags.insert("batch".to_string(), "hist123".to_string());
        tags.insert("time".to_string(), "2026-03-28T12:00:01.000Z".to_string());
        tags.insert("msgid".to_string(), "abc123".to_string());

        let value = event_to_json(Event::Message {
            from: "alice".to_string(),
            target: "#freeq".to_string(),
            text: "hello from history".to_string(),
            tags,
        });

        assert_eq!(value["type"], "message");
        assert_eq!(value["from"], "alice");
        assert_eq!(value["target"], "#freeq");
        assert_eq!(value["text"], "hello from history");
        assert_eq!(value["tags"]["batch"], "hist123");
        assert_eq!(value["tags"]["time"], "2026-03-28T12:00:01.000Z");
        assert_eq!(value["tags"]["msgid"], "abc123");
    }

    #[test]
    fn event_to_json_preserves_replay_batch_end_fields() {
        let value = event_to_json(Event::BatchEnd {
            id: "hist123".to_string(),
        });

        assert_eq!(value["type"], "batch_end");
        assert_eq!(value["id"], "hist123");
    }
}
