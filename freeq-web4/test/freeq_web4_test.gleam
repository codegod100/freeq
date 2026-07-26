import envoy
import freeq_web4
import freeq_web4/atproto/dpop_key
import freeq_web4/atproto/oauth
import freeq_web4/atproto/oauth_session.{OAuthSession}
import freeq_web4/atproto/sasl
import freeq_web4/atproto/util as atutil
import freeq_web4/config
import freeq_web4/irc/render
import freeq_web4/link_preview
import freeq_web4/live
import freeq_web4/ls_form
import freeq_web4/rest
import freeq_web4/session_store
import freeq_web4/upload
import filepath
import gleam/bit_array
import gleam/crypto
import gleam/dict
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import lightspeed/diff
import lightspeed/form
import lightspeed/testing/liveview
import simplifile

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn canonical_channel_test() {
  assert render.canonical_channel("freeq") == "#freeq"
  assert render.canonical_channel("#freeq") == "#freeq"
  assert render.bare_channel("#freeq") == "freeq"
}

pub fn nick_color_stable_test() {
  let a = render.nick_color_class("alice")
  let b = render.nick_color_class("alice")
  assert a == b
  assert string.starts_with(a, "n")
}

pub fn parse_privmsg_test() {
  let line = ":alice!a@host PRIVMSG #freeq :hello world"
  let assert Some(row) = render.parse_message_line(line, Some("bob"))
  assert row.kind == render.Msg
  assert row.nick == Some("alice")
  assert row.text == "hello world"
  assert row.own == False
}

pub fn parse_ignores_protocol_noise_test() {
  assert render.parse_message_line(
      ":irc.freeq.at CAP * LS :sasl message-tags",
      None,
    )
    == None
  assert render.parse_message_line(":irc.freeq.at 001 web4_1 :Welcome", None)
    == None
  assert render.parse_message_line(
      ":irc.freeq.at BATCH +hist01 chathistory #test",
      None,
    )
    == None
  assert render.parse_message_line("CAP END", None) == None
}

pub fn parse_ignores_chathistory_batch_test() {
  let line = "@batch=hist01;msgid=01ABC :eve!e@h PRIVMSG #test :from history"
  assert render.parse_message_line(line, None) == None
  let live = ":eve!e@h PRIVMSG #test :live now"
  let assert Some(row) = render.parse_message_line(live, None)
  assert row.text == "live now"
}

pub fn parse_own_privmsg_test() {
  let line = ":bob!b@host PRIVMSG #freeq :hi"
  let assert Some(row) = render.parse_message_line(line, Some("bob"))
  assert row.own == True
}

pub fn parse_ping_test() {
  assert render.ping_token("PING :irc.freeq.at") == Some("irc.freeq.at")
  assert render.ping_token(":irc.freeq.at PING irc.freeq.at")
    == Some("irc.freeq.at")
  assert render.ping_token("PRIVMSG #c :x") == None
}

pub fn parse_tags_test() {
  let #(tags, rest) =
    render.parse_irc_tags("@msgid=abc;+reply=xyz :nick!u@h PRIVMSG #c :hi")
  assert rest == ":nick!u@h PRIVMSG #c :hi"
  assert tags != []
}

pub fn parse_reply_parent_test() {
  let line =
    "@msgid=child1;+reply=parent1 :bob!b@h PRIVMSG #freeq :this is a reply"
  let assert Some(row) = render.parse_message_line(line, None)
  assert row.parent == Some("parent1")
  assert row.msgid == Some("child1")
  assert row.text == "this is a reply"
}

pub fn history_row_test() {
  let row =
    render.history_row(
      "alice!a@h",
      "scrollback",
      Some("mid1"),
      Some(0),
      None,
      dict.new(),
    )
  assert row.kind == render.Msg
  assert row.nick == Some("alice")
  assert row.msgid == Some("mid1")
  assert row.text == "scrollback"
  assert row.parent == None
  assert row.reactions == dict.new()
  assert row.timestamp == Some(0)
  // Unix 0 = 1970-01-01 00:00 UTC → 12:00 AM
  assert row.time_label == "12:00\u{00A0}AM"
}

pub fn time_label_12h_test() {
  // 15:05 UTC → 3:05 PM
  assert render.time_label_from_unix(15 * 3600 + 5 * 60) == "3:05\u{00A0}PM"
  // midnight
  assert render.time_label_from_unix(0) == "12:00\u{00A0}AM"
  // noon
  assert render.time_label_from_unix(12 * 3600) == "12:00\u{00A0}PM"
  // 09:07 → no leading zero on hour
  assert render.time_label_from_unix(9 * 3600 + 7 * 60) == "9:07\u{00A0}AM"
}

pub fn parse_iso_unix_test() {
  // 2024-01-01T00:00:00.000Z
  assert render.parse_iso_unix("2024-01-01T00:00:00.000Z") == Some(1_704_067_200)
  assert render.parse_iso_unix("2024-01-01T00:00:00Z") == Some(1_704_067_200)
  assert render.parse_iso_unix("not-a-date") == None
}

pub fn parse_privmsg_with_server_time_test() {
  let line =
    "@time=2024-01-01T12:00:00.000Z;msgid=m1 :alice!a@h PRIVMSG #freeq :hi"
  let assert Some(row) = render.parse_message_line(line, None)
  assert row.timestamp == Some(1_704_110_400)
  assert row.time_label == "12:00\u{00A0}PM"
  assert row.msgid == Some("m1")
}

pub fn history_row_with_parent_test() {
  let row =
    render.history_row(
      "bob!b@h",
      "reply body",
      Some("child"),
      Some(0),
      Some("parent"),
      dict.new(),
    )
  assert row.parent == Some("parent")
  assert row.msgid == Some("child")
}

pub fn preview_text_test() {
  assert render.preview_text("  hello   world  ") == "hello world"
  assert string.length(render.preview_text(string.repeat("x", 100))) == 81
}

pub fn linkify_plain_text_test() {
  assert render.linkify_html("hello") == "hello"
  assert render.linkify_html("") == ""
  assert render.linkify_html("a <b> & \"c\"")
    == "a &lt;b&gt; &amp; &quot;c&quot;"
}

pub fn linkify_http_url_test() {
  let out = render.linkify_html("see https://example.com/x ok")
  assert string.contains(out, "href=\"https://example.com/x\"")
  assert string.contains(out, "target=\"_blank\"")
  assert string.contains(out, "rel=\"noopener noreferrer\"")
  assert string.starts_with(out, "see ")
  assert string.ends_with(out, " ok")
}

pub fn linkify_strips_trailing_punct_test() {
  let out = render.linkify_html("pic https://ex.com/i.png.")
  assert string.contains(out, "href=\"https://ex.com/i.png\"")
  assert string.ends_with(out, ".")
  assert string.contains(out, "class=\"link-embed file-embed\"")
  assert string.contains(out, "class=\"link-embed-img file-embed-img\"")
  assert string.contains(out, "class=\"link-embed-title\"")
  assert string.contains(out, ">i.png</div>")
  assert string.contains(out, ">ex.com</div>")
}

pub fn linkify_at_uri_test() {
  let uri =
    "at://did:plc:z72i7hdynmk6r22z27h6tvur/app.bsky.feed.post/3k2yihcrp6f2c"
  let out = render.linkify_html("see " <> uri <> " ok")
  assert string.contains(out, "href=\"https://atproto." <> uri <> "\"")
  assert string.contains(out, ">" <> uri <> "</a>")
  assert string.contains(out, "target=\"_blank\"")
  assert string.contains(out, "rel=\"noopener noreferrer\"")
  assert string.starts_with(out, "see ")
  assert string.ends_with(out, " ok")
}

pub fn linkify_at_uri_strips_trailing_punct_test() {
  let uri = "at://alice.bsky.social/app.bsky.feed.post/3abc"
  let out = render.linkify_html("ref " <> uri <> ".")
  assert string.contains(out, "href=\"https://atproto." <> uri <> "\"")
  assert string.ends_with(out, ".")
  assert !string.contains(out, uri <> ".</a>")
}

pub fn linkify_at_and_https_mixed_test() {
  let out =
    render.linkify_html(
      "a https://ex.com b at://did:plc:x/app.bsky.feed.post/y c",
    )
  assert string.contains(out, "href=\"https://ex.com\"")
  assert string.contains(
    out,
    "href=\"https://atproto.at://did:plc:x/app.bsky.feed.post/y\"",
  )
}

pub fn is_image_url_test() {
  assert render.is_image_url("https://cdn.example.com/photo.jpg")
  assert render.is_image_url("https://cdn.example.com/photo.JPEG?size=large")
  assert render.is_image_url("https://cdn.example.com/a.png#frag")
  assert render.is_image_url(
    "https://irc.freeq.at/api/v1/media/abc/SIG/photo.jpg",
  )
  assert render.is_image_url(
    "https://cdn.bsky.app/img/feed_fullsize/plain/did:plc:x/abc@jpeg",
  )
  assert !render.is_image_url("https://example.com/page")
  assert !render.is_image_url("https://example.com/video.mp4")
  // freeq media with video extension is not an image
  assert !render.is_image_url(
    "https://irc.freeq.at/api/v1/media/abc/SIG/clip.mp4",
  )
}

pub fn is_video_url_test() {
  assert render.is_video_url("https://cdn.example.com/clip.mp4")
  assert render.is_video_url("https://cdn.example.com/clip.MP4?token=1")
  assert render.is_video_url("https://cdn.example.com/a.webm#t=0")
  assert render.is_video_url("https://cdn.example.com/a.mov")
  assert render.is_video_url("https://cdn.example.com/a.m4v")
  assert render.is_video_url(
    "https://irc.freeq.at/api/v1/media/def/SIG/clip.mp4",
  )
  assert !render.is_video_url("https://example.com/page")
  assert !render.is_video_url("https://cdn.example.com/photo.jpg")
  assert !render.is_video_url("https://cdn.example.com/sound.mp3")
}

pub fn linkify_video_url_test() {
  let out = render.linkify_html("watch https://ex.com/clip.mp4 please")
  assert string.contains(out, "href=\"https://ex.com/clip.mp4\"")
  assert string.contains(out, "class=\"link-embed file-embed\"")
  assert string.contains(out, "<video class=\"link-embed-video\" src=\"https://ex.com/clip.mp4\"")
  assert string.contains(out, "controls")
  assert string.contains(out, "preload=\"metadata\"")
  assert string.contains(out, "playsinline")
  assert string.contains(out, "class=\"link-embed-title\"")
  assert string.contains(out, ">clip.mp4</div>")
  assert string.contains(out, ">ex.com</div>")
  assert string.starts_with(out, "watch ")
  assert string.ends_with(out, " please")
  // Video card is a div so controls stay clickable (not nested in <a>)
  assert string.contains(out, "<div class=\"link-embed file-embed\">")
  assert !string.contains(out, "class=\"msg-img\"")
  assert !string.contains(out, "<img ")
}

pub fn linkify_media_mp4_not_image_test() {
  let url = "https://irc.freeq.at/api/v1/media/abc/SIG/clip.mp4"
  let out = render.linkify_html(url)
  assert string.contains(out, "<video class=\"link-embed-video\" src=\"" <> url <> "\"")
  assert string.contains(out, "class=\"link-embed file-embed\"")
  assert string.contains(out, ">clip.mp4</div>")
  assert string.contains(out, ">irc.freeq.at</div>")
  assert !string.contains(out, "class=\"msg-img\"")
  assert !string.contains(out, "<img ")
}

