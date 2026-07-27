//// Bridges freeq-web4 ↔ freeq-gtk over Erlang dist.
////
//// The bridge owns a Live model for GTK and its **own** IRC upstream so
//// compose/send/join work without a browser tab:
//// - LiveView sessions `publish` to overwrite the model (browser keeps it fresh)
//// - GTK UI events are applied here; `IrcSend` / `EnsureUpstream` run on the
////   bridge IRC connection (not dropped)
//// - Events are also fanned out to registered LiveView sessions (browser sync);
////   LiveView skips re-sending PRIVMSG for those events to avoid doubles
//// - Upstream lines update the model and push a full View to freeq-gtk

import freeq_web4/config
import freeq_web4/irc/render
import freeq_web4/irc/upstream
import freeq_web4/live
import freeq_web4/pane
import freeq_web4/rest
import freeq_web4/ui
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import logging

// ── FFI ──────────────────────────────────────────────────────────────────────

@external(erlang, "freeq_web4_gtk_ffi", "start_dist")
fn start_dist_ffi(name: String, cookie: String) -> Result(Nil, String)

@external(erlang, "freeq_web4_gtk_ffi", "register_freeq_view")
fn register_freeq_view_ffi() -> Bool

@external(erlang, "freeq_web4_gtk_ffi", "connect")
fn connect_ffi(node: String) -> Bool

@external(erlang, "freeq_web4_gtk_ffi", "push_view")
fn push_view_ffi(node: String, view: ui.View) -> Result(Nil, String)

@external(erlang, "freeq_web4_gtk_ffi", "put_bridge")
fn put_bridge_ffi(subject: Subject(Msg)) -> Nil

@external(erlang, "freeq_web4_gtk_ffi", "get_bridge")
fn get_bridge_ffi() -> Result(Subject(Msg), Nil)

@external(erlang, "freeq_web4_gtk_ffi", "decode_event")
fn decode_event_ffi(raw: Dynamic) -> ui.Event

// ── Bridge protocol ──────────────────────────────────────────────────────────

type Msg {
  Publish(live.Model)
  Register(Subject(ui.Event))
  Unregister(Subject(ui.Event))
  /// REST channel list finished (bootstrap / refresh).
  ChannelsLoaded(List(rest.ChannelInfo))
  /// REST history finished for a channel open.
  HistoryLoaded(
    channel: String,
    rows: List(render.Row),
    topic: String,
  )
  /// Raw mailbox term from freeq-gtk (clicked / activate / …).
  DistTerm(Dynamic)
  /// IRC upstream event (line, ready, conn state, down).
  Upstream(upstream.Event)
}

type State {
  State(
    cmd: Subject(Msg),
    gtk_node: String,
    subs: List(Subject(ui.Event)),
    /// GTK-facing model (updated by LiveView publish + local event apply).
    model: live.Model,
    /// Dedicated IRC connection for GTK send/join (guest for now).
    upstream: Option(upstream.Handle),
    /// Subject that receives `upstream.Event` (owned by bridge process).
    irc_events: Subject(upstream.Event),
    /// Outbound IRC lines queued until the bridge socket is Ready **and**
    /// membership for the active room is Joined (avoids 404 +n races).
    pending_out: List(String),
    /// Last PRIVMSG batch put on the wire (re-queued after 404 +n).
    last_out: List(String),
  )
}

// ── Public API ───────────────────────────────────────────────────────────────

