# Feedback Queue — ios-durable-auth

**Source:** Bridget context-briefing assembly, 2026-04-25

## Gaps Logged

### FQ-001 — UDL file not located

**Type:** Retrieval miss
**Severity:** Medium
**Description:** `freeq-sdk-ffi/src/freeq.udl` was not found or read during assembly.
The FFI ticket for `set_websocket_url` cannot be fully specified without knowing the exact
UDL syntax in use. The method signature in the briefing is an approximation.
**Recommendation:** Read the UDL file before writing the FFI ticket. Confirm UniFFI version
(0.29 per Cargo.toml) and the correct method declaration syntax.

### FQ-002 — Workspace dependency versions unverified

**Type:** Gap
**Severity:** Low
**Description:** The `[workspace.dependencies]` section of the root `Cargo.toml` was not
read. `tokio-tungstenite` must be added at a version compatible with the existing `tokio`
(workspace) and `rustls` (0.23) versions. The recommended compatible version is
`tokio-tungstenite = "0.24"` (uses tokio 1.x, supports rustls 0.23 via feature flag), but
this must be verified.
**Recommendation:** Read `/Users/chad/src/freeq/Cargo.toml` workspace deps section before
writing the Cargo ticket.

### FQ-003 — No test coverage for SDK transport layer

**Type:** Quality concern (from CLAUDE.md hotspot analysis)
**Severity:** High
**Description:** `sdk/client.rs` has ZERO unit tests per the hotspot analysis in CLAUDE.md.
The WebSocket transport addition is a significant code path. Adding it without tests
compounds an existing risk.
**Recommendation:** The implementation tickets should include a task for integration tests
covering: WS connect success, WS connect timeout, WS idle reconnect (mock server that
stops sending), and WS intentional close (no reconnect).

### FQ-004 — `ring` vs `aws-lc-rs` feature choice for iOS WebSocket TLS

**Type:** Gap
**Severity:** Medium
**Description:** `freeq-sdk-ffi` already uses `ring` (not `aws-lc-rs`) for iOS because
ring works on Apple Silicon. `tokio-tungstenite` with TLS support needs a compatible
rustls backend. The briefing assumes the existing `ring` feature path applies. This needs
verification — `tokio-tungstenite`'s rustls feature flag may require `rustls-tls-webpki-roots`
or `rustls-tls-native-roots`, which must be aligned with the existing rustls 0.23 setup.
**Recommendation:** Test a `cargo check` with the proposed deps on the iOS target
(`aarch64-apple-ios`) before writing the ticket as "done".
