import envoy
import freeq_web4
import freeq_web4/atproto/dpop_key
import freeq_web4/atproto/oauth
import freeq_web4/atproto/oauth_session.{OAuthSession}
import freeq_web4/atproto/sasl
import freeq_web4/atproto/util as atutil
import freeq_web4/irc/render
import freeq_web4/live
import freeq_web4/rest
import freeq_web4/session_store
import freeq_web4/upload
import gleam/bit_array
import gleam/dict
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit
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
  assert string.contains(out, "class=\"msg-img-url\"")
  assert string.contains(out, "class=\"msg-img-link\"")
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

pub fn merge_my_channels_test() {
  assert live.merge_my_channels(["#freeq"], ["#dev", "#freeq", "#test"])
    == ["#freeq", "#dev", "#test"]
  assert live.merge_my_channels([], ["#a", "#b"]) == ["#a", "#b"]
  assert live.merge_my_channels(["#only"], []) == ["#only"]
}

pub fn with_my_channels_test() {
  let model = live.mount_model("/chat")
  let restored = live.with_my_channels(model, ["#dev", "#test"])
  assert restored.my_channels == ["#dev", "#test"]
  assert restored.view == live.Index
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
  let channel = live.mount_model("/chat/freeq")
  assert live.path_for_model(channel) == "/chat/freeq"
  let #(opened, _) = live.apply(index, live.OpenChannel("dev"))
  assert live.path_for_model(opened) == "/chat/dev"
  let #(back, _) = live.apply(opened, live.GoIndex)
  assert live.path_for_model(back) == "/chat"
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
  let assert Some(#(ch, ops)) = render.parse_mode_change(line)
  assert ch == "#freeq"
  assert list.length(ops) == 2
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
  let #(m2, _) = live.apply(m1, live.PushLine(":op!u@h MODE #freeq +o carol"))
  let assert Ok(carol) = list.find(m2.members, fn(m) { m.nick == "carol" })
  assert carol.op == True
  let #(m3, _) = live.apply(m2, live.PushLine(":carol!c@h PART #freeq :bye"))
  assert !list.any(m3.members, fn(m) { m.nick == "carol" })
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
pub fn live_csp_allows_blob_worklets_test() {
  let csp = freeq_web4.live_csp()
  assert string.contains(csp, "script-src 'self' blob:")
  assert string.contains(csp, "worker-src 'self' blob:")
  assert string.contains(csp, "media-src 'self' blob:")
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
