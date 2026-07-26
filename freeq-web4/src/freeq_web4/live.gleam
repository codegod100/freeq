//// freeq chat LiveView — Lightspeed stateful component.
////
//// Server-owned model for channel list + per-channel chat shell.
//// Browser events become typed Msgs; IRC lines become PushLine/etc.
//// Fine-grained region patches keep the shell responsive.

import freeq_web4/config
import freeq_web4/irc/render
import freeq_web4/link_preview
import freeq_web4/ls_form
import freeq_web4/rest
import gleam/bit_array
import gleam/crypto
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string
import lightspeed/component
import lightspeed/component/helpers
import lightspeed/component/stateful
import lightspeed/diff
import lightspeed/event

// ── Model ────────────────────────────────────────────────────────────────────

/// Which page the LiveView is showing: channel directory or a single channel.
pub type View {
  /// Channel list / directory (`/chat`).
  Index
  /// Single channel chat shell (`/chat/:name`).
  Channel
  /// System / server buffer (`/chat/system`) — connection + notices.
  System
}

/// Path segment and sidebar key for the system buffer (not a real IRC channel).
pub const system_key: String = "system"

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
    /// Parent msgid when composing a reply (`@+reply=` on send).
    reply_to: Option(String),
    /// Msgid being edited (`@+draft/edit=` on send). Mutually exclusive with reply.
    edit_to: Option(String),
    /// Banner nick for the message being replied to.
    reply_preview_nick: String,
    /// Banner snippet for the message being replied to (or edited).
    reply_preview_text: String,
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
    /// Open emoji picker target msgid (`None` = closed).
    react_picker_msgid: Option(String),
    /// Nav bar: inline topic editor open.
    editing_topic: Bool,
    /// REST scroll-up page in flight (client debounces on this too).
    history_loading: Bool,
    /// No older REST page left (`before` returned fewer than a full page).
    history_exhausted: Bool,
    /// Message search modal open (channel-scoped FTS).
    search_open: Bool,
    /// Current search query string (form / results header).
    search_query: String,
    /// Hits from the last successful REST search (newest-first).
    search_results: List(render.Row),
    /// REST search request in flight.
    search_loading: Bool,
    /// Empty-state / error line under the search input.
    search_status: String,
    /// After search/reply jump: client scrolls to this msgid once in the DOM.
    scroll_to_msgid: Option(String),
    /// Unread chat counts for non-active joined channels (`#name` → n).
    /// Cleared when the user opens that channel; sidebar shows a badge.
    unread: Dict(String, Int),
    /// System buffer: connection status, server notices, non-channel rows.
    /// Persists across navigation (unlike per-channel `messages`).
    system_messages: List(render.Row),
  )
}

/// Page size for initial + scroll-up REST history fetches.
pub const history_page_size: Int = 50

/// Min characters before we hit freeq-server FTS (matches freeq-app UX).
pub const search_min_chars: Int = 2

/// Human status line after a REST search completes.
pub fn search_status_for(
  results: List(render.Row),
  error: Option(String),
) -> String {
  case error {
    Some("http_403") ->
      "This channel is private — sign in or join before searching"
    Some("http_404") -> "Channel not found"
    Some(_) -> "Search failed — try again"
    None ->
      case results {
        [] -> "No messages found"
        rows -> {
          let n = list.length(rows)
          case n == 1 {
            True -> "1 result"
            False -> int.to_string(n) <> " results"
          }
        }
      }
  }
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
  /// Browser: start replying to a message (msgid).
  StartReply(msgid: String)
  /// Browser: start editing own message (msgid).
  StartEdit(msgid: String)
  /// Browser: soft-delete own message (`+draft/delete` TAGMSG).
  DeleteMessage(msgid: String)
  /// Browser: cancel reply / edit compose mode.
  CancelReply
  /// Browser: join channel form.
  Join(raw: String)
  /// Browser: part a channel.
  Part(channel: String)
  /// Browser: navigate to channel list.
  GoIndex
  /// Browser: open a channel (sidebar / directory).
  OpenChannel(bare: String)
  /// Browser: open the System buffer (`/chat/system`).
  OpenSystem
  /// Browser: set topic.
  SetTopic(topic: String)
  /// Browser: open inline topic editor (ops / half-ops).
  EditTopic
  /// Browser: cancel inline topic editor (Esc).
  CancelTopicEdit
  /// Server: IRC connection state.
  SetWs(WsLabel)
  /// Server: nick assigned.
  SetNick(String)
  /// Server: raw IRC line.
  PushLine(String)
  /// Server: replace history after REST fetch.
  SetHistory(List(render.Row))
  /// Browser: scrolled to top of message pane — load older page.
  LoadOlder
  /// Server: prepend older REST page (scroll-up pagination).
  PrependHistory(List(render.Row))
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
  /// Browser: open emoji picker for a message.
  OpenReactPicker(msgid: String)
  /// Browser: close emoji picker.
  CloseReactPicker
  /// Browser: toggle reaction on a message (add if not mine, else remove).
  ToggleReaction(msgid: String, emoji: String)
  /// Server: async link-preview resolve finished for a row.
  PatchEmbed(row_id: String, embed: render.Embed)
  /// Browser: open channel message search modal.
  OpenSearch
  /// Browser: close search modal (Esc / backdrop / result click).
  CloseSearch
  /// Browser: run FTS for the current channel (`q` from form).
  RunSearch(query: String)
  /// Server: REST search finished (ok or error status line).
  SetSearchResults(
    query: String,
    results: List(render.Row),
    status: String,
  )
  /// Browser: jump to a search hit (close modal; load history if needed).
  JumpToMsg(msgid: String, ts: Option(Int))
  /// Server: history page around a jump target merged into the stream.
  MergeAroundHistory(List(render.Row))
  /// Browser: clear one-shot scroll target after client scrolled.
  ClearScrollTo
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
  /// Fetch older REST history page (`before` = unix ts of oldest loaded).
  FetchOlderHistory(channel: String, before: Int)
  /// Fetch public channel list.
  FetchChannels
  /// Probe freeq-server for an active AV call on a channel.
  FetchActiveCall(channel: String)
  /// Channel FTS via REST `GET /api/v1/search`.
  FetchSearch(channel: String, query: String)
  /// REST history page ending at `before` (unix exclusive) to land on a msgid.
  FetchAround(channel: String, before: Int)
  /// Stop upstream (logout / socket close).
  StopUpstream
  /// Background-resolve Open Graph / YouTube / Bluesky cards for these rows.
  ResolveEmbeds(List(render.Row))
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
      reply_to: None,
      edit_to: None,
      reply_preview_nick: "",
      reply_preview_text: "",
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
      react_picker_msgid: None,
      editing_topic: False,
      history_loading: False,
      history_exhausted: False,
      search_open: False,
      search_query: "",
      search_results: [],
      search_loading: False,
      search_status: "",
      scroll_to_msgid: None,
      unread: dict.new(),
      system_messages: [],
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
      case text == "" {
        True -> #(model, NoEffect)
        False ->
          case string.starts_with(text, "/") {
            // Client-side slash commands (join/op/whois/help/…) — freeq-app parity.
            True -> handle_slash_command(model, text)
            False ->
              case model.view, model.channel {
                System, _ -> #(
                  Model(
                    ..model,
                    flash: "Use /commands here (e.g. /join #channel, /whois nick, /help)",
                  ),
                  NoEffect,
                )
                _, Some(ch) -> #(
                  clear_reply(Model(..model, compose: "", flash: "")),
                  IrcSend([
                    privmsg_line(ch, text, model.reply_to, model.edit_to),
                  ]),
                )
                _, None -> #(
                  Model(..model, flash: "Join a channel first"),
                  NoEffect,
                )
              }
          }
      }
    }

    StartReply(msgid) -> {
      let msgid = string.trim(msgid)
      case msgid == "" {
        True -> #(model, NoEffect)
        False -> {
          let #(nick, text) = message_preview(model.messages, msgid)
          #(
            Model(
              ..model,
              reply_to: Some(msgid),
              edit_to: None,
              reply_preview_nick: nick,
              reply_preview_text: render.preview_text(text),
            ),
            NoEffect,
          )
        }
      }
    }

    StartEdit(msgid) -> {
      let msgid = string.trim(msgid)
      case msgid == "", message_is_deleted(model.messages, msgid) {
        True, _ -> #(model, NoEffect)
        _, True -> #(model, NoEffect)
        False, False -> {
          let #(_nick, text) = message_preview(model.messages, msgid)
          #(
            Model(
              ..model,
              edit_to: Some(msgid),
              reply_to: None,
              reply_preview_nick: "",
              reply_preview_text: render.preview_text(text),
              // Server-side draft hint; client also prefills the input via JS.
              compose: text,
            ),
            NoEffect,
          )
        }
      }
    }

    DeleteMessage(msgid) -> delete_message(model, msgid)

    CancelReply -> #(clear_reply(model), NoEffect)

    Join(raw) -> {
      // "system" is the local status buffer, not IRC #system.
      case is_system_key(raw) {
        True -> open_system(model)
        False -> {
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
                  clear_unread(
                    clear_search(clear_reply(
                      Model(
                        ..model,
                        view: Channel,
                        channel: Some(ch),
                        my_channels: my,
                        messages: [],
                        members: [],
                        topic: topic,
                        flash: "",
                        react_picker_msgid: None,
                        editing_topic: False,
                        history_loading: False,
                        history_exhausted: False,
                        av_channel: case model.av_channel {
                          Some(_) -> model.av_channel
                          None -> model.channel
                        },
                      ),
                    )),
                    ch,
                  )
                False ->
                  clear_unread(
                    clear_search(clear_reply(
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
                        react_picker_msgid: None,
                        editing_topic: False,
                        history_loading: False,
                        history_exhausted: False,
                      ),
                    )),
                    ch,
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
          clear_unread(
            clear_search(clear_reply(
              Model(
                ..model,
                view: Index,
                channel: None,
                my_channels: my,
                messages: [],
                members: [],
                topic: "",
                react_picker_msgid: None,
                editing_topic: False,
                history_loading: False,
                history_exhausted: False,
              ),
            )),
            ch,
          )
        False -> clear_unread(Model(..model, my_channels: my), ch)
      }
      #(model, IrcSend(["PART " <> ch <> "\r\n"]))
    }

    GoIndex ->
      // Keep AV state — browsing the directory must not leave the call.
      #(
        clear_search(clear_reply(
          Model(
            ..model,
            view: Index,
            channel: None,
            messages: [],
            members: [],
            topic: "",
            react_picker_msgid: None,
            editing_topic: False,
            history_loading: False,
            history_exhausted: False,
          ),
        )),
        FetchChannels,
      )

    OpenSystem -> open_system(model)

    OpenChannel(bare) -> {
      case is_system_key(bare) {
        True -> open_system(model)
        False -> open_channel(model, bare)
      }
    }

    SetTopic(raw) -> {
      let topic = string.trim(raw)
      case model.channel, can_edit_topic(model) {
        Some(ch), True -> #(
          Model(..model, topic: topic, editing_topic: False),
          IrcSend(["TOPIC " <> ch <> " :" <> topic <> "\r\n"]),
        )
        _, _ -> #(Model(..model, editing_topic: False), NoEffect)
      }
    }

    EditTopic ->
      case can_edit_topic(model) {
        True -> #(Model(..model, editing_topic: True), NoEffect)
        False -> #(model, NoEffect)
      }

    CancelTopicEdit -> #(Model(..model, editing_topic: False), NoEffect)

    SetWs(ws) -> {
      let label = ws_status(ws)
      let model = Model(..model, ws: ws, status: label)
      // Log meaningful connection transitions into the System buffer.
      case ws {
        WsReady | WsDisconnected -> #(
          append_system_message(model, label),
          NoEffect,
        )
        _ -> #(model, NoEffect)
      }
    }

    SetNick(nick) -> #(Model(..model, nick: nick), NoEffect)

    PushLine(line) -> apply_line(model, line)

    // Prefer apply_rest_history at call sites; raw SetHistory still merges
    // reaction tallies so REST never clobbers chips already on the model.
    // Cache-only embeds for first paint; host warms uncached URLs in background.
    SetHistory(rows) -> {
      let rows = link_preview.attach_many_cache_only(rows)
      let next = apply_rest_history(model, rows)
      let next =
        Model(
          ..next,
          history_loading: False,
          // Full page means more may exist above; short page is the top.
          history_exhausted: list.length(rows) < history_page_size,
        )
      #(next, ResolveEmbeds(next.messages))
    }

    LoadOlder -> {
      case
        model.history_loading,
        model.history_exhausted,
        model.channel,
        render.oldest_timestamp(model.messages)
      {
        True, _, _, _ -> #(model, NoEffect)
        _, True, _, _ -> #(model, NoEffect)
        _, _, None, _ -> #(model, NoEffect)
        _, _, _, None -> #(
          // Nothing to page with (no REST ts yet) — stop spinning forever.
          Model(..model, history_exhausted: True),
          NoEffect,
        )
        _, _, Some(ch), Some(before) -> #(
          Model(..model, history_loading: True),
          FetchOlderHistory(ch, before),
        )
      }
    }

    PrependHistory(older) -> {
      let older = link_preview.attach_many_cache_only(older)
      let merged = prepend_history_rows(older, model.messages)
      let next =
        Model(
          ..model,
          messages: merged,
          history_loading: False,
          history_exhausted: list.length(older) < history_page_size,
        )
      #(next, ResolveEmbeds(older))
    }

    PatchEmbed(row_id, embed) -> #(
      Model(
        ..model,
        messages: patch_row_embed(model.messages, row_id, embed),
      ),
      NoEffect,
    )

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

    OpenReactPicker(msgid) ->
      case string.trim(msgid) {
        "" -> #(model, NoEffect)
        mid -> #(Model(..model, react_picker_msgid: Some(mid)), NoEffect)
      }

    CloseReactPicker -> #(Model(..model, react_picker_msgid: None), NoEffect)

    ToggleReaction(msgid, emoji) -> toggle_reaction(model, msgid, emoji)

    OpenSearch ->
      case model.view, model.channel {
        Channel, Some(_) -> {
          let q = string.trim(model.search_query)
          case string.length(q) < search_min_chars {
            True -> #(
              Model(
                ..model,
                search_open: True,
                search_status: search_hint_status(),
              ),
              NoEffect,
            )
            // Re-open with an existing query — refresh server hits.
            False -> #(
              Model(
                ..model,
                search_open: True,
                search_loading: True,
                search_status: "Searching…",
                search_results: local_search_hits(model.messages, q),
              ),
              case model.channel {
                Some(ch) -> FetchSearch(ch, q)
                None -> NoEffect
              },
            )
          }
        }
        _, _ -> #(
          Model(..model, flash: "Join a channel to search messages"),
          NoEffect,
        )
      }

    CloseSearch -> #(clear_search(model), NoEffect)

    RunSearch(query) -> {
      // Keep raw query for the client-owned input; trim only for FTS / status.
      let raw = query
      let query = string.trim(query)
      case model.channel {
        None -> #(
          Model(
            ..model,
            search_open: True,
            search_query: raw,
            search_results: [],
            search_loading: False,
            search_status: "Join a channel to search messages",
          ),
          NoEffect,
        )
        Some(ch) ->
          case string.length(query) < search_min_chars {
            True -> #(
              Model(
                ..model,
                search_open: True,
                search_query: raw,
                search_results: [],
                search_loading: False,
                search_status: search_hint_status(),
              ),
              NoEffect,
            )
            False -> {
              // Instant local hits from loaded history; REST FTS replaces.
              let local = local_search_hits(model.messages, query)
              #(
                Model(
                  ..model,
                  search_open: True,
                  search_query: raw,
                  search_loading: True,
                  search_status: case local {
                    [] -> "Searching…"
                    rows ->
                      search_status_for(rows, None) <> " (searching history…)"
                  },
                  search_results: local,
                ),
                FetchSearch(ch, query),
              )
            }
          }
      }
    }

    SetSearchResults(query, results, status) -> {
      // Drop stale REST responses when the user has already typed further.
      // Compare trimmed forms so "deploy " / "deploy" still match.
      let want = string.trim(query)
      let have = string.trim(model.search_query)
      case have == want {
        True -> #(
          Model(
            ..model,
            search_results: results,
            search_loading: False,
            search_status: status,
            search_open: True,
          ),
          NoEffect,
        )
        False -> #(model, NoEffect)
      }
    }

    JumpToMsg(msgid, ts) -> jump_to_msg(model, msgid, ts)

    MergeAroundHistory(rows) -> {
      let rows = link_preview.attach_many_cache_only(rows)
      let merged = merge_rows_chronological(model.messages, rows)
      let next =
        Model(
          ..model,
          messages: merged,
          history_loading: False,
          // Opening a window around an old hit — more history may exist above.
          history_exhausted: list.length(rows) < history_page_size,
        )
      #(next, ResolveEmbeds(rows))
    }

    ClearScrollTo -> #(Model(..model, scroll_to_msgid: None), NoEffect)
  }
}

