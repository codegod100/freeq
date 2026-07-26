//// Lightspeed live-session host over Mist WebSockets.
////
//// Bridges the protocol to freeq's chat LiveView and the IRC upstream:
//// 1. Client connects → hello + start IRC (guest or SASL) + REST channel list
//// 2. Client sends `event|ref|name|payload` → live.apply → Diff patches
//// 3. Upstream IRC lines → live.apply(PushLine) → Diff patches
//// 4. Effects: EnsureUpstream / IrcSend / FetchHistory / FetchChannels

import freeq_web4/atproto/oauth_session.{type OAuthSession}
import freeq_web4/irc/render
import freeq_web4/irc/upstream
import freeq_web4/live
import freeq_web4/rest
import freeq_web4/session_store
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import lightspeed/diff
import lightspeed/event
import lightspeed/protocol
import mist

/// Parent-facing messages selected on the Mist websocket process.
pub type Push {
  /// Deferred after `on_init` so Mist never times out the upgrade.
  DoBootstrap
  /// IRC upstream event (line, ready, SASL, down, …).
  UpstreamEvent(upstream.Event)
  /// REST channel directory result.
  RestChannels(List(rest.ChannelInfo))
  /// REST history fetch result for the viewed channel.
  RestHistory(List(render.Row))
}

/// One connected LiveView browser session: model, IRC upstream, OAuth.
pub type Session {
  Session(
    model: live.Model,
    path: String,
    next_ref: Int,
    upstream: Option(upstream.Handle),
    /// Browser cookie session id (OAuth credentials key).
    session_id: String,
    /// Loaded OAuth credentials (if any).
    oauth: Option(OAuthSession),
    /// Receives Push messages (IRC bridge + future async REST).
    self_subject: Subject(Push),
    /// Owned by the Mist websocket process. Upstream sends `Event`s here;
    /// `push_selector` maps them to `UpstreamEvent`. Do not create a relay
    /// process for this subject — only the owner can receive on it.
    events: Subject(upstream.Event),
  )
}

/// Mount a connected LiveView session for `path` (e.g. `/chat` or `/chat/freeq`).
///
/// Keep this **fast**: no REST/IRC. Callers must schedule `DoBootstrap` on
/// `self_subject` after the Mist websocket process is running.
///
/// Must be called on the Mist websocket process so `events` is owned there.
pub fn mount(
  path: String,
  self_subject: Subject(Push),
  session_id: String,
) -> #(Session, List(String)) {
  let model = live.mount_model(path)
  // Restore "My channels" from disk so refresh keeps the sidebar + re-JOINs.
  // Re-save so a direct /chat/foo URL also lands in the persisted list.
  let persisted = session_store.load_channels(session_id)
  let my = live.merge_my_channels(model.my_channels, persisted)
  let model = live.with_my_channels(model, my)
  session_store.save_channels(session_id, my)
  // Prior API-BEARER (if still accepted) lets bootstrap load private-channel
  // history (#freeq) before the new IRC connection finishes SASL.
  let model =
    live.with_api_bearer(model, session_store.load_api_bearer(session_id))
  let oauth = case session_store.load(session_id) {
    Ok(s) -> Some(s)
    Error(_) -> None
  }
  let model = case oauth {
    Some(s) -> {
      let #(m, _) =
        live.apply(
          model,
          live.SetAuth(authenticated: False, handle: s.handle, did: s.did),
        )
      // Credentials present — show handle as pending SASL (not yet authenticated
      // on the wire). Nick will update on Ready/SASL.
      let #(m, _) =
        live.apply(m, live.SetFlash("Signing in as " <> s.handle <> "…"))
      m
    }
    None -> model
  }
  let session =
    Session(
      model: model,
      path: path,
      next_ref: 1,
      upstream: None,
      session_id: session_id,
      oauth: oauth,
      self_subject: self_subject,
      events: process.new_subject(),
    )

  #(session, [protocol.encode(protocol.hello())])
}

/// Queue deferred bootstrap (REST + IRC). Safe to call from `on_init`.
pub fn schedule_bootstrap(self_subject: Subject(Push)) -> Nil {
  process.send(self_subject, DoBootstrap)
}

