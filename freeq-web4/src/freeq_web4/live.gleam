//// freeq chat LiveView — Lightspeed stateful component.
////
//// Server-owned model for channel list + per-channel chat shell.
//// Browser events become typed Msgs; IRC lines become PushLine/etc.
//// Fine-grained region patches keep the shell responsive.

import freeq_web4/irc/render
import freeq_web4/rest
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import lightspeed/component
import lightspeed/component/helpers
import lightspeed/component/stateful
import lightspeed/diff
import lightspeed/event
import lightspeed/form

// ── Model ────────────────────────────────────────────────────────────────────

pub type View {
  Index
  Channel
}

pub type WsLabel {
  WsDisconnected
  WsConnecting
  WsRegistering
  WsReady
}

pub type Model {
  Model(
    view: View,
    /// Canonical channel when view == Channel (e.g. `#freeq`).
    channel: Option(String),
    topic: String,
    nick: String,
    ws: WsLabel,
    my_channels: List(String),
    all_channels: List(rest.ChannelInfo),
    messages: List(render.Row),
    members: List(render.Member),
    compose: String,
    status: String,
    /// Last error / system banner.
    flash: String,
  )
}

/// Parent assigns — path selects index vs channel on mount.
pub type Assigns {
  Assigns(path: String)
}

// ── Messages ─────────────────────────────────────────────────────────────────

pub type Msg {
  /// Browser: submit compose form.
  Send(text: String)
  /// Browser: join channel form.
  Join(raw: String)
  /// Browser: part a channel.
  Part(channel: String)
  /// Browser: navigate to channel list.
  GoIndex
  /// Browser: open a channel (sidebar / directory).
  OpenChannel(bare: String)
  /// Browser: set topic.
  SetTopic(topic: String)
  /// Server: IRC connection state.
  SetWs(WsLabel)
  /// Server: nick assigned.
  SetNick(String)
  /// Server: raw IRC line.
  PushLine(String)
  /// Server: replace history after REST fetch.
  SetHistory(List(render.Row))
  /// Server: public channel directory.
  SetAllChannels(List(rest.ChannelInfo))
  /// Server: topic update.
  SetTopicText(String)
  /// Server: flash/status.
  SetFlash(String)
  /// No-op / ignored.
  Nop
}

/// Side effects the session host should perform after a handle.
pub type Effect {
  NoEffect
  /// Send raw IRC line(s) upstream.
  IrcSend(List(String))
  /// (Re)start upstream with primary + extras.
  EnsureUpstream(primary: String, extras: List(String))
  /// Fetch REST history for a channel.
  FetchHistory(channel: String)
  /// Fetch public channel list.
  FetchChannels
  /// Stop upstream (logout / socket close).
  StopUpstream
}

// ── Component ────────────────────────────────────────────────────────────────

pub fn definition() -> stateful.LifecycleComponent(Model, Assigns, Msg) {
  stateful.LifecycleComponent(
    mount: mount,
    update: update_assigns,
    handle: handle,
    render: render,
    routes: routes(),
  )
}

pub const target = "#app"

pub const root_attrs_fingerprint = "freeq-root-attrs"

/// Decode a Lightspeed event into a Msg (for the session host).
pub fn decode_event(
  name: String,
  payload: String,
) -> Result(Msg, event.DecodeError) {
  let inbound = event.inbound(name, payload)
  stateful.route_event(inbound, routes())
}

/// Apply a Msg and return the next model + effect for the host.
pub fn apply(model: Model, msg: Msg) -> #(Model, Effect) {
  handle_effect(model, msg)
}

// ── Lifecycle ────────────────────────────────────────────────────────────────

