//// freeq chat LiveView — Lightspeed stateful component.
////
//// Server-owned model for channel list + per-channel chat shell.
//// Browser events become typed Msgs; IRC lines become PushLine/etc.
//// Fine-grained region patches keep the shell responsive.

import freeq_web4/config
import freeq_web4/irc/render
import freeq_web4/rest
import gleam/bit_array
import gleam/crypto
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

/// Which page the LiveView is showing: channel directory or a single channel.
pub type View {
  /// Channel list / directory (`/chat`).
  Index
  /// Single channel chat shell (`/chat/:name`).
  Channel
}

/// Upstream IRC WebSocket connection phase, shown in the shell status.
pub type WsLabel {
  /// No upstream socket (or closed).
  WsDisconnected
  /// TCP/WebSocket connect in progress.
  WsConnecting
  /// CAP/NICK/USER (and optional SASL) in progress.
  WsRegistering
  /// Registered and ready for PRIVMSG / JOIN.
  WsReady
}

/// Full server-side state for one LiveView socket (channel shell + AV).
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
    /// AT Protocol identity (after OAuth + SASL).
    authenticated: Bool,
    auth_handle: String,
    auth_did: String,
    /// freeq-server session bearer from API-BEARER NOTICE (post-SASL).
    api_bearer: Option(String),
    /// In an AV call (media panel visible).
    av_active: Bool,
    /// Someone else has a live call on the *viewed* channel.
    av_call_present: Bool,
    /// freeq-server AV session id (`+freeq.at/av-id`).
    av_session_id: Option(String),
    /// Channel the call is on (may differ from text `channel` while browsing).
    av_channel: Option(String),
    av_participant_count: Int,
    av_muted: Bool,
    av_camera: Bool,
    /// Per-device instance id (8 lowercase hex).
    av_instance: String,
    /// MoQ JWT from directed `+freeq.at/av-token` TAGMSG.
    av_token: Option(String),
  )
}

/// Parent assigns — path selects index vs channel on mount.
pub type Assigns {
  Assigns(path: String)
}

// ── Messages ─────────────────────────────────────────────────────────────────

/// Typed events for the chat LiveView: browser actions and server-side pushes.
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
  /// Server: OAuth credentials loaded / SASL identity.
  SetAuth(authenticated: Bool, handle: String, did: String)
  /// Server: API-BEARER from freeq-server after SASL.
  SetApiBearer(String)
  /// Browser: start voice call on current channel.
  AvStart
  /// Browser: join existing call on current channel.
  AvJoin
  /// Browser: leave the active call.
  AvLeave
  /// Browser: toggle mute.
  AvToggleMute
  /// Browser: toggle camera.
  AvToggleCamera
  /// Browser: roster poll reported participant count.
  AvRoster(count: Int)
  /// Server: REST probe found (or cleared) an active call on a channel.
  AvProbe(channel: String, call: Option(rest.ActiveCall))
  /// No-op / ignored.
  Nop
}

