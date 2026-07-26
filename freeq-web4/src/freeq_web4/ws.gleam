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
import freeq_web4/link_preview
import freeq_web4/live
import freeq_web4/profiles
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
  /// REST history (+ topic / optional AV probe) for a channel open.
  /// May be stale if the user already navigated away — always check `channel`.
  RestChannelOpen(
    channel: String,
    rows: List(render.Row),
    topic: String,
    /// `None` = AV not probed (call already active); `Some` = probe result.
    av_call: Option(Option(rest.ActiveCall)),
  )
  /// Background channel FTS finished (may be stale if query moved on).
  RestSearch(
    query: String,
    results: List(render.Row),
    status: String,
  )
  /// Background link-preview resolve finished for one message row.
  MessageEmbed(row_id: String, embed: render.Embed)
  /// Several link-preview resolves finished (one Diff, not N morphs).
  MessageEmbeds(List(#(String, render.Embed)))
  /// Background AT profile avatar resolve finished for a DID.
  AvatarReady(did: String, url: String)
  /// Several avatar resolves finished (one Diff after channel open / history).
  AvatarsReady(List(#(String, String)))
  /// Embeds + avatars from one history warmup (single Diff after open).
  MediaReady(
    embeds: List(#(String, render.Embed)),
    avatars: List(#(String, String)),
  )
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
    /// Nested IRCv3 `BATCH` depth. While > 0, IRC line model updates are
    /// applied without Diff frames; one Diff flushes when depth returns to 0.
    /// Stops CHATHISTORY reaction hydration from remounting `#messages` N times.
    irc_batch_depth: Int,
    /// Model snapshot at outermost BATCH open — `plan_patches` baseline.
    irc_batch_before: Option(live.Model),
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
      irc_batch_depth: 0,
      irc_batch_before: None,
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
      // Seed topic from the public directory immediately; private rooms
      // get a second fill from async REST when the open job returns.
      let topic = rest.topic_for(channels, ch)
      let #(model, _) = live.apply(session.model, live.SetTopicText(topic))
      let model = live.with_history_loading(model, True)
      let session = Session(..session, model: model)
      // Do not block bootstrap Diff on history / AV REST.
      schedule_channel_open_rest(session, ch)
      session
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
    RestChannelOpen(channel, rows, topic, av_call) ->
      apply_rest_channel_open(session, channel, rows, topic, av_call)
    RestSearch(query, results, status) -> {
      let before = session.model
      let #(model, effect) =
        live.apply(before, live.SetSearchResults(query, results, status))
      let session = Session(..session, model: model)
      let session = run_effect(session, effect)
      finish(session, before, session.model)
    }
    MessageEmbed(row_id, embed) -> {
      let before = session.model
      let #(model, _) = live.apply(before, live.PatchEmbed(row_id, embed))
      finish(session, before, model)
    }
    MessageEmbeds(pairs) -> {
      let before = session.model
      case pairs {
        [] -> #(session, [])
        _ -> {
          let #(model, _) = live.apply(before, live.PatchEmbeds(pairs))
          finish(session, before, model)
        }
      }
    }
    AvatarReady(did, url) -> {
      let before = session.model
      let #(model, _) = live.apply(before, live.PatchAvatar(did, url))
      finish(session, before, model)
    }
    AvatarsReady(pairs) -> {
      let before = session.model
      case pairs {
        [] -> #(session, [])
        _ -> {
          let #(model, _) = live.apply(before, live.PatchAvatars(pairs))
          finish(session, before, model)
        }
      }
    }
    MediaReady(embeds, avatars) -> {
      let before = session.model
      case embeds, avatars {
        [], [] -> #(session, [])
        _, _ -> {
          let model = case embeds {
            [] -> before
            pairs -> {
              let #(m, _) = live.apply(before, live.PatchEmbeds(pairs))
              m
            }
          }
          let model = case avatars {
            [] -> model
            pairs -> {
              let #(m, _) = live.apply(model, live.PatchAvatars(pairs))
              m
            }
          }
          finish(session, before, model)
        }
      }
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
      // IRC first so membership / topic / NAMES start immediately. REST
      // history + AV probe run off-process so the channel-switch Diff is not
      // blocked on HTTP (was the main multi-second lag on navigate).
      // Cache hits restore messages already — skip REST, still CHATHISTORY
      // for reaction tags and optionally re-probe AV.
      case session.upstream {
        Some(handle) -> {
          // JOIN for membership. NAMES always refreshes the People panel —
          // freeq may skip 353 on a redundant JOIN, and CAP-time JOIN can
          // race registration so the first 353 never lands.
          upstream.send(handle, "JOIN " <> ch <> "\r\n")
          upstream.send(handle, "NAMES " <> ch <> "\r\n")
          // Explicit TOPIC query when already joined (no 332 on re-JOIN).
          upstream.send(handle, "TOPIC " <> ch <> "\r\n")
          case session.model.history_loading {
            // Cache hit: rows already on the model — hydrate reactions now.
            False -> request_chathistory(handle, ch)
            // Cache miss: CHATHISTORY after REST body (apply_rest_channel_open).
            True -> Nil
          }
        }
        None -> Nil
      }
      case session.model.history_loading {
        True -> schedule_channel_open_rest(session, ch)
        False ->
          // Cached page: light AV probe only (no history re-fetch).
          case session.model.av_active {
            True -> Nil
            False -> schedule_av_probe_only(session, ch)
          }
      }
      session
    }
    None -> session
  }
}

/// Background AV call probe without re-fetching history (cache-hit path).
fn schedule_av_probe_only(session: Session, channel: String) -> Nil {
  let subject = session.self_subject
  let bearer = session.model.api_bearer
  let ch = channel
  let _ =
    process.spawn_unlinked(fn() {
      let call = rest.probe_active_call(ch, bearer)
      process.send(
        subject,
        RestChannelOpen(
          channel: ch,
          rows: [],
          topic: "",
          av_call: Some(call),
        ),
      )
    })
  Nil
}

/// Background REST for channel open: history body, topic fallback, AV probe.
///
/// Results land as `RestChannelOpen` and are ignored if the user already left
/// the channel (fast sidebar clicks must not clobber the new view).
fn schedule_channel_open_rest(session: Session, channel: String) -> Nil {
  let subject = session.self_subject
  let bearer = session.model.api_bearer
  let all = session.model.all_channels
  let probe_av = !session.model.av_active
  let ch = channel
  let _ =
    process.spawn_unlinked(fn() {
      let rows =
        rest.fetch_history(ch, live.history_page_size, bearer, None)
      // Public list first; private rooms need a second REST round-trip.
      let topic = rest.resolve_topic(all, ch)
      let av_call = case probe_av {
        True -> Some(rest.probe_active_call(ch, bearer))
        False -> None
      }
      process.send(
        subject,
        RestChannelOpen(channel: ch, rows: rows, topic: topic, av_call: av_call),
      )
    })
  Nil
}

/// Apply a finished channel-open REST job, or drop it if navigation moved on.
fn apply_rest_channel_open(
  session: Session,
  channel: String,
  rows: List(render.Row),
  topic: String,
  av_call: Option(Option(rest.ActiveCall)),
) -> #(Session, List(String)) {
  case session.model.channel {
    Some(current) ->
      case same_channel(current, channel) {
        False -> #(session, [])
        True -> {
          let before = session.model
          // Cache-hit opens send empty rows + AV only — never wipe restored
          // messages or flip history_exhausted from a dummy SetHistory([]).
          let need_history = before.history_loading
          let #(model, effect) = case need_history {
            True -> live.apply(before, live.SetHistory(rows))
            False -> #(before, live.NoEffect)
          }
          // Prefer REST topic when we have one; keep directory/IRC seed otherwise.
          let #(model, _) = case topic {
            "" -> #(model, live.NoEffect)
            t -> live.apply(model, live.SetTopicText(t))
          }
          let #(model, _) = case av_call {
            None -> #(model, live.NoEffect)
            Some(call) -> live.apply(model, live.AvProbe(channel, call))
          }
          // Reaction tallies ride CHATHISTORY (not REST) — after first body.
          // Cache hits already requested CHATHISTORY in after_join.
          case need_history, session.upstream {
            True, Some(handle) -> request_chathistory(handle, channel)
            _, _ -> Nil
          }
          let session = Session(..session, model: model)
          let session = run_effect(session, effect)
          finish(session, before, session.model)
        }
      }
    None -> #(session, [])
  }
}

