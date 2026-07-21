//! eve-av-bridge — standalone freeq AV media plane, controlled over WebSocket.
//!
//! ```text
//!   freeq SFU (MoQ)  ←── freeq-av ──►  eve-av-bridge  ←WS JSON→  eve / irc-bridge
//!   freeq IRC TAGMSG (av-join)  ── usually Node irc-bridge or optional irc-signaling
//! ```
//!
//! See README.md for the control protocol.

mod egress;
mod protocol;
mod radio;
mod watch;
mod session;
mod viz;
mod ws;

use std::net::SocketAddr;

use clap::Parser;
use tokio::sync::mpsc;
use tracing_subscriber::EnvFilter;

use crate::session::SessionManager;

#[derive(Parser, Debug)]
#[command(name = "eve-av-bridge", about = "WebSocket-controlled freeq AV media plane for eve")]
struct Args {
    /// Bind address for HTTP + WebSocket (`/ws`).
    #[arg(long, env = "AV_BRIDGE_BIND", default_value = "127.0.0.1:8790")]
    bind: SocketAddr,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    rustls::crypto::aws_lc_rs::default_provider()
        .install_default()
        .ok();

    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| EnvFilter::new("eve_av_bridge=info,freeq_av=info,info")),
        )
        .init();

    let args = Args::parse();
    let (event_tx, event_rx) = mpsc::unbounded_channel();
    let sessions = SessionManager::spawn(event_tx);

    ws::serve(args.bind, sessions, event_rx).await
}
