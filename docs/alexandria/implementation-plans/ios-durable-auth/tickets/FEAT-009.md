---
id: FEAT-009
title: "Integration tests for WebSocket transport + reconnect cycle"
outcome: O-5
tier: could
enabler: false
blocked-by: [FEAT-001]
blocks: []
cards: [SDK Transport Layer]
---

## Motivation

We've tried to fix iOS auth durability several times. Pinning the new
transport behavior with tests means the next regression gets caught in CI
instead of in production reports.

## Description

Add to `freeq-sdk/tests/`:

1. `ws_connect_happy_path` — start a mock WebSocket server that speaks the
   IRC handshake (CAP, SASL, 001), drive `establish_ws_connection()` against
   it, assert `Event::Registered` arrives.
2. `ws_connect_timeout` — point at a non-routable address (e.g.
   `wss://192.0.2.1/irc` from RFC 5737), assert connect returns within 11 s
   with a timeout error.
3. `ws_dead_detection` — drive a connection, then have the mock server stop
   responding; assert that ~90 s later the SDK closes the socket.
4. `ws_auto_reconnect` — drive a connection, server kills the socket, mock
   accepts a new one within the backoff window, assert SDK rejoins the
   channels via the same credentials (no fresh SASL).
5. `tcp_fallback_after_ws_failure` — point WS URL at unreachable, TCP at a
   working mock; assert the SDK falls through to TCP within ~12 s.

## Context

- Existing test infrastructure: `freeq-server/tests/multi_device.rs` shows
  the pattern for spinning up a server in-process.
- The mock WS server can be a thin axum handler; mirror what the production
  server does at `freeq-server/src/web.rs:bridge_ws()`.

## Acceptance Criteria

- [ ] All five tests pass on `cargo test -p freeq-sdk --features websocket`.
- [ ] Tests run in < 60 s total (so they don't slow CI).
- [ ] Tests do not depend on `irc.freeq.at` — fully local.

## Implementation Notes

- Mock WS server: spawn axum `Router::new().route("/irc", get(ws_upgrade))`
  on a `TcpListener::bind("127.0.0.1:0")`.
- For the timeout test, RFC 5737 reserves `192.0.2.0/24` for documentation;
  it's safe to use as an unreachable address.
- For dead-detection, sleep slightly over 90 s — the test can use
  `tokio::time::pause()` if the SDK exposes a `Clock` abstraction;
  otherwise just live-time it.