fn bootstrap(session: Session) -> Session {
  let channels = rest.fetch_channels()
  let #(model, _) = live.apply(session.model, live.SetAllChannels(channels))
  let session = Session(..session, model: model)

  case session.model.channel {
    Some(ch) -> {
      let extras = list.filter(session.model.my_channels, fn(c) { c != ch })
      let session = ensure_upstream(session, ch, extras)
      let bearer = session.model.api_bearer
      // REST body first; CHATHISTORY (on Ready / after_join) fills reactions.
      let history = rest.fetch_history(ch, 50, bearer)
      let #(model, _) = live.apply(session.model, live.SetHistory(history))
      // Public list + per-channel topic endpoint (private rooms like #freeq
      // are omitted from /channels; IRC 332 may also skip on reconnect).
      let topic = rest.resolve_topic(channels, ch)
      let #(model, _) = live.apply(model, live.SetTopicText(topic))
      let session = Session(..session, model: model)
      apply_active_call_probe(session, ch)
    }
    None ->
      // Index: re-JOIN restored my_channels; OAuth still opens IRC for SASL
      // when the list is empty (empty primary → CAP END only).
      case session.model.my_channels, session.oauth {
        [], None -> session
        my, _ -> ensure_upstream(session, "", my)
      }
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

/// Handle a server-side push (IRC / REST / deferred bootstrap).
pub fn handle_push(session: Session, push: Push) -> #(Session, List(String)) {
  case push {
    DoBootstrap -> {
      let before = session.model
      let session = bootstrap(session)
      finish(session, before, session.model)
    }
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
      // Join/part/navigate mutates client-authoritative list — persist for refresh.
      let session = case msg {
        live.Join(_) | live.OpenChannel(_) | live.Part(_) -> {
          session_store.save_channels(
            session.session_id,
            session.model.my_channels,
          )
          session
        }
        _ -> session
      }
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
      // REST body first (no +freeq.at/reactions). Then CHATHISTORY attaches
      // tallies onto matching msgids via parse_history_reactions.
      let history = rest.fetch_history(ch, 50, session.model.api_bearer)
      let #(model, _) = live.apply(session.model, live.SetHistory(history))
      // Seed nav topic from public list + REST fallback. IRC 332 still
      // overwrites later; redundant JOIN often skips 332 entirely.
      let topic = rest.resolve_topic(session.model.all_channels, ch)
      let #(model, _) = live.apply(model, live.SetTopicText(topic))
      case session.upstream {
        Some(handle) -> {
          // JOIN for membership. NAMES always refreshes the People panel —
          // freeq may skip 353 on a redundant JOIN, and CAP-time JOIN can
          // race registration so the first 353 never lands.
          upstream.send(handle, "JOIN " <> ch <> "\r\n")
          upstream.send(handle, "NAMES " <> ch <> "\r\n")
          // Explicit TOPIC query when already joined (no 332 on re-JOIN).
          upstream.send(handle, "TOPIC " <> ch <> "\r\n")
          // Reaction tallies ride CHATHISTORY (not REST) — request after body.
          request_chathistory(handle, ch)
        }
        None -> Nil
      }
      let session = Session(..session, model: model)
      apply_active_call_probe(session, ch)
    }
    None -> session
  }
}

/// Ask freeq-server for recent PRIVMSGs with `+freeq.at/reactions` tags.
fn request_chathistory(handle: upstream.Handle, channel: String) -> Nil {
  case channel == "" || channel == "#" {
    True -> Nil
    False ->
      upstream.send(handle, render.chathistory_latest_line(channel, 50))
  }
}

fn apply_active_call_probe(session: Session, channel: String) -> Session {
  case session.model.av_active {
    True -> session
    False -> {
      // Private channels need API-BEARER; guest probes get 403 upstream.
      let call =
        rest.probe_active_call(channel, session.model.api_bearer)
      let #(model, _) =
        live.apply(session.model, live.AvProbe(channel, call))
      Session(..session, model: model)
    }
  }
}

