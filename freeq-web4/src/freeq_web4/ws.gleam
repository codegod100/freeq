//// Lightspeed live-session host over Mist WebSockets.
////
//// Bridges the protocol to freeq's chat LiveView and the IRC upstream:
//// 1. Client connects → hello + start guest IRC + REST channel list
//// 2. Client sends `event|ref|name|payload` → live.apply → Diff patches
//// 3. Upstream IRC lines → live.apply(PushLine) → Diff patches
//// 4. Effects: EnsureUpstream / IrcSend / FetchHistory / FetchChannels

import freeq_web4/irc/render
import freeq_web4/irc/upstream
import freeq_web4/live
import freeq_web4/rest
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import lightspeed/diff
import lightspeed/event
import lightspeed/protocol
import mist

/// Parent-facing messages selected on the Mist websocket process.
pub type Push {
  UpstreamEvent(upstream.Event)
  RestChannels(List(rest.ChannelInfo))
  RestHistory(List(render.Row))
}

pub type Session {
  Session(
    model: live.Model,
    path: String,
    next_ref: Int,
    upstream: Option(upstream.Handle),
    /// Receives Push messages (IRC bridge + future async REST).
    self_subject: Subject(Push),
  )
}

/// Mount a connected LiveView session for `path` (e.g. `/chat` or `/chat/freeq`).
pub fn mount(
  path: String,
  self_subject: Subject(Push),
) -> #(Session, List(String)) {
  let model = live.mount_model(path)
  let session =
    Session(
      model: model,
      path: path,
      next_ref: 1,
      upstream: None,
      self_subject: self_subject,
    )

  let session = bootstrap(session)
  #(session, [protocol.encode(protocol.hello())])
}

fn bootstrap(session: Session) -> Session {
  let channels = rest.fetch_channels()
  let #(model, _) = live.apply(session.model, live.SetAllChannels(channels))
  let session = Session(..session, model: model)

  case session.model.channel {
    Some(ch) -> {
      let extras = list.filter(session.model.my_channels, fn(c) { c != ch })
      let session = ensure_upstream(session, ch, extras)
      let history = rest.fetch_history(ch, 50, None)
      let #(model, _) = live.apply(session.model, live.SetHistory(history))
      Session(..session, model: model)
    }
    None -> session
  }
}

/// Handle one inbound Lightspeed protocol frame.
pub fn handle_frame(
  session: Session,
  payload: String,
) -> #(Session, List(String)) {
  case protocol.decode(payload) {
    Error(err) -> #(session, [
      protocol.encode(protocol.Failure(
        ref: "",
        reason: protocol.decode_error_to_string(err),
      )),
    ])

    Ok(frame) ->
      case frame {
        protocol.Event(ref, name, event_payload) ->
          apply_client_event(session, ref, name, event_payload)

        protocol.Ack(_) -> #(session, [])

        protocol.Hello(_, _) -> #(session, [
          protocol.encode(protocol.Failure(
            ref: "",
            reason: "unsupported_client_frame:hello",
          )),
        ])

        protocol.Diff(ref, _) -> #(session, [
          protocol.encode(protocol.Failure(
            ref: ref,
            reason: "unsupported_client_frame:diff",
          )),
        ])

        protocol.Failure(_, _) -> #(session, [])
      }
  }
}

/// Handle a server-side push (IRC / REST).
pub fn handle_push(session: Session, push: Push) -> #(Session, List(String)) {
  case push {
    UpstreamEvent(ev) -> apply_upstream(session, ev)
    RestChannels(chs) -> {
      let before = session.model
      let #(model, _) = live.apply(before, live.SetAllChannels(chs))
      finish(session, before, model)
    }
    RestHistory(rows) -> {
      let before = session.model
      let #(model, _) = live.apply(before, live.SetHistory(rows))
      finish(session, before, model)
    }
  }
}

fn apply_client_event(
  session: Session,
  ref: String,
  name: String,
  payload: String,
) -> #(Session, List(String)) {
  case live.decode_event(name, payload) {
    Error(err) -> #(session, [
      protocol.encode(protocol.Failure(
        ref: ref,
        reason: event.error_to_string(err),
      )),
    ])
    Ok(msg) -> {
      let before = session.model
      let #(model, effect) = live.apply(before, msg)
      let session = Session(..session, model: model)
      let session = run_effect(session, effect)
      let session = case msg {
        live.Join(_) | live.OpenChannel(_) -> after_join(session)
        live.GoIndex -> {
          let chs = rest.fetch_channels()
          let #(model, _) = live.apply(session.model, live.SetAllChannels(chs))
          Session(..session, model: model)
        }
        _ -> session
      }
      let patches = live.plan_patches(before, session.model)
      let frames = patches_to_frames(session, ref, patches)
      let session = case patches {
        [] -> session
        _ -> Session(..session, next_ref: session.next_ref + 1)
      }
      #(session, frames)
    }
  }
}

