//// Pure HTML renderer for the canonical `ui.View` tree.
////
//// LiveView (Phase 2+) uses `view_html` / `plan_patches` as the web paint path.
//// freeq-gtk still decodes the ETF View tree directly (not this HTML).
////
//// Id conventions (shared with GTK / ui.to_msg):
//// - `send`, `join`, `go_index`, `go_system`, `part` → click / submit actions
//// - `open:<channel>` → open channel
//// - `input` / `join_input` → compose fields
//// - layout ids (`root`, `chat_col`, `user_panel`, `log`, …) → CSS hooks
//// - `Region(name, child)` → `data-ls-region` patch boundary (Lightspeed)
//// - `Msg(row)` → freeq `.row` message (reactions, edit, embeds, …)

import freeq_web4/irc/render
import freeq_web4/ui
import gleam/int
import gleam/list
import gleam/string
import lightspeed/diff

/// Full shell HTML for LiveView / SSR.
///
/// Root uses `#freeq-chat.freeq-root` so existing app.css / client JS still attach.
pub fn view_html(view: ui.View) -> String {
  "<div id=\"freeq-chat\" class=\"freeq-root ui-view\" data-ui-title=\""
  <> escape(view.title)
  <> "\" data-ui-subtitle=\""
  <> escape(view.subtitle)
  <> "\""
  <> scroll_root_attrs(view.scroll)
  <> ">"
  <> "<div class=\"ui-view-meta\" hidden>"
  <> escape(view.subtitle)
  <> "</div>"
  <> node_html(view.body)
  <> "</div>"
}

fn scroll_root_attrs(scroll: ui.Scroll) -> String {
  case scroll {
    ui.ScrollBottom -> " data-scroll=\"bottom\""
    ui.ScrollPreserve -> " data-scroll=\"preserve\""
    ui.ScrollTo(msgid) ->
      " data-scroll=\"to\" data-scroll-to-msgid=\"" <> escape(msgid) <> "\""
  }
}

/// Diff two views by `Region` name. Emits `Replace` patches for regions whose
/// child HTML changed.
pub fn plan_patches(before: ui.View, after: ui.View) -> List(diff.Patch) {
  case before == after {
    True -> []
    False -> {
      let b = region_map(before.body, [])
      let a = region_map(after.body, [])
      list.filter_map(a, fn(pair) {
        let #(name, html_after) = pair
        let html_before = case list.key_find(b, name) {
          Ok(h) -> h
          Error(_) -> ""
        }
        case html_before == html_after {
          True -> Error(Nil)
          False ->
            Ok(diff.Replace(
              target: region_selector(name),
              html: html_after,
            ))
        }
      })
    }
  }
}

