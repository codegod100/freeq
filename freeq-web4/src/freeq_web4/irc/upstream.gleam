//// Stratus WebSocket client to freeq-server `/irc`.
////
//// One process per LiveView socket. Performs CAP/NICK/USER registration,
//// optional SASL `ATPROTO-CHALLENGE` when OAuth credentials are present,
//// answers PINGs, and forwards IRC lines to the parent session subject.

import freeq_web4/atproto/oauth
import freeq_web4/atproto/oauth_session.{type OAuthSession}
import freeq_web4/atproto/sasl
import freeq_web4/config
import freeq_web4/irc/render
import freeq_web4/session_store
import gleam/erlang/process.{type Subject}
import gleam/http
import gleam/http/request
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import logging
import stratus

/// Messages the parent LiveView session receives from upstream.
pub type Event {
  /// Raw IRC line (no trailing CR/LF).
  Line(String)
  /// Connection phase changed.
  ConnState(WsState)
  /// Registration complete; nick is authoritative for this socket.
  Ready(nick: String)
  /// SASL outcome (when OAuth credentials were supplied).
  Sasl(SaslStatus)
  /// freeq-server API-BEARER notice after successful SASL.
  ApiBearer(String)
  /// OAuth tokens / DPoP nonce updated during registration (refresh or NOTICE).
  /// Parent must persist — AS refresh-token rotation invalidates the old RT.
  AuthUpdated(OAuthSession)
  /// Upstream closed or failed.
  Down(String)
}

/// Outcome of the optional SASL `ATPROTO-CHALLENGE` exchange.
pub type SaslStatus {
  /// SASL requested; waiting for challenge / result.
  SaslPending
  /// Numeric 903 — authenticated DID bound to this connection.
  SaslOk
  /// Numeric 904 or local failure — guest fallback or disconnect.
  SaslFailed
}

/// Coarse connection phase forwarded as `ConnState` to the LiveView host.
pub type WsState {
  /// Opening the freeq-server `/irc` WebSocket.
  Connecting
  /// CAP negotiation, NICK/USER, optional SASL.
  Registering
  /// Fully registered; JOINs and PRIVMSGs allowed.
  ReadyState
  /// Socket closed or never connected.
  Disconnected
}

/// Auth for the upstream connection.
pub type Auth {
  /// Anonymous CAP/NICK/USER only (no SASL).
  Guest
  /// OAuth credentials → SASL ATPROTO-CHALLENGE.
  OAuth(OAuthSession)
}

/// Opaque handle to the Stratus actor for this upstream connection.
pub type Handle {
  Handle(subject: Subject(stratus.InternalMessage(UserMsg)))
}

/// Internal user messages for the Stratus actor.
pub type UserMsg {
  /// Kick off CAP LS / registration after the socket is up.
  Bootstrap
  /// Send a raw IRC line to freeq-server.
  Outbound(String)
  /// Tear down the actor and close the socket.
  Shutdown
}

/// Internal registration / SASL state machine phase.
type Phase {
  /// Waiting for CAP ACK after CAP REQ.
  WaitCapAck
  /// Waiting for AUTHENTICATE challenge payload.
  SaslChallenge
  /// Waiting for 903/904 after AUTHENTICATE response.
  SaslResult
  /// CAP END done; fully registered.
  Registered
}

/// Mutable connection state held by the Stratus actor.
type Conn {
  Conn(
    parent: Subject(Event),
    nick: String,
    primary: String,
    extras: List(String),
    phase: Phase,
    auth: Auth,
    /// Browser cookie session id — used to re-load OAuth after RT rotation races.
    session_id: String,
  )
}

