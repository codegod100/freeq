//// Ed25519 keypair for DPoP (Demonstrating Proof-of-Possession) proofs.
////
//// Port of freeq-web3 `Atproto.DpopKey` / freeq-web2 `Atproto::DpopKey`.

import freeq_web4/atproto/util as atutil
import gleam/bit_array
import gleam/crypto
import gleam/json
import gleam/option.{type Option, Some}
import gleam/string

/// Ed25519 keypair used to sign DPoP JWT proofs (private seed + public key).
pub type DpopKey {
  DpopKey(
    /// 32-byte Ed25519 private seed.
    private_key: BitArray,
    /// 32-byte Ed25519 public key.
    public_key: BitArray,
  )
}

/// Generate a fresh Ed25519 keypair (32-byte seed + public).
pub fn generate() -> DpopKey {
  let #(public_key, private_key) = ed25519_generate()
  DpopKey(private_key:, public_key:)
}

/// Restore from unpadded base64url private seed (or raw 32-byte binary).
pub fn deserialize(str: String) -> Result(DpopKey, String) {
  case bit_array.base64_url_decode(str) {
    Ok(bytes) ->
      case bit_array.byte_size(bytes) {
        32 -> {
          let public_key = ed25519_public(bytes)
          Ok(DpopKey(private_key: bytes, public_key:))
        }
        _ -> Error("invalid dpop_key length")
      }
    Error(_) ->
      case bit_array.from_string(str) {
        bits ->
          case bit_array.byte_size(bits) {
            32 -> {
              let public_key = ed25519_public(bits)
              Ok(DpopKey(private_key: bits, public_key:))
            }
            _ -> Error("invalid dpop_key")
          }
      }
  }
}

/// Serialize private seed as unpadded base64url.
pub fn serialize(key: DpopKey) -> String {
  bit_array.base64_url_encode(key.private_key, False)
}

/// JWK representation for the DPoP JWT header.
pub fn jwk(key: DpopKey) -> json.Json {
  json.object([
    #("kty", json.string("OKP")),
    #("crv", json.string("Ed25519")),
    #("x", json.string(bit_array.base64_url_encode(key.public_key, False))),
  ])
}

/// Build a DPoP proof JWT for the given HTTP method and URL.
///
/// - `nonce`: DPoP nonce from the resource server (optional)
/// - `access_token`: when set, includes `ath` (SHA-256 of token, base64url)
pub fn proof(
  key: DpopKey,
  method: String,
  url: String,
  nonce: Option(String),
  access_token: Option(String),
) -> String {
  let method = string.uppercase(method)
  let header =
    json.object([
      #("typ", json.string("dpop+jwt")),
      #("alg", json.string("EdDSA")),
      #("jwk", jwk(key)),
    ])

  let jti = bit_array.base64_url_encode(crypto.strong_random_bytes(16), False)
  let iat = atutil.unix_seconds()

  let base = [
    #("htm", json.string(method)),
    #("htu", json.string(url)),
    #("iat", json.int(iat)),
    #("jti", json.string(jti)),
  ]
  let base = case nonce {
    Some(n) if n != "" -> [#("nonce", json.string(n)), ..base]
    _ -> base
  }
  let base = case access_token {
    Some(tok) if tok != "" -> {
      let ath =
        crypto.hash(crypto.Sha256, <<tok:utf8>>)
        |> bit_array.base64_url_encode(False)
      [#("ath", json.string(ath)), ..base]
    }
    _ -> base
  }

  let header_b64 = b64url_json(header)
  let payload_b64 = b64url_json(json.object(base))
  let signing_input = header_b64 <> "." <> payload_b64
  let signature = ed25519_sign(<<signing_input:utf8>>, key.private_key)
  signing_input <> "." <> bit_array.base64_url_encode(signature, False)
}

fn b64url_json(value: json.Json) -> String {
  value
  |> json.to_string
  |> bit_array.from_string
  |> bit_array.base64_url_encode(False)
}

@external(erlang, "freeq_web4_ffi", "ed25519_generate")
fn ed25519_generate() -> #(BitArray, BitArray)

@external(erlang, "freeq_web4_ffi", "ed25519_public")
fn ed25519_public(seed: BitArray) -> BitArray

@external(erlang, "freeq_web4_ffi", "ed25519_sign")
fn ed25519_sign(msg: BitArray, seed: BitArray) -> BitArray
