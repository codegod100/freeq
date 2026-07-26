//// Channel / navigation pane state machine for freeq-web4.
////
//// Replaces the loose bundle of `view` + `channel` + `history_loading` +
//// `history_exhausted` + `join_errors` that could disagree (e.g. Channel
//// shell with a failed JOIN still accepting Send).
////
//// ```
//// Pane
////   Directory
////   System
////   InRoom(RoomState)
////
//// Membership:  Joining → Joined | Blocked(reason)
//// History:     Loading → Ready(exhausted) ⇄ LoadingOlder(exhausted)
//// ```
////
//// Active room **content** (messages / members / topic) stays on the LiveView
//// model; this machine owns **where you are** and **whether you may send**.

import freeq_web4/irc/render
import gleam/option.{type Option, None, Some}
import gleam/string

// ── Pane ─────────────────────────────────────────────────────────────────────

/// Where the chat shell is focused.
pub type Pane {
  /// Channel directory (`/chat`).
  Directory
  /// Local System buffer (`/chat/system`) — not an IRC channel.
  System
  /// IRC channel shell (`/chat/:name`).
  InRoom(RoomState)
}

/// Active IRC channel shell: name + membership + history lifecycle.
pub type RoomState {
  RoomState(
    /// Canonical `#name`.
    name: String,
    membership: Membership,
    history: History,
  )
}

/// JOIN lifecycle for the room currently on screen.
pub type Membership {
  /// JOIN sent / in flight — do not treat as confirmed yet.
  Joining
  /// 353 / self JOIN confirmed — PRIVMSG allowed (when WS ready).
  Joined
  /// 477 / 471 / 404 / … — Send must flash, never silent-drop.
  Blocked(reason: String)
}

/// REST / scroll history lifecycle for the room on screen.
pub type History {
  /// Cold open — waiting for REST (or first paint spinner).
  Loading
  /// Body present; `exhausted` = no older page above.
  Ready(exhausted: Bool)
  /// Scroll-up older page in flight; body already shown.
  LoadingOlder(exhausted: Bool)
}

// ── Construction ─────────────────────────────────────────────────────────────

pub fn directory() -> Pane {
  Directory
}

pub fn system() -> Pane {
  System
}

/// Cold open: empty pane, history spinning, membership unconfirmed.
pub fn open_cold(name: String) -> Pane {
  InRoom(RoomState(name: canon(name), membership: Joining, history: Loading))
}

/// Cache hit: body ready, still re-JOIN (membership Joining until 353).
pub fn open_cached(name: String, exhausted: Bool) -> Pane {
  InRoom(
    RoomState(
      name: canon(name),
      membership: Joining,
      history: Ready(exhausted),
    ),
  )
}

pub fn from_path(path: String) -> Pane {
  let path = case string.ends_with(path, "/") && string.length(path) > 1 {
    True -> string.drop_end(path, 1)
    False -> path
  }
  case path {
    "/" | "/chat" | "" -> Directory
    "/chat/system" -> System
    _ ->
      case string.starts_with(path, "/chat/") {
        False -> Directory
        True -> {
          let bare = string.drop_start(path, 6)
          case bare == "", is_system_key(bare) {
            True, _ -> Directory
            _, True -> System
            False, False -> open_cold(render.canonical_channel(bare))
          }
        }
      }
  }
}

// ── Queries ──────────────────────────────────────────────────────────────────

pub fn is_directory(p: Pane) -> Bool {
  case p {
    Directory -> True
    System | InRoom(_) -> False
  }
}

pub fn is_system(p: Pane) -> Bool {
  case p {
    System -> True
    Directory | InRoom(_) -> False
  }
}

pub fn is_room(p: Pane) -> Bool {
  case p {
    InRoom(_) -> True
    Directory | System -> False
  }
}

/// Canonical channel when focused on a room.
pub fn channel(p: Pane) -> Option(String) {
  case p {
    InRoom(r) -> Some(r.name)
    Directory | System -> None
  }
}

/// True when `p` is already that room (case-insensitive IRC name).
pub fn same_room(p: Pane, name: String) -> Bool {
  case p {
    InRoom(r) -> channel_key(r.name) == channel_key(name)
    Directory | System -> False
  }
}

pub fn history_loading(p: Pane) -> Bool {
  case p {
    InRoom(RoomState(history: Loading, ..)) -> True
    InRoom(RoomState(history: LoadingOlder(_), ..)) -> True
    _ -> False
  }
}

/// Spinner on cold open only (not scroll-up “loading older”).
pub fn history_cold_loading(p: Pane) -> Bool {
  case p {
    InRoom(RoomState(history: Loading, ..)) -> True
    _ -> False
  }
}

