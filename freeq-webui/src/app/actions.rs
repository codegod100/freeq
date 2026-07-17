//! Mutation routes: send, join, part, topic, react, upload.

use serde::Deserialize;
use topcoat::context::Cx;
use topcoat::router::{Json, Multipart, path_param, route};
use topcoat::Result;
use tracing::info;

use crate::app::state;
use crate::irc_render::canonical_channel;
use crate::session_util::ensure_session_id;
use crate::upstream::spawn_upstream_if_needed;

#[path_param]
struct Channel(str);

#[derive(Deserialize)]
struct SendBody {
    msg: String,
}

#[derive(Deserialize)]
struct JoinBody {
    #[serde(default)]
    channel: String,
}

#[derive(Deserialize)]
struct TopicBody {
    topic: String,
}

#[derive(Deserialize)]
struct ReactBody {
    msgid: String,
    emoji: String,
}

#[derive(serde::Serialize)]
struct OkResp {
    ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
}

fn ok() -> Json<OkResp> {
    Json(OkResp {
        ok: true,
        error: None,
    })
}

fn err(msg: impl Into<String>) -> Json<OkResp> {
    Json(OkResp {
        ok: false,
        error: Some(msg.into()),
    })
}

fn parse_nick_command(msg: &str) -> Option<&str> {
    let rest = msg.strip_prefix("/nick ")?.trim();
    if rest.is_empty() {
        None
    } else {
        Some(rest)
    }
}

fn parse_whois_command(msg: &str) -> Option<&str> {
    let rest = msg.strip_prefix("/whois ")?.trim();
    if rest.is_empty() {
        None
    } else {
        Some(rest)
    }
}

#[route(POST "/chat/{channel}/send")]
async fn send(cx: &Cx, Json(body): Json<SendBody>) -> Result<Json<OkResp>> {
    let raw = path_param::<Channel>(cx);
    let channel = canonical_channel(&raw);
    let app = state(cx);
    let sid = ensure_session_id(cx);
    let session = app.session(&sid);
    spawn_upstream_if_needed(&app, &sid, &session, app.upstream.clone(), &channel);

    let msg = body.msg.trim().to_string();
    if msg.is_empty() {
        return Ok(err("empty message"));
    }

    let line = if let Some(nick) = parse_nick_command(&msg) {
        format!("NICK {nick}\r\n")
    } else if let Some(target) = parse_whois_command(&msg) {
        format!("WHOIS {target}\r\n")
    } else if let Some(rest) = msg.strip_prefix('/') {
        // Pass raw IRC command: /MODE #chan +t → MODE #chan +t
        format!("{rest}\r\n")
    } else {
        format!("PRIVMSG {channel} :{msg}\r\n")
    };

    let tx = session.irc_tx.lock().clone();
    if tx.try_send(line).is_err() {
        return Ok(err("upstream not ready"));
    }
    Ok(ok())
}

#[route(POST "/chat/{channel}/join")]
async fn join(cx: &Cx, Json(body): Json<JoinBody>) -> Result<Json<OkResp>> {
    let raw = path_param::<Channel>(cx);
    let channel = if body.channel.is_empty() {
        canonical_channel(&raw)
    } else {
        canonical_channel(&body.channel)
    };
    let app = state(cx);
    let sid = ensure_session_id(cx);
    let session = app.session(&sid);
    session.joined.lock().insert(channel.clone());
    spawn_upstream_if_needed(&app, &sid, &session, app.upstream.clone(), &channel);
    let tx = session.irc_tx.lock().clone();
    let _ = tx.try_send(format!("JOIN {channel}\r\n"));
    Ok(ok())
}

#[route(POST "/chat/{channel}/part")]
async fn part(cx: &Cx) -> Result<Json<OkResp>> {
    let raw = path_param::<Channel>(cx);
    let channel = canonical_channel(&raw);
    let app = state(cx);
    let sid = ensure_session_id(cx);
    let session = app.session(&sid);
    session.joined.lock().remove(&channel);
    let tx = session.irc_tx.lock().clone();
    let _ = tx.try_send(format!("PART {channel}\r\n"));
    Ok(ok())
}