fn mount(
  ctx: stateful.MountContext,
  assigns: Assigns,
) -> #(Model, List(component.Command(Msg))) {
  let path = case assigns.path {
    "" -> ctx.route
    p -> p
  }
  let #(view, channel) = path_to_view(path)
  let my = case channel {
    Some(ch) -> [ch]
    None -> []
  }
  let model =
    Model(
      view: view,
      channel: channel,
      topic: "",
      nick: "guest",
      ws: WsDisconnected,
      my_channels: my,
      all_channels: [],
      messages: [],
      members: [],
      compose: "",
      status: "connecting…",
      flash: "",
    )
  helpers.no_effect(model)
}

fn update_assigns(
  model: Model,
  _assigns: Assigns,
) -> #(Model, List(component.Command(Msg))) {
  helpers.no_effect(model)
}

fn handle(model: Model, msg: Msg) -> #(Model, List(component.Command(Msg))) {
  let #(next, _effect) = handle_effect(model, msg)
  helpers.no_effect(next)
}

/// Full handle used by the session host (returns effects).
pub fn handle_effect(model: Model, msg: Msg) -> #(Model, Effect) {
  case msg {
    Nop -> #(model, NoEffect)

    Send(text) -> {
      let text = string.trim(text)
      case text == "", model.channel {
        True, _ -> #(model, NoEffect)
        _, None -> #(Model(..model, flash: "Join a channel first"), NoEffect)
        _, Some(ch) -> {
          let line = case string.starts_with(text, "/") {
            True -> string.drop_start(text, 1) <> "\r\n"
            False -> "PRIVMSG " <> ch <> " :" <> text <> "\r\n"
          }
          #(Model(..model, compose: "", flash: ""), IrcSend([line]))
        }
      }
    }

    Join(raw) -> {
      let ch = render.canonical_channel(raw)
      case ch == "#" || ch == "" {
        True -> #(model, NoEffect)
        False -> {
          let my = list_unique_append(model.my_channels, ch)
          let model =
            Model(
              ..model,
              view: Channel,
              channel: Some(ch),
              my_channels: my,
              messages: [],
              members: [],
              topic: "",
              flash: "",
            )
          #(
            model,
            multi_effect([
              EnsureUpstream(ch, list.filter(my, fn(c) { c != ch })),
              IrcSend(["JOIN " <> ch <> "\r\n"]),
              FetchHistory(ch),
            ]),
          )
        }
      }
    }

    Part(raw) -> {
      let ch = render.canonical_channel(raw)
      let my = list.filter(model.my_channels, fn(c) { c != ch })
      let leaving_current = case model.channel {
        Some(c) -> c == ch
        None -> False
      }
      let model = case leaving_current {
        True ->
          Model(
            ..model,
            view: Index,
            channel: None,
            my_channels: my,
            messages: [],
            members: [],
            topic: "",
          )
        False -> Model(..model, my_channels: my)
      }
      #(model, IrcSend(["PART " <> ch <> "\r\n"]))
    }

    GoIndex -> #(
      Model(
        ..model,
        view: Index,
        channel: None,
        messages: [],
        members: [],
        topic: "",
      ),
      FetchChannels,
    )

    OpenChannel(bare) -> {
      let ch = render.canonical_channel(bare)
      let my = list_unique_append(model.my_channels, ch)
      let model =
        Model(
          ..model,
          view: Channel,
          channel: Some(ch),
          my_channels: my,
          messages: [],
          members: [],
          topic: "",
          flash: "",
        )
      #(
        model,
        multi_effect([
          EnsureUpstream(ch, list.filter(my, fn(c) { c != ch })),
          IrcSend(["JOIN " <> ch <> "\r\n"]),
          FetchHistory(ch),
        ]),
      )
    }

    SetTopic(topic) ->
      case model.channel {
        Some(ch) -> #(
          Model(..model, topic: topic),
          IrcSend(["TOPIC " <> ch <> " :" <> topic <> "\r\n"]),
        )
        None -> #(model, NoEffect)
      }

    SetWs(ws) -> #(Model(..model, ws: ws, status: ws_status(ws)), NoEffect)

    SetNick(nick) -> #(Model(..model, nick: nick), NoEffect)

    PushLine(line) -> apply_line(model, line)

    SetHistory(rows) -> #(Model(..model, messages: rows), NoEffect)

    SetAllChannels(chs) -> #(Model(..model, all_channels: chs), NoEffect)

    SetTopicText(topic) -> #(Model(..model, topic: topic), NoEffect)

    SetFlash(flash) -> #(Model(..model, flash: flash), NoEffect)
  }
}

