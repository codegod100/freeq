//! Dist envelope: full view snapshots in, UI events out.
//!
//! ## BEAM → GTK
//!
//! A single term — the Gleam `View` constructor:
//!
//! ```erlang
//! {view, Title, Subtitle, Width, Height, Body}
//! ```
//!
//! ## GTK → BEAM
//!
//! ```erlang
//! {clicked, Id}
//! {activate, Id, Text}
//! {changed, Id, Text}
//! {selected, Id, Index, Item}
//! ```

use eetf::Term;

use crate::view::{View};

/// Inbound payload from a Gleam/Erlang peer.
#[derive(Debug, Clone)]
pub enum Inbound {
    /// Full window snapshot — replaces the entire UI.
    View(View),
    /// Term did not decode as a View (shown in bootstrap subtitle).
    DecodeError(String),
}

impl Inbound {
    pub fn from_term(term: &Term) -> Self {
        match View::from_term(term) {
            Ok(v) => Self::View(v),
            Err(e) => Self::DecodeError(format!("{e}: {term}")),
        }
    }
}