fn after_join(session: Session) -> Session {
  case session.model.channel {
    Some(ch) -> {
      let history = rest.fetch_history(ch, 50, None)
      let #(model, _) = live.apply(session.model, live.SetHistory(history))
      case session.upstream {
        Some(handle) -> upstream.send(handle, "JOIN " <> ch <> "\r\n")
        None -> Nil
      }
      Session(..session, model: model)
    }
    None -> session
  }
}

fn apply_upstream(
  session: Session,
  ev: upstream.Event,
) -> #(Session, List(String)) {
  let before = session.model
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
    upstream.Down(reason) -> {
      let #(m, _) = live.apply(before, live.SetWs(live.WsDisconnected))
      live.apply(m, live.SetFlash("upstream: " <> reason))
    }
  }
  let session = Session(..session, model: model)
  let session = run_effect(session, effect)
  let session = case ev {
    upstream.Down(_) -> Session(..session, upstream: None)
    _ -> session
  }
  finish(session, before, session.model)
}

fn finish(
  session: Session,
  before: live.Model,
  after: live.Model,
) -> #(Session, List(String)) {
  let session = Session(..session, model: after)
  let patches = live.plan_patches(before, after)
  case patches {
    [] -> #(session, [])
    _ -> {
      let patch_ref = int.to_string(session.next_ref)
      let frames = [
        protocol.encode(protocol.Diff(
          ref: patch_ref,
          html: diff.encode_stream(patches),
        )),
      ]
      #(Session(..session, next_ref: session.next_ref + 1), frames)
    }
  }
}

fn patches_to_frames(
  session: Session,
  client_ref: String,
  patches: List(diff.Patch),
) -> List(String) {
  case patches {
    [] -> [protocol.encode(protocol.Ack(ref: client_ref))]
    _ -> {
      let patch_ref = int.to_string(session.next_ref)
      [
        protocol.encode(protocol.Diff(
          ref: patch_ref,
          html: diff.encode_stream(patches),
        )),
        protocol.encode(protocol.Ack(ref: client_ref)),
      ]
    }
  }
}

fn run_effect(session: Session, effect: live.Effect) -> Session {
  case effect {
    live.NoEffect -> session

    live.IrcSend(lines) -> {
      case session.upstream {
        Some(handle) -> {
          list.each(lines, fn(line) { upstream.send(handle, line) })
          session
        }
        None -> {
          let primary = case session.model.channel {
            Some(ch) -> ch
            None ->
              case session.model.my_channels {
                [ch, ..] -> ch
                [] -> "#freeq"
              }
          }
          let session = ensure_upstream(session, primary, [])
          case session.upstream {
            Some(handle) -> {
              list.each(lines, fn(line) { upstream.send(handle, line) })
              session
            }
            None -> session
          }
        }
      }
    }

    live.EnsureUpstream(primary, extras) ->
      ensure_upstream(session, primary, extras)

    live.FetchHistory(channel) -> {
      let rows = rest.fetch_history(channel, 50, None)
      let #(model, _) = live.apply(session.model, live.SetHistory(rows))
      Session(..session, model: model)
    }

    live.FetchChannels -> {
      let chs = rest.fetch_channels()
      let #(model, _) = live.apply(session.model, live.SetAllChannels(chs))
      Session(..session, model: model)
    }

    live.StopUpstream -> {
      case session.upstream {
        Some(handle) -> upstream.stop(handle)
        None -> Nil
      }
      Session(..session, upstream: None)
    }
  }
}

fn ensure_upstream(
  session: Session,
  primary: String,
  extras: List(String),
) -> Session {
  case session.upstream {
    Some(_) -> session
    None -> {
      let events: Subject(upstream.Event) = process.new_subject()
      let parent = session.self_subject
      case upstream.start(events, primary, extras) {
        Error(reason) -> {
          process.send(parent, UpstreamEvent(upstream.Down(reason)))
          session
        }
        Ok(handle) -> {
          // Relay IRC events onto the Mist websocket selector subject.
          let _ = process.spawn(fn() { relay_forever(events, parent) })
          Session(..session, upstream: Some(handle))
        }
      }
    }
  }
}

fn relay_forever(from: Subject(upstream.Event), to: Subject(Push)) -> Nil {
  let ev = process.receive_forever(from)
  process.send(to, UpstreamEvent(ev))
  relay_forever(from, to)
}

/// Selector for upstream/REST pushes (use with mist.with_selector).
pub fn push_selector(session: Session) -> process.Selector(Push) {
  process.new_selector()
  |> process.select(session.self_subject)
}

/// Send outbound protocol frames.
pub fn push_frames(
  conn: mist.WebsocketConnection,
  frames: List(String),
) -> Nil {
  list.each(frames, fn(frame) {
    let _ = mist.send_text_frame(conn, frame)
    Nil
  })
}

/// Tear down IRC on socket close.
pub fn close(session: Session) -> Nil {
  case session.upstream {
    Some(handle) -> upstream.stop(handle)
    None -> Nil
  }
}