/// Start the upstream IRC client. `parent` receives `Event` messages.
///
/// `session_id` is the browser `freeq_session` cookie (empty for pure guests).
/// When set, refresh can recover from multi-tab refresh-token races by
/// re-reading the disk store.
pub fn start(
  parent: Subject(Event),
  primary: String,
  extras: List(String),
  auth: Auth,
  session_id: String,
) -> Result(Handle, String) {
  let nick = case auth {
    OAuth(oauth) -> oauth_session.nick(oauth)
    Guest -> guest_nick()
  }
  // Empty primary = register only (used for SASL on the channel-list page).
  let primary = case string.trim(primary) {
    "" -> ""
    p -> render.canonical_channel(p)
  }
  let extras =
    extras
    |> list.map(render.canonical_channel)
    |> list.filter(fn(c) { c != primary && c != "#" })

  let ws_url = config.upstream_ws()
  use req <- result.try(ws_request(ws_url))

  let init =
    Conn(
      parent: parent,
      nick: nick,
      primary: primary,
      extras: extras,
      phase: WaitCapAck,
      auth: auth,
      session_id: session_id,
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
  // API-BEARER notice (after successful SASL)
  let _ = case parse_api_bearer_notice(line) {
    Some(bearer) -> process.send(conn.parent, ApiBearer(bearer))
    None -> Nil
  }

  // DPoP nonce notice during SASL
  let conn = case parse_dpop_nonce_notice(line) {
    Some(nonce) -> update_dpop_nonce(conn, nonce)
    None -> conn
  }

  case conn.phase {
    WaitCapAck -> reg_wait_cap(conn, line, socket)
    SaslChallenge -> reg_sasl_challenge(conn, line, socket)
    SaslResult -> reg_sasl_result(conn, line, socket)
    Registered -> {
      process.send(conn.parent, Line(line))
      #(conn, True)
    }
  }
}

fn reg_wait_cap(
  conn: Conn,
  line: String,
  socket: stratus.Connection,
) -> #(Conn, Bool) {
  case render.parse_cap_ack(line) {
    Some(caps) -> {
      let has_sasl = list.any(caps, fn(c) { string.lowercase(c) == "sasl" })
      case has_credentials(conn), has_sasl {
        True, True -> {
          let conn = refresh_oauth_before_sasl(conn)
          process.send(conn.parent, Sasl(SaslPending))
          case
            stratus.send_text_message(
              socket,
              "AUTHENTICATE ATPROTO-CHALLENGE\r\n",
            )
          {
            Ok(_) -> {
              logging.log(
                logging.Info,
                "SASL ATPROTO-CHALLENGE for " <> auth_handle(conn),
              )
              #(Conn(..conn, phase: SaslChallenge), True)
            }
            Error(_) -> {
              process.send(conn.parent, Down("authenticate_failed"))
              #(conn, False)
            }
          }
        }
        True, False -> {
          process.send(conn.parent, Sasl(SaslFailed))
          finish_and_ready(conn, socket, False)
        }
        False, _ -> finish_and_ready(conn, socket, False)
      }
    }
    None ->
      case render.welcome_numeric(line) {
        True ->
          case has_credentials(conn) {
            True -> process.send(conn.parent, Sasl(SaslFailed))
            False -> Nil
          }
          |> fn(_) { finish_and_ready(conn, socket, False) }
        False ->
          case string.contains(line, " 433 ") {
            True -> handle_433(conn, socket)
            False -> {
              process.send(conn.parent, Line(line))
              #(conn, True)
            }
          }
      }
  }
}

fn reg_sasl_challenge(
  conn: Conn,
  line: String,
  socket: stratus.Connection,
) -> #(Conn, Bool) {
  case parse_authenticate_challenge(line) {
    Some(challenge_b64) -> respond_challenge(conn, socket, challenge_b64)
    None ->
      case string.contains(line, " 904 ") {
        True -> {
          logging.log(
            logging.Warning,
            "SASL 904 during challenge: " <> string.slice(line, 0, 200),
          )
          process.send(conn.parent, Sasl(SaslFailed))
          finish_and_ready(conn, socket, False)
        }
        False -> {
          // DPOP_NONCE already applied above; ignore other noise.
          process.send(conn.parent, Line(line))
          #(conn, True)
        }
      }
  }
}

fn reg_sasl_result(
  conn: Conn,
  line: String,
  socket: stratus.Connection,
) -> #(Conn, Bool) {
  case string.contains(line, " 903 ") {
    True -> {
      logging.log(logging.Info, "SASL 903 success for " <> auth_handle(conn))
      process.send(conn.parent, Sasl(SaslOk))
      finish_and_ready(conn, socket, True)
    }
    False ->
      case string.contains(line, " 904 ") {
        True -> {
          logging.log(
            logging.Warning,
            "SASL 904 for "
              <> auth_handle(conn)
              <> ": "
              <> string.slice(line, 0, 200),
          )
          process.send(conn.parent, Sasl(SaslFailed))
          finish_and_ready(conn, socket, False)
        }
        False ->
          case parse_authenticate_challenge(line) {
            // Server re-issues challenge (DPoP retry).
            Some(challenge_b64) ->
              respond_challenge(conn, socket, challenge_b64)
            None -> {
              process.send(conn.parent, Line(line))
              #(conn, True)
            }
          }
      }
  }
}

