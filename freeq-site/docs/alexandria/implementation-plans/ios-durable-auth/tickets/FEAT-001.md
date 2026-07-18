---
id: FEAT-001
title: "SDK WebSocket transport with connect timeouts (TCP + WS)"
outcome: O-1
tier: must
enabler: false
blocked-by: []
blocks: [FEAT-002, FEAT-007, FEAT-008, FEAT-009]
cards: [SDK Transport Layer, JS Transport Prior Art]
---

## Motivation

The Rust SDK currently only speaks raw TCP and `TcpStream::connect()` has no
timeout — the root cause of indefinite hangs on networks that block port 6667.
WebSocket transport over `wss://host/irc` exists on the server side and is
proven by the web client; the Rust SDK simply doesn't use it. This ticket
adds the transport itself and a 10 s connect timeout that applies to both
TCP and WS paths.

## Description

In `freeq-sdk`:

1. Add `tokio-tungstenite` and `tungstenite` to `Cargo.toml` under a new
   `websocket` feature flag. Pick a version compatible with the existing
   `tokio` 1.x and `rustls` 0.23 + `aws-lc-rs` (or `ring`) feature set used
   by `freeq-sdk-ffi`.
2. Add a `WebSocket(...)` arm to `EstablishedConnection` (line 713 area)
   wrapping `tokio_tungstenite::WebSocketStream<MaybeTlsStream<TcpStream>>`.
3. Implement `establish_ws_connection(url: &str) -> Result<EstablishedConnection>`:
   - Use `tokio_tungstenite::connect_async()` wrapped in
     `tokio::time::timeout(Duration::from_secs(10), ...)`.
   - On `Elapsed`, return a clear error `"WebSocket connect to {url} timed out after 10s"`.
4. Wrap the existing `TcpStream::connect()` in `establish_connection()` with
   the same 10 s timeout.
5. Wire the WebSocket variant through `run_irc()` — bridge the WS framed
   bytes to/from a `tokio::io::DuplexStream`, mirroring the server-side
   `bridge_ws()` in `freeq-server/src/web.rs`.

## Context

- Server endpoint: `wss://irc.freeq.at/irc`, defined at
  `freeq-server/src/web.rs:173`. SASL handshake identical to TCP, no server
  changes needed.
- Prior art for parameters: `freeq-sdk-js/src/transport.ts` — proven in
  production.
- Existing `Iroh(DuplexStream)` arm in `EstablishedConnection` is the
  template — same DuplexStream bridging pattern applies.
- `tokio-tungstenite` is currently absent from
  `freeq-sdk/Cargo.toml` AND `freeq-sdk-ffi/Cargo.toml`. Add it to
  `freeq-sdk` and propagate the `websocket` feature through
  `freeq-sdk-ffi`'s default features.

## Acceptance Criteria

- [ ] `cargo build -p freeq-sdk --features websocket` succeeds.
- [ ] `establish_connection()` returns within 10 s on a port-blocked
  destination, with a `Result::Err` whose message names the timeout.
- [ ] `establish_ws_connection()` returns within 10 s on an unreachable
  WebSocket URL.
- [ ] A test (`cargo test -p freeq-sdk --features websocket ws_connect`)
  successfully drives a registration over WS against a mock server.
- [ ] No regression in TCP path: existing TUI / native client builds and
  connects unchanged.

## Implementation Notes

- The DuplexStream bridge: spawn two background tasks per WS connection,
  one forwarding `WsMessage::Text` / `WsMessage::Binary` from the WS into
  the read half of the DuplexStream, the other forwarding writes from the
  DuplexStream out as WS messages. Mirror exactly the `bridge_ws()` impl in
  the server.
- For TLS chained through `MaybeTlsStream`, prefer `aws-lc-rs` to match
  `freeq-sdk-ffi`'s existing crypto provider — verify by running both
  crates' tests with the chosen version.
- Bridget flagged: `tokio-tungstenite` version compatibility with rustls
  0.23 must be confirmed before commit. If a clean version doesn't exist,
  open a SPIKE-NNN to investigate.
