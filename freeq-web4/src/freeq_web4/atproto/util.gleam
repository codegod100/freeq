//// Shared helpers for AT Protocol OAuth / DPoP / SASL.

import gleam/bit_array
import gleam/crypto
import gleam/string
import gleam/uri

/// Unix epoch seconds (for JWT `iat` and store TTLs).
pub fn unix_seconds() -> Int {
  system_time_seconds()
}

/// Unpadded base64url of random bytes.
pub fn random_b64url(byte_count: Int) -> String {
  crypto.strong_random_bytes(byte_count)
  |> bit_array.base64_url_encode(False)
}

/// RFC 3986 percent-encoding (not form-urlencoded — no `+` for spaces).
pub fn urlencode(s: String) -> String {
  uri.percent_encode(s)
}

/// Trim trailing `/` from a URL/base.
pub fn trim_slash(s: String) -> String {
  case string.ends_with(s, "/") {
    True -> string.drop_end(s, 1)
    False -> s
  }
}

/// Truncate body for error messages.
pub fn trunc_body(body: String) -> String {
  case string.length(body) > 200 {
    True -> string.slice(body, 0, 200)
    False -> body
  }
}

@external(erlang, "freeq_web4_ffi", "system_time_seconds")
fn system_time_seconds() -> Int
