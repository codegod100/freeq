//// freeq-web4 — Gleam Lightspeed LiveView BFF for freeq.
////
//// Stack:
//// - Lightspeed `endpoint` + verified routes + `get_live`
//// - stateful chat component (`freeq_web4/live`)
//// - Lightspeed protocol over WebSocket at `/live` (`freeq_web4/ws`)
//// - Stratus upstream IRC client (`freeq_web4/irc/upstream`)
//// - freeq-server REST via gleam_httpc (`freeq_web4/rest`)

import filepath
import freeq_web4/config
import freeq_web4/live
import freeq_web4/ws
import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http as gleam_http
import gleam/http/request as http_request
import gleam/http/response as http_response
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/string
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

fn enhance_live_html(body: String) -> String {
  body
  |> string.replace(
    "</head>",
    "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
      <> "<meta name=\"color-scheme\" content=\"dark\">"
      <> "<link rel=\"stylesheet\" href=\"/assets/app.css\">"
      <> "<link href=\"https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap\" rel=\"stylesheet\">"
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
) -> http_response.Response(mist.ResponseData) {
  case req.path, req.method, is_websocket_upgrade(req) {
    "/live", gleam_http.Get, True -> upgrade_live(req)

    path, gleam_http.Get, False ->
      case string.starts_with(path, "/chat/") {
        True -> live_html_response(path)
        False -> call_endpoint(req, port, css, client_js)
      }

    _, _, _ ->
      http_response.new(404)
      |> http_response.set_body(mist.Bytes(bytes_tree.from_string("not found")))
  }
}

fn call_endpoint(
  req: http_request.Request(mist.Connection),
  port: Int,
  css: String,
  client_js: String,
) -> http_response.Response(mist.ResponseData) {
  let response =
    req
    |> to_ls_request(port)
    |> endpoint.call(app(css, client_js), _)
    |> to_http_response

  case response.status, http_response.get_header(response, "content-type") {
    200, Ok(ct) ->
      case string.contains(ct, "text/html") {
        True ->
          case response_body_string(response) {
            Ok(body) ->
              response
              |> http_response.set_body(
                mist.Bytes(bytes_tree.from_string(enhance_live_html(body))),
              )
            Error(_) -> response
          }
        False -> response
      }
    _, _ -> response
  }
}

fn live_html_response(
  path: String,
) -> http_response.Response(mist.ResponseData) {
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
  http_response.new(200)
  |> http_response.set_header("content-type", "text/html; charset=utf-8")
  |> http_response.set_body(mist.Bytes(bytes_tree.from_string(body)))
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

  mist.websocket(
    request: req,
    on_init: fn(_conn) {
      let self_subject = process.new_subject()
      let #(session, frames) = ws.mount(path, self_subject)
      #(#(session, frames), Some(ws.push_selector(session)))
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

  let assert Ok(_) =
    mist.new(fn(req) { handle_request(req, port, css, client_js) })
    |> mist.port(port)
    |> mist.start

  echo_banner(port)
  process.sleep_forever()
}

fn echo_banner(port: Int) -> Nil {
  let base = "http://127.0.0.1:" <> int.to_string(port)
  io_println("freeq-web4 (Lightspeed) at " <> base)
  io_println("  GET  /chat            channel list")
  io_println("  GET  /chat/:channel   chat shell")
  io_println("  WS   /live            lightspeed protocol")
  io_println("  GET  /health          ok")
  io_println("  upstream " <> config.upstream_ws())
  io_println("  rest     " <> config.upstream_rest())
}

@external(erlang, "io", "format")
fn io_format(fmt: String, args: List(String)) -> Nil

fn io_println(line: String) -> Nil {
  io_format("~s~n", [line])
}

fn load_asset(name: String) -> String {
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
    Error(_) -> "/* missing asset: " <> name <> " */"
  }
}

// ── Browser client (star-style, freeq events) ────────────────────────────────

fn freeq_client_js() -> String {
  "const ROOT = document.getElementById('app');
if (!ROOT) throw new Error('Lightspeed: #app missing');

const wsPath = ROOT.dataset.lsWs || '/live';
const route = ROOT.dataset.lsRoute || '/chat';
const proto = location.protocol === 'https:' ? 'wss' : 'ws';
const url = proto + '://' + location.host + wsPath + '?path=' + encodeURIComponent(route);

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

function formPayload(form) {
  try {
    const data = new FormData(form);
    const parts = [];
    for (const [k, v] of data.entries()) {
      // Lightspeed form.parse does not percent-decode; only escape &/=.
      const ek = String(k).replace(/&/g, '%26').replace(/=/g, '%3D');
      const ev = String(v).replace(/&/g, '%26').replace(/=/g, '%3D');
      parts.push(ek + '=' + ev);
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

function applyPatches(encoded) {
  if (!encoded) return;
  const parts = splitFields(encoded);
  let i = 0;
  if (parts[0] === 'ps') i = 3;
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

function onFrame(text) {
  const fields = splitFields(text);
  const tag = fields[0];
  if (tag === 'hello') {
    ROOT.classList.add('ls-connected');
    return;
  }
  if (tag === 'diff') {
    applyPatches(fields[2] || '');
    const msgs = document.getElementById('messages');
    if (msgs) msgs.scrollTop = msgs.scrollHeight;
    return;
  }
  if (tag === 'ack') return;
  if (tag === 'failure') {
    console.warn('lightspeed failure', fields[2] || fields[1]);
  }
}

function onClick(ev) {
  const el = ev.target && ev.target.closest ? ev.target.closest('[data-ls-click]') : null;
  if (!el || !ROOT.contains(el)) return;
  ev.preventDefault();
  const name = el.getAttribute('data-ls-click');
  if (!name) return;
  const payload = el.getAttribute('data-ls-payload') || '';
  pushEvent(name, payload);
}

function onSubmit(ev) {
  const form = ev.target && ev.target.closest ? ev.target.closest('form[data-ls-submit]') : null;
  if (!form || !ROOT.contains(form)) return;
  ev.preventDefault();
  const name = form.getAttribute('data-ls-submit');
  if (!name) return;
  pushEvent(name, formPayload(form));
  if (name === 'send') {
    const input = form.querySelector('input[name=\"msg\"]');
    if (input) input.value = '';
  }
}

function connect() {
  socket = new WebSocket(url);
  socket.addEventListener('open', () => ROOT.classList.add('ls-connected'));
  socket.addEventListener('message', (ev) => onFrame(String(ev.data)));
  socket.addEventListener('close', () => {
    ROOT.classList.remove('ls-connected');
    setTimeout(connect, 1200);
  });
  socket.addEventListener('error', () => { try { socket.close(); } catch (_) {} });
}

ROOT.addEventListener('click', onClick);
ROOT.addEventListener('submit', onSubmit);
connect();
window.__freeq = { pushEvent };
"
}
