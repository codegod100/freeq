# freeq Security Audit — 2026-03-29

**Auditor:** Josh Summitt (CTF pre-release audit)
**Scope:** Server (Rust), SDK crypto/E2EE, web client, REST API, S2S federation, auth broker, FFI, policy engine, deployment
**Total Findings:** 55 (7 Critical, 12 High, 18 Medium, 18 Low)

---

## CRITICAL (7)

### C-1: S2S Pre-Authentication Message Processing
**File:** `freeq-server/src/s2s.rs:1100-1122`, `server.rs:1570-1780`
**Description:** The `authenticated_peers` set is populated on Hello/HelloAck but **never checked** before processing S2S messages. Any peer that connects via QUIC can immediately send Privmsg, Join, Mode, Kick, Ban without completing the handshake. The handshake is cosmetic.
**Impact:** Complete federation bypass. An attacker connects and has full S2S control.
**Fix:** Gate all S2S message processing on `authenticated_peers.contains(&peer_id)`.

### C-2: S2S Forged DID/is_op Claims Enable Full Channel Takeover
**File:** `freeq-server/src/server.rs:2039-2098`
**Description:** S2S Join messages carry `did` and `is_op` fields that are trusted without verification. A malicious peer sends `{"type":"join", "nick":"evil", "channel":"#target", "did":"did:plc:<founder_did>", "is_op":true}` and the receiving server grants full operator privileges.
**Impact:** Attacker can kick any user, set bans, change modes, change topics on any channel.
**Fix:** Never trust `is_op` from peers. Verify DID claims against AT Protocol. Derive op status from local channel state.

### C-3: Unauthenticated E2EE Pre-Key Bundle Overwrite (MITM on DMs)
**File:** `freeq-server/src/web.rs:2746-2773`
**Description:** `POST /api/v1/keys` accepts any DID and pre-key bundle with zero authentication. Anyone can overwrite any user's E2EE keys.
**Impact:** Attacker replaces victim's pre-key bundle with their own keys. All future E2EE DMs to the victim are encrypted to the attacker instead. Classic MITM on key exchange.
**Fix:** Require DID authentication (e.g., signed request or WebSocket session binding) before accepting key uploads.

### C-4: ENC2 Group Key Derivable from Public Information
**File:** `freeq-sdk/src/e2ee_did.rs:77-100`
**Description:** `GroupKey::derive()` derives the encryption key from `HKDF(channel_name || sorted_member_DIDs || epoch)`. DIDs are public (broadcast via extended-join/account-notify). Channel names are public. The epoch is public. There is **no shared secret input**.
**Impact:** Anyone who can observe the channel member list can derive the exact decryption key. ENC2 "encryption" provides zero confidentiality.
**Fix:** Require actual key exchange (X3DH or similar) to establish a shared group secret as input to the KDF.

### C-5: Auth Broker Stores DPoP Private Keys + Refresh Tokens in Plaintext SQLite
**File:** `freeq-auth-broker/src/main.rs:1007-1022`
**Description:** The `sessions` table stores `refresh_token` and `dpop_key_b64` (P-256 private key as base64url) in plaintext. DPoP is the proof-of-possession key — having it defeats the entire purpose of DPoP binding.
**Impact:** Database read access = full impersonation of every user. Attacker can independently refresh tokens and use any identity.
**Fix:** Encrypt secrets at rest using a key derived from a hardware-backed store or env-provided master key.

### C-6: Open Redirect via Unvalidated `return_to` in Auth Broker
**File:** `freeq-auth-broker/src/main.rs:516-527, 762`
**Description:** `/auth/login?return_to=https://evil.com` — after legitimate OAuth, the broker redirects to `{return_to}#oauth={base64(web_token, broker_token, did, handle)}`.
**Impact:** Attacker crafts phishing link. Victim completes real OAuth. Tokens delivered to attacker's domain.
**Fix:** Validate `return_to` against an allowlist of trusted origins.

### C-7: S2S Unsigned Messages Accepted Alongside Signed Envelopes
**File:** `freeq-server/src/s2s.rs:1023-1034`
**Description:** The `Signed` envelope verification path has an `other => other` fallback that passes any non-Signed message through without rejection. Signing is opt-in, not enforced.
**Impact:** All S2S signing infrastructure provides no actual security. Messages can be forged without signatures.
**Fix:** Reject all operational messages that are not wrapped in a valid `Signed` envelope.