/// Start Erlang dist (if configured) and the freeq_view bridge process.
pub fn start() -> Nil {
  case config.gtk_enabled() {
    False -> {
      logging.log(
        logging.Info,
        "gtk bridge disabled (set FREEQ_GTK_NODE to enable)",
      )
    }
    True -> {
      let dist_name = config.dist_node()
      let cookie = config.dist_cookie()
      let gtk_node = config.gtk_node()
      case start_dist_ffi(dist_name, cookie) {
        Error(e) ->
          logging.log(logging.Warning, "gtk dist start failed: " <> e)
        Ok(_) -> {
          logging.log(
            logging.Info,
            "gtk dist node "
              <> dist_name
              <> " cookie set; gtk peer "
              <> gtk_node,
          )
          let ready = process.new_subject()
          let _ =
            process.spawn(fn() {
              let cmd = process.new_subject()
              let irc_events = process.new_subject()
              let _ = register_freeq_view_ffi()
              put_bridge_ffi(cmd)
              let model = live.mount_model("/chat")
              process.send(ready, Nil)
              schedule_fetch_channels(cmd)
              let state =
                State(
                  cmd: cmd,
                  gtk_node: gtk_node,
                  subs: [],
                  model: model,
                  upstream: None,
                  irc_events: irc_events,
                  pending_out: [],
                  last_out: [],
                )
              // Open guest IRC immediately so the first Send can succeed.
              let state = ensure_upstream(state, "", [])
              let _ = do_push(state.gtk_node, state.model)
              loop(state)
            })
          let _ = process.receive(ready, 2000)
          let _ = connect_ffi(gtk_node)
          Nil
        }
      }
    }
  }
}

/// Push a full View snapshot (and refresh bridge model from LiveView).
pub fn publish(model: live.Model) -> Nil {
  case config.gtk_enabled() {
    False -> Nil
    True ->
      case get_bridge_ffi() {
        Ok(cmd) -> process.send(cmd, Publish(model))
        Error(_) -> Nil
      }
  }
}

/// LiveView session wants a copy of GTK events (browser stays in sync).
pub fn register(sub: Subject(ui.Event)) -> Nil {
  case get_bridge_ffi() {
    Ok(cmd) -> process.send(cmd, Register(sub))
    Error(_) -> Nil
  }
}

pub fn unregister(sub: Subject(ui.Event)) -> Nil {
  case get_bridge_ffi() {
    Ok(cmd) -> process.send(cmd, Unregister(sub))
    Error(_) -> Nil
  }
}

// ── Loop ─────────────────────────────────────────────────────────────────────

fn loop(state: State) -> Nil {
  let msg =
    process.new_selector()
    |> process.select(state.cmd)
    |> process.select_map(state.irc_events, Upstream)
    |> process.select_other(fn(raw) { DistTerm(raw) })
    |> process.selector_receive_forever

  let state = case msg {
    Publish(model) -> {
      // Keep connection labels / nick from the bridge IRC — browser publish
      // must not clobber Ready with the LiveView's separate socket state.
      //
      // Critical: browser `pane.Joined` means *browser* IRC is in the room.
      // Bridge has its own IRC socket — never inherit browser Joined/Blocked.
      // If *this* bridge already confirmed JOIN for the same room, keep
      // `Joined` so PRIVMSG is not stuck behind a perpetual re-JOIN race
      // (LiveView publish on every keystroke used to reset membership).
      let prev_ch = live.current_channel(state.model)
      let model =
        live.Model(
          ..model,
          ws: state.model.ws,
          status: state.model.status,
          nick: case state.model.nick {
            "" -> model.nick
            n -> n
          },
          pane: merge_publish_pane(state.model.pane, model.pane),
        )
      let state = State(..state, model: model)
      let state = case live.current_channel(state.model), prev_ch {
        Some(ch), Some(old) if ch == old ->
          case pane.is_joined(state.model.pane) {
            // Already in the room on the bridge socket — do not thrash JOIN.
            True -> state
            False -> join_channel(state, ch)
          }
        Some(_), _ -> after_join(state)
        None, _ -> state
      }
      // If publish restored Joined, release any queued PRIVMSGs.
      let state = flush_pending(state)
      let _ = do_push(state.gtk_node, state.model)
      state
    }
    Register(sub) -> State(..state, subs: [sub, ..state.subs])
    Unregister(sub) ->
      State(..state, subs: list.filter(state.subs, fn(s) { s != sub }))
    ChannelsLoaded(chs) -> {
      let #(model, _) = live.apply(state.model, live.SetAllChannels(chs))
      let state = State(..state, model: model)
      let _ = do_push(state.gtk_node, state.model)
      state
    }
    HistoryLoaded(channel, rows, topic) ->
      case live.current_channel(state.model) {
        Some(ch) if ch == channel -> {
          // Always merge REST into the active room. Cold open needs a body;
          // cache-hit re-entry needs a freshness refresh (GTK has no second
          // LiveView history path). merge_history_rows is chronological.
          let #(model, _) = live.apply(state.model, live.SetTopicText(topic))
          let #(model, _) = live.apply(model, live.SetHistory(rows))
          let state = State(..state, model: model)
          let _ = do_push(state.gtk_node, state.model)
          state
        }
        _ -> state
      }
    DistTerm(raw) -> handle_dist_event(state, raw)
    Upstream(ev) -> handle_upstream(state, ev)
  }
  loop(state)
}

