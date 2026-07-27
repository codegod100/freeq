//! Isomorphic render: GTK widgets follow the Gleam `View` tree as closely as
//! possible.
//!
//! ## Contract
//!
//! - **Data wins.** Layout/scroll intent lives on `View` / `Node`, not in ad-hoc
//!   client timers that invent policy.
//! - **Stable keys.** Nodes with stable `id`s are updated in place when the
//!   surrounding chrome is unchanged. Full destroy/rebuild only when the shell
//!   structure changes (channel switch, directory ↔ chat, …).
//! - **Scroll is pure.** After paint, `View.scroll` is applied once to
//!   `log_scroll` — no multi-second settle loops, no hidden stick state that
//!   overrides the next snapshot.
//!
//! ## Why this fixes “jump to old times on send”
//!
//! Send only changes log children (+ compose draft). Chrome is identical, so
//! we keep the same `ScrolledWindow` and swap message rows. The adjustment
//! stays near the bottom when `scroll = ScrollBottom`.

use std::collections::HashMap;
use std::sync::mpsc;

use gtk::glib;
use gtk::prelude::*;

use crate::render;
use crate::view::{Node, Scroll, UiEvent, View};

/// Holds widgets that must survive message-only updates.
pub struct IsoMount {
    /// Outer body under the content host (usually `shell` VBox).
    body: Option<gtk::Widget>,
    /// Message log scroller (`id = log_scroll`).
    log_scroll: Option<gtk::ScrolledWindow>,
    /// Vertical box inside the log scroller that holds Msg rows.
    log_list: Option<gtk::Box>,
    /// Last chrome fingerprint (view with log children stripped).
    chrome_key: u64,
    /// Last applied scroll policy (skip no-op re-apply).
    last_scroll: Option<Scroll>,
}

impl Default for IsoMount {
    fn default() -> Self {
        Self {
            body: None,
            log_scroll: None,
            log_list: None,
            chrome_key: 0,
            last_scroll: None,
        }
    }
}

impl IsoMount {
    /// Apply `next` isomorphically onto `host`.
    pub fn apply(
        &mut self,
        window: &adw::ApplicationWindow,
        host: &gtk::Box,
        next: &View,
        entry_drafts: &HashMap<String, String>,
        event_tx: mpsc::Sender<UiEvent>,
    ) {
        window.set_title(Some(&next.title));
        if window.default_width() < 100 {
            window.set_default_width(next.width.max(960));
            window.set_default_height(next.height.max(600));
        }

        let chrome = chrome_fingerprint(next);
        let can_patch_log = self.body.is_some()
            && self.log_list.is_some()
            && self.log_scroll.is_some()
            && chrome == self.chrome_key
            && extract_log_children(&next.body).is_some();

        if can_patch_log {
            self.patch_log_rows(next, entry_drafts, event_tx);
            self.sync_entries_from_view(next, entry_drafts);
            self.apply_scroll(&next.scroll, /*force*/ self.last_scroll.as_ref() != Some(&next.scroll));
            self.last_scroll = Some(next.scroll.clone());
            return;
        }

        // Shell changed (or first paint) — full rebuild, then capture handles.
        self.full_remount(host, next, entry_drafts, event_tx);
        self.chrome_key = chrome;
        self.last_scroll = Some(next.scroll.clone());
        self.apply_scroll(&next.scroll, true);
    }

    fn full_remount(
        &mut self,
        host: &gtk::Box,
        view: &View,
        entry_drafts: &HashMap<String, String>,
        event_tx: mpsc::Sender<UiEvent>,
    ) {
        while let Some(child) = host.first_child() {
            host.remove(&child);
        }
        self.log_scroll = None;
        self.log_list = None;
        self.body = None;

        let mut scroll_targets: Vec<(String, gtk::ScrolledWindow)> = Vec::new();
        let body = render::build_node_public(
            &view.body,
            entry_drafts,
            event_tx,
            &mut scroll_targets,
        );
        body.set_hexpand(true);
        body.set_vexpand(true);
        host.append(&body);
        self.body = Some(body.clone());

        // Prefer the real log scroller by id.
        for (id, sw) in scroll_targets {
            if id == "log_scroll" {
                self.log_scroll = Some(sw.clone());
                self.log_list = find_log_list(&sw);
            }
        }
        // Fallback: walk widget tree.
        if self.log_scroll.is_none() {
            if let Some(sw) = find_scrolled_by_name(&body, "fq_log_scroll") {
                self.log_list = find_log_list(&sw);
                self.log_scroll = Some(sw);
            }
        }

        host.queue_allocate();
        host.queue_draw();
    }

