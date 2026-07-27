//! Full-window view tree exchanged over Erlang dist.
//!
//! Shape matches Gleam `freeq_web4/ui` custom types:
//! constructors become ETF tuples with a leading atom (snake_case), fields in
//! declaration order. Strings are UTF-8 binaries; bools are `true`/`false`.
//!
//! ## Root
//!
//! ```text
//! {view, Title, Subtitle, Width, Height, Scroll, Body}
//! ```
//!
//! Scroll (Gleam `ui.Scroll`):
//! - `scroll_bottom` — pin log to newest after paint
//! - `scroll_preserve` — do not force scroll
//! - `{scroll_to, Msgid}` — show a specific message
//!
//! ## Nodes
//!
//! ```text
//! {vbox|v_box, Id, Spacing, Children}   (Gleam `VBox` → atom v_box)
//! {hbox|h_box, Id, Spacing, Children}   (Gleam `HBox` → atom h_box)
//! {label, Id, Text, Dim}
//! {button, Id, Label, Style}          Style = normal | suggested | destructive
//! {entry, Id, Text, Placeholder, Password}
//! {list, Id, Items}                   Items = [binary()]
//! {scrolled, Id, Child}
//! {region, Name, Child}               transparent (web Lightspeed region)
//! {msg, MsgRow}                       Phase 3 structured chat row
//! {av, AvPanel}                       Phase 4 voice/video panel
//! separator
//! spacer
//! ```
//!
//! ## AvPanel (`av_panel`, 12 fields after tag)
//!
//! active, call_present, channel, session_id, token, nick, instance,
//! participant_count, muted, camera, authenticated, av_origin
//!
//! ## MsgRow (`msg_row`, 32 fields after tag)
//!
//! id, msgid, kind, nick, color, time, text, own, edited, deleted, highlight,
//! parent_msgid, parent_nick, parent_preview, avatar_url, reactions,
//! can_reply, can_edit, embed_kind, embed_href, embed_title, embed_description,
//! embed_site, embed_domain, embed_image_url, bsky_display, bsky_handle,
//! bsky_text, bsky_likes, bsky_reposts, bsky_time, bsky_avatar
//!
//! reactions = list of `{reaction_chip, emoji, label, mine}`

use eetf::{Atom, Binary, FixInteger, List, Term, Tuple};

/// Where the message scroller should land after this snapshot paints.
///
/// Full remounts destroy the ScrolledWindow, so Gleam owns this intent.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum Scroll {
    /// Pin the chat log to the newest line after layout settles.
    Bottom,
    /// Leave scroll alone (user reading history).
    Preserve,
    /// Scroll so this msgid is visible (search / jump).
    To { msgid: String },
}

/// Complete window description — the only inbound payload that paints the UI.
#[derive(Debug, Clone, PartialEq)]
pub struct View {
    pub title: String,
    pub subtitle: String,
    pub width: i32,
    pub height: i32,
    pub scroll: Scroll,
    pub body: Node,
}

/// One reaction chip on a message.
#[derive(Debug, Clone, PartialEq)]
pub struct ReactionChip {
    pub emoji: String,
    pub label: String,
    pub mine: bool,
}

/// Structured chat row (Phase 3) — freeq-web4 `ui.MsgRow`.
#[derive(Debug, Clone, PartialEq)]
pub struct MsgRow {
    pub id: String,
    pub msgid: String,
    pub kind: String,
    pub nick: String,
    pub color: String,
    pub time: String,
    pub text: String,
    pub own: bool,
    pub edited: bool,
    pub deleted: bool,
    pub highlight: bool,
    pub parent_msgid: String,
    pub parent_nick: String,
    pub parent_preview: String,
    pub avatar_url: String,
    pub reactions: Vec<ReactionChip>,
    pub can_reply: bool,
    pub can_edit: bool,
    pub embed_kind: String,
    pub embed_href: String,
    pub embed_title: String,
    pub embed_description: String,
    pub embed_site: String,
    pub embed_domain: String,
    pub embed_image_url: String,
    pub bsky_display: String,
    pub bsky_handle: String,
    pub bsky_text: String,
    pub bsky_likes: i32,
    pub bsky_reposts: i32,
    pub bsky_time: String,
    pub bsky_avatar: String,
}