fn respond_challenge(
  conn: Conn,
  socket: stratus.Connection,
  challenge_b64: String,
) -> #(Conn, Bool) {
  case conn.auth {
    Guest -> {
      process.send(conn.parent, Sasl(SaslFailed))
      finish_and_ready(conn, socket, False)
    }
    OAuth(oauth) ->
      case sasl.parse_challenge(challenge_b64) {
        Error(reason) -> {
          logging.log(
            logging.Warning,
            "SASL challenge parse failed: " <> reason,
          )
          process.send(conn.parent, Sasl(SaslFailed))
          finish_and_ready(conn, socket, False)
        }
        Ok(ch) -> {
          let response = sasl.build_response(ch.nonce, oauth)
          case
            stratus.send_text_message(
              socket,
              "AUTHENTICATE " <> response <> "\r\n",
            )
          {
            Ok(_) -> {
              logging.log(
                logging.Info,
                "SASL challenge response sent for " <> auth_handle(conn),
              )
              #(Conn(..conn, phase: SaslResult), True)
            }
            Error(_) -> {
              process.send(conn.parent, Down("sasl_response_failed"))
              #(conn, False)
            }
          }
        }
      }
  }
}

fn finish_and_ready(
  conn: Conn,
  socket: stratus.Connection,
  after_sasl: Bool,
) -> #(Conn, Bool) {
  case finish_registration(socket, conn, after_sasl) {
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
}

fn handle_433(conn: Conn, socket: stratus.Connection) -> #(Conn, Bool) {
  case conn.auth {
    OAuth(oauth) -> {
      // Prefer reclaiming handle nick with a suffix.
      let base = oauth_session.nick(oauth)
      let nick = base <> "_" <> int.to_string(int.random(999))
      case stratus.send_text_message(socket, "NICK " <> nick <> "\r\n") {
        Ok(_) -> #(Conn(..conn, nick: nick), True)
        Error(_) -> {
          process.send(conn.parent, Down("nick_failed"))
          #(conn, False)
        }
      }
    }
    Guest -> {
      let nick = guest_nick()
      case stratus.send_text_message(socket, "NICK " <> nick <> "\r\n") {
        Ok(_) -> #(Conn(..conn, nick: nick), True)
        Error(_) -> {
          process.send(conn.parent, Down("nick_failed"))
          #(conn, False)
        }
      }
    }
  }
}

fn refresh_oauth_before_sasl(conn: Conn) -> Conn {
  case conn.auth {
    Guest -> conn
    OAuth(session) ->
      // Don't burn single-use refresh tokens when access is still good.
      case oauth.access_still_fresh(session, 120) {
        True -> {
          logging.log(
            logging.Info,
            "OAuth access still fresh for "
              <> session.handle
              <> " — skip refresh",
          )
          conn
        }
        False -> attempt_oauth_refresh(conn, session)
      }
  }
}

fn attempt_oauth_refresh(conn: Conn, session: OAuthSession) -> Conn {
  case oauth.refresh(session) {
    Ok(next) -> apply_refreshed_auth(conn, next)
    Error("missing_refresh") -> conn
    Error(reason) ->
      case oauth.is_invalid_grant(reason) {
        True -> recover_invalid_grant(conn, session, reason)
        False -> {
          logging.log(
            logging.Warning,
            "OAuth refresh failed for "
              <> session.handle
              <> ": "
              <> reason
              <> " — SASL may fail",
          )
          conn
        }
      }
  }
}

fn apply_refreshed_auth(conn: Conn, next: OAuthSession) -> Conn {
  logging.log(logging.Info, "OAuth token refreshed for " <> next.handle)
  // Persist via parent — rotated refresh tokens are single-use.
  process.send(conn.parent, AuthUpdated(next))
  Conn(..conn, auth: OAuth(next))
}

/// Another tab may have already rotated the RT and written disk. Re-load and
/// either use that session or retry refresh once with the newer RT.
fn recover_invalid_grant(
  conn: Conn,
  stale: OAuthSession,
  reason: String,
) -> Conn {
  case conn.session_id {
    "" -> {
      log_refresh_dead(stale, reason)
      conn
    }
    sid ->
      case session_store.load(sid) {
        Error(_) -> {
          log_refresh_dead(stale, reason)
          conn
        }
        Ok(from_disk) -> {
          let same_rt =
            option_eq(from_disk.refresh_token, stale.refresh_token)
          case same_rt {
            True -> {
              // RT is truly dead. Keep access token for SASL if still valid.
              log_refresh_dead(stale, reason)
              conn
            }
            False ->
              case oauth.access_still_fresh(from_disk, 30) {
                True -> {
                  logging.log(
                    logging.Info,
                    "OAuth recovered rotated credentials from disk for "
                      <> from_disk.handle,
                  )
                  process.send(conn.parent, AuthUpdated(from_disk))
                  Conn(..conn, auth: OAuth(from_disk))
                }
                False ->
                  case oauth.refresh(from_disk) {
                    Ok(next) -> apply_refreshed_auth(conn, next)
                    Error(e2) -> {
                      log_refresh_dead(from_disk, e2)
                      // Prefer disk tokens over stale in-memory.
                      process.send(conn.parent, AuthUpdated(from_disk))
                      Conn(..conn, auth: OAuth(from_disk))
                    }
                  }
              }
          }
        }
      }
  }
}