/// True when `raw` names the local System buffer (`system` / `#system`).
fn is_system_key(raw: String) -> Bool {
  let bare = string.lowercase(string.trim(raw))
  bare == system_key || bare == "#" <> system_key
}

/// Open the System status buffer (no IRC JOIN, no REST history).
fn open_system(model: Model) -> #(Model, Effect) {
  #(
    clear_search(clear_reply(
      Model(
        ..model,
        view: System,
        channel: None,
        messages: [],
        members: [],
        topic: "",
        flash: "",
        react_picker_msgid: None,
        editing_topic: False,
        history_loading: False,
        history_exhausted: True,
      ),
    )),
    NoEffect,
  )
}

/// Open a real IRC channel (JOIN + history + optional AV probe).
fn open_channel(model: Model, bare: String) -> #(Model, Effect) {
  let ch = render.canonical_channel(bare)
  let my = list_unique_append(model.my_channels, ch)
  // Seed from directory when present (#test); host REST fills private
  // rooms (#freeq) and IRC 332 may refine further.
  let topic = rest.topic_for(model.all_channels, ch)
  let model = case model.av_active {
    True ->
      clear_unread(
        clear_search(clear_reply(
          Model(
            ..model,
            view: Channel,
            channel: Some(ch),
            my_channels: my,
            messages: [],
            members: [],
            topic: topic,
            flash: "",
            react_picker_msgid: None,
            editing_topic: False,
            history_loading: False,
            history_exhausted: False,
            av_channel: case model.av_channel {
              Some(_) -> model.av_channel
              None -> model.channel
            },
          ),
        )),
        ch,
      )
    False ->
      clear_unread(
        clear_search(clear_reply(
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
            react_picker_msgid: None,
            editing_topic: False,
            history_loading: False,
            history_exhausted: False,
          ),
        )),
        ch,
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

/// Append a local system status line (capped).
fn append_system_message(model: Model, text: String) -> Model {
  let row = render.system_row(text)
  Model(
    ..model,
    system_messages: append_capped(model.system_messages, row, 500),
  )
}

/// Expand client slash commands (freeq-app ComposeBox parity).
///
/// Raw strip-the-slash is wrong for `/op`, `/join`, etc. — those need MODE /
/// JOIN framing. Unknown commands become uppercased IRC verbs.
fn handle_slash_command(model: Model, text: String) -> #(Model, Effect) {
  let rest = string.drop_start(string.trim(text), 1)
  let #(cmd_raw, args) = split_cmd_args(rest)
  let cmd = string.lowercase(cmd_raw)
  let model = Model(..model, compose: "", flash: "")
  let model = append_system_message(model, "» /" <> string.trim(rest))
  let current = option.unwrap(model.channel, "")

  case cmd {
    "help" | "commands" -> #(append_help(model), NoEffect)

    "join" | "j" ->
      case first_token(args) {
        "" -> #(
          append_system_message(model, "Usage: /join #channel"),
          NoEffect,
        )
        ch -> {
          // Join navigates + JOINs upstream (open_channel).
          let #(next, effect) = open_channel(model, ch)
          // Preserve system echo from above (open_channel clears messages only).
          #(
            Model(..next, system_messages: model.system_messages),
            effect,
          )
        }
      }

    "part" | "leave" -> {
      let ch = case first_token(args) {
        "" -> current
        c -> render.canonical_channel(c)
      }
      case ch {
        "" | "#" -> #(
          append_system_message(model, "Usage: /part [#channel]"),
          NoEffect,
        )
        c -> {
          // Reuse Part handler logic via apply.
          let #(next, effect) = handle_effect(model, Part(c))
          #(Model(..next, system_messages: model.system_messages), effect)
        }
      }
    }

    "topic" | "t" ->
      case current {
        "" | "#" -> #(
          append_system_message(
            model,
            "Usage: open a channel, then /topic text",
          ),
          NoEffect,
        )
        ch ->
          case string.trim(args) {
            "" -> #(model, IrcSend(["TOPIC " <> ch <> "\r\n"]))
            t -> #(
              model,
              IrcSend(["TOPIC " <> ch <> " :" <> t <> "\r\n"]),
            )
          }
      }

    "mode" | "m" ->
      case string.trim(args) {
        "" ->
          case current {
            "" | "#" -> #(
              append_system_message(model, "Usage: /mode #chan +o nick"),
              NoEffect,
            )
            ch -> #(model, IrcSend(["MODE " <> ch <> "\r\n"]))
          }
        a ->
          case string.starts_with(a, "#") || string.starts_with(a, "&") {
            True -> #(model, IrcSend(["MODE " <> a <> "\r\n"]))
            False ->
              case current {
                "" | "#" -> #(
                  append_system_message(
                    model,
                    "Usage: /mode #chan +o nick  (or run from a channel)",
                  ),
                  NoEffect,
                )
                ch -> #(model, IrcSend(["MODE " <> ch <> " " <> a <> "\r\n"]))
              }
          }
      }

    "op" -> slash_mode(model, current, args, "+o", "op")
    "deop" -> slash_mode(model, current, args, "-o", "deop")
    "voice" -> slash_mode(model, current, args, "+v", "voice")
    "devoice" -> slash_mode(model, current, args, "-v", "devoice")

    "kick" | "k" -> {
      let #(chan, target, why) = kick_args(current, args)
      case chan, target {
        Some(c), t if t != "" ->
          case why {
            "" -> #(model, IrcSend(["KICK " <> c <> " " <> t <> "\r\n"]))
            w -> #(
              model,
              IrcSend(["KICK " <> c <> " " <> t <> " :" <> w <> "\r\n"]),
            )
          }
        _, _ -> #(
          append_system_message(
            model,
            "Usage: /kick nick [reason]  or  /kick #chan nick [reason]",
          ),
          NoEffect,
        )
      }
    }

    "invite" -> {
      let #(nick, rest) = split_cmd_args(args)
      let ch = case first_token(rest) {
        "" -> current
        c -> render.canonical_channel(c)
      }
      case nick == "" || ch == "" || ch == "#" {
        True -> #(
          append_system_message(model, "Usage: /invite nick [#channel]"),
          NoEffect,
        )
        False -> #(
          model,
          IrcSend(["INVITE " <> nick <> " " <> ch <> "\r\n"]),
        )
      }
    }

    "whois" | "wi" ->
      case first_token(args) {
        "" -> #(
          append_system_message(model, "Usage: /whois nick"),
          NoEffect,
        )
        nick -> #(model, IrcSend(["WHOIS " <> nick <> "\r\n"]))
      }

    "away" ->
      case string.trim(args) {
        "" -> #(model, IrcSend(["AWAY\r\n"]))
        reason -> #(model, IrcSend(["AWAY :" <> reason <> "\r\n"]))
      }

    "msg" | "query" | "privmsg" -> {
      let #(target, body) = split_cmd_args(args)
      case target == "" || string.trim(body) == "" {
        True -> #(
          append_system_message(model, "Usage: /msg nick_or_#chan text"),
          NoEffect,
        )
        False -> #(
          model,
          IrcSend([
            "PRIVMSG " <> target <> " :" <> string.trim(body) <> "\r\n",
          ]),
        )
      }
    }

    "me" | "action" ->
      case current {
        "" | "#" -> #(
          append_system_message(model, "Usage: open a channel, then /me action"),
          NoEffect,
        )
        ch ->
          case string.trim(args) {
            "" -> #(
              append_system_message(model, "Usage: /me action text"),
              NoEffect,
            )
            a -> #(
              model,
              IrcSend([
                "PRIVMSG " <> ch <> " :\u{0001}ACTION " <> a <> "\u{0001}\r\n",
              ]),
            )
          }
      }

    "raw" | "quote" ->
      case string.trim(args) {
        "" -> #(
          append_system_message(model, "Usage: /raw IRC_LINE"),
          NoEffect,
        )
        line -> #(model, IrcSend([line <> "\r\n"]))
      }

    // Unknown → uppercased IRC verb (WHOIS-style) so typos get a 421 back.
    _ -> {
      let line = case string.trim(args) {
        "" -> string.uppercase(cmd) <> "\r\n"
        a -> string.uppercase(cmd) <> " " <> a <> "\r\n"
      }
      #(model, IrcSend([line]))
    }
  }
}

