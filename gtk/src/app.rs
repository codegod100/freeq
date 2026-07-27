//! Thin Relm4 shell: holds the latest Gleam `View` and remounts GTK from it.

use std::collections::HashMap;
use std::sync::mpsc;

use adw::prelude::*;
use gtk::gio;
use gtk::glib;
use gtk::prelude::{ActionMapExt, GtkWindowExt, IsA, WidgetExt};
use relm4::prelude::*;

use crate::dist::{DistCommand, DistEvent, DistHandle, DistOptions, Inbound, spawn_dist_node};
use crate::render;
use crate::view::{Node, UiEvent, View};

const APP_ID: &str = "at.freeq.gtk";
const APP_NAME: &str = "freeq";

pub struct AppModel {
    view: View,
    dirty: bool,
    dist: Option<DistHandle>,
    peer_process: String,
    last_peer: Option<String>,
    entry_drafts: HashMap<String, String>,
    boot_detail: String,
    /// Short debug line: last decode / remount status.
    debug: String,
    ui_tx: mpsc::Sender<UiEvent>,
    /// Generation counter so we can skip no-op remounts.
    view_gen: u64,
}

#[derive(Debug)]
pub enum AppMsg {
    Dist(DistEvent),
    Ui(UiEvent),
    ShowAbout,
}

pub struct AppInit {
    pub dist: DistOptions,
}

#[relm4::component(pub)]
impl Component for AppModel {
    type Init = AppInit;
    type Input = AppMsg;
    type Output = ();
    type CommandOutput = ();

    view! {
        #[root]
        adw::ApplicationWindow {
            set_title: Some("freeq-gtk"),
            set_icon_name: Some("at.freeq.gtk"),
            set_default_width: 900,
            set_default_height: 640,

            adw::ToolbarView {
                add_top_bar = &adw::HeaderBar {
                    #[wrap(Some)]
                    set_title_widget = &adw::WindowTitle {
                        #[watch]
                        set_title: &model.view.title,
                        #[watch]
                        set_subtitle: &model.header_subtitle(),
                    },

                    #[name = "menu_btn"]
                    pack_end = &gtk::MenuButton {
                        set_icon_name: "open-menu-symbolic",
                        set_tooltip_text: Some("Main menu"),
                        set_primary: true,
                    },
                },

                #[wrap(Some)]
                set_content = &gtk::Box {
                    set_orientation: gtk::Orientation::Vertical,
                    set_spacing: 0,
                    set_hexpand: true,
                    set_vexpand: true,

                    // Always-visible debug strip (decode / remount status).
                    gtk::Label {
                        set_css_classes: &["dim-label"],
                        set_xalign: 0.0,
                        set_margin_start: 10,
                        set_margin_end: 10,
                        set_margin_top: 4,
                        set_ellipsize: gtk::pango::EllipsizeMode::End,
                        #[watch]
                        set_label: &model.debug,
                    },

                    #[name = "content_host"]
                    gtk::Box {
                        set_orientation: gtk::Orientation::Vertical,
                        set_spacing: 0,
                        set_hexpand: true,
                        set_vexpand: true,
                    },
                },
            },
        }
    }

