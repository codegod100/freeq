//// IRC session: connect, CAP negotiate (guest), join, and interactive loop.

import freeq_cli/config.{type Config}
import freeq_cli/irc
import freeq_cli/transport.{type Transport}
import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

const register_timeout_ms = 15_000

const caps_wanted = [
  "message-tags", "server-time", "batch", "echo-message", "away-notify",
  "account-notify", "account-tag", "extended-join", "draft/chathistory",
  "draft/multiline",
]

pub type ClientError {
  TransportError(transport.TransportError)
  RegistrationFailed(String)
  ProtocolError(String)
}

pub fn error_to_string(e: ClientError) -> String {
  case e {
    TransportError(t) -> transport.error_to_string(t)
    RegistrationFailed(s) -> "registration failed: " <> s
    ProtocolError(s) -> "protocol error: " <> s
  }
}

type Session {
  Session(
    transport: Transport,
    config: Config,
    nick: String,
    registered: Bool,
    current_channel: Option(String),
    buffer: String,
    nick_tries: Int,
    verbose: Bool,
  )
}

type LoopMsg {
  Socket(transport.PacketMessage)
  StdinLine(Result(String, Nil))
  Tick
}

/// Connect, register as guest, join channels, then run interactive or one-shot.
pub fn run(cfg: Config) -> Result(Nil, ClientError) {
  let connect_cfg =
    transport.ConnectConfig(
      host: cfg.host,
      port: cfg.port,
      tls: cfg.tls,
      tls_insecure: cfg.tls_insecure,
      timeout_ms: 10_000,
    )

  io.println(
    style_dim("Connecting to ")
    <> cfg.host
    <> ":"
    <> int.to_string(cfg.port)
    <> case cfg.tls {
      True -> " (TLS)"
      False -> " (TCP)"
    }
    <> " as "
    <> cfg.nick
    <> "…",
  )

  use sock <- result.try(
    transport.connect(connect_cfg)
    |> result.map_error(TransportError),
  )

  let session =
    Session(
      transport: sock,
      config: cfg,
      nick: cfg.nick,
      registered: False,
      current_channel: list.first(cfg.channels) |> option.from_result,
      buffer: "",
      nick_tries: 0,
      verbose: cfg.verbose,
    )

  case register(session) {
    Error(e) -> {
      transport.close(sock)
      Error(e)
    }
    Ok(session) -> {
      case cfg.send_message {
        Some(text) -> {
          let result = oneshot(session, text)
          let _ = send_line(session, "QUIT :bye")
          transport.close(session.transport)
          result
        }
        None -> {
          let result = interactive(session)
          transport.close(session.transport)
          result
        }
      }
    }
  }
}

fn register(session: Session) -> Result(Session, ClientError) {
  use _ <- result.try(send_line(session, "CAP LS 302"))
  use _ <- result.try(send_line(session, "NICK " <> session.nick))
  use _ <- result.try(send_line(
    session,
    "USER "
      <> session.config.user
      <> " 0 * :"
      <> session.config.realname,
  ))

  register_loop(session, register_timeout_ms)
}