/// Recursive HTML for one Node.
pub fn node_html(node: ui.Node) -> String {
  case node {
    ui.VBox(id, spacing, children) ->
      box("v-box", id, spacing, children)

    ui.HBox(id, spacing, children) ->
      box("h-box", id, spacing, children)

    ui.Label(id, text, dim) -> {
      let dim_cls = case dim {
        True -> " ui-label-dim muted"
        False -> ""
      }
      // Empty / system lines still use Label (not MsgRow).
      let #(row_cls, msgid_attr) = case string.split(id, ":") {
        ["msg", mid, ..] if mid != "" -> #(
          " row msg",
          " data-msgid=\"" <> escape(mid) <> "\"",
        )
        _ -> #("", "")
      }
      "<div"
      <> id_attr(id)
      <> msgid_attr
      <> " class=\"ui-label"
      <> row_cls
      <> dim_cls
      <> class_for_id(id)
      <> "\">"
      <> escape(text)
      <> "</div>"
    }

    ui.Button(id, label, style) -> {
      let style_cls = case style {
        ui.Normal -> "ui-btn"
        ui.Suggested -> "ui-btn ui-btn-suggested"
        ui.Destructive -> "ui-btn ui-btn-destructive"
      }
      "<button type=\"button\""
      <> id_attr(id)
      <> " class=\""
      <> style_cls
      <> class_for_id(id)
      <> "\""
      <> click_attrs(id)
      <> ">"
      <> escape(label)
      <> "</button>"
    }

    ui.Entry(id, text, placeholder, password) -> {
      let input_type = case password {
        True -> "password"
        False -> "text"
      }
      let name = entry_name(id)
      // Web compose draft is client-owned (never stamp value= from model).
      // GTK still gets Entry.text from the ETF View, not this HTML path.
      let value_attr = case id {
        "input" | "join_input" -> ""
        _ -> " value=\"" <> escape(text) <> "\""
      }
      case id {
        "input" | "join_input" ->
          "<form"
          <> form_attrs(id)
          <> " class=\"ui-entry-form"
          <> class_for_id(id)
          <> "\">"
          <> "<input"
          <> id_attr(id)
          <> " class=\"ui-entry"
          <> class_for_id(id)
          <> "\" type=\""
          <> input_type
          <> "\" name=\""
          <> name
          <> "\""
          <> value_attr
          <> " placeholder=\""
          <> escape(placeholder)
          <> "\" autocomplete=\"off\" />"
          <> submit_button_for(id)
          <> "</form>"
        _ ->
          "<input"
          <> id_attr(id)
          <> " class=\"ui-entry"
          <> class_for_id(id)
          <> "\" type=\""
          <> input_type
          <> "\" name=\""
          <> name
          <> "\""
          <> value_attr
          <> " placeholder=\""
          <> escape(placeholder)
          <> "\" autocomplete=\"off\" />"
      }
    }

    ui.List(id, items) -> {
      let lis =
        list.map(items, fn(item) {
          "<li class=\"ui-list-item\">" <> escape(item) <> "</li>"
        })
        |> string.concat
      "<ul"
      <> id_attr(id)
      <> " class=\"ui-list"
      <> class_for_id(id)
      <> "\">"
      <> lis
      <> "</ul>"
    }

    ui.Scrolled(id, child) ->
      "<div"
      <> id_attr(id)
      <> " class=\"ui-scrolled"
      <> class_for_id(id)
      <> "\">"
      <> node_html(child)
      <> "</div>"

    ui.Separator -> "<hr class=\"ui-separator\" />"

    ui.Spacer -> "<div class=\"ui-spacer\" aria-hidden=\"true\"></div>"

    ui.Region(name, child) -> region_html(name, child)

    ui.Msg(row) -> msg_row_html(row)

    ui.Av(panel) -> av_panel_html(panel)
  }
}

