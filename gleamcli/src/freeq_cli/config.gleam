//// CLI configuration and defaults for the freeq IRC client.

import argv
import clip
import clip/flag
import clip/help
import clip/opt
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub const default_host = "irc.freeq.at"

pub const default_tls_port = 6697

pub const default_plain_port = 6667

pub type Config {
  Config(
    host: String,
    port: Int,
    tls: Bool,
    tls_insecure: Bool,
    nick: String,
    user: String,
    realname: String,
    channels: List(String),
    send_message: Option(String),
    verbose: Bool,
  )
}

/// Parse CLI args. Returns `Error` with a help/error string for the user.
pub fn parse() -> Result(Config, String) {
  let args = argv.load().arguments
  command()
  |> clip.help(help.simple(
    "freeq-cli",
    "CLI IRC client for irc.freeq.at (guest mode by default)",
  ))
  |> clip.run(args)
  |> result.map(finalize)
}

fn command() -> clip.Command(RawConfig) {
  clip.command({
    use server <- clip.parameter
    use nick <- clip.parameter
    use channel <- clip.parameter
    use send <- clip.parameter
    use tls <- clip.parameter
    use no_tls <- clip.parameter
    use tls_insecure <- clip.parameter
    use verbose <- clip.parameter
    use realname <- clip.parameter

    RawConfig(
      server:,
      nick:,
      channel:,
      send:,
      tls:,
      no_tls:,
      tls_insecure:,
      verbose:,
      realname:,
    )
  })
  |> clip.opt(
    opt.new("server")
    |> opt.short("s")
    |> opt.help("Server host:port (default irc.freeq.at:6697)")
    |> opt.default(default_host <> ":" <> int.to_string(default_tls_port)),
  )
  |> clip.opt(
    opt.new("nick")
    |> opt.short("n")
    |> opt.help("IRC nickname")
    |> opt.default(default_nick()),
  )
  |> clip.opt(
    opt.new("channel")
    |> opt.short("c")
    |> opt.help("Channel(s) to join, comma-separated (e.g. '#playground')")
    |> opt.default(""),
  )
  |> clip.opt(
    opt.new("send")
    |> opt.help("Send one message to the first channel and exit")
    |> opt.default(""),
  )
  |> clip.flag(
    flag.new("tls")
    |> flag.help("Force TLS (default on for port 6697)"),
  )
  |> clip.flag(
    flag.new("no-tls")
    |> flag.help("Disable TLS (use plain TCP)"),
  )
  |> clip.flag(
    flag.new("tls-insecure")
    |> flag.help("Skip TLS certificate verification"),
  )
  |> clip.flag(
    flag.new("verbose")
    |> flag.short("v")
    |> flag.help("Log raw IRC traffic"),
  )
  |> clip.opt(
    opt.new("realname")
    |> opt.help("IRC realname field")
    |> opt.default("freeq-cli"),
  )
}

type RawConfig {
  RawConfig(
    server: String,
    nick: String,
    channel: String,
    send: String,
    tls: Bool,
    no_tls: Bool,
    tls_insecure: Bool,
    verbose: Bool,
    realname: String,
  )
}

fn finalize(raw: RawConfig) -> Config {
  let #(host, port) = parse_server(raw.server)
  let tls = case raw.no_tls {
    True -> False
    False ->
      case raw.tls {
        True -> True
        False -> port == default_tls_port
      }
  }
  let nick = sanitize_nick(raw.nick)
  let channels =
    raw.channel
    |> string.split(",")
    |> list.map(string.trim)
    |> list.filter(fn(c) { c != "" })
    |> list.map(normalize_channel)

  let send_message = case string.trim(raw.send) {
    "" -> None
    m -> Some(m)
  }

  Config(
    host:,
    port:,
    tls:,
    tls_insecure: raw.tls_insecure,
    nick:,
    user: nick,
    realname: raw.realname,
    channels:,
    send_message:,
    verbose: raw.verbose,
  )
}

pub fn parse_server(server: String) -> #(String, Int) {
  let server = string.trim(server)
  case string.split_once(server, ":") {
    Ok(#(host, port_str)) ->
      case int.parse(port_str) {
        Ok(p) -> #(host, p)
        Error(Nil) -> #(server, default_tls_port)
      }
    Error(Nil) -> #(server, default_tls_port)
  }
}

pub fn normalize_channel(name: String) -> String {
  let name = string.trim(name)
  case string.starts_with(name, "#") || string.starts_with(name, "&") {
    True -> name
    False -> "#" <> name
  }
}

pub fn sanitize_nick(nick: String) -> String {
  let nick =
    nick
    |> string.trim
    |> string.replace(" ", "_")
  case nick {
    "" -> "gleam_guest"
    _ ->
      case string.length(nick) > 64 {
        True -> string.slice(nick, 0, 64)
        False -> nick
      }
  }
}

fn default_nick() -> String {
  case getenv_user() {
    Ok(u) -> {
      let base =
        u
        |> string.split(".")
        |> list.first
        |> result.unwrap("user")
      sanitize_nick("gleam_" <> base)
    }
    Error(Nil) -> "gleam_guest"
  }
}

@external(erlang, "freeq_cli_ffi", "getenv")
fn getenv_user() -> Result(String, Nil)
