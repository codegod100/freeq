//// Pure HTML renderer for the canonical `ui.View` tree.
////
//// LiveView (Phase 2) uses `view_html` / `plan_patches` as the web paint path.
//// freeq-gtk still decodes the ETF View tree directly (not this HTML).
////
//// Id conventions (shared with GTK / ui.to_msg):
//// - `send`, `join`, `go_index`, `go_system`, `part` → click / submit actions
//// - `open:<channel>` → open channel
//// - `input` / `join_input` → compose fields
//// - layout ids (`root`, `chat_col`, `user_panel`, `log`, …) → CSS hooks
//// - `Region(name, child)` → `data-ls-region` patch boundary (Lightspeed)

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
  <> "\">"
  <> "<div class=\"ui-view-meta\" hidden>"
  <> escape(view.subtitle)
  <> "</div>"
  <> node_html(view.body)
  <> "</div>"
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
      // Message rows: match legacy #messages > .row[data-msgid] so scroll JS
      // and bottom-stick logic still work.
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
  }
}

fn region_html(name: String, child: ui.Node) -> String {
  case name {
    // Match legacy shell: #messages is the scroll container; rows are direct
    // children (not nested under #log_scroll). Client JS looks for
    // `:scope > .row[data-msgid]`.
    "messages" -> {
      let channel = channel_from_node(child)
      let #(loading, exhausted) = messages_flags_from_node(child)
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

/// Flatten Scrolled/VBox wrappers so message Labels are direct #messages kids.
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
    | ui.Spacer -> acc
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
    _ ->
      " class=\"ui-"
      <> kind
      <> class_for_id(id)
      <> "\""
  }
  let id_part = case id {
    "composer" -> ""
    // id already set via send-bar above; still allow generic id
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
    other ->
      case string.split_once(other, ":") {
        Ok(#("open", bare)) ->
          " data-ls-click=\"open\" data-ls-payload=\"channel="
          <> escape(bare)
          <> "\""
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