fn append_help(model: Model) -> Model {
  [
    "── Commands ──",
    "/join #channel  ·  /part [#channel]  ·  /topic text",
    "/kick nick  ·  /op nick  ·  /deop nick  ·  /voice nick",
    "/invite nick  ·  /mode #chan +o nick",
    "/whois nick  ·  /away reason  ·  /me action",
    "/msg nick_or_#chan text  ·  /raw IRC_LINE",
    "/help",
    "── Note ──",
    "/op and friends use the current channel, or /op nick #channel",
  ]
  |> list.fold(model, fn(m, line) { append_system_message(m, line) })
}

fn slash_mode(
  model: Model,
  current: String,
  args: String,
  mode: String,
  name: String,
) -> #(Model, Effect) {
  case parse_nick_channel_args(current, args) {
    Some(#(ch, nick)) -> #(
      model,
      IrcSend(["MODE " <> ch <> " " <> mode <> " " <> nick <> "\r\n"]),
    )
    None -> #(
      append_system_message(
        model,
        "Usage: /" <> name <> " nick  or  /" <> name <> " nick #channel",
      ),
      NoEffect,
    )
  }
}

/// `/op nick`, `/op nick #chan`, `/op #chan nick`.
fn parse_nick_channel_args(
  current: String,
  args: String,
) -> Option(#(String, String)) {
  let args = string.trim(args)
  case args {
    "" -> None
    _ -> {
      let #(a, b) = split_cmd_args(args)
      case a {
        "" -> None
        first ->
          case string.starts_with(first, "#") || string.starts_with(first, "&") {
            True ->
              case first_token(b) {
                "" -> None
                nick -> Some(#(render.canonical_channel(first), nick))
              }
            False ->
              case first_token(b) {
                "" ->
                  case current {
                    "" | "#" -> None
                    ch -> Some(#(ch, first))
                  }
                maybe_ch ->
                  case
                    string.starts_with(maybe_ch, "#")
                    || string.starts_with(maybe_ch, "&")
                  {
                    True -> Some(#(render.canonical_channel(maybe_ch), first))
                    False ->
                      case current {
                        "" | "#" -> None
                        ch -> Some(#(ch, first))
                      }
                  }
              }
          }
      }
    }
  }
}

/// Kick: `/kick nick [reason]`, `/kick #chan nick [reason]`.
fn kick_args(
  current: String,
  args: String,
) -> #(Option(String), String, String) {
  let args = string.trim(args)
  let #(a, rest) = split_cmd_args(args)
  case a {
    "" -> #(None, "", "")
    first ->
      case string.starts_with(first, "#") || string.starts_with(first, "&") {
        True -> {
          let #(nick, reason) = split_cmd_args(rest)
          #(Some(render.canonical_channel(first)), nick, string.trim(reason))
        }
        False ->
          case current {
            "" | "#" -> #(None, "", "")
            ch -> #(Some(ch), first, string.trim(rest))
          }
      }
  }
}

fn split_cmd_args(s: String) -> #(String, String) {
  let s = string.trim(s)
  case string.split_once(s, " ") {
    Ok(#(cmd, rest)) -> #(cmd, string.trim(rest))
    Error(_) -> #(s, "")
  }
}

fn first_token(s: String) -> String {
  let #(t, _) = split_cmd_args(s)
  t
}

fn jump_to_msg(
  model: Model,
  msgid: String,
  ts: Option(Int),
) -> #(Model, Effect) {
  let msgid = string.trim(msgid)
  case msgid == "" {
    True -> #(clear_search(model), NoEffect)
    False -> {
      let model =
        clear_search(Model(..model, scroll_to_msgid: Some(msgid)))
      case message_in_list(model.messages, msgid) {
        True -> #(model, NoEffect)
        False ->
          case model.channel, ts {
            Some(ch), Some(t) if t > 0 -> #(
              Model(..model, history_loading: True),
              // `before` is exclusive: t+1 includes the hit at timestamp t.
              FetchAround(ch, t + 1),
            )
            Some(ch), _ ->
              // No ts — page upward from current oldest (client may retry).
              case render.oldest_timestamp(model.messages) {
                Some(before) -> #(
                  Model(..model, history_loading: True),
                  FetchOlderHistory(ch, before),
                )
                None -> #(
                  Model(..model, history_loading: True),
                  FetchHistory(ch),
                )
              }
            None, _ -> #(model, NoEffect)
          }
      }
    }
  }
}

fn message_in_list(rows: List(render.Row), msgid: String) -> Bool {
  list.any(rows, fn(r) {
    case r.msgid {
      Some(id) -> id == msgid
      None -> r.id == msgid
    }
  })
}

/// Union two history streams by msgid and sort oldest-first by timestamp.
pub fn merge_rows_chronological(
  a: List(render.Row),
  b: List(render.Row),
) -> List(render.Row) {
  let combined =
    list.fold(b, a, fn(acc, row) {
      case row_msgid_known(acc, row) {
        True -> union_reactions_into(acc, row)
        False -> [row, ..acc]
      }
    })
  list.sort(combined, fn(x, y) {
    case x.timestamp, y.timestamp {
      Some(tx), Some(ty) -> int.compare(tx, ty)
      Some(_), None -> order.Lt
      None, Some(_) -> order.Gt
      None, None -> string.compare(x.id, y.id)
    }
  })
}

/// Hint under the search box before a query is long enough for FTS.
pub fn search_hint_status() -> String {
  "Type at least " <> int.to_string(search_min_chars) <> " characters"
}

/// Substring filter over currently loaded channel rows (newest-first, capped).
/// Used for instant feedback while REST FTS is in flight.
pub fn local_search_hits(
  messages: List(render.Row),
  query: String,
) -> List(render.Row) {
  let q = string.lowercase(string.trim(query))
  case q == "" {
    True -> []
    False ->
      messages
      |> list.reverse
      |> list.filter(fn(row) { row_matches_query(row, q) })
      |> list.take(rest.search_page_size)
  }
}

fn row_matches_query(row: render.Row, q_lower: String) -> Bool {
  case row.kind {
    render.Msg | render.Notice -> {
      let text = string.lowercase(row.text)
      let nick = string.lowercase(option.unwrap(row.nick, ""))
      string.contains(text, q_lower) || string.contains(nick, q_lower)
    }
    _ -> False
  }
}

/// If the search modal is open, fold a new live PRIVMSG into the hit list.
fn live_search_maybe_add(model: Model, row: render.Row) -> Model {
  case model.search_open {
    False -> model
    True -> {
      let q = string.trim(model.search_query)
      case string.length(q) < search_min_chars {
        True -> model
        False ->
          case row_matches_query(row, string.lowercase(q)) {
            False -> model
            True -> {
              let mid = option.unwrap(row.msgid, row.id)
              let already =
                mid != ""
                && list.any(model.search_results, fn(r) {
                  option.unwrap(r.msgid, r.id) == mid
                })
              case already {
                True -> model
                False -> {
                  let results =
                    [row, ..model.search_results]
                    |> list.take(rest.search_page_size)
                  Model(
                    ..model,
                    search_results: results,
                    search_status: case model.search_loading {
                      True ->
                        search_status_for(results, None)
                        <> " (searching history…)"
                      False -> search_status_for(results, None)
                    },
                  )
                }
              }
            }
          }
      }
    }
  }
}

fn toggle_reaction(
  model: Model,
  msgid: String,
  emoji: String,
) -> #(Model, Effect) {
  let msgid = string.trim(msgid)
  let emoji = string.trim(emoji)
  case msgid == "" || emoji == "", model.channel {
    True, _ -> #(Model(..model, react_picker_msgid: None), NoEffect)
    _, None -> #(Model(..model, react_picker_msgid: None), NoEffect)
    _, Some(ch) -> {
      let aliases = my_reaction_aliases(model)
      let nicks = reaction_nicks_for(model.messages, msgid, emoji)
      let mine = nick_in_aliases(nicks, aliases)
      let added = !mine
      let messages =
        apply_reaction_to_messages(
          model.messages,
          msgid,
          emoji,
          model.nick,
          added,
        )
      let line = render.react_line(ch, msgid, emoji, added)
      #(
        Model(..model, messages: messages, react_picker_msgid: None),
        IrcSend([line]),
      )
    }
  }
}

fn my_reaction_aliases(model: Model) -> List(String) {
  [model.nick, model.auth_handle]
  |> list.filter(fn(n) { string.trim(n) != "" })
  |> list.map(string.lowercase)
  |> list.unique
}

fn nick_in_aliases(nicks: List(String), aliases: List(String)) -> Bool {
  list.any(nicks, fn(n) { list.contains(aliases, string.lowercase(n)) })
}

fn reaction_nicks_for(
  messages: List(render.Row),
  msgid: String,
  emoji: String,
) -> List(String) {
  case list.find(messages, fn(r) { r.msgid == Some(msgid) }) {
    Ok(row) ->
      case dict.get(row.reactions, emoji) {
        Ok(ns) -> ns
        Error(_) -> []
      }
    Error(_) -> []
  }
}