pub fn history_exhausted(p: Pane) -> Bool {
  case p {
    InRoom(RoomState(history: Ready(e), ..)) -> e
    InRoom(RoomState(history: LoadingOlder(e), ..)) -> e
    InRoom(RoomState(history: Loading, ..)) -> False
    Directory | System -> True
  }
}

/// Reason send is blocked by membership, if any (independent of WS phase).
///
/// Only `Blocked` (477/404/…) stops Send. `Joining` still allows wire send
/// (server may 404 — that transitions to Blocked). Directory/System never send.
pub fn send_block_reason(p: Pane) -> Option(String) {
  case p {
    InRoom(RoomState(membership: Blocked(reason), name: name, ..)) ->
      Some(case string.trim(reason) {
        "" -> "Not in " <> name
        r -> r
      })
    InRoom(RoomState(membership: Joining, ..)) -> None
    InRoom(RoomState(membership: Joined, ..)) -> None
    Directory | System -> Some("Join a channel first")
  }
}

/// Channel name when the pane is a room that may receive PRIVMSG.
pub fn send_target(p: Pane) -> Option(String) {
  case p {
    InRoom(RoomState(membership: Blocked(_), ..)) -> None
    InRoom(RoomState(name: name, membership: Joining, ..)) -> Some(name)
    InRoom(RoomState(name: name, membership: Joined, ..)) -> Some(name)
    Directory | System -> None
  }
}

pub fn browser_path(p: Pane) -> String {
  case p {
    Directory -> "/chat"
    System -> "/chat/system"
    InRoom(r) -> "/chat/" <> render.bare_channel(r.name)
  }
}

// ── Transitions ──────────────────────────────────────────────────────────────

/// REST history body landed for the room on screen.
pub fn history_ready(p: Pane, exhausted: Bool) -> Pane {
  case p {
    InRoom(r) -> InRoom(RoomState(..r, history: Ready(exhausted)))
    Directory | System -> p
  }
}

/// User scrolled up; older page requested.
pub fn history_start_older(p: Pane) -> Pane {
  case p {
    InRoom(RoomState(history: Ready(e), ..) as r) ->
      InRoom(RoomState(..r, history: LoadingOlder(e)))
    InRoom(RoomState(history: LoadingOlder(_), ..)) -> p
    InRoom(RoomState(history: Loading, ..)) -> p
    Directory | System -> p
  }
}

/// Older page returned (or failed empty).
pub fn history_older_done(p: Pane, exhausted: Bool) -> Pane {
  case p {
    InRoom(r) -> InRoom(RoomState(..r, history: Ready(exhausted)))
    Directory | System -> p
  }
}

/// Force exhausted (e.g. no timestamp to page with).
pub fn history_mark_exhausted(p: Pane) -> Pane {
  case p {
    InRoom(r) -> InRoom(RoomState(..r, history: Ready(True)))
    Directory | System -> p
  }
}

/// 353 / self JOIN for `name` — only affects the active room.
pub fn mark_joined(p: Pane, name: String) -> Pane {
  case p {
    InRoom(r) ->
      case channel_key(r.name) == channel_key(name) {
        True -> InRoom(RoomState(..r, membership: Joined))
        False -> p
      }
    Directory | System -> p
  }
}

/// 477 / 404 / join failure for `name`.
pub fn mark_blocked(p: Pane, name: String, reason: String) -> Pane {
  case p {
    InRoom(r) ->
      case channel_key(r.name) == channel_key(name) {
        True -> InRoom(RoomState(..r, membership: Blocked(string.trim(reason))))
        False -> p
      }
    Directory | System -> p
  }
}

/// Re-open policy: clear block so JOIN is retried (membership → Joining).
pub fn remount_joining(p: Pane) -> Pane {
  case p {
    InRoom(r) -> InRoom(RoomState(..r, membership: Joining))
    Directory | System -> p
  }
}

// ── Flash helpers ────────────────────────────────────────────────────────────

pub fn send_blocked_flash(channel: String, reason: String) -> String {
  let reason = string.trim(reason)
  case reason {
    "" -> "Not in " <> channel <> " — cannot send"
    r ->
      case string.contains(string.lowercase(r), "authentication") {
        True ->
          "Cannot send to "
          <> channel
          <> " — sign in required ("
          <> r
          <> ")"
        False -> "Cannot send to " <> channel <> " — " <> r
      }
  }
}

// ── Internals ────────────────────────────────────────────────────────────────

fn canon(name: String) -> String {
  render.canonical_channel(name)
}

fn channel_key(ch: String) -> String {
  string.lowercase(canon(ch))
}

fn is_system_key(raw: String) -> Bool {
  let bare = string.lowercase(string.trim(raw))
  bare == "system" || bare == "#system"
}