/// Collapse a list of effects into one (session host expands multi).
fn multi_effect(effects: List(Effect)) -> Effect {
  // Session host special-cases EnsureUpstream + list via apply; we encode
  // the common join path as EnsureUpstream and rely on host to also send
  // JOIN + fetch. For simplicity, prefer the first non-NoEffect that is
  // EnsureUpstream, else first.
  case effects {
    [EnsureUpstream(p, e), ..] -> EnsureUpstream(p, e)
    [other, ..] -> other
    [] -> NoEffect
  }
}

fn apply_line(model: Model, line: String) -> #(Model, Effect) {
  // Topic
  case render.parse_topic(line) {
    Some(#(ch, topic)) ->
      case model.channel {
        Some(c) if c == ch -> #(Model(..model, topic: topic), NoEffect)
        _ -> #(model, NoEffect)
      }
    None ->
      // Member roster 353
      case string.contains(line, " 353 ") {
        True -> {
          let members = render.parse_353_members(line)
          // Merge by nick
          let members = merge_members(model.members, members)
          #(Model(..model, members: members), NoEffect)
        }
        False ->
          case render.parse_member_change(line) {
            Some(#("join", nick, Some(ch))) ->
              case model.channel {
                Some(c) if c == ch -> #(
                  Model(
                    ..model,
                    members: upsert_member(
                      model.members,
                      render.Member(
                        nick: nick,
                        op: False,
                        voice: False,
                        color: render.nick_color_class(nick),
                      ),
                    ),
                  ),
                  NoEffect,
                )
                _ -> #(model, NoEffect)
              }
            Some(#("part", nick, Some(ch))) ->
              case model.channel {
                Some(c) if c == ch -> #(
                  Model(
                    ..model,
                    members: list.filter(model.members, fn(m) { m.nick != nick }),
                  ),
                  NoEffect,
                )
                _ -> #(model, NoEffect)
              }
            Some(#("quit", nick, _)) -> #(
              Model(
                ..model,
                members: list.filter(model.members, fn(m) { m.nick != nick }),
              ),
              NoEffect,
            )
            Some(#("nick", old, Some(new))) -> #(
              Model(
                ..model,
                nick: case
                  string.lowercase(model.nick) == string.lowercase(old)
                {
                  True -> new
                  False -> model.nick
                },
                members: list.map(model.members, fn(m) {
                  case m.nick == old {
                    True -> render.Member(..m, nick: new)
                    False -> m
                  }
                }),
              ),
              NoEffect,
            )
            _ ->
              case render.parse_message_line(line, Some(model.nick)) {
                Some(row) -> {
                  // Filter to current channel for PRIVMSG when possible —
                  // full line parse doesn't always carry target; show all.
                  let messages = append_capped(model.messages, row, 400)
                  #(Model(..model, messages: messages), NoEffect)
                }
                None -> #(model, NoEffect)
              }
          }
      }
  }
}

fn merge_members(
  existing: List(render.Member),
  incoming: List(render.Member),
) -> List(render.Member) {
  list.fold(incoming, existing, fn(acc, m) { upsert_member(acc, m) })
}

fn upsert_member(
  members: List(render.Member),
  member: render.Member,
) -> List(render.Member) {
  case list.any(members, fn(m) { m.nick == member.nick }) {
    True ->
      list.map(members, fn(m) {
        case m.nick == member.nick {
          True -> member
          False -> m
        }
      })
    False -> list.append(members, [member])
  }
}

fn append_capped(
  rows: List(render.Row),
  row: render.Row,
  cap: Int,
) -> List(render.Row) {
  let rows = list.append(rows, [row])
  let n = list.length(rows)
  case n > cap {
    True -> list.drop(rows, n - cap)
    False -> rows
  }
}

