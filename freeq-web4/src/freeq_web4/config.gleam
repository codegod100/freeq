//// Runtime configuration for freeq-web4.
////
//// Defaults target production freeq-server (`irc.freeq.at`). Override with
//// `FREEQ_UPSTREAM` / `FREEQ_UPSTREAM_REST` / `PORT` / `FREEQ_PUBLIC_URL`
//// for local development.

import envoy
import gleam/int
import gleam/option.{type Option, None, Some}
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

/// Public base URL for OAuth client_id / redirect_uri.
/// When unset, derived from the request Host header.
pub fn public_url() -> Option(String) {
  case envoy.get("FREEQ_PUBLIC_URL") {
    Ok(url) ->
      case string.trim(url) {
        "" -> None
        u -> Some(trim_trailing_slash(u))
      }
    Error(_) -> None
  }
}

/// Pending OAuth (PKCE) disk store directory.
pub fn pending_oauth_dir() -> String {
  envoy.get("FREEQ_WEB4_PENDING_OAUTH_DIR")
  |> result.unwrap(".dev-data/web4-pending-oauth")
}

/// Persisted OAuth session credentials directory.
pub fn sessions_dir() -> String {
  envoy.get("FREEQ_WEB4_SESSIONS_DIR")
  |> result.unwrap(".dev-data/web4-sessions")
}

/// HTTP(S) origin of freeq-server for MoQ media (`/av/moq`).
///
/// The BFF does not terminate MoQ WebSockets; the browser dials this origin
/// directly. Override with `FREEQ_AV_ORIGIN`; default is derived from
/// `FREEQ_UPSTREAM_REST`.
pub fn av_origin() -> String {
  case envoy.get("FREEQ_AV_ORIGIN") {
    Ok(origin) ->
      case string.trim(origin) {
        "" -> av_origin_from_rest()
        o -> trim_trailing_slash(o)
      }
    Error(_) -> av_origin_from_rest()
  }
}

fn av_origin_from_rest() -> String {
  let base = upstream_rest()
  case string.split_once(base, "://") {
    Error(_) -> base
    Ok(#(scheme, rest)) -> {
      let hostport = case string.split_once(rest, "/") {
        Ok(#(hp, _)) -> hp
        Error(_) -> rest
      }
      case hostport {
        "" -> base
        hp -> scheme <> "://" <> hp
      }
    }
  }
}

fn trim_trailing_slash(s: String) -> String {
  case string.ends_with(s, "/") {
    True -> string.drop_end(s, 1)
    False -> s
  }
}
