---
id: FEAT-004
title: "iOS: foreground guard skips broker round-trip when transport is alive"
outcome: O-2
tier: must
enabler: false
blocked-by: []
blocks: []
cards: [iOS App Auth Lifecycle]
---

## Motivation

`AppState.handleScenePhase(.active)` fires `reconnectSavedSession()` whenever
`connectionState == .disconnected`, but never asks the SDK whether the
underlying transport is still up. After WebSocket migration this matters
even more: the WS transport survives short backgrounding cleanly, but the
app would tear it down on every wake just to re-fetch a web token.

## Description

In `AppState.handleScenePhase(_:)` (around line 820):

```swift
case .active:
    NotificationManager.shared.clearBadge()
    // If the SDK still has a live connection, don't churn the broker.
    if let c = client, c.isConnected() {
        return
    }
    if connectionState == .disconnected && hasSavedSession {
        brokerRetryCount = 0
        reconnectSavedSession()
    }
```

Verify `FreeqClient.isConnected()` is exposed via the FFI (it is — see
`freeq.swift:isConnected()`).

## Context

- `FreeqClient.isConnected()` is already in the FFI surface; no SDK change
  needed.
- This is independent of FEAT-001/2/3 — pure iOS-side, can land first.

## Acceptance Criteria

- [ ] Foregrounding the app while the connection is alive does NOT call
  `fetchBrokerSession()` (verify by grepping logs / instrumenting a counter).
- [ ] Foregrounding the app while disconnected still triggers
  `reconnectSavedSession()` as before.
- [ ] Pulling network mid-session, then foregrounding after recovery, still
  reconnects.

## Implementation Notes

- This is the cheapest fix in the plan; should land immediately and reduce
  broker load even before WebSocket is in.