/// Voice/video panel snapshot (Phase 4) — freeq-web4 `ui.AvPanel`.
#[derive(Debug, Clone, PartialEq)]
pub struct AvPanel {
    pub active: bool,
    pub call_present: bool,
    pub channel: String,
    pub session_id: String,
    pub token: String,
    pub nick: String,
    pub instance: String,
    pub participant_count: i32,
    pub muted: bool,
    pub camera: bool,
    pub authenticated: bool,
    pub av_origin: String,
}

/// Widget tree node.
#[derive(Debug, Clone, PartialEq)]
pub enum Node {
    VBox {
        id: String,
        spacing: i32,
        children: Vec<Node>,
    },
    HBox {
        id: String,
        spacing: i32,
        children: Vec<Node>,
    },
    Label {
        id: String,
        text: String,
        dim: bool,
    },
    Button {
        id: String,
        label: String,
        style: ButtonStyle,
    },
    Entry {
        id: String,
        text: String,
        placeholder: String,
        password: bool,
    },
    List {
        id: String,
        items: Vec<String>,
    },
    Scrolled {
        id: String,
        child: Box<Node>,
    },
    Separator,
    Spacer,
    /// Phase 3 rich message row.
    Msg { row: MsgRow },
    /// Phase 4 voice/video panel.
    Av { panel: AvPanel },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ButtonStyle {
    Normal,
    Suggested,
    Destructive,
}

/// UI → Gleam events (Gleam owns state; GTK is a dumb renderer).
#[derive(Debug, Clone, PartialEq)]
pub enum UiEvent {
    Clicked { id: String },
    Activate { id: String, text: String },
    Changed { id: String, text: String },
    Selected { id: String, index: i32, item: String },
}

impl View {
    pub fn from_term(term: &Term) -> Result<Self, String> {
        // Phase 5: {view, Title, Subtitle, W, H, Scroll, Body} (len 7).
        // Accept legacy 6-tuple (no Scroll) as Scroll::Bottom for older hosts.
        match term {
            Term::Tuple(t) => {
                let n = t.elements.len();
                if n == 7 {
                    let e = expect_tagged(term, "view", 7)?;
                    Ok(Self {
                        title: term_string(&e[1])?,
                        subtitle: term_string(&e[2])?,
                        width: term_int(&e[3])?,
                        height: term_int(&e[4])?,
                        scroll: Scroll::from_term(&e[5])?,
                        body: Node::from_term(&e[6])?,
                    })
                } else if n == 6 {
                    let e = expect_tagged(term, "view", 6)?;
                    Ok(Self {
                        title: term_string(&e[1])?,
                        subtitle: term_string(&e[2])?,
                        width: term_int(&e[3])?,
                        height: term_int(&e[4])?,
                        scroll: Scroll::Bottom,
                        body: Node::from_term(&e[5])?,
                    })
                } else {
                    Err(format!("view: expected 6 or 7 elements, got {n}"))
                }
            }
            other => Err(format!("expected {{view, …}}, got {other}")),
        }
    }