/// Full AV chrome + media host island. Matches legacy `av_region` so
/// `av_call.js` can rebind on `#av-call-panel` data-* without changes.
fn av_panel_html(panel: ui.AvPanel) -> String {
  case panel.active {
    False -> {
      // Idle: optional “call in progress — join” strip when others are on call.
      case panel.call_present {
        False -> ""
        True -> {
          let n = case panel.participant_count {
            c if c > 0 -> c
            _ -> 1
          }
          let who = case n == 1 {
            True -> "person"
            False -> "people"
          }
          "<div class=\"av-invite-bar\" id=\"av-invite-bar\">"
          <> "<span class=\"av-invite-status\">🔊 Call on "
          <> escape(panel.channel)
          <> " · "
          <> int.to_string(n)
          <> " "
          <> who
          <> "</span>"
          <> "<button type=\"button\" class=\"av-call-action av-join-btn\" data-ls-click=\"av_join\">Join</button>"
          <> "</div>"
        }
      }
    }
    True -> {
      let count = case panel.participant_count {
        n if n > 0 -> n
        _ -> 1
      }
      let panel_class =
        "av-call-panel active"
        <> case panel.camera {
          True -> " is-camera-on"
          False -> ""
        }
        <> case panel.muted {
          True -> " is-muted"
          False -> ""
        }
      let mute_class =
        "av-call-action av-mute-btn"
        <> case panel.muted {
          True -> " muted"
          False -> ""
        }
      let cam_class =
        "av-call-action av-cam-btn"
        <> case panel.camera {
          True -> " on"
          False -> ""
        }
      let mute_label = case panel.muted {
        True -> "🎤 off"
        False -> "🎤 on"
      }
      let mute_title = case panel.muted {
        True -> "Unmute"
        False -> "Mute"
      }
      let cam_label = case panel.camera {
        True -> "📷 on"
        False -> "📷 off"
      }
      let cam_title = case panel.camera {
        True -> "Turn off camera"
        False -> "Turn on camera"
      }
      // Host island: #av-video-grid / publish container are client-owned
      // (data-ls-ignore). Tree still *declares* the shell so one object paints.
      "<div id=\"av-call-panel\" class=\""
      <> panel_class
      <> "\" data-channel=\""
      <> escape(panel.channel)
      <> "\" data-nick=\""
      <> escape(panel.nick)
      <> "\" data-instance=\""
      <> escape(panel.instance)
      <> "\" data-session-id=\""
      <> escape(panel.session_id)
      <> "\" data-moq-token=\""
      <> escape(panel.token)
      <> "\" data-muted=\""
      <> bool_attr(panel.muted)
      <> "\" data-camera=\""
      <> bool_attr(panel.camera)
      <> "\" data-authenticated=\""
      <> bool_attr(panel.authenticated)
      <> "\" data-av-origin=\""
      <> escape(panel.av_origin)
      <> "\">"
      <> "<div class=\"av-call-bar\">"
      <> "<span class=\"av-call-status\">📞 "
      <> escape(panel.channel)
      <> " · "
      <> int.to_string(count)
      <> " in call</span>"
      <> "<div class=\"av-call-actions\">"
      <> "<button type=\"button\" class=\""
      <> mute_class
      <> "\" data-ls-click=\"av_toggle_mute\" title=\""
      <> mute_title
      <> "\">"
      <> mute_label
      <> "</button>"
      <> "<button type=\"button\" class=\""
      <> cam_class
      <> "\" data-ls-click=\"av_toggle_camera\" title=\""
      <> cam_title
      <> "\">"
      <> cam_label
      <> "</button>"
      <> "<button type=\"button\" class=\"av-call-action av-leave-btn\" data-ls-click=\"av_leave\" title=\"Leave call\">Leave</button>"
      <> "</div></div>"
      <> "<div id=\"av-video-grid\" class=\"av-video-grid\" data-ls-ignore>"
      <> "<div class=\"av-tile av-tile-local\" id=\"av-local-tile\" title=\"Click to enlarge\" role=\"button\" tabindex=\"0\">"
      <> "<video id=\"av-local-video\" class=\"av-local-video\" autoplay muted playsinline hidden></video>"
      <> "<div class=\"av-tile-avatar local\">You</div>"
      <> "<span class=\"av-tile-label\">You</span>"
      <> "</div>"
      <> "<div id=\"av-remote-tiles\" class=\"av-remote-tiles\"></div>"
      <> "</div>"
      <> "<div id=\"av-publish-container\" class=\"av-publish-container\" data-ls-ignore></div>"
      <> "</div>"
    }
  }
}

fn bool_attr(b: Bool) -> String {
  case b {
    True -> "true"
    False -> "false"
  }
}

