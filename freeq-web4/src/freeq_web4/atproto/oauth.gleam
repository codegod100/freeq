//// AT Protocol OAuth flow: handle resolution → auth server discovery → PAR →
//// token exchange. Port of freeq-web3 `Atproto.OAuth`.

import freeq_web4/atproto/dpop_key.{type DpopKey}
import freeq_web4/atproto/oauth_session.{type OAuthSession, OAuthSession}
import freeq_web4/atproto/util as atutil
import gleam/bit_array
import gleam/crypto
import gleam/dynamic/decode
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/httpc
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// In-flight OAuth login — everything needed for callback completion.
pub type PreparedLogin {
  PreparedLogin(
    /// Authorization server URL to redirect the browser to.
    auth_url: String,
    /// CSRF/state parameter (also keys the pending store).
    state: String,
    /// Registered redirect URI (`…/auth/callback`).
    redirect_uri: String,
    /// OAuth client_id (often the client-metadata URL).
    client_id: String,
    /// PKCE code_verifier (never sent until token exchange).
    code_verifier: String,
    /// AS token endpoint for the code exchange.
    token_endpoint: String,
    /// User's PDS base URL.
    pds_url: String,
    /// Fresh DPoP key for this login.
    dpop_key: DpopKey,
    /// Resolved account DID.
    did: String,
    /// Original handle (display / nick source).
    handle: String,
  )
}

/// Start OAuth for a handle.
pub fn prepare(
  handle: String,
  public_url: String,
) -> Result(PreparedLogin, String) {
  let handle =
    handle
    |> string.trim
    |> drop_at
  use #(did, pds_url) <- result.try(resolve_identity(handle))
  use auth_meta <- result.try(discover_auth_server(pds_url))
  let redirect_uri = atutil.trim_slash(public_url) <> "/auth/callback"
  let client_id = client_id_for(public_url, redirect_uri)
  let #(code_verifier, code_challenge) = generate_pkce()
  let dpop_key = dpop_key.generate()
  let state = atutil.random_b64url(16)
  use par_endpoint <- result.try(map_get(
    auth_meta,
    "pushed_authorization_request_endpoint",
  ))
  use authorization_endpoint <- result.try(map_get(
    auth_meta,
    "authorization_endpoint",
  ))
  use token_endpoint <- result.try(map_get(auth_meta, "token_endpoint"))
  use auth_url <- result.try(push_authorization_request(
    par_endpoint,
    authorization_endpoint,
    client_id,
    redirect_uri,
    code_challenge,
    state,
    handle,
    dpop_key,
  ))
  Ok(PreparedLogin(
    auth_url:,
    state:,
    redirect_uri:,
    client_id:,
    code_verifier:,
    token_endpoint:,
    pds_url:,
    dpop_key:,
    did:,
    handle:,
  ))
}

/// Complete token exchange after the OAuth callback.
pub fn complete(
  prepared: PreparedLogin,
  auth_code: String,
) -> Result(OAuthSession, String) {
  use tokens <- result.try(exchange_code(
    prepared.token_endpoint,
    auth_code,
    prepared.code_verifier,
    prepared.redirect_uri,
    prepared.client_id,
    prepared.dpop_key,
  ))
  case tokens.sub {
    Some(sub) if sub != prepared.did ->
      Error(
        "DID mismatch: resolved " <> prepared.did <> " but token is for " <> sub,
      )
    _ -> {
      let dpop_nonce =
        probe_dpop_nonce(
          prepared.pds_url,
          tokens.access_token,
          prepared.dpop_key,
        )
      Ok(OAuthSession(
        did: prepared.did,
        handle: prepared.handle,
        access_token: tokens.access_token,
        pds_url: prepared.pds_url,
        dpop_key: prepared.dpop_key,
        dpop_nonce: dpop_nonce,
        refresh_token: tokens.refresh_token,
        token_endpoint: Some(prepared.token_endpoint),
        client_id: Some(prepared.client_id),
      ))
    }
  }
}