pub fn upload_multipart_encode_test() {
  let body =
    upload.encode_multipart_for_test(
      bit_array.from_string("PNGDATA"),
      "shot.png",
      "image/png",
      "did:plc:test",
      "#freeq",
      "alt text",
      "BOUND",
    )
  let assert Ok(text) = bit_array.to_string(body)
  assert string.contains(text, "name=\"did\"")
  assert string.contains(text, "did:plc:test")
  assert string.contains(text, "name=\"channel\"")
  assert string.contains(text, "#freeq")
  assert string.contains(text, "name=\"alt\"")
  assert string.contains(text, "filename=\"shot.png\"")
  assert string.contains(text, "Content-Type: image/png")
  assert string.contains(text, "PNGDATA")
  assert string.contains(text, "--BOUND--")
}

pub fn compose_has_attach_controls_test() {
  let html = live.initial_html("/chat/freeq")
  assert string.contains(html, "id=\"attach-btn\"")
  assert string.contains(html, "id=\"file-input\"")
  assert string.contains(html, "id=\"upload-preview\"")
  assert string.contains(html, "paste images")
}

pub fn path_index_mount_test() {
  let model = live.mount_model("/chat")
  assert model.view == live.Index
  assert model.channel == None
}

pub fn path_channel_mount_test() {
  let model = live.mount_model("/chat/freeq")
  assert model.view == live.Channel
  assert model.channel == Some("#freeq")
  assert model.my_channels == ["#freeq"]
}

pub fn path_system_mount_test() {
  let model = live.mount_model("/chat/system")
  assert model.view == live.System
  assert model.channel == None
  assert model.my_channels == []
  assert model.system_messages == []
  assert live.path_for_model(model) == "/chat/system"
}

pub fn open_system_tab_test() {
  let model = live.mount_model("/chat/freeq")
  let #(sys, effect) = live.apply(model, live.OpenSystem)
  assert sys.view == live.System
  assert sys.channel == None
  assert effect == live.NoEffect
  // Opening via bare "system" (sidebar link) must not JOIN #system.
  let #(sys2, effect2) = live.apply(model, live.OpenChannel("system"))
  assert sys2.view == live.System
  assert effect2 == live.NoEffect
  let #(sys3, effect3) = live.apply(model, live.Join("system"))
  assert sys3.view == live.System
  assert effect3 == live.NoEffect
}

pub fn system_buffer_captures_notices_and_ws_test() {
  let model = live.mount_model("/chat/system")
  // Non-channel NOTICE → system buffer.
  let #(next, _) =
    live.apply(
      model,
      live.PushLine(":irc.freeq.at NOTICE guest :Welcome to freeq"),
    )
  assert list.length(next.system_messages) == 1
  let assert [row] = next.system_messages
  assert row.kind == render.Notice
  assert string.contains(row.text, "Welcome to freeq")
  // Ready/Disconnected transitions log a local system line.
  let #(ready, _) = live.apply(next, live.SetWs(live.WsReady))
  assert list.length(ready.system_messages) == 2
  let assert [_, status] = ready.system_messages
  assert status.kind == render.System
  assert status.text == "connected"
  // Sidebar shows System tab; messages region renders the buffer.
  let html = live.initial_html("/chat/system")
  assert string.contains(html, "System")
  assert string.contains(html, "href=\"/chat/system\"")
  assert string.contains(html, "id=\"system-channels\"")
  // Compose input present (slash commands).
  assert string.contains(html, "id=\"message-input\"")
  assert string.contains(html, "Type /join")
  assert string.contains(html, "data-ls-submit=\"send\"")
}

pub fn system_compose_slash_commands_test() {
  let model = live.mount_model("/chat/system")

  // /join navigates + ensures upstream (not raw "join …").
  let #(joined, effect) = live.apply(model, live.Send("/join #dev"))
  assert joined.view == live.Channel
  assert joined.channel == Some("#dev")
  assert list.any(joined.system_messages, fn(r) {
    string.contains(r.text, "/join #dev")
  })
  case effect {
    live.EnsureUpstream("#dev", _) -> Nil
    _ -> panic as "expected EnsureUpstream for /join"
  }

  // /op nick #chan → MODE (works from System without a current channel).
  let #(opped, effect2) = live.apply(model, live.Send("/op eve #test"))
  assert opped.view == live.System
  let line = case effect2 {
    live.IrcSend([line]) -> line
    _ -> panic as "expected MODE from /op"
  }
  assert line == "MODE #test +o eve\r\n"

  // /op without a channel → usage help, no wire send.
  let #(bad, effect3) = live.apply(model, live.Send("/op eve"))
  assert effect3 == live.NoEffect
  assert list.any(bad.system_messages, fn(r) { string.contains(r.text, "Usage") })

  // /help is local.
  let #(helped, effect4) = live.apply(model, live.Send("/help"))
  assert effect4 == live.NoEffect
  assert list.any(helped.system_messages, fn(r) {
    string.contains(r.text, "/whois")
  })

  // /whois → WHOIS
  let #(_, effect5) = live.apply(model, live.Send("/whois alice"))
  let whois = case effect5 {
    live.IrcSend([line]) -> line
    _ -> panic as "expected WHOIS"
  }
  assert whois == "WHOIS alice\r\n"

  // Plain text without slash is rejected on System.
  let #(plain, effect6) = live.apply(model, live.Send("hello"))
  assert effect6 == live.NoEffect
  assert string.contains(plain.flash, "/commands")
}

pub fn system_buffer_shows_error_numerics_test() {
  let model = live.mount_model("/chat/system")
  let #(next, _) =
    live.apply(
      model,
      live.PushLine(
        ":irc.freeq.at 421 guest OP :Unknown command",
      ),
    )
  assert list.any(next.system_messages, fn(r) {
    string.contains(r.text, "421") && string.contains(r.text, "Unknown command")
  })
  // NAMES noise stays out of the System buffer.
  let #(quiet, _) =
    live.apply(
      model,
      live.PushLine(":irc.freeq.at 353 guest = #test :@alice bob"),
    )
  assert quiet.system_messages == []
}

pub fn parse_system_status_line_test() {
  assert render.parse_system_status_line(
      ":irc.freeq.at 421 guest OP :Unknown command",
    )
    == Some("irc.freeq.at 421 OP — Unknown command")
  assert render.parse_system_status_line(
      ":irc.freeq.at 482 guest #test :You're not channel operator",
    )
    == Some("irc.freeq.at 482 #test — You're not channel operator")
  assert render.parse_system_status_line(
      ":irc.freeq.at 353 guest = #test :@alice",
    )
    == None
  assert render.parse_system_status_line("ERROR :Closing Link")
    == Some("ERROR Closing Link")
}

pub fn merge_my_channels_test() {
  assert live.merge_my_channels(["#freeq"], ["#dev", "#freeq", "#test"])
    == ["#freeq", "#dev", "#test"]
  assert live.merge_my_channels([], ["#a", "#b"]) == ["#a", "#b"]
  assert live.merge_my_channels(["#only"], []) == ["#only"]
  // Never treat the local System key as a joined IRC channel.
  assert live.merge_my_channels(["#freeq"], ["system", "#system", "#dev"])
    == ["#freeq", "#dev"]
}

pub fn with_my_channels_test() {
  let model = live.mount_model("/chat")
  let restored = live.with_my_channels(model, ["#dev", "#test"])
  assert restored.my_channels == ["#dev", "#test"]
  assert restored.view == live.Index
}

pub fn message_target_channel_test() {
  assert render.message_target_channel(":alice!a@h PRIVMSG #freeq :hi")
    == Some("#freeq")
  assert render.message_target_channel(
      "@msgid=1 :bob!b@h PRIVMSG #dev :hello",
    )
    == Some("#dev")
  assert render.message_target_channel(":alice!a@h NOTICE #ops :mod")
    == Some("#ops")
  assert render.message_target_channel(":alice!a@h PRIVMSG bob :dm") == None
  assert render.message_target_channel(":alice!a@h JOIN #freeq") == None
}

pub fn unread_bumps_for_other_channel_test() {
  let model =
    live.mount_model("/chat/freeq")
    |> live.with_my_channels(["#freeq", "#dev"])
  assert live.unread_count(model, "#dev") == 0
  let line = "@msgid=u1 :alice!a@h PRIVMSG #dev :ping"
  let #(next, _) = live.apply(model, live.PushLine(line))
  // Not viewing #dev → no stream pollution, badge increments.
  assert next.messages == model.messages
  assert live.unread_count(next, "#dev") == 1
  let #(next2, _) =
    live.apply(next, live.PushLine("@msgid=u2 :bob!b@h PRIVMSG #dev :again"))
  assert live.unread_count(next2, "#dev") == 2
  // Active channel traffic does not bump.
  let #(same, _) =
    live.apply(
      next2,
      live.PushLine("@msgid=u3 :carol!c@h PRIVMSG #freeq :here"),
    )
  assert live.unread_count(same, "#freeq") == 0
  assert list.any(same.messages, fn(r) { r.msgid == Some("u3") })
}

pub fn unread_skips_own_and_unjoined_test() {
  let model =
    live.mount_model("/chat/freeq")
    |> live.with_my_channels(["#freeq", "#dev"])
  // Own echo on another channel.
  let model = live.apply(model, live.SetNick("guest")).0
  let #(next, _) =
    live.apply(model, live.PushLine(":guest!g@h PRIVMSG #dev :mine"))
  assert live.unread_count(next, "#dev") == 0
  // Message for a channel we are not tracking.
  let #(next2, _) =
    live.apply(next, live.PushLine(":alice!a@h PRIVMSG #other :x"))
  assert live.unread_count(next2, "#other") == 0
}

pub fn unread_clears_on_open_test() {
  let model =
    live.mount_model("/chat/freeq")
    |> live.with_my_channels(["#freeq", "#dev"])
  let #(model, _) =
    live.apply(model, live.PushLine(":alice!a@h PRIVMSG #dev :one"))
  let #(model, _) =
    live.apply(model, live.PushLine(":alice!a@h PRIVMSG #dev :two"))
  assert live.unread_count(model, "#dev") == 2
  let #(opened, _) = live.apply(model, live.OpenChannel("dev"))
  assert opened.channel == Some("#dev")
  assert live.unread_count(opened, "#dev") == 0
}

pub fn unread_clears_on_part_test() {
  let model =
    live.mount_model("/chat/freeq")
    |> live.with_my_channels(["#freeq", "#dev"])
  let #(model, _) =
    live.apply(model, live.PushLine(":alice!a@h PRIVMSG #dev :x"))
  assert live.unread_count(model, "#dev") == 1
  let #(parted, _) = live.apply(model, live.Part("dev"))
  assert live.unread_count(parted, "#dev") == 0
  assert !list.contains(parted.my_channels, "#dev")
}

pub fn sidebar_shows_unread_badge_test() {
  let before =
    live.mount_model("/chat/freeq")
    |> live.with_my_channels(["#freeq", "#dev"])
  let #(after, _) =
    live.apply(before, live.PushLine(":alice!a@h PRIVMSG #dev :hello"))
  assert live.unread_count(after, "#dev") == 1
  let patches = live.plan_patches(before, after)
  let assert Ok(side) =
    list.find_map(patches, fn(p) {
      case p {
        diff.Replace(html:, ..) ->
          case string.contains(html, "channel-unread") {
            True -> Ok(html)
            False -> Error(Nil)
          }
        _ -> Error(Nil)
      }
    })
  assert string.contains(side, "has-unread")
  assert string.contains(side, "1 unread")
}

