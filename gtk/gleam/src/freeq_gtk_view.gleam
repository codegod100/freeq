//// Full-window view tree for freeq-gtk + demo host entrypoint.
////
//// GTK is a dumb renderer: on every model change, `dist.push_view` a complete
//// `View`. User actions arrive as `Event` values over Erlang dist.
////
//// Wire format = native Erlang encoding of these Gleam types (tagged tuples /
//// atoms). Keep field order stable — Rust decodes by position.

import freeq_gtk_view/dist
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/string

// ── View tree (BEAM → GTK) ───────────────────────────────────────────────────

/// Entire window. Sent as a single dist message to `{freeq_gtk, Node}`.
pub type View {
  View(
    title: String,
    subtitle: String,
    width: Int,
    height: Int,
    body: Node,
  )
}

/// Widget tree. Zero-arity variants encode as atoms (`separator`, `spacer`).
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
}

pub type ButtonStyle {
  Normal
  Suggested
  Destructive
}

// ── Events (GTK → BEAM) ──────────────────────────────────────────────────────

/// Decoded from dist messages the GTK node reg_sends to `freeq_view`.
pub type Event {
  Clicked(id: String)
  Activate(id: String, text: String)
  Changed(id: String, text: String)
  Selected(id: String, index: Int, item: String)
  Unknown(raw: String)
}

// ── Chat shell helper ────────────────────────────────────────────────────────

pub fn chat_view(
  channel: String,
  topic: String,
  lines: List(String),
  draft: String,
) -> View {
  View(
    title: "freeq",
    subtitle: channel,
    width: 720,
    height: 520,
    body: VBox(id: "root", spacing: 8, children: [
      Label(id: "topic", text: topic, dim: True),
      Scrolled(
        id: "log_scroll",
        child: List(id: "log", items: lines),
      ),
      HBox(id: "composer", spacing: 8, children: [
        Entry(
          id: "input",
          text: draft,
          placeholder: "Message…",
          password: False,
        ),
        Button(id: "send", label: "Send", style: Suggested),
      ]),
    ]),
  )
}

pub fn append_line(lines: List(String), line: String) -> List(String) {
  list.append(lines, [line])
  |> trim_lines(200)
}

fn trim_lines(lines: List(String), max: Int) -> List(String) {
  let n = list.length(lines)
  case n > max {
    True -> list.drop(lines, n - max)
    False -> lines
  }
}

pub fn format_line(nick: String, text: String) -> String {
  string.concat(["[", nick, "] ", text])
}

// ── Demo host (owns model, pushes full views) ────────────────────────────────

type Model {
  Model(
    channel: String,
    topic: String,
    lines: List(String),
    draft: String,
    gtk_node: String,
  )
}

pub fn main() {
  let cookie = dist.env_or("FREEQ_COOKIE", "freeq_dev")
  let our_name = dist.env_or("FREEQ_VIEW_NODE", "freeq_view@localhost")
  let gtk_node = dist.env_or("FREEQ_GTK_NODE", "freeq_gtk@localhost")

  case dist.start_node(our_name, cookie) {
    Error(e) -> io.println("failed to start dist node: " <> e)
    Ok(_) -> {
      let _ = dist.register_view()
      io.println("freeq_gtk_view host as " <> our_name)
      io.println("cookie=" <> cookie <> "  gtk=" <> gtk_node)
      io.println("waiting for freeq-gtk…")
      connect_loop(
        Model(
          channel: "#playground",
          topic: "Gleam owns this view — every update is a full snapshot",
          lines: [
            "· Gleam host ready",
            "· Type below and press Enter or Send",
          ],
          draft: "",
          gtk_node: gtk_node,
        ),
      )
    }
  }
}

fn connect_loop(model: Model) -> Nil {
  case dist.connect(model.gtk_node) {
    True -> {
      io.println("connected to " <> model.gtk_node)
      loop(push(model))
    }
    False -> {
      process.sleep(1000)
      connect_loop(model)
    }
  }
}

fn loop(model: Model) -> Nil {
  case dist.recv_event(500) {
    None -> loop(model)
    Some(event) -> loop(handle(model, event))
  }
}

fn handle(model: Model, event: Event) -> Model {
  case event {
    Changed(id, text) if id == "input" -> Model(..model, draft: text)
    Activate(id, text) if id == "input" -> submit(model, text)
    Clicked(id) if id == "send" -> submit(model, model.draft)
    Selected(id, index, item) -> {
      let line =
        "· selected "
        <> id
        <> "["
        <> int.to_string(index)
        <> "]: "
        <> item
      push(Model(..model, lines: append_line(model.lines, line)))
    }
    Unknown(raw) -> {
      io.println("unknown event: " <> raw)
      model
    }
    _ -> model
  }
}

fn submit(model: Model, text: String) -> Model {
  let text = string.trim(text)
  case text == "" {
    True -> model
    False ->
      push(
        Model(
          ..model,
          draft: "",
          lines: append_line(model.lines, format_line("you", text)),
        ),
      )
  }
}

fn push(model: Model) -> Model {
  let view =
    chat_view(model.channel, model.topic, model.lines, model.draft)
  case dist.push_view(model.gtk_node, view) {
    Ok(_) -> model
    Error(e) -> {
      io.println("push failed: " <> e)
      model
    }
  }
}