fn log_refresh_dead(session: OAuthSession, reason: String) -> Nil {
  logging.log(
    logging.Warning,
    "OAuth refresh failed for "
      <> session.handle
      <> ": "
      <> reason
      <> " — SASL may fail (re-login if access expired)",
  )
}

fn option_eq(a: Option(String), b: Option(String)) -> Bool {
  case a, b {
    Some(x), Some(y) -> x == y
    None, None -> True
    _, _ -> False
  }
}

fn update_dpop_nonce(conn: Conn, nonce: String) -> Conn {
  case conn.auth {
    Guest -> conn
    OAuth(session) -> {
      let next = oauth_session.with_dpop_nonce(session, nonce)
      process.send(conn.parent, AuthUpdated(next))
      Conn(..conn, auth: OAuth(next))
    }
  }
}

fn has_credentials(conn: Conn) -> Bool {
  case conn.auth {
    OAuth(_) -> True
    Guest -> False
  }
}

fn auth_handle(conn: Conn) -> String {
  case conn.auth {
    OAuth(s) -> s.handle
    Guest -> conn.nick
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
  after_sasl: Bool,
) -> Result(Conn, String) {
  let channels =
    case conn.primary {
      "" -> conn.extras
      p -> [p, ..conn.extras]
    }
    |> unique_strings
    |> list.filter(fn(c) { c != "" && c != "#" })
  let joins = list.map(channels, fn(ch) { "JOIN " <> ch <> "\r\n" })
  let lines = ["CAP END\r\n", ..joins]
  use _ <- result.try(send_all(socket, lines))
  // Prefer handle nick after SASL if still on guest-style nick.
  case after_sasl, conn.auth {
    True, OAuth(oauth) -> {
      let preferred = oauth_session.nick(oauth)
      case preferred != "" && preferred != conn.nick {
        True -> {
          let _ =
            stratus.send_text_message(socket, "NICK " <> preferred <> "\r\n")
          Ok(Conn(..conn, nick: preferred))
        }
        False -> Ok(conn)
      }
    }
    _, _ -> Ok(conn)
  }
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

fn parse_authenticate_challenge(line: String) -> Option(String) {
  let payload = irc_command_payload(line)
  case string.starts_with(payload, "AUTHENTICATE ") {
    False -> None
    True -> {
      let challenge =
        string.drop_start(payload, 13)
        |> string.trim
      case challenge {
        "" | "+" -> None
        c -> Some(c)
      }
    }
  }
}

fn parse_dpop_nonce_notice(line: String) -> Option(String) {
  case string.contains(line, "NOTICE") && string.contains(line, "DPOP_NONCE") {
    False -> None
    True -> extract_after_token(line, "DPOP_NONCE")
  }
}

fn parse_api_bearer_notice(line: String) -> Option(String) {
  case string.contains(line, "NOTICE") && string.contains(line, "API-BEARER") {
    False -> None
    True -> extract_after_token(line, "API-BEARER")
  }
}

fn extract_after_token(line: String, token: String) -> Option(String) {
  case string.split_once(line, token) {
    Error(_) -> None
    Ok(#(_, rest)) -> {
      let rest = string.trim(rest)
      case string.split(rest, " ") {
        [first, ..] if first != "" -> Some(string.trim(first))
        _ ->
          case rest {
            "" -> None
            r -> Some(r)
          }
      }
    }
  }
}

fn irc_command_payload(line: String) -> String {
  let line = string.trim_end(line)
  // Drop IRCv3 tags
  let line = case string.starts_with(line, "@") {
    True ->
      case string.split_once(line, " ") {
        Ok(#(_, rest)) -> rest
        Error(_) -> line
      }
    False -> line
  }
  // Drop :prefix
  case string.starts_with(line, ":") {
    True ->
      case string.split_once(line, " ") {
        Ok(#(_, rest)) -> rest
        Error(_) -> line
      }
    False -> line
  }
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
