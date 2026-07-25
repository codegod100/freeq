//// AT Protocol OAuth HTTP handlers: login form, start, callback, logout,
//// client metadata. Port of freeq-web3 `SessionsController`.

import freeq_web4/atproto/oauth
import freeq_web4/atproto/util as atutil
import freeq_web4/config
import freeq_web4/cookie_session
import freeq_web4/pending_oauth_store
import freeq_web4/session_store
import gleam/bytes_tree
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import logging
import mist

/// Route OAuth-related HTTP. Returns None if path is not an auth route.
pub fn handle(
  req: request.Request(mist.Connection),
) -> Option(response.Response(mist.ResponseData)) {
  case req.path, req.method {
    "/login", http.Get -> Some(login_form(req, None))
    "/login/start", http.Get -> Some(login_start(req))
    "/login", http.Post -> Some(login_start(req))
    "/auth/callback", http.Get -> Some(callback(req))
    "/auth/callback", http.Post -> Some(callback(req))
    "/logout", http.Get -> Some(logout(req))
    "/logout", http.Post -> Some(logout(req))
    "/.well-known/oauth-client-metadata", http.Get -> Some(client_metadata(req))
    _, _ -> None
  }
}

fn login_form(
  req: request.Request(mist.Connection),
  flash: Option(#(String, String)),
) -> response.Response(mist.ResponseData) {
  let sid = cookie_session.ensure_id(req)
  let flash_html = case flash {
    None -> ""
    Some(#("error", msg)) ->
      "<div class=\"flash error\">" <> escape(msg) <> "</div>"
    Some(#("info", msg)) ->
      "<div class=\"flash info\">" <> escape(msg) <> "</div>"
    Some(#(_, msg)) -> "<div class=\"flash\">" <> escape(msg) <> "</div>"
  }
  // Already signed in?
  let body = case session_store.load(sid) {
    Ok(oauth) -> redirect_html("/chat", "Signed in as " <> oauth.handle)
    Error(_) -> login_html(flash_html)
  }
  let resp =
    response.new(200)
    |> response.set_header("content-type", "text/html; charset=utf-8")
    |> response.set_body(mist.Bytes(bytes_tree.from_string(body)))
  cookie_session.set_on_response(resp, sid)
}

fn login_start(
  req: request.Request(mist.Connection),
) -> response.Response(mist.ResponseData) {
  let sid = cookie_session.ensure_id(req)
  let handle = query_param(req, "identifier")
  let handle =
    handle
    |> string.trim
    |> drop_at
  case handle {
    "" -> login_form(req, Some(#("error", "Handle is required")))
    handle -> {
      let public = public_url(req)
      case oauth.prepare(handle, public) {
        Error(reason) -> {
          logging.log(logging.Warning, "OAuth prepare failed: " <> reason)
          login_form(req, Some(#("error", "Login failed: " <> reason)))
        }
        Ok(prepared) -> {
          let pending = oauth.prepared_to_pending(prepared, sid)
          let _ = pending_oauth_store.save(pending)
          pending_oauth_store.gc()
          logging.log(
            logging.Info,
            "OAuth start handle="
              <> prepared.handle
              <> " sid="
              <> string.slice(sid, 0, 8)
              <> " state="
              <> string.slice(prepared.state, 0, 12),
          )
          let resp =
            response.new(302)
            |> response.set_header("location", prepared.auth_url)
            |> response.set_body(mist.Bytes(bytes_tree.from_string("")))
          cookie_session.set_on_response(resp, sid)
        }
      }
    }
  }
}

fn callback(
  req: request.Request(mist.Connection),
) -> response.Response(mist.ResponseData) {
  let code = query_param(req, "code")
  let state = query_param(req, "state")
  let error = query_param(req, "error")
  case error {
    e if e != "" -> {
      let _ = pending_oauth_store.remove(state)
      login_form(req, Some(#("error", "OAuth error: " <> e)))
    }
    _ ->
      case code == "" || state == "" {
        True ->
          login_form(
            req,
            Some(#("error", "OAuth callback missing code or state.")),
          )
        False -> complete_callback(req, code, state)
      }
  }
}

fn complete_callback(
  req: request.Request(mist.Connection),
  code: String,
  state: String,
) -> response.Response(mist.ResponseData) {
  case pending_oauth_store.take(state) {
    Error(_) -> {
      logging.log(
        logging.Warning,
        "OAuth callback: no pending for state=" <> string.slice(state, 0, 12),
      )
      login_form(req, Some(#("error", "No pending login. Please try again.")))
    }
    Ok(data) ->
      case oauth.prepared_from_pending(data) {
        Error(reason) ->
          login_form(req, Some(#("error", "Login failed: " <> reason)))
        Ok(prepared) ->
          case oauth.complete(prepared, code) {
            Error(reason) -> {
              logging.log(logging.Warning, "OAuth complete failed: " <> reason)
              login_form(req, Some(#("error", "Login failed: " <> reason)))
            }
            Ok(oauth_session) -> {
              let sid = case data.freeq_session_id {
                id if id != "" -> id
                _ -> cookie_session.ensure_id(req)
              }
              session_store.save(sid, oauth_session)
              logging.log(
                logging.Info,
                "OAuth complete handle="
                  <> oauth_session.handle
                  <> " sid="
                  <> string.slice(sid, 0, 8)
                  <> " did="
                  <> oauth_session.did,
              )
              let body =
                redirect_html(
                  "/chat",
                  "Signed in as " <> oauth_session.handle <> ". Connecting…",
                )
              let resp =
                response.new(200)
                |> response.set_header(
                  "content-type",
                  "text/html; charset=utf-8",
                )
                |> response.set_body(mist.Bytes(bytes_tree.from_string(body)))
              cookie_session.set_on_response(resp, sid)
            }
          }
      }
  }
}

fn logout(
  req: request.Request(mist.Connection),
) -> response.Response(mist.ResponseData) {
  case cookie_session.from_request(req) {
    Some(sid) -> session_store.remove(sid)
    None -> Nil
  }
  let body = redirect_html("/chat", "Signed out")
  let resp =
    response.new(200)
    |> response.set_header("content-type", "text/html; charset=utf-8")
    |> response.set_body(mist.Bytes(bytes_tree.from_string(body)))
  cookie_session.clear_on_response(resp)
}

fn client_metadata(
  req: request.Request(mist.Connection),
) -> response.Response(mist.ResponseData) {
  let public = public_url(req)
  let base = atutil.trim_slash(public)
  let body =
    json.object([
      #("client_id", json.string(base <> "/.well-known/oauth-client-metadata")),
      #("client_name", json.string("freeq-web4")),
      #(
        "redirect_uris",
        json.preprocessed_array([
          json.string(base <> "/auth/callback"),
        ]),
      ),
      #(
        "grant_types",
        json.preprocessed_array([
          json.string("authorization_code"),
          json.string("refresh_token"),
        ]),
      ),
      #("response_types", json.preprocessed_array([json.string("code")])),
      #("scope", json.string("atproto transition:generic")),
      #("token_endpoint_auth_method", json.string("none")),
      #("application_type", json.string("web")),
      #("dpop_bound_access_tokens", json.bool(True)),
    ])
    |> json.to_string
  response.new(200)
  |> response.set_header("content-type", "application/json; charset=utf-8")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(body)))
}

// ── HTML ───────────────────────────────────────────────────────────────────

fn login_html(flash: String) -> String {
  shell(
    "Sign in · freeq",
    "<div id=\"freeq-login\" class=\"login-page\">"
      <> "<div class=\"login-card\">"
      <> "<h1>Sign in to freeq</h1>"
      <> "<p class=\"muted\">Use your Bluesky / AT Protocol handle. Private keys never leave your PDS.</p>"
      <> flash
      <> "<form method=\"get\" action=\"/login/start\" class=\"login-form\">"
      <> "<label for=\"identifier\">Handle</label>"
      <> "<input id=\"identifier\" type=\"text\" name=\"identifier\" "
      <> "placeholder=\"you.bsky.social\" required autofocus autocomplete=\"username\" />"
      <> "<button type=\"submit\">Continue with AT Protocol</button>"
      <> "</form>"
      <> "<p class=\"login-guest\"><a href=\"/chat\">Continue as guest</a></p>"
      <> "</div></div>",
  )
}

fn redirect_html(to: String, message: String) -> String {
  shell(
    "freeq",
    "<div class=\"login-page\"><div class=\"login-card\">"
      <> "<p>"
      <> escape(message)
      <> "</p>"
      <> "<p class=\"muted\"><a href=\""
      <> escape(to)
      <> "\">Continue</a></p>"
      <> "<meta http-equiv=\"refresh\" content=\"0;url="
      <> escape(to)
      <> "\">"
      <> "</div></div>",
  )
}

fn shell(title: String, body: String) -> String {
  "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">"
  <> "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
  <> "<meta name=\"color-scheme\" content=\"dark\">"
  <> "<title>"
  <> escape(title)
  <> "</title>"
  <> "<link rel=\"stylesheet\" href=\"/assets/app.css\">"
  <> "<link href=\"https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap\" rel=\"stylesheet\">"
  <> "<style>"
  <> login_css()
  <> "</style></head><body>"
  <> body
  <> "</body></html>"
}

fn login_css() -> String {
  ".login-page{min-height:100dvh;display:flex;align-items:center;justify-content:center;padding:1rem;background:var(--bg,#0e1116);color:var(--fg,#e7ecf3);font-family:Inter,system-ui,sans-serif}"
  <> ".login-card{width:100%;max-width:28rem;border:1px solid var(--border,#2a3140);background:#151a22;border-radius:12px;padding:24px;box-shadow:0 4px 24px rgba(0,0,0,.3)}"
  <> ".login-card h1{font-size:1.25rem;font-weight:600;letter-spacing:-.02em;margin:0}"
  <> ".login-card .muted{margin:8px 0 0;font-size:.875rem;color:var(--muted,#8b95a8)}"
  <> ".login-form{margin-top:24px;display:flex;flex-direction:column;gap:12px}"
  <> ".login-form label{font-size:.75rem;text-transform:uppercase;letter-spacing:.05em;color:var(--muted,#8b95a8)}"
  <> ".login-form input{border-radius:8px;border:1px solid var(--border,#2a3140);background:var(--bg,#0e1116);padding:8px 12px;font-size:.875rem;outline:none;color:var(--fg,#e7ecf3)}"
  <> ".login-form button{margin-top:8px;border:0;border-radius:8px;background:#7ab7ff;padding:8px 12px;font-size:.875rem;font-weight:600;color:#0e1116;cursor:pointer}"
  <> ".login-guest{margin-top:16px;text-align:center;font-size:.875rem}"
  <> ".login-guest a{color:#7ab7ff;text-decoration:none}"
  <> ".flash{margin:16px 0;padding:8px 12px;border-radius:8px;font-size:.875rem}"
  <> ".flash.error{background:rgba(239,71,111,.1);border:1px solid #ef476f;color:#ef476f}"
  <> ".flash.info{background:rgba(6,214,160,.1);border:1px solid #06d6a0;color:#06d6a0}"
}

// ── helpers ────────────────────────────────────────────────────────────────

pub fn public_url(req: request.Request(body)) -> String {
  case config.public_url() {
    Some(url) -> atutil.trim_slash(url)
    None -> {
      let host = case request.get_header(req, "host") {
        Ok(h) -> h
        Error(_) -> "127.0.0.1:" <> int.to_string(config.port())
      }
      let scheme = case request.get_header(req, "x-forwarded-proto") {
        Ok("https") -> "https"
        Ok("http") -> "http"
        _ ->
          case
            string.contains(host, "localhost")
            || string.starts_with(host, "127.")
          {
            True -> "http"
            False -> "https"
          }
      }
      scheme <> "://" <> host
    }
  }
}

fn query_param(req: request.Request(body), name: String) -> String {
  case request.get_query(req) {
    Ok(pairs) ->
      case list.key_find(pairs, name) {
        Ok(v) -> v
        Error(_) -> ""
      }
    Error(_) -> ""
  }
}

fn drop_at(s: String) -> String {
  case string.starts_with(s, "@") {
    True -> string.drop_start(s, 1)
    False -> s
  }
}

fn escape(s: String) -> String {
  s
  |> string.replace("&", "&amp;")
  |> string.replace("<", "&lt;")
  |> string.replace(">", "&gt;")
  |> string.replace("\"", "&quot;")
}
