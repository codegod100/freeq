//! Erlang Distribution foreign node for freeq-gtk.
//!
//! Registers a hidden node with EPMD, accepts handshakes from BEAM peers
//! (Gleam freeq-web4 / view host), and delivers full view snapshots to the UI.

mod node;
mod protocol;

pub use node::{DistCommand, DistEvent, DistHandle, DistOptions, spawn_dist_node};
pub use protocol::Inbound;
