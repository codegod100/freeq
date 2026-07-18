# Context Briefing

## Task Frame

**Task:** iOS Durable Auth — make authentication survive cellular transitions, port-blocking
firewalls, app backgrounding, and brief broker/PDS outages. The user should see the OAuth
screen only on explicit logout, DID switch, or upstream refresh-token revocation.

**Target type:** Component (Rust SDK transport layer) + System (iOS app auth lifecycle)

**Task type:** Feature / Refactor (new capability in SDK; behaviour change in iOS connect
path)

**Constraints:**
- One transport stack across web/iOS/native — no iOS-only auth bypass
- Cached web-token TTL must not exceed the server-side TTL (currently 30 min; app caches
  for 25 min)
- Do not auto-clear broker credentials on transient broker errors
- No server-side SASL changes beyond what is needed to support the WebSocket transport
  (the server already supports WebSocket; the SDK does not yet use it)
- OAuth/PDS storage architecture is out of scope
- Watch-app auth is out of scope

**Acceptance criteria:**
1. iOS app connects via `wss://irc.freeq.at/irc` (WebSocket), not raw TCP
2. SDK WebSocket transport has connect timeout, ping/dead-connection detection, and
   exponential-backoff reconnect — parity with the JS `Transport` class
3. `consecutive401Count` logic correctly exempts transient broker 502/503 from credential
   clearing; genuine 401s only clear after the 3-count + 14-day threshold already in place
4. `handleScenePhase(.active)` does not hit the broker if the existing IRC connection is
   still alive (connection check before broker round-trip)
5. The 15-second "Sign in manually" cliff in `ContentView` is removed or its timer is
   reset on each reconnect attempt rather than running continuously from first `onAppear`

---

## Primary Cards (full content)

No formal Alexandria library exists for this project. The following "cards" are synthesised
directly from source files. Full content is given as code-referenced analysis.

---

### SDK Transport Layer — `freeq-sdk/src/client.rs`

**Type:** Component (Rust SDK)
**Relevance:** The single most load-bearing file for this plan. All three transport gaps
(no WebSocket, no connect timeout, no SDK-level backoff) live here.

**WHAT:**
The SDK exposes `connect()` → `(ClientHandle, Receiver<Event>)`. Internally it calls
`establish_connection()` then `run_irc()`. `EstablishedConnection` is an enum with
`Plain(TcpStream)`, `Tls(TlsStream)`, and `Iroh(DuplexStream)`. Adding `WebSocket` is a
fourth arm.

**WHERE:**
- `establish_connection()` — line 674–709. The `TcpStream::connect()` call at line 680 has
  no timeout. On a port-blocked network (e.g., carrier firewall blocking 6667) this hangs
  indefinitely because `tokio::net::TcpStream::connect` inherits the OS TCP connect timeout
  (~75 s on iOS/macOS).
- `run_irc()` — line 1127 onwards. The heartbeat loop (lines 1600–1607) sends `PING
  :keepalive` every 60 s and disconnects after 120 s of silence. This is correct for TCP
  but WebSocket frames (PING/PONG) are handled at the framing layer separately.
- `connect()` — line 960. Used by the FFI path; calls `run_client()` → 
  `establish_connection()`. No WebSocket variant.
- `freeq-sdk/Cargo.toml` — `tokio-tungstenite` and `tungstenite` are NOT present. Neither
  is any `ws` feature flag.

**WHY:**
Port 6667 (IRC plain) is blocked by virtually all corporate and hotel Wi-Fi, and by iOS
low-power mode TCP teardown. Port 443 WebSocket survives all of these. The JS client
already proves the pattern works (`freeq-sdk-js/src/transport.ts`).

**WHEN:**
The gap was introduced at project inception; no WebSocket transport was ever planned for
the Rust SDK (it was only needed for the browser). The iOS FFI was built against the TCP
path.

**HOW — what needs to change:**
1. Add `tokio-tungstenite` (and `tungstenite`) to `freeq-sdk/Cargo.toml` under a
   `websocket` feature flag (keep TCP as default; iOS can switch to WS).
2. Add `EstablishedConnection::WebSocket(...)` using `tokio_tungstenite::WebSocketStream`.
3. Add `establish_ws_connection(url: &str, config: &ConnectConfig) -> Result<EstablishedConnection>`
   that connects via `tokio_tungstenite::connect_async()` with a
   `tokio::time::timeout(Duration::from_secs(10), ...)` wrapper.
4. Wire the WebSocket stream through `run_irc()` the same way the Iroh QUIC `DuplexStream`
   is bridged — a pair of background tasks shuttling frames to/from a `tokio::io::DuplexStream`,
   identical to `web.rs:bridge_ws()` but on the client side.