    /// Bootstrap placeholder shown before the first Gleam snapshot arrives.
    pub fn waiting(local_node: &str, detail: &str) -> Self {
        Self {
            title: "freeq-gtk".into(),
            subtitle: detail.into(),
            width: 720,
            height: 520,
            scroll: Scroll::Preserve,
            body: Node::VBox {
                id: "root".into(),
                spacing: 12,
                children: vec![
                    Node::Label {
                        id: "wait_title".into(),
                        text: "Waiting for Gleam view…".into(),
                        dim: false,
                    },
                    Node::Label {
                        id: "wait_node".into(),
                        text: format!("node {local_node}"),
                        dim: true,
                    },
                    Node::Label {
                        id: "wait_hint".into(),
                        text: format!(
                            "From Gleam/Erlang: net_kernel:connect_node('{local_node}'). \
                             then send a full {{view, …}} snapshot to {{freeq_gtk, '{local_node}'}}."
                        ),
                        dim: true,
                    },
                ],
            },
        }
    }
}

impl Scroll {
    fn from_term(term: &Term) -> Result<Self, String> {
        match term {
            Term::Atom(a) if a.name == "scroll_bottom" => Ok(Self::Bottom),
            Term::Atom(a) if a.name == "scroll_preserve" => Ok(Self::Preserve),
            Term::Tuple(t) if !t.elements.is_empty() => {
                match &t.elements[0] {
                    Term::Atom(a) if a.name == "scroll_to" => {
                        let e = expect_len(&t.elements, 2, "scroll_to")?;
                        Ok(Self::To {
                            msgid: term_string(&e[1])?,
                        })
                    }
                    Term::Atom(a) => Err(format!("unknown scroll tag '{}'", a.name)),
                    _ => Err(format!("scroll tag not atom: {term}")),
                }
            }
            other => Err(format!("not a scroll policy: {other}")),
        }
    }
}

impl Node {
    pub fn from_term(term: &Term) -> Result<Self, String> {
        match term {
            Term::Atom(a) if a.name == "separator" => Ok(Self::Separator),
            Term::Atom(a) if a.name == "spacer" => Ok(Self::Spacer),
            Term::Tuple(t) if !t.elements.is_empty() => {
                let tag = match &t.elements[0] {
                    Term::Atom(a) => a.name.as_str(),
                    _ => return Err(format!("node tag not atom: {term}")),
                };
                match tag {
                    // Gleam encodes multi-capital constructors as snake_case:
                    // `VBox` → `v_box`, `HBox` → `h_box`. Accept both spellings.
                    "vbox" | "v_box" => {
                        let e = expect_len(&t.elements, 4, "vbox")?;
                        Ok(Self::VBox {
                            id: term_string(&e[1])?,
                            spacing: term_int(&e[2])?,
                            children: term_node_list(&e[3])?,
                        })
                    }
                    "hbox" | "h_box" => {
                        let e = expect_len(&t.elements, 4, "hbox")?;
                        Ok(Self::HBox {
                            id: term_string(&e[1])?,
                            spacing: term_int(&e[2])?,
                            children: term_node_list(&e[3])?,
                        })
                    }
                    "label" => {
                        let e = expect_len(&t.elements, 4, "label")?;
                        Ok(Self::Label {
                            id: term_string(&e[1])?,
                            text: term_string(&e[2])?,
                            dim: term_bool(&e[3])?,
                        })
                    }
                    "button" => {
                        let e = expect_len(&t.elements, 4, "button")?;
                        Ok(Self::Button {
                            id: term_string(&e[1])?,
                            label: term_string(&e[2])?,
                            style: ButtonStyle::from_term(&e[3])?,
                        })
                    }
                    "entry" => {
                        let e = expect_len(&t.elements, 5, "entry")?;
                        Ok(Self::Entry {
                            id: term_string(&e[1])?,
                            text: term_string(&e[2])?,
                            placeholder: term_string(&e[3])?,
                            password: term_bool(&e[4])?,
                        })
                    }
                    "list" => {
                        let e = expect_len(&t.elements, 3, "list")?;
                        Ok(Self::List {
                            id: term_string(&e[1])?,
                            items: term_string_list(&e[2])?,
                        })
                    }
                    "scrolled" => {
                        let e = expect_len(&t.elements, 3, "scrolled")?;
                        Ok(Self::Scrolled {
                            id: term_string(&e[1])?,
                            child: Box::new(Self::from_term(&e[2])?),
                        })
                    }
                    // Gleam `Region(name, child)` — web patch boundary only.
                    // GTK is a full-snapshot painter; unwrap to the child.
                    "region" => {
                        let e = expect_len(&t.elements, 3, "region")?;
                        let _name = term_string(&e[1])?;
                        Self::from_term(&e[2])
                    }
                    // Gleam `Msg(row)` — Phase 3 structured chat row.
                    "msg" => {
                        let e = expect_len(&t.elements, 2, "msg")?;
                        Ok(Self::Msg {
                            row: MsgRow::from_term(&e[1])?,
                        })
                    }
                    // Gleam `Av(panel)` — Phase 4 voice/video.
                    "av" => {
                        let e = expect_len(&t.elements, 2, "av")?;
                        Ok(Self::Av {
                            panel: AvPanel::from_term(&e[1])?,
                        })
                    }
                    other => Err(format!("unknown node tag '{other}'")),
                }
            }
            other => Err(format!("expected node tuple/atom, got {other}")),
        }
    }
}

impl AvPanel {
    /// Decode `{av_panel, …}` (13 elements: tag + 12 fields).
    pub fn from_term(term: &Term) -> Result<Self, String> {
        let t = expect_tagged(term, "av_panel", 13)?;
        Ok(Self {
            active: term_bool(&t[1])?,
            call_present: term_bool(&t[2])?,
            channel: term_string(&t[3])?,
            session_id: term_string(&t[4])?,
            token: term_string(&t[5])?,
            nick: term_string(&t[6])?,
            instance: term_string(&t[7])?,
            participant_count: term_int(&t[8])?,
            muted: term_bool(&t[9])?,
            camera: term_bool(&t[10])?,
            authenticated: term_bool(&t[11])?,
            av_origin: term_string(&t[12])?,
        })
    }
}

impl MsgRow {
    /// Decode `{msg_row, …}` (33 elements: tag + 32 fields).
    pub fn from_term(term: &Term) -> Result<Self, String> {
        let t = expect_tagged(term, "msg_row", 33)?;
        Ok(Self {
            id: term_string(&t[1])?,
            msgid: term_string(&t[2])?,
            kind: term_string(&t[3])?,
            nick: term_string(&t[4])?,
            color: term_string(&t[5])?,
            time: term_string(&t[6])?,
            text: term_string(&t[7])?,
            own: term_bool(&t[8])?,
            edited: term_bool(&t[9])?,
            deleted: term_bool(&t[10])?,
            highlight: term_bool(&t[11])?,
            parent_msgid: term_string(&t[12])?,
            parent_nick: term_string(&t[13])?,
            parent_preview: term_string(&t[14])?,
            avatar_url: term_string(&t[15])?,
            reactions: term_reaction_list(&t[16])?,
            can_reply: term_bool(&t[17])?,
            can_edit: term_bool(&t[18])?,
            embed_kind: term_string(&t[19])?,
            embed_href: term_string(&t[20])?,
            embed_title: term_string(&t[21])?,
            embed_description: term_string(&t[22])?,
            embed_site: term_string(&t[23])?,
            embed_domain: term_string(&t[24])?,
            embed_image_url: term_string(&t[25])?,
            bsky_display: term_string(&t[26])?,
            bsky_handle: term_string(&t[27])?,
            bsky_text: term_string(&t[28])?,
            bsky_likes: term_int(&t[29])?,
            bsky_reposts: term_int(&t[30])?,
            bsky_time: term_string(&t[31])?,
            bsky_avatar: term_string(&t[32])?,
        })
    }

