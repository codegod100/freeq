import freeq_web4/irc/render
import freeq_web4/live
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import lightspeed/testing/liveview

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

pub fn history_row_test() {
  let row = render.history_row("alice!a@h", "scrollback", Some("mid1"), Some(0))
  assert row.kind == render.Msg
  assert row.nick == Some("alice")
  assert row.msgid == Some("mid1")
  assert row.text == "scrollback"
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

pub fn mount_renders_shell_test() {
  let html = live.initial_html("/chat")
  assert string.contains(html, "freeq")
  assert string.contains(html, "data-ls-region")
  assert string.contains(html, "MY CHANNELS")
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
