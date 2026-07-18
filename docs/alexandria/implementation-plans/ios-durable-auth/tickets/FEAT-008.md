---
id: FEAT-008
title: "SDK: transport-level auto-reconnect with exponential backoff"
outcome: O-4
tier: should
enabler: false
blocked-by: [FEAT-001]
blocks: []
cards: [SDK Transport Layer, JS Transport Prior Art]
---

## Motivation

Today the iOS app drives reconnect at the application layer — every reconnect
goes through `disconnect()` → `reconnectSavedSession()` → broker → fresh
`FreeqClient`. Mirroring the JS transport's reconnect loop inside the SDK
means a transient network blip can be recovered without paying the broker
round-trip cost.

## Description

In `freeq-sdk/src/client.rs`:

1. After a clean transport-level disconnect (WS close, TCP RST, dead detection
   from FEAT-007), if the disconnect was NOT triggered by an explicit user
   `disconnect()` call, schedule a reconnect after
   `min(1000 * 2^attempt, 30000)` ms.
2. Reuse the same SASL credentials (`web_token`) for the retry — no broker
   trip.
3. Cap retries at e.g. 8 attempts before giving up and surfacing
   `Event::Disconnected { reason: "exhausted" }` so iOS goes through the
   broker.
4. Reset attempt counter on successful registration.

## Context

- JS implementation in `freeq-sdk-js/src/transport.ts` lines 121-130 — same
  pattern.
- This is a behavior change that affects ALL clients (TUI, native CLI, iOS).
  Document in release notes.

## Acceptance Criteria

- [ ] Killing the WS server briefly (5 s) and restoring it: SDK reconnects
  automatically without iOS-side intervention.
- [ ] Killing the server for longer than 8 retries (~256 s) surfaces
  `Event::Disconnected { reason: "exhausted" }` so the application can do
  whatever it wants.
- [ ] Explicit `disconnect()` does NOT trigger the auto-reconnect loop.

## Implementation Notes

- The `intentionalClose` flag in JS Transport is the cleanest pattern.
  Mirror in Rust as a `should_reconnect: AtomicBool` on the connection
  state.
- Test against a mock WS server that closes the socket randomly.
