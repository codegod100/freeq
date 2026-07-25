//// Browser session cookie (`freeq_session`) helpers for OAuth + LiveView.

import freeq_web4/atproto/util as atutil
import gleam/http/cookie
import gleam/http/request
import gleam/http/response
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

pub const cookie_name = "freeq_session"

/// Read `freeq_session` from the request Cookie header, or None.
pub fn from_request(req: request.Request(body)) -> Option(String) {
  request.get_cookies(req)
  |> list.key_find(cookie_name)
  |> option.from_result
  |> option.then(fn(v) {
    case string.trim(v) {
      "" -> None
      s -> Some(s)
    }
  })
}

/// Ensure a session id: existing cookie or freshly generated.
pub fn ensure_id(req: request.Request(body)) -> String {
  case from_request(req) {
    Some(id) -> id
    None -> new_id()
  }
}

pub fn new_id() -> String {
  atutil.random_b64url(16)
}

/// Attach Set-Cookie for the session id (HttpOnly, Path=/, SameSite=Lax).
///
/// Secure is left off so local HTTP (127.0.0.1) works; production behind
/// TLS still benefits from SameSite=Lax + HttpOnly.
pub fn set_on_response(
  resp: response.Response(body),
  session_id: String,
) -> response.Response(body) {
  let attrs =
    cookie.Attributes(
      max_age: Some(60 * 60 * 24 * 30),
      domain: None,
      path: Some("/"),
      secure: False,
      http_only: True,
      same_site: Some(cookie.Lax),
    )
  let header = cookie.set_header(cookie_name, session_id, attrs)
  response.prepend_header(resp, "set-cookie", header)
}

/// Clear the session cookie (logout).
pub fn clear_on_response(
  resp: response.Response(body),
) -> response.Response(body) {
  let attrs =
    cookie.Attributes(
      max_age: Some(0),
      domain: None,
      path: Some("/"),
      secure: False,
      http_only: True,
      same_site: Some(cookie.Lax),
    )
  let header = cookie.set_header(cookie_name, "", attrs)
  response.prepend_header(resp, "set-cookie", header)
}
