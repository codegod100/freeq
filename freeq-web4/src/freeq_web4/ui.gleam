//// Canonical presentation tree for freeq-web4.
////
//// One View tree is the UI surface:
//// - freeq-gtk paints it over Erlang dist (ETF; field order is the API)
//// - LiveView translates the same tree to HTML/CSS (`ui/html`)
////
//// Types only — no import of `live` (avoids cycles with LiveView paint).
//// Build with `ui/build.from_model`; events with `ui/build.to_msg`.
////
//// Wire format matches freeq-gtk Rust decoder:
//// tagged Gleam constructors → ETF tuples/atoms.
////
//// Layout conventions (Rust render uses node ids):
//// - `chat_col` — expands to fill width
//// - `user_panel` — fixed right rail (~280px)
//// - `log` — message column; children are wrapping labels (not ListBox)

// ── Tree ─────────────────────────────────────────────────────────────────────

pub type View {
  View(
    title: String,
    subtitle: String,
    width: Int,
    height: Int,
    body: Node,
  )
}

pub type Node {
  VBox(id: String, spacing: Int, children: List(Node))
  HBox(id: String, spacing: Int, children: List(Node))
  Label(id: String, text: String, dim: Bool)
  Button(id: String, label: String, style: ButtonStyle)
  Entry(id: String, text: String, placeholder: String, password: Bool)
  List(id: String, items: List(String))
  Scrolled(id: String, child: Node)
  Separator
  Spacer
  /// Lightspeed patch boundary. Web: `data-ls-region="name"`. GTK: transparent
  /// (render `child` only). Stable names: nav, sidebar, main, messages,
  /// compose, flash, members, av, search, …
  Region(name: String, child: Node)
}

pub type ButtonStyle {
  Normal
  Suggested
  Destructive
}

// ── Events from GTK ──────────────────────────────────────────────────────────

pub type Event {
  Clicked(id: String)
  Activate(id: String, text: String)
  Changed(id: String, text: String)
  Selected(id: String, index: Int, item: String)
  Unknown(raw: String)
}