    fn patch_log_rows(
        &mut self,
        view: &View,
        entry_drafts: &HashMap<String, String>,
        event_tx: mpsc::Sender<UiEvent>,
    ) {
        let Some(list) = self.log_list.clone() else {
            return;
        };
        let Some(children) = extract_log_children(&view.body) else {
            return;
        };

        // Remember stick: if we were near bottom before patch, re-pin after.
        let was_near_bottom = self
            .log_scroll
            .as_ref()
            .map(|sw| near_bottom(sw))
            .unwrap_or(true);

        while let Some(c) = list.first_child() {
            list.remove(&c);
        }

        let mut dummy_targets = Vec::new();
        for child in children {
            let w = render::build_node_public(
                child,
                entry_drafts,
                event_tx.clone(),
                &mut dummy_targets,
            );
            w.set_hexpand(true);
            list.append(&w);
        }

        list.queue_allocate();
        if let Some(sw) = &self.log_scroll {
            sw.queue_allocate();
        }

        // If View says bottom OR user was already at bottom, pin after layout.
        let pin = matches!(view.scroll, Scroll::Bottom) || was_near_bottom;
        if pin {
            if let Some(sw) = &self.log_scroll {
                pin_bottom_once(sw);
                // One frame later for wrap growth of new Msg rows.
                let sw = sw.clone();
                glib::idle_add_local_once(move || {
                    pin_bottom_once(&sw);
                });
            }
        }
    }

    /// Compose Entry: local drafts win while typing; empty View draft after
    /// send clears the field without a full remount.
    fn sync_entries_from_view(
        &self,
        view: &View,
        entry_drafts: &HashMap<String, String>,
    ) {
        let Some(body) = &self.body else {
            return;
        };
        for (id, name) in [("input", "fq_input"), ("join_input", "fq_join_input")] {
            let Some(entry) = find_entry_by_name(body, name) else {
                continue;
            };
            if let Some(draft) = entry_drafts.get(id) {
                if entry.text().as_str() != draft.as_str() {
                    entry.set_text(draft);
                }
                continue;
            }
            // No local draft — use View Entry.text (cleared after successful send).
            if let Some(text) = entry_text_from_view(&view.body, id) {
                if entry.text().as_str() != text {
                    entry.set_text(text);
                }
            }
        }
    }

    fn apply_scroll(&self, policy: &Scroll, force: bool) {
        let Some(sw) = &self.log_scroll else {
            return;
        };
        match policy {
            Scroll::Preserve if !force => {}
            Scroll::Preserve => {}
            Scroll::Bottom => {
                pin_bottom_once(sw);
                let sw = sw.clone();
                glib::idle_add_local_once(move || pin_bottom_once(&sw));
                let sw2 = self.log_scroll.clone();
                glib::timeout_add_local(std::time::Duration::from_millis(50), move || {
                    if let Some(ref s) = sw2 {
                        pin_bottom_once(s);
                    }
                    glib::ControlFlow::Break
                });
            }
            Scroll::To { msgid } => {
                if !scroll_to_msgid_iso(sw, msgid) {
                    pin_bottom_once(sw);
                }
            }
        }
    }
}

fn pin_bottom_once(sw: &gtk::ScrolledWindow) {
    let adj = sw.vadjustment();
    let upper = adj.upper();
    let page = adj.page_size();
    let max = (upper - page).max(0.0);
    adj.set_value(max);
}

