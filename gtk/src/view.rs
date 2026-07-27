//! Full-window view tree exchanged over Erlang dist.
//!
//! Shape matches Gleam custom types in `gleam/src/freeq_gtk_view.gleam`:
//! constructors become ETF tuples with a leading atom (snake_case), fields in
//! declaration order. Strings are UTF-8 binaries; bools are `true`/`false`.
//!
//! ## Root
//!
//! ```text
//! {view, Title, Subtitle, Width, Height, Body}
//! ```
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
//! separator
//! spacer
//! ```

use eetf::{Atom, Binary, FixInteger, List, Term, Tuple};

/// Complete window description — the only inbound payload that paints the UI.
#[derive(Debug, Clone, PartialEq)]
pub struct View {
    pub title: String,
    pub subtitle: String,
    pub width: i32,
    pub height: i32,
    pub body: Node,
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
        let t = expect_tagged(term, "view", 6)?;
        Ok(Self {
            title: term_string(&t[1])?,
            subtitle: term_string(&t[2])?,
            width: term_int(&t[3])?,
            height: term_int(&t[4])?,
            body: Node::from_term(&t[5])?,
        })
    }

    /// Bootstrap placeholder shown before the first Gleam snapshot arrives.
    pub fn waiting(local_node: &str, detail: &str) -> Self {
        Self {
            title: "freeq-gtk".into(),
            subtitle: detail.into(),
            width: 720,
            height: 520,
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
                    other => Err(format!("unknown node tag '{other}'")),
                }
            }
            other => Err(format!("expected node tuple/atom, got {other}")),
        }
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
        match v.body {
            Node::VBox { children, .. } => assert_eq!(children.len(), 3),
            other => panic!("unexpected body {other:?}"),
        }
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
}