fn handle_dist_event(state: State, raw: Dynamic) -> State {
  let event = decode_event_ffi(raw)
  logging.log(logging.Info, "gtk event: " <> string_event(event))

  // Fan-out to LiveView sessions (browser follows GTK UI). LiveView must not
  // re-PRIVMSG — bridge owns IRC for gtk-originated sends.
  list.each(state.subs, fn(sub) { process.send(sub, event) })

  case live.ui_to_msg(event, state.model) {
    None -> {
      logging.log(logging.Info, "gtk event ignored (no msg mapping)")
      state
    }
    Some(msg) -> {
      let before = live.view(state.model)
      // If Send is blocked (stale +n after browser Publish), clear block and
      // re-JOIN before applying so this keystroke can still go out.
      let state = case msg {
        live.Send(_) -> ensure_joined_for_send(state)
        _ -> state
      }
      let #(model, effect) = live.apply(state.model, msg)
      let state = State(..state, model: model)
      let _ = do_push(state.gtk_node, state.model)
      let after = live.view(state.model)
      logging.log(
        logging.Info,
        "gtk applied → pane "
          <> pane_label(before)
          <> " → "
          <> pane_label(after)
          <> case live.current_channel(state.model) {
            Some(ch) -> " " <> ch
            None -> ""
          },
      )
      // When IRC is not Ready yet, `live.Send` only nudges EnsureUpstream and
      // drops the PRIVMSG — queue it so the first keypress after open works.
      let state = case msg, effect {
        live.Send(_text), live.IrcSend(lines) -> send_or_queue(state, lines)
        live.Send(text), other -> {
          let state = run_effect(state, other)
          queue_send_text(state, text)
        }
        _, _ -> run_effect(state, effect)
      }
      // JOIN/NAMES after navigate so membership is live (send needs +n etc.).
      case msg {
        live.Join(_) | live.OpenChannel(_) -> after_join(state)
        live.Part(_) -> state
        _ -> state
      }
    }
  }
}

/// Merge browser paint state into the bridge pane without stealing membership.
///
/// - Different / new room → Joining (bridge must JOIN its own socket)
/// - Same room and bridge already Joined → keep Joined
/// - Same room but bridge still Joining/Blocked → keep bridge membership
///   (do not adopt browser Joined)
fn merge_publish_pane(bridge: pane.Pane, browser: pane.Pane) -> pane.Pane {
  case browser, bridge {
    pane.InRoom(br), pane.InRoom(bb) ->
      case pane.same_room(bridge, br.name) {
        True ->
          pane.InRoom(
            pane.RoomState(
              ..br,
              // Bridge socket authority for membership only.
              membership: bb.membership,
            ),
          )
        False ->
          pane.InRoom(
            pane.RoomState(..br, membership: pane.Joining),
          )
      }
    pane.InRoom(br), _ ->
      pane.InRoom(pane.RoomState(..br, membership: pane.Joining))
    other, _ -> other
  }
}

/// Before Send: clear Blocked / stale Joined, re-assert JOIN.
///
/// PRIVMSG is held in `pending_out` until `on_channel` (Joined + self in
/// roster when the roster is non-empty). Always re-sends JOIN — safe if
/// already present, recovers after silent PART/reconnect.
fn ensure_joined_for_send(state: State) -> State {
  case live.current_channel(state.model) {
    None -> state
    Some(ch) -> {
      let on_chan = on_channel(state)
      let state = ensure_upstream(state, ch, other_channels(state, ch))
      // Always re-assert JOIN (idempotent when already a member).
      let state = join_channel(state, ch)
      case on_chan {
        True -> state
        False -> {
          // Clear Blocked / stale Joined so live.Send emits IrcSend → queue.
          let model =
            live.Model(
              ..state.model,
              pane: pane.open_cached(
                ch,
                pane.history_exhausted(state.model.pane),
              ),
              flash: "Joining " <> ch <> "…",
            )
          State(..state, model: model)
        }
      }
    }
  }
}

