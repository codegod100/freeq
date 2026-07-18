# freeq Security Audit & Hardening Report

**Date:** 2026-03-29 through 2026-03-31
**Auditor:** Claude Opus 4.6 (automated security review)
**Scope:** freeq-server, freeq-sdk, freeq-app (web client), freeq-auth-broker

---

## Executive Summary

Comprehensive security audit and hardening of the freeq IRC server with AT Protocol
authentication. Over two days, the audit produced **1,420 tests** across all components
and identified **46 bugs**, all of which have been fixed. The system is now significantly
hardened against the threat model of a humanitarian deployment where state-level
adversaries may control federation peers, intercept network traffic, or attempt
identity takeover.

**Key findings and fixes:**
- 6 critical security vulnerabilities patched (secret file permissions, REST API auth
  bypass, message integrity, IRC protocol injection)
- End-to-end encryption pipeline verified (X3DH → Double Ratchet → encrypted messages)
- Federation trust boundary hardened (S2S authorization, sanitization, rate limiting)
- Web client XSS prevention confirmed across 5 attack vectors
- All authentication paths tested adversarially (SASL, broker HMAC, web-token)
- Resource exhaustion limits added (connections, bans, invites, messages, rate limiter state)

---

## Test Coverage

| Component | Tests | Framework |
|-----------|-------|-----------|
| Server (unit) | 102 | Rust #[test] |
| Server (integration) | 536 | Rust #[tokio::test] + raw TCP |
| SDK (unit + integration) | 333 | Rust #[test] |
| Web client (unit) | 397 | vitest |
| Web client (E2E) | 48 | Playwright (headless Chromium) |
| **Total** | **1,420** | |

### Test Suite Inventory

**Server test files:**
- `legacy_irc.rs` — 27 tests: raw TCP IRC compatibility (no SASL, no IRCv3)
- `edge_cases.rs` — 20 tests: protocol boundary conditions
- `nasty_edge_cases.rs` — 23 tests: adversarial protocol abuse
- `protocol_hardening.rs` — 25 tests: RFC compliance, canonicalization
- `bug_hunt.rs` — 40 tests: targeted bug discovery
- `broker_auth.rs` — 20 tests: HMAC verification, replay protection
- `sasl_adversarial.rs` — 17 tests: SASL state machine abuse
- `edit_delete_adversarial.rs` — 15 tests: message edit/delete authorization
- `chathistory_adversarial.rs` — 13 tests: history access control
- `s2s_adversarial.rs` — 12 tests: federation security (env-var gated)
- `multi_device.rs` — 4 tests: ghost sessions, multi-device sync
- `server.rs` (in-crate) — 10 tests: direct S2S message injection

**SDK test files:**
- `sdk_edge_cases.rs` — 149 tests: parser, crypto, auth, bot, SSRF, E2EE, ratchet
- `adversarial.rs` — 78 tests: cross-algorithm confusion, context binding, IPv6
- `e2ee_key_exchange.rs` — 16 tests: X3DH → Ratchet pipeline, GroupKey, DmKey

**Web client test files:**
- `parser.test.ts` — 50 tests: IRC parser fuzzing
- `parser.fuzz.test.ts` — 25 tests: crash cases
- `store.test.ts` — 39 tests: state management
- `store.bugs.test.ts` — 25 tests: bug hunting
- `corner-cases.test.ts` — 98 tests: channels, DMs, WHOIS, modes
- `mega-test.test.ts` — 160 tests: comprehensive coverage
- `adversarial.spec.ts` — 22 tests: XSS, hostile input, UI resilience
- `channel-behavior.spec.ts` — 26 tests: join/part lifecycle, DMs, modes

---

## Bugs Found and Fixed (46 total)

### Critical (6)