/// Re-fetch REST history for the viewed channel and merge with any live rows.
/// No-op when not on a channel view.
fn backfill_channel_history(
  model: live.Model,
  bearer: Option(String),
) -> live.Model {
  case model.channel {
    None -> model
    Some(ch) -> {
      let rows = rest.fetch_history(ch, 50, bearer)
      let merged = live.merge_history_rows(rows, model.messages)
      let #(model, _) = live.apply(model, live.SetHistory(merged))
      // Topic for private rooms is also often empty until we are authorized.
      let topic = case model.topic {
        "" -> rest.resolve_topic(model.all_channels, ch)
        t -> t
      }
      let #(model, _) = live.apply(model, live.SetTopicText(topic))
      model
    }
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
    upstream.Sasl(upstream.SaslPending) ->
      live.apply(before, live.SetFlash("SASL…"))
    upstream.Sasl(upstream.SaslOk) -> {
      let handle = case session.oauth {
        Some(s) -> s.handle
        None -> before.auth_handle
      }
      let did = case session.oauth {
        Some(s) -> s.did
        None -> before.auth_did
      }
      let #(m, _) =
        live.apply(
          before,
          live.SetAuth(authenticated: True, handle: handle, did: did),
        )
      live.apply(m, live.SetFlash(""))
    }
    upstream.Sasl(upstream.SaslFailed) ->
      live.apply(before, live.SetFlash("SASL failed — continuing as guest"))
    upstream.ApiBearer(bearer) -> {
      session_store.save_api_bearer(session.session_id, bearer)
      let #(m, _) = live.apply(before, live.SetApiBearer(bearer))
      // Bootstrap often fetched history before SASL (guest / stale bearer).
      // Private rooms (#freeq) 403 without a valid API-BEARER, and IRC
      // chathistory is suppressed — re-fetch once the bearer lands (web3
      // auth_history_backfill).
      let m = backfill_channel_history(m, Some(bearer))
      // REST still omits +freeq.at/reactions; re-request CHATHISTORY after
      // the authorized body lands so chips survive refresh/SASL.
      case session.upstream, m.channel {
        Some(handle), Some(ch) -> request_chathistory(handle, ch)
        _, _ -> Nil
      }
      // Navigate/join often runs FetchActiveCall before SASL finishes; private
      // rooms (e.g. #freeq) 403 without the bearer. Re-probe once it lands.
      case m.av_active, m.channel {
        False, Some(ch) -> {
          let call = rest.probe_active_call(ch, Some(bearer))
          live.apply(m, live.AvProbe(ch, call))
        }
        _, _ -> #(m, live.NoEffect)
      }
    }
    // Token refresh / DPoP nonce — keep disk credentials current so SASL
    // still works after process restart (refresh tokens rotate).
    upstream.AuthUpdated(_) -> #(before, live.NoEffect)
    upstream.Down(reason) -> {
      let #(m, _) = live.apply(before, live.SetWs(live.WsDisconnected))
      live.apply(m, live.SetFlash("upstream: " <> reason))
    }
  }
  let session = case ev {
    upstream.AuthUpdated(oauth) -> {
      session_store.save(session.session_id, oauth)
      Session(..session, oauth: Some(oauth), model: model)
    }
    _ -> Session(..session, model: model)
  }
  let session = run_effect(session, effect)
  // Join-failure (477 policy, etc.) may need an IRC reply.
  let session = case ev {
    upstream.Line(line) -> handle_join_failure(session, line)
    _ -> session
  }
  let session = case ev {
    upstream.Down(_) -> Session(..session, upstream: None)
    // Registration finished: re-assert JOIN + NAMES so the People panel fills
    // even if the CAP-time JOIN raced the server's registration gate.
    // Only on Ready (nick) — ReadyState is paired with it and would double-fire.
    upstream.Ready(_) -> rejoin_and_names(session)
    upstream.Sasl(upstream.SaslOk) -> {
      // Re-JOIN channels post-SASL so membership is under the real DID.
      // OAuth is already persisted on AuthUpdated (refresh / DPoP nonce).
      post_sasl_rejoin(session)
    }
    _ -> session
  }
  finish(session, before, session.model)
}

fn rejoin_and_names(session: Session) -> Session {
  case session.upstream {
    None -> session
    Some(handle) -> {
      let channels = case session.model.channel {
        Some(ch) -> [ch, ..list.filter(session.model.my_channels, fn(c) { c != ch })]
        None -> session.model.my_channels
      }
      list.each(channels, fn(ch) {
        case ch == "" || ch == "#" {
          True -> Nil
          False -> {
            upstream.send(handle, "JOIN " <> ch <> "\r\n")
            upstream.send(handle, "NAMES " <> ch <> "\r\n")
          }
        }
      })
      // Hydrate reactions for the channel in view (REST body already loaded).
      case session.model.channel {
        Some(ch) -> request_chathistory(handle, ch)
        None -> Nil
      }
      session
    }
  }
}