/// True when this bridge socket is safe to PRIVMSG the active room.
///
/// Requires pane Joined **and**, once a NAMES roster has arrived, that our
/// nick is on it. Stale `Joined` after a silent leave used to fire 404 +n.
fn on_channel(state: State) -> Bool {
  case pane.is_joined(state.model.pane) {
    False -> False
    True ->
      case state.model.members {
        // Roster not loaded yet — trust the Joined flag from 353/self JOIN.
        [] -> True
        _ -> self_in_roster(state.model)
      }
  }
}

fn self_in_roster(model: live.Model) -> Bool {
  let nick = string.lowercase(string.trim(model.nick))
  case nick == "" {
    True -> False
    False ->
      list.any(model.members, fn(m) {
        string.lowercase(m.nick) == nick
      })
  }
}

/// Build a plain PRIVMSG when `live.Send` did not emit IrcSend.
fn queue_send_text(state: State, text: String) -> State {
  let text = string.trim(text)
  case text == "", live.current_channel(state.model) {
    True, _ -> state
    _, None -> state
    _, Some(ch) -> {
      let line = "PRIVMSG " <> ch <> " :" <> text <> "\r\n"
      let #(model, _) = live.apply(state.model, live.SetCompose(""))
      let state = State(..state, model: model)
      let _ = do_push(state.gtk_node, state.model)
      send_or_queue(state, [line])
    }
  }
}

fn handle_upstream(state: State, ev: upstream.Event) -> State {
  let before = state.model
  let was_on = on_channel(state)
  let #(model, effect) = case ev {
    upstream.Line(line) -> live.apply(before, live.PushLine(line))
    upstream.ConnState(upstream.Connecting) ->
      live.apply(before, live.SetWs(live.WsConnecting))
    upstream.ConnState(upstream.Registering) ->
      live.apply(before, live.SetWs(live.WsRegistering))
    upstream.ConnState(upstream.ReadyState) ->
      live.apply(before, live.SetWs(live.WsReady))
    upstream.ConnState(upstream.Disconnected) ->
      live.apply(before, live.SetWs(live.WsDisconnected))
    upstream.Ready(nick) -> live.apply(before, live.SetNick(nick))
    upstream.Sasl(_) -> #(before, live.NoEffect)
    upstream.ApiBearer(bearer) -> live.apply(before, live.SetApiBearer(bearer))
    upstream.AuthUpdated(_) -> #(before, live.NoEffect)
    upstream.Down(reason) -> {
      let #(m, _) = live.apply(before, live.SetWs(live.WsDisconnected))
      live.apply(m, live.SetFlash("upstream: " <> reason))
    }
  }
  let state = case ev {
    upstream.Down(_) ->
      State(..state, model: model, upstream: None, last_out: [])
    _ -> State(..state, model: model)
  }
  let state = run_effect(state, effect)
  // 404 +n marks Blocked — re-JOIN and re-queue the PRIVMSG that failed.
  let state = recover_join_if_blocked(state)
  let state = case ev {
    // Registration done: re-assert JOIN/NAMES; flush only once on-channel.
    upstream.Ready(_) -> rejoin_and_names(state)
    _ -> state
  }
  // Flush queued PRIVMSGs when we become on-channel (353 / self JOIN / roster).
  let state = case was_on, on_channel(state) {
    False, True -> flush_pending(state)
    _, True -> flush_pending(state)
    _, False -> state
  }
  let _ = do_push(state.gtk_node, state.model)
  state
}

