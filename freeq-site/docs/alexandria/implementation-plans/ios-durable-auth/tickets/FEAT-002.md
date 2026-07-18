---
id: FEAT-002
title: "FFI: expose WebSocket URL setter on FreeqClient"
outcome: O-1
tier: must
enabler: false
blocked-by: [FEAT-001]
blocks: [FEAT-003]
cards: [FFI Binding Layer]
---

## Motivation

iOS speaks to the Rust SDK exclusively through the UniFFI-generated bindings.
For iOS to opt into the new WebSocket transport, the FFI must expose either a
constructor argument or a setter that lets Swift pass `wss://irc.freeq.at/irc`
into the SDK before `connect()`.

## Description

In `freeq-sdk-ffi`:

1. Add a public method on `FreeqClient`:
   ```rust
   pub fn set_websocket_url(&self, url: String) -> Result<(), FreeqError>
   ```
   Stores the URL alongside the existing pending fields (web_token, etc.).
2. Update the UDL file (`freeq-sdk-ffi/src/freeq.udl`) to declare the new
   method on the `FreeqClient` interface.
3. In `connect()` (around lines 197–244), if a websocket URL has been set,
   call `freeq_sdk::client::connect_websocket(...)` (or whatever the SDK
   exposes from FEAT-001) instead of `establish_connection()`.
4. Re-run `uniffi-bindgen` to regenerate the Swift bindings.
5. Make the `freeq-sdk` `websocket` feature a default feature of
   `freeq-sdk-ffi` so iOS framework builds always include it.

## Context

- Prior art: `set_web_token` already exists on `FreeqClient` and follows the
  same setter-then-connect pattern. Use the identical shape.
- The FFI `connect()` builds `ConnectConfig` inline (lib.rs:197-213); add a
  branch for the WebSocket path that calls into the SDK's WS connect.
- Run `./freeq-ios/build-rust.sh` to regenerate the xcframework + Swift
  bindings.

## Acceptance Criteria

- [ ] `Generated/freeq.swift` contains `func setWebsocketUrl(url: String) throws`
  on `FreeqClient`.
- [ ] iOS app compiles cleanly against the new bindings.
- [ ] Calling `setWebsocketUrl(url:)` then `connect()` results in the SDK
  using the WebSocket transport (verify via tracing log).
- [ ] If WebSocket URL is unset, `connect()` falls through to TCP unchanged
  (no behaviour change for existing callers).

## Implementation Notes

- UDL syntax for a method:
  ```
  void set_websocket_url(string url);
  ```
  inside the `FreeqClient` interface block. Verify against existing entries
  for `set_web_token` and `set_platform` — copy exact style.
- The `FreeqClient` struct in `lib.rs` likely needs a new field
  `websocket_url: Mutex<Option<String>>` parallel to `pending_web_token`.