fn same_channel(a: String, b: String) -> Bool {
  string.lowercase(render.canonical_channel(a))
  == string.lowercase(render.canonical_channel(b))
}

/// Ask freeq-server for recent PRIVMSGs with `+freeq.at/reactions` tags.
fn request_chathistory(handle: upstream.Handle, channel: String) -> Nil {
  case channel == "" || channel == "#" {
    True -> Nil
    False ->
      upstream.send(
        handle,
        render.chathistory_latest_line(channel, live.history_page_size),
      )
  }
}

/// Reaction hydration for a scroll-up page (messages before `before_ts`).
fn request_chathistory_before(
  handle: upstream.Handle,
  channel: String,
  before_ts: Int,
) -> Nil {
  case channel == "" || channel == "#" {
    True -> Nil
    False ->
      upstream.send(
        handle,
        render.chathistory_before_line(
          channel,
          before_ts,
          live.history_page_size,
        ),
      )
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
/// No-op when not on a channel view. Schedules link-preview warmup.
fn backfill_channel_history(
  session: Session,
  bearer: Option(String),
) -> Session {
  case session.model.channel {
    None -> session
    Some(ch) -> {
      let rows = rest.fetch_history(ch, live.history_page_size, bearer, None)
      let merged = live.merge_history_rows(rows, session.model.messages)
      let #(model, effect) = live.apply(session.model, live.SetHistory(merged))
      // Topic for private rooms is also often empty until we are authorized.
      let topic = case model.topic {
        "" -> rest.resolve_topic(model.all_channels, ch)
        t -> t
      }
      let #(model, _) = live.apply(model, live.SetTopicText(topic))
      let session = Session(..session, model: model)
      run_effect(session, effect)
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
      // auth_history_backfill). Embed warmup is scheduled inside backfill.
      let session = backfill_channel_history(
        Session(..session, model: m),
        Some(bearer),
      )
      let m = session.model
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
  // IRCv3 BATCH: apply every line to the model, but emit at most one Diff
  // when the outermost batch closes (CHATHISTORY reaction hydrate, multiline).
  case ev {
    upstream.Line(line) -> finish_irc_line(session, before, line)
    _ -> finish(session, before, session.model)
  }
}

/// Diff policy for one IRC line: suppress while nested in BATCH, flush on close.
fn finish_irc_line(
  session: Session,
  line_before: live.Model,
  line: String,
) -> #(Session, List(String)) {
  case render.parse_batch_control(line) {
    Some(render.BatchOpen(_, _)) -> {
      let session = case session.irc_batch_depth {
        0 ->
          Session(
            ..session,
            irc_batch_depth: 1,
            // Snapshot before this open (and any prior lines already applied
            // this tick live in `session.model` after apply).
            irc_batch_before: Some(line_before),
          )
        n -> Session(..session, irc_batch_depth: n + 1)
      }
      // No Diff for BATCH + itself.
      #(session, [])
    }
    Some(render.BatchClose(_)) -> {
      // Orphan `-` (depth already 0) still flushes any pending snapshot.
      let depth = case session.irc_batch_depth {
        n if n > 0 -> n - 1
        _ -> 0
      }
      case depth > 0 {
        True -> #(Session(..session, irc_batch_depth: depth), [])
        False -> {
          let paint_before = case session.irc_batch_before {
            Some(m) -> m
            None -> line_before
          }
          let session =
            Session(..session, irc_batch_depth: 0, irc_batch_before: None)
          finish(session, paint_before, session.model)
        }
      }
    }
    None ->
      case session.irc_batch_depth > 0 {
        // Inside batch: model already updated; wait for BATCH -.
        True -> #(session, [])
        False -> finish(session, line_before, session.model)
      }
  }
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
      let rows =
        rest.fetch_history(
          channel,
          live.history_page_size,
          session.model.api_bearer,
          None,
        )
      // SetHistory merges reaction tallies with any live/CHATHISTORY state.
      let #(model, effect) = live.apply(session.model, live.SetHistory(rows))
      // After REST body, request CHATHISTORY so chips reappear on refresh.
      case session.upstream {
        Some(handle) -> request_chathistory(handle, channel)
        None -> Nil
      }
      let session = Session(..session, model: model)
      run_effect(session, effect)
    }

    live.FetchOlderHistory(channel, before) -> {
      let rows =
        rest.fetch_history(
          channel,
          live.history_page_size,
          session.model.api_bearer,
          Some(before),
        )
      let #(model, effect) =
        live.apply(session.model, live.PrependHistory(rows))
      // Hydrate reaction chips for the older page (batch lines still skipped
      // as rows; parse_history_reactions attaches tallies by msgid).
      case session.upstream {
        Some(handle) -> request_chathistory_before(handle, channel, before)
        None -> Nil
      }
      let session = Session(..session, model: model)
      run_effect(session, effect)
    }

    live.FetchChannels -> {
      let chs = rest.fetch_channels()
      let #(model, _) = live.apply(session.model, live.SetAllChannels(chs))
      Session(..session, model: model)
    }

    live.FetchActiveCall(channel) -> apply_active_call_probe(session, channel)

    live.FetchSearch(channel, query) -> {
      // Off-session so keystroke search does not block IRC / LiveView.
      let subject = session.self_subject
      let bearer = session.model.api_bearer
      let _ =
        process.spawn_unlinked(fn() {
          let outcome =
            rest.search_messages(
              channel,
              query,
              rest.search_page_size,
              bearer,
            )
          let #(results, err) = case outcome {
            rest.SearchOk(rows) -> #(rows, None)
            rest.SearchErr(reason) -> #([], Some(reason))
          }
          let status = live.search_status_for(results, err)
          process.send(subject, RestSearch(query, results, status))
        })
      session
    }

    live.FetchAround(channel, before) -> {
      // Load a history page ending at `before` so a search hit can be scrolled
      // into view even when it was outside the current window.
      let rows =
        rest.fetch_history(
          channel,
          live.history_page_size,
          session.model.api_bearer,
          Some(before),
        )
      let #(model, effect) =
        live.apply(session.model, live.MergeAroundHistory(rows))
      case session.upstream {
        Some(handle) -> request_chathistory_before(handle, channel, before)
        None -> Nil
      }
      let session = Session(..session, model: model)
      run_effect(session, effect)
    }

    live.StopUpstream -> {
      case session.upstream {
        Some(handle) -> upstream.stop(handle)
        None -> Nil
      }
      Session(..session, upstream: None)
    }

    live.ResolveEmbeds(rows) -> {
      // One background job → one Diff (embeds + avatars together).
      let dids = live.avatar_dids_for_rows(session.model, rows)
      schedule_media_warmup(session.self_subject, rows, dids)
      session
    }

    live.ResolveAvatars(dids) -> {
      schedule_avatar_fetch(session.self_subject, dids)
      session
    }
  }
}

