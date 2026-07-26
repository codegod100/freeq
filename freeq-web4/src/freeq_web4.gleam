//// freeq-web4 — Gleam Lightspeed LiveView BFF for freeq.
////
//// Stack:
//// - Lightspeed `endpoint` + verified routes + `get_live`
//// - stateful chat component (`freeq_web4/live`)
//// - Lightspeed protocol over WebSocket at `/live` (`freeq_web4/ws`)
//// - Stratus upstream IRC client (`freeq_web4/irc/upstream`)
//// - freeq-server REST via gleam_httpc (`freeq_web4/rest`)

import filepath
import freeq_web4/auth
import freeq_web4/config
import freeq_web4/cookie_session
import freeq_web4/link_preview
import freeq_web4/live
import freeq_web4/rest
import freeq_web4/session_store
import freeq_web4/upload
import freeq_web4/ws
import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http as gleam_http
import gleam/http/request as http_request
import gleam/http/response as http_response
import gleam/httpc
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import lightspeed/framework/controller
import lightspeed/framework/endpoint
import lightspeed/framework/http as ls_http
import lightspeed/framework/verified_routes
import lightspeed/transport/contract
import mist
import simplifile

// ── Endpoint ─────────────────────────────────────────────────────────────────

/// Framework endpoint: live chat, health, static assets.
pub fn app(css: String, client_js: String) -> endpoint.Endpoint {
  let index = verified_routes.route0("/chat")
  let root = verified_routes.route0("/")
  let health = verified_routes.route0("/health")
  let up = verified_routes.route0("/up")

  endpoint.new(contract.allow_all("owner-1"), "/live")
  |> endpoint.get_live(index, "freeq_view", fn(_conn) {
    live.initial_html("/chat")
  })
  |> endpoint.get_controller(root, fn(conn) {
    controller.redirect(conn, "/chat")
  })
  |> endpoint.get_controller(health, fn(conn) { controller.text(conn, "ok") })
  |> endpoint.get_controller(up, fn(conn) {
    controller.text(conn, "{\"ok\":true,\"service\":\"freeq-web4\"}")
  })
  |> endpoint.static("/assets/app.css", "text/css; charset=utf-8", css)
  |> endpoint.static(
    "/assets/lightspeed.js",
    "application/javascript; charset=utf-8",
    client_js,
  )
}

// ── Mist adapter ─────────────────────────────────────────────────────────────

fn to_ls_method(method: gleam_http.Method) -> ls_http.Method {
  case method {
    gleam_http.Get -> ls_http.Get
    gleam_http.Post -> ls_http.Post
    gleam_http.Put -> ls_http.Put
    gleam_http.Patch -> ls_http.Patch
    gleam_http.Delete -> ls_http.Delete
    gleam_http.Head -> ls_http.Head
    gleam_http.Options -> ls_http.Options
    gleam_http.Trace -> ls_http.Other("TRACE")
    gleam_http.Connect -> ls_http.Other("CONNECT")
    gleam_http.Other(label) -> ls_http.Other(label)
  }
}

fn to_ls_request(
  req: http_request.Request(mist.Connection),
  port: Int,
) -> ls_http.Request {
  ls_http.request(
    method: to_ls_method(req.method),
    path: req.path,
    headers: req.headers,
    body: "",
    session_id: "session-1",
    csrf_token: "token-1",
    origin: "http://127.0.0.1:" <> int.to_string(port),
    session: [],
    flash: [],
  )
}

fn to_http_response(
  response: ls_http.Response,
) -> http_response.Response(mist.ResponseData) {
  let resp =
    http_response.new(response.status)
    |> http_response.set_body(mist.Bytes(bytes_tree.from_string(response.body)))

  list.fold(response.headers, resp, fn(resp, header) {
    http_response.set_header(resp, header.0, header.1)
  })
}

/// CSP for Live HTML. MoQ's AudioWorklet loads a blob: module — without
/// `blob:` in script-src/worker-src Chrome throws:
///   AbortError: Unable to load a worklet's module.
/// Keep this in sync with freeq-server's default CSP (plus font CDN used below).
/// Public so tests can lock the blob: worklet allowance.
pub fn live_csp() -> String {
  "default-src 'self'; "
  <> "script-src 'self' blob:; "
  <> "worker-src 'self' blob:; "
  <> "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; "
  <> "font-src 'self' https://fonts.gstatic.com data:; "
  <> "img-src 'self' https: data: blob:; "
  <> "media-src 'self' blob:; "
  <> "connect-src 'self' ws: wss: https:; "
  <> "frame-ancestors 'none'; "
  <> "base-uri 'self'; "
  <> "form-action 'self'; "
  <> "object-src 'none'"
}

fn with_live_security_headers(
  resp: http_response.Response(mist.ResponseData),
) -> http_response.Response(mist.ResponseData) {
  resp
  |> http_response.set_header("content-security-policy", live_csp())
  |> http_response.set_header("x-content-type-options", "nosniff")
  |> http_response.set_header("referrer-policy", "strict-origin-when-cross-origin")
}

fn enhance_live_html(body: String) -> String {
  body
  |> string.replace(
    "</head>",
    "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
      <> "<meta name=\"color-scheme\" content=\"dark\">"
      <> "<link rel=\"icon\" href=\"/favicon.png?v=2\" type=\"image/png\" sizes=\"48x48\">"
      <> "<link rel=\"apple-touch-icon\" href=\"/apple-touch-icon.png?v=2\" sizes=\"180x180\">"
      <> "<link rel=\"stylesheet\" href=\"/assets/app.css\">"
      <> "<link href=\"https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap\" rel=\"stylesheet\">"
      <> "<script type=\"module\" src=\"/assets/av_call.js\"></script>"
      <> "<script type=\"module\" src=\"/assets/lightspeed.js\"></script>"
      <> "</head>",
  )
  |> string.replace("<title>Lightspeed</title>", "<title>freeq · web4</title>")
}

fn response_body_string(
  response: http_response.Response(mist.ResponseData),
) -> Result(String, Nil) {
  case response.body {
    mist.Bytes(tree) ->
      tree
      |> bytes_tree.to_bit_array
      |> bit_array.to_string
    _ -> Error(Nil)
  }
}

fn is_websocket_upgrade(req: http_request.Request(mist.Connection)) -> Bool {
  case http_request.get_header(req, "upgrade") {
    Ok(value) -> string.lowercase(value) == "websocket"
    Error(_) -> False
  }
}

fn chat_path(path: String) -> String {
  case path {
    "/" -> "/chat"
    p -> p
  }
}

fn handle_request(
  req: http_request.Request(mist.Connection),
  port: Int,
  css: String,
  client_js: String,
  av_js: String,
  favicon_png: BitArray,
  apple_touch_png: BitArray,
  icon_192_png: BitArray,
) -> http_response.Response(mist.ResponseData) {
  case req.path, req.method, is_websocket_upgrade(req) {
    "/live", gleam_http.Get, True -> upgrade_live(req)

    // PNG bytes (same file as favicon.png); browsers accept PNG at /favicon.ico.
    "/favicon.ico", gleam_http.Get, False ->
      static_png(favicon_png, "image/png")

    "/favicon.png", gleam_http.Get, False ->
      static_png(favicon_png, "image/png")

    "/apple-touch-icon.png", gleam_http.Get, False ->
      static_png(apple_touch_png, "image/png")

    "/icon-192.png", gleam_http.Get, False ->
      static_png(icon_192_png, "image/png")

    "/assets/av_call.js", gleam_http.Get, False ->
      http_response.new(200)
      |> http_response.set_header(
        "content-type",
        "application/javascript; charset=utf-8",
      )
      |> http_response.set_body(mist.Bytes(bytes_tree.from_string(av_js)))

    // Re-read CSS from disk each request so priv/static/app.css edits show
    // without restarting (boot-time `css` is only a fallback if the file is gone).
    "/assets/app.css", gleam_http.Get, False ->
      http_response.new(200)
      |> http_response.set_header("content-type", "text/css; charset=utf-8")
      |> http_response.set_header("cache-control", "no-cache")
      |> http_response.set_body(
        mist.Bytes(bytes_tree.from_string(load_asset_or(css, "app.css"))),
      )

    "/upload", gleam_http.Post, False -> upload.handle(req)

    _, _, False ->
      case auth.handle(req) {
        Some(resp) -> resp
        None ->
          case handle_preview_routes(req) {
            Some(resp) -> resp
            None ->
              case handle_av_api(req) {
                Some(resp) -> resp
                None ->
                  case req.method {
                    gleam_http.Get ->
                      case string.starts_with(req.path, "/chat/") {
                        True -> live_html_response(req)
                        False -> call_endpoint(req, port, css, client_js)
                      }
                    _ ->
                      http_response.new(404)
                      |> http_response.set_body(
                        mist.Bytes(bytes_tree.from_string("not found")),
                      )
                  }
              }
          }
      }

    _, _, True ->
      http_response.new(404)
      |> http_response.set_body(mist.Bytes(bytes_tree.from_string("not found")))
  }
}

/// Same-origin OG proxy + cached preview images (web3 parity).
fn handle_preview_routes(
  req: http_request.Request(mist.Connection),
) -> Option(http_response.Response(mist.ResponseData)) {
  case req.method {
    gleam_http.Get ->
      case req.path {
        "/api/v1/og" -> Some(handle_og_proxy(req))
        _ ->
          case string.starts_with(req.path, "/preview-cache/") {
            True -> {
              let id =
                string.drop_start(req.path, string.length("/preview-cache/"))
              Some(handle_preview_cache(id))
            }
            False -> None
          }
      }
    _ -> None
  }
}

fn handle_og_proxy(
  req: http_request.Request(mist.Connection),
) -> http_response.Response(mist.ResponseData) {
  let url = query_param(req, "url")
  let url =
    url
    |> string.replace("\u{200B}", "")
    |> string.replace("\u{200C}", "")
    |> string.replace("\u{200D}", "")
    |> string.replace("\u{FEFF}", "")
    |> string.trim
  let url = case string.starts_with(url, "<") {
    True -> string.drop_start(url, 1)
    False -> url
  }
  let url = case string.ends_with(url, ">") {
    True -> string.drop_end(url, 1)
    False -> url
  }
  case url {
    "" -> json_response(400, "{\"error\":\"url required\"}")
    u ->
      case string.starts_with(u, "http://") || string.starts_with(u, "https://")
      {
        False -> json_response(400, "{\"error\":\"Invalid URL\"}")
        True ->
          case rest.fetch_og(u) {
            None -> json_response(502, "{\"error\":\"Fetch failed\"}")
            Some(meta) ->
              json_response(
                200,
                json_object([
                  #("title", meta.title),
                  #("description", meta.description),
                  #("image", meta.image),
                  #("site_name", meta.site_name),
                ]),
              )
          }
      }
  }
}