fn register_loop(
  session: Session,
  budget_ms: Int,
) -> Result(Session, ClientError) {
  case budget_ms <= 0 {
    True -> Error(RegistrationFailed("timed out waiting for welcome (001)"))
    False -> {
      let chunk_ms = 500
      case transport.receive(session.transport, chunk_ms) {
        Error(transport.Timeout) ->
          register_loop(session, budget_ms - chunk_ms)
        Error(transport.Closed) ->
          Error(RegistrationFailed("connection closed during registration"))
        Error(e) -> Error(TransportError(e))
        Ok(data) -> {
          case bit_array.to_string(data) {
            Error(Nil) ->
              Error(ProtocolError("non-utf8 data during registration"))
            Ok(text) -> {
              let #(session, lines) = take_lines(session, text)
              case handle_register_lines(session, lines) {
                Error(e) -> Error(e)
                Ok(#(session, True)) -> Ok(session)
                Ok(#(session, False)) ->
                  register_loop(session, budget_ms - chunk_ms)
              }
            }
          }
        }
      }
    }
  }
}

fn handle_register_lines(
  session: Session,
  lines: List(String),
) -> Result(#(Session, Bool), ClientError) {
  list.try_fold(lines, #(session, False), fn(acc, line) {
    let #(session, done) = acc
    case done {
      True -> Ok(#(session, True))
      False -> handle_register_line(session, line)
    }
  })
}

fn handle_register_line(
  session: Session,
  line: String,
) -> Result(#(Session, Bool), ClientError) {
  log_raw(session, "← " <> line)

  case irc.parse(line) {
    None -> Ok(#(session, False))
    Some(msg) ->
      case msg.command {
        "PING" -> {
          let token = irc.trailing(msg)
          use _ <- result.try(send_line(session, "PONG :" <> token))
          Ok(#(session, False))
        }
        "CAP" -> handle_cap(session, msg)
        "001" -> {
          let nick = case msg.params {
            [n, ..] -> n
            [] -> session.nick
          }
          io.println(style_ok("Connected as ") <> nick <> " (guest)")
          let session = Session(..session, nick:, registered: True)
          use session <- result.try(join_configured(session))
          Ok(#(session, True))
        }
        "433" -> {
          // Nickname in use — try a suffix.
          let tries = session.nick_tries + 1
          case tries > 5 {
            True -> Error(RegistrationFailed("nickname already in use"))
            False -> {
              let alt = session.config.nick <> int.to_string(tries)
              use _ <- result.try(send_line(session, "NICK " <> alt))
              Ok(#(Session(..session, nick: alt, nick_tries: tries), False))
            }
          }
        }
        "ERROR" -> Error(RegistrationFailed(irc.trailing(msg)))
        _ -> Ok(#(session, False))
      }
  }
}

fn handle_cap(
  session: Session,
  msg: irc.Message,
) -> Result(#(Session, Bool), ClientError) {
  case irc.cap_subcmd(msg) {
    Some("LS") -> {
      let available = irc.trailing(msg)
      let req =
        caps_wanted
        |> list.filter(fn(c) { string.contains(available, c) })
      case req {
        [] -> {
          use _ <- result.try(send_line(session, "CAP END"))
          Ok(#(session, False))
        }
        caps -> {
          use _ <- result.try(send_line(
            session,
            "CAP REQ :" <> string.join(caps, " "),
          ))
          Ok(#(session, False))
        }
      }
    }
    Some("ACK") | Some("NAK") -> {
      // Guest mode: never request SASL.
      use _ <- result.try(send_line(session, "CAP END"))
      Ok(#(session, False))
    }
    _ -> Ok(#(session, False))
  }
}

fn join_configured(session: Session) -> Result(Session, ClientError) {
  list.try_fold(session.config.channels, session, fn(session, channel) {
    use _ <- result.try(send_line(session, "JOIN " <> channel))
    io.println(style_dim("Joining ") <> channel)
    Ok(
      Session(
        ..session,
        current_channel: Some(channel),
      ),
    )
  })
}

fn oneshot(session: Session, text: String) -> Result(Nil, ClientError) {
  case session.current_channel {
    None ->
      Error(ProtocolError(" --send requires --channel / -c"))
    Some(channel) -> {
      use _ <- result.try(send_line(
        session,
        "PRIVMSG " <> channel <> " :" <> text,
      ))
      io.println(style_dim("→ ") <> channel <> " " <> text)
      // Brief drain so the server sees the message before QUIT.
      let _ = transport.receive(session.transport, 500)
      Ok(Nil)
    }
  }
}

fn interactive(session: Session) -> Result(Nil, ClientError) {
  use session <- result.try(
    transport.set_active(session.transport)
    |> result.map(fn(t) { Session(..session, transport: t) })
    |> result.map_error(TransportError),
  )

  print_help_brief()
  print_prompt(session)

  let parent = process.new_subject()
  let _stdin_pid =
    process.spawn(fn() { stdin_loop(parent) })

  let selector =
    process.new_selector()
    |> process.select(parent)
    |> transport.select(Socket)

  interactive_loop(session, selector)
}

fn stdin_loop(parent: Subject(LoopMsg)) -> Nil {
  case get_line("") {
    Error(_) -> {
      process.send(parent, StdinLine(Error(Nil)))
      Nil
    }
    Ok(line) -> {
      process.send(parent, StdinLine(Ok(line)))
      stdin_loop(parent)
    }
  }
}

fn interactive_loop(
  session: Session,
  selector: process.Selector(LoopMsg),
) -> Result(Nil, ClientError) {
  // Wake periodically so we can re-print prompt if needed; mainly for PING via active.
  case process.selector_receive(selector, 60_000) {
    Error(Nil) -> {
      // Idle timeout — send keepalive PING.
      case send_line(session, "PING :keepalive") {
        Error(e) -> Error(e)
        Ok(_) -> interactive_loop(session, selector)
      }
    }
    Ok(Socket(transport.PeerClosed)) -> {
      io.println(style_err("Disconnected."))
      Ok(Nil)
    }
    Ok(Socket(transport.SocketError(e))) -> {
      io.println(style_err("Socket error: " <> e))
      Error(TransportError(transport.ReceiveFailed(e)))
    }
    Ok(Socket(transport.Data(data))) -> {
      case bit_array.to_string(data) {
        Error(Nil) -> interactive_loop(session, selector)
        Ok(text) -> {
          let #(session, lines) = take_lines(session, text)
          case handle_server_lines(session, lines) {
            Error(e) -> Error(e)
            Ok(#(_session, True)) -> Ok(Nil)
            Ok(#(session, False)) -> {
              print_prompt(session)
              interactive_loop(session, selector)
            }
          }
        }
      }
    }
    Ok(StdinLine(Error(Nil))) -> {
      let _ = send_line(session, "QUIT :EOF")
      Ok(Nil)
    }
    Ok(StdinLine(Ok(line))) -> {
      case handle_user_input(session, string.trim_end(line)) {
        Error(e) -> Error(e)
        Ok(#(_session, True)) -> Ok(Nil)
        Ok(#(session, False)) -> {
          print_prompt(session)
          interactive_loop(session, selector)
        }
      }
    }
    Ok(Tick) -> interactive_loop(session, selector)
  }
}

fn handle_server_lines(
  session: Session,
  lines: List(String),
) -> Result(#(Session, Bool), ClientError) {
  list.try_fold(lines, #(session, False), fn(acc, line) {
    let #(session, quit) = acc
    case quit {
      True -> Ok(#(session, True))
      False -> handle_server_line(session, line)
    }
  })
}

fn handle_server_line(
  session: Session,
  line: String,
) -> Result(#(Session, Bool), ClientError) {
  log_raw(session, "← " <> line)

  case irc.parse(line) {
    None -> Ok(#(session, False))
    Some(msg) ->
      case msg.command {
        "PING" -> {
          use _ <- result.try(send_line(session, "PONG :" <> irc.trailing(msg)))
          Ok(#(session, False))
        }
        "PRIVMSG" -> {
          display_privmsg(session, msg)
          Ok(#(session, False))
        }
        "NOTICE" -> {
          display_notice(session, msg)
          Ok(#(session, False))
        }
        "JOIN" -> {
          let nick = irc.nick_from_prefix(msg.prefix)
          let channel = case msg.params {
            [c, ..] -> c
            [] -> ""
          }
          io.println(style_dim("* " <> nick <> " joined " <> channel))
          Ok(#(session, False))
        }
        "PART" -> {
          let nick = irc.nick_from_prefix(msg.prefix)
          let channel = case msg.params {
            [c, ..] -> c
            [] -> ""
          }
          io.println(style_dim("* " <> nick <> " left " <> channel))
          Ok(#(session, False))
        }
        "QUIT" -> {
          let nick = irc.nick_from_prefix(msg.prefix)
          io.println(style_dim("* " <> nick <> " quit"))
          Ok(#(session, False))
        }
        "NICK" -> {
          let old = irc.nick_from_prefix(msg.prefix)
          let new = irc.trailing(msg)
          let session = case old == session.nick {
            True -> Session(..session, nick: new)
            False -> session
          }
          io.println(style_dim("* " <> old <> " is now " <> new))
          Ok(#(session, False))
        }
        "332" -> {
          // RPL_TOPIC
          let topic = irc.trailing(msg)
          let channel = case msg.params {
            [_, c, ..] -> c
            _ -> ""
          }
          io.println(style_dim("Topic for " <> channel <> ": ") <> topic)
          Ok(#(session, False))
        }
        "353" -> {
          // RPL_NAMREPLY — suppress noisy dump unless verbose
          case session.verbose {
            True -> io.println(style_dim(line))
            False -> Nil
          }
          Ok(#(session, False))
        }
        "366" -> Ok(#(session, False))
        // End of names
        "ERROR" -> {
          io.println(style_err("ERROR: " <> irc.trailing(msg)))
          Ok(#(session, True))
        }
        _ -> {
          // Show server numerics that look like errors/info (400+ and a few useful ones)
          case is_noticeable_numeric(msg.command) {
            True -> {
              io.println(style_dim(msg.command <> " " <> irc.trailing(msg)))
              Ok(#(session, False))
            }
            False -> Ok(#(session, False))
          }
        }
      }
  }
}

fn is_noticeable_numeric(cmd: String) -> Bool {
  case int.parse(cmd) {
    Error(Nil) -> False
    Ok(n) -> n >= 400 || n == 301 || n == 305 || n == 306
  }
}

fn display_privmsg(session: Session, msg: irc.Message) -> Nil {
  let from = irc.nick_from_prefix(msg.prefix)
  let target = case msg.params {
    [t, ..] -> t
    [] -> "?"
  }
  let text = irc.trailing(msg)
  let label = case string.starts_with(target, "#") || string.starts_with(target, "&") {
    True -> target
    False -> "dm"
  }
  // Clear the prompt line before printing.
  io.print("\r\u{001b}[K")
  case from == session.nick {
    True ->
      io.println(
        style_dim(label <> " ") <> style_self("<" <> from <> "> ") <> text,
      )
    False ->
      io.println(style_dim(label <> " ") <> style_nick("<" <> from <> "> ") <> text)
  }
}

fn display_notice(_session: Session, msg: irc.Message) -> Nil {
  let from = irc.nick_from_prefix(msg.prefix)
  let text = irc.trailing(msg)
  io.print("\r\u{001b}[K")
  io.println(style_dim("-" <> from <> "- ") <> text)
}

fn handle_user_input(
  session: Session,
  line: String,
) -> Result(#(Session, Bool), ClientError) {
  case line {
    "" -> Ok(#(session, False))
    _ ->
      case string.starts_with(line, "/") {
        True -> handle_slash(session, line)
        False -> send_chat(session, line)
      }
  }
}

fn handle_slash(
  session: Session,
  line: String,
) -> Result(#(Session, Bool), ClientError) {
  let body = string.drop_start(line, 1)
  let #(cmd, rest) = case string.split_once(body, " ") {
    Ok(#(c, r)) -> #(string.lowercase(c), r)
    Error(Nil) -> #(string.lowercase(body), "")
  }

  case cmd {
    "help" | "h" | "?" -> {
      print_help()
      Ok(#(session, False))
    }
    "quit" | "q" | "exit" -> {
      let reason = case rest {
        "" -> "Leaving"
        r -> r
      }
      use _ <- result.try(send_line(session, "QUIT :" <> reason))
      Ok(#(session, True))
    }
    "join" | "j" -> {
      case rest {
        "" -> {
          io.println(style_err("Usage: /join #channel"))
          Ok(#(session, False))
        }
        ch -> {
          let channel = config.normalize_channel(ch)
          use _ <- result.try(send_line(session, "JOIN " <> channel))
          Ok(#(Session(..session, current_channel: Some(channel)), False))
        }
      }
    }
    "part" | "leave" -> {
      let channel = case rest {
        "" -> option.unwrap(session.current_channel, "")
        c -> config.normalize_channel(c)
      }
      case channel {
        "" -> {
          io.println(style_err("No channel to part"))
          Ok(#(session, False))
        }
        c -> {
          use _ <- result.try(send_line(session, "PART " <> c))
          let current = case session.current_channel {
            Some(cur) if cur == c -> None
            other -> other
          }
          Ok(#(Session(..session, current_channel: current), False))
        }
      }
    }
    "msg" | "query" -> {
      case string.split_once(rest, " ") {
        Error(Nil) -> {
          io.println(style_err("Usage: /msg <nick> <text>"))
          Ok(#(session, False))
        }
        Ok(#(nick, text)) -> {
          use _ <- result.try(send_line(
            session,
            "PRIVMSG " <> nick <> " :" <> text,
          ))
          Ok(#(session, False))
        }
      }
    }
    "nick" -> {
      case rest {
        "" -> {
          io.println(style_err("Usage: /nick <name>"))
          Ok(#(session, False))
        }
        n -> {
          let n = config.sanitize_nick(n)
          use _ <- result.try(send_line(session, "NICK " <> n))
          Ok(#(session, False))
        }
      }
    }
    "me" -> {
      case session.current_channel {
        None -> {
          io.println(style_err("Join a channel first"))
          Ok(#(session, False))
        }
        Some(ch) -> {
          use _ <- result.try(send_line(
            session,
            "PRIVMSG " <> ch <> " :\u{0001}ACTION " <> rest <> "\u{0001}",
          ))
          Ok(#(session, False))
        }
      }
    }
    "raw" -> {
      case rest {
        "" -> {
          io.println(style_err("Usage: /raw <irc line>"))
          Ok(#(session, False))
        }
        r -> {
          use _ <- result.try(send_line(session, r))
          Ok(#(session, False))
        }
      }
    }
    "names" -> {
      case option.or(
        case rest {
          "" -> None
          c -> Some(config.normalize_channel(c))
        },
        session.current_channel,
      ) {
        None -> {
          io.println(style_err("No channel"))
          Ok(#(session, False))
        }
        Some(ch) -> {
          use _ <- result.try(send_line(session, "NAMES " <> ch))
          Ok(#(session, False))
        }
      }
    }
    "focus" | "win" | "w" -> {
      case rest {
        "" -> {
          io.println(
            "Current: "
            <> option.unwrap(session.current_channel, "(none)"),
          )
          Ok(#(session, False))
        }
        c -> {
          let channel = config.normalize_channel(c)
          Ok(#(Session(..session, current_channel: Some(channel)), False))
        }
      }
    }
    _ -> {
      // Treat /cmd as raw IRC if it looks like a known verb, else help.
      use _ <- result.try(send_line(session, string.drop_start(line, 1)))
      Ok(#(session, False))
    }
  }
}

fn send_chat(
  session: Session,
  text: String,
) -> Result(#(Session, Bool), ClientError) {
  case session.current_channel {
    None -> {
      io.println(style_err("No channel selected. /join #channel first."))
      Ok(#(session, False))
    }
    Some(ch) -> {
      use _ <- result.try(send_line(
        session,
        "PRIVMSG " <> ch <> " :" <> text,
      ))
      // Local echo if server may not have echo-message.
      io.println(
        style_dim(ch <> " ") <> style_self("<" <> session.nick <> "> ") <> text,
      )
      Ok(#(session, False))
    }
  }
}

fn take_lines(session: Session, chunk: String) -> #(Session, List(String)) {
  let buffer = session.buffer <> chunk
  let parts = string.split(buffer, "\n")
  case list.reverse(parts) {
    [] -> #(Session(..session, buffer: ""), [])
    [incomplete, ..complete_rev] -> {
      let complete =
        complete_rev
        |> list.reverse
        |> list.map(fn(l) {
          case string.ends_with(l, "\r") {
            True -> string.drop_end(l, 1)
            False -> l
          }
        })
        |> list.filter(fn(l) { l != "" })
      #(Session(..session, buffer: incomplete), complete)
    }
  }
}

fn send_line(session: Session, line: String) -> Result(Nil, ClientError) {
  log_raw(session, "→ " <> line)
  transport.send(session.transport, line)
  |> result.map_error(TransportError)
}

fn log_raw(session: Session, line: String) -> Nil {
  case session.verbose {
    True -> io.println_error(style_dim(line))
    False -> Nil
  }
}

fn print_prompt(session: Session) -> Nil {
  let ch = option.unwrap(session.current_channel, "*")
  io.print(style_dim("[" <> session.nick <> " " <> ch <> "] "))
}

fn print_help_brief() -> Nil {
  io.println(
    style_dim(
      "Type to chat. Commands: /join /part /msg /nick /quit /help  (guest mode)",
    ),
  )
}

fn print_help() -> Nil {
  io.println(
    "
Commands:
  /join #channel     Join a channel (and focus it)
  /part [#channel]   Leave channel
  /focus #channel    Set current channel without JOIN
  /msg nick text     Private message
  /nick name         Change nickname
  /me action         CTCP ACTION
  /names [#channel]  List names
  /raw LINE          Send raw IRC
  /quit [reason]     Disconnect
  /help              This help

Plain text is sent to the current channel.
Connected as a guest (no AT Protocol SASL).
",
  )
}

// ── tiny ANSI helpers ──────────────────────────────────────────────

fn style_dim(s: String) -> String {
  "\u{001b}[90m" <> s <> "\u{001b}[0m"
}

fn style_ok(s: String) -> String {
  "\u{001b}[32m" <> s <> "\u{001b}[0m"
}

fn style_err(s: String) -> String {
  "\u{001b}[31m" <> s <> "\u{001b}[0m"
}

fn style_nick(s: String) -> String {
  "\u{001b}[36m" <> s <> "\u{001b}[0m"
}

fn style_self(s: String) -> String {
  "\u{001b}[33m" <> s <> "\u{001b}[0m"
}

@external(erlang, "freeq_cli_ffi", "get_line")
fn get_line(prompt: String) -> Result(String, Nil)