/// Fetch ATProto profile avatars off the Live session process.
///
/// On success, stores the avatar under the query key **and** the resolved
/// DID/handle so `chadfowler.com` (nick) and `did:plc:…` (account tag) share
/// one profile fetch.
///
/// Sends **one** `AvatarsReady` for the whole batch (not one Diff per DID)
/// so channel open is history paint + one avatar paint, not N morphs.
fn schedule_avatar_fetch(subject: Subject(Push), dids: List(String)) -> Nil {
  let pending = pending_avatar_actors(dids)
  case pending {
    [] -> Nil
    _ -> {
      let _ =
        process.spawn_unlinked(fn() {
          let pairs = collect_avatars(pending)
          case pairs {
            [] -> Nil
            _ -> process.send(subject, AvatarsReady(pairs))
          }
        })
      Nil
    }
  }
}

/// History / open warmup: resolve embeds + avatars in one job → one Diff.
fn schedule_media_warmup(
  subject: Subject(Push),
  rows: List(render.Row),
  dids: List(String),
) -> Nil {
  let embed_rows =
    rows
    |> list.filter(link_preview.needs_resolve)
    |> list.take(30)
  let actors = pending_avatar_actors(dids)
  case embed_rows, actors {
    [], [] -> Nil
    _, _ -> {
      let _ =
        process.spawn_unlinked(fn() {
          let embeds = collect_embeds(embed_rows)
          let avatars = collect_avatars(actors)
          case embeds, avatars {
            [], [] -> Nil
            _, _ -> process.send(subject, MediaReady(embeds, avatars))
          }
        })
      Nil
    }
  }
}

fn pending_avatar_actors(dids: List(String)) -> List(String) {
  dids
  |> list.filter(fn(d) { string.trim(d) != "" })
  |> list.unique
  |> list.take(40)
}

fn collect_embeds(
  rows: List(render.Row),
) -> List(#(String, render.Embed)) {
  list.filter_map(rows, fn(row) {
    let full = link_preview.attach(row)
    case full.embed {
      Some(embed) -> Ok(#(row.id, embed))
      None -> Error(Nil)
    }
  })
}

fn collect_avatars(actors: List(String)) -> List(#(String, String)) {
  list.flat_map(actors, fn(actor) {
    case profiles.fetch_profile(actor) {
      Some(profile) -> {
        let url = profile.avatar
        list.map(profiles.avatar_cache_keys(actor, profile), fn(key) {
          #(key, url)
        })
      }
      None -> [#(actor, "")]
    }
  })
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
