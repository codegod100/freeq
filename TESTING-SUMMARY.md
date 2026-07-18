# freeq Testing & Security Audit Summary

## Test Counts

| Component | Tests | Passing |
|-----------|-------|---------|
| Server (Rust) | 642 | 642 |
| SDK (Rust) | 333 | 333 |
| Web Client (vitest) | 397 | 397 |
| Web Client (Playwright E2E) | 48 | 48 |
| **Total** | **1,420** | **1,420** |

## Bugs Found and Fixed

### Security Fixes (Round 1 — security audit)
| # | Severity | Bug | Fix |
|---|----------|-----|-----|
| 1 | **Critical** | Secret files world-readable (0644) | Write with 0600, tighten on load |
| 2 | **High** | Broker HMAC replay (timestamp optional) | Require timestamp, bind to MAC |
| 3 | **High** | Web-token TTL 30min vs documented 5min | Reduced to 300s |
| 4 | **Medium** | Secrets default to CWD | Platform state dir default |
| 5 | **Medium** | No REST API rate limiting | Per-IP rate limiter on /og, /blob, /upload |
| 6 | **Medium** | Crypto-at-rest silent plaintext fallback | Hard error on encrypt/decrypt failure |

### Security Fixes (Round 2 — deep audit)
| # | Severity | Bug | Fix |
|---|----------|-----|-----|
| 7 | **Critical** | REST API history no auth for +i/+k channels | Returns 403 for restricted channels |
| 8 | **Critical** | Edit/delete auth used nick not DID | DID-based authorship check |
| 9 | **Critical** | S2S fields allow IRC protocol injection | sanitize_s2s_str strips \r\n\0 |
| 10 | **High** | OAuth maps no TTL (memory exhaustion) | 10-minute TTL with periodic cleanup |
| 11 | **High** | No channel name/topic length limits | 64 char / 512 char limits |

### Bug Fixes (testing rounds)
| # | Severity | Bug | Fix |
|---|----------|-----|-----|
| 12 | **High** | DM flood: no rate limiting | Flood check applies to all messages |
| 13 | **High** | Policy UNIQUE constraint on authority_sets | INSERT OR IGNORE |
| 14 | **High** | WHOIS cache shows stale bluesky link for guests | Clear DID/handle on new WHOIS 311 |
| 15 | **High** | Auto-rejoin every channel ever joined | Server-only auto-rejoin for DID users |
| 16 | **High** | localStorage JSON.parse crashes app on corruption | safeJsonParse helper |
| 17 | **High** | IRC serialization CRLF injection (SDK) | Strip \r\n\0 from all output fields |
| 18 | **High** | SSRF hostname bypass via trailing dot | Strip trailing dot before check |
| 19 | **Medium** | NOTICE returns error reply (RFC violation) | Suppress errors for NOTICE |
| 20 | **Medium** | MODE +b accepts whitespace ban mask | Trim and reject empty masks |
| 21 | **Medium** | WHOIS ignores comma-separated nicks | Split and process each nick |
| 22 | **Medium** | PART missing ERR_NOTONCHANNEL | Added membership check |
| 23 | **Medium** | Nick case-change broken for guests | Added in_use_by_self check |
| 24 | **Medium** | Web: handleMode creates phantom members | Only apply if member exists |
| 25 | **Medium** | Web: addMember accepts empty nicks | Reject empty/whitespace |
| 26 | **Medium** | Web: renameUser with empty nick | Reject empty/whitespace |
| 27 | **Medium** | Web: removeChannel leaves orphan batches | Clean up batches on remove |
| 28 | **Medium** | Web: NICK/JOIN/PART case-sensitive self-detection | toLowerCase() comparison |
| 29 | **Medium** | Web: compound MODE parsing dropped (+ov, +Eo) | Parse each mode char individually |
| 30 | **Medium** | Web: empty DID/handle stored as "" not undefined | Use undefined for empty values |
| 31 | **Medium** | Web: empty emoji reactions stored | Reject empty emoji |
| 32 | **Medium** | Web: addDmTarget("") creates empty-key channel | Reject empty nick |
| 33 | **Medium** | Web: editMessage to empty text invisible | Show [message cleared] placeholder |
| 34 | **Medium** | Web: setActiveChannel accepts non-existent channels | Validate channel exists |
| 35 | **Low** | showJoinPart defaults to false | Changed to default-on |

### Total: 35 bugs found and fixed

## Test Suites Created