pub fn with_api_bearer_test() {
  let model = live.mount_model("/chat/freeq")
  assert model.api_bearer == None
  assert model.authenticated == False
  let restored = live.with_api_bearer(model, Some("tok-abc"))
  // Bearer restored for REST; SASL still owns `authenticated`.
  assert restored.api_bearer == Some("tok-abc")
  assert restored.authenticated == False
}

pub fn merge_history_rows_test() {
  let rest = [
    render.history_row("alice!a@h", "a", Some("m1"), Some(1), None, dict.new()),
    render.history_row("bob!b@h", "b", Some("m2"), Some(2), None, dict.new()),
  ]
  let live_only = [
    render.history_row("bob!b@h", "b", Some("m2"), Some(2), None, dict.new()),
    render.history_row("carol!c@h", "c", Some("m3"), Some(3), None, dict.new()),
  ]
  let merged = live.merge_history_rows(rest, live_only)
  assert list.length(merged) == 3
  assert list.map(merged, fn(r) { r.msgid })
    == [Some("m1"), Some("m2"), Some("m3")]
  // Empty REST must not clobber live rows (failed private-channel fetch).
  assert live.merge_history_rows([], live_only) == live_only
  assert live.merge_history_rows(rest, []) == rest
}

pub fn session_channels_persist_test() {
  // Isolate disk under a temp-ish dir so we don't touch real sessions.
  let dir = ".dev-data/web4-test-sessions-" <> atutil.random_b64url(6)
  let _ = envoy.set("FREEQ_WEB4_SESSIONS_DIR", dir)
  let sid = "test-sid-" <> atutil.random_b64url(8)
  assert session_store.load_channels(sid) == []
  session_store.save_channels(sid, ["#freeq", "dev", "#freeq", ""])
  assert session_store.load_channels(sid) == ["#freeq", "#dev"]
  session_store.remove(sid)
  assert session_store.load_channels(sid) == []
  let _ = simplifile.delete(dir)
}

pub fn path_for_model_test() {
  let index = live.mount_model("/chat")
  assert live.path_for_model(index) == "/chat"
  assert live.channel_path("#freeq") == "/chat/freeq"
  assert live.channel_path("dev") == "/chat/dev"
  assert live.system_path() == "/chat/system"
  let channel = live.mount_model("/chat/freeq")
  assert live.path_for_model(channel) == "/chat/freeq"
  let #(opened, _) = live.apply(index, live.OpenChannel("dev"))
  assert live.path_for_model(opened) == "/chat/dev"
  let #(back, _) = live.apply(opened, live.GoIndex)
  assert live.path_for_model(back) == "/chat"
  let #(sys, _) = live.apply(index, live.OpenSystem)
  assert live.path_for_model(sys) == "/chat/system"
}

pub fn join_effect_test() {
  let model = live.mount_model("/chat")
  let #(next, effect) = live.apply(model, live.Join("dev"))
  assert next.view == live.Channel
  assert next.channel == Some("#dev")
  let primary = case effect {
    live.EnsureUpstream(primary, _) -> primary
    _ -> panic as "expected EnsureUpstream"
  }
  assert primary == "#dev"
}

pub fn send_builds_privmsg_test() {
  let model = live.mount_model("/chat/freeq")
  let #(next, effect) = live.apply(model, live.Send("hello"))
  assert next.compose == ""
  let line = case effect {
    live.IrcSend([line]) -> line
    _ -> panic as "expected IrcSend"
  }
  assert string.contains(line, "PRIVMSG #freeq :hello")
}

pub fn start_reply_sets_banner_test() {
  let model = live.mount_model("/chat/freeq")
  let row =
    render.history_row(
      "alice!a@h",
      "original body",
      Some("parent1"),
      Some(0),
      None,
      dict.new(),
    )
  let model = live.apply(model, live.SetHistory([row])).0
  let #(next, _) = live.apply(model, live.StartReply("parent1"))
  assert next.reply_to == Some("parent1")
  assert next.reply_preview_nick == "alice"
  assert next.reply_preview_text == "original body"
}

pub fn cancel_reply_clears_test() {
  let model = live.mount_model("/chat/freeq")
  let model = live.apply(model, live.StartReply("mid-x")).0
  assert model.reply_to == Some("mid-x")
  let #(next, _) = live.apply(model, live.CancelReply)
  assert next.reply_to == None
  assert next.reply_preview_nick == ""
  assert next.reply_preview_text == ""
}

pub fn send_reply_builds_tagged_privmsg_test() {
  let model = live.mount_model("/chat/freeq")
  let row =
    render.history_row(
      "alice!a@h",
      "hi",
      Some("parent1"),
      Some(0),
      None,
      dict.new(),
    )
  let model = live.apply(model, live.SetHistory([row])).0
  let model = live.apply(model, live.StartReply("parent1")).0
  let #(next, effect) = live.apply(model, live.Send("this is a reply"))
  let assert live.IrcSend([line]) = effect
  assert string.contains(line, "@+reply=parent1")
  assert string.contains(line, "PRIVMSG #freeq :this is a reply")
  // Reply mode clears after send.
  assert next.reply_to == None
  assert next.reply_preview_nick == ""
}

pub fn start_edit_sets_banner_test() {
  let model = live.mount_model("/chat/freeq")
  let row =
    render.history_row(
      "guest!g@h",
      "typo message",
      Some("editme"),
      Some(0),
      None,
      dict.new(),
    )
  let model = live.apply(model, live.SetHistory([row])).0
  let #(next, _) = live.apply(model, live.StartEdit("editme"))
  assert next.edit_to == Some("editme")
  assert next.reply_to == None
  assert next.compose == "typo message"
  assert next.reply_preview_text == "typo message"
}

pub fn send_edit_builds_draft_edit_privmsg_test() {
  let model = live.mount_model("/chat/freeq")
  let row =
    render.history_row(
      "guest!g@h",
      "old text",
      Some("m-edit"),
      Some(0),
      None,
      dict.new(),
    )
  let model = live.apply(model, live.SetHistory([row])).0
  let model = live.apply(model, live.StartEdit("m-edit")).0
  let #(next, effect) = live.apply(model, live.Send("fixed text"))
  let assert live.IrcSend([line]) = effect
  assert string.contains(line, "@+draft/edit=m-edit")
  assert string.contains(line, "PRIVMSG #freeq :fixed text")
  assert !string.contains(line, "+reply=")
  assert next.edit_to == None
  assert next.compose == ""
}

pub fn cancel_edit_clears_test() {
  let model = live.mount_model("/chat/freeq")
  let model = live.apply(model, live.StartEdit("mid-x")).0
  assert model.edit_to == Some("mid-x")
  let #(next, _) = live.apply(model, live.CancelReply)
  assert next.edit_to == None
  assert next.compose == ""
}

pub fn parse_draft_edit_keeps_original_msgid_test() {
  let line =
    "@msgid=new1;+draft/edit=orig1 :alice!a@h PRIVMSG #freeq :fixed typo"
  let assert Some(row) = render.parse_message_line(line, Some("bob"))
  assert row.msgid == Some("orig1")
  assert row.text == "fixed typo"
  assert row.edited == True
}

pub fn live_edit_updates_existing_row_test() {
  let model = live.mount_model("/chat/freeq")
  let model = live.apply(model, live.SetNick("alice")).0
  let orig =
    "@msgid=orig1 :alice!a@h PRIVMSG #freeq :first draft"
  let model = live.apply(model, live.PushLine(orig)).0
  assert list.length(model.messages) == 1
  let edit =
    "@msgid=edit1;+draft/edit=orig1 :alice!a@h PRIVMSG #freeq :second draft"
  let next = live.apply(model, live.PushLine(edit)).0
  // Still one row; text replaced in place.
  assert list.length(next.messages) == 1
  let assert Ok(row) = list.first(next.messages)
  assert row.msgid == Some("orig1")
  assert row.text == "second draft"
  assert row.edited == True
}