fn near_bottom(sw: &gtk::ScrolledWindow) -> bool {
    let adj = sw.vadjustment();
    let upper = adj.upper();
    let page = adj.page_size();
    let max = (upper - page).max(0.0);
    max - adj.value() < 96.0
}

fn scroll_to_msgid_iso(sw: &gtk::ScrolledWindow, msgid: &str) -> bool {
    let Some(child) = sw.child() else {
        return false;
    };
    if let Some(w) = find_widget_name_contains(&child, msgid) {
        let sw = sw.clone();
        let w = w.clone();
        glib::idle_add_local_once(move || {
            if let Some(bounds) = w.compute_bounds(&sw) {
                let adj = sw.vadjustment();
                let y = bounds.y() as f64;
                let page = adj.page_size();
                let max = (adj.upper() - page).max(0.0);
                let target = (y - page * 0.25).clamp(0.0, max);
                adj.set_value(target);
            }
        });
        true
    } else {
        false
    }
}

/// Fingerprint of the view with log message children removed.
fn chrome_fingerprint(view: &View) -> u64 {
    use std::collections::hash_map::DefaultHasher;
    use std::hash::{Hash, Hasher};
    let mut h = DefaultHasher::new();
    view.title.hash(&mut h);
    view.subtitle.hash(&mut h);
    // Strip log rows so message text does not affect chrome key.
    let stripped = strip_log_children(&view.body);
    hash_node(&stripped, &mut h);
    // Scroll policy is applied after paint, not part of chrome structure.
    h.finish()
}

fn hash_node(node: &Node, h: &mut impl std::hash::Hasher) {
    use std::hash::Hash;
    match node {
        Node::VBox { id, spacing, children } => {
            "vbox".hash(h);
            id.hash(h);
            spacing.hash(h);
            for c in children {
                hash_node(c, h);
            }
        }
        Node::HBox { id, spacing, children } => {
            "hbox".hash(h);
            id.hash(h);
            spacing.hash(h);
            for c in children {
                hash_node(c, h);
            }
        }
        Node::Label { id, text, dim } => {
            "label".hash(h);
            id.hash(h);
            text.hash(h);
            dim.hash(h);
        }
        Node::Button { id, label, style } => {
            "button".hash(h);
            id.hash(h);
            label.hash(h);
            format!("{style:?}").hash(h);
        }
        Node::Entry {
            id,
            text,
            placeholder,
            password,
        } => {
            "entry".hash(h);
            id.hash(h);
            // Draft text is client-owned; ignore for chrome key.
            let _ = text;
            placeholder.hash(h);
            password.hash(h);
        }
        Node::List { id, items } => {
            "list".hash(h);
            id.hash(h);
            items.hash(h);
        }
        Node::Scrolled { id, child } => {
            "scrolled".hash(h);
            id.hash(h);
            if id == "log_scroll" {
                // Children hashed as empty for chrome — only structure.
                "log_body".hash(h);
            } else {
                hash_node(child, h);
            }
        }
        Node::Separator => "sep".hash(h),
        Node::Spacer => "spacer".hash(h),
        Node::Msg { row } => {
            // Should not appear outside log in chrome strip.
            "msg".hash(h);
            row.id.hash(h);
            row.msgid.hash(h);
            row.text.hash(h);
        }
        Node::Av { panel } => {
            "av".hash(h);
            panel.active.hash(h);
            panel.call_present.hash(h);
            panel.channel.hash(h);
            panel.session_id.hash(h);
            panel.muted.hash(h);
            panel.camera.hash(h);
            panel.participant_count.hash(h);
        }
    }
}

fn strip_log_children(node: &Node) -> Node {
    match node {
        Node::Scrolled { id, child } if id == "log_scroll" => Node::Scrolled {
            id: id.clone(),
            child: Box::new(match child.as_ref() {
                Node::VBox { id, spacing, .. } => Node::VBox {
                    id: id.clone(),
                    spacing: *spacing,
                    children: vec![],
                },
                other => other.clone(),
            }),
        },
        Node::VBox { id, spacing, children } => Node::VBox {
            id: id.clone(),
            spacing: *spacing,
            children: children.iter().map(strip_log_children).collect(),
        },
        Node::HBox { id, spacing, children } => Node::HBox {
            id: id.clone(),
            spacing: *spacing,
            children: children.iter().map(strip_log_children).collect(),
        },
        // Region is unwrapped at decode time — never present here.
        other => other.clone(),
    }
}

