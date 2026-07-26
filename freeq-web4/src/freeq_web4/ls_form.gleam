//// Lightspeed form-field escape used by freeq-web4's browser runtime.
////
//// `lightspeed/form.parse_payload` splits on raw `=` / `&` and does **not**
//// percent-decode. The browser therefore escapes those characters (and `%`
//// so the transform is reversible) before joining `name=value&…` pairs.
//// Server-side readers must call `unescape` on every field value.

import gleam/result
import gleam/string
import lightspeed/form.{type FormData, type FormError}

/// Escape a field name or value for a Lightspeed form payload.
///
/// Encode order: `%` first, then `&`, then `=` (so decode is unambiguous).
pub fn escape(s: String) -> String {
  s
  |> string.replace("%", "%25")
  |> string.replace("&", "%26")
  |> string.replace("=", "%3D")
}

/// Reverse `escape` (and the older client that only escaped `=` / `&`).
///
/// Decode order is the reverse of encode: `%3D` → `=`, `%26` → `&`,
/// then `%25` → `%`.
pub fn unescape(s: String) -> String {
  s
  |> string.replace("%3D", "=")
  |> string.replace("%26", "&")
  |> string.replace("%25", "%")
}

/// `form.require` with Lightspeed field unescape applied.
pub fn require(data: FormData, name: String) -> Result(String, FormError) {
  form.require(data, name)
  |> result.map(unescape)
}