fn list_unique_append(xs: List(String), x: String) -> List(String) {
  case list.contains(xs, x) {
    True -> xs
    False -> list.append(xs, [x])
  }
}

fn path_to_view(path: String) -> #(View, Option(String)) {
  let path = case string.ends_with(path, "/") && string.length(path) > 1 {
    True -> string.drop_end(path, 1)
    False -> path
  }
  case path {
    "/" | "/chat" | "" -> #(Index, None)
    _ ->
      case string.starts_with(path, "/chat/") {
        True -> {
          let bare = string.drop_start(path, 6)
          case bare == "" {
            True -> #(Index, None)
            False -> #(Channel, Some(render.canonical_channel(bare)))
          }
        }
        False -> #(Index, None)
      }
  }
}

fn ws_status(ws: WsLabel) -> String {
  case ws {
    WsDisconnected -> "disconnected"
    WsConnecting -> "connecting…"
    WsRegistering -> "registering…"
    WsReady -> "connected"
  }
}

// ── Routes ───────────────────────────────────────────────────────────────────

fn routes() -> List(stateful.EventRoute(Msg)) {
  [
    stateful.route("send", fn(e) {
      event.decode_form(e, "send", fn(data) {
        use text <- result.try(
          form.require(data, "msg")
          |> result.or(form.require(data, "text")),
        )
        Ok(Send(text))
      })
    }),
    stateful.route("join", fn(e) {
      event.decode_form(e, "join", fn(data) {
        use ch <- result.try(form.require(data, "channel"))
        Ok(Join(ch))
      })
    }),
    stateful.route("part", fn(e) {
      event.decode_form(e, "part", fn(data) {
        use ch <- result.try(form.require(data, "channel"))
        Ok(Part(ch))
      })
    }),
    stateful.route("go_index", fn(e) {
      event.decode_unit(e, "go_index", GoIndex)
    }),
    stateful.route("open", fn(e) {
      event.decode_form(e, "open", fn(data) {
        use ch <- result.try(form.require(data, "channel"))
        Ok(OpenChannel(ch))
      })
    }),
    stateful.route("set_topic", fn(e) {
      event.decode_form(e, "set_topic", fn(data) {
        use topic <- result.try(form.require(data, "topic"))
        Ok(SetTopic(topic))
      })
    }),
  ]
}

// ── Patches ──────────────────────────────────────────────────────────────────

pub fn plan_patches(before: Model, after: Model) -> List(diff.Patch) {
  case before == after {
    True -> []
    False -> {
      let acc = []
      let acc = maybe_region(before, after, "nav", nav_region, acc)
      let acc = maybe_region(before, after, "sidebar", sidebar_region, acc)
      let acc = maybe_region(before, after, "main", main_region, acc)
      let acc = maybe_region(before, after, "members", members_region, acc)
      list.reverse(acc)
    }
  }
}

fn region_selector(name: String) -> String {
  "[data-ls-region=\"" <> name <> "\"]"
}

fn maybe_region(
  before: Model,
  after: Model,
  name: String,
  render_fn: fn(Model) -> String,
  acc: List(diff.Patch),
) -> List(diff.Patch) {
  let next = render_fn(after)
  case render_fn(before) == next {
    True -> acc
    False -> [diff.Replace(target: region_selector(name), html: next), ..acc]
  }
}

// ── Render ───────────────────────────────────────────────────────────────────

fn render(model: Model) -> component.Rendered {
  component.html(shell(model))
}

fn shell(model: Model) -> String {
  "<div id=\"freeq-chat\" class=\"freeq-root\">"
  <> nav_region(model)
  <> "<div class=\"chat-body\">"
  <> sidebar_region(model)
  <> main_region(model)
  <> members_region(model)
  <> "</div></div>"
}