### Server (Rust)
| File | Tests | Focus |
|------|-------|-------|
| `tests/legacy_irc.rs` | 27 | Raw TCP IRC compatibility |
| `tests/edge_cases.rs` | 20 | Protocol boundary conditions |
| `tests/nasty_edge_cases.rs` | 23 | Adversarial protocol abuse |
| `tests/protocol_hardening.rs` | 25 | RFC compliance, parser safety |
| `tests/bug_hunt.rs` | 40 | Targeted bug discovery |
| `tests/broker_auth.rs` | 20 | HMAC verification, replay protection |
| `tests/sasl_adversarial.rs` | 17 | SASL state machine abuse |
| `tests/edit_delete_adversarial.rs` | 15 | Message edit/delete authorization |
| `tests/chathistory_adversarial.rs` | 13 | History access control, DM privacy |
| `tests/s2s_adversarial.rs` | 12 | Federation trust boundary |
| `tests/multi_device.rs` | 4 | Ghost sessions, multi-device sync |
| `src/server.rs` (in-crate) | 10 | Direct S2S message injection |

### SDK (Rust)
| File | Tests | Focus |
|------|-------|-------|
| `tests/sdk_edge_cases.rs` | 149 | Parser, crypto, auth, bot, SSRF, E2EE, ratchet |
| `tests/adversarial.rs` | 78 | Cross-algorithm confusion, context binding, IPv6 SSRF |
| `tests/e2ee_key_exchange.rs` | 16 | X3DH → Ratchet full pipeline, GroupKey, DmKey |

### Web Client (TypeScript)
| File | Tests | Focus |
|------|-------|-------|
| `src/irc/parser.test.ts` | 50 | IRC parser fuzzing |
| `src/irc/parser.fuzz.test.ts` | 25 | Parser crash cases |
| `src/store.test.ts` | 39 | Store state management |
| `src/store.bugs.test.ts` | 25 | Store bug hunting |
| `src/corner-cases.test.ts` | 98 | Channels, DMs, WHOIS, modes, batches |
| `src/mega-test.test.ts` | 160 | Comprehensive store coverage |

### Web Client (Playwright E2E)
| File | Tests | Focus |
|------|-------|-------|
| `e2e/adversarial.spec.ts` | 22 | XSS prevention, hostile input, UI resilience |
| `e2e/channel-behavior.spec.ts` | 26 | Join/part lifecycle, DMs, modes, nicks |

## Security Properties Confirmed

### Authentication
- SASL challenge single-use (replay fails)
- Challenge expiry enforced (configurable timeout)
- DID format validated, resolution failure = auth failure
- 3-failure disconnect works end-to-end
- Broker HMAC binds timestamp to signature
- Web-token single-use + 5-minute TTL

### Authorization
- Channel CHATHISTORY requires membership
- DM CHATHISTORY requires authentication
- Third-party DM snooping impossible (canonical_dm_key binds to requester)
- Edit/delete checks DID (not nick) for authenticated users
- Ops can delete in channels, not DMs
- Mode/Kick/Ban from S2S non-op rejected

### Encryption
- X3DH signature verification prevents MITM
- Each handshake uses fresh ephemeral key
- Ratchet replay protection works
- Group key binds to channel + members + epoch
- DM key binds to both DIDs via ECDH
- Forward secrecy maintained after DH ratchet step

### Federation (S2S)
- Rate limited at 100 events/sec per peer
- CRLF injection stripped from all S2S fields
- Duplicate events rejected by dedup
- Trust levels enforced (Readonly/Relay/Full)
- Channel names truncated to 200 chars

### Web Client
- All 5 XSS vectors blocked (script, img onerror, javascript:, data:, markdown)
- React rendering prevents script execution
- localStorage corruption handled gracefully
- Phantom members prevented
- Empty/whitespace nicks rejected

## Additional Fixes (final round)

| # | Fix | Details |
|---|-----|---------|
| 36 | Per-channel ban limit (500) | Prevents memory/DB exhaustion via MODE +b spam |
| 37 | Per-channel invite limit (500) | Prevents invite HashSet exhaustion |
| 38 | Global connection limit (10,000) | Prevents distributed DoS (was per-IP only) |
| 39 | SDK raw command CRLF injection | Strips \r\n\0 from Command::Raw before wire |

### Total: 39 bugs found and fixed

## Remaining Open Items

### S2S Federation
- ~~`is_op` flag accepted without DID authority proof~~ **ALREADY FIXED** (recalculated from founder_did/did_ops)
- SyncResponse invites merged without founder authority check
- Dedup high-water mark resets on peer disconnect

### Web Client
- Typing indicators have no auto-timeout
- backgroundWhois set has no size limit
- DM targets not in any channel member list lose DID updates

### SDK
- `oauth.rs` has zero test coverage (requires mock PDS)
- `ConnectConfig` fields not validated
- Jitter function uses system time instead of crypto random

### Server
- No automatic database message pruning
- OAuth flow requires real PDS (untestable in unit tests)