/// Side effects the session host should perform after a handle.
pub type Effect {
  /// Nothing to do.
  NoEffect
  /// Send raw IRC line(s) upstream.
  IrcSend(List(String))
  /// (Re)start upstream with primary + extras.
  EnsureUpstream(primary: String, extras: List(String))
  /// Fetch REST history for a channel.
  FetchHistory(channel: String)
  /// Fetch public channel list.
  FetchChannels
  /// Probe freeq-server for an active AV call on a channel.
  FetchActiveCall(channel: String)
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
      authenticated: False,
      auth_handle: "",
      auth_did: "",
      api_bearer: None,
      av_active: False,
      av_call_present: False,
      av_session_id: None,
      av_channel: None,
      av_participant_count: 0,
      av_muted: False,
      av_camera: False,
      av_instance: generate_av_instance(),
      av_token: None,
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
          // Seed from directory when present (#test); host REST fills private
          // rooms (#freeq) and IRC 332 may refine further.
          let topic = rest.topic_for(model.all_channels, ch)
          let model = case model.av_active {
            True ->
              Model(
                ..model,
                view: Channel,
                channel: Some(ch),
                my_channels: my,
                messages: [],
                members: [],
                topic: topic,
                flash: "",
                av_channel: case model.av_channel {
                  Some(_) -> model.av_channel
                  None -> model.channel
                },
              )
            False ->
              Model(
                ..model,
                view: Channel,
                channel: Some(ch),
                my_channels: my,
                messages: [],
                members: [],
                topic: topic,
                flash: "",
                av_call_present: False,
                av_session_id: None,
                av_channel: None,
                av_participant_count: 0,
                av_muted: False,
                av_camera: False,
                av_instance: generate_av_instance(),
                av_token: None,
              )
          }
          #(
            model,
            multi_effect([
              EnsureUpstream(ch, list.filter(my, fn(c) { c != ch })),
              // JOIN + NAMES: re-open of an already-joined channel still refreshes
              // the userlist (some servers skip 353 on redundant JOIN).
              IrcSend(["JOIN " <> ch <> "\r\n", "NAMES " <> ch <> "\r\n"]),
              FetchHistory(ch),
              FetchActiveCall(ch),
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

    GoIndex ->
      // Keep AV state — browsing the directory must not leave the call.
      #(
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
      // Seed from directory when present (#test); host REST fills private
      // rooms (#freeq) and IRC 332 may refine further.
      let topic = rest.topic_for(model.all_channels, ch)
      let model = case model.av_active {
        True ->
          Model(
            ..model,
            view: Channel,
            channel: Some(ch),
            my_channels: my,
            messages: [],
            members: [],
            topic: topic,
            flash: "",
            av_channel: case model.av_channel {
              Some(_) -> model.av_channel
              None -> model.channel
            },
          )
        False ->
          Model(
            ..model,
            view: Channel,
            channel: Some(ch),
            my_channels: my,
            messages: [],
            members: [],
            topic: topic,
            flash: "",
            av_call_present: False,
            av_session_id: None,
            av_channel: None,
            av_participant_count: 0,
            av_muted: False,
            av_camera: False,
            av_instance: generate_av_instance(),
            av_token: None,
          )
      }
      #(
        model,
        multi_effect([
          EnsureUpstream(ch, list.filter(my, fn(c) { c != ch })),
          IrcSend(["JOIN " <> ch <> "\r\n", "NAMES " <> ch <> "\r\n"]),
          FetchHistory(ch),
          FetchActiveCall(ch),
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

    SetAuth(authenticated, handle, did) -> #(
      Model(
        ..model,
        authenticated: authenticated,
        auth_handle: handle,
        auth_did: did,
        nick: case authenticated && handle != "" {
          True -> render.sanitize_nick(handle)
          False -> model.nick
        },
      ),
      NoEffect,
    )

    SetApiBearer(bearer) -> #(
      Model(..model, api_bearer: Some(bearer), authenticated: True),
      NoEffect,
    )

    AvStart -> av_start_or_join(model)
    AvJoin -> av_start_or_join(model)
    AvLeave -> av_leave(model)
    AvToggleMute -> #(Model(..model, av_muted: !model.av_muted), NoEffect)
    AvToggleCamera -> #(Model(..model, av_camera: !model.av_camera), NoEffect)
    AvRoster(count) ->
      case count >= 0 {
        True -> #(Model(..model, av_participant_count: count), NoEffect)
        False -> #(model, NoEffect)
      }
    AvProbe(channel, call) -> apply_av_probe(model, channel, call)
  }
}

fn av_start_or_join(model: Model) -> #(Model, Effect) {
  case model.av_active {
    True -> #(model, NoEffect)
    False ->
      case model.channel {
        None -> #(Model(..model, flash: "Join a channel first"), NoEffect)
        Some(ch) -> {
          let instance = model.av_instance
          let line = case
            model.av_call_present,
            model.av_session_id
          {
            True, Some(sid) if sid != "" ->
              render.av_join_line(ch, sid, instance)
            _, _ -> render.av_start_line(ch, instance)
          }
          #(
            Model(
              ..model,
              av_active: True,
              av_channel: Some(ch),
              flash: "",
            ),
            IrcSend([line]),
          )
        }
      }
  }
}

fn av_leave(model: Model) -> #(Model, Effect) {
  let ch = case model.av_channel {
    Some(c) -> Some(c)
    None -> model.channel
  }
  let line = case ch, model.av_session_id {
    Some(c), Some(sid) if sid != "" ->
      Some(render.av_leave_line(c, sid, model.av_instance))
    _, _ -> None
  }
  let next =
    Model(
      ..model,
      av_active: False,
      av_call_present: False,
      av_session_id: None,
      av_channel: None,
      av_participant_count: 0,
      av_muted: False,
      av_camera: False,
      av_token: None,
    )
  case line {
    Some(l) -> #(next, IrcSend([l]))
    None -> #(next, NoEffect)
  }
}