/// Rebuild a PreparedLogin from pending-oauth store payload (string map via JSON).
pub fn prepared_from_pending(
  data: PendingData,
) -> Result(PreparedLogin, String) {
  use dpop_key <- result.try(dpop_key.deserialize(data.dpop_key))
  Ok(PreparedLogin(
    auth_url: "",
    state: data.state,
    redirect_uri: data.redirect_uri,
    client_id: data.client_id,
    code_verifier: data.code_verifier,
    token_endpoint: data.token_endpoint,
    pds_url: data.pds_url,
    dpop_key:,
    did: data.did,
    handle: data.handle,
  ))
}

/// Serializable pending login fields (disk store keyed by OAuth `state`).
pub type PendingData {
  PendingData(
    handle: String,
    did: String,
    pds_url: String,
    token_endpoint: String,
    redirect_uri: String,
    client_id: String,
    code_verifier: String,
    /// Serialized DPoP private seed (base64url).
    dpop_key: String,
    state: String,
    /// Browser `freeq_session` cookie value to bind after callback.
    freeq_session_id: String,
    /// Unix seconds when the pending entry was created (TTL expiry).
    created_at: Int,
  )
}

pub fn pending_to_json(data: PendingData) -> String {
  json.object([
    #("handle", json.string(data.handle)),
    #("did", json.string(data.did)),
    #("pds_url", json.string(data.pds_url)),
    #("token_endpoint", json.string(data.token_endpoint)),
    #("redirect_uri", json.string(data.redirect_uri)),
    #("client_id", json.string(data.client_id)),
    #("code_verifier", json.string(data.code_verifier)),
    #("dpop_key", json.string(data.dpop_key)),
    #("state", json.string(data.state)),
    #("freeq_session_id", json.string(data.freeq_session_id)),
    #("created_at", json.int(data.created_at)),
  ])
  |> json.to_string
}

pub fn pending_from_json(raw: String) -> Result(PendingData, String) {
  case
    json.parse(raw, {
      use handle <- decode.field("handle", decode.string)
      use did <- decode.field("did", decode.string)
      use pds_url <- decode.field("pds_url", decode.string)
      use token_endpoint <- decode.field("token_endpoint", decode.string)
      use redirect_uri <- decode.field("redirect_uri", decode.string)
      use client_id <- decode.field("client_id", decode.string)
      use code_verifier <- decode.field("code_verifier", decode.string)
      use dpop_key <- decode.field("dpop_key", decode.string)
      use state <- decode.field("state", decode.string)
      use freeq_session_id <- decode.optional_field(
        "freeq_session_id",
        "",
        decode.string,
      )
      use created_at <- decode.optional_field("created_at", 0, decode.int)
      decode.success(PendingData(
        handle:,
        did:,
        pds_url:,
        token_endpoint:,
        redirect_uri:,
        client_id:,
        code_verifier:,
        dpop_key:,
        state:,
        freeq_session_id:,
        created_at:,
      ))
    })
  {
    Ok(d) -> Ok(d)
    Error(_) -> Error("invalid pending oauth json")
  }
}

pub fn prepared_to_pending(
  prepared: PreparedLogin,
  freeq_session_id: String,
) -> PendingData {
  PendingData(
    handle: prepared.handle,
    did: prepared.did,
    pds_url: prepared.pds_url,
    token_endpoint: prepared.token_endpoint,
    redirect_uri: prepared.redirect_uri,
    client_id: prepared.client_id,
    code_verifier: prepared.code_verifier,
    dpop_key: dpop_key.serialize(prepared.dpop_key),
    state: prepared.state,
    freeq_session_id:,
    created_at: atutil.unix_seconds(),
  )
}