fn msg_row_html(row: ui.MsgRow) -> String {
  let kind = case row.kind {
    "" -> "msg"
    k -> k
  }
  let own = case row.own {
    True -> " own"
    False -> ""
  }
  let deleted_cls = case row.deleted {
    True -> " deleted"
    False -> ""
  }
  let hl = case row.highlight {
    True -> " highlight"
    False -> ""
  }
  let data_nick = case row.nick {
    "" -> ""
    n -> " data-nick=\"" <> escape(n) <> "\""
  }
  let data_text = case kind, row.deleted {
    "msg", False | "notice", False ->
      " data-text=\"" <> escape(row.text) <> "\""
    _, _ -> ""
  }
  let nick_html = case row.nick {
    "" -> ""
    n ->
      "<span class=\"nick "
      <> escape(row.color)
      <> "\">"
      <> escape(n)
      <> "</span> "
  }
  let body_inner = case row.deleted {
    True -> {
      let who = case row.nick {
        "" -> "someone"
        n -> n
      }
      "<span class=\"msg-deleted-label\">Message from "
      <> escape(who)
      <> " deleted</span>"
    }
    False -> {
      let badge = reply_badge_html(row)
      let edited_mark = case row.edited {
        True -> "<span class=\"msg-edited\" title=\"Edited\">(edited)</span>"
        False -> ""
      }
      badge
      <> nick_html
      <> render.linkify_html(row.text)
      <> edited_mark
      <> reactions_html(row)
      <> reply_edit_btns(row)
    }
  }
  let avatar = avatar_html(row)
  let embed = case row.deleted {
    True -> ""
    False -> embed_html(row)
  }
  "<div class=\"row "
  <> escape(kind)
  <> own
  <> deleted_cls
  <> hl
  <> "\" data-msgid=\""
  <> escape(row.msgid)
  <> "\""
  <> data_nick
  <> data_text
  <> " data-ui-id=\""
  <> escape(row.id)
  <> "\">"
  <> "<span class=\"ts\">"
  <> escape(row.time)
  <> "</span>"
  <> avatar
  <> "<span class=\"body\">"
  <> body_inner
  <> "</span>"
  <> embed
  <> "</div>"
}

fn avatar_html(row: ui.MsgRow) -> String {
  let show = case row.kind {
    "msg" | "notice" -> row.nick != ""
    _ -> False
  }
  case show, row.avatar_url {
    True, "" ->
      // Live fills avatar_url from the profile map when known.
      "<span class=\"msg-avatar msg-avatar-empty\" aria-hidden=\"true\"></span>"
    True, src ->
      "<img class=\"msg-avatar\" src=\""
      <> escape(src)
      <> "\" alt=\"\" loading=\"lazy\" referrerpolicy=\"no-referrer\" title=\""
      <> escape(row.nick)
      <> "\">"
    False, _ ->
      "<span class=\"msg-avatar msg-avatar-empty\" aria-hidden=\"true\"></span>"
  }
}

fn reply_badge_html(row: ui.MsgRow) -> String {
  case row.parent_msgid {
    "" -> ""
    parent -> {
      let nick_label = case row.parent_nick {
        "" -> "message"
        n -> n
      }
      let text_span = case row.parent_preview {
        "" -> ""
        t ->
          "<span class=\"reply-text\">" <> escape(t) <> "</span>"
      }
      "<button type=\"button\" class=\"reply-badge\" data-reply-to=\""
      <> escape(parent)
      <> "\" title=\"Jump to original\">↪ <span class=\"reply-nick\">"
      <> escape(nick_label)
      <> "</span>"
      <> text_span
      <> "</button>"
    }
  }
}

fn reactions_html(row: ui.MsgRow) -> String {
  case row.deleted, row.kind, row.msgid {
    True, _, _ -> ""
    False, "msg", msgid if msgid != "" -> {
      let chips =
        list.map(row.reactions, fn(chip: ui.ReactionChip) {
          let mine = case chip.mine {
            True -> " mine"
            False -> ""
          }
          "<button type=\"button\" class=\"reaction-chip"
          <> mine
          <> "\" title=\""
          <> escape(chip.label)
          <> "\" data-ls-click=\"toggle_reaction\" data-ls-payload=\"msgid="
          <> escape(msgid)
          <> "&emoji="
          <> escape(chip.emoji)
          <> "\">"
          <> escape(chip.label)
          <> "</button>"
        })
        |> string.concat
      "<span class=\"reactions\">"
      <> chips
      <> "<button type=\"button\" class=\"react-btn\" title=\"React\" data-ls-click=\"open_react_picker\" data-ls-payload=\"msgid="
      <> escape(msgid)
      <> "\">+</button></span>"
    }
    _, _, _ -> ""
  }
}

