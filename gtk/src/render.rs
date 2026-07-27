//! Imperative GTK mount of a full [`View`] snapshot.
//!
//! Id conventions from the Gleam view tree:
//! - `chat_col` — expands to fill remaining width
//! - `user_panel` — fixed right rail (~280px), no horizontal expand
//! - `log` / `log_scroll` — chat stream; labels wrap fully (no ellipsis)
//! - `members_scroll` — compact right-rail list

use std::cell::Cell;
use std::collections::HashMap;
use std::rc::Rc;
use std::sync::mpsc;

use gtk::glib;
use gtk::prelude::*;

use crate::view::{ButtonStyle, Node, UiEvent, View};

pub fn mount_view(
    window: &adw::ApplicationWindow,
    host: &gtk::Box,
    view: &View,
    entry_drafts: &HashMap<String, String>,
    event_tx: mpsc::Sender<UiEvent>,
) {
    window.set_title(Some(&view.title));
    if window.default_width() < 100 {
        window.set_default_width(view.width.max(960));
        window.set_default_height(view.height.max(600));
    }

    while let Some(child) = host.first_child() {
        host.remove(&child);
    }

    let mut scroll_bottom: Vec<gtk::ScrolledWindow> = Vec::new();
    let body = build_node(
        &view.body,
        entry_drafts,
        event_tx,
        LayoutCtx::Root,
        &mut scroll_bottom,
    );
    body.set_hexpand(true);
    body.set_vexpand(true);
    host.append(&body);
    host.queue_allocate();
    host.queue_draw();

    // After layout, pin chat logs to the newest messages.
    for sw in scroll_bottom {
        scroll_to_bottom(&sw);
    }
}

/// Scroll a chat `ScrolledWindow` to the end once content has a real height.
///
/// Wrapping labels grow `upper` over several frames after remount. A single
/// early pin (or "done after first non-zero") leaves the viewport on older
/// messages until the user scrolls — felt like "stale until I wheel". Keep
/// pinning while height is still settling, then stop.
fn scroll_to_bottom(sw: &gtk::ScrolledWindow) {
    let vadj = sw.vadjustment();

    let pin = |adj: &gtk::Adjustment| {
        let upper = adj.upper();
        let page = adj.page_size();
        if upper > page {
            adj.set_value(upper - page);
        }
    };

    // Immediate (often still 0 height).
    pin(&vadj);

    // Settle flag: re-pin on adjustment changes while true.
    let settling = Rc::new(Cell::new(true));
    let settling_cb = settling.clone();
    vadj.connect_changed(move |adj| {
        if settling_cb.get() {
            let upper = adj.upper();
            let page = adj.page_size();
            if upper > page {
                adj.set_value(upper - page);
            }
        }
    });

    // Explicit ticks cover allocate / wrap without relying only on signals.
    for delay_ms in [0_u64, 16, 50, 100, 200, 350] {
        let adj = vadj.clone();
        let settling = settling.clone();
        glib::timeout_add_local(std::time::Duration::from_millis(delay_ms), move || {
            if settling.get() {
                pin(&adj);
            }
            glib::ControlFlow::Break
        });
    }

    // End settle window so later user scroll is not yanked back to bottom.
    {
        let settling = settling.clone();
        glib::timeout_add_local(std::time::Duration::from_millis(450), move || {
            settling.set(false);
            glib::ControlFlow::Break
        });
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
    } else if id == "log" || id == "log_scroll" || id.starts_with("msg:") {
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
    scroll_bottom: &mut Vec<gtk::ScrolledWindow>,
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
            for c in children {
                let child_ctx = match c {
                    Node::VBox { id, .. } | Node::HBox { id, .. } | Node::Scrolled { id, .. } => {
                        ctx_for_id(id, ctx)
                    }
                    Node::Label { id, .. } => ctx_for_id(id, ctx),
                    _ => ctx,
                };
                let w = build_node(c, drafts, event_tx.clone(), child_ctx, scroll_bottom);
                if matches!(c, Node::Scrolled { .. }) {
                    w.set_vexpand(true);
                    w.set_hexpand(true);
                }
                if matches!(c, Node::Entry { .. }) {
                    w.set_hexpand(true);
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
                let w = build_node(c, drafts, event_tx.clone(), child_ctx, scroll_bottom);
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
            let inner = build_node(child, drafts, event_tx, ctx, scroll_bottom);
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
            // Chat / system logs should open scrolled to the newest line.
            if id == "log_scroll" || ctx == LayoutCtx::ChatLog {
                scroll_bottom.push(sw.clone());
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
            s.set_vexpand(true);
            s.upcast()
        }
    }
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