pub fn collapse_history_edits_test() {
  let orig =
    render.history_row(
      "alice!a@h",
      "v1",
      Some("m0"),
      Some(1),
      None,
      dict.new(),
    )
  let edit =
    render.history_row(
      "alice!a@h",
      "v2",
      Some("e1"),
      Some(2),
      None,
      dict.new(),
    )
  let collapsed =
    render.collapse_history_edits([#(orig, None), #(edit, Some("m0"))])
  assert list.length(collapsed) == 1
  let assert Ok(row) = list.first(collapsed)
  assert row.msgid == Some("m0")
  assert row.text == "v2"
  assert row.edited == True
}

pub fn channel_shell_has_edit_controls_for_own_test() {
  let model = live.mount_model("/chat/freeq")
  let model = live.apply(model, live.SetNick("alice")).0
  let row =
    render.Row(
      ..render.history_row(
        "alice!a@h",
        "mine",
        Some("own1"),
        Some(0),
        None,
        dict.new(),
      ),
      own: True,
    )
  let model = live.apply(model, live.SetHistory([row])).0
  let html = live.messages_region_for_test(model)
  assert string.contains(html, "data-ls-click=\"edit\"")
  assert string.contains(html, "class=\"edit-btn\"")
  // Delete is on the edit banner, not a per-message hover icon.
  assert !string.contains(html, "class=\"delete-btn\"")
}

pub fn edit_banner_has_delete_control_test() {
  let model = live.mount_model("/chat/freeq")
  let row =
    render.history_row(
      "guest!g@h",
      "typo",
      Some("m-del"),
      Some(0),
      None,
      dict.new(),
    )
  let model = live.apply(model, live.SetHistory([row])).0
  let model = live.apply(model, live.StartEdit("m-del")).0
  assert model.edit_to == Some("m-del")
  let html = live.compose_region_for_test(model)
  assert string.contains(html, "id=\"reply-banner\"")
  assert string.contains(html, "data-mode=\"edit\"")
  assert string.contains(html, "data-ls-click=\"delete\"")
  assert string.contains(html, "class=\"reply-banner-delete\"")
  assert string.contains(html, "msgid=m-del")
  assert string.contains(html, "Delete")
}

pub fn delete_line_test() {
  let line = render.delete_line("#freeq", "msg99")
  assert string.contains(line, "@+draft/delete=msg99")
  assert string.contains(line, "TAGMSG #freeq")
}

pub fn parse_tagmsg_delete_test() {
  let line = "@+draft/delete=orig1 :alice!a@h TAGMSG #freeq"
  let assert Some(#(mid, nick, ch)) = render.parse_tagmsg_delete(line)
  assert mid == "orig1"
  assert nick == "alice"
  assert ch == "#freeq"
}

pub fn delete_message_sends_tagmsg_test() {
  let model = live.mount_model("/chat/freeq")
  let model = live.apply(model, live.SetNick("alice")).0
  let row =
    render.Row(
      ..render.history_row(
        "alice!a@h",
        "bye",
        Some("del1"),
        Some(0),
        None,
        dict.new(),
      ),
      own: True,
    )
  let model = live.apply(model, live.SetHistory([row])).0
  let #(next, effect) = live.apply(model, live.DeleteMessage("del1"))
  let assert live.IrcSend([line]) = effect
  assert string.contains(line, "+draft/delete=del1")
  assert string.contains(line, "TAGMSG #freeq")
  let assert Ok(row) = list.first(next.messages)
  assert row.deleted == True
  assert string.contains(
    live.messages_region_for_test(next),
    "Message from alice deleted",
  )
}

pub fn live_delete_tagmsg_marks_row_test() {
  let model = live.mount_model("/chat/freeq")
  let model = live.apply(model, live.SetNick("alice")).0
  let orig = "@msgid=orig1 :alice!a@h PRIVMSG #freeq :secret"
  let model = live.apply(model, live.PushLine(orig)).0
  let del = "@+draft/delete=orig1 :alice!a@h TAGMSG #freeq"
  let next = live.apply(model, live.PushLine(del)).0
  assert list.length(next.messages) == 1
  let assert Ok(row) = list.first(next.messages)
  assert row.deleted == True
  assert row.msgid == Some("orig1")
}

pub fn edit_after_delete_stays_deleted_test() {
  let model = live.mount_model("/chat/freeq")
  let model = live.apply(model, live.SetNick("alice")).0
  let orig = "@msgid=orig1 :alice!a@h PRIVMSG #freeq :secret"
  let model = live.apply(model, live.PushLine(orig)).0
  let model =
    live.apply(
      model,
      live.PushLine("@+draft/delete=orig1 :alice!a@h TAGMSG #freeq"),
    ).0
  let next =
    live.apply(
      model,
      live.PushLine(
        "@msgid=e1;+draft/edit=orig1 :alice!a@h PRIVMSG #freeq :revived",
      ),
    ).0
  let assert Ok(row) = list.first(next.messages)
  assert row.deleted == True
  assert row.text == ""
}

pub fn delete_cancels_edit_compose_test() {
  let model = live.mount_model("/chat/freeq")
  let row =
    render.history_row(
      "guest!g@h",
      "oops",
      Some("m1"),
      Some(0),
      None,
      dict.new(),
    )
  let model = live.apply(model, live.SetHistory([row])).0
  let model = live.apply(model, live.StartEdit("m1")).0
  assert model.edit_to == Some("m1")
  let next = live.apply(model, live.DeleteMessage("m1")).0
  assert next.edit_to == None
  let assert Ok(r) = list.first(next.messages)
  assert r.deleted == True
}

pub fn open_channel_clears_reply_test() {
  let model = live.mount_model("/chat/freeq")
  let model = live.apply(model, live.StartReply("mid1")).0
  assert model.reply_to == Some("mid1")
  let #(next, _) = live.apply(model, live.OpenChannel("dev"))
  assert next.reply_to == None
  assert next.channel == Some("#dev")
}

pub fn channel_shell_has_reply_controls_test() {
  let html = live.initial_html("/chat/freeq")
  // Compose stack is present; reply banner appears only when replying.
  assert string.contains(html, "data-ls-region=\"compose\"")
  assert !string.contains(html, "id=\"reply-banner\"")
}

pub fn decode_channels_null_topic_test() {
  // freeq-server emits topic:null for unset topics; must not drop the list.
  let body =
    "[{\"name\":\"#general\",\"members\":7,\"topic\":\"hi\"},"
    <> "{\"name\":\"#freeqpilot\",\"members\":4,\"topic\":null},"
    <> "{\"name\":\"#dev\",\"members\":5}]"
  let channels = rest.parse_channels_json(body)
  assert list.length(channels) == 3
  let assert Ok(first) = list.first(channels)
  assert first.name == "#general"
  assert first.topic == "hi"
  let pilot = list.find(channels, fn(c) { c.name == "#freeqpilot" })
  let assert Ok(pilot) = pilot
  assert pilot.topic == ""
  assert pilot.members == 4
}

pub fn topic_for_directory_test() {
  let all = [
    rest.ChannelInfo(name: "#test", topic: "6789", members: 10),
    rest.ChannelInfo(name: "#general", topic: "General", members: 3),
  ]
  assert rest.topic_for(all, "#test") == "6789"
  assert rest.topic_for(all, "test") == "6789"
  // Private rooms are omitted from the public list.
  assert rest.topic_for(all, "#freeq") == ""
}

pub fn parse_topic_332_test() {
  let assert Some(#(ch, topic)) =
    render.parse_topic(":irc.freeq.at 332 guest #test :6789")
  assert ch == "#test"
  assert topic == "6789"

  let assert Some(#(ch2, topic2)) =
    render.parse_topic(
      ":irc.freeq.at 332 guest #freeq :Welcome to freeq — decentralized chat",
    )
  assert ch2 == "#freeq"
  assert string.contains(topic2, "Welcome to freeq")

  let assert Some(#(ch3, topic3)) =
    render.parse_topic(":alice!a@h TOPIC #test :new topic here")
  assert ch3 == "#test"
  assert topic3 == "new topic here"
}

pub fn open_channel_seeds_topic_from_directory_test() {
  let model = live.mount_model("/chat")
  let #(model, _) =
    live.apply(
      model,
      live.SetAllChannels([
        rest.ChannelInfo(name: "#test", topic: "6789", members: 10),
      ]),
    )
  let #(opened, _) = live.apply(model, live.OpenChannel("test"))
  assert opened.channel == Some("#test")
  assert opened.topic == "6789"

  // Unknown / private channel: empty until host REST resolve_topic runs.
  let #(freeq, _) = live.apply(model, live.OpenChannel("freeq"))
  assert freeq.channel == Some("#freeq")
  assert freeq.topic == ""
}

pub fn topic_edit_op_only_test() {
  let model = live.mount_model("/chat/test")
  let model =
    live.Model(
      ..model,
      nick: "alice",
      topic: "old",
      members: [
        render.Member(
          nick: "alice",
          op: False,
          halfop: False,
          voice: False,
          color: "n1",
        ),
      ],
    )
  let #(plain, effect) = live.apply(model, live.EditTopic)
  assert plain.editing_topic == False
  assert effect == live.NoEffect

  let model =
    live.Model(
      ..model,
      members: [
        render.Member(
          nick: "alice",
          op: True,
          halfop: False,
          voice: False,
          color: "n1",
        ),
      ],
    )
  let #(editing, _) = live.apply(model, live.EditTopic)
  assert editing.editing_topic == True

  let #(saved, send) = live.apply(editing, live.SetTopic("  new topic  "))
  assert saved.topic == "new topic"
  assert saved.editing_topic == False
  let assert live.IrcSend([line]) = send
  assert line == "TOPIC #test :new topic\r\n"

  let #(halfop_model, _) =
    live.apply(
      live.Model(
        ..model,
        members: [
          render.Member(
            nick: "alice",
            op: False,
            halfop: True,
            voice: False,
            color: "n1",
          ),
        ],
      ),
      live.EditTopic,
    )
  assert halfop_model.editing_topic == True

  let #(cancelled, _) = live.apply(halfop_model, live.CancelTopicEdit)
  assert cancelled.editing_topic == False
  assert cancelled.topic == "old"
}

pub fn topic_edit_route_and_nav_test() {
  let assert Ok(live.EditTopic) = live.decode_event("edit_topic", "")
  let assert Ok(live.CancelTopicEdit) =
    live.decode_event("cancel_topic_edit", "")
  let assert Ok(live.SetTopic("hello")) =
    live.decode_event("set_topic", "topic=hello")

  let html = live.initial_html("/chat/test")
  assert string.contains(html, "channel-topic")
  assert string.contains(html, "id=\"channel-topic\"")

  // Op member: patches include the topic form when edit opens.
  let model = live.mount_model("/chat/test")
  let before =
    live.Model(
      ..model,
      nick: "op",
      topic: "hello",
      members: [
        render.Member(
          nick: "op",
          op: True,
          halfop: False,
          voice: False,
          color: "n1",
        ),
      ],
    )
  let #(after, _) = live.apply(before, live.EditTopic)
  let patches = live.plan_patches(before, after)
  let htmls =
    list.map(patches, fn(p) {
      case p {
        diff.Replace(_, html) -> html
        _ -> ""
      }
    })
    |> string.concat
  assert string.contains(htmls, "topic-form")
  assert string.contains(htmls, "topic-input")
  assert string.contains(htmls, "data-ls-submit=\"set_topic\"")
  // Form replaces the clickable span while editing.
  assert !string.contains(htmls, "data-ls-click=\"edit_topic\"")
}

pub fn mount_renders_shell_test() {
  let html = live.initial_html("/chat")
  assert string.contains(html, "freeq")
  assert string.contains(html, "data-ls-region")
  assert string.contains(html, "MY CHANNELS")
  // Directory + channel nav use real hrefs so the bar can patch like web3.
  assert string.contains(html, "href=\"/chat\"")
}

pub fn channel_shell_renders_href_test() {
  let html = live.initial_html("/chat/freeq")
  assert string.contains(html, "href=\"/chat/freeq\"")
  assert string.contains(html, "data-ls-click=\"open\"")
}

pub fn liveview_join_event_test() {
  let session =
    liveview.mount_connected(
      live.definition(),
      "freeq-root",
      "/chat",
      live.Assigns(path: "/chat"),
      live.target,
    )
  let #(session, routed) =
    liveview.render_event(session, "join", "channel=test")
  assert routed == Ok(live.Join("test"))
  let html = liveview.html(session)
  assert string.contains(html, "#test") || string.contains(html, "test")
}

pub fn sanitize_nick_test() {
  assert render.sanitize_nick("alice.bsky.social") == "alice.bsky.social"
  assert render.sanitize_nick("123starts") == "u123starts"
  assert string.length(render.sanitize_nick("a.very.long.handle.example.com"))
    <= 20
}

pub fn dpop_key_roundtrip_test() {
  let key = dpop_key.generate()
  let ser = dpop_key.serialize(key)
  let assert Ok(key2) = dpop_key.deserialize(ser)
  assert key2.private_key == key.private_key
  assert key2.public_key == key.public_key
}

pub fn dpop_proof_shape_test() {
  let key = dpop_key.generate()
  let proof =
    dpop_key.proof(key, "POST", "https://example.com/token", None, None)
  let parts = string.split(proof, ".")
  assert list.length(parts) == 3
  let assert [header_b64, ..] = parts
  let assert Ok(header_bits) = bit_array.base64_url_decode(header_b64)
  let assert Ok(header_json) = bit_array.to_string(header_bits)
  assert string.contains(header_json, "dpop+jwt")
  assert string.contains(header_json, "EdDSA")
}

pub fn dpop_proof_with_ath_and_nonce_test() {
  let key = dpop_key.generate()
  let proof =
    dpop_key.proof(
      key,
      "GET",
      "https://pds.example/xrpc/foo",
      Some("abc123"),
      Some("tok"),
    )
  let parts = string.split(proof, ".")
  let assert [_, payload_b64, _] = parts
  let assert Ok(payload_bits) = bit_array.base64_url_decode(payload_b64)
  let assert Ok(payload_json) = bit_array.to_string(payload_bits)
  assert string.contains(payload_json, "\"nonce\"")
  assert string.contains(payload_json, "abc123")
  assert string.contains(payload_json, "\"ath\"")
}

pub fn sasl_parse_challenge_test() {
  let payload =
    json.object([
      #("session_id", json.string("sid-1")),
      #("nonce", json.string("n-abc")),
      #("timestamp", json.int(1_700_000_000)),
    ])
    |> json.to_string
    |> bit_array.from_string
    |> bit_array.base64_url_encode(False)
  let assert Ok(ch) = sasl.parse_challenge(payload)
  assert ch.session_id == "sid-1"
  assert ch.nonce == "n-abc"
  assert ch.timestamp == 1_700_000_000
}

pub fn sasl_build_response_test() {
  let oauth =
    OAuthSession(
      did: "did:plc:test",
      handle: "alice.bsky.social",
      access_token: "access-tok",
      pds_url: "https://pds.example",
      dpop_key: dpop_key.generate(),
      dpop_nonce: Some("nonce-1"),
      refresh_token: None,
      token_endpoint: None,
      client_id: None,
    )
  let resp = sasl.build_response("challenge-nonce", oauth)
  let assert Ok(json_bits) = bit_array.base64_url_decode(resp)
  let assert Ok(json_str) = bit_array.to_string(json_bits)
  assert string.contains(json_str, "did:plc:test")
  assert string.contains(json_str, "pds-oauth")
  assert string.contains(json_str, "challenge-nonce")
  assert string.contains(json_str, "access-tok")
}

pub fn access_still_fresh_jwt_test() {
  let exp = atutil.unix_seconds() + 3600
  let payload =
    json.object([#("exp", json.int(exp)), #("sub", json.string("did:plc:x"))])
    |> json.to_string
    |> bit_array.from_string
    |> bit_array.base64_url_encode(False)
  let token = "eyJhbGciOiJub25lIn0." <> payload <> ".sig"
  let sess =
    OAuthSession(
      did: "did:plc:x",
      handle: "x.test",
      access_token: token,
      pds_url: "https://pds.example",
      dpop_key: dpop_key.generate(),
      dpop_nonce: None,
      refresh_token: Some("rt"),
      token_endpoint: Some("https://as.example/token"),
      client_id: Some("cid"),
    )
  assert oauth.access_still_fresh(sess, 120) == True
  assert oauth.is_invalid_grant(
    "OAuth refresh failed (400): {\"error\":\"invalid_grant\"}",
  )
  let expired_payload =
    json.object([#("exp", json.int(atutil.unix_seconds() - 10))])
    |> json.to_string
    |> bit_array.from_string
    |> bit_array.base64_url_encode(False)
  let expired =
    OAuthSession(
      ..sess,
      access_token: "hdr." <> expired_payload <> ".sig",
    )
  assert oauth.access_still_fresh(expired, 120) == False
}

pub fn set_auth_msg_test() {
  let model = live.mount_model("/chat")
  let #(next, _) =
    live.apply(
      model,
      live.SetAuth(
        authenticated: True,
        handle: "alice.bsky.social",
        did: "did:plc:alice",
      ),
    )
  assert next.authenticated == True
  assert next.auth_handle == "alice.bsky.social"
  assert next.auth_did == "did:plc:alice"
  let html = live.initial_html("/chat")
  // SSR shell is guest until LiveView applies auth.
  assert string.contains(html, "Sign in") || string.contains(html, "guest")
}

pub fn parse_353_members_test() {
  let line = ":irc.freeq.at 353 me = #freeq :@alice +bob carol"
  let members = render.parse_353_members(line)
  assert list.length(members) == 3
  let assert Ok(alice) = list.find(members, fn(m) { m.nick == "alice" })
  assert alice.op == True
  assert alice.voice == False
  let assert Ok(bob) = list.find(members, fn(m) { m.nick == "bob" })
  assert bob.voice == True
  assert bob.op == False
  let assert Ok(carol) = list.find(members, fn(m) { m.nick == "carol" })
  assert carol.op == False
  assert carol.voice == False
}

pub fn parse_353_multiprefix_and_halfop_test() {
  let line = ":irc.freeq.at 353 me = #dev :@+alice %bob ~carol"
  let members = render.parse_353_members(line)
  let assert Ok(alice) = list.find(members, fn(m) { m.nick == "alice" })
  assert alice.op == True
  assert alice.voice == True
  let assert Ok(bob) = list.find(members, fn(m) { m.nick == "bob" })
  assert bob.halfop == True
  assert bob.op == False
  let assert Ok(carol) = list.find(members, fn(m) { m.nick == "carol" })
  assert carol.op == True
  assert render.channel_from_353(line) == Some("#dev")
}

pub fn sort_members_rank_test() {
  let members = [
    render.Member(
      nick: "zzz",
      op: False,
      halfop: False,
      voice: False,
      color: "n1",
    ),
    render.Member(
      nick: "alice",
      op: True,
      halfop: False,
      voice: False,
      color: "n1",
    ),
    render.Member(
      nick: "bob",
      op: False,
      halfop: False,
      voice: True,
      color: "n1",
    ),
    render.Member(
      nick: "half",
      op: False,
      halfop: True,
      voice: False,
      color: "n1",
    ),
  ]
  let sorted = render.sort_members(members)
  assert list.map(sorted, fn(m) { m.nick }) == ["alice", "half", "bob", "zzz"]
}

pub fn parse_mode_change_test() {
  let line = ":op!u@h MODE #freeq +ov alice bob"
  let assert Some(#(ch, from, modestring, args, ops)) =
    render.parse_mode_change(line)
  assert ch == "#freeq"
  assert from == "op"
  assert modestring == "+ov"
  assert args == ["alice", "bob"]
  assert list.length(ops) == 2
  assert render.format_mode_meta(from, modestring, args)
    == "— op set mode +ov alice bob"
  let members =
    render.apply_mode_ops(
      [
        render.Member(
          nick: "alice",
          op: False,
          halfop: False,
          voice: False,
          color: "n1",
        ),
        render.Member(
          nick: "bob",
          op: False,
          halfop: False,
          voice: False,
          color: "n1",
        ),
      ],
      ops,
    )
  let assert Ok(alice) = list.find(members, fn(m) { m.nick == "alice" })
  assert alice.op == True
  let assert Ok(bob) = list.find(members, fn(m) { m.nick == "bob" })
  assert bob.voice == True
}

pub fn format_mode_meta_single_test() {
  assert render.format_mode_meta("nandi.uk", "+o", ["eve"])
    == "— nandi.uk set mode +o eve"
  assert render.format_mode_meta("nandi.uk", "+m", [])
    == "— nandi.uk set mode +m"
}

pub fn parse_kick_meta_test() {
  let line = ":op!u@h KICK #freeq eve :spam"
  let assert Some(#(ch, kicker, kicked, reason)) = render.parse_kick(line)
  assert ch == "#freeq"
  assert kicker == "op"
  assert kicked == "eve"
  assert reason == "spam"
  assert render.format_kick_meta(kicker, kicked, reason)
    == "— eve kicked by op: spam"
}

pub fn userlist_applies_353_for_current_channel_test() {
  let model = live.mount_model("/chat/freeq")
  let line = ":irc.freeq.at 353 me = #freeq :@alice bob"
  let #(next, _) = live.apply(model, live.PushLine(line))
  assert list.length(next.members) == 2
  let assert Ok(alice) = list.find(next.members, fn(m) { m.nick == "alice" })
  assert alice.op == True
}

pub fn userlist_ignores_353_for_other_channel_test() {
  let model = live.mount_model("/chat/freeq")
  let line = ":irc.freeq.at 353 me = #other :@eve"
  let #(next, _) = live.apply(model, live.PushLine(line))
  assert next.members == []
}

pub fn userlist_join_part_mode_test() {
  let model = live.mount_model("/chat/freeq")
  let #(m1, _) = live.apply(model, live.PushLine(":carol!c@h JOIN #freeq"))
  assert list.any(m1.members, fn(m) { m.nick == "carol" })
  // Join also appears as a presence row in the channel stream.
  assert list.any(m1.messages, fn(r) {
    r.kind == render.Join && r.nick == Some("carol")
  })
  let #(m2, _) = live.apply(m1, live.PushLine(":op!u@h MODE #freeq +o carol"))
  let assert Ok(carol) = list.find(m2.members, fn(m) { m.nick == "carol" })
  assert carol.op == True
  // Mode meta: freeq-app style em-dash line.
  assert list.any(m2.messages, fn(r) {
    r.kind == render.System
    && string.contains(r.text, "set mode +o carol")
  })
  let #(m3, _) = live.apply(m2, live.PushLine(":carol!c@h PART #freeq :bye"))
  assert !list.any(m3.members, fn(m) { m.nick == "carol" })
  assert list.any(m3.messages, fn(r) {
    r.kind == render.Part && r.nick == Some("carol")
  })
}

pub fn channel_mode_meta_in_stream_test() {
  let model = live.mount_model("/chat/freeq")
  let #(next, _) =
    live.apply(model, live.PushLine(":nandi.uk!n@h MODE #freeq +o eve"))
  let assert [row] = next.messages
  assert row.kind == render.System
  assert row.text == "— nandi.uk set mode +o eve"
  // Other channel: no stream row, no roster change.
  let #(other, _) =
    live.apply(model, live.PushLine(":nandi.uk!n@h MODE #other +o eve"))
  assert other.messages == []
}

pub fn members_prefix_helpers_test() {
  let alice =
    render.Member(
      nick: "alice",
      op: True,
      halfop: False,
      voice: False,
      color: "n1",
    )
  let bob =
    render.Member(
      nick: "bob",
      op: False,
      halfop: False,
      voice: True,
      color: "n2",
    )
  assert render.member_prefix_char(alice) == "@"
  assert render.member_prefix_class(alice) == "op"
  assert render.member_prefix_char(bob) == "+"
  assert render.member_prefix_class(bob) == "voice"
}

pub fn channel_shell_has_member_panel_test() {
  let html = live.initial_html("/chat/freeq")
  assert string.contains(html, "member-panel")
  assert string.contains(html, "member-list")
  assert string.contains(html, "People")
  assert string.contains(html, "data-drawer=\"members\"")
}

pub fn is_353_realistic_test() {
  let line = ":irc.freeq.at 353 web4_1 = #freeq :@alice +bob carol"
  assert render.is_353(line) == True
  assert render.channel_from_353(line) == Some("#freeq")
  let members = render.parse_353_members(line)
  assert list.length(members) == 3
}

pub fn is_353_with_tags_test() {
  let line = "@time=2024-01-01T00:00:00.000Z :irc.freeq.at 353 me = #freeq :alice"
  assert render.is_353(line) == True
  assert render.channel_from_353(line) == Some("#freeq")
}

pub fn is_353_bundled_366_test() {
  // freeq-server sometimes batches 353+366 in one write
  let line = ":irc.freeq.at 353 me = #freeq :alice\r\n:irc.freeq.at 366 me #freeq :End of /NAMES list"
  assert render.is_353(line) == True
  assert render.channel_from_353(line) == Some("#freeq")
  assert list.length(render.parse_353_members(line)) >= 1
}

// ── Reactions ────────────────────────────────────────────────────────────────

pub fn parse_reactions_tag_test() {
  let map = render.parse_reactions_tag("👍:alice,bob;❤️:carol")
  assert dict.get(map, "👍") == Ok(["alice", "bob"])
  assert dict.get(map, "❤️") == Ok(["carol"])
  assert render.parse_reactions_tag("") == dict.new()
  assert render.parse_reactions_tag("notacolon;:no_emoji;👍:") == dict.new()
}

pub fn parse_tagmsg_reaction_add_test() {
  let line = "@+react=👍;+reply=msg123 :bob!b@h TAGMSG #freeq"
  let assert Some(#(msgid, emoji, nick, added, ch)) =
    render.parse_tagmsg_reaction(line)
  assert msgid == "msg123"
  assert emoji == "👍"
  assert nick == "bob"
  assert added == True
  assert ch == "#freeq"
}

pub fn parse_tagmsg_reaction_remove_test() {
  let line = "@+freeq.at/unreact=❤️;+reply=msg99 :alice!a@h TAGMSG #freeq"
  let assert Some(#(msgid, emoji, nick, added, ch)) =
    render.parse_tagmsg_reaction(line)
  assert msgid == "msg99"
  assert emoji == "❤️"
  assert nick == "alice"
  assert added == False
  assert ch == "#freeq"
}

pub fn parse_tagmsg_reaction_draft_react_test() {
  let line = "@+draft/react=🔥;+reply=m1 :carol!c@h TAGMSG #dev"
  let assert Some(#(msgid, emoji, _, added, ch)) =
    render.parse_tagmsg_reaction(line)
  assert msgid == "m1"
  assert emoji == "🔥"
  assert added == True
  assert ch == "#dev"
}

pub fn apply_reaction_map_test() {
  let empty = dict.new()
  let one = render.apply_reaction_map(empty, "👍", "alice", True)
  assert dict.get(one, "👍") == Ok(["alice"])
  // Idempotent add
  let still = render.apply_reaction_map(one, "👍", "alice", True)
  assert dict.get(still, "👍") == Ok(["alice"])
  let two = render.apply_reaction_map(one, "👍", "bob", True)
  assert dict.get(two, "👍") == Ok(["alice", "bob"])
  let back = render.apply_reaction_map(two, "👍", "alice", False)
  assert dict.get(back, "👍") == Ok(["bob"])
  let gone = render.apply_reaction_map(back, "👍", "bob", False)
  assert gone == dict.new()
}

pub fn react_line_test() {
  let add = render.react_line("#freeq", "msg1", "👍", True)
  assert string.contains(add, "+react=👍")
  assert string.contains(add, "+reply=msg1")
  assert string.contains(add, "TAGMSG #freeq")
  let rem = render.react_line("freeq", "msg1", "❤️", False)
  assert string.contains(rem, "+freeq.at/unreact=❤️")
  assert string.contains(rem, "+reply=msg1")
}

pub fn history_row_with_reactions_test() {
  let rx = render.parse_reactions_tag("👍:alice")
  let row =
    render.history_row("bob!b@h", "hi", Some("m1"), Some(0), None, rx)
  assert dict.get(row.reactions, "👍") == Ok(["alice"])
}

pub fn toggle_reaction_sends_tagmsg_test() {
  let model = live.mount_model("/chat/freeq")
  let row =
    render.history_row("alice!a@h", "hello", Some("mid1"), Some(0), None, dict.new())
  let model = live.apply(model, live.SetHistory([row])).0
  let #(next, effect) = live.apply(model, live.ToggleReaction("mid1", "👍"))
  let assert live.IrcSend([line]) = effect
  assert string.contains(line, "+react=👍")
  assert string.contains(line, "+reply=mid1")
  // Optimistic local chip
  let assert Ok(updated) = list.find(next.messages, fn(r) { r.msgid == Some("mid1") })
  assert dict.get(updated.reactions, "👍") == Ok([model.nick])
  // Toggle again removes
  let #(next2, effect2) = live.apply(next, live.ToggleReaction("mid1", "👍"))
  let assert live.IrcSend([line2]) = effect2
  assert string.contains(line2, "+freeq.at/unreact=👍")
  let assert Ok(updated2) =
    list.find(next2.messages, fn(r) { r.msgid == Some("mid1") })
  assert updated2.reactions == dict.new()
}

pub fn live_reaction_tagmsg_updates_row_test() {
  let model = live.mount_model("/chat/freeq")
  let row =
    render.history_row("alice!a@h", "hello", Some("mid1"), Some(0), None, dict.new())
  let model = live.apply(model, live.SetHistory([row])).0
  let line = "@+react=🎉;+reply=mid1 :bob!b@h TAGMSG #freeq"
  let #(next, _) = live.apply(model, live.PushLine(line))
  let assert Ok(updated) = list.find(next.messages, fn(r) { r.msgid == Some("mid1") })
  assert dict.get(updated.reactions, "🎉") == Ok(["bob"])
}

pub fn channel_shell_has_react_picker_region_test() {
  let html = live.initial_html("/chat/freeq")
  assert string.contains(html, "data-ls-region=\"react-picker\"")
}

pub fn parse_history_reactions_from_batch_test() {
  let line =
    "@batch=h1;msgid=mid1;+freeq.at/reactions=👍:alice,bob :alice!a@h PRIVMSG #freeq :hi"
  // Batch lines are not chat rows…
  assert render.parse_message_line(line, None) == None
  // …but still expose reaction tallies for hydration.
  let assert Some(#(msgid, rx)) = render.parse_history_reactions(line)
  assert msgid == "mid1"
  assert dict.get(rx, "👍") == Ok(["alice", "bob"])
}

pub fn history_decode_includes_reactions_tag_test() {
  let body =
    "[{\"sender\":\"alice\",\"text\":\"hi\",\"msgid\":\"m1\",\"timestamp\":1,\"tags\":{\"+freeq.at/reactions\":\"🎉:bob\"}}]"
  let rows = rest.parse_history_json(body)
  assert list.length(rows) == 1
  let assert Ok(row) = list.first(rows)
  assert dict.get(row.reactions, "🎉") == Ok(["bob"])
}

pub fn merge_history_preserves_live_reactions_test() {
  let rest_row =
    render.history_row("alice!a@h", "hi", Some("m1"), Some(1), None, dict.new())
  let live_rx = render.parse_reactions_tag("👍:carol")
  let live_row =
    render.history_row("alice!a@h", "hi", Some("m1"), Some(1), None, live_rx)
  let merged = live.merge_history_rows([rest_row], [live_row])
  assert list.length(merged) == 1
  let assert Ok(row) = list.first(merged)
  assert dict.get(row.reactions, "👍") == Ok(["carol"])
}

pub fn chathistory_batch_hydrates_reactions_test() {
  let model = live.mount_model("/chat/freeq")
  let row =
    render.history_row("alice!a@h", "hello", Some("mid1"), Some(0), None, dict.new())
  let model = live.apply(model, live.SetHistory([row])).0
  let line =
    "@batch=hist01;msgid=mid1;+freeq.at/reactions=🔥:bob :alice!a@h PRIVMSG #freeq :hello"
  let #(next, _) = live.apply(model, live.PushLine(line))
  let assert Ok(updated) =
    list.find(next.messages, fn(r) { r.msgid == Some("mid1") })
  assert dict.get(updated.reactions, "🔥") == Ok(["bob"])
}

pub fn chathistory_latest_line_test() {
  let line = render.chathistory_latest_line("freeq", 50)
  assert string.contains(line, "CHATHISTORY LATEST #freeq * 50")
  assert string.ends_with(string.trim_end(line), "\r\n")
    || string.contains(line, "\r\n")
}

pub fn chathistory_before_line_test() {
  let line = render.chathistory_before_line("freeq", 1_700_000_000, 50)
  assert string.contains(line, "CHATHISTORY BEFORE #freeq timestamp=1700000000 50")
  assert string.contains(line, "\r\n")
}

pub fn oldest_timestamp_test() {
  let rows = [
    render.history_row("a!a@h", "x", Some("m1"), Some(100), None, dict.new()),
    render.history_row("b!b@h", "y", Some("m2"), Some(50), None, dict.new()),
    render.history_row("c!c@h", "z", Some("m3"), None, None, dict.new()),
  ]
  assert render.oldest_timestamp(rows) == Some(50)
  assert render.oldest_timestamp([]) == None
}

pub fn prepend_history_rows_test() {
  let older = [
    render.history_row("a!a@h", "old", Some("m0"), Some(1), None, dict.new()),
    render.history_row("b!b@h", "mid", Some("m1"), Some(2), None, dict.new()),
  ]
  let current = [
    render.history_row("b!b@h", "mid", Some("m1"), Some(2), None, dict.new()),
    render.history_row("c!c@h", "new", Some("m2"), Some(3), None, dict.new()),
  ]
  let merged = live.prepend_history_rows(older, current)
  assert list.length(merged) == 3
  let assert [first, ..] = merged
  assert first.msgid == Some("m0")
  assert live.prepend_history_rows([], current) == current
}

pub fn load_older_requests_fetch_test() {
  let model = live.mount_model("/chat/freeq")
  let recent =
    render.history_row(
      "alice!a@h",
      "hello",
      Some("mid1"),
      Some(1000),
      None,
      dict.new(),
    )
  let model = live.apply(model, live.SetHistory([recent])).0
  // Short page → exhausted; LoadOlder is a no-op.
  assert model.history_exhausted == True
  let #(noop, effect) = live.apply(model, live.LoadOlder)
  assert effect == live.NoEffect
  assert noop.history_loading == False

  // Fresh channel model with a full initial page so more history may exist.
  // Timestamps 1001..1050 — oldest is 1001.
  let model = live.mount_model("/chat/freeq")
  let full =
    list.repeat(0, live.history_page_size)
    |> list.index_map(fn(_, i) {
      let n = i + 1
      render.history_row(
        "alice!a@h",
        "msg",
        Some("m" <> int.to_string(n)),
        Some(1000 + n),
        None,
        dict.new(),
      )
    })
  let model = live.apply(model, live.SetHistory(full)).0
  assert model.history_exhausted == False
  let #(loading, effect) = live.apply(model, live.LoadOlder)
  assert loading.history_loading == True
  let assert live.FetchOlderHistory("#freeq", before) = effect
  assert before == 1001

  let older = [
    render.history_row(
      "bob!b@h",
      "earlier",
      Some("m0"),
      Some(900),
      None,
      dict.new(),
    ),
  ]
  let #(next, _) = live.apply(loading, live.PrependHistory(older))
  assert next.history_loading == False
  assert next.history_exhausted == True
  let assert [first, ..] = next.messages
  assert first.msgid == Some("m0")
}

pub fn load_older_route_test() {
  let assert Ok(live.LoadOlder) = live.decode_event("load_older", "")
}

pub fn jump_bottom_html_test() {
  let html = live.jump_bottom_html()
  assert string.contains(html, "id=\"jump-bottom\"")
  assert string.contains(html, "Jump to bottom")
  assert string.contains(html, "hidden")
}

pub fn messages_region_is_only_messages_node_test() {
  // Lightspeed patches [data-ls-region=messages] by replacing that node with
  // the region HTML root. The shell + FAB must NOT be in this HTML or each
  // message update nests another .messages-shell and the FAB breaks.
  let model = live.mount_model("/chat/freeq")
  let html = live.messages_region_for_test(model)
  assert string.contains(html, "id=\"messages\"")
  assert string.contains(html, "data-ls-region=\"messages\"")
  // Client uses data-channel to force scroll-to-bottom on stream switch.
  assert string.contains(html, "data-channel=\"freeq\"")
  assert !string.contains(html, "messages-shell")
  assert !string.contains(html, "jump-bottom")
}

pub fn messages_region_system_data_channel_test() {
  let model = live.mount_model("/chat/system")
  let html = live.messages_region_for_test(model)
  assert string.contains(html, "data-channel=\"system\"")
}

pub fn history_loading_html_test() {
  let html = live.history_loading_html()
  assert string.contains(html, "history-loading")
  assert string.contains(html, "history-spinner")
  assert string.contains(html, "Loading older messages")
}

pub fn set_history_preserves_prior_reactions_test() {
  // Simulate: CHATHISTORY hydrated chips, then REST SetHistory without tags.
  let model = live.mount_model("/chat/freeq")
  let with_rx =
    render.history_row(
      "alice!a@h",
      "hello",
      Some("mid1"),
      Some(0),
      None,
      render.parse_reactions_tag("👍:bob"),
    )
  let model = live.apply(model, live.SetHistory([with_rx])).0
  let rest_plain =
    render.history_row("alice!a@h", "hello", Some("mid1"), Some(0), None, dict.new())
  let #(next, _) = live.apply(model, live.SetHistory([rest_plain]))
  let assert Ok(row) = list.find(next.messages, fn(r) { r.msgid == Some("mid1") })
  assert dict.get(row.reactions, "👍") == Ok(["bob"])
}

pub fn chathistory_replaces_stale_optimistic_test() {
  // Authoritative CHATHISTORY tallies replace (not union) so removed reactors
  // do not stick around from optimistic local state.
  let model = live.mount_model("/chat/freeq")
  let stale =
    render.history_row(
      "alice!a@h",
      "hello",
      Some("mid1"),
      Some(0),
      None,
      render.parse_reactions_tag("👍:guest,bob"),
    )
  let model = live.apply(model, live.SetHistory([stale])).0
  let line =
    "@batch=h1;msgid=mid1;+freeq.at/reactions=👍:bob :alice!a@h PRIVMSG #freeq :hello"
  let #(next, _) = live.apply(model, live.PushLine(line))
  let assert Ok(row) = list.find(next.messages, fn(r) { r.msgid == Some("mid1") })
  assert dict.get(row.reactions, "👍") == Ok(["bob"])
}

// ── AV call TAGMSG ───────────────────────────────────────────────────────────

pub fn parse_av_state_tagmsg_test() {
  let line =
    "@+freeq.at/av-state=started;+freeq.at/av-id=01ABC;+freeq.at/av-actor=alice;+freeq.at/av-participants=2 :irc.freeq.at TAGMSG #freeq"
  let assert Some(av) = render.parse_av_state_tagmsg(line)
  assert av.channel == "#freeq"
  assert av.state == "started"
  assert av.session_id == "01ABC"
  assert av.actor == "alice"
  assert av.participants == 2
}

pub fn parse_av_state_ignores_other_tagmsg_test() {
  let line = "@+freeq.at/react=👍 :alice!a@h TAGMSG #freeq"
  assert render.parse_av_state_tagmsg(line) == None
}

pub fn parse_av_token_tagmsg_test() {
  let line =
    "@+freeq.at/av-token=jwt.abc;+freeq.at/av-id=01SID :irc.freeq.at TAGMSG bob"
  let assert Some(#(sid, tok)) =
    render.parse_av_token_tagmsg(line, ["bob", "alice"])
  assert sid == "01SID"
  assert tok == "jwt.abc"
}

pub fn parse_av_token_wrong_nick_test() {
  let line =
    "@+freeq.at/av-token=jwt.abc;+freeq.at/av-id=01SID :irc.freeq.at TAGMSG eve"
  assert render.parse_av_token_tagmsg(line, ["bob"]) == None
}

pub fn av_tagmsg_lines_test() {
  let start = render.av_start_line("#freeq", "abcd1234")
  assert string.contains(start, "+freeq.at/av-start=")
  assert string.contains(start, "+freeq.at/av-instance=abcd1234")
  assert string.contains(start, "TAGMSG #freeq")

  let join = render.av_join_line("freeq", "01SID", "abcd1234")
  assert string.contains(join, "+freeq.at/av-join=")
  assert string.contains(join, "+freeq.at/av-id=01SID")
  assert string.contains(join, "#freeq")

  let leave = render.av_leave_line("#freeq", "01SID", "abcd1234")
  assert string.contains(leave, "+freeq.at/av-leave=")
}

pub fn av_start_sends_tagmsg_test() {
  let model = live.mount_model("/chat/freeq")
  let model = live.Model(..model, nick: "alice")
  let #(next, effect) = live.apply(model, live.AvStart)
  assert next.av_active == True
  assert next.av_channel == Some("#freeq")
  let assert live.IrcSend([line]) = effect
  assert string.contains(line, "av-start")
  assert string.contains(line, "TAGMSG #freeq")
}

pub fn av_join_existing_session_test() {
  let model = live.mount_model("/chat/freeq")
  let model =
    live.Model(
      ..model,
      nick: "bob",
      av_call_present: True,
      av_session_id: Some("01EXIST"),
    )
  let #(next, effect) = live.apply(model, live.AvJoin)
  assert next.av_active == True
  let assert live.IrcSend([line]) = effect
  assert string.contains(line, "av-join")
  assert string.contains(line, "01EXIST")
}

pub fn av_state_started_marks_call_present_test() {
  let model = live.mount_model("/chat/freeq")
  let line =
    "@+freeq.at/av-state=started;+freeq.at/av-id=01CALL;+freeq.at/av-actor=eve;+freeq.at/av-participants=1 :irc.freeq.at TAGMSG #freeq"
  let #(next, _) = live.apply(model, live.PushLine(line))
  assert next.av_call_present == True
  assert next.av_session_id == Some("01CALL")
  assert next.av_active == False
  assert next.av_participant_count == 1
}

pub fn av_state_self_actor_becomes_active_test() {
  let model = live.mount_model("/chat/freeq")
  let model = live.Model(..model, nick: "alice")
  let line =
    "@+freeq.at/av-state=started;+freeq.at/av-id=01CALL;+freeq.at/av-actor=alice;+freeq.at/av-participants=1 :irc.freeq.at TAGMSG #freeq"
  let #(next, _) = live.apply(model, live.PushLine(line))
  assert next.av_active == True
  assert next.av_channel == Some("#freeq")
}

pub fn av_token_updates_model_test() {
  let model = live.mount_model("/chat/freeq")
  let model = live.Model(..model, nick: "alice", av_active: True)
  let line =
    "@+freeq.at/av-token=eyJhbGci;+freeq.at/av-id=01SID :irc.freeq.at TAGMSG alice"
  let #(next, _) = live.apply(model, live.PushLine(line))
  assert next.av_token == Some("eyJhbGci")
  assert next.av_session_id == Some("01SID")
}

pub fn av_leave_clears_state_test() {
  let model = live.mount_model("/chat/freeq")
  let model =
    live.Model(
      ..model,
      av_active: True,
      av_channel: Some("#freeq"),
      av_session_id: Some("01SID"),
      av_instance: "deadbeef",
    )
  let #(next, effect) = live.apply(model, live.AvLeave)
  assert next.av_active == False
  assert next.av_session_id == None
  let assert live.IrcSend([line]) = effect
  assert string.contains(line, "av-leave")
}

pub fn av_channel_shell_has_call_button_test() {
  let html = live.initial_html("/chat/freeq")
  assert string.contains(html, "av-call-btn")
  assert string.contains(html, "av_start")
  assert string.contains(html, "chat-center")
}

/// MoQ capture/render AudioWorklets load via blob: URLs. CSP without blob:
/// yields AbortError: Unable to load a worklet's module (silent calls).
/// media-src must also allow https:/http: so freeq-server /api/v1/media
/// video players work when the BFF origin differs from the IRC host.
pub fn live_csp_allows_blob_worklets_test() {
  let csp = freeq_web4.live_csp()
  assert string.contains(csp, "script-src 'self' blob:")
  assert string.contains(csp, "worker-src 'self' blob:")
  assert string.contains(csp, "media-src 'self' https: http: blob:")
}

pub fn active_call_from_sessions_json_test() {
  let body =
    "{\"active\":{\"id\":\"01X\",\"state\":\"Active\",\"participant_count\":3,\"title\":\"standup\"}}"
  let assert Some(call) = rest.active_call_from_sessions(Some(body))
  assert call.session_id == "01X"
  assert call.participant_count == 3
  assert rest.active_call_from_sessions(Some("{\"active\":null}")) == None
  assert rest.active_call_from_sessions(None) == None
}

pub fn apply_line_353_test_channel_test() {
  let model = live.mount_model("/chat/test")
  assert model.channel == Some("#test")
  let line = ":irc.freeq.at 353 web4_1 = #test :@alice bob carol"
  let #(next, _) = live.apply(model, live.PushLine(line))
  assert list.length(next.members) == 3
  let patches = live.plan_patches(model, next)
  assert patches != []
}

pub fn ls_form_round_trip_test() {
  let samples = [
    "hello",
    "https://www.youtube.com/watch?v=-7vISn5nnks",
    "a=b&c=d",
    "100% done",
    "literal %3D and %26 stay",
    "",
  ]
  list.each(samples, fn(s) {
    assert ls_form.unescape(ls_form.escape(s)) == s
  })
}

/// Older browser only escaped = / & (not %). Server still recovers those.
pub fn ls_form_legacy_client_unescape_test() {
  assert ls_form.unescape("https://www.youtube.com/watch?v%3D-7vISn5nnks")
    == "https://www.youtube.com/watch?v=-7vISn5nnks"
  assert ls_form.unescape("a%3Db%26c%3Dd") == "a=b&c=d"
}

pub fn ls_form_require_decodes_payload_test() {
  // Simulate browser formPayload for a YouTube URL.
  let payload =
    "msg=" <> ls_form.escape("https://www.youtube.com/watch?v=-7vISn5nnks")
  let data = form.parse_payload(payload)
  let assert Ok(text) = ls_form.require(data, "msg")
  assert text == "https://www.youtube.com/watch?v=-7vISn5nnks"
  // Bare form.require would leave the mangled value (the old bug).
  let assert Ok(raw) = form.require(data, "msg")
  assert string.contains(raw, "%3D")
}

pub fn link_preview_needs_resolve_test() {
  let row =
    render.history_row(
      "alice!a@h",
      "see https://example.com/post",
      Some("m1"),
      Some(1),
      None,
      dict.new(),
    )
  assert link_preview.needs_resolve(row)
  let with_embed =
    render.Row(
      ..row,
      embed: Some(
        render.Embed(
          kind: render.Og,
          href: "https://example.com/post",
          title: Some("Hello"),
          description: None,
          site_name: None,
          domain: Some("example.com"),
          image_url: None,
          video_id: None,
          bsky: None,
        ),
      ),
    )
  assert !link_preview.needs_resolve(with_embed)
  let plain =
    render.history_row("alice!a@h", "no links here", Some("m2"), Some(1), None, dict.new())
  assert !link_preview.needs_resolve(plain)
}

pub fn link_preview_attach_cache_only_test() {
  let url = "https://example.com/cached-preview-test"
  let key =
    crypto.hash(crypto.Sha256, bit_array.from_string("og:" <> url))
    |> bit_array.base16_encode
    |> string.lowercase
    |> string.slice(0, 40)
  let dir = config.preview_cache_dir()
  let _ = simplifile.create_directory_all(dir)
  let meta =
    "{\"fail\":false,\"kind\":\"og\",\"href\":\""
    <> url
    <> "\",\"title\":\"Cached Title\",\"domain\":\"example.com\"}"
  let path = filepath.join(dir, key <> ".json")
  let assert Ok(_) = simplifile.write(path, meta)
  let row =
    render.history_row(
      "bob!b@h",
      "check " <> url,
      Some("m-cache"),
      Some(1),
      None,
      dict.new(),
    )
  let attached = link_preview.attach_cache_only(row)
  let assert Some(embed) = attached.embed
  assert embed.kind == render.Og
  assert embed.href == url
  assert embed.title == Some("Cached Title")
  assert embed.domain == Some("example.com")
}

pub fn patch_embed_renders_link_card_test() {
  let model = live.mount_model("/chat/test")
  let row =
    render.history_row(
      "alice!a@h",
      "https://example.com/x",
      Some("m-embed"),
      Some(1),
      None,
      dict.new(),
    )
  let #(with_hist, _) = live.apply(model, live.SetHistory([row]))
  let embed =
    render.Embed(
      kind: render.Og,
      href: "https://example.com/x",
      title: Some("Example Domain"),
      description: Some("This domain is for use in illustrative examples."),
      site_name: Some("Example"),
      domain: Some("example.com"),
      image_url: None,
      video_id: None,
      bsky: None,
    )
  let #(with_embed, _) =
    live.apply(with_hist, live.PatchEmbed("m-embed", embed))
  let htmls =
    live.plan_patches(with_hist, with_embed)
    |> list.map(fn(p) {
      case p {
        diff.Replace(_, html) -> html
        _ -> ""
      }
    })
    |> string.concat
  assert string.contains(htmls, "class=\"link-embed\"")
  assert string.contains(htmls, "Example Domain")
  assert string.contains(htmls, "example.com")
  assert string.contains(htmls, "href=\"https://example.com/x\"")
}

// ── Message search ───────────────────────────────────────────────────────────

pub fn search_routes_test() {
  let assert Ok(live.OpenSearch) = live.decode_event("open_search", "")
  let assert Ok(live.CloseSearch) = live.decode_event("close_search", "")
  let assert Ok(live.RunSearch(q)) = live.decode_event("search", "q=deploy")
  assert q == "deploy"
}

pub fn open_search_on_channel_test() {
  let model = live.mount_model("/chat/freeq")
  let #(next, effect) = live.apply(model, live.OpenSearch)
  assert next.search_open == True
  assert effect == live.NoEffect
  assert string.contains(next.search_status, "at least")
}

pub fn open_search_on_index_flash_test() {
  let model = live.mount_model("/chat")
  let #(next, effect) = live.apply(model, live.OpenSearch)
  assert next.search_open == False
  assert effect == live.NoEffect
  assert string.contains(next.flash, "Join a channel")
}

pub fn run_search_too_short_test() {
  let model = live.mount_model("/chat/freeq")
  let #(next, effect) = live.apply(model, live.RunSearch("a"))
  assert next.search_open == True
  assert next.search_loading == False
  assert effect == live.NoEffect
  assert string.contains(next.search_status, "at least")
}

pub fn run_search_fetch_effect_test() {
  let model = live.mount_model("/chat/freeq")
  let hit =
    render.history_row(
      "alice!a@h",
      "deploy failed",
      Some("m1"),
      Some(1),
      None,
      dict.new(),
    )
  let model = live.apply(model, live.SetHistory([hit])).0
  let #(next, effect) = live.apply(model, live.RunSearch("deploy"))
  assert next.search_open == True
  assert next.search_loading == True
  assert next.search_query == "deploy"
  // Instant local hit before REST returns.
  assert list.length(next.search_results) == 1
  let assert live.FetchSearch(ch, q) = effect
  assert ch == "#freeq"
  assert q == "deploy"
}

pub fn set_search_results_test() {
  let model = live.mount_model("/chat/freeq")
  let model = live.apply(model, live.RunSearch("deploy")).0
  let hit =
    render.history_row(
      "alice!a@h",
      "deploy failed",
      Some("mid-s1"),
      Some(1_700_000_000),
      None,
      dict.new(),
    )
  let #(next, _) =
    live.apply(
      model,
      live.SetSearchResults("deploy", [hit], "1 result"),
    )
  assert next.search_loading == False
  assert list.length(next.search_results) == 1
  assert next.search_status == "1 result"
}

pub fn set_search_results_stale_ignored_test() {
  let model = live.mount_model("/chat/freeq")
  let model = live.apply(model, live.RunSearch("deploy")).0
  // User typed further before REST returned for "deploy".
  let model = live.apply(model, live.RunSearch("deployment")).0
  let hit =
    render.history_row(
      "alice!a@h",
      "deploy failed",
      Some("mid-old"),
      Some(1),
      None,
      dict.new(),
    )
  let #(next, _) =
    live.apply(model, live.SetSearchResults("deploy", [hit], "1 result"))
  // Stale — still waiting on "deployment", no clobber.
  assert next.search_query == "deployment"
  assert next.search_loading == True
  assert !list.any(next.search_results, fn(r) { r.msgid == Some("mid-old") })
}

pub fn local_search_hits_test() {
  let rows = [
    render.history_row("alice!a@h", "hello", Some("m1"), Some(1), None, dict.new()),
    render.history_row(
      "bob!b@h",
      "deploy failed",
      Some("m2"),
      Some(2),
      None,
      dict.new(),
    ),
    render.history_row(
      "carol!c@h",
      "another deploy",
      Some("m3"),
      Some(3),
      None,
      dict.new(),
    ),
  ]
  let hits = live.local_search_hits(rows, "deploy")
  assert list.length(hits) == 2
  // Newest first.
  let assert Ok(first) = list.first(hits)
  assert first.msgid == Some("m3")
}

pub fn live_message_updates_open_search_test() {
  let model = live.mount_model("/chat/freeq")
  let model = live.apply(model, live.OpenSearch).0
  let model = live.apply(model, live.RunSearch("needle")).0
  assert model.search_open == True
  // Simulate REST empty first.
  let model =
    live.apply(model, live.SetSearchResults("needle", [], "No messages found")).0
  assert model.search_results == []
  // Live PRIVMSG matching the query should land in the hit list.
  let line = "@msgid=live1 :alice!a@h PRIVMSG #freeq :found a needle here"
  let #(next, _) = live.apply(model, live.PushLine(line))
  assert list.any(next.search_results, fn(r) { r.msgid == Some("live1") })
}

pub fn search_status_for_test() {
  assert live.search_status_for([], None) == "No messages found"
  assert live.search_status_for([], Some("http_403"))
    == "This channel is private — sign in or join before searching"
  let hit =
    render.history_row("a!a@h", "x", Some("m1"), Some(1), None, dict.new())
  assert live.search_status_for([hit], None) == "1 result"
  assert live.search_status_for([hit, hit], None) == "2 results"
}

pub fn search_modal_patches_test() {
  let model = live.mount_model("/chat/freeq")
  let hit =
    render.history_row(
      "bob!b@h",
      "needle in haystack",
      Some("mid-hit"),
      Some(42),
      None,
      dict.new(),
    )
  let open = live.apply(model, live.OpenSearch).0
  let searching = live.apply(open, live.RunSearch("needle")).0
  let with_hits =
    live.apply(
      searching,
      live.SetSearchResults("needle", [hit], "1 result"),
    ).0
  let htmls =
    live.plan_patches(model, with_hits)
    |> list.map(fn(p) {
      case p {
        diff.Replace(_, html) -> html
        _ -> ""
      }
    })
    |> string.concat
  assert string.contains(htmls, "search-modal")
  assert string.contains(htmls, "id=\"search-input\"")
  assert string.contains(htmls, "data-scroll-to=\"mid-hit\"")
  assert string.contains(htmls, "needle in haystack")
  assert string.contains(htmls, "bob")

  // While open, result updates patch search-body without remounting the form.
  let body_only = live.plan_patches(searching, with_hits)
  let body_html =
    list.map(body_only, fn(p) {
      case p {
        diff.Replace(target, html) -> target <> html
        _ -> ""
      }
    })
    |> string.concat
  assert string.contains(body_html, "search-body")
  assert string.contains(body_html, "mid-hit")
}

pub fn close_search_clears_test() {
  let model = live.mount_model("/chat/freeq")
  let hit =
    render.history_row("a!a@h", "x", Some("m1"), Some(1), None, dict.new())
  let model = live.apply(model, live.RunSearch("xx")).0
  let model =
    live.apply(
      model,
      live.SetSearchResults("xx", [hit], "1 result"),
    ).0
  assert model.search_open == True
  let #(next, _) = live.apply(model, live.CloseSearch)
  assert next.search_open == False
  assert next.search_results == []
  assert next.search_query == ""
}

pub fn navigate_clears_search_test() {
  let model = live.mount_model("/chat/freeq")
  let model = live.apply(model, live.RunSearch("xx")).0
  let model =
    live.apply(
      model,
      live.SetSearchResults(
        "xx",
        [
          render.history_row(
            "a!a@h",
            "x",
            Some("m1"),
            Some(1),
            None,
            dict.new(),
          ),
        ],
        "1 result",
      ),
    ).0
  assert model.search_open == True
  let #(next, _) = live.apply(model, live.GoIndex)
  assert next.search_open == False
  assert next.search_results == []
}

pub fn jump_to_msg_in_list_test() {
  let model = live.mount_model("/chat/freeq")
  let row =
    render.history_row(
      "alice!a@h",
      "hello",
      Some("mid-jump"),
      Some(1000),
      None,
      dict.new(),
    )
  let model = live.apply(model, live.SetHistory([row])).0
  let model = live.apply(model, live.OpenSearch).0
  let #(next, effect) =
    live.apply(model, live.JumpToMsg("mid-jump", Some(1000)))
  assert next.search_open == False
  assert next.scroll_to_msgid == Some("mid-jump")
  assert effect == live.NoEffect
}

pub fn jump_to_msg_fetches_around_test() {
  let model = live.mount_model("/chat/freeq")
  let model = live.apply(model, live.OpenSearch).0
  let #(next, effect) =
    live.apply(model, live.JumpToMsg("mid-old", Some(500)))
  assert next.search_open == False
  assert next.scroll_to_msgid == Some("mid-old")
  assert next.history_loading == True
  let assert live.FetchAround("#freeq", before) = effect
  // before is exclusive so target at 500 is included.
  assert before == 501
}

pub fn merge_around_history_test() {
  let recent =
    render.history_row("a!a@h", "new", Some("m2"), Some(200), None, dict.new())
  let older =
    render.history_row("b!b@h", "old", Some("m1"), Some(100), None, dict.new())
  // Pure merge helper (oldest-first, de-duped).
  let merged = live.merge_rows_chronological([recent], [older, recent])
  assert list.length(merged) == 2
  let assert [first, second] = merged
  assert first.msgid == Some("m1")
  assert second.msgid == Some("m2")

  // MergeAroundHistory keeps scroll_to_msgid so the client can land on it.
  let base = live.mount_model("/chat/freeq")
  let base = live.apply(base, live.SetHistory([recent])).0
  let base = live.apply(base, live.JumpToMsg("m1", Some(100))).0
  // Jump queues FetchAround; re-seed messages and apply the page merge.
  let with_scroll =
    live.Model(..base, messages: [recent], scroll_to_msgid: Some("m1"))
  let #(next, _) =
    live.apply(with_scroll, live.MergeAroundHistory([older, recent]))
  assert list.length(next.messages) == 2
  assert next.scroll_to_msgid == Some("m1")
  assert next.history_loading == False
}

pub fn jump_to_msg_route_test() {
  let assert Ok(live.JumpToMsg(mid, ts)) =
    live.decode_event("jump_to_msg", "msgid=abc&ts=1700000000")
  assert mid == "abc"
  assert ts == Some(1_700_000_000)
  let assert Ok(live.ClearScrollTo) = live.decode_event("clear_scroll_to", "")
}

pub fn jump_to_msg_renders_highlight_class_test() {
  let row =
    render.history_row(
      "alice!a@h",
      "hello",
      Some("mid-hl"),
      Some(1000),
      None,
      dict.new(),
    )
  let model = live.mount_model("/chat/freeq")
  let model = live.apply(model, live.SetHistory([row])).0
  let jumped = live.apply(model, live.JumpToMsg("mid-hl", Some(1000))).0
  assert jumped.scroll_to_msgid == Some("mid-hl")
  let htmls =
    live.plan_patches(model, jumped)
    |> list.map(fn(p) {
      case p {
        diff.Replace(_, html) -> html
        _ -> ""
      }
    })
    |> string.concat
  assert string.contains(htmls, "highlight")
  assert string.contains(htmls, "data-msgid=\"mid-hl\"")
  assert string.contains(htmls, "data-scroll-to-msgid=\"mid-hl\"")
}

pub fn unread_case_insensitive_test() {
  let model =
    live.mount_model("/chat/freeq")
    |> live.with_my_channels(["#freeq", "#Dev"])
  let #(next, _) =
    live.apply(model, live.PushLine(":alice!a@h PRIVMSG #dev :hi"))
  assert live.unread_count(next, "#Dev") == 1
  assert live.unread_count(next, "#dev") == 1
  assert live.total_unread(next) == 1
  let #(opened, _) = live.apply(next, live.OpenChannel("DEV"))
  assert live.unread_count(opened, "#dev") == 0
}