#[route(POST "/chat/{channel}/topic")]
async fn topic(cx: &Cx, Json(body): Json<TopicBody>) -> Result<Json<OkResp>> {
    let raw = path_param::<Channel>(cx);
    let channel = canonical_channel(&raw);
    let app = state(cx);
    let sid = ensure_session_id(cx);
    let session = app.session(&sid);
    let tx = session.irc_tx.lock().clone();
    let _ = tx.try_send(format!("TOPIC {channel} :{}\r\n", body.topic));
    Ok(ok())
}

#[route(POST "/chat/{channel}/react")]
async fn react(cx: &Cx, Json(body): Json<ReactBody>) -> Result<Json<OkResp>> {
    let raw = path_param::<Channel>(cx);
    let channel = canonical_channel(&raw);
    let app = state(cx);
    let sid = ensure_session_id(cx);
    let session = app.session(&sid);
    let tx = session.irc_tx.lock().clone();
    // IRCv3 TAGMSG reaction
    let line = format!(
        "@+react={};+reply={} TAGMSG {channel}\r\n",
        body.emoji, body.msgid
    );
    if tx.try_send(line).is_err() {
        return Ok(err("upstream not ready"));
    }
    Ok(ok())
}

#[route(POST "/chat/{channel}/unreact")]
async fn unreact(cx: &Cx, Json(body): Json<ReactBody>) -> Result<Json<OkResp>> {
    let raw = path_param::<Channel>(cx);
    let channel = canonical_channel(&raw);
    let app = state(cx);
    let sid = ensure_session_id(cx);
    let session = app.session(&sid);
    let tx = session.irc_tx.lock().clone();
    let line = format!(
        "@+freeq.at/unreact={};+reply={} TAGMSG {channel}\r\n",
        body.emoji, body.msgid
    );
    if tx.try_send(line).is_err() {
        return Ok(err("upstream not ready"));
    }
    Ok(ok())
}

#[route(POST "/upload")]
async fn upload(cx: &Cx, mut multipart: Multipart) -> Result<Json<serde_json::Value>> {
    let app = state(cx);
    let sid = ensure_session_id(cx);
    let session = app.session(&sid);

    let mut file_data: Option<Vec<u8>> = None;
    let mut content_type = "application/octet-stream".to_string();
    let mut filename = "upload".to_string();
    let mut channel = String::new();
    let mut did = String::new();

    while let Some(field) = multipart.next_field().await? {
        match field.name() {
            Some("file") => {
                content_type = field
                    .content_type()
                    .unwrap_or("application/octet-stream")
                    .to_string();
                filename = field.file_name().unwrap_or("upload").to_string();
                file_data = Some(field.bytes().await?.to_vec());
            }
            Some("channel") => {
                channel = field.text().await?;
            }
            Some("did") => {
                did = field.text().await?;
            }
            _ => {}
        }
    }

    let session_did = session
        .auth
        .lock()
        .did()
        .map(|d| d.to_string())
        .or_else(|| session.extracted_did.lock().clone())
        .unwrap_or_default();
    let effective_did = if session_did.starts_with("did:") {
        session_did
    } else {
        did
    };
    let Some(file_data) = file_data else {
        return Ok(Json(serde_json::json!({"error": "No file provided"})));
    };

    info!(did = %effective_did, "upload proxy forwarding");
    let upstream_url = app.upstream.base.join("api/v1/upload").unwrap();
    let form = reqwest::multipart::Form::new()
        .part(
            "file",
            reqwest::multipart::Part::bytes(file_data)
                .file_name(filename)
                .mime_str(&content_type)
                .unwrap(),
        )
        .text("did", effective_did)
        .text("channel", channel);

    match app.http.post(upstream_url).multipart(form).send().await {
        Ok(r) => {
            let status = r.status().as_u16();
            let body: serde_json::Value = r.json().await.unwrap_or_else(|_| {
                serde_json::json!({"error": "invalid upstream response", "status": status})
            });
            Ok(Json(body))
        }
        Err(e) => Ok(Json(serde_json::json!({"error": format!("upstream: {e}")}))),
    }
}