fn apply_reaction_to_messages(
  messages: List(render.Row),
  msgid: String,
  emoji: String,
  nick: String,
  added: Bool,
) -> List(render.Row) {
  list.map(messages, fn(row) {
    case row.deleted, row.msgid {
      True, _ -> row
      False, Some(m) if m == msgid ->
        render.Row(
          ..row,
          reactions: render.apply_reaction_map(
            row.reactions,
            emoji,
            nick,
            added,
          ),
        )
      _, _ -> row
    }
  })
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
        None ->
          case render.parse_tagmsg_delete(line) {
            Some(#(msgid, _nick, ch)) ->
              case model.channel {
                Some(c) if c == ch -> #(
                  apply_delete_to_model(model, msgid),
                  NoEffect,
                )
                _ -> #(model, NoEffect)
              }
            None ->
              case render.parse_tagmsg_reaction(line) {
                Some(#(msgid, emoji, nick, added, ch)) ->
                  case model.channel {
                    Some(c) if c == ch -> #(
                      Model(
                        ..model,
                        messages: apply_reaction_to_messages(
                          model.messages,
                          msgid,
                          emoji,
                          nick,
                          added,
                        ),
                      ),
                      NoEffect,
                    )
                    _ -> #(model, NoEffect)
                  }
                None -> apply_line_chat(model, line)
              }
          }
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
  // Topic (header + live meta when someone changes it)
  case render.parse_topic(line) {
    Some(#(ch, topic)) -> {
      let viewing = viewing_channel(model, ch)
      let model = case viewing {
        True -> Model(..model, topic: topic)
        False -> model
      }
      // Live TOPIC (not 332 RPL on join) → meta in the stream.
      case viewing && string.contains(line, " TOPIC ") {
        True -> {
          let from = topic_setter_nick(line)
          let text = case from {
            Some(n) -> "— " <> n <> " set topic: " <> topic
            None -> "— topic: " <> topic
          }
          #(append_channel_meta(model, text), NoEffect)
        }
        False -> #(model, NoEffect)
      }
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
            Some(#(ch, from, modestring, args, ops)) -> {
              let viewing = viewing_channel(model, ch)
              let model = case viewing {
                True ->
                  Model(
                    ..model,
                    members: render.apply_mode_ops(model.members, ops),
                  )
                False -> model
              }
              case viewing {
                True -> #(
                  append_channel_meta(
                    model,
                    render.format_mode_meta(from, modestring, args),
                  ),
                  NoEffect,
                )
                False -> #(model, NoEffect)
              }
            }
            None ->
              case render.parse_kick(line) {
                Some(#(ch, kicker, kicked, reason)) -> {
                  let viewing = viewing_channel(model, ch)
                  let model = case viewing {
                    True ->
                      Model(
                        ..model,
                        members: list.filter(model.members, fn(m) {
                          string.lowercase(m.nick) != string.lowercase(kicked)
                        }),
                      )
                    False -> model
                  }
                  case viewing {
                    True -> #(
                      append_channel_meta(
                        model,
                        render.format_kick_meta(kicker, kicked, reason),
                      ),
                      NoEffect,
                    )
                    False -> #(model, NoEffect)
                  }
                }
                None ->
                  case render.parse_member_change(line) {
                    Some(#("join", nick, Some(ch))) -> {
                      let viewing = viewing_channel(model, ch)
                      let model = case viewing {
                        True ->
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
                          )
                        False -> model
                      }
                      case viewing {
                        True ->
                          case
                            render.parse_message_line(line, Some(model.nick))
                          {
                            Some(row) -> #(
                              Model(
                                ..model,
                                messages: append_capped(
                                  model.messages,
                                  row,
                                  400,
                                ),
                              ),
                              NoEffect,
                            )
                            None -> #(model, NoEffect)
                          }
                        False -> #(model, NoEffect)
                      }
                    }
                    Some(#("part", nick, Some(ch))) -> {
                      let viewing = viewing_channel(model, ch)
                      let model = case viewing {
                        True ->
                          Model(
                            ..model,
                            members: list.filter(model.members, fn(m) {
                              m.nick != nick
                            }),
                          )
                        False -> model
                      }
                      case viewing {
                        True ->
                          case
                            render.parse_message_line(line, Some(model.nick))
                          {
                            Some(row) -> #(
                              Model(
                                ..model,
                                messages: append_capped(
                                  model.messages,
                                  row,
                                  400,
                                ),
                              ),
                              NoEffect,
                            )
                            None -> #(model, NoEffect)
                          }
                        False -> #(model, NoEffect)
                      }
                    }
                    Some(#("quit", nick, _)) -> {
                      let was_member =
                        list.any(model.members, fn(m) {
                          string.lowercase(m.nick) == string.lowercase(nick)
                        })
                      let model =
                        Model(
                          ..model,
                          members: list.filter(model.members, fn(m) {
                            m.nick != nick
                          }),
                        )
                      case was_member {
                        True ->
                          case
                            render.parse_message_line(line, Some(model.nick))
                          {
                            Some(row) -> #(
                              Model(
                                ..model,
                                messages: append_capped(
                                  model.messages,
                                  row,
                                  400,
                                ),
                              ),
                              NoEffect,
                            )
                            None -> #(model, NoEffect)
                          }
                        False -> #(model, NoEffect)
                      }
                    }
                    Some(#("nick", old, Some(new))) -> {
                      let was_member =
                        list.any(model.members, fn(m) {
                          string.lowercase(m.nick) == string.lowercase(old)
                        })
                      let model =
                        Model(
                          ..model,
                          nick: case
                            string.lowercase(model.nick)
                            == string.lowercase(old)
                          {
                            True -> new
                            False -> model.nick
                          },
                          members: list.map(model.members, fn(m) {
                            case
                              string.lowercase(m.nick) == string.lowercase(old)
                            {
                              True ->
                                render.Member(
                                  ..m,
                                  nick: new,
                                  color: render.nick_color_class(new),
                                )
                              False -> m
                            }
                          }),
                        )
                      case was_member {
                        True -> #(
                          append_channel_meta(
                            model,
                            "— " <> old <> " is now known as " <> new,
                          ),
                          NoEffect,
                        )
                        False -> #(model, NoEffect)
                      }
                    }
                    _ ->
                      case render.parse_message_line(line, Some(model.nick)) {
                        Some(row) -> apply_chat_row(model, line, row)
                        None ->
                          // CHATHISTORY batch lines are skipped as rows, but still
                          // carry +freeq.at/reactions — hydrate matching REST rows.
                          case render.parse_history_reactions(line) {
                            Some(#(msgid, reactions)) -> #(
                              Model(
                                ..model,
                                messages: hydrate_reactions(
                                  model.messages,
                                  msgid,
                                  reactions,
                                ),
                              ),
                              NoEffect,
                            )
                            None ->
                              // Error numerics / WHOIS / FAIL → System buffer so
                              // slash commands get visible feedback.
                              case render.parse_system_status_line(line) {
                                Some(text) -> #(
                                  append_system_message(model, text),
                                  NoEffect,
                                )
                                None -> #(model, NoEffect)
                              }
                          }
                      }
                  }
              }
          }
      }
  }
}

fn viewing_channel(model: Model, ch: String) -> Bool {
  case model.channel {
    Some(c) -> channels_equal(c, ch)
    None -> False
  }
}

/// Append a muted meta line to the active channel stream (mode / kick / topic / nick).
fn append_channel_meta(model: Model, text: String) -> Model {
  Model(
    ..model,
    messages: append_capped(model.messages, render.system_row(text), 400),
  )
}

fn topic_setter_nick(line: String) -> Option(String) {
  let #(_tags, rest) = render.parse_irc_tags(string.trim_end(line))
  case string.starts_with(rest, ":") {
    False -> None
    True -> {
      let body = string.drop_start(rest, 1)
      case string.split_once(body, " ") {
        Ok(#(prefix, _)) ->
          case string.split_once(prefix, "!") {
            Ok(#(n, _)) -> Some(n)
            Error(_) -> Some(prefix)
          }
        Error(_) -> None
      }
    }
  }
}

/// Live PRIVMSG/NOTICE: append when viewing that channel; otherwise bump
/// sidebar unread (joined channels only, not own echoes / presence rows).
fn apply_chat_row(
  model: Model,
  line: String,
  row: render.Row,
) -> #(Model, Effect) {
  let target = render.message_target_channel(line)
  let viewing = case target, model.channel {
    Some(t), Some(c) -> channels_equal(t, c)
    _, _ -> False
  }
  case viewing {
    True -> {
      // Fast path: cache-only embed; network resolve off-session.
      let row = link_preview.attach_cache_only(row)
      let messages = append_capped(model.messages, row, 400)
      let model =
        live_search_maybe_add(Model(..model, messages: messages), row)
      let effect = case link_preview.needs_resolve(row) {
        True -> ResolveEmbeds([row])
        False -> NoEffect
      }
      #(model, effect)
    }
    False -> {
      case target {
        Some(ch) -> #(maybe_bump_unread(model, ch, row), NoEffect)
        // Server notices / directed NOTICE / non-channel targets → System tab.
        None -> #(
          Model(
            ..model,
            system_messages: append_capped(model.system_messages, row, 500),
          ),
          NoEffect,
        )
      }
    }
  }
}

/// IRC channel names are case-insensitive (freeq-server keys are lowercase).
fn channels_equal(a: String, b: String) -> Bool {
  channel_key(a) == channel_key(b)
}

fn channel_key(ch: String) -> String {
  string.lowercase(render.canonical_channel(ch))
}

fn in_my_channels(model: Model, channel: String) -> Bool {
  let key = channel_key(channel)
  list.any(model.my_channels, fn(c) { channel_key(c) == key })
}

/// Unread for a non-active joined channel (chat messages only, not own).
fn maybe_bump_unread(model: Model, channel: String, row: render.Row) -> Model {
  case row.own {
    True -> model
    False ->
      case row.kind {
        render.Msg | render.Notice ->
          case in_my_channels(model, channel) {
            True -> bump_unread(model, channel)
            False -> model
          }
        _ -> model
      }
  }
}

/// Clear the unread badge when the user opens / parts a channel.
fn clear_unread(model: Model, channel: String) -> Model {
  let key = channel_key(channel)
  // Drop any casing variant that may have been stored earlier.
  let unread =
    dict.drop(
      model.unread,
      dict.keys(model.unread)
        |> list.filter(fn(k) { channel_key(k) == key }),
    )
  Model(..model, unread: unread)
}

fn bump_unread(model: Model, channel: String) -> Model {
  let key = channel_key(channel)
  // Prefer the existing key spelling if present; else store canonical lower.
  let store_key = case
    list.find(dict.keys(model.unread), fn(k) { channel_key(k) == key })
  {
    Ok(k) -> k
    Error(_) -> key
  }
  let n = case dict.get(model.unread, store_key) {
    Ok(c) -> c + 1
    Error(_) -> 1
  }
  Model(..model, unread: dict.insert(model.unread, store_key, n))
}

/// Unread count for a channel (0 when none). Case-insensitive.
pub fn unread_count(model: Model, channel: String) -> Int {
  let key = channel_key(channel)
  dict.fold(model.unread, 0, fn(acc, k, n) {
    case channel_key(k) == key {
      True -> acc + n
      False -> acc
    }
  })
}

