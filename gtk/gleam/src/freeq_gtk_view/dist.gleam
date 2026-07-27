//// Erlang distribution helpers for the view host.
////
//// Intentionally generic over View/Event so this module does not import the
//// parent package (avoids a Gleam import cycle).

import gleam/option.{type Option, None, Some}

@external(erlang, "freeq_gtk_view_ffi", "start_node")
fn start_node_ffi(name: String, cookie: String) -> Result(Nil, String)

@external(erlang, "freeq_gtk_view_ffi", "register_view")
fn register_view_ffi() -> Bool

@external(erlang, "freeq_gtk_view_ffi", "connect")
fn connect_ffi(node: String) -> Bool

@external(erlang, "freeq_gtk_view_ffi", "push_view")
fn push_view_ffi(node: String, view: view) -> Result(Nil, String)

@external(erlang, "freeq_gtk_view_ffi", "recv_event")
fn recv_event_ffi(timeout_ms: Int) -> Result(event, Nil)

@external(erlang, "freeq_gtk_view_ffi", "env_or")
fn env_or_ffi(key: String, default: String) -> String

pub fn start_node(name: String, cookie: String) -> Result(Nil, String) {
  start_node_ffi(name, cookie)
}

pub fn register_view() -> Bool {
  register_view_ffi()
}

pub fn connect(node: String) -> Bool {
  connect_ffi(node)
}

/// Send any term (normally a `freeq_gtk_view.View`) to `{freeq_gtk, Node}`.
pub fn push_view(node: String, view: view) -> Result(Nil, String) {
  push_view_ffi(node, view)
}

/// Next mailbox message, decoded by the FFI into a `freeq_gtk_view.Event`.
pub fn recv_event(timeout_ms: Int) -> Option(event) {
  case recv_event_ffi(timeout_ms) {
    Ok(msg) -> Some(msg)
    Error(_) -> None
  }
}

pub fn env_or(key: String, default: String) -> String {
  env_or_ffi(key, default)
}
