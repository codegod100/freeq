//// Stratus WebSocket client to freeq-server `/irc`.
////
//// One process per LiveView socket. Performs guest CAP/NICK/USER
//// registration, answers PINGs, and forwards IRC lines to the parent
//// session subject.

import freeq_web4/config
import freeq_web4/irc/render
import gleam/erlang/process.{type Subject}
import gleam/http
import gleam/http/request
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/uri
import stratus

/// Messages the parent LiveView session receives from upstream.
pub type Event {
  /// Raw IRC line (no trailing CR/LF).
  Line(String)
  /// Connection phase changed.
  ConnState(WsState)
  /// Registration complete; nick is authoritative for this socket.
  Ready(nick: String)
  /// Upstream closed or failed.
  Down(String)
}

pub type WsState {
  Connecting
  Registering
  ReadyState
  Disconnected
}

pub type Handle {
  Handle(subject: Subject(stratus.InternalMessage(UserMsg)))
}

/// Internal user messages for the Stratus actor.
pub type UserMsg {
  Bootstrap
  Outbound(String)
  Shutdown
}

type Phase {
  WaitCapAck
  Registered
}

type Conn {
  Conn(
    parent: Subject(Event),
    nick: String,
    primary: String,
    extras: List(String),
    phase: Phase,
  )
}

/// Start the upstream IRC client. `parent` receives `Event` messages.
pub fn start(
  parent: Subject(Event),
  primary: String,
  extras: List(String),
) -> Result(Handle, String) {
  let nick = guest_nick()
  let primary = render.canonical_channel(primary)
  let extras =
    extras
    |> list.map(render.canonical_channel)
    |> list.filter(fn(c) { c != primary })

  let ws_url = config.upstream_ws()
  use req <- result.try(ws_request(ws_url))

  let init =
    Conn(
      parent: parent,
      nick: nick,
      primary: primary,
      extras: extras,
      phase: WaitCapAck,
    )

  process.send(parent, ConnState(Connecting))

  case
    stratus.new(req, init)
    |> stratus.on_message(on_message)
    |> stratus.on_close(fn(conn, _reason) {
      process.send(conn.parent, Down("closed"))
      Nil
    })
    |> stratus.start
  {
    Ok(started) -> {
      process.send(started.data, stratus.to_user_message(Bootstrap))
      Ok(Handle(subject: started.data))
    }
    Error(_) -> Error("stratus_start_failed")
  }
}

/// Enqueue an IRC line (with or without trailing CRLF).
pub fn send(handle: Handle, line: String) -> Nil {
  let line = case string.ends_with(line, "\r\n") {
    True -> line
    False ->
      case string.ends_with(line, "\n") {
        True -> line
        False -> line <> "\r\n"
      }
  }
  process.send(handle.subject, stratus.to_user_message(Outbound(line)))
}

/// Stop the upstream process.
pub fn stop(handle: Handle) -> Nil {
  process.send(handle.subject, stratus.to_user_message(Shutdown))
}

fn on_message(
  conn: Conn,
  msg: stratus.Message(UserMsg),
  socket: stratus.Connection,
) -> stratus.Next(Conn, UserMsg) {
  case msg {
    stratus.Text(text) -> handle_text(conn, text, socket)

    stratus.Binary(_) -> stratus.continue(conn)

    stratus.User(Bootstrap) -> {
      process.send(conn.parent, ConnState(Registering))
      case send_registration(socket, conn.nick) {
        Ok(_) -> stratus.continue(conn)
        Error(reason) -> {
          process.send(conn.parent, Down(reason))
          stratus.stop()
        }
      }
    }

    stratus.User(Outbound(line)) -> {
      case stratus.send_text_message(socket, line) {
        Ok(_) -> stratus.continue(conn)
        Error(_) -> {
          process.send(conn.parent, Down("send_failed"))
          stratus.stop()
        }
      }
    }

    stratus.User(Shutdown) -> {
      let _ = stratus.close(socket, stratus.Normal(<<"bye">>))
      stratus.stop()
    }
  }
}

fn handle_text(
  conn: Conn,
  text: String,
  socket: stratus.Connection,
) -> stratus.Next(Conn, UserMsg) {
  let lines =
    text
    |> string.replace("\r\n", "\n")
    |> string.replace("\r", "\n")
    |> string.split("\n")
    |> list.filter(fn(l) { l != "" })

  // Process lines sequentially; stop early if registration fails.
  list.fold(lines, #(conn, True), fn(acc, line) {
    let #(c, ok) = acc
    case ok {
      False -> acc
      True ->
        case handle_line(c, line, socket) {
          #(next, continue) -> #(next, continue)
        }
    }
  })
  |> fn(acc) {
    let #(c, _) = acc
    stratus.continue(c)
  }
}