    fn init(
        init: Self::Init,
        root: Self::Root,
        sender: ComponentSender<Self>,
    ) -> ComponentParts<Self> {
        let local = init.dist.local_node.to_string();
        let (ui_tx, ui_rx) = mpsc::channel::<UiEvent>();

        let mut model = AppModel {
            view: View::waiting(&local, "starting Erlang dist…"),
            dirty: true,
            dist: None,
            peer_process: init.dist.peer_process.clone(),
            last_peer: init.dist.peer_node.as_ref().map(|p| p.to_string()),
            entry_drafts: HashMap::new(),
            boot_detail: "starting…".into(),
            debug: "init".into(),
            ui_tx,
            view_gen: 0,
        };

        let (event_tx, event_rx) = mpsc::channel::<DistEvent>();
        match spawn_dist_node(init.dist, event_tx) {
            Ok(handle) => model.dist = Some(handle),
            Err(e) => {
                model.boot_detail = e.clone();
                model.debug = format!("dist error: {e}");
                model.view = View::waiting(&local, &e);
                model.dirty = true;
            }
        }

        let widgets = view_output!();

        // Primary menu: hamburger → About freeq
        let menu = gio::Menu::new();
        menu.append(Some("_About freeq"), Some("win.about"));
        widgets.menu_btn.set_menu_model(Some(&menu));

        let about_action = gio::SimpleAction::new("about", None);
        {
            let sender = sender.clone();
            about_action.connect_activate(move |_, _| {
                sender.input(AppMsg::ShowAbout);
            });
        }
        root.add_action(&about_action);

        {
            let sender = sender.clone();
            glib::timeout_add_local(std::time::Duration::from_millis(50), move || {
                while let Ok(ev) = event_rx.try_recv() {
                    sender.input(AppMsg::Dist(ev));
                }
                while let Ok(ev) = ui_rx.try_recv() {
                    sender.input(AppMsg::Ui(ev));
                }
                glib::ControlFlow::Continue
            });
        }

        // Defer first mount until the window is realized — avoids
        // gtk_widget_is_ancestor assertions during early init.
        {
            let host = widgets.content_host.clone();
            let view = model.view.clone();
            let drafts = model.entry_drafts.clone();
            let ui_tx = model.ui_tx.clone();
            let root = root.clone();
            glib::idle_add_local_once(move || {
                render::mount_view(&root, &host, &view, &drafts, ui_tx);
            });
        }
        model.dirty = false;

        ComponentParts { model, widgets }
    }

    fn update_with_view(
        &mut self,
        widgets: &mut Self::Widgets,
        message: Self::Input,
        sender: ComponentSender<Self>,
        root: &Self::Root,
    ) {
        match message {
            AppMsg::Dist(ev) => self.on_dist(ev),
            AppMsg::Ui(ev) => self.on_ui(ev),
            AppMsg::ShowAbout => present_about(root),
        }

        if self.dirty {
            let gen = self.view_gen;
            let summary = view_summary(&self.view);
            tracing::info!(gen, %summary, "remount view");
            self.debug = format!("remount #{gen} · {summary}");
            render::mount_view(
                root,
                &widgets.content_host,
                &self.view,
                &self.entry_drafts,
                self.ui_tx.clone(),
            );
            self.dirty = false;
        }

        self.update_view(widgets, sender);
    }
}

impl AppModel {
    fn header_subtitle(&self) -> String {
        if self.view.subtitle.is_empty() {
            self.boot_detail.clone()
        } else {
            format!("{} · {}", self.view.subtitle, self.boot_detail)
        }
    }

    fn accept_view(&mut self, v: View, peer: &str) {
        let summary = view_summary(&v);
        tracing::info!(%peer, %summary, "view ok");
        self.view = v;
        self.view_gen = self.view_gen.wrapping_add(1);
        self.dirty = true;
        self.boot_detail = format!("view from {peer}");
        self.debug = format!("ok #{gen} · {summary}", gen = self.view_gen);
    }

    fn on_dist(&mut self, ev: DistEvent) {
        match ev {
            DistEvent::Ready {
                local_node,
                port,
                process_name,
            } => {
                self.boot_detail = format!("dist :{port} as {process_name}");
                self.debug = format!("ready {local_node}:{port}");
                if self.view.title == "freeq-gtk" {
                    self.view = View::waiting(
                        &local_node,
                        &format!("listening :{port} — waiting for full View from Gleam"),
                    );
                    self.view_gen = self.view_gen.wrapping_add(1);
                    self.dirty = true;
                }
            }
            DistEvent::PeerConnected { peer } => {
                self.boot_detail = format!("peer {peer}");
                self.debug = format!("peer connected {peer}");
                self.last_peer = Some(peer);
            }
            DistEvent::PeerDisconnected { peer } => {
                self.boot_detail = format!("lost {peer}");
                self.debug = format!("peer lost {peer}");
            }
            DistEvent::Error(e) => {
                self.boot_detail = e.clone();
                self.debug = format!("error: {e}");
                tracing::warn!(%e, "dist error");
            }
            DistEvent::Inbound { peer, msg } => {
                self.last_peer = Some(peer.clone());
                match msg {
                    Inbound::View(v) => self.accept_view(v, &peer),
                    Inbound::DecodeError(e) => {
                        tracing::warn!(%peer, %e, "bad view term");
                        self.boot_detail = "bad view".into();
                        // Keep previous body; surface error in debug strip.
                        let short = if e.len() > 160 {
                            format!("{}…", &e[..160])
                        } else {
                            e
                        };
                        self.debug = format!("decode fail from {peer}: {short}");
                    }
                }
            }
        }
    }

