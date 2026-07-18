---
id: FEAT-006
title: "iOS: reconnect UI no longer drops credentials at 15 seconds"
outcome: O-3
tier: must
enabler: false
blocked-by: []
blocks: []
cards: [iOS App Auth Lifecycle]
---

## Motivation

The "Sign in manually" cliff at 15 s is the most user-visible failure. The
timer runs from first `.onAppear` of the reconnecting view, not from each
fresh attempt — so a slow broker can trip the cliff before the second
retry has even started. Then the user taps the button thinking they need
to re-OAuth, when in fact their saved session is still intact. The fix has
two parts: reset the timer per attempt, and remove the implication that
"manual signin" is the only path forward.

## Description

In `freeq-ios/freeq/ContentView.swift`:

1. Reset `reconnectSeconds` to `0` at the start of every reconnect cycle.
   Hook to `appState.connectionState` becoming `.connecting` after a prior
   `.disconnected`, OR add a `reconnectAttempt: Int` counter on `AppState`
   that the view watches and resets on.
2. Raise the cliff threshold from 15 s to 45 s — matches realistic broker
   tail latency.
3. Reframe the button: instead of "Sign in manually" (which sounds like
   *the* fix), label it "Sign in with a different account" and have it
   navigate to ConnectView WITHOUT calling `disconnect()`. Saved session
   stays intact; user can back out.
4. Add a less-alarming control above the cliff button (visible from ~10 s
   onwards) that says e.g. "Network issues? Pull to retry" or just an
   informational subtitle.

In `freeq-ios/freeq/Models/AppState.swift`:

5. Add `@Published var reconnectAttempt: Int = 0` that increments at the
   start of each `reconnectSavedSession()` invocation. ContentView watches
   this to reset its timer.

## Context

- `ContentView.swift:47-87` is the reconnecting view.
- The `userCancelledReconnect` state must remain so the user can opt out
  of auto-reconnect if they really want to.
- Pull-to-refresh already works inside `MessageListView` (we added it
  earlier); the corresponding gesture for the disconnected screen could
  cover this.

## Acceptance Criteria

- [ ] Slowing the broker to 30 s response does NOT show the cliff button
  before 45 s elapsed total.
- [ ] Tapping the cliff button navigates to ConnectView; backing out
  resumes the saved session.
- [ ] `reconnectSeconds` resets every time a fresh reconnect attempt fires.

## Implementation Notes

- The `userCancelledReconnect` flag must NOT clear `brokerToken` —
  re-verify the existing `disconnect()` doesn't do this (it shouldn't —
  only `logout()` does — but worth a check given how often we've revisited
  this code).