fn json_object(fields: List(#(String, String))) -> String {
  fields
  |> list.map(fn(pair) {
    "\"" <> json_escape(pair.0) <> "\":\"" <> json_escape(pair.1) <> "\""
  })
  |> string.join(",")
  |> fn(body) { "{" <> body <> "}" }
}

fn query_param(
  req: http_request.Request(mist.Connection),
  name: String,
) -> String {
  case http_request.get_query(req) {
    Ok(pairs) ->
      case list.find(pairs, fn(p) { p.0 == name }) {
        Ok(#(_, v)) -> v
        Error(_) -> ""
      }
    Error(_) -> ""
  }
}

fn handle_preview_cache(id: String) -> http_response.Response(mist.ResponseData) {
  case link_preview.read_image(id) {
    Error(_) ->
      http_response.new(404)
      |> http_response.set_body(mist.Bytes(bytes_tree.from_string("not found")))
    Ok(#(bin, content_type)) ->
      http_response.new(200)
      |> http_response.set_header("content-type", content_type)
      |> http_response.set_header(
        "cache-control",
        "public, max-age=604800, immutable",
      )
      |> http_response.set_body(mist.Bytes(bytes_tree.from_bit_array(bin)))
  }
}

/// Same-origin BFF for AV roster / token / MoQ static assets.
fn handle_av_api(
  req: http_request.Request(mist.Connection),
) -> Option(http_response.Response(mist.ResponseData)) {
  let path = req.path
  case req.method {
    gleam_http.Get ->
      case string.starts_with(path, "/api/v1/sessions/") {
        True -> {
          let id = string.drop_start(path, string.length("/api/v1/sessions/"))
          case id == "" || string.contains(id, "/") {
            True -> None
            False ->
              Some(json_or_empty(rest.fetch_session_detail(uri.percent_decode(
                id,
              )
              |> result.unwrap(id))))
          }
        }
        False ->
          case
            string.starts_with(path, "/api/v1/av/sessions/")
            && string.ends_with(path, "/token")
          {
            True -> {
              let mid =
                string.drop_start(path, string.length("/api/v1/av/sessions/"))
              let id = string.drop_end(mid, string.length("/token"))
              case id == "" {
                True -> None
                False -> {
                  let sid = cookie_session.ensure_id(req)
                  let bearer = session_store.load_api_bearer(sid)
                  case bearer {
                    None ->
                      Some(
                        json_response(
                          401,
                          "{\"error\":\"guest — use +freeq.at/av-token TAGMSG\",\"guest\":true}",
                        ),
                      )
                    Some(_) -> {
                      let tok =
                        rest.fetch_av_token(
                          uri.percent_decode(id) |> result.unwrap(id),
                          bearer,
                        )
                      case tok {
                        Some(t) ->
                          Some(json_response(
                            200,
                            "{\"token\":\"" <> json_escape(t) <> "\"}",
                          ))
                        None ->
                          Some(json_response(
                            403,
                            "{\"error\":\"upstream refused token\"}",
                          ))
                      }
                    }
                  }
                }
              }
            }
            False ->
              case string.starts_with(path, "/av/assets/") {
                True -> {
                  let rel = string.drop_start(path, string.length("/av/assets/"))
                  Some(proxy_av_asset(rel))
                }
                False -> None
              }
          }
      }
    _ -> None
  }
}

fn json_or_empty(body: Option(String)) -> http_response.Response(
  mist.ResponseData,
) {
  case body {
    Some(b) -> json_response(200, b)
    None -> json_response(200, "{}")
  }
}

fn json_response(
  status: Int,
  body: String,
) -> http_response.Response(mist.ResponseData) {
  http_response.new(status)
  |> http_response.set_header("content-type", "application/json; charset=utf-8")
  |> http_response.set_body(mist.Bytes(bytes_tree.from_string(body)))
}

fn json_escape(s: String) -> String {
  s
  |> string.replace("\\", "\\\\")
  |> string.replace("\"", "\\\"")
  |> string.replace("\n", "\\n")
  |> string.replace("\r", "\\r")
}

fn proxy_av_asset(rel: String) -> http_response.Response(mist.ResponseData) {
  // Prevent path traversal.
  case string.contains(rel, "..") || rel == "" {
    True ->
      http_response.new(400)
      |> http_response.set_body(mist.Bytes(bytes_tree.from_string("bad path")))
    False -> {
      let url = config.upstream_rest() <> "/av/assets/" <> rel
      case http_request.to(url) {
        Error(_) ->
          http_response.new(502)
          |> http_response.set_body(mist.Bytes(bytes_tree.from_string("")))
        Ok(req) -> {
          let req =
            req
            |> http_request.set_method(gleam_http.Get)
          case httpc.send(req) {
            Ok(resp) -> {
              let ct = case string.ends_with(rel, ".js") {
                True -> "application/javascript; charset=utf-8"
                False -> "application/octet-stream"
              }
              http_response.new(resp.status)
              |> http_response.set_header("content-type", ct)
              |> http_response.set_header("access-control-allow-origin", "*")
              |> http_response.set_body(
                mist.Bytes(bytes_tree.from_string(resp.body)),
              )
            }
            Error(_) ->
              http_response.new(502)
              |> http_response.set_body(mist.Bytes(bytes_tree.from_string("")))
          }
        }
      }
    }
  }
}

fn call_endpoint(
  req: http_request.Request(mist.Connection),
  port: Int,
  css: String,
  client_js: String,
) -> http_response.Response(mist.ResponseData) {
  let sid = cookie_session.ensure_id(req)
  let response =
    req
    |> to_ls_request(port)
    |> endpoint.call(app(css, client_js), _)
    |> to_http_response

  let response = case
    response.status,
    http_response.get_header(response, "content-type")
  {
    200, Ok(ct) ->
      case string.contains(ct, "text/html") {
        True ->
          case response_body_string(response) {
            Ok(body) ->
              response
              |> http_response.set_body(
                mist.Bytes(bytes_tree.from_string(enhance_live_html(body))),
              )
              |> with_live_security_headers
            Error(_) -> response
          }
        False -> response
      }
    _, _ -> response
  }
  cookie_session.set_on_response(response, sid)
}

fn live_html_response(
  req: http_request.Request(mist.Connection),
) -> http_response.Response(mist.ResponseData) {
  let path = chat_path(req.path)
  let sid = cookie_session.ensure_id(req)
  let inner = live.initial_html(path)
  let shell =
    "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">"
    <> "<title>Lightspeed</title></head><body>"
    <> "<main id=\"app\" data-ls-session=\"session-1\" data-ls-owner=\"owner-1\""
    <> " data-ls-route=\""
    <> path
    <> "\" data-ls-ws=\"/live\" data-ls-protocol=\"lightspeed\""
    <> " data-ls-version=\"1\" data-ls-patch-stream-version=\"1\">"
    <> inner
    <> "</main></body></html>"
  let body = enhance_live_html(shell)
  let resp =
    http_response.new(200)
    |> http_response.set_header("content-type", "text/html; charset=utf-8")
    |> http_response.set_body(mist.Bytes(bytes_tree.from_string(body)))
    |> with_live_security_headers
  cookie_session.set_on_response(resp, sid)
}

fn upgrade_live(
  req: http_request.Request(mist.Connection),
) -> http_response.Response(mist.ResponseData) {
  let path = case http_request.get_query(req) {
    Ok(pairs) ->
      case list.key_find(pairs, "path") {
        Ok(p) -> chat_path(p)
        Error(_) -> "/chat"
      }
    Error(_) -> "/chat"
  }
  let session_id = cookie_session.ensure_id(req)

  // Browsers send `Sec-WebSocket-Extensions: permessage-deflate`. Mist will
  // negotiate it, but compressed frames have been observed as
  // "Invalid frame header" in Chrome. Drop the extension so we speak plain
  // text frames (same as a curl client without extensions).
  let req =
    http_request.Request(
      ..req,
      headers: list.filter(req.headers, fn(h) {
        string.lowercase(h.0) != "sec-websocket-extensions"
      }),
    )

  mist.websocket(
    request: req,
    on_init: fn(conn) {
      let self_subject = process.new_subject()
      let #(session, frames) = ws.mount(path, self_subject, session_id)
      // Hello first — must not block on REST/IRC or Mist aborts the upgrade
      // (browser then sees "Invalid frame header" / HTTP 400 on the socket).
      ws.push_frames(conn, frames)
      ws.schedule_bootstrap(self_subject)
      #(#(session, []), Some(ws.push_selector(session)))
    },
    handler: handle_ws,
    on_close: fn(state) {
      let #(session, _) = state
      ws.close(session)
    },
  )
}

fn handle_ws(
  state: #(ws.Session, List(String)),
  message: mist.WebsocketMessage(ws.Push),
  conn: mist.WebsocketConnection,
) -> mist.Next(#(ws.Session, List(String)), ws.Push) {
  let #(session, pending) = state
  case pending {
    [] -> Nil
    frames -> ws.push_frames(conn, frames)
  }

  case message {
    mist.Text(payload) -> {
      let #(next, outbound) = ws.handle_frame(session, payload)
      ws.push_frames(conn, outbound)
      mist.continue(#(next, []))
      |> mist.with_selector(ws.push_selector(next))
    }
    mist.Binary(_) ->
      mist.continue(#(session, []))
      |> mist.with_selector(ws.push_selector(session))
    mist.Custom(push) -> {
      let #(next, outbound) = ws.handle_push(session, push)
      ws.push_frames(conn, outbound)
      mist.continue(#(next, []))
      |> mist.with_selector(ws.push_selector(next))
    }
    mist.Closed | mist.Shutdown -> mist.stop()
  }
}

// ── Main ─────────────────────────────────────────────────────────────────────

pub fn main() -> Nil {
  let port = config.port()
  let css = load_asset("app.css")
  let client_js = freeq_client_js()
  let av_js = load_asset("av_call.js")
  let favicon_png = load_asset_bits("favicon.png")
  let apple_touch_png = load_asset_bits("apple-touch-icon.png")
  let icon_192_png = load_asset_bits("icon-192.png")

  // Log before bind so Eaddrinuse (etc.) still shows which port we tried.
  io_println(
    "freeq-web4 listening on port "
    <> int.to_string(port)
    <> " (PORT env, default 4004)",
  )

  // Bind all interfaces + IPv6 so browsers resolving localhost → ::1 work.
  let assert Ok(_) =
    mist.new(fn(req) {
      handle_request(
        req,
        port,
        css,
        client_js,
        av_js,
        favicon_png,
        apple_touch_png,
        icon_192_png,
      )
    })
    |> mist.port(port)
    |> mist.bind("0.0.0.0")
    |> mist.with_ipv6
    |> mist.start

  echo_banner(port)
  process.sleep_forever()
}

fn echo_banner(port: Int) -> Nil {
  let base = "http://127.0.0.1:" <> int.to_string(port)
  io_println("freeq-web4 (Lightspeed) at " <> base)
  io_println("  GET  /chat            channel list")
  io_println("  GET  /chat/:channel   chat shell")
  io_println("  GET  /login           AT Protocol OAuth")
  io_println("  GET  /auth/callback   OAuth callback")
  io_println("  WS   /live            lightspeed protocol")
  io_println("  GET  /health          ok")
  io_println("  POST /upload          image upload proxy")
  io_println("  GET  /api/v1/sessions/:id   AV roster proxy")
  io_println("  GET  /av/assets/*     MoQ asset proxy")
  io_println("  upstream " <> config.upstream_ws())
  io_println("  rest     " <> config.upstream_rest())
  io_println("  av       " <> config.av_origin())
}

@external(erlang, "io", "format")
fn io_format(fmt: String, args: List(String)) -> Nil

fn io_println(line: String) -> Nil {
  io_format("~s~n", [line])
}

fn load_asset(name: String) -> String {
  load_asset_or("/* missing asset: " <> name <> " */", name)
}

/// Read `priv/static/<name>` (or freeq-web4/… when cwd is the monorepo root).
/// Falls back to `fallback` when the file is missing (e.g. packed deploy).
fn load_asset_or(fallback: String, name: String) -> String {
  let candidates = [
    filepath.join("priv/static", name),
    filepath.join("freeq-web4/priv/static", name),
  ]
  case
    list.find_map(candidates, fn(path) {
      case simplifile.read(path) {
        Ok(body) -> Ok(body)
        Error(_) -> Error(Nil)
      }
    })
  {
    Ok(body) -> body
    Error(_) -> fallback
  }
}

fn load_asset_bits(name: String) -> BitArray {
  let candidates = [
    filepath.join("priv/static", name),
    filepath.join("freeq-web4/priv/static", name),
  ]
  case
    list.find_map(candidates, fn(path) {
      case simplifile.read_bits(path) {
        Ok(body) -> Ok(body)
        Error(_) -> Error(Nil)
      }
    })
  {
    Ok(body) -> body
    Error(_) -> <<>>
  }
}

fn static_png(
  body: BitArray,
  content_type: String,
) -> http_response.Response(mist.ResponseData) {
  case bit_array.byte_size(body) {
    0 ->
      http_response.new(404)
      |> http_response.set_body(mist.Bytes(bytes_tree.from_string("not found")))
    _ ->
      http_response.new(200)
      |> http_response.set_header("content-type", content_type)
      |> http_response.set_header(
        "cache-control",
        "public, max-age=86400",
      )
      |> http_response.set_body(mist.Bytes(bytes_tree.from_bit_array(body)))
  }
}

// ── Browser client (star-style, freeq events) ────────────────────────────────

fn freeq_client_js() -> String {
  "const ROOT = document.getElementById('app');
if (!ROOT) throw new Error('Lightspeed: #app missing');

const wsPath = ROOT.dataset.lsWs || '/live';
const proto = location.protocol === 'https:' ? 'wss' : 'ws';

function currentRoute() {
  return ROOT.dataset.lsRoute || location.pathname || '/chat';
}

function wsUrl() {
  return proto + '://' + location.host + wsPath + '?path=' + encodeURIComponent(currentRoute());
}

/** Keep the address bar + reconnect route in sync (LiveView push_patch style). */
function pushPath(path, options) {
  if (!path || typeof path !== 'string') return;
  const replace = !!(options && options.replace);
  if (path !== location.pathname) {
    try {
      if (replace) history.replaceState({ freeq: true }, '', path);
      else history.pushState({ freeq: true }, '', path);
    } catch (_) {}
  }
  ROOT.dataset.lsRoute = path;
}

function channelPathFromInput(raw) {
  const bare = String(raw || '').trim().replace(/^#+/, '');
  if (!bare) return null;
  return '/chat/' + bare;
}

let socket;
let refSeq = 1;

function escapeField(value) {
  return String(value).replace(/\\\\/g, '\\\\\\\\').replace(/\\|/g, '\\\\|');
}

function encodeEvent(name, payload) {
  const ref = String(refSeq++);
  return ['event', ref, name, payload || ''].map(escapeField).join('|');
}

function splitFields(payload) {
  const fields = [];
  let cur = '';
  let esc = false;
  for (const ch of payload) {
    if (esc) { cur += ch; esc = false; continue; }
    if (ch === '\\\\') { esc = true; continue; }
    if (ch === '|') { fields.push(cur); cur = ''; continue; }
    cur += ch;
  }
  fields.push(cur);
  return fields;
}

// Lightspeed form.parse_payload splits on raw = / & and does not percent-decode.
// Escape so field boundaries stay intact; freeq_web4/ls_form unescapes on read.
// Order: % first so round-trip of literal %3D / %26 is unambiguous.
function escapeLsField(s) {
  return String(s ?? '')
    .replace(/%/g, '%25')
    .replace(/&/g, '%26')
    .replace(/=/g, '%3D');
}

function formPayload(form) {
  try {
    const data = new FormData(form);
    const parts = [];
    for (const [k, v] of data.entries()) {
      parts.push(escapeLsField(k) + '=' + escapeLsField(v));
    }
    return parts.join('&');
  } catch (_) {
    return '';
  }
}

function pushEvent(name, payload) {
  if (!socket || socket.readyState !== 1) return;
  socket.send(encodeEvent(name, payload || ''));
}

function applyReplace(target, html) {
  if (!target || html == null) return;
  let el = null;
  if (target === '#app' || target === '[data-ls-root]') el = ROOT;
  else {
    try { el = ROOT.querySelector(target) || document.querySelector(target); }
    catch (_) { el = null; }
  }
  if (!el) return;
  const tmp = document.createElement('div');
  tmp.innerHTML = html;
  const next = tmp.firstElementChild;
  if (next && el.parentNode && next.tagName === el.tagName) {
    el.replaceWith(next);
  } else {
    el.outerHTML = html;
  }
}

function applyAppend(target, html) {
  if (!target || html == null) return;
  let el = null;
  try { el = ROOT.querySelector(target) || document.querySelector(target); }
  catch (_) { el = null; }
  if (!el) return;
  el.insertAdjacentHTML('beforeend', html);
}

function applyPrepend(target, html) {
  if (!target || html == null) return;
  let el = null;
  try { el = ROOT.querySelector(target) || document.querySelector(target); }
  catch (_) { el = null; }
  if (!el) return;
  el.insertAdjacentHTML('afterbegin', html);
}

function applyRemove(target) {
  if (!target) return;
  let el = null;
  try { el = ROOT.querySelector(target) || document.querySelector(target); }
  catch (_) { el = null; }
  if (el && el.parentNode) el.remove();
}

// Lightspeed patch stream: ps|ver|dictLen|…dict|opCount|ops
// Ops are dictionary-compressed: r,ti,hi = replace (see lightspeed/diff).
function dictAt(dictionary, indexText) {
  const i = parseInt(indexText, 10);
  if (!Number.isFinite(i) || i < 0 || i >= dictionary.length) return '';
  return dictionary[i] || '';
}

function applyCompressedOp(opField, dictionary) {
  const tokens = String(opField || '').split(',');
  const tag = tokens[0];
  if (tag === 'r' && tokens.length >= 3) {
    applyReplace(dictAt(dictionary, tokens[1]), dictAt(dictionary, tokens[2]));
    return true;
  }
  if (tag === 'a' && tokens.length >= 3) {
    applyAppend(dictAt(dictionary, tokens[1]), dictAt(dictionary, tokens[2]));
    return true;
  }
  if (tag === 'p' && tokens.length >= 3) {
    applyPrepend(dictAt(dictionary, tokens[1]), dictAt(dictionary, tokens[2]));
    return true;
  }
  if (tag === 'x' && tokens.length >= 2) {
    applyRemove(dictAt(dictionary, tokens[1]));
    return true;
  }
  // Segment / keyed ops not needed for freeq MVP region replaces.
  return false;
}

function applyPatchStream(parts) {
  // parts[0] === 'ps'
  if (parts.length < 5) return false;
  const version = parseInt(parts[1], 10);
  if (version !== 1) return false;
  const dictLen = parseInt(parts[2], 10);
  if (!Number.isFinite(dictLen) || dictLen < 0) return false;
  let i = 3;
  if (parts.length < i + dictLen + 1) return false;
  const dictionary = parts.slice(i, i + dictLen);
  i += dictLen;
  const opCount = parseInt(parts[i++], 10);
  if (!Number.isFinite(opCount) || opCount < 0) return false;
  const ops = parts.slice(i, i + opCount);
  let applied = false;
  for (const op of ops) {
    if (applyCompressedOp(op, dictionary)) applied = true;
  }
  return applied;
}

function applyPatches(encoded) {
  if (!encoded) return;
  const parts = splitFields(encoded);
  if (parts[0] === 'ps') {
    applyPatchStream(parts);
    return;
  }
  // Legacy uncompressed: replace|target|html …
  let i = 0;
  let applied = false;
  while (i < parts.length) {
    const op = (parts[i] || '').toLowerCase();
    if (op === 'replace') {
      applyReplace(parts[i + 1] || '', parts[i + 2] || '');
      applied = true;
      i += 3;
    } else if (op === 'update_segments') {
      i += 4;
    } else {
      i += 1;
    }
  }
  if (!applied && encoded.trim().startsWith('<')) {
    applyReplace('#app', encoded);
  }
}

function composeInput() {
  return ROOT.querySelector('#message-input, #send-form input[name=\"msg\"]');
}

function focusCompose() {
  const input = composeInput();
  if (!input) return false;
  try { input.focus({ preventScroll: true }); } catch (_) { input.focus(); }
  return true;
}

function snapshotCompose() {
  const input = composeInput();
  if (!input) return null;
  const ae = document.activeElement;
  const focused =
    ae === input ||
    (ae && input.form && (ae === input.form || input.form.contains(ae)));
  return {
    focused: !!focused,
    value: input.value,
    start: input.selectionStart ?? input.value.length,
    end: input.selectionEnd ?? input.value.length,
  };
}

function restoreCompose(snap, forceFocus) {
  const input = composeInput();
  if (!input) return;
  // One-shot prefill for edit start / edit cancel (do not re-apply on later patches).
  if (pendingComposePrefill !== null && pendingComposePrefill !== undefined) {
    const prefill = pendingComposePrefill;
    pendingComposePrefill = null;
    input.value = prefill;
    focusCompose();
    try {
      const len = input.value.length;
      input.setSelectionRange(len, len);
    } catch (_) {}
    return;
  }
  if (snap) {
    // Region morphs remount nodes; re-apply draft + caret when needed.
    if (input.value !== snap.value) input.value = snap.value;
    if (snap.focused || forceFocus) {
      focusCompose();
      try { input.setSelectionRange(snap.start, snap.end); } catch (_) {}
    }
  } else if (forceFocus) {
    focusCompose();
  }
}

let pendingComposeFocus = false;
/** When set (string), next compose restore uses this draft instead of snapshot. */
let pendingComposePrefill = null;
let pendingScrollTo = null;
let searchDebounceTimer = 0;
let lastPushedSearchQ = null;

function searchInput() {
  return document.getElementById('search-input');
}

function snapshotSearch() {
  const input = searchInput();
  if (!input) return null;
  return {
    focused: document.activeElement === input,
    value: input.value,
    start: input.selectionStart ?? input.value.length,
    end: input.selectionEnd ?? input.value.length,
  };
}

function restoreSearch(snap, forceFocus) {
  const input = searchInput();
  if (!input) return;
  if (snap) {
    if (input.value !== snap.value) input.value = snap.value;
    if (snap.focused || forceFocus) {
      try { input.focus({ preventScroll: true }); } catch (_) { input.focus(); }
      try { input.setSelectionRange(snap.start, snap.end); } catch (_) {}
    }
  } else if (forceFocus) {
    try { input.focus({ preventScroll: true }); } catch (_) { input.focus(); }
  }
}

function encodeSearchPayload(q) {
  return 'q=' + escapeLsField(q);
}

function pushSearchQuery(q) {
  if (lastPushedSearchQ === q) return;
  lastPushedSearchQ = q;
  pushEvent('search', encodeSearchPayload(q));
}

function onSearchInput(ev) {
  const t = ev.target;
  if (!t || t.id !== 'search-input') return;
  const q = t.value || '';
  if (searchDebounceTimer) clearTimeout(searchDebounceTimer);
  // Clear / short query: respond quickly; longer queries debounce for FTS.
  const delay = q.trim().length < 2 ? 40 : 180;
  searchDebounceTimer = setTimeout(() => {
    searchDebounceTimer = 0;
    pushSearchQuery(q);
  }, delay);
}

function findMessageRow(mid, root) {
  const scope = root || document.getElementById('messages') || ROOT;
  if (!scope || !mid) return null;
  try {
    return scope.querySelector('[data-msgid=\"' + CSS.escape(mid) + '\"]');
  } catch (_) {
    const safe = mid.split('\"').join('').split('\\\\').join('');
    return scope.querySelector('[data-msgid=\"' + safe + '\"]');
  }
}

// Keep flash visible across Lightspeed remounts of #messages.
let highlightMsgid = null;
let highlightUntil = 0;
let highlightClearTimer = 0;

function applyHighlight(row, mid) {
  if (!row) return;
  row.classList.add('highlight');
  highlightMsgid = mid;
  highlightUntil = Date.now() + 1800;
  if (highlightClearTimer) clearTimeout(highlightClearTimer);
  highlightClearTimer = setTimeout(() => {
    highlightClearTimer = 0;
    const root = document.getElementById('messages');
    const el = root && findMessageRow(mid, root);
    if (el) el.classList.remove('highlight');
    if (highlightMsgid === mid) {
      highlightMsgid = null;
      highlightUntil = 0;
    }
  }, 1800);
}

/** Re-apply highlight after a messages region morph if still within the flash window. */
function restoreHighlightFlash() {
  if (!highlightMsgid || Date.now() > highlightUntil) return;
  const root = document.getElementById('messages');
  const row = root && findMessageRow(highlightMsgid, root);
  if (row && !row.classList.contains('highlight')) {
    row.classList.add('highlight');
  }
}

/** Scroll #messages so `msgid` is centered. Returns true if the row was found.
 *  Uses manual scrollTop — flex + ::before spacer breaks scrollIntoView. */
function scrollToMessage(msgid) {
  const mid = String(msgid || '');
  if (!mid) return false;
  const root = document.getElementById('messages');
  if (!root) return false;
  const row = findMessageRow(mid, root);
  if (!row) return false;
  stickToBottom = false;
  // Center the row inside the scroll container (not the window).
  const rootRect = root.getBoundingClientRect();
  const rowRect = row.getBoundingClientRect();
  const delta =
    rowRect.top + rowRect.height / 2 - (rootRect.top + rootRect.height / 2);
  root.scrollTop += delta;
  applyHighlight(row, mid);
  updateJumpBottomUi();
  return true;
}

/** Try scroll; keep pendingScrollTo until success so history loads can retry. */
function tryPendingScroll() {
  if (!pendingScrollTo) return;
  const mid = pendingScrollTo;
  if (scrollToMessage(mid)) {
    pendingScrollTo = null;
    // Delay clear so the server can keep the highlight class on the row for
    // the flash, then clear_scroll_to remounts without immediately wiping it
    // before the user sees anything. restoreHighlightFlash covers the remount.
    setTimeout(() => {
      pushEvent('clear_scroll_to', '');
      // After clear patch, re-assert class for remaining flash duration.
      setTimeout(restoreHighlightFlash, 30);
      setTimeout(restoreHighlightFlash, 120);
    }, 400);
  }
}

/**
 * Rewrite .ts[data-ts] into the browser's local timezone (12h) and rebuild
 * day separators on local calendar boundaries (web2/web3 parity).
 * Server still emits UTC 12h clocks as a no-JS fallback.
 */
function localizeTimes() {
  const root = document.getElementById('messages');
  if (!root) return;

  root.querySelectorAll('.ts[data-ts]').forEach((el) => {
    const sec = parseInt(el.dataset.ts, 10);
    if (!Number.isFinite(sec)) return;
    const d = new Date(sec * 1000);
    // NBSP so time and AM/PM never wrap onto separate lines.
    el.textContent = d
      .toLocaleTimeString(undefined, {
        hour: 'numeric',
        minute: '2-digit',
        hour12: true,
      })
      .replace(/\\s+/g, String.fromCharCode(160));
  });

  rebuildDateSeparators(root);
}

function localDayKey(d) {
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, '0');
  const day = String(d.getDate()).padStart(2, '0');
  return y + '-' + m + '-' + day;
}

function formatLocalDateLabel(d) {
  const now = new Date();
  const today = localDayKey(now);
  const key = localDayKey(d);
  if (key === today) return 'Today';
  const yest = new Date(now);
  yest.setDate(yest.getDate() - 1);
  if (key === localDayKey(yest)) return 'Yesterday';
  return d.toLocaleDateString(undefined, {
    weekday: 'long',
    month: 'long',
    day: 'numeric',
    year: 'numeric',
  });
}

/**
 * Insert .date-sep rows between message stream items when the local
 * calendar day changes. Rebuilt after every patch so region morphs
 * cannot leave stale separators.
 */
function rebuildDateSeparators(root) {
  if (!root) return;
  root.querySelectorAll('.date-sep').forEach((el) => el.remove());

  let lastDay = null;
  const children = Array.from(root.children);
  for (const node of children) {
    if (node.classList && node.classList.contains('date-sep')) continue;
    // Skip history-loading spinner and flex spacer pseudo-content.
    if (node.classList && node.classList.contains('history-loading')) continue;
    const tsEl = node.querySelector && node.querySelector('.ts[data-ts]');
    if (!tsEl) continue;
    const sec = parseInt(tsEl.dataset.ts, 10);
    if (!Number.isFinite(sec)) continue;
    const d = new Date(sec * 1000);
    const day = localDayKey(d);
    if (day === lastDay) continue;
    lastDay = day;

    const sep = document.createElement('div');
    sep.className = 'date-sep';
    sep.dataset.ts = String(sec);
    sep.dataset.day = day;
    sep.setAttribute('role', 'separator');
    const span = document.createElement('span');
    span.textContent = formatLocalDateLabel(d);
    sep.appendChild(span);
    node.parentNode.insertBefore(sep, node);
  }
}

// Fill reply badges whose parent nick/text was missing when the server
// rendered (parent not yet in history / out of window).
function hydrateReplyBadges() {
  const root = document.getElementById('messages');
  if (!root) return;
  root.querySelectorAll('.reply-badge[data-reply-to]').forEach((badge) => {
    const mid = badge.getAttribute('data-reply-to');
    if (!mid) return;
    const nickEl = badge.querySelector('.reply-nick');
    const textEl = badge.querySelector('.reply-text');
    const needsNick =
      !nickEl || !nickEl.textContent || nickEl.textContent === 'message';
    const needsText = !textEl || !textEl.textContent;
    if (!needsNick && !needsText) return;
    let parent = null;
    try {
      parent = root.querySelector('[data-msgid=\"' + CSS.escape(mid) + '\"]');
    } catch (_) {
      parent = null;
    }
    if (!parent) return;
    if (needsNick && nickEl && parent.dataset.nick) {
      nickEl.textContent = parent.dataset.nick;
    }
    if (parent.dataset.text) {
      const t = parent.dataset.text.replace(/\\s+/g, ' ').trim();
      const snippet = t.length > 80 ? t.slice(0, 80) + '…' : t;
      if (textEl) {
        textEl.textContent = snippet;
      } else if (needsText && snippet) {
        const span = document.createElement('span');
        span.className = 'reply-text';
        span.textContent = snippet;
        badge.appendChild(span);
      }
    }
  });
}

// Message pane: stick to bottom for new traffic; preserve position when
// prepending older history (scroll-to-top load more).
// FAB visibility is geometry-based (not at bottom) except during jumpLock,
// when we hide optimistically while force-scrolling to the end.
let stickToBottom = true;
let loadOlderPending = false;
let loadOlderTimer = 0;
// Jump-to-bottom FAB: unread count while the user is reading history.
let newMsgCount = 0;
// Last (newest) msgid at the bottom of the stream — used to count only
// appends, not older-history prepending.
let lastBottomMsgid = '';
// While Date.now() < jumpLockUntil, hide FAB and keep force-scrolling.
let jumpLockUntil = 0;
let jumpBottomTimers = [];
let ignoreScrollEvents = false;

function messagesEl() {
  return document.getElementById('messages');
}

function jumpBottomEl() {
  return document.getElementById('jump-bottom');
}

function messagesShellEl() {
  const msgs = messagesEl();
  if (msgs && msgs.parentElement && msgs.parentElement.classList.contains('messages-shell')) {
    return msgs.parentElement;
  }
  return document.querySelector('#freeq-chat .messages-shell, .messages-shell');
}

/**
 * Keep shell + FAB as siblings of #messages (outside the Lightspeed
 * messages region). Older builds nested shells inside #messages patches;
 * unwrap that and re-attach a single FAB.
 */
function ensureJumpBottomDom() {
  const msgs = messagesEl();
  if (!msgs) return null;
  let shell = msgs.parentElement;
  // Unwrap accidental nesting: .messages-shell > .messages-shell > #messages
  while (
    shell &&
    shell.classList.contains('messages-shell') &&
    shell.parentElement &&
    shell.parentElement.classList.contains('messages-shell')
  ) {
    const outer = shell.parentElement;
    outer.parentNode.insertBefore(shell, outer);
    outer.remove();
    shell = msgs.parentElement;
  }
  if (!shell || !shell.classList.contains('messages-shell')) {
    shell = document.createElement('div');
    shell.className = 'messages-shell';
    msgs.parentNode.insertBefore(shell, msgs);
    shell.appendChild(msgs);
  }
  // One FAB only, sibling of #messages (not inside the scroll region).
  shell.querySelectorAll('#jump-bottom').forEach((b) => {
    if (b.parentElement !== shell) b.remove();
  });
  document.querySelectorAll('#jump-bottom').forEach((b) => {
    if (b.parentElement !== shell) b.remove();
  });
  let btn = shell.querySelector(':scope > #jump-bottom');
  if (!btn) {
    btn = document.createElement('button');
    btn.type = 'button';
    btn.id = 'jump-bottom';
    btn.className = 'jump-bottom';
    btn.hidden = true;
    btn.setAttribute('aria-label', 'Jump to bottom');
    btn.innerHTML =
      '<svg class=\"jump-bottom-icon\" viewBox=\"0 0 16 16\" width=\"14\" height=\"14\" aria-hidden=\"true\" focusable=\"false\">' +
      '<path fill=\"currentColor\" fill-rule=\"evenodd\" d=\"M8 1a.5.5 0 01.5.5v11.793l3.146-3.147a.5.5 0 01.708.708l-4 4a.5.5 0 01-.708 0l-4-4a.5.5 0 01.708-.708L7.5 13.293V1.5A.5.5 0 018 1z\"/>' +
      '</svg><span class=\"jump-bottom-label\">Jump to bottom</span>';
    shell.appendChild(btn);
  }
  return btn;
}

function nearBottom(el) {
  if (!el) return true;
  // Slack for subpixel + short flicks; still shows FAB after ~1 line scroll.
  return el.scrollHeight - el.scrollTop - el.clientHeight < 80;
}

/** Newest message row id in #messages (last .row[data-msgid] child). */
function lastMessageId(el) {
  if (!el) return '';
  const rows = el.querySelectorAll(':scope > .row[data-msgid]');
  if (!rows.length) return '';
  return rows[rows.length - 1].getAttribute('data-msgid') || '';
}

/** How many rows sit after `msgid` (0 if msgid missing / is last). */
function countRowsAfter(el, msgid) {
  if (!el || !msgid) return 0;
  const rows = el.querySelectorAll(':scope > .row[data-msgid]');
  let idx = -1;
  for (let i = 0; i < rows.length; i++) {
    if ((rows[i].getAttribute('data-msgid') || '') === msgid) {
      idx = i;
      break;
    }
  }
  if (idx < 0) return 0;
  return rows.length - idx - 1;
}

function jumpBottomLabel() {
  if (newMsgCount <= 0) return 'Jump to bottom';
  if (newMsgCount === 1) return '1 new message';
  return newMsgCount + ' new messages';
}

function isJumpLocked() {
  return Date.now() < jumpLockUntil;
}

function updateJumpBottomUi() {
  const el = messagesEl();
  if (!el) return;
  const btn = ensureJumpBottomDom() || jumpBottomEl();
  const shell = messagesShellEl();
  const atBottom = nearBottom(el);
  // freeq-app parity: show whenever scrolled up. jumpLock hides during
  // an in-progress jump so the FAB does not flash mid-scroll.
  const show = !isJumpLocked() && !atBottom;
  if (shell) shell.classList.toggle('is-at-bottom', !show);
  if (!btn) return;
  if (show) {
    btn.hidden = false;
    btn.removeAttribute('hidden');
    btn.style.display = '';
  } else {
    btn.hidden = true;
    btn.setAttribute('hidden', '');
  }
  const label = btn.querySelector('.jump-bottom-label');
  if (label) label.textContent = jumpBottomLabel();
  btn.classList.toggle('has-new', newMsgCount > 0);
  btn.setAttribute('aria-label', jumpBottomLabel());
  bindJumpBottomButton(btn);
}

function resetJumpBottom() {
  newMsgCount = 0;
  lastBottomMsgid = lastMessageId(messagesEl());
  updateJumpBottomUi();
}

/** Clamp scroll position to the true bottom of #messages. */
function scrollMessagesToEnd() {
  const el = messagesEl();
  if (!el) return;
  ignoreScrollEvents = true;
  try {
    el.scrollTop = el.scrollHeight;
    el.scrollTop = Math.max(0, el.scrollHeight - el.clientHeight);
  } finally {
    // scroll events are sync in modern browsers; clear on next task too.
    ignoreScrollEvents = false;
  }
}

function clearJumpBottomTimers() {
  for (const id of jumpBottomTimers) clearTimeout(id);
  jumpBottomTimers = [];
}

function jumpToBottom() {
  const el = messagesEl();
  if (!el) return;
  stickToBottom = true;
  newMsgCount = 0;
  // Hide FAB immediately; keep locked while we force-scroll (tall history).
  jumpLockUntil = Date.now() + 900;
  updateJumpBottomUi();
  clearJumpBottomTimers();
  scrollMessagesToEnd();
  lastBottomMsgid = lastMessageId(el);
  const reassert = () => {
    scrollMessagesToEnd();
    lastBottomMsgid = lastMessageId(messagesEl());
    if (nearBottom(messagesEl())) {
      stickToBottom = true;
      newMsgCount = 0;
      jumpLockUntil = 0;
    }
    updateJumpBottomUi();
  };
  requestAnimationFrame(() => {
    reassert();
    requestAnimationFrame(reassert);
  });
  jumpBottomTimers.push(setTimeout(reassert, 50));
  jumpBottomTimers.push(setTimeout(reassert, 150));
  jumpBottomTimers.push(setTimeout(reassert, 350));
  jumpBottomTimers.push(
    setTimeout(() => {
      reassert();
      // End lock even if geometry is still short — stick intent keeps
      // following new messages; next user scroll will re-show FAB via geometry.
      jumpLockUntil = 0;
      stickToBottom = true;
      updateJumpBottomUi();
    }, 900),
  );
}

/**
 * After a messages patch: if the user is scrolled up and new rows landed
 * below the previous bottom msgid, bump the FAB counter. Prepending older
 * history keeps the same last msgid so it does not inflate the count.
 */
function noteNewMessagesIfScrolledUp(el) {
  if (!el) return;
  const bottom = lastMessageId(el);
  if (stickToBottom || pendingScrollTo || isJumpLocked()) {
    lastBottomMsgid = bottom;
    if (stickToBottom || isJumpLocked()) {
      newMsgCount = 0;
      scrollMessagesToEnd();
    }
    updateJumpBottomUi();
    return;
  }
  if (lastBottomMsgid && bottom && bottom !== lastBottomMsgid) {
    const added = countRowsAfter(el, lastBottomMsgid);
    if (added > 0) newMsgCount += added;
  }
  if (bottom) lastBottomMsgid = bottom;
  updateJumpBottomUi();
}

function bindJumpBottomButton(btn) {
  const el = btn || jumpBottomEl();
  if (!el || el.dataset.freeqJumpBound === '1') return;
  el.dataset.freeqJumpBound = '1';
  el.addEventListener('click', (ev) => {
    ev.preventDefault();
    ev.stopPropagation();
    jumpToBottom();
  });
}

function bindMessagesScroll() {
  ensureJumpBottomDom();
  const el = messagesEl();
  if (!el) return;
  if (el.dataset.freeqScrollBound !== '1') {
    el.dataset.freeqScrollBound = '1';
    el.addEventListener('scroll', onMessagesScroll, { passive: true });
  }
  bindJumpBottomButton();
  updateJumpBottomUi();
}

function onMessagesScroll() {
  const el = messagesEl();
  if (!el) return;
  if (ignoreScrollEvents) return;
  if (isJumpLocked()) {
    // Stay glued while jump animation runs; do not flip stick off mid-jump.
    if (!nearBottom(el)) scrollMessagesToEnd();
    updateJumpBottomUi();
    return;
  }
  // Geometry drives both stick and FAB (freeq-app MessageList parity).
  const atBottom = nearBottom(el);
  stickToBottom = atBottom;
  if (atBottom) {
    newMsgCount = 0;
    lastBottomMsgid = lastMessageId(el);
  }
  updateJumpBottomUi();
  if (!atBottom && el.scrollTop <= 48) requestLoadOlder(el);
}

/** Optimistic spinner at the top of the pane (fetch is often one round-trip). */
function showHistoryLoading(el) {
  if (!el) return;
  let node = el.querySelector(':scope > .history-loading');
  if (node) {
    node.hidden = false;
    return;
  }
  const prevH = el.scrollHeight;
  const prevT = el.scrollTop;
  node = document.createElement('div');
  node.className = 'history-loading';
  node.setAttribute('aria-live', 'polite');
  node.setAttribute('role', 'status');
  const spin = document.createElement('span');
  spin.className = 'history-spinner';
  spin.setAttribute('aria-hidden', 'true');
  const label = document.createElement('span');
  label.className = 'history-loading-text';
  label.textContent = 'Loading older messages…';
  node.appendChild(spin);
  node.appendChild(label);
  // After the flex spacer (::before), as the first real child.
  el.insertBefore(node, el.firstChild);
  // Keep the same messages in view when the spinner grows the top.
  const delta = el.scrollHeight - prevH;
  if (delta > 0) el.scrollTop = prevT + delta;
}

function hideHistoryLoading(el) {
  if (!el) return;
  const node = el.querySelector(':scope > .history-loading');
  if (node) node.remove();
}

function clearLoadOlderPending() {
  loadOlderPending = false;
  if (loadOlderTimer) {
    clearTimeout(loadOlderTimer);
    loadOlderTimer = 0;
  }
}

function requestLoadOlder(el) {
  if (!el) return;
  if (loadOlderPending) return;
  if (el.dataset.historyExhausted === '1') return;
  if (el.dataset.historyLoading === '1') return;
  // Nothing rendered yet — wait for initial history.
  if (!el.querySelector('[data-msgid], .row')) return;
  loadOlderPending = true;
  showHistoryLoading(el);
  pushEvent('load_older', '');
  if (loadOlderTimer) clearTimeout(loadOlderTimer);
  // Safety: unlock if the server never clears loading (offline / empty).
  loadOlderTimer = setTimeout(() => {
    clearLoadOlderPending();
    hideHistoryLoading(messagesEl());
  }, 8000);
}

// Document title badge from sidebar unreads (nav data-unread-total).
const TITLE_BASE = 'freeq · web4';
function syncUnreadTitle() {
  const navEl = document.querySelector('nav[data-ls-region=nav]');
  const raw = navEl && navEl.getAttribute('data-unread-total');
  const n = raw ? parseInt(raw, 10) : 0;
  if (Number.isFinite(n) && n > 0) {
    document.title = '(' + n + ') ' + TITLE_BASE;
  } else {
    document.title = TITLE_BASE;
  }
}

function onFrame(text) {
  const fields = splitFields(text);
  const tag = fields[0];
  if (tag === 'hello') {
    ROOT.classList.add('ls-connected');
    syncUnreadTitle();
    return;
  }
  if (tag === 'diff') {
    const hadCompose = !!composeInput();
    const hadTopic = !!document.getElementById('topic-input');
    const hadSearchInput = !!searchInput();
    const snap = snapshotCompose();
    const searchSnap = snapshotSearch();
    const force = pendingComposeFocus;
    pendingComposeFocus = false;
    const msgsBefore = messagesEl();
    // Preserve viewport when the user is reading history (not stuck to bottom).
    let savedScroll = null;
    if (msgsBefore && !stickToBottom) {
      savedScroll = { h: msgsBefore.scrollHeight, t: msgsBefore.scrollTop };
    }
    applyPatches(fields[2] || '');
    syncUnreadTitle();
    // autofocus only runs on initial HTML parse; re-focus when compose
    // appears after join/open, and restore after morph/send.
    const hasCompose = !!composeInput();
    const topicInput = document.getElementById('topic-input');
    const hasSearch = !!searchInput();
    if (topicInput && !hadTopic) {
      try { topicInput.focus({ preventScroll: true }); } catch (_) { topicInput.focus(); }
      try { topicInput.select(); } catch (_) {}
    } else if (hasSearch && (!hadSearchInput || (searchSnap && searchSnap.focused))) {
      // Prefer search focus while the modal is open.
      restoreSearch(searchSnap, !hadSearchInput);
      if (!hadSearchInput) {
        lastPushedSearchQ = null;
        try { searchInput().select(); } catch (_) {}
      }
    } else {
      restoreCompose(snap, force || (!hadCompose && hasCompose));
      restoreSearch(searchSnap, false);
    }
    const msgs = messagesEl();
    if (msgs) {
      // Server may ask us to land on a msgid (search jump / reply).
      if (msgs.dataset.scrollToMsgid) {
        pendingScrollTo = msgs.dataset.scrollToMsgid;
        stickToBottom = false;
      }
      if (pendingScrollTo) {
        // Do not yank back to bottom while seeking a target.
        stickToBottom = false;
      } else if (savedScroll) {
        msgs.scrollTop = msgs.scrollHeight - savedScroll.h + savedScroll.t;
      } else if (stickToBottom) {
        scrollMessagesToEnd();
      }
      // Server finished the older-page fetch (or still loading async).
      if (msgs.dataset.historyLoading === '1') {
        showHistoryLoading(msgs);
      } else {
        clearLoadOlderPending();
      }
      bindMessagesScroll();
      // Still at the top after prepend? load the next page if more remain.
      // Skip auto-load-older while seeking a jump target (FetchAround owns that).
      if (
        !pendingScrollTo &&
        msgs.scrollTop <= 48 &&
        msgs.dataset.historyLoading !== '1'
      ) {
        requestLoadOlder(msgs);
      }
    } else {
      clearLoadOlderPending();
    }
    hydrateReplyBadges();
    // Date seps change #messages height — measure before/after so scroll sticks.
    const msgsAfter = messagesEl();
    const hBeforeSep = msgsAfter ? msgsAfter.scrollHeight : 0;
    const tBeforeSep = msgsAfter ? msgsAfter.scrollTop : 0;
    localizeTimes();
    if (msgsAfter && !pendingScrollTo) {
      if (stickToBottom) {
        scrollMessagesToEnd();
      } else {
        const grew = msgsAfter.scrollHeight - hBeforeSep;
        if (grew > 0) msgsAfter.scrollTop = tBeforeSep + grew;
      }
    }
    // Search / reply jump after layout settles (region morph + flex spacer).
    if (pendingScrollTo) {
      requestAnimationFrame(() => {
        requestAnimationFrame(() => {
          tryPendingScroll();
          // One more frame if font/layout still settling.
          if (pendingScrollTo) {
            setTimeout(tryPendingScroll, 50);
          }
          noteNewMessagesIfScrolledUp(messagesEl());
        });
      });
    } else {
      // Messages region may have remounted (clear_scroll_to, live PRIVMSG).
      restoreHighlightFlash();
      noteNewMessagesIfScrolledUp(msgsAfter || messagesEl());
    }
    try { if (window.__freeqAv && window.__freeqAv.sync) window.__freeqAv.sync(); } catch (_) {}
    return;
  }
  if (tag === 'ack') return;
  if (tag === 'failure') {
    console.warn('lightspeed failure', fields[2] || fields[1]);
  }
}

function closeDrawers() {
  const sidebar = document.getElementById('sidebar');
  const members = document.getElementById('member-panel');
  const scrim = document.getElementById('drawer-scrim');
  if (sidebar) sidebar.classList.remove('open');
  if (members) members.classList.remove('open');
  if (scrim) scrim.classList.remove('open');
}

function toggleDrawer(which) {
  const sidebar = document.getElementById('sidebar');
  const members = document.getElementById('member-panel');
  const scrim = document.getElementById('drawer-scrim');
  if (!scrim) return;
  const target = which === 'members' ? members : sidebar;
  if (!target) return;
  const opening = !target.classList.contains('open');
  if (sidebar) sidebar.classList.remove('open');
  if (members) members.classList.remove('open');
  if (opening) {
    target.classList.add('open');
    scrim.classList.add('open');
  } else {
    scrim.classList.remove('open');
  }
}

function onClick(ev) {
  // Mobile drawer toggles (People / Channels) — pure client class toggles.
  const drawerBtn = ev.target && ev.target.closest
    ? ev.target.closest('[data-drawer]')
    : null;
  if (drawerBtn && ROOT.contains(drawerBtn)) {
    ev.preventDefault();
    toggleDrawer(drawerBtn.getAttribute('data-drawer') || 'sidebar');
    return;
  }
  const scrim = ev.target && ev.target.id === 'drawer-scrim'
    ? ev.target
    : (ev.target && ev.target.closest ? ev.target.closest('#drawer-scrim') : null);
  if (scrim && ROOT.contains(scrim)) {
    ev.preventDefault();
    closeDrawers();
    return;
  }

  // Jump-to-bottom FAB (client-only; outside Lightspeed click routing).
  const jumpBtn = ev.target && ev.target.closest
    ? ev.target.closest('#jump-bottom')
    : null;
  if (jumpBtn && ROOT.contains(jumpBtn)) {
    ev.preventDefault();
    jumpToBottom();
    return;
  }

  // Reply chip: jump to the original message in the stream.
  const badge = ev.target && ev.target.closest
    ? ev.target.closest('.reply-badge[data-reply-to]')
    : null;
  if (badge && ROOT.contains(badge)) {
    ev.preventDefault();
    const mid = badge.getAttribute('data-reply-to') || '';
    stickToBottom = false;
    pendingScrollTo = mid;
    updateJumpBottomUi();
    if (!scrollToMessage(mid)) {
      // Not loaded — ask server for a history window around it (no ts known).
      pushEvent(
        'jump_to_msg',
        'msgid=' + escapeLsField(mid),
      );
    } else {
      pendingScrollTo = null;
    }
    return;
  }

  // Search hit: close modal, load history around the hit if needed, scroll.
  const searchHit = ev.target && ev.target.closest
    ? ev.target.closest('.search-hit[data-scroll-to]')
    : null;
  if (searchHit && ROOT.contains(searchHit)) {
    ev.preventDefault();
    const mid = searchHit.getAttribute('data-scroll-to') || '';
    const ts = searchHit.getAttribute('data-ts') || '';
    stickToBottom = false;
    pendingScrollTo = mid;
    updateJumpBottomUi();
    // Prefer server jump so unloaded hits are fetched; it also closes search.
    let payload = 'msgid=' + escapeLsField(mid);
    if (ts) payload += '&ts=' + escapeLsField(ts);
    pushEvent('jump_to_msg', payload);
    return;
  }

  const el = ev.target && ev.target.closest ? ev.target.closest('[data-ls-click]') : null;
  if (!el || !ROOT.contains(el)) return;
  const href = el.tagName === 'A' ? el.getAttribute('href') : null;
  // Let modified / non-primary clicks open real hrefs in a new tab.
  if (href && (ev.metaKey || ev.ctrlKey || ev.shiftKey || ev.altKey || ev.button !== 0)) {
    return;
  }
  ev.preventDefault();
  // Navigating / parting closes mobile drawers.
  closeDrawers();
  const name = el.getAttribute('data-ls-click');
  if (!name) return;
  // Patch URL immediately (same as web3 push_patch) so the bar matches.
  if (href && href.startsWith('/chat')) {
    pushPath(href);
  } else if (name === 'part') {
    // Leaving the active channel returns to the directory.
    const li = el.closest('li');
    if (li && li.classList.contains('active')) pushPath('/chat');
  }
  // Channel open / reply / edit steals focus; re-grab compose after the diff
  // (same as web3 focus_compose on navigate / reply).
  if (name === 'open' || name === 'reply' || name === 'edit' || name === 'cancel_reply') {
    pendingComposeFocus = true;
  }
  // Prefill compose from the message row when starting an edit.
  if (name === 'edit') {
    const row = el.closest('[data-msgid]');
    const text = row && row.getAttribute('data-text');
    pendingComposePrefill = text != null ? text : '';
  }
  // Confirm before soft-deleting (freeq-app parity).
  if (name === 'delete') {
    if (!window.confirm('Delete this message?')) return;
  }
  // Cancelling edit clears the draft; cancelling reply keeps typed text.
  if (name === 'cancel_reply') {
    const stack = document.getElementById('compose-stack');
    const mode = stack && stack.dataset ? stack.dataset.composeMode : '';
    const banner = document.getElementById('reply-banner');
    const bannerMode = banner && banner.dataset ? banner.dataset.mode : '';
    if (mode === 'edit' || bannerMode === 'edit') {
      pendingComposePrefill = '';
    }
  }
  // New channel → jump to latest when the history patch lands.
  if (name === 'open' || name === 'join' || name === 'go_index' || name === 'part') {
    stickToBottom = true;
    jumpLockUntil = 0;
    loadOlderPending = false;
    newMsgCount = 0;
    lastBottomMsgid = '';
    clearJumpBottomTimers();
    updateJumpBottomUi();
  }
  const payload = el.getAttribute('data-ls-payload') || '';
  pushEvent(name, payload);
}

function onSubmit(ev) {
  const form = ev.target && ev.target.closest ? ev.target.closest('form[data-ls-submit]') : null;
  if (!form || !ROOT.contains(form)) return;
  ev.preventDefault();
  const name = form.getAttribute('data-ls-submit');
  if (!name) return;
  if (name === 'join') {
    const input = form.querySelector('input[name=\"channel\"]');
    const path = channelPathFromInput(input && input.value);
    if (path) pushPath(path);
    pendingComposeFocus = true;
    stickToBottom = true;
    jumpLockUntil = 0;
    loadOlderPending = false;
    newMsgCount = 0;
    lastBottomMsgid = '';
    updateJumpBottomUi();
  }
  pushEvent(name, formPayload(form));
  if (name === 'send' || form.id === 'send-form') {
    const input = form.querySelector('input[name=\"msg\"]') || composeInput();
    if (input) input.value = '';
    focusCompose();
    // Keep focus after the next diff even if the Send button was active.
    pendingComposeFocus = true;
    tabCycle = null;
    // Scroll now so the user's own send lands at the bottom before the echo.
    jumpToBottom();
  }
}

function onPopState() {
  const path = location.pathname || '/chat';
  ROOT.dataset.lsRoute = path;
  if (path === '/chat' || path === '/chat/' || path === '/') {
    pushEvent('go_index', '');
    return;
  }
  if (path.startsWith('/chat/')) {
    const bare = path.slice('/chat/'.length).replace(/\\/+$/, '');
    if (!bare) {
      pushEvent('go_index', '');
      return;
    }
    pendingComposeFocus = true;
    pushEvent('open', 'channel=' + bare);
  }
}

// IRC-style Tab nick completion (port of freeq-web3 tab_complete.js).
// Event-delegated so Lightspeed region replaces do not drop the handler.
let tabCycle = null;

function channelNicks() {
  const seen = new Set();
  const out = [];
  const push = (n) => {
    n = (n || '').trim();
    if (!n) return;
    const k = n.toLowerCase();
    if (seen.has(k)) return;
    seen.add(k);
    out.push(n);
  };
  const panel = document.getElementById('member-panel');
  if (panel) {
    panel.querySelectorAll('[data-nick]').forEach((el) => push(el.dataset.nick));
    if (out.length) return out;
  }
  document.querySelectorAll('#messages [data-nick]').forEach((el) => push(el.dataset.nick));
  return out;
}

function applyTabMatch(input, wordStart, after, cycle) {
  const nick = cycle.matches[cycle.index];
  // freeq-app style: keep a typed \"@\", use \"nick: \" only at line start.
  const prefix = cycle.hasAt ? '@' : '';
  const suffix = cycle.isStart ? ': ' : ' ';
  const replacement = prefix + nick + suffix;
  let rest = after;
  if (cycle.insertedLen > 0) {
    const already = (input.selectionStart ?? wordStart) - wordStart;
    const leftover = cycle.insertedLen - already;
    if (leftover > 0) rest = rest.slice(leftover);
  }
  input.value = input.value.substring(0, wordStart) + replacement + rest;
  cycle.insertedLen = replacement.length;
  cycle.inserted = replacement;
  const newCursor = wordStart + replacement.length;
  input.setSelectionRange(newCursor, newCursor);
}

function onKeyDown(ev) {
  // Global: Ctrl/Cmd+F opens channel message search (when available).
  if ((ev.metaKey || ev.ctrlKey) && (ev.key === 'f' || ev.key === 'F')) {
    if (document.querySelector('.nav-search-btn, #search-input')) {
      ev.preventDefault();
      if (!document.getElementById('search-input')) {
        pushEvent('open_search', '');
      } else {
        const si = document.getElementById('search-input');
        try { si.focus({ preventScroll: true }); } catch (_) { si.focus(); }
        try { si.select(); } catch (_) {}
      }
      return;
    }
  }

  // Escape closes search modal from anywhere.
  if (ev.key === 'Escape' && document.getElementById('search-input')) {
    ev.preventDefault();
    pushEvent('close_search', '');
    pendingComposeFocus = true;
    tabCycle = null;
    return;
  }

  const t = ev.target;
  if (!t || (t.tagName !== 'INPUT' && t.tagName !== 'TEXTAREA')) return;
  if (!ROOT.contains(t)) return;

  // Escape on topic editor cancels without saving.
  if (ev.key === 'Escape' && (t.id === 'topic-input' || t.name === 'topic')) {
    ev.preventDefault();
    pushEvent('cancel_topic_edit', '');
    pendingComposeFocus = true;
    tabCycle = null;
    return;
  }

  // Search input: realtime via input events; Enter still submits immediately.
  if (t.id === 'search-input' || t.name === 'q') {
    if (ev.key === 'Tab') ev.preventDefault();
    if (ev.key === 'Enter') {
      // Flush debounce so Enter does not wait for the timer.
      if (searchDebounceTimer) {
        clearTimeout(searchDebounceTimer);
        searchDebounceTimer = 0;
      }
      // Let the form submit handler fire; also push now for snappiness.
      pushSearchQuery(t.value || '');
    }
    return;
  }

  if (t.name !== 'msg' && t.id !== 'message-input') return;

  // Escape cancels compose-side reply / edit mode (banner).
  if (ev.key === 'Escape') {
    if (document.getElementById('reply-banner')) {
      ev.preventDefault();
      pendingComposeFocus = true;
      const stack = document.getElementById('compose-stack');
      const mode = stack && stack.dataset ? stack.dataset.composeMode : '';
      const banner = document.getElementById('reply-banner');
      const bannerMode = banner && banner.dataset ? banner.dataset.mode : '';
      if (mode === 'edit' || bannerMode === 'edit') {
        pendingComposePrefill = '';
      }
      pushEvent('cancel_reply', '');
    }
    tabCycle = null;
    return;
  }

  // ArrowUp on empty compose: edit last own message (freeq-app / Slack style).
  if (ev.key === 'ArrowUp' && !(t.value || '').trim()) {
    const ownRows = document.querySelectorAll('#messages .row.own.msg[data-msgid], #messages .row.own[data-msgid]');
    if (ownRows.length) {
      const last = ownRows[ownRows.length - 1];
      const mid = last.getAttribute('data-msgid') || '';
      if (mid) {
        ev.preventDefault();
        pendingComposeFocus = true;
        pendingComposePrefill = last.getAttribute('data-text') || '';
        pushEvent('edit', 'msgid=' + escapeLsField(mid));
        tabCycle = null;
        return;
      }
    }
  }

  if (ev.key !== 'Tab') {
    if (tabCycle && ev.key !== 'Shift') tabCycle = null;
    return;
  }

  ev.preventDefault();
  const input = t;
  const pos = input.selectionStart ?? 0;
  const value = input.value;
  const before = value.substring(0, pos);
  const after = value.substring(pos);

  if (tabCycle) {
    const { wordStart, insertedLen, matches, inserted } = tabCycle;
    const stillThere =
      pos >= wordStart &&
      pos <= wordStart + insertedLen &&
      value.substring(wordStart, wordStart + insertedLen) === inserted;
    if (stillThere) {
      tabCycle.index = (tabCycle.index + 1) % matches.length;
      applyTabMatch(input, wordStart, after, tabCycle);
      return;
    }
    tabCycle = null;
  }

  // Word before caret, optional leading @. IRC nicks: letter/digit/._-
  const m = before.match(/(?:^|[\\s,])(@?[\\w.\\-]*)$/);
  if (!m) return;
  const token = m[1];
  const wordStart = before.length - token.length;
  const hasAt = token.startsWith('@');
  const partial = (hasAt ? token.slice(1) : token).toLowerCase();
  const nicks = channelNicks();
  if (!nicks.length) return;
  const matches =
    partial === ''
      ? nicks.slice()
      : nicks.filter((n) => n.toLowerCase().startsWith(partial));
  if (!matches.length) return;
  tabCycle = {
    matches,
    index: 0,
    wordStart,
    insertedLen: 0,
    inserted: '',
    hasAt,
    isStart: wordStart === 0,
    basePartial: partial,
  };
  applyTabMatch(input, wordStart, after, tabCycle);
}

function connect() {
  socket = new WebSocket(wsUrl());
  socket.addEventListener('open', () => ROOT.classList.add('ls-connected'));
  socket.addEventListener('message', (ev) => onFrame(String(ev.data)));
  socket.addEventListener('close', () => {
    ROOT.classList.remove('ls-connected');
    setTimeout(connect, 1200);
  });
  socket.addEventListener('error', () => { try { socket.close(); } catch (_) {} });
}

// ── Image upload (+ button, paste, optional drop) — freeq-web2 parity ──
const MAX_UPLOAD_BYTES = 10 * 1024 * 1024;
let uploadObjectUrl = null;
let uploading = false;

function authDid() {
  const form = document.getElementById('send-form');
  if (form && form.dataset.authDid && form.dataset.authDid.startsWith('did:')) {
    return form.dataset.authDid;
  }
  const handle = document.getElementById('user-handle');
  if (handle && handle.classList.contains('signed-in') && handle.title && handle.title.startsWith('did:')) {
    return handle.title;
  }
  return '';
}

function channelName() {
  const form = document.getElementById('send-form');
  if (!form) return '';
  const raw = (form.dataset.channel || '').trim();
  if (!raw) return '';
  return raw.startsWith('#') ? raw : '#' + raw;
}

function clearUploadPreview() {
  if (uploadObjectUrl) {
    try { URL.revokeObjectURL(uploadObjectUrl); } catch (_) {}
    uploadObjectUrl = null;
  }
  const preview = document.getElementById('upload-preview');
  const previewImg = document.getElementById('upload-preview-img');
  const previewName = document.getElementById('upload-preview-name');
  const previewStatus = document.getElementById('upload-preview-status');
  const fileInput = document.getElementById('file-input');
  const attachBtn = document.getElementById('attach-btn');
  if (preview) preview.hidden = true;
  if (previewImg) {
    previewImg.removeAttribute('src');
    previewImg.hidden = false;
  }
  if (previewName) previewName.textContent = '';
  if (previewStatus) {
    previewStatus.textContent = '';
    previewStatus.classList.remove('error');
  }
  if (fileInput) fileInput.value = '';
  uploading = false;
  if (attachBtn) attachBtn.disabled = false;
}

function showUploadPreview(file, statusText) {
  const preview = document.getElementById('upload-preview');
  const previewImg = document.getElementById('upload-preview-img');
  const previewName = document.getElementById('upload-preview-name');
  const previewStatus = document.getElementById('upload-preview-status');
  if (!preview) return;
  if (uploadObjectUrl) {
    try { URL.revokeObjectURL(uploadObjectUrl); } catch (_) {}
    uploadObjectUrl = null;
  }
  if (file && file.type && file.type.startsWith('image/') && file.size > 0) {
    uploadObjectUrl = URL.createObjectURL(file);
  }
  if (previewImg) {
    if (uploadObjectUrl) {
      previewImg.src = uploadObjectUrl;
      previewImg.hidden = false;
    } else {
      previewImg.removeAttribute('src');
      previewImg.hidden = true;
    }
  }
  if (previewName) previewName.textContent = (file && file.name) || 'image';
  if (previewStatus) {
    previewStatus.textContent = statusText || '';
    previewStatus.classList.remove('error');
  }
  preview.hidden = false;
}

function setUploadStatus(text, isError) {
  const previewStatus = document.getElementById('upload-preview-status');
  if (!previewStatus) return;
  previewStatus.textContent = text || '';
  previewStatus.classList.toggle('error', !!isError);
}

function sendUrlMessage(url) {
  const input = composeInput();
  if (!input) return;
  const caption = (input.value || '').trim();
  input.value = caption ? caption + ' ' + url : url;
  const form = document.getElementById('send-form');
  if (!form) return;
  if (typeof form.requestSubmit === 'function') form.requestSubmit();
  else form.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }));
}

async function uploadFile(file) {
  if (!file || uploading) return;
  const attachBtn = document.getElementById('attach-btn');
  if (!authDid().startsWith('did:')) {
    showUploadPreview(file, 'Sign in to upload images');
    setUploadStatus('Sign in to upload images', true);
    return;
  }
  if (file.size > MAX_UPLOAD_BYTES) {
    showUploadPreview(file, 'File too large (max 10MB)');
    setUploadStatus('File too large (max 10MB)', true);
    return;
  }
  if (file.type && !file.type.startsWith('image/')) {
    showUploadPreview(file, 'Unsupported type: ' + file.type);
    setUploadStatus('Unsupported type: ' + file.type, true);
    return;
  }
  uploading = true;
  if (attachBtn) attachBtn.disabled = true;
  showUploadPreview(file, 'Uploading…');
  try {
    const fd = new FormData();
    fd.append('file', file, file.name || 'screenshot.png');
    const ch = channelName();
    if (ch) fd.append('channel', ch);
    const input = composeInput();
    const caption = input ? (input.value || '').trim() : '';
    if (caption) fd.append('alt', caption);
    const res = await fetch('/upload', {
      method: 'POST',
      body: fd,
      credentials: 'same-origin',
    });
    let data = {};
    try { data = await res.json(); }
    catch (_) {
      try { data = { error: await res.text() }; } catch (__) { data = {}; }
    }
    if (!res.ok) {
      throw new Error(data.error || data.message || ('Upload failed (' + res.status + ')'));
    }
    if (!data.url) throw new Error('Upload succeeded but no URL returned');
    setUploadStatus('Sending…', false);
    sendUrlMessage(data.url);
    clearUploadPreview();
  } catch (e) {
    console.error('upload', e);
    setUploadStatus((e && e.message) || 'Upload failed', true);
    uploading = false;
    if (attachBtn) attachBtn.disabled = false;
  }
}

function onAttachClick(ev) {
  const btn = ev.target && ev.target.closest ? ev.target.closest('#attach-btn') : null;
  if (!btn || !ROOT.contains(btn)) return;
  ev.preventDefault();
  if (!authDid().startsWith('did:')) {
    showUploadPreview(null, 'Sign in to upload images');
    const previewName = document.getElementById('upload-preview-name');
    if (previewName) previewName.textContent = 'Upload';
    setUploadStatus('Sign in to upload images', true);
    return;
  }
  const fileInput = document.getElementById('file-input');
  if (fileInput) fileInput.click();
}

function onFileChange(ev) {
  const input = ev.target;
  if (!input || input.id !== 'file-input') return;
  const file = input.files && input.files[0];
  if (file) uploadFile(file);
}

function onPaste(ev) {
  const items = ev.clipboardData && ev.clipboardData.items;
  if (!items) return;
  // Image paste anywhere in the chat shell (compose, messages, main column).
  const t = ev.target;
  if (t && t.closest && !t.closest('#freeq-chat, #app')) return;
  for (const item of items) {
    if (item.kind === 'file' && (!item.type || item.type.startsWith('image/'))) {
      const file = item.getAsFile();
      if (file) {
        ev.preventDefault();
        uploadFile(file);
        return;
      }
    }
  }
}

function onDragOver(ev) {
  if (ev.dataTransfer && [...ev.dataTransfer.types].includes('Files')) {
    const t = ev.target;
    if (t && t.closest && t.closest('#send-bar, #compose-stack, #messages, .chat-main')) {
      ev.preventDefault();
    }
  }
}

function onDrop(ev) {
  const t = ev.target;
  if (!t || !t.closest || !t.closest('#send-bar, #compose-stack, #messages, .chat-main')) return;
  if (!ev.dataTransfer || !ev.dataTransfer.files || !ev.dataTransfer.files.length) return;
  ev.preventDefault();
  const file = ev.dataTransfer.files[0];
  if (file) uploadFile(file);
}

function onPreviewCancel(ev) {
  const btn = ev.target && ev.target.closest ? ev.target.closest('#upload-preview-cancel') : null;
  if (!btn || !ROOT.contains(btn)) return;
  ev.preventDefault();
  clearUploadPreview();
}

ROOT.addEventListener('click', onClick);
ROOT.addEventListener('click', onAttachClick);
ROOT.addEventListener('click', onPreviewCancel);
ROOT.addEventListener('change', onFileChange);
ROOT.addEventListener('input', onSearchInput);
ROOT.addEventListener('submit', onSubmit);
// Capture phase so Ctrl+F / Esc work even when focus is outside #app.
document.addEventListener('keydown', onKeyDown);
ROOT.addEventListener('paste', onPaste);
ROOT.addEventListener('dragover', onDragOver);
ROOT.addEventListener('drop', onDrop);
window.addEventListener('popstate', onPopState);
// Align dataset with the real URL (SSR sets data-ls-route; keep them matched).
ROOT.dataset.lsRoute = location.pathname || ROOT.dataset.lsRoute || '/chat';
// Grab chat input on SSR channel pages (autofocus is flaky with module scripts).
focusCompose();
queueMicrotask(focusCompose);
hydrateReplyBadges();
localizeTimes();
bindMessagesScroll();
// Initial channel pages should land at the latest message (after date seps).
{
  const el = messagesEl();
  if (el) {
    stickToBottom = true;
    scrollMessagesToEnd();
    lastBottomMsgid = lastMessageId(el);
  }
  updateJumpBottomUi();
}
connect();
window.__freeq = { pushEvent, pushPath, uploadFile, clearUploadPreview, scrollToMessage, jumpToBottom };
"
}