fn post_sasl_rejoin(session: Session) -> Session {
  case session.upstream {
    None -> session
    Some(handle) -> {
      list.each(session.model.my_channels, fn(ch) {
        upstream.send(handle, "JOIN " <> ch <> "\r\n")
        upstream.send(handle, "NAMES " <> ch <> "\r\n")
      })
      // Post-SASL REST backfill may have just replaced the pane — re-request
      // CHATHISTORY so +freeq.at/reactions lands on the new rows.
      case session.model.channel {
        Some(ch) -> request_chathistory(handle, ch)
        None -> Nil
      }
      session
    }
  }
}

/// Auto POLICY ACCEPT + re-JOIN for policy-gated channels (web3 parity).
fn handle_join_failure(session: Session, line: String) -> Session {
  case render.parse_join_failure(line) {
    None -> session
    Some(#(ch, _numeric, trailing)) -> {
      let needs_policy =
        session.model.authenticated
        && string.contains(string.lowercase(trailing), "policy acceptance")
      case needs_policy, session.upstream {
        True, Some(handle) -> {
          let #(model, _) =
            live.apply(
              session.model,
              live.SetFlash(ch <> " requires policy acceptance — accepting…"),
            )
          upstream.send(handle, "POLICY " <> ch <> " ACCEPT\r\n")
          // Re-JOIN after a short delay is ideal; best-effort immediate retry.
          upstream.send(handle, "JOIN " <> ch <> "\r\n")
          upstream.send(handle, "NAMES " <> ch <> "\r\n")
          Session(..session, model: model)
        }
        _, _ -> {
          let #(model, _) =
            live.apply(
              session.model,
              live.SetFlash("Could not join " <> ch <> ": " <> trailing),
            )
          Session(..session, model: model)
        }
      }
    }
  }
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
      let rows = rest.fetch_history(channel, 50, session.model.api_bearer)
      // SetHistory merges reaction tallies with any live/CHATHISTORY state.
      let #(model, _) = live.apply(session.model, live.SetHistory(rows))
      // After REST body, request CHATHISTORY so chips reappear on refresh.
      case session.upstream {
        Some(handle) -> request_chathistory(handle, channel)
        None -> Nil
      }
      Session(..session, model: model)
    }

    live.FetchChannels -> {
      let chs = rest.fetch_channels()
      let #(model, _) = live.apply(session.model, live.SetAllChannels(chs))
      Session(..session, model: model)
    }

    live.FetchActiveCall(channel) -> apply_active_call_probe(session, channel)

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
      // Always re-read disk so a peer tab's refresh-token rotation is picked up
      // before we open another SASL connection with a dead RT.
      let oauth = case session_store.load(session.session_id) {
        Ok(s) -> Some(s)
        Error(_) -> session.oauth
      }
      let session = Session(..session, oauth: oauth)
      let auth = case oauth {
        Some(s) -> upstream.OAuth(s)
        None -> upstream.Guest
      }
      case
        upstream.start(
          session.events,
          primary,
          extras,
          auth,
          session.session_id,
        )
      {
        Error(reason) -> {
          process.send(
            session.self_subject,
            UpstreamEvent(upstream.Down(reason)),
          )
          session
        }
        Ok(handle) -> Session(..session, upstream: Some(handle))
      }
    }
  }
}

/// Selector for upstream/REST pushes (use with mist.with_selector).
pub fn push_selector(session: Session) -> process.Selector(Push) {
  process.new_selector()
  |> process.select(session.self_subject)
  |> process.select_map(session.events, UpstreamEvent)
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

/// Tear down IRC on socket close (leave AV first so peers see us drop).
pub fn close(session: Session) -> Nil {
  case session.model.av_active, session.upstream {
    True, Some(handle) -> {
      let ch = case session.model.av_channel {
        Some(c) -> Some(c)
        None -> session.model.channel
      }
      case ch, session.model.av_session_id {
        Some(c), Some(sid) if sid != "" ->
          upstream.send(
            handle,
            render.av_leave_line(c, sid, session.model.av_instance),
          )
        _, _ -> Nil
      }
      upstream.stop(handle)
    }
    _, Some(handle) -> upstream.stop(handle)
    _, None -> Nil
  }
}