    /// One-line plain text for GTK (compact chat log).
    pub fn display_line(&self) -> String {
        let nick = if self.nick.is_empty() {
            "*"
        } else {
            self.nick.as_str()
        };
        let prefix = match self.kind.as_str() {
            "notice" => "· notice · ",
            "join" => "→ ",
            "part" => "← ",
            "quit" => "✕ ",
            _ => "",
        };
        let body = if self.deleted {
            "(deleted)"
        } else {
            self.text.as_str()
        };
        let edited = if self.edited { "  (edited)" } else { "" };
        let time = if self.time.is_empty() {
            String::new()
        } else {
            format!("{}  ", self.time)
        };
        let mut line = format!("{time}{prefix}{nick}: {body}{edited}");
        if !self.parent_preview.is_empty() || !self.parent_nick.is_empty() {
            let who = if self.parent_nick.is_empty() {
                "msg"
            } else {
                self.parent_nick.as_str()
            };
            let preview = if self.parent_preview.is_empty() {
                String::new()
            } else {
                format!(" — {}", self.parent_preview)
            };
            line = format!("↪ {who}{preview}\n{line}");
        }
        if !self.reactions.is_empty() {
            let chips: Vec<&str> = self.reactions.iter().map(|c| c.label.as_str()).collect();
            line.push_str("\n  ");
            line.push_str(&chips.join("  "));
        }
        if !self.embed_href.is_empty() {
            let title = if self.embed_title.is_empty() {
                self.embed_href.as_str()
            } else {
                self.embed_title.as_str()
            };
            line.push_str(&format!("\n  🔗 {title}"));
        }
        line
    }
}

fn term_reaction_list(term: &Term) -> Result<Vec<ReactionChip>, String> {
    match term {
        Term::List(List { elements })
        | Term::ImproperList(eetf::ImproperList { elements, .. }) => {
            elements.iter().map(ReactionChip::from_term).collect()
        }
        Term::Atom(a) if a.name == "nil" => Ok(vec![]),
        other => Err(format!("expected reaction list, got {other}")),
    }
}

impl ReactionChip {
    fn from_term(term: &Term) -> Result<Self, String> {
        let t = expect_tagged(term, "reaction_chip", 4)?;
        Ok(Self {
            emoji: term_string(&t[1])?,
            label: term_string(&t[2])?,
            mine: term_bool(&t[3])?,
        })
    }
}

impl ButtonStyle {
    fn from_term(term: &Term) -> Result<Self, String> {
        match term {
            Term::Atom(a) => match a.name.as_str() {
                "normal" => Ok(Self::Normal),
                "suggested" => Ok(Self::Suggested),
                "destructive" => Ok(Self::Destructive),
                other => Err(format!("unknown button style '{other}'")),
            },
            // Gleam zero-arity constructors may still be atoms.
            other => Err(format!("button style not atom: {other}")),
        }
    }
}

impl UiEvent {
    pub fn to_term(&self) -> Term {
        match self {
            Self::Clicked { id } => tagged2("clicked", bin(id)),
            Self::Activate { id, text } => tagged3("activate", bin(id), bin(text)),
            Self::Changed { id, text } => tagged3("changed", bin(id), bin(text)),
            Self::Selected { id, index, item } => Tuple {
                elements: vec![
                    Atom::from("selected").into(),
                    bin(id),
                    FixInteger::from(*index).into(),
                    bin(item),
                ],
            }
            .into(),
        }
    }
}

fn tagged2(tag: &str, a: Term) -> Term {
    Tuple {
        elements: vec![Atom::from(tag).into(), a],
    }
    .into()
}

fn tagged3(tag: &str, a: Term, b: Term) -> Term {
    Tuple {
        elements: vec![Atom::from(tag).into(), a, b],
    }
    .into()
}

fn bin(s: &str) -> Term {
    Binary::from(s.as_bytes()).into()
}

fn expect_tagged<'a>(term: &'a Term, tag: &str, len: usize) -> Result<&'a [Term], String> {
    match term {
        Term::Tuple(t) => {
            let e = expect_len(&t.elements, len, tag)?;
            match &e[0] {
                Term::Atom(a) if a.name == tag => Ok(e),
                Term::Atom(a) => Err(format!("expected '{tag}', got '{}'", a.name)),
                _ => Err(format!("expected tagged '{tag}'")),
            }
        }
        other => Err(format!("expected {{{tag}, …}}, got {other}")),
    }
}