fn extract_log_children(node: &Node) -> Option<Vec<&Node>> {
    match node {
        Node::Scrolled { id, child } if id == "log_scroll" => match child.as_ref() {
            Node::VBox { children, .. } => Some(children.iter().collect()),
            _ => Some(vec![child.as_ref()]),
        },
        Node::VBox { children, .. } | Node::HBox { children, .. } => {
            for c in children {
                if let Some(found) = extract_log_children(c) {
                    return Some(found);
                }
            }
            None
        }
        Node::Scrolled { child, .. } => extract_log_children(child),
        _ => None,
    }
}

fn find_log_list(sw: &gtk::ScrolledWindow) -> Option<gtk::Box> {
    let child = sw.child()?;
    // We wrap the log VBox in an outer Box — prefer fq_log@ or first VBox.
    find_box_with_log_id(&child)
}

fn find_box_with_log_id(w: &gtk::Widget) -> Option<gtk::Box> {
    if let Ok(b) = w.clone().downcast::<gtk::Box>() {
        let name = b.widget_name();
        if name.as_str().starts_with("fq_log") || name.as_str() == "fq_log" {
            return Some(b);
        }
        // Outer wrap has no name match — search children for log VBox.
        let mut c = b.first_child();
        while let Some(ch) = c {
            if let Some(found) = find_box_with_log_id(&ch) {
                return Some(found);
            }
            c = ch.next_sibling();
        }
        // Fallback: single child box used as list.
        if let Some(only) = b.first_child() {
            if let Ok(inner) = only.downcast::<gtk::Box>() {
                return Some(inner);
            }
        }
    }
    let mut c = w.first_child();
    while let Some(ch) = c {
        if let Some(found) = find_box_with_log_id(&ch) {
            return Some(found);
        }
        c = ch.next_sibling();
    }
    None
}

fn find_scrolled_by_name(root: &gtk::Widget, name: &str) -> Option<gtk::ScrolledWindow> {
    if let Ok(sw) = root.clone().downcast::<gtk::ScrolledWindow>() {
        if sw.widget_name().as_str() == name {
            return Some(sw);
        }
    }
    let mut c = root.first_child();
    while let Some(ch) = c {
        if let Some(found) = find_scrolled_by_name(&ch, name) {
            return Some(found);
        }
        c = ch.next_sibling();
    }
    None
}

fn entry_text_from_view<'a>(node: &'a Node, want_id: &str) -> Option<&'a str> {
    match node {
        Node::Entry { id, text, .. } if id == want_id => Some(text.as_str()),
        Node::VBox { children, .. } | Node::HBox { children, .. } => {
            for c in children {
                if let Some(t) = entry_text_from_view(c, want_id) {
                    return Some(t);
                }
            }
            None
        }
        Node::Scrolled { child, .. } => entry_text_from_view(child, want_id),
        _ => None,
    }
}

fn find_entry_by_name(root: &gtk::Widget, name: &str) -> Option<gtk::Entry> {
    if let Ok(e) = root.clone().downcast::<gtk::Entry>() {
        if e.widget_name().as_str() == name {
            return Some(e);
        }
    }
    let mut c = root.first_child();
    while let Some(ch) = c {
        if let Some(found) = find_entry_by_name(&ch, name) {
            return Some(found);
        }
        c = ch.next_sibling();
    }
    None
}

fn find_widget_name_contains(root: &gtk::Widget, needle: &str) -> Option<gtk::Widget> {
    if !needle.is_empty() && root.widget_name().as_str().contains(needle) {
        return Some(root.clone());
    }
    let mut c = root.first_child();
    while let Some(ch) = c {
        if let Some(found) = find_widget_name_contains(&ch, needle) {
            return Some(found);
        }
        c = ch.next_sibling();
    }
    None
}