---

## HIGH (12)

### H-1: Stored XSS via Channel Topic in Invite Page
**File:** `freeq-server/src/web.rs:2393-2441`
**Description:** Channel topic rendered via `format!()` into HTML with no escaping. Any channel op can set `<script>...</script>` as topic.
**Impact:** XSS on server origin → steal broker tokens from localStorage → persistent account takeover.
**Fix:** HTML-escape all user content in templates. Use a proper templating engine.

### H-2: Memory Exhaustion via Unbounded `read_line`
**File:** `freeq-server/src/connection/mod.rs:392-403`
**Description:** `reader.read_line()` reads until `\n` with no size cap. The 8KB check happens **after** the read. A client sends gigabytes without a newline → server OOM.
**Impact:** Single-connection DoS kills the server process.
**Fix:** Wrap reader with `take(8192)` or use bounded read loop.

### H-3: SASL Web Token Reuse (30-min Session Hijacking Window)
**File:** `freeq-server/src/connection/cap.rs:160-173`
**Description:** Web tokens are deliberately reusable within 30-min TTL (`tokens.get()` not `remove()`). A leaked token grants repeated authentication.
**Impact:** Token theft from logs/XSS/network → 30 minutes of unlimited impersonation.
**Fix:** Make tokens single-use. Issue fresh tokens for each connection.

### H-4: SSRF in Link Preview Fetcher (No Private IP Filtering)
**File:** `freeq-sdk/src/media.rs:179-248`
**Description:** `fetch_link_preview()` fetches arbitrary URLs with no blocklist for `127.0.0.0/8`, `169.254.169.254`, `10.0.0.0/8`, etc.
**Impact:** Cloud metadata credential theft, internal service probing.
**Fix:** Resolve DNS first, reject private/link-local IPs before fetching.

### H-5: No Zeroization of Any Secret Key Material in Memory
**File:** `freeq-sdk/src/crypto.rs`, `x3dh.rs`, `ratchet.rs`, `e2ee_did.rs`, `oauth.rs` (multiple locations)
**Description:** No `Zeroize`/`ZeroizeOnDrop` on any private key type. Session keys, ratchet state, identity keys, DPoP keys all persist in memory after drop.
**Impact:** Core dumps, swap files, cold boot attacks recover all keys. Defeats forward secrecy of Double Ratchet.
**Fix:** Add `zeroize` dependency. Implement `ZeroizeOnDrop` on all secret key types.

### H-6: Policy Admin API Has No Authentication
**File:** `freeq-server/src/policy/api.rs:23-41`
**Description:** All policy endpoints (`/api/v1/verify/github`, `/api/v1/credentials/present`, `/api/v1/policy/{channel}/join`) are unauthenticated.
**Impact:** Anyone can inject credentials for any DID and obtain server-signed membership attestations.
**Fix:** Require IRC session auth or bearer token on all policy mutation endpoints.

### H-7: Credential Store Accepts Arbitrary `subject_did` Without Ownership Proof
**File:** `freeq-server/src/policy/api.rs:151-175`
**Description:** The join endpoint accepts `subject_did` from the request body with no proof the caller controls that DID.
**Impact:** Forge membership attestations for arbitrary DIDs → identity impersonation in the policy system.
**Fix:** Require signed proof of DID ownership or session binding.

### H-8: Auth Broker Unbounded Pending Auth Map (OOM DoS)
**File:** `freeq-auth-broker/src/main.rs:28, 532-548`
**Description:** `pending: Mutex<HashMap<String, PendingAuth>>` has no TTL, no max size, no cleanup. Each `/auth/login` creates an entry.
**Impact:** Millions of login requests → unbounded memory growth → broker crash.
**Fix:** Add TTL (5 min), max pending count, background cleanup task.

### H-9: S2S Unrestricted Policy Injection via PolicySync
**File:** `freeq-server/src/server.rs:2930-2958`
**Description:** PolicySync has zero authorization. Not even in the trust enforcement match arms. Any peer (including readonly) can inject arbitrary policy documents.
**Impact:** Attacker injects restrictive policies to block legitimate users or override channel governance.
**Fix:** Require full-trust level for PolicySync. Validate policy document signatures.