| # | Component | Bug | Impact |
|---|-----------|-----|--------|
| 1 | Server | Secret files created with 0644 (world-readable) | Local user reads signing keys, forges messages |
| 2 | Server | REST API channel history exposed without auth for +i/+k | Anyone reads private channel messages |
| 3 | Server | Message edit/delete authorized by nick (not DID) | Attacker edits others' messages via nick change |
| 4 | Server | S2S message fields allow \r\n injection | Inject arbitrary IRC commands to local clients |
| 5 | Server | Broker HMAC timestamp optional (replay attack) | Replay captured broker requests indefinitely |
| 6 | SDK | IRC serialization passes \r\n to wire | Protocol injection via Message::to_string() |

### High (15)

| # | Component | Bug |
|---|-----------|-----|
| 7 | Server | Web-token TTL 30min vs documented 5min |
| 8 | Server | DM flood: no rate limiting (channels only) |
| 9 | Server | OAuth pending/complete maps no TTL (memory DoS) |
| 10 | Server | No channel name (64) or topic (512) length limits |
| 11 | Server | Policy authority_sets UNIQUE constraint crash |
| 12 | Web | WHOIS cache shows stale bluesky link for guests |
| 13 | Web | Auto-rejoin every channel ever joined |
| 14 | Web | localStorage JSON.parse crashes app on corruption |
| 15 | Web | Compound MODE parsing dropped (+ov, +Eo silently ignored) |
| 16 | Web | NICK/JOIN/PART case-sensitive self-detection |
| 17 | SDK | SSRF hostname bypass via trailing dot (localhost.) |
| 18 | SDK | Raw command CRLF injection (Command::Raw) |
| 19 | Server | No global connection limit (only per-IP) |
| 20 | Server | No per-channel ban/invite count limits |
| 21 | Server | No automatic database message pruning |

### Medium (23)

| # | Component | Bug |
|---|-----------|-----|
| 22 | Server | Secrets default to CWD (accidental commit risk) |
| 23 | Server | No REST API rate limiting on proxy endpoints |
| 24 | Server | Crypto-at-rest silent plaintext fallback |
| 25 | Server | NOTICE returns error reply (RFC 2812 violation) |
| 26 | Server | MODE +b accepts whitespace-only ban mask |
| 27 | Server | WHOIS ignores comma-separated nicks |
| 28 | Server | PART missing ERR_NOTONCHANNEL |
| 29 | Server | Nick case-change broken for guests |
| 30 | Web | handleMode creates phantom members |
| 31 | Web | addMember accepts empty/whitespace nicks |
| 32 | Web | renameUser with empty nick creates phantom |
| 33 | Web | removeChannel leaves orphan batches |
| 34 | Web | Empty DID/handle from WHOIS stored as "" |
| 35 | Web | Empty emoji reactions stored |
| 36 | Web | addDmTarget("") creates empty-key channel |
| 37 | Web | editMessage to empty text invisible |
| 38 | Web | setActiveChannel accepts non-existent channels |
| 39 | Web | Typing indicators no auto-timeout |
| 40 | Web | backgroundWhois set no size limit |
| 41 | SDK | ConnectConfig fields not validated |
| 42 | SDK | Jitter uses system time (predictable) |
| 43 | Server | SyncResponse invites merged without limit |
| 44 | Server | Rate limiter state never pruned |

### Low (2)

| # | Component | Bug |
|---|-----------|-----|
| 45 | Web | showJoinPart defaults to false (UX for humanitarian deployment) |
| 46 | Server | HSTS set regardless of TLS scheme |

---

## Security Properties Verified

### Authentication
- [x] SASL challenge single-use (replay fails)
- [x] Challenge expiry enforced (configurable timeout)
- [x] DID format validated, resolution failure = auth failure
- [x] 3-failure disconnect works end-to-end
- [x] Broker HMAC binds timestamp to signature body
- [x] Web-token single-use + 5-minute TTL
- [x] Multi-device ghost session recovery within 30s
- [x] Nick ownership enforced against guests
- [x] ConnectConfig validated before connection

