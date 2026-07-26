//// AT Protocol profile avatar fetch (public AppView API).
////
//// Used to show Bluesky avatars for channel members / message authors who
//// authenticated with a DID (`account` tag, extended-join, self SASL), or
//// whose IRC nick is already a handle (e.g. `chadfowler.com`).
////
//// Also builds deterministic SVG fallbacks for guests (no AT avatar).

import gleam/dynamic/decode
import gleam/http
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam/uri

const public_api = "https://public.api.bsky.app"

/// Minimal AT profile used for avatars.
pub type Profile {
  Profile(did: String, handle: String, avatar: String)
}

/// Fetch profile for a DID or handle via `app.bsky.actor.getProfile`.
pub fn fetch_profile(did_or_handle: String) -> Option(Profile) {
  let actor = string.trim(did_or_handle)
  case actor == "" || !looks_like_actor(actor) {
    True -> None
    False -> {
      let url =
        public_api
        <> "/xrpc/app.bsky.actor.getProfile?actor="
        <> uri.percent_encode(actor)
      case get_json(url) {
        Error(_) -> None
        Ok(body) -> parse_profile(body)
      }
    }
  }
}

/// Fetch avatar URL only (compat helper).
pub fn fetch_avatar_url(did_or_handle: String) -> Option(String) {
  case fetch_profile(did_or_handle) {
    Some(Profile(avatar: a, ..)) if a != "" -> Some(a)
    _ -> None
  }
}

/// True for DIDs (`did:…`) and plausible handles (`alice.bsky.social`,
/// `chadfowler.com`). IRC nicks from freeq's handle→nick sanitizer keep dots.
pub fn looks_like_actor(s: String) -> Bool {
  let s = string.trim(s)
  case s {
    "" -> False
    _ ->
      case string.starts_with(s, "did:") {
        True -> string.length(s) > 8
        False ->
          string.contains(s, ".")
          && !string.contains(s, " ")
          && !string.starts_with(s, "#")
          && !string.starts_with(s, "&")
          && !string.starts_with(s, ":")
      }
  }
}

/// First grapheme of a nick for fallback initials (uppercase).
pub fn nick_initial(nick: String) -> String {
  case string.to_graphemes(string.trim(nick)) {
    [g, ..] -> string.uppercase(g)
    [] -> "?"
  }
}

/// Deterministic data-URI avatar for guests (no AT profile photo).
///
/// Flat solid nick-color disk + initial (no gradients/shadows).
/// `color_class` is the IRC nick palette (`n1`…`n8`).
pub fn fallback_avatar_data_uri(nick: String, color_class: String) -> String {
  let letter = xml_escape(nick_initial(nick))
  let fill = palette_for_class(color_class)
  let svg =
    "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 64 64\" width=\"64\" height=\"64\">"
    <> "<circle cx=\"32\" cy=\"32\" r=\"32\" fill=\""
    <> fill
    <> "\"/>"
    <> "<text x=\"32\" y=\"33\" text-anchor=\"middle\" dominant-baseline=\"middle\" "
    <> "font-family=\"ui-sans-serif,system-ui,-apple-system,Segoe UI,sans-serif\" "
    <> "font-size=\"28\" font-weight=\"700\" fill=\"#0e1116\">"
    <> letter
    <> "</text>"
    <> "</svg>"
  "data:image/svg+xml;charset=utf-8," <> uri.percent_encode(svg)
}

/// Solid fill matching priv/static/app.css `--nick-N`.
fn palette_for_class(color_class: String) -> String {
  case color_class {
    "n1" -> "#7ab7ff"
    "n2" -> "#f78b6c"
    "n3" -> "#c792ea"
    "n4" -> "#ffd166"
    "n5" -> "#06d6a0"
    "n6" -> "#ef476f"
    "n7" -> "#f4a261"
    "n8" -> "#90e0ef"
    _ -> "#6b7280"
  }
}

fn xml_escape(s: String) -> String {
  s
  |> string.replace("&", "&amp;")
  |> string.replace("<", "&lt;")
  |> string.replace(">", "&gt;")
  |> string.replace("\"", "&quot;")
  |> string.replace("'", "&apos;")
}

/// Cache keys to store an avatar under after a successful profile fetch.
/// Includes the query actor, resolved DID, and handle so lookups by nick
/// (`chadfowler.com`) or by `account` DID both hit.
pub fn avatar_cache_keys(query: String, profile: Profile) -> List(String) {
  [string.trim(query), profile.did, profile.handle]
  |> list.filter(fn(k) { string.trim(k) != "" })
  |> list.unique
}

fn parse_profile(body: String) -> Option(Profile) {
  let decoder = {
    use did <- decode.optional_field("did", "", decode.string)
    use handle <- decode.optional_field("handle", "", decode.string)
    use avatar <- decode.optional_field("avatar", "", decode.string)
    decode.success(Profile(did: did, handle: handle, avatar: avatar))
  }
  case json.parse(body, decoder) {
    Ok(Profile(did: d, ..) as p) if d != "" -> Some(p)
    _ -> None
  }
}

fn get_json(url: String) -> Result(String, String) {
  case request.to(url) {
    Error(_) -> Error("bad_url")
    Ok(req) -> {
      let req =
        req
        |> request.set_method(http.Get)
        |> request.set_header("accept", "application/json")
      case
        httpc.configure()
        |> httpc.timeout(6000)
        |> httpc.dispatch(req)
      {
        Ok(resp) if resp.status == 200 -> Ok(resp.body)
        Ok(resp) -> Error("http_" <> int.to_string(resp.status))
        Error(_) -> Error("request_failed")
      }
    }
  }
}
