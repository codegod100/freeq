//! freeq-webui — standalone web UI for the freeq IRC server.

mod helpers;
mod irc;
mod routes;
mod state;
mod upstream;

use std::net::SocketAddr;

use anyhow::{Context, Result};
use axum::extract::State;
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::Router;
use tower_http::cors::{Any, CorsLayer};
use tracing::info;
use url::Url;

use crate::routes::*;
use crate::state::AppState;

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| {
                tracing_subscriber::EnvFilter::new("debug,reqwest=info,hyper=info,tungstenite=info")
            }),
        )
        .init();

    let upstream =
        std::env::var("FREEQ_UPSTREAM").unwrap_or_else(|_| "http://127.0.0.1:8080".to_string());
    let bind = std::env::var("FREEQ_WEBUI_BIND").unwrap_or_else(|_| "127.0.0.1:8090".to_string());
    let public_url = std::env::var("FREEQ_PUBLIC_URL").ok();
    let upstream_url: Url = upstream.parse().context("FREEQ_UPSTREAM must be a URL")?;

    let state = AppState::new(upstream_url.clone(), public_url.clone())?;
    info!(upstream = %upstream_url, bind = %bind, public_url = ?public_url, "freeq-webui starting");

    let app = Router::new()
        .route("/", get(get_root))
        .route("/login", get(get_login).post(post_login))
        .route("/logout", post(post_logout))
        .route("/auth/status", get(get_auth_status))
        .route("/auth/callback", get(get_auth_callback))
        .route(
            "/.well-known/oauth-client-metadata",
            get(get_oauth_client_metadata),
        )
        .route("/chat", get(get_channels_page))
        .route("/chat/{channel}", get(get_chat))
        .route("/chat/{channel}/send", post(post_channel_send))
        .route("/chat/{channel}/join", post(post_channel_join))
        .route("/chat/{channel}/part", post(post_channel_part))
        .route("/chat/{channel}/topic", post(post_channel_topic))
        .route("/chat/{channel}/react", post(post_channel_react))
        .route("/chat/{channel}/unreact", post(post_channel_unreact))
        .route("/chat/{channel}/stream", get(get_channel_stream))
        .route("/upload", post(post_upload))
        .route("/manifest.json", get(get_manifest_json))
        .route("/sw.js", get(get_service_worker))
        .route("/icon-192.png", get(get_icon_192))
        .route("/icon-512.png", get(get_icon_512))
        .route("/freeq_webui_client.js", get(get_freeq_client_js))
        .route("/freeq_webui_client_bg.wasm", get(get_freeq_client_wasm))
        .route("/api/channels", get(get_channels))
        .route("/api/policy/{channel}", get(get_policy))
        .route("/api/policy/{channel}/rules", get(get_policy_rules))
        .route("/api/rules/{hash}", get(get_rule))
        .route("/api/history/{channel}", get(get_channel_history))
        .layer(
            CorsLayer::new()
                .allow_origin(Any)
                .allow_methods(Any)
                .allow_headers(Any),
        )
        .with_state(state);

    let addr: SocketAddr = bind.parse().context("FREEQ_WEBUI_BIND must be host:port")?;
    let listener = tokio::net::TcpListener::bind(addr).await?;
    info!(%addr, "listening");
    axum::serve(listener, app).await?;
    Ok(())
}

async fn get_root(State(_state): State<AppState>) -> Response {
    (StatusCode::FOUND, [("Location", "/chat")], "").into_response()
}
