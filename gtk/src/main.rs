//! freeq-gtk — Relm4 renderer for Gleam-owned view trees over Erlang dist.

mod app;
mod dist;
mod iso;
mod render;
mod scroll_state;
mod view;

use std::path::PathBuf;

use clap::Parser;
use erl_dist::node::NodeName;
use relm4::RelmApp;
use tracing_subscriber::EnvFilter;

use crate::app::{AppInit, AppModel};
use crate::dist::DistOptions;

#[derive(Debug, Parser)]
#[command(
    name = "freeq-gtk",
    about = "Relm4 GTK renderer for Gleam views over Erlang distribution"
)]
struct Cli {
    /// Local node name (name@host). Default: freeq_gtk@localhost
    #[arg(long, env = "FREEQ_GTK_NODE")]
    node: Option<String>,

    /// Erlang cookie. Default: contents of ~/.erlang.cookie, else freeq_dev
    #[arg(long, env = "FREEQ_COOKIE")]
    cookie: Option<String>,

    /// Path to cookie file
    #[arg(long, env = "FREEQ_COOKIE_FILE")]
    cookie_file: Option<PathBuf>,

    /// Peer BEAM node for UI events (e.g. freeq_view@localhost)
    #[arg(long, env = "FREEQ_PEER")]
    peer: Option<String>,

    /// Registered process name on the peer for outbound events
    #[arg(long, default_value = "freeq_view", env = "FREEQ_PEER_PROCESS")]
    peer_process: String,

    /// Local process name (informational)
    #[arg(long, default_value = "freeq_gtk", env = "FREEQ_PROCESS")]
    process: String,

    /// Register as a published (non-hidden) node
    #[arg(long)]
    published: bool,
}

fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")),
        )
        .with_target(false)
        .init();

    let cli = Cli::parse();
    adw::init().expect("libadwaita init");
    install_app_icon();

    let default_node = "freeq_gtk@localhost".to_string();
    let local_node: NodeName = cli
        .node
        .unwrap_or(default_node)
        .parse()
        .expect("invalid --node (expected name@host)");

    let cookie = resolve_cookie(cli.cookie, cli.cookie_file);
    let peer_node = cli.peer.map(|p| {
        p.parse::<NodeName>()
            .unwrap_or_else(|e| panic!("invalid --peer: {e}"))
    });

    let dist = DistOptions {
        local_node,
        cookie,
        process_name: cli.process,
        peer_node,
        peer_process: cli.peer_process,
        published: cli.published,
    };

    // GApplication only accepts its own flags — pass program name alone so
    // clap options like --cookie are not rejected as "Unknown option".
    let prog = std::env::args().next().unwrap_or_else(|| "freeq-gtk".into());
    let app = RelmApp::new("at.freeq.gtk").with_args(vec![prog]);
    app.run::<AppModel>(AppInit { dist });
}

fn resolve_cookie(explicit: Option<String>, file: Option<PathBuf>) -> String {
    if let Some(c) = explicit {
        return c.trim().to_string();
    }
    let path = file.unwrap_or_else(|| {
        dirs_cookie_path().unwrap_or_else(|| PathBuf::from(".erlang.cookie"))
    });
    if let Ok(s) = std::fs::read_to_string(&path) {
        let c = s.trim().to_string();
        if !c.is_empty() {
            tracing::info!(path = %path.display(), "using cookie file");
            return c;
        }
    }
    tracing::warn!("no cookie file; using freeq_dev (set --cookie or ~/.erlang.cookie)");
    "freeq_dev".into()
}

fn dirs_cookie_path() -> Option<PathBuf> {
    let home = std::env::var_os("HOME")?;
    Some(PathBuf::from(home).join(".erlang.cookie"))
}

/// Register freeq-web4 icons (copied under assets/icons) so the window and
/// task switcher show `at.freeq.gtk` instead of a generic placeholder.
fn install_app_icon() {
    const ICON_NAME: &str = "at.freeq.gtk";

    let candidates = [
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("assets/icons"),
        // next to the binary (e.g. after a copy into a run dir)
        std::env::current_exe()
            .ok()
            .and_then(|p| p.parent().map(|d| d.join("assets/icons")))
            .unwrap_or_default(),
        PathBuf::from("assets/icons"),
    ];

    let icons_dir = candidates.into_iter().find(|p| p.is_dir());
    match icons_dir {
        Some(dir) => {
            if let Some(display) = gtk::gdk::Display::default() {
                let theme = gtk::IconTheme::for_display(&display);
                theme.add_search_path(&dir);
                tracing::info!(path = %dir.display(), icon = ICON_NAME, "app icon theme path");
            } else {
                tracing::warn!("no default display; cannot register icon theme path");
            }
            gtk::Window::set_default_icon_name(ICON_NAME);
        }
        None => {
            tracing::warn!("assets/icons not found; window will use the generic app icon");
        }
    }
}
