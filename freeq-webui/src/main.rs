//! freeq-webui — Topcoat BFF for the freeq IRC server.
//!
//! Browser ← HTML / SSE / form POSTs → freeq-webui ← WS /irc + REST → freeq-server

mod app;
mod irc_render;
mod oauth_flow;
mod session_util;
mod state;
mod upstream;

use std::net::SocketAddr;

use anyhow::{Context, Result};
use tracing::info;
use url::Url;

use crate::state::AppState;

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| {
                tracing_subscriber::EnvFilter::new(
                    "debug,reqwest=info,hyper=info,tungstenite=info,topcoat=info",
                )
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

    let addr: SocketAddr = bind.parse().context("FREEQ_WEBUI_BIND must be host:port")?;
    let listener = tokio::net::TcpListener::bind(addr).await?;
    info!(%addr, "listening");

    topcoat::serve(listener, app::router(state)).await?;
    Ok(())
}