fn nav_region(model: Model) -> String {
  let channel_label = case model.view, model.channel {
    Index, _ -> "channels"
    Channel, Some(ch) -> ch
    Channel, None -> "chat"
  }
  let topic = case model.topic {
    "" -> "add topic"
    t -> render.escape_html(t)
  }
  let connected = case model.ws {
    WsReady -> " connected"
    _ -> ""
  }
  "<nav data-ls-region=\"nav\">"
  <> "<span class=\"brand\">freeq</span>"
  <> "<div class=\"nav-channel-meta\">"
  <> "<span class=\"nav-channel\">"
  <> render.escape_html(channel_label)
  <> "</span>"
  <> case model.view {
    Channel ->
      "<span id=\"channel-topic\" class=\"editable\">" <> topic <> "</span>"
    Index -> ""
  }
  <> "</div>"
  <> "<div class=\"nav-right\">"
  <> "<span id=\"status\" class=\""
  <> connected
  <> "\"><span class=\"dot\"></span><span>"
  <> render.escape_html(model.status)
  <> "</span></span>"
  <> "<span class=\"auth-badge guest\">👤 "
  <> render.escape_html(model.nick)
  <> "</span>"
  <> "</div></nav>"
}

fn sidebar_region(model: Model) -> String {
  let my =
    list.map(model.my_channels, fn(ch) {
      let bare = render.bare_channel(ch)
      let active = case model.channel {
        Some(c) if c == ch -> " active"
        _ -> ""
      }
      "<li class=\""
      <> active
      <> "\">"
      <> "<button type=\"button\" class=\"channel-link\" data-ls-click=\"open\" data-ls-payload=\"channel="
      <> bare
      <> "\"><span class=\"channel-link-name\">"
      <> render.escape_html(ch)
      <> "</span></button>"
      <> "<button type=\"button\" class=\"sidebar-channel-part\" data-ls-click=\"part\" data-ls-payload=\"channel="
      <> bare
      <> "\" title=\"Part\">×</button>"
      <> "</li>"
    })
    |> string.concat

  "<aside id=\"sidebar\" data-ls-region=\"sidebar\">"
  <> "<p class=\"drawer-heading\">Channels</p>"
  <> "<div class=\"sidebar-scroll\">"
  <> "<form id=\"join-form\" data-ls-submit=\"join\">"
  <> "<input type=\"text\" name=\"channel\" placeholder=\"join #…\" autocomplete=\"off\" />"
  <> "<button type=\"submit\">+</button>"
  <> "</form>"
  <> "<p class=\"sidebar-toggle\"><span class=\"arrow\">▾</span> MY CHANNELS</p>"
  <> "<ul id=\"my-channels\">"
  <> my
  <> "</ul>"
  <> "</div>"
  <> "<div id=\"user-info\">"
  <> "<div class=\"user-handle guest\" id=\"user-handle\">👤 "
  <> render.escape_html(model.nick)
  <> "</div>"
  <> "<div class=\"user-actions\">"
  <> "<button type=\"button\" class=\"btn-link\" data-ls-click=\"go_index\">All channels</button>"
  <> "<span class=\"btn-link\" title=\"OAuth not yet ported\">guest</span>"
  <> "</div></div></aside>"
}

fn main_region(model: Model) -> String {
  case model.view {
    Index -> index_main(model)
    Channel -> channel_main(model)
  }
}