5. The WS ping loop already exists in `run_irc()` (PING :keepalive); for WebSocket this
   should be upgraded to send proper WebSocket Ping frames OR keep the IRC-level PING —
   both work because the server's `bridge_ws()` passes all text frames straight through.
6. Expose a `ConnectConfig.use_websocket: bool` field (or `transport: Transport` enum)
   and a `server_ws_url: Option<String>` field so the FFI can pass
   `wss://irc.freeq.at/irc`.

---

### FFI Binding Layer — `freeq-sdk-ffi/src/lib.rs`

**Type:** Component (UniFFI bridge)
**Relevance:** The FFI layer owns `FreeqClient::connect()` and constructs `ConnectConfig`.
Any new `ConnectConfig` field must be surfaced here and in the UDL file.

**WHAT:**
`FreeqClient::connect()` (line 197) constructs `ConnectConfig` inline. It infers TLS from
`:6697` or `:443` in the server string. There is no mechanism to pass a WebSocket URL or
opt into WebSocket transport. The server string is set at init from `ServerConfig.ircServer`
(`irc.freeq.at:6667`).

**WHERE:**
- `freeq-sdk-ffi/src/lib.rs:197–244` — `connect()` function
- `freeq-sdk-ffi/src/lib.rs:197–213` — `ConnectConfig` construction; `tls` flag driven by
  port substring match
- `freeq-ios/freeq/Models/ServerConfig.swift:6` — `ircServer = "irc.freeq.at:6667"`
  (plain TCP, not WebSocket URL)
- The `.udl` file (not read but will need updating to expose new fields)

**WHY:**
UniFFI auto-generates Swift bindings from the UDL + Rust types. Every new public field or
method on `FreeqClient` needs a UDL declaration and Rust FFI wrapper.

**WHEN:**
Static since iOS launch. No WebSocket surface has ever been exposed to Swift.

**HOW — what needs to change:**
1. Add a `set_websocket_url(url: String)` method to `FreeqClient` (or add optional
   `ws_url: Option<String>` to the constructor). Simpler to add a setter like
   `set_web_token` already does.
2. In `connect()`, if `ws_url` is set, call `establish_ws_connection(ws_url)` instead of
   `establish_connection(config)`.
3. Update `ServerConfig.swift` to store `wssServer = "wss://irc.freeq.at/irc"` and call
   `client?.setWebsocketUrl(url: ServerConfig.wssServer)` before `client?.connect()`.
4. UDL: add `set_websocket_url(url: string): void` to the interface.

---

### iOS App Auth Lifecycle — `freeq-ios/freeq/Models/AppState.swift`

**Type:** Component (iOS SwiftUI state)
**Relevance:** Contains the three behavioural gaps: unnecessary broker round-trips on
foreground, aggressive 401 clearing, and the cliff that feeds the 15-second UI timer.

**WHAT:**
`AppState` manages:
- `brokerToken` (Keychain, long-lived) — the durable credential
- `cachedWebToken` / `cachedWebTokenExpiry` — 25-minute in-process cache
- `reconnectSavedSession()` — checks cache, then broker, then `connect()`
- `handleScenePhase(.active)` — triggers reconnect if `connectionState == .disconnected`
- `fetchBrokerSession()` — retries up to 4× with backoff; 401 count tracked across calls

**WHERE (gaps):**
1. `handleScenePhase(.active)` at line 820–837: checks `connectionState == .disconnected`
   but does NOT check whether the SDK still has a live connection at the transport level.
   Background → foreground while on the same Wi-Fi: TCP may still be up. The app will hit
   the broker unnecessarily. After WebSocket migration the WS connection is even more
   likely to survive brief background pauses (iOS suspends the app; WS survives TCP keep-
   alive at the OS level better than raw IRC-on-6667).
2. `reconnectSavedSession()` line 444–509: path 3 (broker fetch) is reached whenever
   `cachedWebToken` is absent or expired. The 25-minute cache is correct, but if the IRC
   connection drops and immediately comes back (cellular handoff), the app discards the old
   `FreeqClient` and creates a new one — burning a broker round-trip even though the token
   is still valid and in cache. This is because `disconnect()` sets `connectionState =
   .disconnected` which triggers `reconnectSavedSession()` → full `connect()` cycle.
3. `fetchBrokerSession()` at lines 755–776: 401 clears credentials only if
   `consecutive401Count >= 3 && canAutoClearBrokerCredentials`. But 401 from the broker can
   also mean "broker was just restarted / DB migration" — transient. The 3-count helps, but
   there is no distinction between "PDS revoked the refresh token" (genuine) and "broker
   restarted" (transient). Current code is close to correct but logs no diagnostic. A
   diagnostic log here would help.

