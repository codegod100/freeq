//// Runtime configuration for freeq-web4.
////
//// Defaults target production freeq-server (`irc.freeq.at`). Override with
//// `FREEQ_UPSTREAM` / `FREEQ_UPSTREAM_REST` / `PORT` for local development.

import envoy
import gleam/int
import gleam/result
import gleam/string

/// Upstream IRC WebSocket URL (guest CAP/NICK/USER + PRIVMSG).
pub fn upstream_ws() -> String {
  envoy.get("FREEQ_UPSTREAM")
  |> result.unwrap("wss://irc.freeq.at/irc")
}

/// Upstream freeq-server REST base (channels + history).
pub fn upstream_rest() -> String {
  envoy.get("FREEQ_UPSTREAM_REST")
  |> result.unwrap("https://irc.freeq.at")
  |> string.trim_end
  |> trim_trailing_slash
}

/// HTTP listen port (default 4004 so web3 can keep 4000).
pub fn port() -> Int {
  case envoy.get("PORT") {
    Ok(raw) ->
      case int.parse(raw) {
        Ok(n) if n > 0 && n < 65_536 -> n
        _ -> 4004
      }
    Error(_) -> 4004
  }
}

fn trim_trailing_slash(s: String) -> String {
  case string.ends_with(s, "/") {
    True -> string.drop_end(s, 1)
    False -> s
  }
}
