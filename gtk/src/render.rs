//! Imperative GTK mount of a full [`View`] snapshot.
//!
//! Id conventions from the Gleam view tree:
//! - `chat_col` — expands to fill remaining width
//! - `user_panel` — fixed right rail (~280px), no horizontal expand
//! - `log` / `log_scroll` — chat stream; labels wrap fully (no ellipsis)
//! - `members_scroll` — compact right-rail list

use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;
use std::sync::mpsc;

use gtk::glib;
use gtk::prelude::*;

use crate::scroll_state::ScrollState;
use crate::view::{AvPanel, ButtonStyle, MsgRow, Node, Scroll, UiEvent, View};

/// Public builder used by [`crate::iso`] for full mounts and log-row patches.
pub fn build_node_public(
    node: &Node,
    drafts: &HashMap<String, String>,
    event_tx: mpsc::Sender<UiEvent>,
    scroll_targets: &mut Vec<(String, gtk::ScrolledWindow)>,
) -> gtk::Widget {
    build_node(node, drafts, event_tx, LayoutCtx::Root, scroll_targets)
}

/// Legacy full remount (prefer [`crate::iso::IsoMount::apply`]).
pub fn mount_view(
    window: &adw::ApplicationWindow,
    host: &gtk::Box,
    view: &View,
    entry_drafts: &HashMap<String, String>,
    event_tx: mpsc::Sender<UiEvent>,
    _scroll_state: &Rc<RefCell<ScrollState>>,
) {
    window.set_title(Some(&view.title));
    if window.default_width() < 100 {
        window.set_default_width(view.width.max(960));
        window.set_default_height(view.height.max(600));
    }

    while let Some(child) = host.first_child() {
        host.remove(&child);
    }

    let mut scroll_targets: Vec<(String, gtk::ScrolledWindow)> = Vec::new();
    let body = build_node(
        &view.body,
        entry_drafts,
        event_tx,
        LayoutCtx::Root,
        &mut scroll_targets,
    );
    body.set_hexpand(true);
    body.set_vexpand(true);
    host.append(&body);
    host.queue_allocate();
    host.queue_draw();

    // Pure scroll apply from View data (isomorphic — no stick hacks).
    for (id, sw) in &scroll_targets {
        if id == "log_scroll" {
            apply_scroll_simple(&view.scroll, sw);
        }
    }
}

