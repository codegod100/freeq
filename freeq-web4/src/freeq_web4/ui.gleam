//// Canonical presentation tree for freeq-web4.
////
//// One View tree is the UI surface:
//// - freeq-gtk paints it over Erlang dist (ETF; field order is the API)
//// - LiveView translates the same tree to HTML/CSS (`ui/html`)
////
//// Types only — no import of `live` (avoids cycles with LiveView paint).
//// Build with `live.view_tree`; events with `live.ui_to_msg`.
////
//// Wire format matches freeq-gtk Rust decoder:
//// tagged Gleam constructors → ETF tuples/atoms.
////
//// Layout conventions (Rust render uses node ids):
//// - `chat_col` — expands to fill width
//// - `user_panel` — fixed right rail (~280px)
//// - `log` / `log_scroll` — message column; children are Msg rows
//// - `Av(panel)` — call chrome + web media host island (`#av-call-panel`)
////
//// ## Isomorphic paint (freeq-gtk)
////
//// The View tree *is* the UI. GTK should:
//// 1. Keep widgets for stable ids when chrome is unchanged (esp. `log_scroll`)
//// 2. Patch only log children when messages change (send / live tail)
//// 3. Apply `View.scroll` as pure data after paint — no client policy that
////    invents a different scroll position than the snapshot
////
//// Full destroy/rebuild of the log scroller on every PRIVMSG is what made
//// “send jumps to old times” — that path is intentionally not isomorphic.

// ── Tree ─────────────────────────────────────────────────────────────────────

/// Where the primary message scroller should land after this snapshot paints.
///
/// Full-snapshot renderers (freeq-gtk) destroy the ScrolledWindow on every
/// push, so scroll position cannot live only in the client — Gleam must
/// declare intent on each View. Web can also honor this via `data-scroll-*`.
///
/// Field / wire order is the ETF API:
/// - `ScrollBottom` → atom `scroll_bottom`
/// - `ScrollPreserve` → atom `scroll_preserve`
/// - `ScrollTo(msgid)` → `{scroll_to, Msgid}`
pub type Scroll {
  /// Pin the log to the newest line (channel open, own send, live tail).
  ScrollBottom
  /// Do not force scroll (user is reading history above the fold).
  ScrollPreserve
  /// Bring a specific msgid into view (search / jump / highlight).
  ScrollTo(msgid: String)
}

pub type View {
  View(
    title: String,
    subtitle: String,
    width: Int,
    height: Int,
    /// Message-log scroll policy for this paint (see [`Scroll`]).
    scroll: Scroll,
    body: Node,
  )
}

/// One reaction chip on a message (emoji + display label + whether mine).
pub type ReactionChip {
  ReactionChip(emoji: String, label: String, mine: Bool)
}

/// Voice/video call snapshot for the shared View tree.
///
/// One node describes the whole AV surface:
/// - **Web**: paints `#av-call-panel` + `data-*` so `av_call.js` owns MoQ media
/// - **GTK**: status line + mute/camera/leave (no media plane yet)
///
/// Field order is the ETF API (do not reorder). Empty strings mean “none”.
/// When `active` is False the panel is idle (empty region / join affordance only).
pub type AvPanel {
  AvPanel(
    active: Bool,
    /// Someone else has a live call on the viewed channel (join affordance).
    call_present: Bool,
    channel: String,
    session_id: String,
    /// MoQ JWT (web host only; GTK may ignore).
    token: String,
    nick: String,
    instance: String,
    participant_count: Int,
    muted: Bool,
    camera: Bool,
    authenticated: Bool,
    /// freeq-server origin for MoQ (`config.av_origin()`).
    av_origin: String,
  )
}

/// Structured chat row — web paints freeq CSS; GTK paints a multi-line block.
///
/// Field order is the ETF API (do not reorder). Empty strings mean “none”.
pub type MsgRow {
  MsgRow(
    id: String,
    msgid: String,
    kind: String,
    nick: String,
    color: String,
    time: String,
    text: String,
    own: Bool,
    edited: Bool,
    deleted: Bool,
    highlight: Bool,
    parent_msgid: String,
    parent_nick: String,
    parent_preview: String,
    avatar_url: String,
    reactions: List(ReactionChip),
    can_reply: Bool,
    can_edit: Bool,
    /// Embed card (link preview). Empty href ⇒ no card.
    embed_kind: String,
    embed_href: String,
    embed_title: String,
    embed_description: String,
    embed_site: String,
    embed_domain: String,
    embed_image_url: String,
    bsky_display: String,
    bsky_handle: String,
    bsky_text: String,
    bsky_likes: Int,
    bsky_reposts: Int,
    bsky_time: String,
    bsky_avatar: String,
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
  /// compose, flash, members, av, search, react-picker, …
  Region(name: String, child: Node)
  /// Rich channel / system message row (Phase 3).
  Msg(row: MsgRow)
  /// Voice/video call panel (Phase 4). Always present under Region("av").
  Av(panel: AvPanel)
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
