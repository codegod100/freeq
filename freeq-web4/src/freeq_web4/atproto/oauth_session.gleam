//// Authenticated AT Protocol session. Carried by the LiveView host for SASL.
////
//// Port of freeq-web3 `Atproto.OAuthSession`.

import freeq_web4/atproto/dpop_key.{type DpopKey}
import freeq_web4/irc/render
import gleam/dynamic/decode
import gleam/json
import gleam/option.{type Option, None, Some}

/// Authenticated AT Protocol session used for SASL and DPoP-protected XRPC.
pub type OAuthSession {
  OAuthSession(
    /// Account DID (`did:plc:…` / `did:web:…`).
    did: String,
    /// Human handle (e.g. `user.bsky.social`).
    handle: String,
    /// OAuth access token (Bearer / DPoP).
    access_token: String,
    /// User's PDS base URL.
    pds_url: String,
    /// Ed25519 keypair for DPoP proofs.
    dpop_key: DpopKey,
    /// Last DPoP nonce from the PDS (if any).
    dpop_nonce: Option(String),
    /// OAuth refresh token for silent renewal.
    refresh_token: Option(String),
    /// AS token endpoint (for refresh).
    token_endpoint: Option(String),
    /// OAuth client_id used at authorize time.
    client_id: Option(String),
  )
}

/// IRC nick derived from the handle (sanitized).
pub fn nick(session: OAuthSession) -> String {
  render.sanitize_nick(session.handle)
}

/// JSON object for disk persistence.
pub fn to_json(session: OAuthSession) -> json.Json {
  json.object([
    #("did", json.string(session.did)),
    #("handle", json.string(session.handle)),
    #("access_token", json.string(session.access_token)),
    #("pds_url", json.string(session.pds_url)),
    #("dpop_key", json.string(dpop_key.serialize(session.dpop_key))),
    #("dpop_nonce", opt_string(session.dpop_nonce)),
    #("refresh_token", opt_string(session.refresh_token)),
    #("token_endpoint", opt_string(session.token_endpoint)),
    #("client_id", opt_string(session.client_id)),
  ])
}

pub fn to_string(session: OAuthSession) -> String {
  json.to_string(to_json(session))
}

/// Parse from JSON string (session store).
pub fn from_string(raw: String) -> Result(OAuthSession, String) {
  case json.parse(raw, decoder()) {
    Ok(s) -> Ok(s)
    Error(_) -> Error("invalid oauth session json")
  }
}

pub fn with_dpop_nonce(session: OAuthSession, nonce: String) -> OAuthSession {
  OAuthSession(..session, dpop_nonce: Some(nonce))
}

pub fn with_tokens(
  session: OAuthSession,
  access: String,
  refresh: Option(String),
  nonce: Option(String),
) -> OAuthSession {
  OAuthSession(
    ..session,
    access_token: access,
    refresh_token: case refresh {
      Some(r) if r != "" -> Some(r)
      _ -> session.refresh_token
    },
    dpop_nonce: case nonce {
      Some(n) if n != "" -> Some(n)
      _ -> session.dpop_nonce
    },
  )
}

fn opt_string(opt: Option(String)) -> json.Json {
  case opt {
    Some(s) -> json.string(s)
    None -> json.null()
  }
}

fn decoder() -> decode.Decoder(OAuthSession) {
  use did <- decode.field("did", decode.string)
  use handle <- decode.field("handle", decode.string)
  use access_token <- decode.field("access_token", decode.string)
  use pds_url <- decode.field("pds_url", decode.string)
  use dpop_raw <- decode.field("dpop_key", decode.string)
  use dpop_nonce <- decode.optional_field(
    "dpop_nonce",
    None,
    decode.optional(decode.string),
  )
  use refresh_token <- decode.optional_field(
    "refresh_token",
    None,
    decode.optional(decode.string),
  )
  use token_endpoint <- decode.optional_field(
    "token_endpoint",
    None,
    decode.optional(decode.string),
  )
  use client_id <- decode.optional_field(
    "client_id",
    None,
    decode.optional(decode.string),
  )
  case dpop_key.deserialize(dpop_raw) {
    Ok(key) ->
      decode.success(OAuthSession(
        did:,
        handle:,
        access_token:,
        pds_url:,
        dpop_key: key,
        dpop_nonce: flatten_opt(dpop_nonce),
        refresh_token: flatten_opt(refresh_token),
        token_endpoint: flatten_opt(token_endpoint),
        client_id: flatten_opt(client_id),
      ))
    Error(reason) -> decode.failure(dummy_session(), reason)
  }
}

fn flatten_opt(opt: Option(String)) -> Option(String) {
  case opt {
    Some(s) if s != "" -> Some(s)
    _ -> None
  }
}

fn dummy_session() -> OAuthSession {
  // Only used as decode.failure placeholder — never returned as Ok.
  let key = dpop_key.generate()
  OAuthSession(
    did: "",
    handle: "",
    access_token: "",
    pds_url: "",
    dpop_key: key,
    dpop_nonce: None,
    refresh_token: None,
    token_endpoint: None,
    client_id: None,
  )
}
