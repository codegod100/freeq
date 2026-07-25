//// SASL ATPROTO-CHALLENGE response builder.
////
//// Port of freeq-web3 `Atproto.Sasl`.

import freeq_web4/atproto/dpop_key
import freeq_web4/atproto/oauth_session.{type OAuthSession}
import freeq_web4/atproto/util as atutil
import gleam/bit_array
import gleam/dynamic/decode
import gleam/json
import gleam/option.{Some}
import gleam/result

/// Server SASL challenge payload for `ATPROTO-CHALLENGE` (decoded JSON).
pub type Challenge {
  Challenge(
    /// freeq-server session id bound into the challenge.
    session_id: String,
    /// One-time random nonce; must not be replayed.
    nonce: String,
    /// Unix timestamp; validity window is ≤ 60s on the server.
    timestamp: Int,
  )
}

/// Parse the server's AUTHENTICATE challenge (base64url JSON).
pub fn parse_challenge(challenge_b64: String) -> Result(Challenge, String) {
  use bin <- result.try(case bit_array.base64_url_decode(challenge_b64) {
    Ok(b) -> Ok(b)
    Error(_) ->
      case bit_array.base64_decode(challenge_b64) {
        Ok(b) -> Ok(b)
        Error(_) -> Error("challenge not base64")
      }
  })
  use json_str <- result.try(case bit_array.to_string(bin) {
    Ok(s) -> Ok(s)
    Error(_) -> Error("challenge not utf8")
  })
  case
    json.parse(json_str, {
      use session_id <- decode.optional_field("session_id", "", decode.string)
      use nonce <- decode.field("nonce", decode.string)
      use timestamp <- decode.optional_field("timestamp", 0, decode.int)
      decode.success(Challenge(session_id:, nonce:, timestamp:))
    })
  {
    Ok(ch) -> Ok(ch)
    Error(_) -> Error("challenge json invalid")
  }
}

/// Build the SASL response payload for the given challenge nonce + OAuth session.
///
/// The DPoP proof is for GET `/xrpc/com.atproto.server.getSession` on the PDS.
pub fn build_response(challenge_nonce: String, oauth: OAuthSession) -> String {
  let get_session_url =
    atutil.trim_slash(oauth.pds_url) <> "/xrpc/com.atproto.server.getSession"
  let dpop_proof =
    dpop_key.proof(
      oauth.dpop_key,
      "GET",
      get_session_url,
      oauth.dpop_nonce,
      Some(oauth.access_token),
    )
  let payload =
    json.object([
      #("did", json.string(oauth.did)),
      #("signature", json.string(oauth.access_token)),
      #("method", json.string("pds-oauth")),
      #("pds_url", json.string(oauth.pds_url)),
      #("dpop_proof", json.string(dpop_proof)),
      #("challenge_nonce", json.string(challenge_nonce)),
    ])
  payload
  |> json.to_string
  |> bit_array.from_string
  |> bit_array.base64_url_encode(False)
}