/// After a cannot-send / join failure, force Joining + JOIN and re-queue
/// the last on-wire PRIVMSG (otherwise the user keystroke is lost).
fn recover_join_if_blocked(state: State) -> State {
  case state.model.pane {
    pane.InRoom(pane.RoomState(membership: pane.Blocked(_), name: ch, ..)) -> {
      logging.log(
        logging.Info,
        "gtk bridge re-JOIN after block on "
          <> ch
          <> " (re-queue "
          <> int.to_string(list.length(state.last_out))
          <> " line(s))",
      )
      let model =
        live.Model(
          ..state.model,
          pane: pane.remount_joining(state.model.pane),
          flash: "Rejoining " <> ch <> "…",
        )
      let pending =
        list.append(state.pending_out, state.last_out)
      let state =
        State(..state, model: model, pending_out: pending, last_out: [])
      join_channel(state, ch)
    }
    _ -> state
  }
}

fn run_effect(state: State, effect: live.Effect) -> State {
  case effect {
    live.NoEffect -> state

    live.EnsureUpstream(primary, extras) -> {
      let state = ensure_upstream(state, primary, extras)
      // If already connected, still JOIN the primary channel.
      case primary {
        "" -> state
        ch -> join_channel(state, ch)
      }
    }

    live.FetchChannels -> {
      schedule_fetch_channels(state.cmd)
      state
    }

    live.FetchHistory(channel) -> {
      schedule_fetch_history(state.cmd, channel, state.model.api_bearer)
      state
    }

    live.IrcSend(lines) -> send_or_queue(state, lines)

    // GTK shell does not need AV/search/embed side effects.
    _ -> state
  }
}

fn send_or_queue(state: State, lines: List(String)) -> State {
  case lines {
    [] -> state
    _ ->
      case wire_ready(state) {
        True -> {
          // On-channel + Ready — send now.
          flush_lines(state, lines)
        }
        False -> {
          // Not on channel yet: queue and make sure JOIN is out.
          logging.log(
            logging.Info,
            "gtk irc queue "
              <> int.to_string(list.length(lines))
              <> " line(s) until on-channel (membership="
              <> membership_label(state.model.pane)
              <> " roster_self="
              <> case self_in_roster(state.model) {
                True -> "yes"
                False -> "no"
              }
              <> " ws="
              <> ws_label(state.model.ws)
              <> ")",
          )
          let state = case live.current_channel(state.model) {
            Some(ch) -> {
              let state =
                ensure_upstream(state, ch, other_channels(state, ch))
              join_channel(state, ch)
            }
            None -> state
          }
          State(
            ..state,
            pending_out: list.append(state.pending_out, lines),
          )
        }
      }
  }
}

/// PRIVMSG only when Ready and actually on the channel (see `on_channel`).
fn wire_ready(state: State) -> Bool {
  case state.upstream, state.model.ws, on_channel(state) {
    Some(_), live.WsReady, True -> True
    _, _, _ -> False
  }
}

fn flush_lines(state: State, lines: List(String)) -> State {
  case state.upstream {
    Some(handle) -> {
      list.each(lines, fn(line) {
        logging.log(logging.Info, "gtk irc out: " <> string.trim(line))
        upstream.send(handle, line)
      })
      // Remember for 404 +n recovery.
      State(..state, last_out: lines)
    }
    None ->
      State(..state, pending_out: list.append(state.pending_out, lines))
  }
}

fn flush_pending(state: State) -> State {
  case state.pending_out {
    [] -> state
    lines ->
      case wire_ready(state) {
        False -> state
        True -> {
          list.each(lines, fn(line) {
            logging.log(logging.Info, "gtk irc flush: " <> string.trim(line))
            case state.upstream {
              Some(handle) -> upstream.send(handle, line)
              None -> Nil
            }
          })
          State(..state, pending_out: [], last_out: lines)
        }
      }
  }
}

fn membership_label(p: pane.Pane) -> String {
  case p {
    pane.InRoom(pane.RoomState(membership: pane.Joined, ..)) -> "joined"
    pane.InRoom(pane.RoomState(membership: pane.Joining, ..)) -> "joining"
    pane.InRoom(pane.RoomState(membership: pane.Blocked(r), ..)) ->
      "blocked:" <> r
    pane.Directory -> "directory"
    pane.System -> "system"
  }
}