fn index_main(model: Model) -> String {
  let items =
    list.map(model.all_channels, fn(ch) {
      let bare = render.bare_channel(ch.name)
      let topic = case ch.topic {
        "" -> ""
        t ->
          "<span class=\"channel-topic\">" <> render.escape_html(t) <> "</span>"
      }
      "<li><button type=\"button\" class=\"channel-item\" data-ls-click=\"open\" data-ls-payload=\"channel="
      <> bare
      <> "\"><span class=\"channel-name\">"
      <> render.escape_html(ch.name)
      <> "</span>"
      <> topic
      <> "<span class=\"channel-members\">"
      <> int.to_string(ch.members)
      <> "</span></button></li>"
    })
    |> string.concat

  let flash = case model.flash {
    "" -> ""
    f -> "<p class=\"flash\">" <> render.escape_html(f) <> "</p>"
  }

  "<section class=\"chat-main\" data-ls-region=\"main\">"
  <> "<div class=\"channel-list-page\">"
  <> flash
  <> "<form id=\"index-join-form\" data-ls-submit=\"join\">"
  <> "<input type=\"text\" name=\"channel\" placeholder=\"join #channel\" autocomplete=\"off\" />"
  <> "<button type=\"submit\">Join</button>"
  <> "</form>"
  <> case model.all_channels {
    [] -> "<p class=\"muted\">Loading channels… (or none public)</p>"
    _ -> "<ul class=\"channel-list\">" <> items <> "</ul>"
  }
  <> "</div></section>"
}

fn channel_main(model: Model) -> String {
  let msgs =
    list.map(model.messages, message_html)
    |> string.concat

  let flash = case model.flash {
    "" -> ""
    f -> "<div class=\"flash\">" <> render.escape_html(f) <> "</div>"
  }

  "<section class=\"chat-main\" data-ls-region=\"main\">"
  <> flash
  <> "<div id=\"messages\" class=\"messages\">"
  <> msgs
  <> "</div>"
  <> "<form id=\"compose\" data-ls-submit=\"send\" class=\"compose\">"
  <> "<input type=\"text\" name=\"msg\" placeholder=\"Message "
  <> render.escape_html(option.unwrap(model.channel, ""))
  <> "\" autocomplete=\"off\" autofocus />"
  <> "<button type=\"submit\">Send</button>"
  <> "</form>"
  <> "</section>"
}

fn message_html(row: render.Row) -> String {
  let kind = render.kind_class(row.kind)
  let nick = case row.nick {
    Some(n) ->
      "<span class=\"nick "
      <> row.color
      <> "\">"
      <> render.escape_html(n)
      <> "</span>"
    None -> ""
  }
  let own = case row.own {
    True -> " own"
    False -> ""
  }
  "<div class=\"row "
  <> kind
  <> own
  <> "\" data-msgid=\""
  <> render.escape_html(option.unwrap(row.msgid, row.id))
  <> "\">"
  <> "<span class=\"time\">"
  <> render.escape_html(row.time_label)
  <> "</span>"
  <> nick
  <> "<span class=\"body\">"
  <> render.escape_html(row.text)
  <> "</span></div>"
}

fn members_region(model: Model) -> String {
  case model.view {
    Index ->
      "<aside id=\"member-panel\" data-ls-region=\"members\" class=\"hidden\"></aside>"
    Channel -> {
      let items =
        list.map(model.members, fn(m) {
          let prefix = case m.op, m.voice {
            True, _ -> "@"
            False, True -> "+"
            False, False -> ""
          }
          "<li class=\""
          <> m.color
          <> "\">"
          <> render.escape_html(prefix <> m.nick)
          <> "</li>"
        })
        |> string.concat
      "<aside id=\"member-panel\" data-ls-region=\"members\">"
      <> "<p class=\"drawer-heading\">People ("
      <> int.to_string(list.length(model.members))
      <> ")</p>"
      <> "<ul id=\"members\">"
      <> items
      <> "</ul></aside>"
    }
  }
}

/// Initial disconnected HTML for a path (SSR shell).
pub fn initial_html(path: String) -> String {
  let context =
    stateful.mount_context("freeq-root", path, stateful.Disconnected)
  let #(instance, _commands, _patches) =
    stateful.start(definition(), context, Assigns(path: path), target)
  stateful.html(instance)
}

/// Bootstrap model for a connected session (same path).
pub fn mount_model(path: String) -> Model {
  let context = stateful.mount_context("freeq-root", path, stateful.Connected)
  let #(instance, _, _) =
    stateful.start(definition(), context, Assigns(path: path), target)
  stateful.model(instance)
}