### H-10: TAGMSG Bypasses +m and +n Channel Modes
**File:** `freeq-server/src/connection/messaging.rs:60-213`
**Description:** `handle_tagmsg` delivers to channels without checking `no_ext_msg` or `moderated`. The `+react` fallback generates a visible PRIVMSG ACTION.
**Impact:** Non-members message +n channels. Unvoiced users send visible messages to +m channels via reactions.
**Fix:** Apply the same mode checks as `handle_privmsg`.

### H-11: Message Edit/Delete Authorship Check Uses Nick (Not DID)
**File:** `freeq-server/src/connection/messaging.rs:1074-1092, 1350-1377`
**Description:** Authorship verified by comparing current nick against stored sender's nick. After nick reuse, a guest can edit/delete DID-authenticated users' messages.
**Impact:** Message integrity compromise. Attacker registers freed nick and modifies historical messages.
**Fix:** Compare `conn.authenticated_did` against stored message DID. Only fall back to nick for guest messages.

### H-12: postMessage with `'*'` Origin Leaks OAuth Tokens
**File:** `freeq-server/src/web.rs:2119`
**Description:** OAuth callback sends tokens via `window.opener.postMessage({...}, '*')`. Any opener page receives `web_token`, `broker_token`, `access_jwt`.
**Impact:** Attacker page opens auth popup → victim authenticates → tokens sent to attacker's window.
**Fix:** Use specific origin: `window.opener.postMessage({...}, 'https://irc.freeq.at')`.

---

## MEDIUM (18)

### M-1: X25519 Public Key Validation Missing (Small Subgroup Attack)
**File:** `freeq-sdk/src/x3dh.rs:169-170, 183-184, 288, 291`
**Description:** Received X25519 keys deserialized via `PublicKey::from(arr)` without checking for low-order points. DH output can be all-zero/predictable.
**Fix:** Check DH output is not all-zero before proceeding with key derivation.

### M-2: X3DH SPK Signature Not Verified in `initiate()`
**File:** `freeq-sdk/src/x3dh.rs:230-267`
**Description:** `initiate()` uses Bob's pre-key bundle without calling `verify_spk_signature()`. Verification exists but is not enforced by the API.
**Fix:** Call `verify_spk_signature()` inside `initiate()` and return error on failure.

### M-3: Double Ratchet Session Serialized as Plaintext JSON
**File:** `freeq-sdk/src/ratchet.rs:370-372`
**Description:** `Session::to_bytes()` serializes all ratchet keys as plaintext JSON to disk.
**Fix:** Encrypt serialized session state before writing.

### M-4: StubSigner Echoes Challenge as "Signature"
**File:** `freeq-sdk/src/auth.rs:254-268`
**Description:** `StubSigner` returns raw challenge bytes as the signature. If server code path accepts this, it's a trivial auth bypass.
**Fix:** Remove `StubSigner` from release builds or ensure server rejects empty/echo signatures.

### M-5: OAuth Session + DPoP Key Cached in Plaintext on Disk
**File:** `freeq-sdk/src/oauth.rs:50-75`
**Description:** `OAuthSession::save()` writes access token and DPoP private key as plaintext JSON (0o600 perms).
**Fix:** Encrypt at rest using OS keychain or derived key.

### M-6: PDS-Session/OAuth Methods Ignore the Challenge Nonce
**File:** `freeq-server/src/sasl.rs:189-190, 250-251`
**Description:** Both accept `_challenge` (unused). The challenge-response mechanism is bypassed — verification only proves PDS session access, not response to this specific challenge.
**Fix:** Require the client to sign the challenge bytes with the PDS session key.

### M-7: SASL Failure Limit Not Enforced (Infinite Retries)
**File:** `freeq-server/src/connection/cap.rs:357-362`
**Description:** After 3 failures, server sends ERROR but doesn't close the connection. Client can keep trying. Counter is `u8` (wraps at 255 in release builds).
**Fix:** Disconnect the client after 3 SASL failures.

### M-8: SSRF via `did:web` Resolution (No IP Filtering)
**File:** `freeq-sdk/src/did.rs:196-224`, `freeq-auth-broker/src/main.rs:175-180`
**Description:** `did:web:127.0.0.1` → fetches `https://127.0.0.1/.well-known/did.json`. No private IP blocking in either the SDK or the broker.
**Fix:** Validate resolved IPs against private ranges before fetching.