fn ws_label(ws: live.WsLabel) -> String {
  case ws {
    live.WsDisconnected -> "disconnected"
    live.WsConnecting -> "connecting"
    live.WsRegistering -> "registering"
    live.WsReady -> "ready"
  }
}

fn ensure_upstream(
  state: State,
  primary: String,
  extras: List(String),
) -> State {
  case state.upstream {
    Some(_) -> state
    None -> {
      logging.log(
        logging.Info,
        "gtk bridge starting guest IRC (primary="
          <> primary
          <> ")",
      )
      case
        upstream.start(
          state.irc_events,
          primary,
          extras,
          upstream.Guest,
          "",
        )
      {
        Error(reason) -> {
          logging.log(
            logging.Warning,
            "gtk bridge IRC start failed: " <> reason,
          )
          let #(model, _) =
            live.apply(state.model, live.SetFlash("IRC: " <> reason))
          State(..state, model: model)
        }
        Ok(handle) -> State(..state, upstream: Some(handle))
      }
    }
  }
}

fn after_join(state: State) -> State {
  case live.current_channel(state.model) {
    None -> state
    Some(ch) -> {
      let state = ensure_upstream(state, ch, other_channels(state, ch))
      let state = join_channel(state, ch)
      // Always refresh REST body for the open room.
      schedule_fetch_history(state.cmd, ch, state.model.api_bearer)
      state
    }
  }
}

fn other_channels(state: State, primary: String) -> List(String) {
  list.filter(state.model.my_channels, fn(c) { c != primary })
}

fn join_channel(state: State, ch: String) -> State {
  case state.upstream {
    None -> state
    Some(handle) -> {
      case ch == "" || ch == "#" {
        True -> state
        False -> {
          upstream.send(handle, "JOIN " <> ch <> "\r\n")
          upstream.send(handle, "NAMES " <> ch <> "\r\n")
          upstream.send(handle, "TOPIC " <> ch <> "\r\n")
          state
        }
      }
    }
  }
}

fn rejoin_and_names(state: State) -> State {
  case live.current_channel(state.model) {
    Some(ch) -> join_channel(state, ch)
    None -> state
  }
  |> fn(s) {
    // Also JOIN other my_channels so we receive multi-room traffic.
    case s.upstream {
      None -> s
      Some(handle) -> {
        list.each(s.model.my_channels, fn(ch) {
          case live.current_channel(s.model) {
            Some(cur) if cur == ch -> Nil
            _ -> {
              let _ = upstream.send(handle, "JOIN " <> ch <> "\r\n")
              Nil
            }
          }
        })
        s
      }
    }
  }
}

fn do_push(gtk_node: String, model: live.Model) -> Nil {
  let view = live.view_tree(model)
  case push_view_ffi(gtk_node, view) {
    Ok(_) -> Nil
    Error(_) -> {
      let _ = connect_ffi(gtk_node)
      let _ = push_view_ffi(gtk_node, view)
      Nil
    }
  }
}

fn schedule_fetch_channels(cmd: Subject(Msg)) -> Nil {
  let _ =
    process.spawn_unlinked(fn() {
      let chs = rest.fetch_channels()
      process.send(cmd, ChannelsLoaded(chs))
    })
  Nil
}

fn schedule_fetch_history(
  cmd: Subject(Msg),
  channel: String,
  bearer: Option(String),
) -> Nil {
  let _ =
    process.spawn_unlinked(fn() {
      let rows =
        rest.fetch_history(channel, live.history_page_size, bearer, None)
      let topic = rest.topic_for(rest.fetch_channels(), channel)
      process.send(cmd, HistoryLoaded(channel, rows, topic))
    })
  Nil
}

fn string_event(event: ui.Event) -> String {
  case event {
    ui.Clicked(id) -> "clicked:" <> id
    ui.Activate(id, text) -> "activate:" <> id <> ":" <> text
    ui.Changed(id, _) -> "changed:" <> id
    ui.Selected(id, index, _) ->
      "selected:" <> id <> ":" <> int.to_string(index)
    ui.Unknown(raw) -> "unknown:" <> raw
  }
}

fn pane_label(v: live.View) -> String {
  case v {
    live.Index -> "index"
    live.System -> "system"
    live.Channel -> "channel"
  }
}