fn reply_edit_btns(row: ui.MsgRow) -> String {
  let reply = case row.can_reply, row.msgid {
    True, mid if mid != "" ->
      "<button type=\"button\" class=\"reply-btn\" title=\"Reply\" data-ls-click=\"reply\" data-ls-payload=\"msgid="
      <> escape(mid)
      <> "\">↩</button>"
    _, _ -> ""
  }
  let edit = case row.can_edit, row.msgid {
    True, mid if mid != "" ->
      "<button type=\"button\" class=\"edit-btn\" title=\"Edit\" data-ls-click=\"edit\" data-ls-payload=\"msgid="
      <> escape(mid)
      <> "\">✎</button>"
    _, _ -> ""
  }
  reply <> edit
}

fn embed_html(row: ui.MsgRow) -> String {
  case row.embed_href {
    "" -> ""
    href -> {
      let kind_class = case row.embed_kind {
        "youtube" -> " yt-embed"
        "bsky" -> " bsky-embed"
        _ -> ""
      }
      let inner = case row.embed_kind {
        "youtube" -> youtube_embed_inner(row)
        "bsky" -> bsky_embed_inner(row)
        _ -> og_embed_inner(row)
      }
      "<a href=\""
      <> escape(href)
      <> "\" target=\"_blank\" rel=\"noopener noreferrer\" class=\"link-embed"
      <> kind_class
      <> "\" style=\"grid-column: 3\">"
      <> inner
      <> "</a>"
    }
  }
}

fn youtube_embed_inner(row: ui.MsgRow) -> String {
  let img = case row.embed_image_url {
    "" -> ""
    src ->
      "<img class=\"link-embed-img yt-thumb\" src=\""
      <> escape(src)
      <> "\" alt=\"\" loading=\"lazy\">"
  }
  img
  <> "<div class=\"link-embed-body yt-footer\"><span class=\"yt-play\">▶</span> YouTube</div>"
}

fn og_embed_inner(row: ui.MsgRow) -> String {
  let img = case row.embed_image_url {
    "" -> ""
    src ->
      "<img class=\"link-embed-img\" src=\""
      <> escape(src)
      <> "\" alt=\"\" loading=\"lazy\" referrerpolicy=\"no-referrer\">"
  }
  let site = case row.embed_site {
    "" -> ""
    s -> "<div class=\"link-embed-site\">" <> escape(s) <> "</div>"
  }
  let title = case row.embed_title {
    "" -> ""
    t -> "<div class=\"link-embed-title\">" <> escape(t) <> "</div>"
  }
  let desc = case row.embed_description {
    "" -> ""
    d -> "<div class=\"link-embed-desc\">" <> escape(d) <> "</div>"
  }
  let domain = case row.embed_domain {
    "" -> ""
    d -> "<div class=\"link-embed-domain\">" <> escape(d) <> "</div>"
  }
  img
  <> "<div class=\"link-embed-body\">"
  <> site
  <> title
  <> desc
  <> domain
  <> "</div>"
}

fn bsky_embed_inner(row: ui.MsgRow) -> String {
  let avatar = case row.bsky_avatar {
    "" -> {
      let letter = case string.first(row.bsky_handle) {
        Ok(ch) -> string.uppercase(ch)
        Error(_) -> "?"
      }
      "<span class=\"bsky-avatar bsky-avatar-fallback\">"
      <> escape(letter)
      <> "</span>"
    }
    src ->
      "<img class=\"bsky-avatar\" src=\""
      <> escape(src)
      <> "\" alt=\"\" loading=\"lazy\">"
  }
  let img = case row.embed_image_url {
    "" -> ""
    src ->
      "<img class=\"link-embed-img\" src=\""
      <> escape(src)
      <> "\" alt=\"\" loading=\"lazy\">"
  }
  "<div class=\"bsky-author\">"
  <> avatar
  <> "<span class=\"bsky-name\">"
  <> escape(row.bsky_display)
  <> "</span>"
  <> "<span class=\"bsky-handle\">@"
  <> escape(row.bsky_handle)
  <> "</span></div>"
  <> "<div class=\"bsky-text\">"
  <> escape(row.bsky_text)
  <> "</div>"
  <> img
  <> "<div class=\"bsky-footer\"><span>♥ "
  <> int.to_string(row.bsky_likes)
  <> "</span><span>↻ "
  <> int.to_string(row.bsky_reposts)
  <> "</span><span class=\"bsky-time\">🦋 "
  <> escape(row.bsky_time)
  <> "</span></div>"
}

