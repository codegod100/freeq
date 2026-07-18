# Provenance Log — ios-durable-auth

**Assembly date:** 2026-04-25
**Assembler:** Bridget (context-briefing skill)
**Library status:** No Alexandria library found for this project. Briefing assembled
directly from source files.

## Seeds

| Seed | Rationale |
| --- | --- |
| `freeq-ios/freeq/Models/AppState.swift` | Provided by requester; iOS auth lifecycle |
| `freeq-ios/freeq/ContentView.swift` | Provided by requester; 15 s cliff location |
| `freeq-sdk/src/client.rs` | Provided by requester; Rust SDK transport layer |
| `freeq-sdk-js/src/transport.ts` | Provided by requester; JS prior-art transport |
| `freeq-server/src/web.rs` | Provided by requester; server WebSocket endpoint |
| `freeq-auth-broker/src/main.rs` | Provided by requester; broker /session behaviour |

## Files Read

| File | Lines Read | Decision |
| --- | --- | --- |
| `freeq-ios/freeq/Models/AppState.swift` | Full (1433 lines) | Primary card — iOS auth lifecycle |
| `freeq-ios/freeq/ContentView.swift` | Full (89 lines) | Primary card — 15 s cliff |
| `freeq-sdk/src/client.rs` | 1–120, 650–200, 750–200, 950–200, 1127–200, 1380–100, 1550–100 | Primary card — transport layer |
| `freeq-sdk/Cargo.toml` | Full | Confirmed no `tokio-tungstenite` |
| `freeq-sdk-ffi/src/lib.rs` | 1–400 | Primary card — FFI bridge |
| `freeq-sdk-ffi/Cargo.toml` | Full | Feature flags, dependency list |
| `freeq-sdk-js/src/transport.ts` | Full | Prior-art reference card |
| `freeq-server/src/web.rs` | 1–260 | Server WS endpoint confirmation |
| `freeq-ios/freeq/Models/ServerConfig.swift` | Full | `ircServer` URL (6667 plain TCP) |
| `freeq-auth-broker/src/main.rs` | 1–100, 300–150, 600–150 | Broker /session endpoint |

## Files Not Read (gaps)

| File | Reason |
| --- | --- |
| `freeq-sdk-ffi/src/freeq.udl` | Not located; needed for UDL method signatures |
| `Cargo.toml` (workspace root) | Not read; workspace dep versions unverified |
| `freeq-ios/freeq/Views/ChatDetailView.swift` | Out of scope for auth |

## Retrieval Profile Applied

No formal profile available (no library). Manual traversal: iOS auth lifecycle → Rust SDK
transport → FFI bridge → server endpoint → JS prior art → broker behaviour.