fn apply_scroll_simple(policy: &Scroll, sw: &gtk::ScrolledWindow) {
    match policy {
        Scroll::Preserve => {}
        Scroll::Bottom => {
            let pin = |adj: &gtk::Adjustment| {
                let max = (adj.upper() - adj.page_size()).max(0.0);
                adj.set_value(max);
            };
            pin(&sw.vadjustment());
            let adj = sw.vadjustment();
            glib::idle_add_local_once(move || {
                pin(&adj);
            });
        }
        Scroll::To { msgid } => {
            let _ = msgid;
            let max = (sw.vadjustment().upper() - sw.vadjustment().page_size()).max(0.0);
            sw.vadjustment().set_value(max);
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum LayoutCtx {
    Root,
    /// Inside the message log column — labels must wrap, never ellipsize.
    ChatLog,
    /// Right rail — fixed width, no horizontal steal from chat.
    SideRail,
    Normal,
}

fn css_name(id: &str) -> String {
    let mut out = String::with_capacity(id.len() + 4);
    out.push_str("fq_");
    for c in id.chars() {
        if c.is_ascii_alphanumeric() || c == '_' || c == '-' {
            out.push(c);
        } else {
            out.push('_');
        }
    }
    out
}

fn ctx_for_id(id: &str, parent: LayoutCtx) -> LayoutCtx {
    if id == "user_panel" || id == "side" || id.ends_with("_panel") {
        LayoutCtx::SideRail
    } else if id == "log"
        || id == "log_scroll"
        || id.starts_with("msg:")
        || id.starts_with("log@")
    {
        LayoutCtx::ChatLog
    } else if id == "chat_col" {
        LayoutCtx::Normal
    } else if parent == LayoutCtx::ChatLog {
        LayoutCtx::ChatLog
    } else if parent == LayoutCtx::SideRail {
        LayoutCtx::SideRail
    } else {
        LayoutCtx::Normal
    }
}

fn build_node(
    node: &Node,
    drafts: &HashMap<String, String>,
    event_tx: mpsc::Sender<UiEvent>,
    parent_ctx: LayoutCtx,
    scroll_targets: &mut Vec<(String, gtk::ScrolledWindow)>,
) -> gtk::Widget {
    match node {
        Node::VBox {
            id,
            spacing,
            children,
        } => {
            let ctx = ctx_for_id(id, parent_ctx);
            let b = gtk::Box::new(gtk::Orientation::Vertical, *spacing);
            b.set_widget_name(&css_name(id));
            apply_box_layout(&b, id, ctx, true);
            // Shell / chat column must fill so log_scroll gets a real viewport
            // (otherwise SW grows with content and "scroll to bottom" is a no-op).
            if id == "shell" || id == "chat_col" || id.starts_with("log@") {
                b.set_vexpand(true);
                b.set_hexpand(true);
            }
            for c in children {
                let child_id = node_id(c);
                let child_ctx = match c {
                    Node::VBox { id, .. } | Node::HBox { id, .. } | Node::Scrolled { id, .. } => {
                        ctx_for_id(id, ctx)
                    }
                    Node::Label { id, .. } => ctx_for_id(id, ctx),
                    Node::Msg { row } => ctx_for_id(&row.id, LayoutCtx::ChatLog),
                    _ => ctx,
                };
                let w = build_node(c, drafts, event_tx.clone(), child_ctx, scroll_targets);
                if matches!(c, Node::Scrolled { .. }) || child_id == "log_scroll" {
                    w.set_vexpand(true);
                    w.set_hexpand(true);
                    w.set_valign(gtk::Align::Fill);
                }
                if child_id == "root" || child_id == "chat_col" {
                    w.set_vexpand(true);
                    w.set_hexpand(true);
                }
                if matches!(c, Node::Entry { .. }) {
                    w.set_hexpand(true);
                }
                // Non-log chrome must not steal vertical space from the log.
                if matches!(
                    c,
                    Node::Label { .. } | Node::Button { .. } | Node::HBox { .. } | Node::Av { .. }
                ) && child_id != "root"
                    && child_id != "chat_col"
                    && child_id != "composer"
                {
                    w.set_vexpand(false);
                }
                if child_id == "composer" || child_id == "nav" || child_id == "ch_header" {
                    w.set_vexpand(false);
                }
                b.append(&w);
            }
            b.upcast()
        }
        Node::HBox {
            id,
            spacing,
            children,
        } => {
            let ctx = ctx_for_id(id, parent_ctx);
            let b = gtk::Box::new(gtk::Orientation::Horizontal, *spacing);
            b.set_widget_name(&css_name(id));
            apply_box_layout(&b, id, ctx, false);
            for c in children {
                let child_id = node_id(c);
                let child_ctx = ctx_for_id(child_id, ctx);
                let w = build_node(c, drafts, event_tx.clone(), child_ctx, scroll_targets);
                // Chat column grows; user panel stays fixed.
                if child_id == "chat_col" || child_id == "log_scroll" {
                    w.set_hexpand(true);
                    w.set_vexpand(true);
                    w.set_halign(gtk::Align::Fill);
                } else if child_id == "user_panel" {
                    w.set_hexpand(false);
                    w.set_vexpand(true);
                    w.set_halign(gtk::Align::End);
                } else if matches!(c, Node::Scrolled { .. } | Node::Entry { .. }) {
                    w.set_hexpand(true);
                    if matches!(c, Node::Scrolled { .. }) {
                        w.set_vexpand(true);
                    }
                }
                b.append(&w);
            }
            b.upcast()
        }
        Node::Label { id, text, dim } => {
            let ctx = ctx_for_id(id, parent_ctx);
            let l = gtk::Label::new(Some(text));
            l.set_widget_name(&css_name(id));
            l.set_xalign(0.0);
            l.set_yalign(0.0);
            l.set_selectable(true);
            l.set_wrap(true);
            l.set_wrap_mode(gtk::pango::WrapMode::WordChar);
            l.set_ellipsize(gtk::pango::EllipsizeMode::None);
            l.set_hexpand(true);
            l.set_halign(gtk::Align::Fill);

            match ctx {
                LayoutCtx::ChatLog => {
                    // Force wrap within the chat column; never truncate.
                    l.set_wrap(true);
                    l.set_justify(gtk::Justification::Left);
                    l.add_css_class("chat-line");
                    // Natural width hint so Pango wraps before parent is huge.
                    l.set_max_width_chars(72);
                    l.set_width_chars(20);
                }
                LayoutCtx::SideRail => {
                    l.set_max_width_chars(26);
                    l.set_hexpand(true);
                    l.set_wrap(true);
                    // Inner padding so text sits off the card edges.
                    l.set_margin_start(14);
                    l.set_margin_end(14);
                    if id.ends_with("_hdr") || id == "you_hdr" || id == "members_hdr" || id == "rooms_hdr"
                    {
                        l.set_margin_top(4);
                        l.set_margin_bottom(2);
                    } else {
                        l.set_margin_top(1);
                        l.set_margin_bottom(1);
                    }
                }
                _ => {
                    l.set_max_width_chars(100);
                }
            }

            if *dim {
                l.add_css_class("dim-label");
            }
            // Emphasize title-ish ids.
            if id == "ch_title" || id == "hdr" || id == "you_nick" || id.ends_with("_hdr") {
                l.add_css_class("title-4");
            }
            l.upcast()
        }
        Node::Button { id, label, style } => {
            let btn = gtk::Button::with_label(label);
            btn.set_widget_name(&css_name(id));
            btn.set_halign(gtk::Align::Fill);
            btn.set_hexpand(parent_ctx == LayoutCtx::SideRail);
            if parent_ctx == LayoutCtx::SideRail {
                btn.set_margin_start(10);
                btn.set_margin_end(10);
                btn.set_margin_top(2);
                btn.set_margin_bottom(2);
            }
            match style {
                ButtonStyle::Normal => {
                    if parent_ctx == LayoutCtx::SideRail || id.starts_with("open:") {
                        btn.add_css_class("flat");
                    }
                }
                ButtonStyle::Suggested => btn.add_css_class("suggested-action"),
                ButtonStyle::Destructive => btn.add_css_class("destructive-action"),
            }
            let id = id.clone();
            let tx = event_tx.clone();
            btn.connect_clicked(move |_| {
                tracing::debug!(%id, "clicked");
                let _ = tx.send(UiEvent::Clicked { id: id.clone() });
            });
            btn.upcast()
        }
        Node::Entry {
            id,
            text,
            placeholder,
            password,
        } => {
            let entry = gtk::Entry::new();
            entry.set_widget_name(&css_name(id));
            entry.set_hexpand(true);
            entry.set_placeholder_text(Some(placeholder));
            entry.set_visibility(!*password);
            let shown = drafts.get(id).cloned().unwrap_or_else(|| text.clone());
            entry.set_text(&shown);

            let id_c = id.clone();
            let tx = event_tx.clone();
            entry.connect_changed(move |e| {
                let _ = tx.send(UiEvent::Changed {
                    id: id_c.clone(),
                    text: e.text().to_string(),
                });
            });

            let id_a = id.clone();
            let tx = event_tx.clone();
            entry.connect_activate(move |e| {
                let _ = tx.send(UiEvent::Activate {
                    id: id_a.clone(),
                    text: e.text().to_string(),
                });
            });
            entry.upcast()
        }
        Node::List { id, items } => {
            // Prefer VBox-of-labels for chat; keep List for rare generic use.
            let ctx = ctx_for_id(id, parent_ctx);
            let list = gtk::ListBox::new();
            list.set_widget_name(&css_name(id));
            list.set_selection_mode(gtk::SelectionMode::None);
            list.set_show_separators(ctx == LayoutCtx::ChatLog);
            list.set_hexpand(true);
            list.set_vexpand(true);
            list.set_css_classes(&[]); // drop boxed-list — it fights wrap

            if items.is_empty() {
                let row = gtk::ListBoxRow::new();
                let label = gtk::Label::new(Some("(empty)"));
                label.add_css_class("dim-label");
                label.set_margin_start(8);
                label.set_margin_end(8);
                label.set_margin_top(8);
                label.set_margin_bottom(8);
                row.set_child(Some(&label));
                list.append(&row);
            }
            for (i, item) in items.iter().enumerate() {
                let row = gtk::ListBoxRow::new();
                row.set_activatable(false);
                let label = gtk::Label::new(Some(item));
                label.set_xalign(0.0);
                label.set_yalign(0.0);
                label.set_wrap(true);
                label.set_wrap_mode(gtk::pango::WrapMode::WordChar);
                label.set_ellipsize(gtk::pango::EllipsizeMode::None);
                label.set_hexpand(true);
                label.set_halign(gtk::Align::Fill);
                label.set_max_width_chars(if ctx == LayoutCtx::ChatLog { 72 } else { 40 });
                label.set_margin_start(8);
                label.set_margin_end(8);
                label.set_margin_top(4);
                label.set_margin_bottom(4);
                label.set_selectable(true);
                row.set_child(Some(&label));
                list.append(&row);

                let id = id.clone();
                let item = item.clone();
                let tx = event_tx.clone();
                let index = i as i32;
                row.connect_activate(move |_| {
                    let _ = tx.send(UiEvent::Selected {
                        id: id.clone(),
                        index,
                        item: item.clone(),
                    });
                });
            }
            list.upcast()
        }
        Node::Scrolled { id, child } => {
            let ctx = ctx_for_id(id, parent_ctx);
            let sw = gtk::ScrolledWindow::new();
            sw.set_widget_name(&css_name(id));
            sw.set_vexpand(true);
            sw.set_hexpand(ctx != LayoutCtx::SideRail);
            sw.set_policy(gtk::PolicyType::Never, gtk::PolicyType::Automatic);
            // Never = no horizontal scrollbar — force content to wrap instead.
            if ctx == LayoutCtx::ChatLog || id == "log_scroll" {
                sw.set_min_content_height(200);
                sw.set_hexpand(true);
                sw.set_policy(gtk::PolicyType::Never, gtk::PolicyType::Automatic);
            }
            if ctx == LayoutCtx::SideRail || id == "members_scroll" {
                sw.set_min_content_height(120);
                sw.set_max_content_width(268);
                sw.set_margin_start(4);
                sw.set_margin_end(4);
            }
            let inner = build_node(child, drafts, event_tx, ctx, scroll_targets);
            inner.set_hexpand(true);
            // Viewport-friendly wrapper so labels get a defined width.
            let wrap = gtk::Box::new(gtk::Orientation::Vertical, 0);
            wrap.set_hexpand(true);
            wrap.set_halign(gtk::Align::Fill);
            if ctx == LayoutCtx::SideRail {
                wrap.set_margin_start(2);
                wrap.set_margin_end(2);
            }
            wrap.append(&inner);
            sw.set_child(Some(&wrap));
            // Chat / system logs — View.scroll decides pin vs preserve.
            if id == "log_scroll" || ctx == LayoutCtx::ChatLog {
                scroll_targets.push((id.clone(), sw.clone()));
            }
            sw.upcast()
        }
        Node::Separator => {
            let s = gtk::Separator::new(gtk::Orientation::Horizontal);
            if parent_ctx == LayoutCtx::SideRail {
                s.set_margin_start(14);
                s.set_margin_end(14);
                s.set_margin_top(10);
                s.set_margin_bottom(10);
            } else {
                s.set_margin_top(6);
                s.set_margin_bottom(6);
            }
            s.upcast()
        }
        Node::Spacer => {
            let s = gtk::Box::new(gtk::Orientation::Vertical, 0);
            // Overlay placeholders (empty react-picker) must not steal vertical space.
            s.set_vexpand(false);
            s.set_size_request(-1, 0);
            s.upcast()
        }
        Node::Msg { row } => build_msg_row(row, event_tx),
        Node::Av { panel } => build_av_panel(panel, event_tx),
    }
}

/// Call chrome only — MoQ media is browser-side; GTK shows status + controls.
fn build_av_panel(panel: &AvPanel, event_tx: mpsc::Sender<UiEvent>) -> gtk::Widget {
    if !panel.active && !panel.call_present {
        let empty = gtk::Box::new(gtk::Orientation::Vertical, 0);
        empty.set_size_request(-1, 0);
        return empty.upcast();
    }

    let outer = gtk::Box::new(gtk::Orientation::Vertical, 6);
    outer.set_widget_name("fq_av_panel");
    outer.set_hexpand(true);
    outer.set_margin_top(4);
    outer.set_margin_bottom(4);
    outer.add_css_class("card");
    outer.set_margin_start(4);
    outer.set_margin_end(4);

    if panel.active {
        let n = if panel.participant_count > 0 {
            panel.participant_count
        } else {
            1
        };
        let status = gtk::Label::new(Some(&format!(
            "📞 {} · {} in call",
            panel.channel, n
        )));
        status.set_xalign(0.0);
        status.set_margin_start(10);
        status.set_margin_end(10);
        status.set_margin_top(8);
        outer.append(&status);

        let actions = gtk::Box::new(gtk::Orientation::Horizontal, 6);
        actions.set_margin_start(10);
        actions.set_margin_end(10);
        actions.set_margin_bottom(8);

        let mute_label = if panel.muted { "🎤 off" } else { "🎤 on" };
        let mute = gtk::Button::with_label(mute_label);
        mute.add_css_class("flat");
        let tx = event_tx.clone();
        mute.connect_clicked(move |_| {
            let _ = tx.send(UiEvent::Clicked {
                id: "av_toggle_mute".into(),
            });
        });
        actions.append(&mute);

        let cam_label = if panel.camera { "📷 on" } else { "📷 off" };
        let cam = gtk::Button::with_label(cam_label);
        cam.add_css_class("flat");
        let tx = event_tx.clone();
        cam.connect_clicked(move |_| {
            let _ = tx.send(UiEvent::Clicked {
                id: "av_toggle_camera".into(),
            });
        });
        actions.append(&cam);

        let leave = gtk::Button::with_label("Leave");
        leave.add_css_class("destructive-action");
        let tx = event_tx.clone();
        leave.connect_clicked(move |_| {
            let _ = tx.send(UiEvent::Clicked {
                id: "av_leave".into(),
            });
        });
        actions.append(&leave);

        outer.append(&actions);

        let hint = gtk::Label::new(Some(
            "Media tiles are browser-only (MoQ). Controls sync via the shared View tree.",
        ));
        hint.add_css_class("dim-label");
        hint.set_xalign(0.0);
        hint.set_wrap(true);
        hint.set_margin_start(10);
        hint.set_margin_end(10);
        hint.set_margin_bottom(8);
        outer.append(&hint);
    } else if panel.call_present {
        let n = if panel.participant_count > 0 {
            panel.participant_count
        } else {
            1
        };
        let status = gtk::Label::new(Some(&format!(
            "🔊 Call on {} · {} in call",
            panel.channel, n
        )));
        status.set_xalign(0.0);
        status.set_margin_start(10);
        status.set_margin_top(8);
        outer.append(&status);

        let join = gtk::Button::with_label("Join call");
        join.add_css_class("suggested-action");
        join.set_margin_start(10);
        join.set_margin_end(10);
        join.set_margin_bottom(8);
        let tx = event_tx.clone();
        join.connect_clicked(move |_| {
            let _ = tx.send(UiEvent::Clicked {
                id: "av_join".into(),
            });
        });
        outer.append(&join);
    }

    outer.upcast()
}

fn build_msg_row(row: &MsgRow, event_tx: mpsc::Sender<UiEvent>) -> gtk::Widget {
    let outer = gtk::Box::new(gtk::Orientation::Vertical, 2);
    outer.set_widget_name(&css_name(&row.id));
    outer.set_hexpand(true);
    outer.set_halign(gtk::Align::Fill);
    outer.set_margin_top(2);
    outer.set_margin_bottom(2);
    outer.add_css_class("chat-msg");
    if row.own {
        outer.add_css_class("chat-msg-own");
    }
    if row.deleted {
        outer.add_css_class("chat-msg-deleted");
    }
    if row.highlight {
        outer.add_css_class("chat-msg-highlight");
    }

    // Header: time · nick
    let header = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    if !row.time.is_empty() {
        let ts = gtk::Label::new(Some(&row.time));
        ts.add_css_class("dim-label");
        ts.set_xalign(0.0);
        header.append(&ts);
    }
    if !row.nick.is_empty() {
        let nick = gtk::Label::new(Some(&row.nick));
        nick.add_css_class("title-4");
        nick.set_xalign(0.0);
        header.append(&nick);
    }
    if row.edited && !row.deleted {
        let ed = gtk::Label::new(Some("(edited)"));
        ed.add_css_class("dim-label");
        header.append(&ed);
    }
    outer.append(&header);

    if !row.parent_msgid.is_empty() {
        let who = if row.parent_nick.is_empty() {
            "message"
        } else {
            row.parent_nick.as_str()
        };
        let preview = if row.parent_preview.is_empty() {
            format!("↪ {who}")
        } else {
            format!("↪ {who}: {}", row.parent_preview)
        };
        let badge = gtk::Label::new(Some(&preview));
        badge.add_css_class("dim-label");
        badge.set_xalign(0.0);
        badge.set_wrap(true);
        badge.set_max_width_chars(72);
        outer.append(&badge);
    }

    let body_text = if row.deleted {
        let who = if row.nick.is_empty() {
            "someone"
        } else {
            row.nick.as_str()
        };
        format!("Message from {who} deleted")
    } else {
        row.text.clone()
    };
    let body = gtk::Label::new(Some(&body_text));
    body.set_xalign(0.0);
    body.set_yalign(0.0);
    body.set_selectable(true);
    body.set_wrap(true);
    body.set_wrap_mode(gtk::pango::WrapMode::WordChar);
    body.set_ellipsize(gtk::pango::EllipsizeMode::None);
    body.set_hexpand(true);
    body.set_halign(gtk::Align::Fill);
    body.set_max_width_chars(72);
    body.add_css_class("chat-line");
    if row.deleted {
        body.add_css_class("dim-label");
    }
    outer.append(&body);

    if !row.deleted && !row.embed_href.is_empty() {
        let title = if row.embed_title.is_empty() {
            row.embed_href.clone()
        } else {
            row.embed_title.clone()
        };
        let emb = gtk::Label::new(Some(&format!("🔗 {title}")));
        emb.add_css_class("dim-label");
        emb.set_xalign(0.0);
        emb.set_wrap(true);
        emb.set_max_width_chars(72);
        emb.set_selectable(true);
        outer.append(&emb);
    }

    if !row.deleted && (row.can_reply || row.can_edit || !row.reactions.is_empty() || !row.msgid.is_empty())
    {
        let actions = gtk::Box::new(gtk::Orientation::Horizontal, 4);
        actions.set_halign(gtk::Align::Start);

        for chip in &row.reactions {
            let id = format!("react:{}:{}", row.msgid, chip.emoji);
            let btn = gtk::Button::with_label(&chip.label);
            btn.add_css_class("flat");
            btn.add_css_class("pill");
            if chip.mine {
                btn.add_css_class("suggested-action");
            }
            let tx = event_tx.clone();
            btn.connect_clicked(move |_| {
                let _ = tx.send(UiEvent::Clicked { id: id.clone() });
            });
            actions.append(&btn);
        }

        if !row.msgid.is_empty() && !row.deleted && row.kind == "msg" {
            let id = format!("open_react:{}", row.msgid);
            let btn = gtk::Button::with_label("+");
            btn.add_css_class("flat");
            btn.set_tooltip_text(Some("React"));
            let tx = event_tx.clone();
            btn.connect_clicked(move |_| {
                let _ = tx.send(UiEvent::Clicked { id: id.clone() });
            });
            actions.append(&btn);
        }

        if row.can_reply {
            let id = format!("reply:{}", row.msgid);
            let btn = gtk::Button::with_label("↩");
            btn.add_css_class("flat");
            btn.set_tooltip_text(Some("Reply"));
            let tx = event_tx.clone();
            btn.connect_clicked(move |_| {
                let _ = tx.send(UiEvent::Clicked { id: id.clone() });
            });
            actions.append(&btn);
        }

        if row.can_edit {
            let id = format!("edit:{}", row.msgid);
            let btn = gtk::Button::with_label("✎");
            btn.add_css_class("flat");
            btn.set_tooltip_text(Some("Edit"));
            let tx = event_tx.clone();
            btn.connect_clicked(move |_| {
                let _ = tx.send(UiEvent::Clicked { id: id.clone() });
            });
            actions.append(&btn);
        }

        outer.append(&actions);
    }

    outer.upcast()
}

fn node_id(node: &Node) -> &str {
    match node {
        Node::VBox { id, .. }
        | Node::HBox { id, .. }
        | Node::Label { id, .. }
        | Node::Button { id, .. }
        | Node::Entry { id, .. }
        | Node::List { id, .. }
        | Node::Scrolled { id, .. } => id.as_str(),
        Node::Msg { row } => row.id.as_str(),
        Node::Av { .. } => "av_panel",
        Node::Separator | Node::Spacer => "",
    }
}

fn apply_box_layout(b: &gtk::Box, id: &str, ctx: LayoutCtx, vertical: bool) {
    if id == "user_panel" || id == "side" {
        b.set_hexpand(false);
        b.set_vexpand(true);
        b.set_size_request(304, -1);
        // Outer gap from window / chat column.
        b.set_margin_start(12);
        b.set_margin_end(16);
        b.set_margin_top(12);
        b.set_margin_bottom(16);
        b.set_spacing(10);
        b.add_css_class("card");
        return;
    }
    if ctx == LayoutCtx::SideRail && (id == "members_list" || id == "rooms_list") {
        b.set_hexpand(true);
        b.set_margin_start(8);
        b.set_margin_end(8);
        b.set_margin_top(4);
        b.set_margin_bottom(10);
        return;
    }
    if id == "chat_col" {
        b.set_hexpand(true);
        b.set_vexpand(true);
        b.set_margin_start(12);
        b.set_margin_end(8);
        b.set_margin_top(12);
        b.set_margin_bottom(12);
        return;
    }
    if id == "log" {
        b.set_hexpand(true);
        b.set_halign(gtk::Align::Fill);
        b.set_margin_start(4);
        b.set_margin_end(8);
        return;
    }
    if vertical {
        b.set_hexpand(true);
    }
    if ctx == LayoutCtx::SideRail {
        b.set_margin_start(8);
        b.set_margin_end(8);
    } else {
        b.set_margin_start(4);
        b.set_margin_end(4);
    }
}
