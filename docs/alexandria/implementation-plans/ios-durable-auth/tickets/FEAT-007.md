---
id: FEAT-007
title: "SDK: WebSocket heartbeat — 45s ping, 90s dead detection"
outcome: O-4
tier: should
enabler: false
blocked-by: [FEAT-001]
blocks: []
cards: [SDK Transport Layer, JS Transport Prior Art]
---

## Motivation

The JS Transport class (`freeq-sdk-js/src/transport.ts`) sends an IRC `PING`
after 45 s of idle and force-reconnects after 90 s without data. Mirroring
this in the Rust SDK's WebSocket path keeps cellular handoffs (Wi-Fi → LTE)
recoverable without going through the broker for a fresh SASL handshake.

## Description

In `freeq-sdk/src/client.rs`, in the WebSocket branch of `run_irc()`:

1. Spawn a background task that, every 15 s, checks `last_data_received_at`:
   - If `> 45 s` ago: send `PING :keepalive\r\n` over the WS (text frame).
   - If `> 90 s` ago: close the WebSocket (with reason "dead-detection")
     so the outer reconnect loop kicks in.
2. Update `last_data_received_at` on every inbound WS frame.
3. The existing 60 s / 120 s timer in `run_irc()` (lines 1601-1607) is for
   TCP — leave it alone but make sure both paths can't race.

## Context

- JS transport parameters table from CONTEXT_BRIEFING.md, "JS Transport Prior
  Art" card.
- This complements but does not replace the IRC-level heartbeat — the WS
  ping-frame mechanism would also work but the JS implementation uses
  `PRIVMSG`-style PING for compatibility, and we should follow.

## Acceptance Criteria

- [ ] Idle WS connection sends `PING :keepalive` every 45 s of silence.
- [ ] WS connection without inbound data for 90 s closes itself, triggering
  the outer reconnect loop.
- [ ] No interaction with the existing TCP heartbeat path.

## Implementation Notes

- This is a Should — ship after the Must tickets are validated. The Must
  outcomes alone solve the "manually sign in" problem; this is for the
  smoothness of long-running sessions.