fn handle_line(
  conn: Conn,
  line: String,
  socket: stratus.Connection,
) -> #(Conn, Bool) {
  case render.ping_token(line) {
    Some(token) -> {
      let pong = case token {
        "" -> "PONG\r\n"
        t -> "PONG :" <> t <> "\r\n"
      }
      case stratus.send_text_message(socket, pong) {
        Ok(_) -> #(conn, True)
        Error(_) -> {
          process.send(conn.parent, Down("pong_failed"))
          #(conn, False)
        }
      }
    }
    None -> handle_non_ping(conn, line, socket)
  }
}

fn handle_non_ping(
  conn: Conn,
  line: String,
  socket: stratus.Connection,
) -> #(Conn, Bool) {
  case conn.phase {
    WaitCapAck ->
      case render.parse_cap_ack(line) {
        Some(_caps) ->
          case finish_registration(socket, conn) {
            Ok(conn) -> {
              process.send(conn.parent, Ready(conn.nick))
              process.send(conn.parent, ConnState(ReadyState))
              #(Conn(..conn, phase: Registered), True)
            }
            Error(reason) -> {
              process.send(conn.parent, Down(reason))
              #(conn, False)
            }
          }
        None ->
          case render.welcome_numeric(line) {
            True ->
              case finish_registration(socket, conn) {
                Ok(conn) -> {
                  process.send(conn.parent, Ready(conn.nick))
                  process.send(conn.parent, ConnState(ReadyState))
                  process.send(conn.parent, Line(line))
                  #(Conn(..conn, phase: Registered), True)
                }
                Error(reason) -> {
                  process.send(conn.parent, Down(reason))
                  #(conn, False)
                }
              }
            False ->
              case string.contains(line, " 433 ") {
                True -> {
                  let nick = guest_nick()
                  case
                    stratus.send_text_message(socket, "NICK " <> nick <> "\r\n")
                  {
                    Ok(_) -> #(Conn(..conn, nick: nick), True)
                    Error(_) -> {
                      process.send(conn.parent, Down("nick_failed"))
                      #(conn, False)
                    }
                  }
                }
                False -> {
                  process.send(conn.parent, Line(line))
                  #(conn, True)
                }
              }
          }
      }
    Registered -> {
      process.send(conn.parent, Line(line))
      #(conn, True)
    }
  }
}

fn send_registration(
  socket: stratus.Connection,
  nick: String,
) -> Result(Nil, String) {
  let lines = [
    "CAP LS 302\r\n",
    "NICK " <> nick <> "\r\n",
    "USER web4 0 * :freeq-web4\r\n",
    "CAP REQ :sasl account-notify extended-join account-tag message-tags batch server-time echo-message draft/chathistory\r\n",
  ]
  send_all(socket, lines)
}

fn finish_registration(
  socket: stratus.Connection,
  conn: Conn,
) -> Result(Conn, String) {
  let channels = unique_strings([conn.primary, ..conn.extras])
  let joins = list.map(channels, fn(ch) { "JOIN " <> ch <> "\r\n" })
  let lines = ["CAP END\r\n", ..joins]
  use _ <- result.try(send_all(socket, lines))
  Ok(conn)
}

fn unique_strings(items: List(String)) -> List(String) {
  list.fold(items, [], fn(acc, item) {
    case list.contains(acc, item) {
      True -> acc
      False -> list.append(acc, [item])
    }
  })
}

fn send_all(
  socket: stratus.Connection,
  lines: List(String),
) -> Result(Nil, String) {
  list.try_fold(lines, Nil, fn(_, line) {
    case stratus.send_text_message(socket, line) {
      Ok(_) -> Ok(Nil)
      Error(_) -> Error("send_failed")
    }
  })
}

fn ws_request(url: String) -> Result(request.Request(String), String) {
  let http_url =
    url
    |> string.replace("wss://", "https://")
    |> string.replace("ws://", "http://")
  case request.to(http_url) {
    Ok(req) -> Ok(req)
    Error(_) ->
      case uri.parse(http_url) {
        Ok(u) -> {
          let host = case u.host {
            Some(h) -> h
            None -> "irc.freeq.at"
          }
          let path = case u.path {
            "" -> "/irc"
            p -> p
          }
          let scheme = case u.scheme {
            Some("https") -> http.Https
            Some("http") -> http.Http
            _ -> http.Https
          }
          let port = case u.port {
            Some(p) -> p
            None ->
              case scheme {
                http.Https -> 443
                _ -> 80
              }
          }
          Ok(
            request.new()
            |> request.set_scheme(scheme)
            |> request.set_host(host)
            |> request.set_port(port)
            |> request.set_path(path),
          )
        }
        Error(_) -> Error("bad_upstream_url")
      }
  }
}

@external(erlang, "os", "system_time")
fn os_system_time() -> Int

fn guest_nick() -> String {
  let n = int.absolute_value({ os_system_time() / 1_000_000 } % 90_000) + 10_000
  "web4_" <> int.to_string(n)
}