**WHY:**
The 15-second cliff (ContentView lines 72–83) is fed by `reconnectSeconds` which starts on
the very first `onAppear`. If the broker is slow (502 cascade during a deploy), the user
sees "Sign in manually" before the reconnect logic even gets a second attempt. This is the
most visible symptom.

**HOW — what needs to change:**
1. `handleScenePhase(.active)`: add a guard — if `client?.isConnected() == true`, skip
   `reconnectSavedSession()`. The FFI already exposes `is_connected()` on `FreeqClient`.
2. `reconnectSavedSession()`: when triggered by `Event.Disconnected`, re-check the cached
   web token before creating a new `FreeqClient`. If cache is still valid and nick is
   known, skip broker fetch.
3. `ContentView.reconnectingView`: the timer (`reconnectSeconds`) should reset on each new
   reconnect cycle, not run continuously from first `.onAppear`. Or increase the threshold
   from 15 s to a higher value (45–60 s) to match real-world broker latency. The "Sign in
   manually" button should remain available for genuine stuck states.

---

### Server WebSocket Endpoint — `freeq-server/src/web.rs`

**Type:** System (server transport)
**Relevance:** Confirms the server side is already done. No server changes needed.

**WHAT:**
`bridge_ws()` (line 44) wraps an axum WebSocket into a `DuplexStream` that the IRC handler
reads/writes as plain bytes. The IRC protocol runs identically over TCP and WebSocket; SASL
(including `web-token`) works unchanged.

**WHERE:**
- `/irc` route at line 173 — `ws_upgrade` handler
- `WsBridge` implements both `AsyncRead` and `AsyncWrite` via `tokio::io::split` of the
  duplex stream
- Origin allowlist (lines 223–) does NOT include iOS app; but `URLSession` sends no
  `Origin` header for WS requests, so the server's CORS check does not apply

**WHY:**
The server intentionally exposes the same SASL handshake over both transports. This is the
correct architecture — adding WebSocket to the Rust SDK does not require any server change.

**WHEN:**
WebSocket has been live since web app launch. Proven stable in production.

**HOW:**
Nothing to do on the server. Document this explicitly in the plan so implementors do not
waste time here.

---

### JS Transport Prior Art — `freeq-sdk-js/src/transport.ts`

**Type:** Component (JS SDK — reference implementation)
**Relevance:** The proven WebSocket transport to mirror in Rust. Contains the exact
parameters to replicate.

**WHAT:**
`Transport` class manages a single `WebSocket`. Key behaviours:

| Parameter | Value | Meaning |
|---|---|---|
| `PING_INTERVAL` | 45 000 ms | Send `PING :heartbeat` if no data for 45 s |
| `DEAD_TIMEOUT` | 90 000 ms | Force reconnect if no data for 90 s |
| Heartbeat poll | every 15 s | Checks elapsed time; decides ping-or-reconnect |
| `bufferedAmount` threshold | 65 536 bytes | Force reconnect on write backpressure |
| Reconnect backoff | `min(1000 * 2^n, 30000)` ms | Exponential, 1 s → 30 s cap |
| `intentionalClose` flag | boolean | Prevents reconnect on deliberate disconnect |

The Rust SDK `run_irc()` already has a 60 s PING / 120 s timeout loop. For the WebSocket
path, converging toward PING_INTERVAL=45 s / DEAD_TIMEOUT=90 s would give parity. The
existing Rust heartbeat loop (lines 1601–1607) can remain as-is for TCP; a separate WS
heartbeat can be layered in the bridge tasks.

**HOW:**
The WS bridge in the Rust SDK should implement the same pattern as `bridge_ws()` in
`web.rs`, with the addition of a client-side idle timer that sends PING frames or IRC PING
lines when no data has been received for 45 s, and closes/reconnects the socket after 90 s
of silence.

---

## Supporting Cards (summaries)

