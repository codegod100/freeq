---
id: FEAT-005
title: "iOS: stricter 401 discrimination + diagnostic logging on credential clear"
outcome: O-2
tier: must
enabler: false
blocked-by: []
blocks: []
cards: [iOS App Auth Lifecycle]
---

## Motivation

`fetchBrokerSession()` already has the right shape — 4-attempt inner retry,
3-strike `consecutive401Count`, 14-day `canAutoClearBrokerCredentials` gate
— but operates blind. We have no way to confirm credentials were cleared
for a genuine reason vs a transient broker bug. Several past "I had to log
in again" reports had no logs to attribute to.

## Description

In `freeq-ios/freeq/Models/AppState.swift::fetchBrokerSession()`:

1. Add an `os.Logger` (or `print` if simpler) at the credential-clear branch
   (line 765-775) that captures:
   - `consecutive401Count`
   - status code of the most recent failure
   - time since `lastLoginDate`
   - whether the broker URL was reachable at all (network error vs HTTP 401)
2. Also log at `connect(nick:)` start whether we're using cached web-token
   or freshly fetched, so retroactive log triage can correlate broker hits
   with foreground events.
3. Verify the existing logic: a 502/503/504 should NEVER increment
   `consecutive401Count`. Add a unit test or a manual verification note.
4. Reset `consecutive401Count` on any `200` response (already done at
   line 780; just confirm and document with a comment).

## Context

- Lines 754-781 in `AppState.swift`: the broker-retry inner loop.
- `consecutive401Count` is `private`; tests will need either to be in the
  same module or to use a debug-only accessor.
- This is independent of FEAT-001/2/3.

## Acceptance Criteria

- [ ] When credentials are auto-cleared, a single log line captures the
  reason. Visible in `Console.app` connected to the device.
- [ ] Simulating a 503 from the broker for 30 s does NOT increment
  `consecutive401Count` (verifiable via debug build).
- [ ] All 200 responses reset the counter to 0.

## Implementation Notes

- `os.Logger(subsystem: "at.freeq.ios", category: "auth")` is the modern way.
- Keep the log under DEBUG-only if there's any concern about leaking
  per-user details to logs visible to other apps; broker token / web token
  must NEVER appear in logs.