### M-9: SSRF via DNS Rebinding in OG Preview Proxy
**File:** `freeq-server/src/web.rs:2574-2628`
**Description:** `/api/v1/og` validates DNS then fetches separately → TOCTOU race allows DNS rebinding to `127.0.0.1`.
**Fix:** Pin DNS resolution so the fetch uses the same IP that was validated.

### M-10: Permissive CORS on Auth Broker
**File:** `freeq-auth-broker/src/main.rs:285`
**Description:** `CorsLayer::permissive()` allows any origin to call all broker endpoints including `/session`.
**Fix:** Restrict CORS to trusted origins.

### M-11: Empty Shared Secret Accepted (Broker Runs Unauthenticated)
**File:** `freeq-auth-broker/src/main.rs:250-261`
**Description:** `BROKER_SHARED_SECRET` defaults to `""`. HMAC-SHA256 with empty key is computable by anyone.
**Fix:** Refuse to start if shared secret is not set or is too short.

### M-12: Sensitive Tokens Logged in Redirect URLs
**File:** `freeq-auth-broker/src/main.rs:763`
**Description:** `tracing::info!` logs the full redirect URL containing `web_token` and `broker_token`.
**Fix:** Redact tokens in log output.

### M-13: No CSRF Protection on Broker `/session` Endpoint
**File:** `freeq-auth-broker/src/main.rs:767-825`
**Description:** `/session` POST accepts `broker_token` in JSON with no CSRF token, combined with permissive CORS.
**Fix:** Add CSRF token or restrict CORS origin.

### M-14: IRC Tag Injection via Unsanitized Reason Fields
**File:** `freeq-server/src/connection/mod.rs:1407-1411, 1565, 862`
**Description:** AGENT PAUSE/RESUME/REVOKE reason interpolated into IRC tag string without escaping. `;` or `\r\n` injects additional tags or new IRC messages.
**Fix:** Use existing `escape_tag_value()` function on all user-controlled tag values.

### M-15: Unbounded Channel Creation (No Per-User Limit)
**File:** `freeq-server/src/connection/channel.rs:173`
**Description:** No limit on channels per user or globally. JOIN is rate-limit exempt. A client can create millions of channels.
**Fix:** Add per-user channel limit (e.g., 50) and global channel cap.

### M-16: OPER Password Timing Side-Channel
**File:** `freeq-server/src/connection/mod.rs:1258-1259`
**Description:** `password == oper_pw` uses short-circuit string comparison.
**Fix:** Use constant-time comparison.

### M-17: S2S Nick Collision via NickChange
**File:** `freeq-server/src/server.rs:2907-2928`
**Description:** NickChange doesn't check if new nick conflicts with local users. Creates ambiguous identity for authorization checks.
**Fix:** Reject S2S nick changes that collide with local nicks.

### M-18: HMAC Signing Key Partially Leaked via Public API
**File:** `freeq-server/src/policy/engine.rs:88`
**Description:** First 16 bytes of 32-byte HMAC signing key exposed via `GET /api/v1/authority/{hash}`.
**Fix:** Use asymmetric signing (ed25519) for attestations, or don't expose any key material.

---

## LOW (18)

### L-1: HKDF Used Directly on Passphrase (No Password Strengthening)
**File:** `freeq-sdk/src/e2ee.rs:43-51`
**Desc:** ENC1 key derived via HKDF on raw passphrase. No Argon2/scrypt. Brute-forceable in microseconds.

### L-2: MAX_SKIP=1000 Allows Memory Pressure
**File:** `freeq-sdk/src/ratchet.rs:39`
**Desc:** Attacker forces 1000 skipped key storage per ratchet step. Signal uses 256.

### L-3: DPoP jti Randomness (Acceptable)
**File:** `freeq-sdk/src/oauth.rs:216`
**Desc:** 128 bits of entropy for jti. Sufficient per RFC 9449.

### L-4: Broker Token Not Bound to Client Identity
**File:** `freeq-auth-broker/src/main.rs:698-719`
**Desc:** Bearer token with no IP/device binding. Theft = unlimited session minting from anywhere.

### L-5: Mutex Poisoning Risk in FFI Layer
**File:** `freeq-sdk-ffi/src/lib.rs` (throughout)
**Desc:** All `.lock().unwrap()` — panicked thread poisons mutex, cascading failure across FFI boundary.

### L-6: PINS Command Leaks Pin Metadata to Non-Members
**File:** `freeq-server/src/connection/mod.rs:887-921`
**Desc:** `PINS #secret-channel` returns all pin metadata without membership check.

