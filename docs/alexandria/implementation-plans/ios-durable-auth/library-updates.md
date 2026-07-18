# Library Updates from iOS durable auth

Ask Conan to review this list and produce a transient surgery plan for Sam
in the conversation, not as a checked-in file.

The project does not yet have a formal Alexandria knowledge graph — Bridget
synthesised the briefing from source. The updates below would seed the
library with the cards we just relied on.

| Action | Card | What Changed | Source |
|--------|------|-------------|--------|
| Create | System - Auth Transport (WebSocket + TCP) | New system: the iOS app speaks IRC over WebSocket primarily, with TCP fallback. The server already supports both. | Step 4, Decision D-1 |
| Create | Component - SDK Transport Layer | New component: `freeq-sdk/src/client.rs::establish_connection`, `establish_ws_connection`, `EstablishedConnection` enum. Owns WebSocket + TCP transports + heartbeat. | Step 2 (briefing) |
| Create | Component - iOS Auth Lifecycle | New component: `AppState.swift` connect / reconnect / scene-phase machinery. Owns broker round-trip discipline + credential persistence. | Step 2 (briefing) |
| Create | Component - JS Transport (reference) | Cross-link from "SDK Transport Layer" card: the JS implementation is canonical for heartbeat / reconnect parameters. | Step 2 (briefing) |
| Create | Artifact - Decision: WebSocket primary, TCP fallback | New decision: iOS attempts WebSocket first, falls back to TCP after 10 s timeout. Confirmed by user 2026-04-26. | Step 4, Decision D-1 |
| Create | Artifact - Decision: Heartbeat parameters mirror JS (45s/90s/2^n*1000 max 30s) | Don't invent new numbers; copy the parameters proven in production by the web client. | Step 4, Decision D-3 |
| Create | Artifact - Decision: 14-day minimum persistent session preserved | Auth credentials are NOT auto-cleared in the first 14 days after login regardless of broker errors. Existing behaviour kept and documented. | Step 4, A-3 |
| Create | Anti-pattern - Do not bypass the SDK with iOS-only auth | Future tickets must keep one transport stack across web/iOS/native. | Step 1 (constraints) |
| Create | Anti-pattern - Do not extend cached web-token TTL beyond server-side TTL | Client cache and server expiry must agree (currently 25 min vs 30 min). | Step 1 (constraints) |
| Create | Anti-pattern - Do not auto-clear broker credentials on transient errors | 502/503/504 must NEVER count toward the 401-clear threshold. | Step 1 (constraints) |