fn expect_len<'a>(elements: &'a [Term], len: usize, ctx: &str) -> Result<&'a [Term], String> {
    if elements.len() != len {
        Err(format!(
            "{ctx}: expected {len} elements, got {}",
            elements.len()
        ))
    } else {
        Ok(elements)
    }
}

fn term_string(term: &Term) -> Result<String, String> {
    match term {
        Term::Binary(b) => Ok(String::from_utf8_lossy(&b.bytes).into_owned()),
        Term::BitBinary(b) => Ok(String::from_utf8_lossy(&b.bytes).into_owned()),
        Term::Atom(a) => Ok(a.name.clone()),
        Term::List(list) => {
            if list.elements.is_empty() {
                return Ok(String::new());
            }
            let bytes: Result<Vec<u8>, _> = list
                .elements
                .iter()
                .map(|t| match t {
                    Term::FixInteger(i) if (0..=255).contains(&i.value) => Ok(i.value as u8),
                    _ => Err(()),
                })
                .collect();
            match bytes {
                Ok(b) if b.len() == list.elements.len() => {
                    Ok(String::from_utf8_lossy(&b).into_owned())
                }
                _ => Err(format!("not a string: {term}")),
            }
        }
        other => Err(format!("not a string: {other}")),
    }
}

fn term_int(term: &Term) -> Result<i32, String> {
    match term {
        Term::FixInteger(i) => Ok(i.value),
        Term::BigInteger(b) => b
            .value
            .to_string()
            .parse()
            .map_err(|_| format!("int out of range: {term}")),
        other => Err(format!("not an int: {other}")),
    }
}

fn term_bool(term: &Term) -> Result<bool, String> {
    match term {
        Term::Atom(a) if a.name == "true" => Ok(true),
        Term::Atom(a) if a.name == "false" => Ok(false),
        other => Err(format!("not a bool: {other}")),
    }
}

fn term_node_list(term: &Term) -> Result<Vec<Node>, String> {
    match term {
        Term::List(List { elements }) | Term::ImproperList(eetf::ImproperList { elements, .. }) => {
            elements.iter().map(Node::from_term).collect()
        }
        // Some encoders use the nil atom for [].
        Term::Atom(a) if a.name == "nil" => Ok(vec![]),
        other => Err(format!("expected node list, got {other}")),
    }
}