### L-7: NAMES Returns Member List for Any Channel
**File:** `freeq-server/src/connection/channel.rs:1558-1640`
**Desc:** No membership check for +s channels. Enables social graph enumeration.

### L-8: DM History LIKE Pattern May Over-Match DIDs
**File:** `freeq-server/src/db.rs:728-748`
**Desc:** `%{did}%` pattern could match DID substrings. Practically unlikely but logic flaw.

### L-9: No Flood Protection on TAGMSG
**File:** `freeq-server/src/connection/messaging.rs:60-213`
**Desc:** Per-channel burst protection missing for TAGMSG. Reaction spam possible.

### L-10: TAGMSG-Based Deletion Bypasses Channel Membership Check
**File:** `freeq-server/src/connection/messaging.rs:60-74`
**Desc:** Delete via TAGMSG routes before membership verification. Non-members can delete own old messages.

### L-11: S2S Channel Key Disclosure in SyncResponse
**File:** `freeq-server/src/server.rs:2341`
**Desc:** +k channel passwords sent in plaintext to all federated peers.

### L-12: S2S SyncResponse Leaks All State to Any Peer
**File:** `freeq-server/src/server.rs:2304-2355`
**Desc:** Full channel state (members, bans, invites, keys, DIDs) sent to any requesting peer.

### L-13: S2S Dedup Bypass via Empty event_id
**File:** `freeq-server/src/s2s.rs:448-451`
**Desc:** Empty `event_id` (default) skips all dedup. Unlimited message replay.

### L-14: S2S Origin Field Not Validated Against Transport Identity
**File:** `freeq-server/src/server.rs:1680-1741`
**Desc:** `origin` field trusted from payload, not bound to transport peer identity.

### L-15: S2S CRDT Founder Takeover via Actor ID Brute-Force
**File:** `freeq-server/src/crdt.rs:356-384`
**Desc:** Min-actor-wins for founder. Attacker generates keys until small ID → takes founder.

### L-16: Broker Replay Protection is Optional
**File:** `freeq-server/src/web.rs:1412-1428`
**Desc:** Timestamp check only applies if `X-Broker-Timestamp` header present. Otherwise unlimited replay.

### L-17: Docker Image Uses Unpinned Base Tags
**File:** `Dockerfile:2,18,27`
**Desc:** `rust:1.85-slim-bookworm` etc. not pinned by digest.

### L-18: Broker Token in localStorage Accessible to XSS
**File:** `freeq-app/src/components/ConnectScreen.tsx:195-196`
**Desc:** `localStorage.setItem('freeq-broker-token', ...)` — no HttpOnly equivalent for JS storage.

---

## Attack Chains (Compound Exploits)

### Chain 1: Anonymous Full Server Takeover via S2S
**C-1 + C-2 + C-7:** Connect QUIC → skip handshake → send unsigned Join with forged founder DID + is_op:true → kick all users, set bans, take over every channel.

### Chain 2: E2EE is Illusory
**C-3 + C-4:** Pre-key overwrite gives MITM on DMs. Group encryption uses no secret. The entire E2EE layer provides no real confidentiality.

### Chain 3: Stored XSS → Account Takeover
**H-1 + L-18:** Set XSS in channel topic → visitor hits `/join/channel` → script reads `localStorage['freeq-broker-token']` → attacker has persistent session.

### Chain 4: OAuth Token Theft via Popup
**H-12 + C-6:** Attacker page opens auth popup → victim completes OAuth → `postMessage('*')` sends tokens to attacker. OR: attacker crafts `return_to=evil.com` → tokens in URL fragment.

### Chain 5: Policy Identity Impersonation
**H-6 + H-7:** Inject GitHub credential for any DID via unauthenticated API → obtain server-signed membership attestation → bypass channel access policies.

### Chain 6: Unlimited SASL Brute Force
**M-7 + H-3:** SASL failure limit not enforced → infinite retries → reusable web tokens make the window 30 minutes wide.

---

## Recommended Priority

1. **Immediately** (ship-blocking): C-1 through C-7, H-1, H-2, H-3, H-12
2. **Before GA**: All HIGH findings, M-6, M-7, M-14, M-15
3. **Before scale**: All MEDIUM findings
4. **Harden**: LOW findings as time permits

---

*Generated 2026-03-29 via manual source code review.*