/// Seconds until the access token JWT `exp` (None if not a JWT / unparseable).
pub fn access_token_ttl_seconds(session: OAuthSession) -> Option(Int) {
  case jwt_exp(session.access_token) {
    None -> None
    Some(exp) -> Some(exp - atutil.unix_seconds())
  }
}

/// True when the access token should still be usable for SASL without a
/// refresh. Avoids burning single-use refresh tokens on every reconnect.
///
/// `skew_seconds` is the minimum remaining lifetime required (e.g. 120).
pub fn access_still_fresh(session: OAuthSession, skew_seconds: Int) -> Bool {
  case access_token_ttl_seconds(session) {
    Some(ttl) if ttl > skew_seconds -> True
    _ -> False
  }
}

/// True when an OAuth error body is a terminal `invalid_grant` (dead RT).
pub fn is_invalid_grant(reason: String) -> Bool {
  string.contains(reason, "invalid_grant")
}

/// Refresh a DPoP-bound access token.
pub fn refresh(session: OAuthSession) -> Result(OAuthSession, String) {
  let rt = option_str(session.refresh_token)
  let te = option_str(session.token_endpoint)
  let cid = option_str(session.client_id)
  case rt == "" || te == "" || cid == "" {
    True -> Error("missing_refresh")
    False -> {
      let params = [
        #("grant_type", "refresh_token"),
        #("refresh_token", rt),
        #("client_id", cid),
      ]
      // Never send a PDS resource-server nonce to the AS token endpoint —
      // first attempt without nonce; AS returns DPoP-Nonce on 400.
      let dpop_proof =
        dpop_key.proof(session.dpop_key, "POST", te, None, None)
      case post_form(te, params, [#("dpop", dpop_proof)]) {
        Ok(resp) if resp.status == 200 -> apply_token_response(session, resp)
        Ok(resp) if resp.status == 400 || resp.status == 401 ->
          case is_invalid_grant(resp.body) {
            True ->
              Error(
                "OAuth refresh failed ("
                <> int.to_string(resp.status)
                <> "): "
                <> atutil.trunc_body(resp.body),
              )
            False ->
              case header_value(resp.headers, "dpop-nonce") {
                None ->
                  Error(
                    "OAuth refresh failed ("
                    <> int.to_string(resp.status)
                    <> "): "
                    <> atutil.trunc_body(resp.body),
                  )
                Some(nonce) -> {
                  let dpop2 =
                    dpop_key.proof(
                      session.dpop_key,
                      "POST",
                      te,
                      Some(nonce),
                      None,
                    )
                  case post_form(te, params, [#("dpop", dpop2)]) {
                    Ok(resp2) if resp2.status == 200 ->
                      apply_token_response(session, resp2)
                    Ok(resp2) ->
                      Error(
                        "OAuth refresh failed ("
                        <> int.to_string(resp2.status)
                        <> "): "
                        <> atutil.trunc_body(resp2.body),
                      )
                    Error(e) -> Error(e)
                  }
                }
              }
          }
        Ok(resp) ->
          Error(
            "OAuth refresh failed ("
            <> int.to_string(resp.status)
            <> "): "
            <> atutil.trunc_body(resp.body),
          )
        Error(e) -> Error(e)
      }
    }
  }
}

/// Decode JWT `exp` claim (unpadded base64url payload).
fn jwt_exp(token: String) -> Option(Int) {
  case string.split(token, ".") {
    [_, payload, ..] ->
      case bit_array.base64_url_decode(pad_b64url(payload)) {
        Error(_) -> None
        Ok(bits) ->
          case bit_array.to_string(bits) {
            Error(_) -> None
            Ok(raw) ->
              case
                json.parse(raw, {
                  use exp <- decode.optional_field("exp", 0, decode.int)
                  decode.success(exp)
                })
              {
                Ok(exp) if exp > 0 -> Some(exp)
                _ -> None
              }
          }
      }
    _ -> None
  }
}

fn pad_b64url(s: String) -> String {
  let rem = string.length(s) % 4
  case rem {
    0 -> s
    2 -> s <> "=="
    3 -> s <> "="
    _ -> s <> "==="
  }
}

fn apply_token_response(
  session: OAuthSession,
  resp: response.Response(String),
) -> Result(OAuthSession, String) {
  case
    json.parse(resp.body, {
      use access <- decode.optional_field("access_token", "", decode.string)
      use refresh_tok <- decode.optional_field(
        "refresh_token",
        "",
        decode.string,
      )
      decode.success(#(access, refresh_tok))
    })
  {
    Error(_) -> Error("bad token response")
    Ok(#(access, refresh_tok)) -> {
      let access = case access {
        "" -> session.access_token
        a -> a
      }
      let refresh_opt = case refresh_tok {
        "" -> None
        r -> Some(r)
      }
      let dpop_nonce = case header_value(resp.headers, "dpop-nonce") {
        Some(n) -> Some(n)
        None -> probe_dpop_nonce(session.pds_url, access, session.dpop_key)
      }
      Ok(oauth_session.with_tokens(session, access, refresh_opt, dpop_nonce))
    }
  }
}

// ── Identity resolution ────────────────────────────────────────────────────

pub fn resolve_identity(handle: String) -> Result(#(String, String), String) {
  let handle = drop_at(string.trim(handle))
  case resolve_handle(handle) {
    None -> Error("Could not resolve handle: " <> handle)
    Some(did) ->
      case get_text("https://plc.directory/" <> did) {
        Ok(body) ->
          case extract_pds_url(body) {
            None -> Error("No PDS service endpoint in DID document")
            Some(pds_url) -> Ok(#(did, pds_url))
          }
        Error(reason) -> Error(reason)
      }
  }
}

pub fn resolve_handle(handle: String) -> Option(String) {
  case resolve_handle_dns(handle) {
    Some(did) -> Some(did)
    None -> resolve_handle_http(handle)
  }
}

fn resolve_handle_dns(handle: String) -> Option(String) {
  let name = "_atproto." <> handle
  lookup_txt(name)
  |> list.find_map(fn(txt) {
    case extract_did(txt) {
      Some(did) -> Ok(did)
      None -> Error(Nil)
    }
  })
  |> option.from_result
}

fn extract_did(val: String) -> Option(String) {
  let val = string.trim(val)
  case string.starts_with(val, "did=") {
    True -> Some(string.drop_start(val, 4))
    False ->
      case string.starts_with(val, "did:") {
        True -> Some(val)
        False -> None
      }
  }
}

fn resolve_handle_http(handle: String) -> Option(String) {
  let url = "https://" <> handle <> "/.well-known/atproto-did"
  case get_text(url) {
    Ok(body) -> {
      let body = string.trim(body)
      case string.starts_with(body, "did:") {
        True -> Some(body)
        False -> None
      }
    }
    Error(_) -> None
  }
}

fn discover_auth_server(
  pds_url: String,
) -> Result(List(#(String, String)), String) {
  let pr_url =
    atutil.trim_slash(pds_url) <> "/.well-known/oauth-protected-resource"
  use pr_body <- result.try(get_text(pr_url))
  case auth_servers_from(pr_body) {
    [] -> Error("No authorization servers listed")
    [auth_server, ..] -> {
      let as_url =
        atutil.trim_slash(auth_server)
        <> "/.well-known/oauth-authorization-server"
      fetch_json_map(as_url)
    }
  }
}

fn auth_servers_from(raw: String) -> List(String) {
  case
    json.parse(raw, {
      use servers <- decode.optional_field(
        "authorization_servers",
        [],
        decode.list(decode.string),
      )
      use servers2 <- decode.optional_field(
        "authorizationServers",
        [],
        decode.list(decode.string),
      )
      decode.success(case servers {
        [] -> servers2
        s -> s
      })
    })
  {
    Ok(list) -> list
    Error(_) -> []
  }
}

fn extract_pds_url(raw: String) -> Option(String) {
  case
    json.parse(raw, {
      use services <- decode.optional_field(
        "service",
        [],
        decode.list({
          use id <- decode.optional_field("id", "", decode.string)
          use type_ <- decode.optional_field("type", "", decode.string)
          use endpoint <- decode.optional_field(
            "serviceEndpoint",
            "",
            decode.string,
          )
          decode.success(#(id, type_, endpoint))
        }),
      )
      decode.success(services)
    })
  {
    Ok(services) ->
      list.find_map(services, fn(svc) {
        let #(id, type_, endpoint) = svc
        case id == "#atproto_pds" || type_ == "AtprotoPersonalDataServer" {
          True if endpoint != "" -> Ok(endpoint)
          _ -> Error(Nil)
        }
      })
      |> option.from_result
    Error(_) -> None
  }
}

// ── PAR / token ────────────────────────────────────────────────────────────

pub fn generate_pkce() -> #(String, String) {
  let verifier = atutil.random_b64url(32)
  let challenge =
    crypto.hash(crypto.Sha256, <<verifier:utf8>>)
    |> bit_array.base64_url_encode(False)
  #(verifier, challenge)
}

fn push_authorization_request(
  par_endpoint: String,
  authorization_endpoint: String,
  client_id: String,
  redirect_uri: String,
  code_challenge: String,
  state: String,
  login_hint: String,
  key: DpopKey,
) -> Result(String, String) {
  let params = [
    #("response_type", "code"),
    #("client_id", client_id),
    #("redirect_uri", redirect_uri),
    #("code_challenge", code_challenge),
    #("code_challenge_method", "S256"),
    #("scope", "atproto transition:generic"),
    #("state", state),
    #("login_hint", login_hint),
  ]
  let dpop_proof = dpop_key.proof(key, "POST", par_endpoint, None, None)
  case post_form(par_endpoint, params, [#("dpop", dpop_proof)]) {
    Ok(resp) if resp.status >= 200 && resp.status < 300 ->
      parse_par_response(resp.body, authorization_endpoint, client_id)
    Ok(resp) if resp.status == 400 || resp.status == 401 ->
      case header_value(resp.headers, "dpop-nonce") {
        None ->
          Error(
            "PAR failed ("
            <> int.to_string(resp.status)
            <> "): "
            <> atutil.trunc_body(resp.body),
          )
        Some(nonce) -> {
          let dpop2 =
            dpop_key.proof(key, "POST", par_endpoint, Some(nonce), None)
          case post_form(par_endpoint, params, [#("dpop", dpop2)]) {
            Ok(resp2) if resp2.status >= 200 && resp2.status < 300 ->
              parse_par_response(resp2.body, authorization_endpoint, client_id)
            Ok(resp2) ->
              Error(
                "PAR failed ("
                <> int.to_string(resp2.status)
                <> "): "
                <> atutil.trunc_body(resp2.body),
              )
            Error(e) -> Error(e)
          }
        }
      }
    Ok(resp) ->
      Error(
        "PAR failed ("
        <> int.to_string(resp.status)
        <> "): "
        <> atutil.trunc_body(resp.body),
      )
    Error(e) -> Error(e)
  }
}

fn parse_par_response(
  body: String,
  authorization_endpoint: String,
  client_id: String,
) -> Result(String, String) {
  case
    json.parse(body, {
      use request_uri <- decode.optional_field("request_uri", "", decode.string)
      decode.success(request_uri)
    })
  {
    Ok(request_uri) if request_uri != "" -> {
      let auth_url =
        authorization_endpoint
        <> "?client_id="
        <> atutil.urlencode(client_id)
        <> "&request_uri="
        <> atutil.urlencode(request_uri)
      Ok(auth_url)
    }
    _ -> Error("No request_uri in PAR response")
  }
}

/// Subset of the OAuth token-endpoint JSON used after code exchange.
type TokenResult {
  TokenResult(
    access_token: String,
    refresh_token: Option(String),
    /// Token `sub` claim — must match the resolved DID when present.
    sub: Option(String),
  )
}

fn exchange_code(
  token_endpoint: String,
  code: String,
  code_verifier: String,
  redirect_uri: String,
  client_id: String,
  key: DpopKey,
) -> Result(TokenResult, String) {
  let params = [
    #("grant_type", "authorization_code"),
    #("code", code),
    #("redirect_uri", redirect_uri),
    #("client_id", client_id),
    #("code_verifier", code_verifier),
  ]
  let dpop_proof = dpop_key.proof(key, "POST", token_endpoint, None, None)
  case post_form(token_endpoint, params, [#("dpop", dpop_proof)]) {
    Ok(resp) if resp.status >= 200 && resp.status < 300 ->
      parse_token_response(resp.body)
    Ok(resp) if resp.status == 400 || resp.status == 401 ->
      case header_value(resp.headers, "dpop-nonce") {
        None ->
          Error("Token exchange failed (" <> int.to_string(resp.status) <> ")")
        Some(nonce) -> {
          let dpop2 =
            dpop_key.proof(key, "POST", token_endpoint, Some(nonce), None)
          case post_form(token_endpoint, params, [#("dpop", dpop2)]) {
            Ok(resp2) if resp2.status >= 200 && resp2.status < 300 ->
              parse_token_response(resp2.body)
            Ok(resp2) ->
              Error(
                "Token exchange failed ("
                <> int.to_string(resp2.status)
                <> "): "
                <> atutil.trunc_body(resp2.body),
              )
            Error(e) -> Error(e)
          }
        }
      }
    Ok(resp) ->
      Error(
        "Token exchange failed ("
        <> int.to_string(resp.status)
        <> "): "
        <> atutil.trunc_body(resp.body),
      )
    Error(e) -> Error(e)
  }
}

fn parse_token_response(body: String) -> Result(TokenResult, String) {
  case
    json.parse(body, {
      use access_token <- decode.field("access_token", decode.string)
      use refresh_token <- decode.optional_field(
        "refresh_token",
        "",
        decode.string,
      )
      use sub <- decode.optional_field("sub", "", decode.string)
      decode.success(#(access_token, refresh_token, sub))
    })
  {
    Ok(#(access, refresh, sub)) ->
      Ok(
        TokenResult(
          access_token: access,
          refresh_token: case refresh {
            "" -> None
            r -> Some(r)
          },
          sub: case sub {
            "" -> None
            s -> Some(s)
          },
        ),
      )
    Error(_) -> Error("bad token response")
  }
}

pub fn probe_dpop_nonce(
  pds_url: String,
  access_token: String,
  key: DpopKey,
) -> Option(String) {
  let url = atutil.trim_slash(pds_url) <> "/xrpc/com.atproto.server.getSession"
  let proof = dpop_key.proof(key, "GET", url, None, Some(access_token))
  case
    get_with_headers(url, [
      #("authorization", "DPoP " <> access_token),
      #("dpop", proof),
    ])
  {
    Ok(resp) -> header_value(resp.headers, "dpop-nonce")
    Error(_) -> None
  }
}

// ── HTTP helpers ───────────────────────────────────────────────────────────

fn client_id_for(public_url: String, redirect_uri: String) -> String {
  case
    string.contains(public_url, "localhost")
    || string.contains(public_url, "127.0.0.1")
  {
    True -> {
      let scope = "atproto transition:generic"
      "http://localhost?redirect_uri="
      <> atutil.urlencode(redirect_uri)
      <> "&scope="
      <> atutil.urlencode(scope)
    }
    False ->
      atutil.trim_slash(public_url) <> "/.well-known/oauth-client-metadata"
  }
}

fn drop_at(s: String) -> String {
  case string.starts_with(s, "@") {
    True -> string.drop_start(s, 1)
    False -> s
  }
}

fn map_get(
  map: List(#(String, String)),
  key: String,
) -> Result(String, String) {
  case list.key_find(map, key) {
    Ok(v) if v != "" -> Ok(v)
    _ -> Error("missing " <> key)
  }
}

fn fetch_json_map(url: String) -> Result(List(#(String, String)), String) {
  case get_text(url) {
    Ok(body) -> parse_oauth_meta_map(body)
    Error(e) -> Error(e)
  }
}

fn parse_oauth_meta_map(
  body: String,
) -> Result(List(#(String, String)), String) {
  let keys = [
    "issuer",
    "authorization_endpoint",
    "token_endpoint",
    "pushed_authorization_request_endpoint",
    "jwks_uri",
    "registration_endpoint",
  ]
  let pairs =
    list.filter_map(keys, fn(key) {
      case
        json.parse(body, {
          use v <- decode.optional_field(key, "", decode.string)
          decode.success(v)
        })
      {
        Ok(v) if v != "" -> Ok(#(key, v))
        _ -> Error(Nil)
      }
    })
  case pairs {
    [] -> Error("empty oauth authorization server metadata")
    _ -> Ok(pairs)
  }
}

fn get_text(url: String) -> Result(String, String) {
  case request.to(url) {
    Error(_) -> Error("bad_url")
    Ok(req) -> {
      let req =
        req
        |> request.set_method(http.Get)
        |> request.set_header("accept", "application/json")
      case httpc.send(req) {
        Ok(resp) if resp.status >= 200 && resp.status < 300 -> Ok(resp.body)
        Ok(resp) ->
          Error(
            "GET " <> url <> " failed (" <> int.to_string(resp.status) <> ")",
          )
        Error(_) -> Error("GET " <> url <> " failed")
      }
    }
  }
}

fn get_with_headers(
  url: String,
  headers: List(#(String, String)),
) -> Result(response.Response(String), String) {
  case request.to(url) {
    Error(_) -> Error("bad_url")
    Ok(req) -> {
      let req =
        list.fold(headers, request.set_method(req, http.Get), fn(r, h) {
          request.set_header(r, h.0, h.1)
        })
      case httpc.send(req) {
        Ok(resp) -> Ok(resp)
        Error(_) -> Error("request_failed")
      }
    }
  }
}

fn post_form(
  url: String,
  params: List(#(String, String)),
  headers: List(#(String, String)),
) -> Result(response.Response(String), String) {
  case request.to(url) {
    Error(_) -> Error("bad_url")
    Ok(req) -> {
      let body =
        params
        |> list.map(fn(p) {
          atutil.urlencode(p.0) <> "=" <> atutil.urlencode(p.1)
        })
        |> string.join("&")
      let req =
        req
        |> request.set_method(http.Post)
        |> request.set_header(
          "content-type",
          "application/x-www-form-urlencoded",
        )
        |> request.set_body(body)
      let req =
        list.fold(headers, req, fn(r, h) { request.set_header(r, h.0, h.1) })
      case httpc.send(req) {
        Ok(resp) -> Ok(resp)
        Error(_) -> Error("post_failed")
      }
    }
  }
}

pub fn header_value(
  headers: List(#(String, String)),
  name: String,
) -> Option(String) {
  let name_down = string.lowercase(name)
  case
    list.find_map(headers, fn(h) {
      case string.lowercase(h.0) == name_down {
        True if h.1 != "" -> Ok(h.1)
        _ -> Error(Nil)
      }
    })
  {
    Ok(v) -> Some(v)
    Error(_) -> None
  }
}

fn option_str(opt: Option(String)) -> String {
  case opt {
    Some(s) -> s
    None -> ""
  }
}

@external(erlang, "freeq_web4_ffi", "lookup_txt")
fn lookup_txt(name: String) -> List(String)
