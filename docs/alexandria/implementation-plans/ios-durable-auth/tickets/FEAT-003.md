---
id: FEAT-003
title: "iOS: use WebSocket as primary transport, fall back to TCP after 10s"
outcome: O-1
tier: must
enabler: false
blocked-by: [FEAT-002]
blocks: []
cards: [iOS App Auth Lifecycle]
---

## Motivation

This ticket completes the user-visible part of O-1: iOS prefers WebSocket and
only falls through to TCP if WebSocket genuinely cannot be established. The
result is that on every network where the web client can connect, the iOS app
also connects.

## Description

In `freeq-ios/freeq/Models/ServerConfig.swift`:

1. Add `static var wssServer = "wss://irc.freeq.at/irc"` next to the existing
   `ircServer = "irc.freeq.at:6667"`.

In `freeq-ios/freeq/Models/AppState.swift::connect(nick:)`:

2. After creating the `FreeqClient`, before `client?.connect()`, call
   `try client?.setWebsocketUrl(url: ServerConfig.wssServer)`.
3. Add fallback orchestration: if the SDK's connect emits an
   `Event.Disconnected` within 10 s with reason "WebSocket connect ... timed
   out" or "WebSocket connect ... failed", reissue `connect(nick:)` with the
   websocket URL temporarily cleared so the SDK uses TCP. Track this with a
   per-attempt `transportFallbackUsed` flag so we don't infinitely loop.
4. Persist the fallback choice for the rest of the session (next app launch
   tries WebSocket again — networks can recover).

## Context

- Decision: WebSocket-first with TCP fallback after 10 s timeout (recorded in
  release.md decisions).
- The connect path is `AppState.swift:511-541`. The fallback wiring is tightly
  coupled to the FFI shape from FEAT-002.
- This is the ticket the user will feel: it's where "iOS works on cellular"
  becomes true.

## Acceptance Criteria

- [ ] On a network where both transports work, iOS uses WebSocket (verifiable
  by inspecting `tracing` output from the SDK).
- [ ] On a simulated network that blocks WS upgrade but allows TCP, iOS
  successfully connects via TCP within ~12 s (10 s WS timeout + ~2 s TCP).
- [ ] Fallback only fires once per `connect(nick:)` call — no infinite loop.
- [ ] When the user logs out and back in, the next session attempts WS again.

## Implementation Notes

- Fallback must respect the existing `connectionState` — the user shouldn't
  see a flicker between `.disconnected` and `.connecting` during fallback.
- One way to implement: the SDK's WebSocket-failure event surfaces as a
  specific `Event::Disconnected { reason }` whose reason starts with
  `"WebSocket"`. iOS catches that, calls `disconnect()` cleanly, then re-runs
  `connect(nick:)` with `setWebsocketUrl("")` (empty disables WS).
- An alternative: add `try_websocket: bool` parameter to FFI connect. Less
  clean — prefer the per-call setter.