fn apply_av_probe(
  model: Model,
  channel: String,
  call: Option(rest.ActiveCall),
) -> #(Model, Effect) {
  // Never overwrite an active local call (may be on another channel).
  case model.av_active {
    True -> #(model, NoEffect)
    False -> {
      let ch = render.canonical_channel(channel)
      let viewing = case model.channel {
        Some(c) -> c == ch
        None -> False
      }
      case viewing {
        False -> #(model, NoEffect)
        True ->
          case call {
            Some(info) if info.session_id != "" -> #(
              Model(
                ..model,
                av_call_present: True,
                av_session_id: Some(info.session_id),
                av_participant_count: info.participant_count,
              ),
              NoEffect,
            )
            _ -> #(
              Model(
                ..model,
                av_call_present: False,
                av_session_id: None,
                av_participant_count: 0,
              ),
              NoEffect,
            )
          }
      }
    }
  }
}

fn generate_av_instance() -> String {
  crypto.strong_random_bytes(4)
  |> bit_array.base16_encode
  |> string.lowercase
}

fn av_actor_is_self(model: Model, actor: String) -> Bool {
  case string.trim(actor) {
    "" -> False
    a -> {
      let a = string.lowercase(a)
      let candidates =
        [model.nick, model.auth_handle]
        |> list.filter(fn(n) { n != "" })
        |> list.map(string.lowercase)
      list.contains(candidates, a)
    }
  }
}

/// Collapse a list of effects into one (session host expands multi).
/// Prefer EnsureUpstream so the host opens IRC; after_join sends JOIN + history.
/// FetchActiveCall is applied by the host after join when present.
fn multi_effect(effects: List(Effect)) -> Effect {
  case effects {
    [EnsureUpstream(p, e), ..] -> EnsureUpstream(p, e)
    [other, ..] -> other
    [] -> NoEffect
  }
}

fn apply_line(model: Model, line: String) -> #(Model, Effect) {
  // AV token (directed to us) — preferred MoQ JWT path for guests + SASL.
  let own_nicks =
    [model.nick, model.auth_handle]
    |> list.filter(fn(n) { n != "" })
  case render.parse_av_token_tagmsg(line, own_nicks) {
    Some(#(sid, token)) if token != "" -> {
      let session_id = case sid {
        "" -> model.av_session_id
        s -> Some(s)
      }
      #(
        Model(..model, av_session_id: session_id, av_token: Some(token)),
        NoEffect,
      )
    }
    _ ->
      case render.parse_av_state_tagmsg(line) {
        Some(av) -> apply_av_state(model, av)
        None -> apply_line_chat(model, line)
      }
  }
}

fn apply_av_state(model: Model, av: render.AvState) -> #(Model, Effect) {
  let ch = render.canonical_channel(av.channel)
  let av_ch = case model.av_channel {
    Some(c) -> Some(render.canonical_channel(c))
    None -> None
  }
  let our_call =
    model.av_active
    && case av_ch {
      Some(c) -> c == ch
      None -> False
    }
  let view_channel = case model.channel {
    Some(c) -> c == ch
    None -> False
  }
  let state = string.lowercase(av.state)

  case state {
    "started" | "joined" -> {
      case model.av_active && !our_call {
        // Already in a different call — ignore.
        True -> #(model, NoEffect)
        False -> {
          let become_active = model.av_active || av_actor_is_self(model, av.actor)
          #(
            Model(
              ..model,
              av_call_present: True,
              av_session_id: case av.session_id {
                "" -> model.av_session_id
                s -> Some(s)
              },
              av_participant_count: av.participants,
              av_active: become_active,
              av_channel: case become_active {
                True -> Some(ch)
                False -> model.av_channel
              },
            ),
            NoEffect,
          )
        }
      }
    }
    "ended" ->
      case our_call || { view_channel && !model.av_active } {
        True -> #(
          Model(
            ..model,
            av_active: False,
            av_call_present: False,
            av_session_id: None,
            av_channel: None,
            av_participant_count: 0,
            av_muted: False,
            av_camera: False,
            av_token: None,
          ),
          NoEffect,
        )
        False -> #(model, NoEffect)
      }
    "left" ->
      case our_call || { view_channel && !model.av_active } {
        True -> #(
          Model(..model, av_participant_count: av.participants),
          NoEffect,
        )
        False -> #(model, NoEffect)
      }
    _ -> #(model, NoEffect)
  }
}

