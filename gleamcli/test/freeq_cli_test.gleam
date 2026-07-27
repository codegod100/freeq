import freeq_cli/config
import freeq_cli/irc
import gleam/dict
import gleam/option.{None, Some}
import gleeunit

pub fn main() -> Nil {
  gleeunit.main()
}

// ── IRC parse ──────────────────────────────────────────────────────

pub fn parse_simple_privmsg_test() {
  let assert Some(msg) =
    irc.parse(":alice!u@h PRIVMSG #playground :hello world")
  assert msg.command == "PRIVMSG"
  assert msg.prefix == Some("alice!u@h")
  assert msg.params == ["#playground", "hello world"]
  assert irc.nick_from_prefix(msg.prefix) == "alice"
}

pub fn parse_tags_test() {
  let assert Some(msg) =
    irc.parse(
      "@time=2026-01-01T00:00:00.000Z;msgid=abc :bob!u@h PRIVMSG #c :hi",
    )
  assert msg.command == "PRIVMSG"
  assert dict.get(msg.tags, "msgid") == Ok("abc")
  assert dict.get(msg.tags, "time") == Ok("2026-01-01T00:00:00.000Z")
}

pub fn parse_ping_test() {
  let assert Some(msg) = irc.parse("PING :irc.freeq.at")
  assert msg.command == "PING"
  assert irc.trailing(msg) == "irc.freeq.at"
}

pub fn parse_cap_ls_test() {
  let assert Some(msg) =
    irc.parse(":irc.freeq.at CAP * LS :message-tags sasl server-time")
  assert msg.command == "CAP"
  assert irc.cap_subcmd(msg) == Some("LS")
  assert irc.trailing(msg) == "message-tags sasl server-time"
}

pub fn format_command_test() {
  let line = irc.command("PRIVMSG", ["#c", "hello there"])
  assert line == "PRIVMSG #c :hello there"
}

pub fn format_roundtrip_simple_test() {
  let assert Some(msg) = irc.parse("JOIN #playground")
  assert irc.format(msg) == "JOIN #playground"
}

pub fn parse_empty_test() {
  assert irc.parse("") == None
  assert irc.parse("\r\n") == None
}

// ── config helpers ─────────────────────────────────────────────────

pub fn parse_server_with_port_test() {
  assert config.parse_server("irc.freeq.at:6697") == #("irc.freeq.at", 6697)
  assert config.parse_server("localhost:6667") == #("localhost", 6667)
}

pub fn parse_server_default_port_test() {
  assert config.parse_server("irc.freeq.at") == #("irc.freeq.at", 6697)
}

pub fn normalize_channel_test() {
  assert config.normalize_channel("playground") == "#playground"
  assert config.normalize_channel("#hello") == "#hello"
  assert config.normalize_channel("&local") == "&local"
}

pub fn sanitize_nick_test() {
  assert config.sanitize_nick("  alice bob  ") == "alice_bob"
  assert config.sanitize_nick("") == "gleam_guest"
}