/// Sum of all channel unread badges (for nav / title).
pub fn total_unread(model: Model) -> Int {
  dict.fold(model.unread, 0, fn(acc, _k, n) { acc + n })
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
  // Same msgid: update in place when text/edit changes (live `+draft/edit`).
  // Pure echoes (identical text, not an edit) are skipped.
  // Soft-deleted rows stay deleted (edits / echoes must not revive them).
  case row.msgid {
    Some(id) ->
      case
        list.find(rows, fn(r) {
          case r.msgid {
            Some(existing) -> existing == id
            None -> r.id == id
          }
        })
      {
        Ok(existing) ->
          case existing.deleted {
            True -> rows
            False ->
              case existing.text == row.text && !row.edited {
                True -> rows
                False ->
                  list.map(rows, fn(r) {
                    case r.msgid {
                      Some(m) if m == id ->
                        case r.deleted {
                          True -> r
                          False ->
                            render.Row(
                              ..r,
                              text: case string.trim(row.text) {
                                "" if row.edited -> "[message cleared]"
                                _ -> row.text
                              },
                              edited: r.edited
                                || row.edited
                                || r.text != row.text,
                              reactions: case dict.size(row.reactions) {
                                0 -> r.reactions
                                _ ->
                                  render.merge_reaction_dicts(
                                    r.reactions,
                                    row.reactions,
                                  )
                              },
                              embed: case row.embed {
                                Some(e) -> Some(e)
                                None -> r.embed
                              },
                            )
                        }
                      _ -> r
                    }
                  })
              }
          }
        Error(_) -> {
          let rows = list.append(rows, [row])
          let n = list.length(rows)
          case n > cap {
            True -> list.drop(rows, n - cap)
            False -> rows
          }
        }
      }
    None -> {
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
    "/chat/system" -> #(System, None)
    _ ->
      case string.starts_with(path, "/chat/") {
        True -> {
          let bare = string.drop_start(path, 6)
          case bare == "", is_system_key(bare) {
            True, _ -> #(Index, None)
            _, True -> #(System, None)
            False, False -> #(Channel, Some(render.canonical_channel(bare)))
          }
        }
        False -> #(Index, None)
      }
  }
}

/// Browser path for the current view (`/chat`, `/chat/system`, or `/chat/freeq`).
/// Used by the client to keep the address bar in sync with LiveView state.
pub fn path_for_model(model: Model) -> String {
  case model.view, model.channel {
    System, _ -> system_path()
    Channel, Some(ch) -> channel_path(ch)
    _, _ -> "/chat"
  }
}

/// `/chat/<bare>` for a channel name (with or without `#`).
pub fn channel_path(channel: String) -> String {
  "/chat/" <> render.bare_channel(channel)
}

/// Fixed path for the System status buffer.
pub fn system_path() -> String {
  "/chat/" <> system_key
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
          ls_form.require(data, "msg")
          |> result.or(ls_form.require(data, "text")),
        )
        Ok(Send(text))
      })
    }),
    stateful.route("reply", fn(e) {
      event.decode_form(e, "reply", fn(data) {
        use msgid <- result.try(ls_form.require(data, "msgid"))
        Ok(StartReply(msgid))
      })
    }),
    stateful.route("edit", fn(e) {
      event.decode_form(e, "edit", fn(data) {
        use msgid <- result.try(ls_form.require(data, "msgid"))
        Ok(StartEdit(msgid))
      })
    }),
    stateful.route("delete", fn(e) {
      event.decode_form(e, "delete", fn(data) {
        use msgid <- result.try(ls_form.require(data, "msgid"))
        Ok(DeleteMessage(msgid))
      })
    }),
    stateful.route("cancel_reply", fn(e) {
      event.decode_unit(e, "cancel_reply", CancelReply)
    }),
    stateful.route("join", fn(e) {
      event.decode_form(e, "join", fn(data) {
        use ch <- result.try(ls_form.require(data, "channel"))
        Ok(Join(ch))
      })
    }),
    stateful.route("part", fn(e) {
      event.decode_form(e, "part", fn(data) {
        use ch <- result.try(ls_form.require(data, "channel"))
        Ok(Part(ch))
      })
    }),
    stateful.route("go_index", fn(e) {
      event.decode_unit(e, "go_index", GoIndex)
    }),
    stateful.route("open", fn(e) {
      event.decode_form(e, "open", fn(data) {
        use ch <- result.try(ls_form.require(data, "channel"))
        Ok(OpenChannel(ch))
      })
    }),
    stateful.route("set_topic", fn(e) {
      event.decode_form(e, "set_topic", fn(data) {
        use topic <- result.try(ls_form.require(data, "topic"))
        Ok(SetTopic(topic))
      })
    }),
    stateful.route("edit_topic", fn(e) {
      event.decode_unit(e, "edit_topic", EditTopic)
    }),
    stateful.route("cancel_topic_edit", fn(e) {
      event.decode_unit(e, "cancel_topic_edit", CancelTopicEdit)
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
        use raw <- result.try(ls_form.require(data, "count"))
        case int.parse(raw) {
          Ok(n) -> Ok(AvRoster(n))
          Error(_) -> Ok(AvRoster(0))
        }
      })
    }),
    stateful.route("open_react_picker", fn(e) {
      event.decode_form(e, "open_react_picker", fn(data) {
        use msgid <- result.try(ls_form.require(data, "msgid"))
        Ok(OpenReactPicker(msgid))
      })
    }),
    stateful.route("close_react_picker", fn(e) {
      event.decode_unit(e, "close_react_picker", CloseReactPicker)
    }),
    stateful.route("toggle_reaction", fn(e) {
      event.decode_form(e, "toggle_reaction", fn(data) {
        use msgid <- result.try(ls_form.require(data, "msgid"))
        use emoji <- result.try(ls_form.require(data, "emoji"))
        Ok(ToggleReaction(msgid, emoji))
      })
    }),
    stateful.route("load_older", fn(e) {
      event.decode_unit(e, "load_older", LoadOlder)
    }),
    stateful.route("open_search", fn(e) {
      event.decode_unit(e, "open_search", OpenSearch)
    }),
    stateful.route("close_search", fn(e) {
      event.decode_unit(e, "close_search", CloseSearch)
    }),
    stateful.route("search", fn(e) {
      event.decode_form(e, "search", fn(data) {
        use q <- result.try(
          ls_form.require(data, "q")
          |> result.or(ls_form.require(data, "query")),
        )
        Ok(RunSearch(q))
      })
    }),
    stateful.route("jump_to_msg", fn(e) {
      event.decode_form(e, "jump_to_msg", fn(data) {
        use msgid <- result.try(ls_form.require(data, "msgid"))
        let ts = case ls_form.require(data, "ts") {
          Ok(raw) ->
            case int.parse(string.trim(raw)) {
              Ok(n) if n > 0 -> Some(n)
              _ -> None
            }
          Error(_) -> None
        }
        Ok(JumpToMsg(msgid, ts))
      })
    }),
    stateful.route("clear_scroll_to", fn(e) {
      event.decode_unit(e, "clear_scroll_to", ClearScrollTo)
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
      // Channel / System chat: patch messages (and compose on Channel) so
      // the compose input is not remounted on every PRIVMSG.
      // Index, or view switches: replace the whole main region.
      let acc = case before.view, after.view {
        Channel, Channel -> {
          let acc = maybe_region(before, after, "flash", flash_region, acc)
          let acc =
            maybe_region(before, after, "messages", messages_region, acc)
          maybe_region(before, after, "compose", compose_region, acc)
        }
        System, System -> {
          let acc = maybe_region(before, after, "flash", flash_region, acc)
          let acc =
            maybe_region(before, after, "messages", messages_region, acc)
          // Compose stays mounted; only patch if structure changes (rare).
          maybe_region(before, after, "compose", compose_region, acc)
        }
        _, _ -> maybe_region(before, after, "main", main_region, acc)
      }
      // AV panel is a sibling of main so directory browse keeps the call.
      let acc = maybe_region(before, after, "av", av_region, acc)
      let acc = maybe_region(before, after, "members", members_region, acc)
      let acc =
        maybe_region(before, after, "react-picker", react_picker_region, acc)
      // Search: open/close replaces the host; while open, patch form and body
      // separately so keystrokes do not remount the input (would drop focus).
      let acc = case before.search_open, after.search_open {
        True, True -> {
          let acc =
            maybe_region(before, after, "search-form", search_form_region, acc)
          maybe_region(before, after, "search-body", search_body_region, acc)
        }
        _, _ -> maybe_region(before, after, "search", search_region, acc)
      }
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
  <> "</div>"
  <> react_picker_region(model)
  <> search_region(model)
  <> "</div>"
}

fn react_picker_region(model: Model) -> String {
  case model.react_picker_msgid {
    None ->
      "<div data-ls-region=\"react-picker\" class=\"react-picker-host\"></div>"
    Some(msgid) -> {
      let buttons =
        list.map(render.react_emojis(), fn(emoji) {
          "<button type=\"button\" data-ls-click=\"toggle_reaction\" data-ls-payload=\"msgid="
          <> render.escape_html(msgid)
          <> "&emoji="
          <> render.escape_html(emoji)
          <> "\">"
          <> emoji
          <> "</button>"
        })
        |> string.concat
      "<div data-ls-region=\"react-picker\" class=\"react-picker-host\">"
      <> "<div id=\"react-picker-backdrop\" class=\"react-picker-backdrop\" data-ls-click=\"close_react_picker\"></div>"
      <> "<div id=\"react-picker\" class=\"open\" role=\"menu\" aria-label=\"React with emoji\">"
      <> buttons
      <> "</div></div>"
    }
  }
}

fn search_region(model: Model) -> String {
  case model.search_open {
    False ->
      "<div data-ls-region=\"search\" class=\"search-host\" hidden></div>"
    True ->
      "<div data-ls-region=\"search\" class=\"search-host\">"
      <> "<div class=\"search-backdrop\" data-ls-click=\"close_search\" aria-hidden=\"true\"></div>"
      <> "<div class=\"search-modal\" role=\"dialog\" aria-label=\"Search messages\" aria-modal=\"true\">"
      <> search_form_region(model)
      <> search_body_region(model)
      <> "</div></div>"
  }
}

/// Search box — client owns the draft (no `value`); only channel placeholder
/// comes from the model so typing does not remount the input.
fn search_form_region(model: Model) -> String {
  let ch = option.unwrap(model.channel, "")
  "<div data-ls-region=\"search-form\">"
  <> "<form id=\"search-form\" class=\"search-form\" data-ls-submit=\"search\">"
  <> "<svg class=\"search-icon\" viewBox=\"0 0 16 16\" aria-hidden=\"true\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\">"
  <> "<circle cx=\"7\" cy=\"7\" r=\"5\" /><path d=\"M11 11l3.5 3.5\" />"
  <> "</svg>"
  <> "<input id=\"search-input\" type=\"search\" name=\"q\" placeholder=\"Search "
  <> render.escape_html(ch)
  <> "…\" autocomplete=\"off\" maxlength=\"200\" autofocus />"
  <> "<kbd class=\"search-esc\">ESC</kbd>"
  <> "</form></div>"
}

/// Status line + hit list (updates on every keystroke / REST response).
fn search_body_region(model: Model) -> String {
  let status = case model.search_status {
    "" -> ""
    s ->
      "<div class=\"search-status"
      <> case model.search_loading {
        True -> " search-status-loading"
        False -> ""
      }
      <> "\">"
      <> render.escape_html(s)
      <> "</div>"
  }
  let hits = search_hits_html(model)
  "<div data-ls-region=\"search-body\">"
  <> status
  <> "<div class=\"search-results\" id=\"search-results\">"
  <> hits
  <> "</div></div>"
}

fn search_hits_html(model: Model) -> String {
  case model.search_results {
    [] -> ""
    results ->
      list.map(results, search_hit_html)
      |> string.concat
  }
}

fn search_hit_html(row: render.Row) -> String {
  let nick = option.unwrap(row.nick, "unknown")
  let mid = option.unwrap(row.msgid, row.id)
  let scroll = case mid {
    "" -> ""
    m -> " data-scroll-to=\"" <> render.escape_html(m) <> "\""
  }
  let ts_attr = case row.timestamp {
    Some(t) -> " data-ts=\"" <> int.to_string(t) <> "\""
    None -> ""
  }
  // Client: jump_to_msg closes the modal, loads history if the row is not
  // in the pane, then scrolls/highlights the hit.
  "<button type=\"button\" class=\"search-hit\""
  <> scroll
  <> ts_attr
  <> ">"
  <> "<div class=\"search-hit-meta\">"
  <> "<span class=\"search-hit-nick\">"
  <> render.escape_html(nick)
  <> "</span>"
  <> "<span class=\"search-hit-time\">"
  <> render.escape_html(row.time_label)
  <> "</span>"
  <> "</div>"
  <> "<div class=\"search-hit-text\">"
  <> render.escape_html(row.text)
  <> "</div>"
  <> "</button>"
}

fn nav_region(model: Model) -> String {
  let channel_label = case model.view, model.channel {
    Index, _ -> "channels"
    System, _ -> "System"
    Channel, Some(ch) -> ch
    Channel, None -> "chat"
  }
  let topic_label = case model.topic {
    "" -> "add topic"
    t -> render.escape_html(t)
  }
  let connected = case model.ws {
    WsReady -> " connected"
    _ -> ""
  }
  let search_btn = case model.view {
    Channel ->
      "<button type=\"button\" class=\"nav-search-btn\" data-ls-click=\"open_search\" title=\"Search messages (Ctrl+F)\" aria-label=\"Search messages\">"
      <> "<svg viewBox=\"0 0 16 16\" aria-hidden=\"true\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\">"
      <> "<circle cx=\"7\" cy=\"7\" r=\"5\" />"
      <> "<path d=\"M11 11l3.5 3.5\" />"
      <> "</svg></button>"
    Index | System -> ""
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
    Index | System -> ""
  }
  let topic_ui = case model.view {
    Index | System -> ""
    Channel ->
      case model.editing_topic {
        True ->
          "<form id=\"topic-form\" data-ls-submit=\"set_topic\">"
          <> "<input id=\"topic-input\" type=\"text\" name=\"topic\" value=\""
          <> render.escape_html(model.topic)
          <> "\" placeholder=\"Set topic… (Enter to save, Esc to cancel)\" "
          <> "autocomplete=\"off\" maxlength=\"390\" autofocus />"
          <> "</form>"
        False -> {
          let editable = can_edit_topic(model)
          let class = case editable {
            True -> "editable"
            False -> ""
          }
          let title = case editable {
            True -> "Click to edit topic"
            False -> "Channel topic"
          }
          let click = case editable {
            True -> " data-ls-click=\"edit_topic\""
            False -> ""
          }
          "<span id=\"channel-topic\" class=\""
          <> class
          <> "\" title=\""
          <> title
          <> "\""
          <> click
          <> ">"
          <> topic_label
          <> "</span>"
        }
      }
  }
  let total = total_unread(model)
  let channels_badge = case total > 0 {
    True -> {
      let label = case total > 99 {
        True -> "99+"
        False -> int.to_string(total)
      }
      "<span class=\"nav-channels-unread\" aria-label=\""
      <> label
      <> " unread across channels\">"
      <> label
      <> "</span>"
    }
    False -> ""
  }
  "<nav data-ls-region=\"nav\""
  <> case total > 0 {
    True -> " data-unread-total=\"" <> int.to_string(total) <> "\""
    False -> " data-unread-total=\"0\""
  }
  <> ">"
  <> "<button type=\"button\" class=\"mobile-btn channels-btn\" data-drawer=\"sidebar\" aria-label=\"Channels\">"
  <> "<svg viewBox=\"0 0 24 24\" aria-hidden=\"true\"><path d=\"M4 7h16M4 12h16M4 17h16\" /></svg>"
  <> channels_badge
  <> "</button>"
  <> "<span class=\"brand\">freeq</span>"
  <> "<div class=\"nav-channel-meta\">"
  <> "<span class=\"nav-channel\">"
  <> render.escape_html(channel_label)
  <> "</span>"
  <> topic_ui
  <> av_call_button(model)
  <> "</div>"
  <> "<div class=\"nav-right\">"
  <> search_btn
  <> "<span id=\"status\" class=\""
  <> connected
  <> "\"><span class=\"dot\"></span><span>"
  <> render.escape_html(model.status)
  <> "</span></span>"
  <> people_btn
  <> auth_badge(model)
  <> "</div></nav>"
}

/// Channel +o / half-op can set topic when +t is on; server enforces 482.
/// Founder/admin prefixes are already folded into `Member.op` by the parser.
fn can_edit_topic(model: Model) -> Bool {
  let nick = string.lowercase(string.trim(model.nick))
  case nick == "" {
    True -> False
    False ->
      case
        list.find(model.members, fn(m) {
          string.lowercase(m.nick) == nick
        })
      {
        Ok(m) -> m.op || m.halfop
        Error(_) -> False
      }
  }
}

fn av_call_button(model: Model) -> String {
  let show = case model.view {
    Channel -> True
    Index | System -> model.av_active
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
  let system_active = case model.view {
    System -> " active"
    _ -> ""
  }
  let system_dot = case model.view, model.system_messages {
    System, _ -> ""
    _, [] -> ""
    _, _ -> "<span class=\"system-dot\" aria-hidden=\"true\"></span>"
  }
  let system_li =
    "<li class=\"system-channel"
    <> system_active
    <> "\">"
    <> "<a href=\""
    <> system_path()
    <> "\" class=\"channel-link\" data-ls-click=\"open\" data-ls-payload=\"channel="
    <> system_key
    <> "\" title=\"Connection status and server notices\">"
    <> "<span class=\"channel-link-icon\" aria-hidden=\"true\">⚙</span>"
    <> "<span class=\"channel-link-name\">System</span>"
    <> system_dot
    <> "</a>"
    <> "</li>"

  let my =
    list.map(model.my_channels, fn(ch) {
      let bare = render.bare_channel(ch)
      let n = unread_count(model, ch)
      let has_unread = n > 0
      let active = case model.view, model.channel {
        Channel, Some(c) if c == ch -> " active"
        _, _ -> ""
      }
      let unread_class = case has_unread {
        True -> " has-unread"
        False -> ""
      }
      let badge = case has_unread {
        True -> {
          let label = case n > 99 {
            True -> "99+"
            False -> int.to_string(n)
          }
          "<span class=\"channel-unread\" aria-label=\""
          <> label
          <> " unread\">"
          <> label
          <> "</span>"
        }
        False -> ""
      }
      "<li class=\""
      <> active
      <> unread_class
      <> "\">"
      <> "<a href=\""
      <> channel_path(ch)
      <> "\" class=\"channel-link\" data-ls-click=\"open\" data-ls-payload=\"channel="
      <> bare
      <> "\"><span class=\"channel-link-name\">"
      <> render.escape_html(ch)
      <> "</span>"
      <> badge
      <> "</a>"
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
  <> "<ul id=\"system-channels\">"
  <> system_li
  <> "</ul>"
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
    System -> system_main(model)
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
  // Shell + jump FAB sit *outside* data-ls-region=messages so message
  // patches replace only #messages (applyReplace swaps by tag/selector).
  // If the shell were inside messages_region HTML, each PRIVMSG would
  // nest another .messages-shell and the FAB would never show correctly.
  "<section class=\"chat-main\" data-ls-region=\"main\">"
  <> flash_region(model)
  <> "<div class=\"messages-shell\">"
  <> messages_region(model)
  <> jump_bottom_html()
  <> "</div>"
  <> compose_region(model)
  <> "</section>"
}

/// System buffer: notices + connection log + slash-command compose.
fn system_main(model: Model) -> String {
  "<section class=\"chat-main\" data-ls-region=\"main\">"
  <> flash_region(model)
  <> "<div class=\"messages-shell\">"
  <> messages_region(model)
  <> jump_bottom_html()
  <> "</div>"
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

/// ONLY the #messages node — must match `[data-ls-region=\"messages\"]`.
/// Pub for unit tests (region HTML must not wrap shell/FAB).
pub fn messages_region_for_test(model: Model) -> String {
  messages_region(model)
}

/// Compose stack (banner + send bar) for unit tests.
pub fn compose_region_for_test(model: Model) -> String {
  compose_region(model)
}

fn messages_region(model: Model) -> String {
  let rows = case model.view {
    System -> model.system_messages
    _ -> model.messages
  }
  let lookup = parent_lookup_from_rows(rows)
  let aliases = my_reaction_aliases(model)
  let loader = case model.view, model.history_loading {
    Channel, True -> history_loading_html()
    _, _ -> ""
  }
  let scroll_mid = option.unwrap(model.scroll_to_msgid, "")
  let empty = case model.view, rows {
    System, [] ->
      "<div class=\"empty-state system-empty\">"
      <> "<div class=\"empty-state-title\">System</div>"
      <> "<div class=\"empty-state-sub\">Connection status and server notices will appear here.</div>"
      <> "</div>"
    _, _ -> ""
  }
  let my_nick = model.nick
  let msgs =
    list.map(rows, fn(row) {
      message_html(row, lookup, aliases, scroll_mid, my_nick)
    })
    |> string.concat
  let loading = case model.view, model.history_loading {
    Channel, True -> "1"
    _, _ -> "0"
  }
  let exhausted = case model.view {
    System -> "1"
    _ ->
      case model.history_exhausted {
        True -> "1"
        False -> "0"
      }
  }
  let scroll_attr = case scroll_mid {
    "" -> ""
    mid -> " data-scroll-to-msgid=\"" <> render.escape_html(mid) <> "\""
  }
  "<div id=\"messages\" class=\"messages\" data-ls-region=\"messages\""
  <> " data-history-loading=\""
  <> loading
  <> "\" data-history-exhausted=\""
  <> exhausted
  <> "\""
  <> scroll_attr
  <> ">"
  <> loader
  <> empty
  <> msgs
  <> "</div>"
}

/// Floating control shown by client JS when the user scrolls up the stream.
pub fn jump_bottom_html() -> String {
  "<button type=\"button\" id=\"jump-bottom\" class=\"jump-bottom\" hidden"
  <> " aria-label=\"Jump to bottom\">"
  <> "<svg class=\"jump-bottom-icon\" viewBox=\"0 0 16 16\" width=\"14\" height=\"14\""
  <> " aria-hidden=\"true\" focusable=\"false\">"
  <> "<path fill=\"currentColor\" fill-rule=\"evenodd\""
  <> " d=\"M8 1a.5.5 0 01.5.5v11.793l3.146-3.147a.5.5 0 01.708.708l-4 4"
  <> "a.5.5 0 01-.708 0l-4-4a.5.5 0 01.708-.708L7.5 13.293V1.5A.5.5 0 018 1z\"/>"
  <> "</svg>"
  <> "<span class=\"jump-bottom-label\">Jump to bottom</span>"
  <> "</button>"
}

/// Spinner + label for scroll-up history fetch (also injected client-side).
pub fn history_loading_html() -> String {
  "<div class=\"history-loading\" aria-live=\"polite\" role=\"status\">"
  <> "<span class=\"history-spinner\" aria-hidden=\"true\"></span>"
  <> "<span class=\"history-loading-text\">Loading older messages…</span>"
  <> "</div>"
}

/// msgid → {nick, text} so reply badges can quote the original in-channel.
fn parent_lookup_from_rows(
  rows: List(render.Row),
) -> Dict(String, #(String, String)) {
  list.fold(rows, dict.new(), fn(acc, row) {
    case row.msgid, row.nick {
      Some(mid), Some(nick) if mid != "" ->
        dict.insert(acc, mid, #(nick, row.text))
      Some(mid), None if mid != "" ->
        dict.insert(acc, mid, #("", row.text))
      _, _ -> acc
    }
  })
}

fn compose_region(model: Model) -> String {
  // IDs match app.css / freeq-web2 (#send-bar, #attach-btn, #upload-preview).
  // No value attr on the text input: draft is client-owned so message patches
  // never wipe it. Image paste/upload is handled client-side (POST /upload).
  let system = case model.view {
    System -> True
    _ -> False
  }
  let ch = option.unwrap(model.channel, "")
  let auth_did = case model.authenticated {
    True -> model.auth_did
    False -> ""
  }
  let banner = reply_banner_html(model)
  let attach = case system {
    True -> ""
    False ->
      "<input type=\"file\" id=\"file-input\" accept=\"image/*,image/png,image/jpeg,image/gif,image/webp\" hidden />"
      <> "<button type=\"button\" id=\"attach-btn\" class=\"attach-btn\" title=\"Upload screenshot or image\" aria-label=\"Upload image\">+</button>"
  }
  let placeholder = case system {
    True -> "Type /join #channel, /whois nick, …"
    False ->
      "Message " <> render.escape_html(ch) <> "… (paste images)"
  }
  let channel_attr = case system {
    True -> system_key
    False -> ch
  }
  let compose_mode = case model.edit_to, model.reply_to {
    Some(mid), _ if mid != "" -> "edit"
    _, Some(mid) if mid != "" -> "reply"
    _, _ -> ""
  }
  let prefill_attr = case model.edit_to, model.compose {
    Some(mid), text if mid != "" && text != "" ->
      " data-compose-prefill=\"" <> render.escape_html(text) <> "\""
    _, _ -> ""
  }
  let mode_attr = case compose_mode {
    "" -> ""
    m -> " data-compose-mode=\"" <> m <> "\""
  }
  "<div id=\"compose-stack\" data-ls-region=\"compose\""
  <> case system {
    True -> " class=\"system-compose\""
    False -> ""
  }
  <> mode_attr
  <> prefill_attr
  <> ">"
  <> case system {
    True -> ""
    False ->
      "<div id=\"upload-preview\" class=\"upload-preview\" hidden>"
      <> "<img id=\"upload-preview-img\" alt=\"preview\" />"
      <> "<div class=\"upload-preview-meta\">"
      <> "<span id=\"upload-preview-name\"></span>"
      <> "<span id=\"upload-preview-status\"></span>"
      <> "</div>"
      <> "<button type=\"button\" id=\"upload-preview-cancel\" class=\"btn-link\" title=\"Cancel\">×</button>"
      <> "</div>"
  }
  <> banner
  <> "<div id=\"send-bar\">"
  <> attach
  <> "<form id=\"send-form\" data-ls-submit=\"send\" data-channel=\""
  <> render.escape_html(channel_attr)
  <> "\" data-auth-did=\""
  <> render.escape_html(auth_did)
  <> "\">"
  <> "<input id=\"message-input\" type=\"text\" name=\"msg\" placeholder=\""
  <> placeholder
  <> "\" autocomplete=\"off\" autofocus />"
  <> "<button type=\"submit\">Send</button>"
  <> "</form>"
  <> "</div></div>"
}

fn reply_banner_html(model: Model) -> String {
  case model.view, model.edit_to, model.reply_to {
    Channel, Some(mid), _ if mid != "" -> {
      let text_span = case model.reply_preview_text {
        "" -> ""
        t ->
          "<span class=\"reply-banner-text\">"
          <> render.escape_html(t)
          <> "</span>"
      }
      "<div id=\"reply-banner\" class=\"reply-banner\" data-mode=\"edit\">"
      <> "<span class=\"reply-banner-label\">Editing message</span>"
      <> text_span
      <> "<button type=\"button\" class=\"reply-banner-delete\" title=\"Delete message\" data-ls-click=\"delete\" data-ls-payload=\"msgid="
      <> render.escape_html(mid)
      <> "\">Delete</button>"
      <> "<button type=\"button\" class=\"reply-banner-cancel\" title=\"Cancel\" data-ls-click=\"cancel_reply\">×</button>"
      <> "</div>"
    }
    Channel, None, Some(mid) if mid != "" -> {
      let nick = case model.reply_preview_nick {
        "" -> "message"
        n -> n
      }
      let text_span = case model.reply_preview_text {
        "" -> ""
        t ->
          "<span class=\"reply-banner-text\">"
          <> render.escape_html(t)
          <> "</span>"
      }
      "<div id=\"reply-banner\" class=\"reply-banner\" data-mode=\"reply\">"
      <> "<span class=\"reply-banner-label\">Replying to "
      <> render.escape_html(nick)
      <> "</span>"
      <> text_span
      <> "<button type=\"button\" class=\"reply-banner-cancel\" title=\"Cancel\" data-ls-click=\"cancel_reply\">×</button>"
      <> "</div>"
    }
    _, _, _ -> ""
  }
}

fn message_html(
  row: render.Row,
  lookup: Dict(String, #(String, String)),
  aliases: List(String),
  scroll_mid: String,
  my_nick: String,
) -> String {
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
  let is_own = is_own_row(row, my_nick)
  let own = case is_own {
    True -> " own"
    False -> ""
  }
  // Server-rendered highlight so Lightspeed region replaces keep the flash
  // (client-only classList is wiped when clear_scroll_to remounts #messages).
  let hl = case scroll_mid {
    "" -> ""
    target ->
      case row.msgid, row.id {
        Some(mid), _ if mid == target -> " highlight"
        _, id if id == target -> " highlight"
        _, _ -> ""
      }
  }
  let data_nick = case row.nick {
    Some(n) -> " data-nick=\"" <> render.escape_html(n) <> "\""
    None -> ""
  }
  let data_text = case row.kind {
    render.Msg | render.Notice ->
      " data-text=\"" <> render.escape_html(row.text) <> "\""
    _ -> ""
  }
  let deleted_cls = case row.deleted {
    True -> " deleted"
    False -> ""
  }
  let body_inner = case row.deleted {
    True -> {
      let who = case row.nick {
        Some(n) -> render.escape_html(n)
        None -> "someone"
      }
      "<span class=\"msg-deleted-label\">Message from "
      <> who
      <> " deleted</span>"
    }
    False -> {
      let badge = reply_badge_html(row, lookup)
      let reactions = reactions_html(row, aliases)
      let reply_btn = reply_btn_html(row)
      let edit_btn = edit_btn_html(row, is_own)
      let edited_mark = case row.edited {
        True -> "<span class=\"msg-edited\" title=\"Edited\">(edited)</span>"
        False -> ""
      }
      badge
      <> nick
      <> render.linkify_html(row.text)
      <> edited_mark
      <> reactions
      <> reply_btn
      <> edit_btn
    }
  }
  // data-ts = unix seconds so the browser can localize to 12h + day separators.
  let ts_attr = case row.timestamp {
    Some(sec) -> " data-ts=\"" <> int.to_string(sec) <> "\""
    None -> ""
  }
  "<div class=\"row "
  <> kind
  <> own
  <> deleted_cls
  <> hl
  <> "\" data-msgid=\""
  <> render.escape_html(option.unwrap(row.msgid, row.id))
  <> "\""
  <> data_nick
  <> data_text
  <> ">"
  <> "<span class=\"ts\""
  <> ts_attr
  <> ">"
  <> render.escape_html(row.time_label)
  <> "</span>"
  <> "<span class=\"body\">"
  <> body_inner
  <> "</span>"
  <> case row.deleted {
    True -> ""
    False -> link_embed_html(row.embed)
  }
  <> "</div>"
}

/// Open Graph / YouTube / Bluesky card under the message body (web3 parity).
fn link_embed_html(embed: Option(render.Embed)) -> String {
  case embed {
    None -> ""
    Some(e) -> {
      let kind_class = case e.kind {
        render.Youtube -> " yt-embed"
        render.Bsky -> " bsky-embed"
        render.Og -> ""
      }
      let inner = case e.kind, e.bsky {
        render.Bsky, Some(b) -> bsky_embed_inner(e, b)
        render.Youtube, _ -> youtube_embed_inner(e)
        _, _ -> og_embed_inner(e)
      }
      "<a href=\""
      <> render.escape_html(e.href)
      <> "\" target=\"_blank\" rel=\"noopener noreferrer\" class=\"link-embed"
      <> kind_class
      <> "\" style=\"grid-column: 2\">"
      <> inner
      <> "</a>"
    }
  }
}

fn youtube_embed_inner(e: render.Embed) -> String {
  let img = case e.image_url {
    Some(src) ->
      "<img class=\"link-embed-img yt-thumb\" src=\""
      <> render.escape_html(src)
      <> "\" alt=\"\" loading=\"lazy\">"
    None -> ""
  }
  img
  <> "<div class=\"link-embed-body yt-footer\"><span class=\"yt-play\">▶</span> YouTube</div>"
}

fn og_embed_inner(e: render.Embed) -> String {
  let img = case e.image_url {
    Some(src) ->
      "<img class=\"link-embed-img\" src=\""
      <> render.escape_html(src)
      <> "\" alt=\"\" loading=\"lazy\" referrerpolicy=\"no-referrer\">"
    None -> ""
  }
  let site = case e.site_name {
    Some(s) ->
      "<div class=\"link-embed-site\">" <> render.escape_html(s) <> "</div>"
    None -> ""
  }
  let title = case e.title {
    Some(t) ->
      "<div class=\"link-embed-title\">" <> render.escape_html(t) <> "</div>"
    None -> ""
  }
  let desc = case e.description {
    Some(d) ->
      "<div class=\"link-embed-desc\">" <> render.escape_html(d) <> "</div>"
    None -> ""
  }
  let domain = case e.domain {
    Some(d) ->
      "<div class=\"link-embed-domain\">" <> render.escape_html(d) <> "</div>"
    None -> ""
  }
  img
  <> "<div class=\"link-embed-body\">"
  <> site
  <> title
  <> desc
  <> domain
  <> "</div>"
}

fn bsky_embed_inner(e: render.Embed, b: render.BskyMeta) -> String {
  let avatar = case b.avatar_url {
    Some(src) ->
      "<img class=\"bsky-avatar\" src=\""
      <> render.escape_html(src)
      <> "\" alt=\"\" loading=\"lazy\">"
    None -> {
      let letter = case string.first(b.handle) {
        Ok(ch) -> string.uppercase(ch)
        Error(_) -> "?"
      }
      "<span class=\"bsky-avatar bsky-avatar-fallback\">"
      <> render.escape_html(letter)
      <> "</span>"
    }
  }
  let img = case e.image_url {
    Some(src) ->
      "<img class=\"link-embed-img\" src=\""
      <> render.escape_html(src)
      <> "\" alt=\"\" loading=\"lazy\">"
    None -> ""
  }
  "<div class=\"bsky-author\">"
  <> avatar
  <> "<span class=\"bsky-name\">"
  <> render.escape_html(b.display)
  <> "</span>"
  <> "<span class=\"bsky-handle\">@"
  <> render.escape_html(b.handle)
  <> "</span></div>"
  <> "<div class=\"bsky-text\">"
  <> render.escape_html(b.text)
  <> "</div>"
  <> img
  <> "<div class=\"bsky-footer\"><span>♥ "
  <> int.to_string(b.likes)
  <> "</span><span>↻ "
  <> int.to_string(b.reposts)
  <> "</span><span class=\"bsky-time\">🦋 "
  <> render.escape_html(b.time)
  <> "</span></div>"
}

/// Hover reply control — starts compose-side `@+reply=` mode.
fn reply_btn_html(row: render.Row) -> String {
  case row.deleted, row.kind, row.msgid {
    False, render.Msg, Some(mid) if mid != "" ->
      "<button type=\"button\" class=\"reply-btn\" title=\"Reply\" data-ls-click=\"reply\" data-ls-payload=\"msgid="
      <> render.escape_html(mid)
      <> "\">↩</button>"
    _, _, _ -> ""
  }
}

/// Hover edit control — only on own messages (`@+draft/edit=`).
fn edit_btn_html(row: render.Row, is_own: Bool) -> String {
  case is_own, row.deleted, row.kind, row.msgid {
    True, False, render.Msg, Some(mid) if mid != "" ->
      "<button type=\"button\" class=\"edit-btn\" title=\"Edit\" data-ls-click=\"edit\" data-ls-payload=\"msgid="
      <> render.escape_html(mid)
      <> "\">✎</button>"
    _, _, _, _ -> ""
  }
}

fn is_own_row(row: render.Row, my_nick: String) -> Bool {
  case row.own {
    True -> True
    False ->
      case row.nick {
        Some(n) -> string.lowercase(n) == string.lowercase(my_nick)
        None -> False
      }
  }
}

/// Soft-delete a message: optimistic local mark + upstream TAGMSG.
fn delete_message(model: Model, msgid: String) -> #(Model, Effect) {
  let msgid = string.trim(msgid)
  case msgid == "", model.channel, message_is_deleted(model.messages, msgid) {
    True, _, _ -> #(model, NoEffect)
    _, None, _ -> #(model, NoEffect)
    _, _, True -> #(model, NoEffect)
    False, Some(ch), False -> {
      let model = apply_delete_to_model(model, msgid)
      #(model, IrcSend([render.delete_line(ch, msgid)]))
    }
  }
}

/// Mark msgid deleted and cancel compose if that message was being edited/replied.
fn apply_delete_to_model(model: Model, msgid: String) -> Model {
  let messages =
    list.map(model.messages, fn(row) {
      case row.msgid {
        Some(m) if m == msgid -> render.mark_row_deleted(row)
        _ ->
          case row.id == msgid {
            True -> render.mark_row_deleted(row)
            False -> row
          }
      }
    })
  let model = Model(..model, messages: messages)
  let editing_this = case model.edit_to {
    Some(m) if m == msgid -> True
    _ -> False
  }
  let replying_this = case model.reply_to {
    Some(m) if m == msgid -> True
    _ -> False
  }
  case editing_this || replying_this {
    True -> clear_reply(model)
    False -> model
  }
}

fn message_is_deleted(rows: List(render.Row), msgid: String) -> Bool {
  case msgid == "" {
    True -> False
    False ->
      list.any(rows, fn(r) {
        case r.msgid {
          Some(id) if id == msgid -> r.deleted
          _ -> r.id == msgid && r.deleted
        }
      })
  }
}

fn reactions_html(row: render.Row, aliases: List(String)) -> String {
  case row.deleted, row.kind, row.msgid {
    True, _, _ -> ""
    False, render.Msg, Some(msgid) if msgid != "" -> {
      let chips =
        list.map(render.reaction_entries(row.reactions), fn(entry) {
          let #(emoji, nicks) = entry
          let mine = case nick_in_aliases(nicks, aliases) {
            True -> " mine"
            False -> ""
          }
          let title =
            nicks
            |> string.join(", ")
            |> render.escape_html
          "<button type=\"button\" class=\"reaction-chip"
          <> mine
          <> "\" title=\""
          <> title
          <> "\" data-ls-click=\"toggle_reaction\" data-ls-payload=\"msgid="
          <> render.escape_html(msgid)
          <> "&emoji="
          <> render.escape_html(emoji)
          <> "\">"
          <> render.escape_html(render.reaction_chip_label(emoji, nicks))
          <> "</button>"
        })
        |> string.concat
      "<span class=\"reactions\">"
      <> chips
      <> "<button type=\"button\" class=\"react-btn\" title=\"React\" data-ls-click=\"open_react_picker\" data-ls-payload=\"msgid="
      <> render.escape_html(msgid)
      <> "\">+</button></span>"
    }
    _, _, _ -> ""
  }
}

/// Inline quote of the parent message on replies (freeq-web2 / web3 parity).
fn reply_badge_html(
  row: render.Row,
  lookup: Dict(String, #(String, String)),
) -> String {
  case row.kind, row.parent {
    render.Msg, Some(parent) if parent != "" -> {
      let #(parent_nick, parent_text) = case dict.get(lookup, parent) {
        Ok(#(n, t)) -> #(n, t)
        Error(_) -> #("", "")
      }
      let nick_label = case parent_nick {
        "" -> "message"
        n -> n
      }
      let text_span = case parent_text {
        "" -> ""
        t ->
          "<span class=\"reply-text\">"
          <> render.escape_html(render.preview_text(t))
          <> "</span>"
      }
      "<button type=\"button\" class=\"reply-badge\" data-reply-to=\""
      <> render.escape_html(parent)
      <> "\" title=\"Jump to original\">↪ <span class=\"reply-nick\">"
      <> render.escape_html(nick_label)
      <> "</span>"
      <> text_span
      <> "</button>"
    }
    _, _ -> ""
  }
}

fn members_region(model: Model) -> String {
  case model.view {
    Index | System ->
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
/// Drops the local System key if it was ever persisted by mistake.
pub fn merge_my_channels(
  seed: List(String),
  persisted: List(String),
) -> List(String) {
  list.fold(persisted, seed, list_unique_append)
  |> list.filter(fn(c) { !is_system_key(c) })
}

/// Merge REST history with any live rows already on the model.
///
/// REST is the chronological base; live-only rows (msgid not in REST) are
/// appended so a post-SASL backfill does not drop messages that arrived
/// while the first anonymous fetch was empty.
///
/// When a msgid exists in both, reaction tallies are unioned so live TAGMSG /
/// CHATHISTORY hydration is not wiped by a later REST backfill that still
/// lacks `+freeq.at/reactions` (older freeq-server).
pub fn merge_history_rows(
  rest_rows: List(render.Row),
  live_rows: List(render.Row),
) -> List(render.Row) {
  case rest_rows {
    [] -> live_rows
    _ ->
      list.fold(live_rows, rest_rows, fn(acc, row) {
        case row_msgid_known(acc, row) {
          True -> union_reactions_into(acc, row)
          False -> list.append(acc, [row])
        }
      })
  }
}

/// Prepend an older REST page in front of the current stream (scroll-up).
///
/// Drops rows already present (by msgid) so a race with live traffic is safe.
pub fn prepend_history_rows(
  older: List(render.Row),
  current: List(render.Row),
) -> List(render.Row) {
  case older {
    [] -> current
    _ -> {
      let new_only =
        list.filter(older, fn(row) { !row_msgid_known(current, row) })
      list.append(new_only, current)
    }
  }
}

/// Copy/union reactions from `live` onto the matching msgid row in `rows`.
/// Also prefer a live edit body when REST still has the pre-edit text.
fn union_reactions_into(
  rows: List(render.Row),
  live: render.Row,
) -> List(render.Row) {
  case live.msgid {
    None -> rows
    Some(mid) ->
      list.map(rows, fn(r) {
        case r.msgid {
          Some(id) if id == mid ->
            case r.deleted || live.deleted {
              // Soft-delete wins: never revive a deleted row from history merge.
              True ->
                case r.deleted {
                  True -> r
                  False -> render.mark_row_deleted(r)
                }
              False ->
                render.Row(
                  ..r,
                  text: case live.edited {
                    True -> live.text
                    False -> r.text
                  },
                  edited: r.edited || live.edited,
                  reactions: render.merge_reaction_dicts(
                    r.reactions,
                    live.reactions,
                  ),
                  // Keep a live-resolved embed if REST has none yet.
                  embed: case r.embed {
                    Some(e) -> Some(e)
                    None -> live.embed
                  },
                )
            }
          _ -> r
        }
      })
  }
}

/// Attach a fully resolved link preview onto a row by id or msgid.
fn patch_row_embed(
  messages: List(render.Row),
  row_id: String,
  embed: render.Embed,
) -> List(render.Row) {
  list.map(messages, fn(row) {
    case row.id == row_id || row.msgid == Some(row_id) {
      True -> render.Row(..row, embed: Some(embed))
      False -> row
    }
  })
}

/// Apply server-attached reaction tallies to a row already in the stream.
///
/// CHATHISTORY tallies are authoritative for that msgid — **replace**, do not
/// union (union would keep optimistic chips after a remote unreact).
fn hydrate_reactions(
  messages: List(render.Row),
  msgid: String,
  reactions: Dict(String, List(String)),
) -> List(render.Row) {
  list.map(messages, fn(row) {
    case row.msgid {
      Some(m) if m == msgid -> render.Row(..row, reactions: reactions)
      _ -> row
    }
  })
}

/// REST history as base, preserving any reaction tallies already on the model
/// (live TAGMSG / prior CHATHISTORY) for matching msgids.
pub fn apply_rest_history(
  model: Model,
  rest_rows: List(render.Row),
) -> Model {
  let merged = merge_history_rows(rest_rows, model.messages)
  Model(..model, messages: merged)
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

/// Drop compose-side reply/edit target + banner fields.
///
/// Clears `compose` only when leaving edit mode (reply cancel keeps the draft
/// in the client-owned input; the model draft is unused for replies).
fn clear_reply(model: Model) -> Model {
  let was_editing = case model.edit_to {
    Some(mid) if mid != "" -> True
    _ -> False
  }
  Model(
    ..model,
    reply_to: None,
    edit_to: None,
    reply_preview_nick: "",
    reply_preview_text: "",
    compose: case was_editing {
      True -> ""
      False -> model.compose
    },
  )
}

/// Close search modal and drop results (navigate / Esc).
fn clear_search(model: Model) -> Model {
  Model(
    ..model,
    search_open: False,
    search_query: "",
    search_results: [],
    search_loading: False,
    search_status: "",
  )
}

// scroll_to_msgid is intentionally preserved across clear_search so a
// search-hit jump can close the modal and still land on the target row.

/// Build a channel PRIVMSG, optionally tagged with reply or edit.
fn privmsg_line(
  channel: String,
  text: String,
  reply_to: Option(String),
  edit_to: Option(String),
) -> String {
  case edit_to, reply_to {
    Some(mid), _ if mid != "" ->
      "@+draft/edit="
      <> render.escape_tag_value(mid)
      <> " PRIVMSG "
      <> channel
      <> " :"
      <> text
      <> "\r\n"
    _, Some(mid) if mid != "" ->
      "@+reply="
      <> render.escape_tag_value(mid)
      <> " PRIVMSG "
      <> channel
      <> " :"
      <> text
      <> "\r\n"
    _, _ -> "PRIVMSG " <> channel <> " :" <> text <> "\r\n"
  }
}

/// Look up nick + body for a msgid (for the reply banner).
fn message_preview(
  rows: List(render.Row),
  msgid: String,
) -> #(String, String) {
  case
    list.find(rows, fn(r) {
      case r.msgid {
        Some(id) -> id == msgid
        None -> r.id == msgid
      }
    })
  {
    Ok(row) -> #(option.unwrap(row.nick, ""), row.text)
    Error(_) -> #("message", "")
  }
}