### Authorization
- [x] Channel CHATHISTORY requires membership
- [x] DM CHATHISTORY requires DID authentication
- [x] Third-party DM snooping impossible (canonical_dm_key)
- [x] Edit/delete checks DID for authenticated users
- [x] Ops can delete in channels only (not DMs)
- [x] S2S Mode/Kick/Ban/Topic require op verification
- [x] S2S is_op recalculated from founder_did/did_ops (not trusted from peer)
- [x] Deleted messages excluded from all history queries

### Encryption
- [x] X3DH signature verification prevents MITM on key bundles
- [x] Each X3DH handshake uses fresh ephemeral key (forward secrecy)
- [x] Ratchet replay protection works after session establishment
- [x] Group key binds to channel name + member set + epoch
- [x] DM key binds to both DIDs via ECDH
- [x] Forward secrecy maintained after DH ratchet advancement
- [x] Ed25519 and secp256k1 signatures never cross-verify
- [x] Ciphertext version prefix enforced (ENC1, ENC2, ENC3)

### Federation (S2S)
- [x] Rate limited at 100 events/sec per peer
- [x] CRLF/NUL stripped from all S2S string fields
- [x] Duplicate events rejected by monotonic counter + ring buffer
- [x] Trust levels enforced (Readonly/Relay/Full)
- [x] Channel names truncated to 200 chars
- [x] SyncResponse capped at 500 channels
- [x] Invites capped at 500 per channel in sync

### Web Client
- [x] `<script>` tags rendered as text (React escaping)
- [x] `<img onerror>` rendered as text (no execution)
- [x] `javascript:` URLs not rendered as clickable links
- [x] `data:` URLs not rendered as links
- [x] Markdown `![](javascript:...)` blocked by sanitizeUrl
- [x] localStorage corruption handled via safeJsonParse
- [x] Phantom members prevented (empty nick, MODE on absent user)
- [x] Compound MODE parsing (each char processed individually)

### Resource Exhaustion Protection
- [x] Per-IP connection limit: 20
- [x] Global connection limit: 10,000
- [x] Per-channel ban limit: 500
- [x] Per-channel invite limit: 500
- [x] Message flood limit: 5/2sec (channels + DMs)
- [x] REST API rate limit: 30/60sec per IP
- [x] S2S rate limit: 100 events/sec per peer
- [x] IRC line length limit: 8KB
- [x] Channel name limit: 64 chars
- [x] Topic length limit: 512 chars
- [x] CHATHISTORY limit cap: 500 per request
- [x] Database auto-pruning: 50K messages per channel
- [x] Rate limiter state pruning: entries older than 1 hour
- [x] Typing indicator timeout: 10 seconds
- [x] backgroundWhois cap: 500 entries
- [x] OAuth map TTL: 10 minutes
- [x] Web-token TTL: 5 minutes
- [x] Web session TTL: 24 hours

---

## Remaining Items

| Item | Reason Not Fixed |
|------|------------------|
| OAuth flow end-to-end testing | Requires mock AT Protocol PDS |
| Dedup high-water mark reset on peer disconnect | Architecture decision (clock skew tolerance) |
| DM targets not in channel member lists lose DID | Requires DM-specific member tracking |

---

## Methodology

1. **Code review** — Manual reading of all security-critical paths across 4 codebases
2. **Unit testing** — Parser, crypto, auth, bot, SSRF, E2EE, ratchet, store
3. **Integration testing** — Raw TCP against live server, SDK client against live server
4. **Adversarial testing** — Malformed input, protocol abuse, injection attacks
5. **E2E testing** — Playwright headless Chromium against live server + vite
6. **Direct injection** — S2S messages injected via pub(crate) process_s2s_message()

All tests run in CI-compatible configurations (no external dependencies except for
S2S acceptance tests which require two peered servers).

---

## Files Modified

### Security fixes: 21 files across 4 codebases
### Test files created: 25 new test files
### Documentation: TESTING-SUMMARY.md, AUDIT-REPORT.md, security-audit-2026-03-29.html