fn term_string_list(term: &Term) -> Result<Vec<String>, String> {
    match term {
        Term::List(List { elements }) => elements.iter().map(term_string).collect(),
        other => Err(format!("expected string list, got {other}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_view_term() -> Term {
        // Mirrors freeq_gtk_view.sample_view() on the Gleam side.
        let items = List {
            elements: vec![
                Binary::from(b"[#playground] alice: hi".as_slice()).into(),
                Binary::from(b"[#playground] bob: yo".as_slice()).into(),
            ],
        };
        let body = Tuple {
            elements: vec![
                Atom::from("vbox").into(),
                Binary::from(b"root".as_slice()).into(),
                FixInteger::from(8).into(),
                List {
                    elements: vec![
                        Tuple {
                            elements: vec![
                                Atom::from("label").into(),
                                Binary::from(b"topic".as_slice()).into(),
                                Binary::from(b"welcome".as_slice()).into(),
                                Atom::from("true").into(),
                            ],
                        }
                        .into(),
                        Tuple {
                            elements: vec![
                                Atom::from("scrolled").into(),
                                Binary::from(b"log_scroll".as_slice()).into(),
                                Tuple {
                                    elements: vec![
                                        Atom::from("list").into(),
                                        Binary::from(b"log".as_slice()).into(),
                                        items.into(),
                                    ],
                                }
                                .into(),
                            ],
                        }
                        .into(),
                        Tuple {
                            elements: vec![
                                Atom::from("hbox").into(),
                                Binary::from(b"composer".as_slice()).into(),
                                FixInteger::from(8).into(),
                                List {
                                    elements: vec![
                                        Tuple {
                                            elements: vec![
                                                Atom::from("entry").into(),
                                                Binary::from(b"input".as_slice()).into(),
                                                Binary::from(b"".as_slice()).into(),
                                                Binary::from(b"Message...".as_slice()).into(),
                                                Atom::from("false").into(),
                                            ],
                                        }
                                        .into(),
                                        Tuple {
                                            elements: vec![
                                                Atom::from("button").into(),
                                                Binary::from(b"send".as_slice()).into(),
                                                Binary::from(b"Send".as_slice()).into(),
                                                Atom::from("suggested").into(),
                                            ],
                                        }
                                        .into(),
                                    ],
                                }
                                .into(),
                            ],
                        }
                        .into(),
                    ],
                }
                .into(),
            ],
        };
        Tuple {
            elements: vec![
                Atom::from("view").into(),
                Binary::from(b"freeq".as_slice()).into(),
                Binary::from(b"#playground".as_slice()).into(),
                FixInteger::from(720).into(),
                FixInteger::from(520).into(),
                body.into(),
            ],
        }
        .into()
    }

    #[test]
    fn decode_sample_view() {
        let v = View::from_term(&sample_view_term()).expect("decode");
        assert_eq!(v.title, "freeq");
        assert_eq!(v.subtitle, "#playground");
        // Legacy 6-field view defaults to Bottom.
        assert_eq!(v.scroll, Scroll::Bottom);
        match v.body {
            Node::VBox { children, .. } => assert_eq!(children.len(), 3),
            other => panic!("unexpected body {other:?}"),
        }
    }

    #[test]
    fn decode_view_with_scroll() {
        let body = Tuple {
            elements: vec![
                Atom::from("vbox").into(),
                Binary::from(b"root".as_slice()).into(),
                FixInteger::from(0).into(),
                List { elements: vec![] }.into(),
            ],
        };
        let term = Tuple {
            elements: vec![
                Atom::from("view").into(),
                Binary::from(b"freeq".as_slice()).into(),
                Binary::from(b"#test".as_slice()).into(),
                FixInteger::from(800).into(),
                FixInteger::from(600).into(),
                Atom::from("scroll_bottom").into(),
                body.into(),
            ],
        }
        .into();
        let v = View::from_term(&term).expect("decode");
        assert_eq!(v.scroll, Scroll::Bottom);

        let term_to = Tuple {
            elements: vec![
                Atom::from("view").into(),
                Binary::from(b"freeq".as_slice()).into(),
                Binary::from(b"#test".as_slice()).into(),
                FixInteger::from(800).into(),
                FixInteger::from(600).into(),
                Tuple {
                    elements: vec![
                        Atom::from("scroll_to").into(),
                        Binary::from(b"mid-1".as_slice()).into(),
                    ],
                }
                .into(),
                Tuple {
                    elements: vec![
                        Atom::from("vbox").into(),
                        Binary::from(b"root".as_slice()).into(),
                        FixInteger::from(0).into(),
                        List { elements: vec![] }.into(),
                    ],
                }
                .into(),
            ],
        }
        .into();
        let v2 = View::from_term(&term_to).expect("decode scroll_to");
        assert_eq!(
            v2.scroll,
            Scroll::To {
                msgid: "mid-1".into()
            }
        );
    }

    #[test]
    fn encode_clicked() {
        let t = UiEvent::Clicked { id: "send".into() }.to_term();
        match t {
            Term::Tuple(tup) => {
                assert!(matches!(&tup.elements[0], Term::Atom(a) if a.name == "clicked"));
            }
            _ => panic!("expected tuple"),
        }
    }

    #[test]
    fn decode_av_panel() {
        let fields: Vec<Term> = vec![
            Atom::from("av_panel").into(),
            Atom::from("true").into(),
            Atom::from("false").into(),
            Binary::from(b"#freeq".as_slice()).into(),
            Binary::from(b"01SID".as_slice()).into(),
            Binary::from(b"tok".as_slice()).into(),
            Binary::from(b"alice".as_slice()).into(),
            Binary::from(b"deadbeef".as_slice()).into(),
            FixInteger::from(2).into(),
            Atom::from("false").into(),
            Atom::from("true").into(),
            Atom::from("true").into(),
            Binary::from(b"https://irc.freeq.at".as_slice()).into(),
        ];
        assert_eq!(fields.len(), 13);
        let panel_term = Tuple { elements: fields }.into();
        let av_term = Tuple {
            elements: vec![Atom::from("av").into(), panel_term],
        }
        .into();
        match Node::from_term(&av_term).expect("decode av") {
            Node::Av { panel } => {
                assert!(panel.active);
                assert_eq!(panel.channel, "#freeq");
                assert_eq!(panel.session_id, "01SID");
                assert_eq!(panel.participant_count, 2);
                assert!(panel.camera);
            }
            other => panic!("expected Av, got {other:?}"),
        }
    }

    #[test]
    fn decode_msg_row() {
        // {msg, {msg_row, …32 fields}}
        let chip = Tuple {
            elements: vec![
                Atom::from("reaction_chip").into(),
                Binary::from(b"\xf0\x9f\x91\x8d".as_slice()).into(), // 👍
                Binary::from(b"\xf0\x9f\x91\x8d 2".as_slice()).into(),
                Atom::from("true").into(),
            ],
        };
        let mut fields: Vec<Term> = vec![Atom::from("msg_row").into()];
        let strings = [
            "msg:m1:0", "m1", "msg", "alice", "n1", "12:00", "hello",
        ];
        for s in strings {
            fields.push(Binary::from(s.as_bytes()).into());
        }
        for b in [false, false, false, false] {
            fields.push(Atom::from(if b { "true" } else { "false" }).into());
        }
        for s in ["", "", "", ""] {
            fields.push(Binary::from(s.as_bytes()).into());
        }
        fields.push(
            List {
                elements: vec![chip.into()],
            }
            .into(),
        );
        for b in [true, false] {
            fields.push(Atom::from(if b { "true" } else { "false" }).into());
        }
        for s in ["", "", "", "", "", "", "", "", "", ""] {
            fields.push(Binary::from(s.as_bytes()).into());
        }
        fields.push(FixInteger::from(0).into());
        fields.push(FixInteger::from(0).into());
        fields.push(Binary::from(b"".as_slice()).into());
        fields.push(Binary::from(b"".as_slice()).into());
        assert_eq!(fields.len(), 33);
        let row_term = Tuple { elements: fields }.into();
        let msg_term = Tuple {
            elements: vec![Atom::from("msg").into(), row_term],
        }
        .into();
        let node = Node::from_term(&msg_term).expect("decode msg");
        match node {
            Node::Msg { row } => {
                assert_eq!(row.msgid, "m1");
                assert_eq!(row.nick, "alice");
                assert_eq!(row.text, "hello");
                assert!(row.can_reply);
                assert_eq!(row.reactions.len(), 1);
                assert!(row.reactions[0].mine);
                assert!(row.display_line().contains("alice"));
            }
            other => panic!("expected Msg, got {other:?}"),
        }
    }
}
