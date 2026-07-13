//! JSON/proxy API routes.

use axum::extract::{Multipart, Path, State};
use axum::http::{header, HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};

use crate::helpers::session_id_from_request;
use crate::state::AppState;
use crate::irc::render_history_row;
use crate::upstream::fetch_history;

pub async fn get_channel_history(
    State(state): State<AppState>,
    Path(channel): Path<String>,
    axum::extract::Query(params): axum::extract::Query<std::collections::HashMap<String, String>>,
) -> Response {
    let since = params.get("since").and_then(|s| s.parse::<i64>().ok());
    let limit = params.get("limit").and_then(|s| s.parse::<usize>().ok()).unwrap_or(50);
    match fetch_history(&state, &channel, limit, since).await {
        Ok(msgs) => {
            let html: Vec<String> = msgs.iter().map(render_history_row).collect();
            (
                axum::http::StatusCode::OK,
                [(axum::http::header::CONTENT_TYPE, "application/json")],
                serde_json::json!({
                    "messages": msgs,
                    "html": html,
                })
                .to_string(),
            )
                .into_response()
        }
        Err(e) => (
            axum::http::StatusCode::BAD_GATEWAY,
            format!("upstream: {e}"),
        )
            .into_response(),
    }
}

pub async fn get_channels(State(state): State<AppState>) -> Response {
    let url = state
        .upstream
        .base
        .join("api/v1/channels")
        .expect("upstream URL is valid");
    match state.http.get(url).send().await {
        Ok(r) => {
            let status = r.status();
            let body = r.text().await.unwrap_or_default();
            (status, [(header::CONTENT_TYPE, "application/json")], body).into_response()
        }
        Err(e) => (StatusCode::BAD_GATEWAY, format!("upstream: {e}")).into_response(),
    }
}

pub async fn get_policy(State(state): State<AppState>, Path(channel): Path<String>) -> Response {
    let url = {
        let mut u = state.upstream.base.clone();
        {
            let mut seg = u.path_segments_mut().expect("upstream URL is valid");
            seg.extend(["api", "v1", "policy", &channel]);
        }
        u
    };
    match state.http.get(url).send().await {
        Ok(r) => {
            let status = r.status();
            let body = r.text().await.unwrap_or_default();
            (status, [(header::CONTENT_TYPE, "application/json")], body).into_response()
        }
        Err(e) => (StatusCode::BAD_GATEWAY, format!("upstream: {e}")).into_response(),
    }
}

pub async fn get_policy_rules(
    State(state): State<AppState>,
    Path(channel): Path<String>,
) -> Response {
    let url = {
        let mut u = state.upstream.base.clone();
        {
            let mut seg = u.path_segments_mut().expect("upstream URL is valid");
            seg.extend(["api", "v1", "policy", &channel, "rules"]);
        }
        u
    };
    match state.http.get(url).send().await {
        Ok(r) => {
            let status = r.status();
            let body = r.text().await.unwrap_or_default();
            (status, [(header::CONTENT_TYPE, "application/json")], body).into_response()
        }
        Err(e) => (StatusCode::BAD_GATEWAY, format!("upstream: {e}")).into_response(),
    }
}

pub async fn get_rule(State(state): State<AppState>, Path(hash): Path<String>) -> Response {
    let url = {
        let mut u = state.upstream.base.clone();
        {
            let mut seg = u.path_segments_mut().expect("upstream URL is valid");
            seg.extend(["api", "v1", "rules", &hash]);
        }
        u
    };
    match state.http.get(url).send().await {
        Ok(r) => {
            let status = r.status();
            let body = r.text().await.unwrap_or_default();
            (status, [(header::CONTENT_TYPE, "application/json")], body).into_response()
        }
        Err(e) => (StatusCode::BAD_GATEWAY, format!("upstream: {e}")).into_response(),
    }
}

pub async fn post_upload(
    State(state): State<AppState>,
    headers: HeaderMap,
    mut multipart: Multipart,
) -> Response {
    let mut file_data: Option<Vec<u8>> = None;
    let mut content_type = "application/octet-stream".to_string();
    let mut filename = "upload".to_string();
    let mut channel = String::new();
    let mut did = String::new();

    while let Ok(Some(field)) = multipart.next_field().await {
        match field.name() {
            Some("file") => {
                content_type = field
                    .content_type()
                    .unwrap_or("application/octet-stream")
                    .to_string();
                filename = field.file_name().unwrap_or("upload").to_string();
                if let Ok(bytes) = field.bytes().await {
                    file_data = Some(bytes.to_vec());
                }
            }
            Some("channel") => {
                if let Ok(v) = field.text().await {
                    channel = v;
                }
            }
            Some("did") => {
                if let Ok(v) = field.text().await {
                    did = v;
                }
            }
            _ => {}
        }
    }

    let (sid, _) = session_id_from_request(&headers);
    let session = state.session(&sid);
    let session_did = session
        .auth
        .lock()
        .did()
        .map(|d| d.to_string())
        .or_else(|| session.extracted_did.lock().clone())
        .unwrap_or_default();
    let effective_did = if !session_did.is_empty() && session_did.starts_with("did:") {
        session_did
    } else {
        did
    };

    let file_data = match file_data {
        Some(d) => d,
        None => return (StatusCode::BAD_REQUEST, "No file provided").into_response(),
    };

    tracing::info!(did = %effective_did, "upload proxy forwarding");
    let upstream_url = state.upstream.base.join("api/v1/upload").unwrap();
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

    match state.http.post(upstream_url).multipart(form).send().await {
        Ok(r) => {
            let status = r.status();
            let body = r.text().await.unwrap_or_default();
            (status, [(header::CONTENT_TYPE, "application/json")], body).into_response()
        }
        Err(e) => (StatusCode::BAD_GATEWAY, format!("upstream: {e}")).into_response(),
    }
}