fn region_html(name: String, child: ui.Node) -> String {
  case name {
    // Match legacy shell: #messages is the scroll container; rows are direct
    // children (not nested under #log_scroll). Client JS looks for
    // `:scope > .row[data-msgid]`.
    "messages" -> {
      let channel = channel_from_node(child)
      let #(loading, exhausted) = messages_flags_from_node(child)
      // Scroll policy also lands on the root; region carries channel/history flags.
      "<div id=\"messages\" class=\"messages\" data-ls-region=\"messages\""
      <> " data-channel=\""
      <> escape(channel)
      <> "\" data-history-loading=\""
      <> loading
      <> "\" data-history-exhausted=\""
      <> exhausted
      <> "\">"
      <> messages_body_html(child)
      <> "</div>"
    }
    "compose" ->
      "<div data-ls-region=\"compose\" id=\"compose-stack\" class=\"compose-stack ui-region-compose\">"
      <> node_html(child)
      <> "</div>"
    "flash" ->
      "<div data-ls-region=\"flash\" class=\"ui-region-flash\">"
      <> node_html(child)
      <> "</div>"
    "nav" ->
      "<nav data-ls-region=\"nav\" class=\"ui-region-nav\">"
      <> node_html(child)
      <> "</nav>"
    "members" ->
      "<aside data-ls-region=\"members\" class=\"ui-region-members members-panel\">"
      <> node_html(child)
      <> "</aside>"
    // Header / directory body — not the flex message column (that is #chat_col).
    "main" ->
      "<section data-ls-region=\"main\" class=\"ui-region-main ui-channel-header\">"
      <> node_html(child)
      <> "</section>"
    "av" -> {
      let empty = case child {
        ui.Spacer -> True
        ui.Av(p) -> !p.active && !p.call_present
        _ -> False
      }
      let empty_cls = case empty {
        True -> "av-region empty"
        False -> "av-region"
      }
      "<div data-ls-region=\"av\" class=\""
      <> empty_cls
      <> "\">"
      <> case child {
        ui.Spacer -> ""
        other -> node_html(other)
      }
      <> "</div>"
    }
    "react-picker" ->
      case child {
        ui.Spacer | ui.VBox(_, _, []) ->
          "<div data-ls-region=\"react-picker\" class=\"react-picker-host\"></div>"
        _ ->
          "<div data-ls-region=\"react-picker\" class=\"react-picker-host open\">"
          <> node_html(child)
          <> "</div>"
      }
    "search" ->
      "<div data-ls-region=\"search\" class=\"search-host ui-region-search\">"
      <> node_html(child)
      <> "</div>"
    other ->
      "<div data-ls-region=\""
      <> escape(other)
      <> "\" class=\"ui-region ui-region-"
      <> sanitize_class(other)
      <> "\">"
      <> node_html(child)
      <> "</div>"
  }
}

/// Bare channel from `log@freeq` / `log@freeq@L0E0` ids.
fn channel_from_node(node: ui.Node) -> String {
  case node_log_id(node) {
    "" -> ""
    id ->
      case string.split(id, "@") {
        ["log", bare, ..] -> bare
        ["messages", bare, ..] -> bare
        _ -> ""
      }
  }
}