    fn on_ui(&mut self, ev: UiEvent) {
        // Local drafts only — do not ship every keystroke over dist (flood + remount).
        if let UiEvent::Changed { id, text } = &ev {
            self.entry_drafts.insert(id.clone(), text.clone());
            return;
        }
        if let UiEvent::Activate { id, .. } = &ev {
            self.entry_drafts.remove(id);
        }

        let Some(dist) = &self.dist else {
            self.debug = "ui event but no dist".into();
            return;
        };

        let peer = self.last_peer.as_ref().and_then(|p| p.parse().ok());
        let label = match &ev {
            UiEvent::Clicked { id } => format!("click {id}"),
            UiEvent::Activate { id, .. } => format!("activate {id}"),
            UiEvent::Changed { id, .. } => format!("change {id}"),
            UiEvent::Selected { id, index, .. } => format!("select {id}[{index}]"),
        };
        self.debug = format!("→ {label}");
        tracing::info!(?ev, peer = ?self.last_peer, "ui event → beam (live link)");

        let _ = dist.cmd_tx.send(DistCommand::SendTerm {
            peer,
            dest: Some(self.peer_process.clone()),
            term: ev.to_term(),
        });
    }
}

fn present_about(parent: &impl IsA<gtk::Widget>) {
    let dialog = adw::AboutDialog::builder()
        .application_name(APP_NAME)
        .application_icon(APP_ID)
        .developer_name("freeq")
        .version(env!("CARGO_PKG_VERSION"))
        .comments(
            "IRC with AT Protocol identity. Pronounced like freak.\n\n\
             freeq-gtk is a Relm4 renderer: Gleam owns the UI model and \
             pushes full view snapshots over Erlang distribution.",
        )
        .website("https://freeq.at")
        .issue_url("https://github.com/freeq-at/freeq")
        .license_type(gtk::License::Apache20)
        .copyright("© freeq contributors")
        .build();

    dialog.add_link("Web client", "https://irc.freeq.at");
    dialog.add_link("Documentation", "https://freeq.at");

    let debug = format!(
        "application-id: {APP_ID}\n\
         version: {}\n\
         gtk: {}.{}.{}\n\
         libadwaita: {}.{}.{}\n\
         os: {}",
        env!("CARGO_PKG_VERSION"),
        gtk::major_version(),
        gtk::minor_version(),
        gtk::micro_version(),
        adw::major_version(),
        adw::minor_version(),
        adw::micro_version(),
        std::env::consts::OS,
    );
    dialog.set_debug_info(&debug);
    dialog.set_debug_info_filename("freeq-gtk-debug.txt");

    dialog.present(Some(parent));
}

fn view_summary(view: &View) -> String {
    let nodes = count_nodes(&view.body);
    format!(
        "\"{}\" / \"{}\" · {} nodes · {}×{}",
        view.title, view.subtitle, nodes, view.width, view.height
    )
}

fn count_nodes(n: &Node) -> usize {
    match n {
        Node::VBox { children, .. } | Node::HBox { children, .. } => {
            1 + children.iter().map(count_nodes).sum::<usize>()
        }
        Node::Scrolled { child, .. } => 1 + count_nodes(child),
        _ => 1,
    }
}