fn apply_line_chat(model: Model, line: String) -> #(Model, Effect) {
  // Topic
  case render.parse_topic(line) {
    Some(#(ch, topic)) ->
      case model.channel {
        Some(c) if c == ch -> #(Model(..model, topic: topic), NoEffect)
        _ -> #(model, NoEffect)
      }
    None ->
      // Member roster 353 (only for the channel currently in view)
      case render.is_353(line) {
        True ->
          case render.channel_from_353(line), model.channel {
            Some(ch), Some(c) if ch == c -> {
              let members =
                merge_members(model.members, render.parse_353_members(line))
              #(Model(..model, members: members), NoEffect)
            }
            _, _ -> #(model, NoEffect)
          }
        False ->
          case render.parse_mode_change(line) {
            Some(#(ch, ops)) ->
              case model.channel {
                Some(c) if c == ch -> #(
                  Model(
                    ..model,
                    members: render.apply_mode_ops(model.members, ops),
                  ),
                  NoEffect,
                )
                _ -> #(model, NoEffect)
              }
            None ->
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
                            halfop: False,
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
                        members: list.filter(model.members, fn(m) {
                          m.nick != nick
                        }),
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
                      case string.lowercase(m.nick) == string.lowercase(old) {
                        True ->
                          render.Member(
                            ..m,
                            nick: new,
                            color: render.nick_color_class(new),
                          )
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
  // Skip IRC chathistory / echo duplicates when msgid already present.
  let already = case row.msgid {
    Some(id) ->
      list.any(rows, fn(r) {
        case r.msgid {
          Some(existing) -> existing == id
          None -> r.id == id
        }
      })
    None -> False
  }
  case already {
    True -> rows
    False -> {
      let rows = list.append(rows, [row])
      let n = list.length(rows)
      case n > cap {
        True -> list.drop(rows, n - cap)
        False -> rows
      }
    }
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

/// Browser path for the current view (`/chat` or `/chat/freeq`).
/// Used by the client to keep the address bar in sync with LiveView state.
pub fn path_for_model(model: Model) -> String {
  case model.view, model.channel {
    Channel, Some(ch) -> channel_path(ch)
    _, _ -> "/chat"
  }
}

/// `/chat/<bare>` for a channel name (with or without `#`).
pub fn channel_path(channel: String) -> String {
  "/chat/" <> render.bare_channel(channel)
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
    stateful.route("av_start", fn(e) {
      event.decode_unit(e, "av_start", AvStart)
    }),
    stateful.route("av_join", fn(e) {
      event.decode_unit(e, "av_join", AvJoin)
    }),
    stateful.route("av_leave", fn(e) {
      event.decode_unit(e, "av_leave", AvLeave)
    }),
    stateful.route("av_toggle_mute", fn(e) {
      event.decode_unit(e, "av_toggle_mute", AvToggleMute)
    }),
    stateful.route("av_toggle_camera", fn(e) {
      event.decode_unit(e, "av_toggle_camera", AvToggleCamera)
    }),
    stateful.route("av_roster", fn(e) {
      event.decode_form(e, "av_roster", fn(data) {
        use raw <- result.try(form.require(data, "count"))
        case int.parse(raw) {
          Ok(n) -> Ok(AvRoster(n))
          Error(_) -> Ok(AvRoster(0))
        }
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
      // Channel chat: patch messages / compose separately so the compose
      // input is not remounted on every PRIVMSG (would drop focus + draft).
      // Index, or Index↔Channel: replace the whole main region.
      let acc = case before.view, after.view {
        Channel, Channel -> {
          let acc = maybe_region(before, after, "flash", flash_region, acc)
          let acc =
            maybe_region(before, after, "messages", messages_region, acc)
          maybe_region(before, after, "compose", compose_region, acc)
        }
        _, _ -> maybe_region(before, after, "main", main_region, acc)
      }
      // AV panel is a sibling of main so directory browse keeps the call.
      let acc = maybe_region(before, after, "av", av_region, acc)
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
  // Center column = main + av so AV survives index↔channel main swaps
  // (sibling region) while staying a vertical flex child of the chat column.
  "<div id=\"freeq-chat\" class=\"freeq-root\">"
  <> nav_region(model)
  <> "<div id=\"drawer-scrim\" aria-hidden=\"true\"></div>"
  <> "<div class=\"chat-body\">"
  <> sidebar_region(model)
  <> "<div class=\"chat-center\">"
  <> main_region(model)
  <> av_region(model)
  <> "</div>"
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
  let people_btn = case model.view {
    Channel ->
      "<button type=\"button\" class=\"mobile-btn\" data-drawer=\"members\" aria-label=\"People\">"
      <> "<svg viewBox=\"0 0 24 24\" aria-hidden=\"true\">"
      <> "<path d=\"M16 19v-1a4 4 0 0 0-4-4H7a4 4 0 0 0-4 4v1\" />"
      <> "<circle cx=\"9.5\" cy=\"8\" r=\"3.5\" />"
      <> "<path d=\"M20 19v-1a3.5 3.5 0 0 0-2.5-3.35\" />"
      <> "<path d=\"M16.5 4.6a3.5 3.5 0 0 1 0 6.8\" />"
      <> "</svg></button>"
    Index -> ""
  }
  "<nav data-ls-region=\"nav\">"
  <> "<button type=\"button\" class=\"mobile-btn\" data-drawer=\"sidebar\" aria-label=\"Channels\">"
  <> "<svg viewBox=\"0 0 24 24\" aria-hidden=\"true\"><path d=\"M4 7h16M4 12h16M4 17h16\" /></svg>"
  <> "</button>"
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
  <> av_call_button(model)
  <> "</div>"
  <> "<div class=\"nav-right\">"
  <> "<span id=\"status\" class=\""
  <> connected
  <> "\"><span class=\"dot\"></span><span>"
  <> render.escape_html(model.status)
  <> "</span></span>"
  <> people_btn
  <> auth_badge(model)
  <> "</div></nav>"
}

fn av_call_button(model: Model) -> String {
  let show = case model.view {
    Channel -> True
    Index -> model.av_active
  }
  case show {
    False -> ""
    True -> {
      let class = case model.av_active, model.av_call_present {
        True, _ -> "av-call-btn in-call"
        False, True -> "av-call-btn has-call"
        False, False -> "av-call-btn"
      }
      let action = case model.av_active, model.av_call_present {
        True, _ -> "av_leave"
        False, True -> "av_join"
        False, False -> "av_start"
      }
      let icon = case model.av_active, model.av_call_present {
        True, _ -> "📞"
        False, True -> "🔊"
        False, False -> "🎙️"
      }
      let call_ch = case model.av_channel {
        Some(c) -> c
        None -> option.unwrap(model.channel, "")
      }
      let title = case model.av_active, model.av_call_present {
        True, _ ->
          "In call on " <> call_ch <> " — click to leave"
        False, True -> {
          let n = model.av_participant_count
          let who = case n == 1 {
            True -> "person"
            False -> "people"
          }
          "Join voice call (" <> int.to_string(n) <> " " <> who <> ")"
        }
        False, False -> "Start voice call"
      }
      let badge = case model.av_active, model.av_call_present {
        False, True ->
          "<span class=\"av-call-badge\">"
          <> case model.av_participant_count {
            0 -> "!"
            n -> int.to_string(n)
          }
          <> "</span>"
        _, _ -> ""
      }
      "<button type=\"button\" id=\"av-call-btn\" class=\""
      <> class
      <> "\" data-ls-click=\""
      <> action
      <> "\" data-channel=\""
      <> render.escape_html(call_ch)
      <> "\" data-nick=\""
      <> render.escape_html(model.nick)
      <> "\" data-instance=\""
      <> render.escape_html(model.av_instance)
      <> "\" data-active=\""
      <> case model.av_active {
        True -> "true"
        False -> "false"
      }
      <> "\" title=\""
      <> render.escape_html(title)
      <> "\">"
      <> icon
      <> badge
      <> "</button>"
    }
  }
}

fn av_region(model: Model) -> String {
  case model.av_active {
    False -> "<div data-ls-region=\"av\" class=\"av-region empty\"></div>"
    True -> {
      let call_ch = case model.av_channel {
        Some(c) -> c
        None -> option.unwrap(model.channel, "")
      }
      let session = option.unwrap(model.av_session_id, "")
      let token = option.unwrap(model.av_token, "")
      let count = case model.av_participant_count {
        n if n > 0 -> n
        _ -> 1
      }
      let panel_class =
        "av-call-panel active"
        <> case model.av_camera {
          True -> " is-camera-on"
          False -> ""
        }
        <> case model.av_muted {
          True -> " is-muted"
          False -> ""
        }
      let mute_class =
        "av-call-action av-mute-btn"
        <> case model.av_muted {
          True -> " muted"
          False -> ""
        }
      let cam_class =
        "av-call-action av-cam-btn"
        <> case model.av_camera {
          True -> " on"
          False -> ""
        }
      "<div data-ls-region=\"av\">"
      <> "<div id=\"av-call-panel\" class=\""
      <> panel_class
      <> "\" data-channel=\""
      <> render.escape_html(call_ch)
      <> "\" data-nick=\""
      <> render.escape_html(model.nick)
      <> "\" data-instance=\""
      <> render.escape_html(model.av_instance)
      <> "\" data-session-id=\""
      <> render.escape_html(session)
      <> "\" data-moq-token=\""
      <> render.escape_html(token)
      <> "\" data-muted=\""
      <> bool_attr(model.av_muted)
      <> "\" data-camera=\""
      <> bool_attr(model.av_camera)
      <> "\" data-authenticated=\""
      <> bool_attr(model.authenticated)
      <> "\" data-av-origin=\""
      <> render.escape_html(config.av_origin())
      <> "\">"
      <> "<div class=\"av-call-bar\">"
      <> "<span class=\"av-call-status\">📞 "
      <> render.escape_html(call_ch)
      <> " · "
      <> int.to_string(count)
      <> " in call</span>"
      <> "<div class=\"av-call-actions\">"
      <> "<button type=\"button\" class=\""
      <> mute_class
      <> "\" data-ls-click=\"av_toggle_mute\" title=\""
      <> case model.av_muted {
        True -> "Unmute"
        False -> "Mute"
      }
      <> "\">"
      <> case model.av_muted {
        True -> "🎤 off"
        False -> "🎤 on"
      }
      <> "</button>"
      <> "<button type=\"button\" class=\""
      <> cam_class
      <> "\" data-ls-click=\"av_toggle_camera\" title=\""
      <> case model.av_camera {
        True -> "Turn off camera"
        False -> "Turn on camera"
      }
      <> "\">"
      <> case model.av_camera {
        True -> "📷 on"
        False -> "📷 off"
      }
      <> "</button>"
      <> "<button type=\"button\" class=\"av-call-action av-leave-btn\" data-ls-click=\"av_leave\" title=\"Leave call\">Leave</button>"
      <> "</div></div>"
      // Media tiles: client AvCall owns children; morph preserves #av-video-grid.
      <> "<div id=\"av-video-grid\" class=\"av-video-grid\" data-ls-ignore>"
      <> "<div class=\"av-tile av-tile-local\" id=\"av-local-tile\" title=\"Click to enlarge\" role=\"button\" tabindex=\"0\">"
      <> "<video id=\"av-local-video\" class=\"av-local-video\" autoplay muted playsinline hidden></video>"
      <> "<div class=\"av-tile-avatar local\">You</div>"
      <> "<span class=\"av-tile-label\">You</span>"
      <> "</div>"
      <> "<div id=\"av-remote-tiles\" class=\"av-remote-tiles\"></div>"
      <> "</div>"
      <> "<div id=\"av-publish-container\" class=\"av-publish-container\" data-ls-ignore></div>"
      <> "</div></div>"
    }
  }
}

fn bool_attr(b: Bool) -> String {
  case b {
    True -> "true"
    False -> "false"
  }
}

fn auth_badge(model: Model) -> String {
  case model.authenticated {
    True -> {
      let label = case model.auth_handle {
        "" -> model.nick
        h -> h
      }
      "<span class=\"auth-badge signed-in\" title=\""
      <> render.escape_html(model.auth_did)
      <> "\">👤 "
      <> render.escape_html(label)
      <> "</span>"
    }
    False ->
      "<span class=\"auth-badge guest\">👤 "
      <> render.escape_html(model.nick)
      <> "</span>"
  }
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
      <> "<a href=\""
      <> channel_path(ch)
      <> "\" class=\"channel-link\" data-ls-click=\"open\" data-ls-payload=\"channel="
      <> bare
      <> "\"><span class=\"channel-link-name\">"
      <> render.escape_html(ch)
      <> "</span></a>"
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
  <> user_handle_block(model)
  <> "<div class=\"user-actions\">"
  <> "<a href=\"/chat\" class=\"btn-link\" data-ls-click=\"go_index\">All channels</a>"
  <> auth_action(model)
  <> "</div></div></aside>"
}

fn user_handle_block(model: Model) -> String {
  case model.authenticated {
    True -> {
      let label = case model.auth_handle {
        "" -> model.nick
        h -> h
      }
      "<div class=\"user-handle signed-in\" id=\"user-handle\" title=\""
      <> render.escape_html(model.auth_did)
      <> "\">👤 "
      <> render.escape_html(label)
      <> "</div>"
    }
    False ->
      "<div class=\"user-handle guest\" id=\"user-handle\">👤 "
      <> render.escape_html(model.nick)
      <> "</div>"
  }
}

fn auth_action(model: Model) -> String {
  case model.authenticated {
    True -> "<a href=\"/logout\" class=\"btn-link\">Sign out</a>"
    False -> "<a href=\"/login\" class=\"btn-link\">Sign in</a>"
  }
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
      "<li><a href=\""
      <> channel_path(ch.name)
      <> "\" class=\"channel-item\" data-ls-click=\"open\" data-ls-payload=\"channel="
      <> bare
      <> "\"><span class=\"channel-name\">"
      <> render.escape_html(ch.name)
      <> "</span>"
      <> topic
      <> "<span class=\"channel-members\">"
      <> int.to_string(ch.members)
      <> "</span></a></li>"
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
  // Nested regions: messages updates must not remount #send-form.
  "<section class=\"chat-main\" data-ls-region=\"main\">"
  <> flash_region(model)
  <> messages_region(model)
  <> compose_region(model)
  <> "</section>"
}

fn flash_region(model: Model) -> String {
  let inner = case model.flash {
    "" -> ""
    f -> "<div class=\"flash\">" <> render.escape_html(f) <> "</div>"
  }
  "<div data-ls-region=\"flash\">" <> inner <> "</div>"
}

fn messages_region(model: Model) -> String {
  let msgs =
    list.map(model.messages, message_html)
    |> string.concat
  "<div id=\"messages\" class=\"messages\" data-ls-region=\"messages\">"
  <> msgs
  <> "</div>"
}

fn compose_region(model: Model) -> String {
  // IDs match app.css / freeq-web2 (#send-bar, #attach-btn, #upload-preview).
  // No value attr on the text input: draft is client-owned so message patches
  // never wipe it. Image paste/upload is handled client-side (POST /upload).
  let ch = option.unwrap(model.channel, "")
  let auth_did = case model.authenticated {
    True -> model.auth_did
    False -> ""
  }
  "<div id=\"compose-stack\" data-ls-region=\"compose\">"
  <> "<div id=\"upload-preview\" class=\"upload-preview\" hidden>"
  <> "<img id=\"upload-preview-img\" alt=\"preview\" />"
  <> "<div class=\"upload-preview-meta\">"
  <> "<span id=\"upload-preview-name\"></span>"
  <> "<span id=\"upload-preview-status\"></span>"
  <> "</div>"
  <> "<button type=\"button\" id=\"upload-preview-cancel\" class=\"btn-link\" title=\"Cancel\">×</button>"
  <> "</div>"
  <> "<div id=\"send-bar\">"
  <> "<input type=\"file\" id=\"file-input\" accept=\"image/*,image/png,image/jpeg,image/gif,image/webp\" hidden />"
  <> "<button type=\"button\" id=\"attach-btn\" class=\"attach-btn\" title=\"Upload screenshot or image\" aria-label=\"Upload image\">+</button>"
  <> "<form id=\"send-form\" data-ls-submit=\"send\" data-channel=\""
  <> render.escape_html(ch)
  <> "\" data-auth-did=\""
  <> render.escape_html(auth_did)
  <> "\">"
  <> "<input id=\"message-input\" type=\"text\" name=\"msg\" placeholder=\"Message "
  <> render.escape_html(ch)
  <> "… (paste images)\" autocomplete=\"off\" autofocus />"
  <> "<button type=\"submit\">Send</button>"
  <> "</form>"
  <> "</div></div>"
}

fn message_html(row: render.Row) -> String {
  // Match freeq-web3 row shape: 2-column grid `.ts` | `.body` (nick inline).
  let kind = render.kind_class(row.kind)
  let nick = case row.nick {
    Some(n) ->
      "<span class=\"nick "
      <> row.color
      <> "\">"
      <> render.escape_html(n)
      <> "</span> "
    None -> ""
  }
  let own = case row.own {
    True -> " own"
    False -> ""
  }
  let data_nick = case row.nick {
    Some(n) -> " data-nick=\"" <> render.escape_html(n) <> "\""
    None -> ""
  }
  "<div class=\"row "
  <> kind
  <> own
  <> "\" data-msgid=\""
  <> render.escape_html(option.unwrap(row.msgid, row.id))
  <> "\""
  <> data_nick
  <> ">"
  <> "<span class=\"ts\">"
  <> render.escape_html(row.time_label)
  <> "</span>"
  <> "<span class=\"body\">"
  <> nick
  <> render.linkify_html(row.text)
  <> "</span></div>"
}

fn members_region(model: Model) -> String {
  case model.view {
    Index ->
      "<aside id=\"member-panel\" data-ls-region=\"members\" class=\"hidden\"></aside>"
    Channel -> {
      let sorted = render.sort_members(model.members)
      let items = case sorted {
        [] -> "<div class=\"member empty\">—</div>"
        _ ->
          list.map(sorted, fn(m) {
            let pfx = render.member_prefix_char(m)
            let pfx_class = render.member_prefix_class(m)
            let pfx_cls = case pfx_class {
              "" -> "pfx"
              c -> "pfx " <> c
            }
            // data-nick drives Tab complete; prefix is display-only.
            "<div class=\"member\" data-nick=\""
            <> render.escape_html(m.nick)
            <> "\"><span class=\""
            <> pfx_cls
            <> "\">"
            <> render.escape_html(pfx)
            <> "</span><span class=\"nick "
            <> m.color
            <> "\">"
            <> render.escape_html(m.nick)
            <> "</span></div>"
          })
          |> string.concat
      }
      let count = list.length(sorted)
      let heading = case count {
        0 ->
          case model.ws {
            WsReady -> "People · joining…"
            _ -> "People"
          }
        n -> "People · " <> int.to_string(n)
      }
      "<aside id=\"member-panel\" data-ls-region=\"members\">"
      <> "<p class=\"member-heading\">"
      <> heading
      <> "</p>"
      <> "<div id=\"member-list\">"
      <> items
      <> "</div></aside>"
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

/// Replace the client-authoritative channel list (session restore).
pub fn with_my_channels(model: Model, channels: List(String)) -> Model {
  Model(..model, my_channels: channels)
}

/// Restore a previously persisted freeq-server API-BEARER without flipping
/// `authenticated` (SASL still has to succeed on the wire).
pub fn with_api_bearer(model: Model, bearer: Option(String)) -> Model {
  Model(..model, api_bearer: bearer)
}

/// Merge path-seeded channels with a persisted list (path first, then rest).
pub fn merge_my_channels(
  seed: List(String),
  persisted: List(String),
) -> List(String) {
  list.fold(persisted, seed, list_unique_append)
}

/// Merge REST history with any live rows already on the model.
///
/// REST is the chronological base; live-only rows (msgid not in REST) are
/// appended so a post-SASL backfill does not drop messages that arrived
/// while the first anonymous fetch was empty.
pub fn merge_history_rows(
  rest_rows: List(render.Row),
  live_rows: List(render.Row),
) -> List(render.Row) {
  case rest_rows {
    [] -> live_rows
    _ ->
      list.fold(live_rows, rest_rows, fn(acc, row) {
        case row_msgid_known(acc, row) {
          True -> acc
          False -> list.append(acc, [row])
        }
      })
  }
}

fn row_msgid_known(rows: List(render.Row), row: render.Row) -> Bool {
  case row.msgid {
    Some(id) ->
      list.any(rows, fn(r) {
        case r.msgid {
          Some(existing) -> existing == id
          None -> r.id == id
        }
      })
    None ->
      // No msgid: match on stable row id when present.
      case row.id {
        "" -> False
        id -> list.any(rows, fn(r) { r.id == id })
      }
  }
}