/// History flags encoded as `log@channel@L0E1` (loading / exhausted).
fn messages_flags_from_node(node: ui.Node) -> #(String, String) {
  case string.split(node_log_id(node), "@") {
    [_, _, flags] -> {
      let loading = case string.contains(flags, "L1") {
        True -> "1"
        False -> "0"
      }
      let exhausted = case string.contains(flags, "E1") {
        True -> "1"
        False -> "0"
      }
      #(loading, exhausted)
    }
    _ -> #("0", "0")
  }
}

fn node_log_id(node: ui.Node) -> String {
  case node {
    ui.VBox(id, _, _) | ui.HBox(id, _, _) -> id
    ui.Scrolled(_, child) | ui.Region(_, child) -> node_log_id(child)
    _ -> ""
  }
}

/// Flatten Scrolled/VBox wrappers so message Labels/MsgRows are direct #messages kids.
fn messages_body_html(node: ui.Node) -> String {
  case node {
    ui.Scrolled(_, child) -> messages_body_html(child)
    ui.VBox(_, _, children) | ui.HBox(_, _, children) ->
      list.map(children, node_html) |> string.concat
    other -> node_html(other)
  }
}

/// Collect `Region(name, …)` → full region HTML (wrapper included) for diffs.
fn region_map(
  node: ui.Node,
  acc: List(#(String, String)),
) -> List(#(String, String)) {
  case node {
    ui.Region(name, child) -> {
      let html = region_html(name, child)
      let acc = [#(name, html), ..acc]
      region_map(child, acc)
    }
    ui.VBox(_, _, children) | ui.HBox(_, _, children) ->
      list.fold(children, acc, fn(a, c) { region_map(c, a) })
    ui.Scrolled(_, child) -> region_map(child, acc)
    ui.Label(_, _, _)
    | ui.Button(_, _, _)
    | ui.Entry(_, _, _, _)
    | ui.List(_, _)
    | ui.Separator
    | ui.Spacer
    | ui.Msg(_)
    | ui.Av(_) -> acc
  }
}

fn region_selector(name: String) -> String {
  "[data-ls-region=\"" <> name <> "\"]"
}

fn box(
  kind: String,
  id: String,
  spacing: Int,
  children: List(ui.Node),
) -> String {
  let kids =
    list.map(children, node_html)
    |> string.concat
  // root → chat-body-ish flex row for freeq CSS.
  let tag_class = case id {
    "root" ->
      " class=\"ui-"
      <> kind
      <> " freeq-root chat-body"
      <> class_for_id(id)
      <> "\""
    "chat_col" ->
      " class=\"ui-"
      <> kind
      <> " chat-center ui-chat-col-flex"
      <> class_for_id(id)
      <> "\""
    "composer" ->
      " class=\"ui-"
      <> kind
      <> " send-bar"
      <> class_for_id(id)
      <> "\" id=\"send-bar\""
    "compose_banner" ->
      " class=\"ui-"
      <> kind
      <> " reply-banner"
      <> class_for_id(id)
      <> "\""
    "react_picker_row" ->
      " class=\"ui-"
      <> kind
      <> " react-picker-row"
      <> class_for_id(id)
      <> "\""
    _ ->
      " class=\"ui-"
      <> kind
      <> class_for_id(id)
      <> "\""
  }
  let id_part = case id {
    "composer" -> ""
    _ -> id_attr(id)
  }
  "<div"
  <> id_part
  <> tag_class
  <> " style=\"gap:"
  <> int.to_string(spacing)
  <> "px\">"
  <> kids
  <> "</div>"
}

fn id_attr(id: String) -> String {
  case string.trim(id) {
    "" -> ""
    // Stable DOM id for the nav call control (av_call.js / CSS hooks).
    "av_start" | "av_join" | "av_leave" -> " id=\"av-call-btn\""
    // log@freeq is metadata for data-channel; keep a stable id for the list.
    i ->
      case string.split_once(i, "@") {
        Ok(#("log", _)) -> " id=\"log\""
        Ok(#("messages", _)) -> " id=\"log\""
        _ -> " id=\"" <> escape(i) <> "\""
      }
  }
}

fn class_for_id(id: String) -> String {
  case id {
    "" -> ""
    "root" -> " ui-root"
    "chat_col" -> " ui-chat-col"
    "user_panel" -> " ui-user-panel"
    "log" -> " ui-log"
    "log_scroll" -> " ui-log-scroll"
    "composer" -> " ui-composer"
    "input" -> " ui-compose-input"
    "send" -> " ui-send"
    "nav" -> " ui-nav"
    "members_list" -> " ui-members"
    "dir_list" -> " channel-list ui-dir-list"
    "flash" -> " flash ui-flash"
    "av_start" -> " av-call-btn"
    "av_join" -> " av-call-btn has-call"
    "av_leave" -> " av-call-btn in-call"
    other ->
      case string.split_once(other, "@") {
        Ok(#("log", _)) -> " ui-log"
        _ -> " ui-id-" <> sanitize_class(other)
      }
  }
}

fn sanitize_class(id: String) -> String {
  id
  |> string.replace(":", "-")
  |> string.replace("#", "")
  |> string.replace("@", "-")
  |> string.replace(" ", "-")
}

fn click_attrs(id: String) -> String {
  case id {
    "send" -> " data-ls-click=\"send\""
    "join" -> " data-ls-click=\"join\""
    "go_index" -> " data-ls-click=\"go_index\""
    "go_system" -> " data-ls-click=\"go_system\""
    "part" -> " data-ls-click=\"part\""
    "cancel_compose" -> " data-ls-click=\"cancel_reply\""
    "close_react" -> " data-ls-click=\"close_react_picker\""
    "av_start" -> " data-ls-click=\"av_start\""
    "av_join" -> " data-ls-click=\"av_join\""
    "av_leave" -> " data-ls-click=\"av_leave\""
    "av_toggle_mute" -> " data-ls-click=\"av_toggle_mute\""
    "av_toggle_camera" -> " data-ls-click=\"av_toggle_camera\""
    other ->
      case string.split_once(other, ":") {
        Ok(#("open", bare)) ->
          " data-ls-click=\"open\" data-ls-payload=\"channel="
          <> escape(bare)
          <> "\""
        Ok(#("reply", mid)) ->
          " data-ls-click=\"reply\" data-ls-payload=\"msgid="
          <> escape(mid)
          <> "\""
        Ok(#("edit", mid)) ->
          " data-ls-click=\"edit\" data-ls-payload=\"msgid="
          <> escape(mid)
          <> "\""
        Ok(#("open_react", mid)) ->
          " data-ls-click=\"open_react_picker\" data-ls-payload=\"msgid="
          <> escape(mid)
          <> "\""
        Ok(#("react", rest)) ->
          case string.split_once(rest, ":") {
            Ok(#(mid, emoji)) ->
              " data-ls-click=\"toggle_reaction\" data-ls-payload=\"msgid="
              <> escape(mid)
              <> "&emoji="
              <> escape(emoji)
              <> "\""
            Error(_) -> " data-ui-id=\"" <> escape(other) <> "\""
          }
        _ -> " data-ui-id=\"" <> escape(other) <> "\""
      }
  }
}

fn form_attrs(entry_id: String) -> String {
  case entry_id {
    "input" -> " id=\"send-form\" data-ls-submit=\"send\""
    "join_input" -> " id=\"join-form\" data-ls-submit=\"join\""
    _ -> ""
  }
}

fn submit_button_for(entry_id: String) -> String {
  // Composer Entry is only the field in the View tree; Send is a sibling Button.
  // Join row also has a sibling Button. No extra submit here.
  let _ = entry_id
  ""
}

fn entry_name(id: String) -> String {
  case id {
    "input" -> "msg"
    "join_input" -> "channel"
    other -> other
  }
}

fn escape(s: String) -> String {
  render.escape_html(s)
}