| Card | Type | Key Insight |
| --- | --- | --- |
| `freeq-sdk-ffi/Cargo.toml` | Component | `freeq-sdk` is linked with `ring` + `rustls-tls` + `iroh-transport`; `tokio-tungstenite` needs to be added here too if SDK's `websocket` feature is gated |
| `freeq-ios/freeq/Models/ServerConfig.swift` | Component | `ircServer = "irc.freeq.at:6667"` must gain a `wssServer` or be replaced; API base URL derivation is fine as-is |
| `freeq-ios/freeq/ContentView.swift:47–87` | Component | `reconnectingView` timer runs from first `onAppear` not from each reconnect attempt; the 15 s cliff fires while broker is still retrying |
| `freeq-auth-broker/src/main.rs:session endpoint` | System | `/session` POST does DPoP refresh against PDS; can 502 on broker restart; iOS already retries 4× with backoff — this part is adequate |
| `freeq-ios/AppState.swift:hasSavedSession` | Component | Returns `brokerToken != nil` — correct signal; does NOT check connection liveness — that is the gap |
| `freeq-ios/AppState.swift:Event.Disconnected handler` | Component | Lines 1363–1379 trigger `reconnectSavedSession()` with exponential backoff 1→2→4→8→15 s cap; this is correct and should be preserved |
| `freeq-sdk/src/client.rs:EstablishedConnection enum` | Component | Has Plain / Tls / Iroh arms; WS arm follows the same DuplexStream bridge pattern as Iroh |
| `freeq-sdk/src/client.rs:run_irc()` heartbeat | Component | 60 s PING / 120 s timeout is correct for TCP; WS path needs 45/90 s to match JS |

---

## Relationship Map

- `AppState.connect()` depends-on `FreeqClient.connect()` (FFI) — the iOS connect path
  flows through the UniFFI bridge into Rust SDK
- `FreeqClient.connect()` depends-on `freeq_sdk::client::connect()` which calls
  `establish_connection()` — the TCP-only path that needs a WebSocket alternative
- `establish_connection()` must gain a parallel `establish_ws_connection()` — mirroring how
  `bridge_ws()` in `web.rs` wraps the server side of the same WebSocket session
- `JS Transport` is the prior-art reference for `establish_ws_connection()` ping/backoff
  parameters
- `AppState.handleScenePhase()` depends-on `FreeqClient.is_connected()` (already exposed
  in FFI) — the fix is simply to call this before triggering `reconnectSavedSession()`
- `ContentView.reconnectingView` depends-on `AppState.connectionState` — the 15 s cliff
  is UI state, fixed without touching the SDK

---

## Gap Manifest

| Dimension | Topic | Searched | Found | Recommendation |
| --- | --- | --- | --- | --- |
| HOW | WebSocket transport in Rust SDK | `freeq-sdk/Cargo.toml`, `client.rs` | Not present — `tokio-tungstenite` absent, no WS arm in `EstablishedConnection` | Add `websocket` feature; implement `establish_ws_connection()` + DuplexStream bridge |
| HOW | TCP connect timeout | `client.rs:establish_connection()` | No timeout on `TcpStream::connect()` at line 680 | Wrap with `tokio::time::timeout(Duration::from_secs(10), ...)` |
| HOW | WebSocket connect timeout | n/a (feature doesn't exist yet) | n/a | Same 10 s timeout on `tokio_tungstenite::connect_async()` |
| HOW | iOS foreground guard — skip broker if connected | `AppState.handleScenePhase()` | Missing — checks `connectionState == .disconnected` but not transport liveness | Call `client?.isConnected()` before `reconnectSavedSession()` |
| HOW | ContentView 15 s cliff | `ContentView.swift:72` | Timer runs continuously from first `onAppear` | Reset timer on each new reconnect cycle OR raise threshold to 45–60 s |
| WHY | 401 vs transient discrimination | `AppState.fetchBrokerSession()` | Present but undocumented; 3-count logic is correct but no diagnostic log | Add `tracing::warn!` on genuine 401 clears; confirm logic is sufficient |
| WHERE | FFI UDL file | Not read in this session | Unknown | Locate `freeq-sdk-ffi/src/freeq.udl`, add `set_websocket_url` method declaration |
| WHERE | WS ping/reconnect in Rust SDK | `client.rs run_irc()` | TCP heartbeat exists (60 s / 120 s); no WS-specific path | Add WS bridge task with 45 s idle / 90 s dead detection, matching JS Transport |
| WHEN | Reconnect backoff reset on foreground | `AppState.handleScenePhase()` | Already resets `brokerRetryCount = 0` on `.active` | Verify `reconnectAttempts` is also reset (it is, at `Event.Registered` — line 977) |

---

## Completion Status

**Status:** DONE_WITH_CONCERNS

**Concerns:**
1. The UDL file (`freeq-sdk-ffi/src/freeq.udl`) was not read. The exact method signature
   for `set_websocket_url` in UDL syntax needs to be confirmed before the FFI ticket is
   written.
2. The Cargo workspace `[workspace.dependencies]` was not checked; `tokio-tungstenite`
   version compatibility with the existing `tokio` and `rustls` versions needs verification
   before the Cargo.toml ticket is written.
3. The `iroh-transport` feature is already in `freeq-sdk-ffi/Cargo.toml` — WebSocket
   should follow the same optional-feature pattern to keep the binary size for non-WS
   targets unchanged.
