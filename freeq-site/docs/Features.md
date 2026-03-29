# Freeq Feature List

This document catalogs every feature implemented in Freeq, organized by category. Features unique to Freeq (not present in classic IRC) are marked with **🆕**. Features that extend or modify standard IRC behavior are marked with **🔧**. Standard IRC features are unmarked.

---

## 1. IRC Protocol — Core

### Connection & Registration

| Feature | Status | Notes |
|---------|--------|-------|
| NICK / USER registration | ✅ | Standard IRC registration flow |
| NICK change after registration | ✅ | Broadcasts `:old NICK :new` to user + shared channels + S2S |
| PING / PONG keepalive | ✅ | Both client→server and server→client |
| QUIT with reason broadcast | ✅ | Broadcasts to all shared channels |
| Connection timeout detection | ✅ | 90s ping interval, 180s timeout |
| Rate limiting (token bucket) | ✅ | 10 cmd/sec; exempt during registration |
| ERR_UNKNOWNCOMMAND (421) | ✅ | For unrecognized commands |

### Channels

| Feature | Status | Notes |
|---------|--------|-------|
| JOIN (single and multi-channel) | ✅ | `JOIN #a,#b` with per-channel keys |
| PART (single and multi-channel) | ✅ | |
| PRIVMSG to channels | ✅ | |
| PRIVMSG to users (PM) | ✅ | |
| NOTICE to channels and users | ✅ | |
| CTCP ACTION (`/me`) | ✅ | Via `\x01ACTION ...\x01` |
| TOPIC query and set | ✅ | RPL_TOPIC (332), RPL_TOPICWHOTIME (333), RPL_NOTOPIC (331) |
| NAMES (353/366) | ✅ | With `@` and `+` prefixes for ops/voiced |
| LIST (322/323) | ✅ | Channel list with member counts and topics |
| WHO (352/315) | ✅ | Per-channel and global, shows DID/handle for authenticated users |
| AWAY (301/305/306) | ✅ | Sets/clears away, RPL_AWAY on PM |
| MOTD (375/372/376) | ✅ | On registration + standalone command |
| KICK | ✅ | With reason, proper numeric errors |
| INVITE | ✅ | RPL_INVITING (341), notifies target |

### Channel Modes

| Mode | Status | Notes |
|------|--------|-------|
| `+o` / `-o` (channel operator) | ✅ | |
| `+v` / `-v` (voice) | ✅ | |
| `+b` / `-b` (ban) | ✅ | Hostmask + DID wildcard matching |
| `+i` / `-i` (invite-only) | ✅ | |
| `+t` / `-t` (topic lock) | ✅ | Only ops can set topic when enabled |
| `+k` / `-k` (channel key) | ✅ | Password required to join |
| `+n` / `-n` (no external messages) | ✅ | Non-members can't send to channel |
| `+m` / `-m` (moderated) | ✅ | Only ops/voiced can speak |
| MODE query (324) | ✅ | Lists current channel modes |
| Ban list query (`+b` no arg) | ✅ | RPL_BANLIST (367), RPL_ENDOFBANLIST (368) |

### User Modes

| Feature | Status | Notes |
|---------|--------|-------|
| User mode query (221) | ✅ | Returns `+` (no user modes implemented) |

### WHOIS

| Feature | Status | Notes |
|---------|--------|-------|
| RPL_WHOISUSER (311) | ✅ | |
| RPL_WHOISSERVER (312) | ✅ | |
| RPL_ENDOFWHOIS (318) | ✅ | |
| RPL_WHOISACCOUNT (330) | 🆕 | Shows authenticated DID |
| Custom 671: AT Protocol handle | 🆕 | Shows resolved Bluesky handle |
| Custom 672: iroh endpoint | 🆕 | Shows P2P iroh endpoint ID |
| RPL_WHOISCHANNELS (319) | ✅ | For remote S2S users |

### Informational Commands

| Feature | Status | Notes |
|---------|--------|-------|
| VERSION (351) | ✅ | Server version and feature summary |
| TIME (391) | ✅ | Server UTC time |
| LUSERS (251-255) | ✅ | User/channel/server counts, local + remote |
| ADMIN (256-259) | ✅ | Server admin info |
| INFO (371/374) | ✅ | Server description and links |
| USERHOST (302) | ✅ | Up to 5 nicks, with op status |
| ISON (303) | ✅ | Online presence check |

### Missing Standard IRC Commands

| Feature | Status | Notes |
|---------|--------|-------|
| OPER (server operator) | ✅ | `OPER <name> <password>` + auto-OPER via `--oper-dids` |
| WALLOPS | ❌ | Not implemented |
| LINKS | ❌ | Not implemented |
| STATS | ❌ | Not implemented |
| Channel modes: `+s` / `+p` (secret/private) | ❌ | Not implemented |
| Channel modes: `+l` (user limit) | ❌ | Not implemented |
| Hostname cloaking | ✅ | 🆕 `freeq/plc/xxxxxxxx` for DID users, `freeq/guest` for guests |
| Reverse DNS lookup | ❌ | |
| K-line / G-line (server bans) | ❌ | |

---

## 2. IRCv3 Capabilities

| Feature | Status | Notes |
|---------|--------|-------|
| CAP LS / REQ / ACK / NAK / END | ✅ | IRCv3 capability negotiation |
| `sasl` capability | ✅ | With ATPROTO-CHALLENGE mechanism |
| `message-tags` capability | ✅ | Tag-aware routing per client |
| `server-time` capability | ✅ | Timestamps on history replay |
| `batch` capability | ✅ | History wrapped in `chathistory` batch |
| `multi-prefix` capability | ✅ | Shows all prefix chars in NAMES |
| `echo-message` capability | ✅ | Echoes own messages to negotiated clients |
| TAGMSG (tags-only messages) | ✅ | With fallback for plain clients |
| `iroh=<id>` CAP advertisement | 🆕 | Transport discovery via CAP LS |
| SASL AUTHENTICATE `*` abort | ✅ | Cleanly aborts SASL negotiation |

| `account-notify` capability | ✅ | Broadcasts ACCOUNT on auth to shared channels |
| `extended-join` capability | ✅ | JOIN includes account + realname |
| `draft/chathistory` capability | ✅ | On-demand `CHATHISTORY LATEST/BEFORE/AFTER` |

### Missing IRCv3 Extensions

| Feature | Status | Notes |
|---------|--------|-------|
| `away-notify` | ✅ | Broadcasts AWAY changes to shared channel members |
| `msgid` (message IDs) | ✅ | 🆕 ULID on every PRIVMSG/NOTICE, stored in DB, included in history replay |
| `account-tag` | ❌ | |
| `labeled-response` | ❌ | |
| `invite-notify` | ❌ | |
| `chghost` | ❌ | |
| `cap-notify` | ❌ | |
| `setname` | ❌ | |
| `standard-replies` | ❌ | |

---

## 3. Authentication — SASL ATPROTO-CHALLENGE 🆕

| Feature | Status | Notes |
|---------|--------|-------|
| Challenge-response SASL flow | ✅ | Custom `ATPROTO-CHALLENGE` mechanism |
| Cryptographically random nonce (32 bytes) | ✅ | Per challenge |
| Challenge single-use enforcement | ✅ | Consumed on take, replay blocked |
| Configurable challenge timeout | ✅ | Default 60s, `--challenge-timeout-secs` |
| JSON-encoded challenges | ✅ | Deviation from binary: for debuggability |
| RPL_LOGGEDIN (900) | ✅ | |
| RPL_SASLSUCCESS (903) | ✅ | |
| ERR_SASLFAIL (904) | ✅ | |
| Guest fallback (no SASL) | ✅ | Standard IRC clients work unmodified |

### Verification Methods

| Method | Status | Notes |
|--------|--------|-------|
| `crypto` (DID document key signature) | ✅ | Signs raw challenge bytes |
| `pds-session` (app password Bearer JWT) | ✅ | Verifies via PDS `getSession` |
| `pds-oauth` (DPoP-bound access token) | ✅ | DPoP proof forwarded to PDS |

### Key Types

| Key Type | Status | Notes |
|----------|--------|-------|
| secp256k1 | ✅ | MUST per spec — compressed SEC1 encoding |
| ed25519 | ✅ | SHOULD per spec |
| Multibase/multicodec parsing | ✅ | `z` prefix (base58btc), proper varint codecs |

### DID Resolution

| Feature | Status | Notes |
|---------|--------|-------|
| `did:plc` resolution (plc.directory) | ✅ | |
| `did:web` resolution | ✅ | Including path-based DIDs |
| Handle resolution (`.well-known/atproto-did`) | ✅ | |
| PDS endpoint extraction from DID doc | ✅ | `AtprotoPersonalDataServer` service type |
| PDS URL verification (claimed vs doc) | ✅ | Prevents spoofing |
| Authentication key extraction | ✅ | From `authentication` + `assertionMethod` |
| Static resolver (testing) | ✅ | In-memory DID document map |

---

## 4. DID-Aware IRC Features 🆕

| Feature | Status | Notes |
|---------|--------|-------|
| DID-based bans (`MODE +b did:plc:xyz`) | ✅ | Identity-based, survives nick changes |
| DID-based invites | ✅ | Stored by DID, survive reconnect |
| Nick ownership (DID binding) | ✅ | Persisted across restarts |
| Nick enforcement at registration | ✅ | Non-owners renamed to `GuestXXXX` |
| Persistent DID-based channel ops | ✅ | Auto-op on rejoin by DID, persisted in DB |
| Channel founder (first authenticated user) | ✅ | Can't be de-opped, persisted in DB |
| DID in WHOIS output | ✅ | Numeric 330 |
| AT handle in WHOIS output | ✅ | Resolved asynchronously from DID doc |
| Auto-op on empty channel rejoin | ✅ | First user joining empty+zero-ops channel gets ops |

---

## 5. Transport Stack

### TCP / TLS (Standard)

| Feature | Status | Notes |
|---------|--------|-------|
| Plain TCP (port 6667) | ✅ | |
| TLS (port 6697) | ✅ | rustls with configurable cert/key |
| Auto-detect TLS by port (client) | ✅ | Port 6697 → TLS |
| Self-signed cert support (client) | ✅ | `--tls-insecure` flag |

### WebSocket 🆕

| Feature | Status | Notes |
|---------|--------|-------|
| WebSocket IRC transport (`/irc`) | ✅ | IRC-over-WS, not a new protocol |
| Text frame ↔ IRC line bridging | ✅ | One line per frame, `\r\n` handling |
| `--web-addr` opt-in | ✅ | Zero-cost when disabled |
| HTML test client | ✅ | `test-client.html` |

### Iroh QUIC Transport 🆕

| Feature | Status | Notes |
|---------|--------|-------|
| Iroh endpoint for IRC connections | ✅ | ALPN: `freeq/iroh/1` |
| Persistent secret key (`iroh-key.secret`) | ✅ | Stable endpoint ID across restarts |
| Iroh endpoint stored in SharedState | ✅ | Proper lifetime (no `mem::forget`) |
| NAT hole-punching + relay fallback | ✅ | Via iroh's infrastructure |
| Transport-agnostic handler | ✅ | All transports → `handle_generic()` |
| Iroh ID in CAP LS for auto-discovery | ✅ | `iroh=<endpoint-id>` |
| Client auto-upgrade to iroh | ✅ | Probes CAP LS, reconnects via iroh |
| Configurable iroh UDP port | ✅ | `--iroh-port` |
| Connection held alive for session | ✅ | Explicit close with CONNECTION_CLOSE frame |
| Bridge task abort on disconnect | ✅ | Clean cleanup |

---

## 6. End-to-End Encryption (E2EE) 🆕

| Feature | Status | Notes |
|---------|--------|-------|
| AES-256-GCM channel encryption | ✅ | Per-channel passphrase |
| HKDF-SHA256 key derivation | ✅ | Channel-name-salted |
| Wire format: `ENC1:<nonce>:<ciphertext>` | ✅ | Version-tagged, base64 encoded |
| Server-transparent relay | ✅ | Server sees ciphertext only |
| `/encrypt` and `/decrypt` commands | ✅ | TUI commands |
| Unicode passphrase support | ✅ | |
| Tamper detection (GCM auth tag) | ✅ | |

### DID-Based E2EE (ENC2) 🆕

| Feature | Status | Notes |
|---------|--------|-------|
| Identity-bound group encryption | ✅ | Key derived from sorted member DIDs |
| Wire format: `ENC2:<epoch>:<nonce>:<ct>` | ✅ | Epoch tracks membership changes |
| Group key rotation on member change | ✅ | New epoch = new key |
| ECDH DM encryption (secp256k1) | ✅ | Pairwise key from DID document keys |
| Wire format: `ENC2:dm:<nonce>:<ct>` | ✅ | DM variant |
| DID-sorted deterministic derivation | ✅ | Same members = same key regardless of order |

---

## 7. Peer-to-Peer Encrypted DMs 🆕

| Feature | Status | Notes |
|---------|--------|-------|
| Client-side iroh endpoint for DMs | ✅ | ALPN: `freeq/p2p-dm/1` |
| Direct encrypted QUIC connections | ✅ | Server-free |
| `/p2p start/id/connect/msg` commands | ✅ | TUI commands |
| Newline-delimited JSON wire format | ✅ | Not IRC protocol |
| Dedicated `p2p:<id>` TUI buffers | ✅ | |
| Iroh endpoint ID in WHOIS (672) | ✅ | For peer discovery |

---

## 8. Server-to-Server Federation (S2S) 🆕

| Feature | Status | Notes |
|---------|--------|-------|
| Iroh QUIC-based S2S links | ✅ | ALPN: `freeq/s2s/1` |
| `--s2s-peers` CLI option | ✅ | Connect to peers on startup |
| Incoming S2S acceptance (when iroh enabled) | ✅ | |
| ALPN-based routing (client vs S2S) | ✅ | |
| Origin tracking (loop prevention) | ✅ | `origin` field in S2S messages |
| Newline-delimited JSON S2S protocol | ✅ | |
| Auto-reconnection with exponential backoff | ✅ | 1s→60s cap, `connect_peer_with_retry()` |
| Diagnostic logging (byte/message counts) | ✅ | Which side ended link, close reasons |

### What Syncs

| Feature | Status | Notes |
|---------|--------|-------|
| PRIVMSG relay | ✅ | Channel messages, enforces +n/+m |
| JOIN / PART / QUIT propagation | ✅ | Membership tracking per origin server |
| NICK change propagation | ✅ | Updates remote_members map in all channels |
| TOPIC sync | ✅ | Enforces +t on incoming S2S topics |
| MODE sync (real-time) | ✅ | +t/+i/+n/+m/+k broadcast via S2S Mode message |
| MODE sync (SyncResponse) | ✅ | Full state replacement (not additive) |
| Remote member tracking | ✅ | `remote_members` with DID, handle, is_op |
| SyncRequest / SyncResponse | ✅ | Initial state exchange with rich nick_info |
| NAMES includes remote members | ✅ | With op status from home server + DID-based |
| WHOIS for remote users | ✅ | Shows DID, handle, origin |
| DID-based ops sync | ✅ | Union merge |
| Founder sync (first-write-wins) | ✅ | No timestamp dependency |
| ChannelCreated propagation | ✅ | Founder + DID ops + created_at |
| Ban sync (S2S) | ✅ | 🆕 S2sMessage::Ban variant, authorized set/remove, SyncResponse carries bans |
| Invite sync (S2S) | ✅ | 🆕 S2sMessage::Invite variant, relays invite tokens to peers |
| S2S Join enforcement | ✅ | 🆕 Incoming S2S Joins check bans (nick + DID) and +i (invite only) |
| Policy sync (S2S) | ✅ | 🆕 S2sMessage::PolicySync for channel policy documents |

### CRDT State Layer (Automerge)

| Feature | Status | Notes |
|---------|--------|-------|
| Flat-key Automerge document | ✅ | Avoids nested-map conflicts |
| Channel membership CRDT | ✅ | `member:{channel}:{nick}` |
| Topic CRDT (LWW) | ✅ | |
| Ban CRDT (add/remove) | ✅ | |
| Nick ownership CRDT | ✅ | |
| Founder CRDT (first-write-wins) | ✅ | Conditional put, deterministic convergence |
| DID ops CRDT (grant/revoke) | ✅ | |
| Sync message generation/receipt | ✅ | Automerge sync protocol |
| Save/load from bytes | ✅ | |
| **🆕** Live CRDT sync via S2S | ✅ | `CrdtSync` message type; mutations written to CRDT alongside in-memory state; Automerge sync messages exchanged on link establishment and after each remote sync |

### S2S Limitations (see also docs/s2s-audit.md)

| Limitation | Notes |
|------------|-------|
| ChannelCreated race in narrow window | Both servers may create simultaneously |
| Rogue server can add `did_ops` | Authorization-on-write not implemented |

---

## 9. Persistence (SQLite)

| Feature | Status | Notes |
|---------|--------|-------|
| `--db-path` opt-in | ✅ | In-memory by default |
| WAL mode | ✅ | Good concurrent read performance |
| Message history storage | ✅ | All channel messages |
| Channel state persistence | ✅ | Topics, modes (+t/+i/+k/+n/+m), keys |
| Ban persistence | ✅ | Hostmask and DID bans |
| DID-nick identity bindings | ✅ | Survive restarts |
| DID-based ops persistence | ✅ | `did_ops_json` column |
| Founder persistence | ✅ | `founder_did` column |
| History replay on JOIN | ✅ | Last 100 messages with `server-time` + `batch` |
| Message pruning | ✅ | `--max-messages-per-channel` config |
| Idempotent DB migration | ✅ | `ALTER TABLE ADD COLUMN` on startup |
| Graceful persistence failures | ✅ | Logged, don't crash server |
| Load persisted state on startup | ✅ | Channels, bans, messages, identities |

### Persistence Gaps

| Gap | Notes |
|-----|-------|
| No `--message-retention-days` | Only count-based pruning |
| No full-text search | SQLite FTS5 not wired up |

---

## 10. REST API 🆕

| Endpoint | Status | Notes |
|----------|--------|-------|
| `GET /api/v1/health` | ✅ | Server stats |
| `GET /api/v1/channels` | ✅ | List all channels |
| `GET /api/v1/channels/{name}/history` | ✅ | Paginated, `?limit=N&before=T` |
| `GET /api/v1/channels/{name}/topic` | ✅ | |
| `GET /api/v1/channels/{name}/pins` | ✅ | 🆕 Pinned messages for a channel |
| `GET /api/v1/channels/{name}/events` | ✅ | 🆕 SSE event stream |
| `GET /api/v1/channels/{name}/audit` | ✅ | 🆕 Channel audit log |
| `GET /api/v1/channels/{name}/agent-capabilities` | ✅ | 🆕 Agent capabilities |
| `GET /api/v1/channels/{name}/approvals` | ✅ | 🆕 Pending approvals |
| `GET /api/v1/channels/{name}/budget` | ✅ | 🆕 Channel budget info |
| `GET /api/v1/channels/{name}/spend` | ✅ | 🆕 Channel spend info |
| `GET /api/v1/users/{nick}` | ✅ | Online status, DID, handle |
| `GET /api/v1/users/{nick}/whois` | ✅ | + channels |
| `GET /api/v1/signing-key` | ✅ | 🆕 Server ed25519 public key |
| `GET /api/v1/signing-keys/{did}` | ✅ | 🆕 Per-DID client signing key |
| `GET /api/v1/verify/{msgid}` | ✅ | 🆕 Verify message signature |
| `GET /api/v1/actors/{did}` | ✅ | 🆕 Actor identity info |
| `GET /api/v1/keys/{did}` | ✅ | 🆕 E2EE public keys for a DID |
| `POST /api/v1/keys` | ✅ | 🆕 Upload E2EE public keys |
| `POST /api/v1/upload` | ✅ | 🆕 Upload media to PDS (auth required) |
| `GET /api/v1/blob` | ✅ | 🆕 PDS blob proxy with Range support |
| `GET /api/v1/og` | ✅ | 🆕 OpenGraph link preview |
| `GET /api/v1/tasks/{task_id}` | ✅ | 🆕 Agent task status |
| `GET /api/v1/agents/manifests` | ✅ | 🆕 List agent manifests |
| `GET /api/v1/agents/manifests/{did}` | ✅ | 🆕 Get agent manifest |
| `GET /api/v1/agents/spawned` | ✅ | 🆕 List spawned agents |
| CORS support | ✅ | Configurable allowed origins |
| Security headers | ✅ | CSP, HSTS, X-Frame-Options, etc. |

---

## 11. Rich Media (IRCv3 Tags) 🆕

| Feature | Status | Notes |
|---------|--------|-------|
| Media attachment tags | ✅ | `content-type`, `media-url`, `media-alt`, etc. |
| Multipart/alternative semantics | ✅ | Tags for rich clients, body for plain clients |
| Link preview tags | ✅ | `text/x-link-preview` content type |
| Reaction tags (`+react`) | ✅ | With TAGMSG, fallback ACTION for plain clients |
| Media upload to AT Protocol PDS | ✅ | Blob upload + record pinning |
| `blue.irc.media` custom lexicon | ✅ | Prevents blob GC, doesn't pollute feed |
| Optional cross-post to Bluesky feed | ✅ | |
| OpenGraph link preview fetching | ✅ | HTML parsing, 64KB limit |
| CDN URL generation (bsky.app) | ✅ | |
| DPoP nonce retry for PDS uploads | ✅ | Up to 3 attempts |
| Tag escaping/unescaping (IRCv3 spec) | ✅ | `\:`, `\s`, `\\`, `\r`, `\n` |

---

## 11.5. Message Signing 🆕

| Feature | Status | Notes |
|---------|--------|-------|
| Client-side ed25519 session keys | ✅ | Per-session keypair, registered via `MSGSIG` command |
| Client message signing (`+freeq.at/sig`) | ✅ | Non-repudiation — client signs every PRIVMSG |
| Server signature verification | ✅ | Verifies client sigs, relays unchanged |
| Server fallback signing | ✅ | Server signs if client doesn't support signing |
| Public key endpoint (server) | ✅ | `GET /api/v1/signing-key` |
| Public key endpoint (per-DID) | ✅ | `GET /api/v1/signing-keys/{did}` |
| Signature verification endpoint | ✅ | `GET /api/v1/verify/{msgid}` |
| S2S signature preservation | ✅ | `msgid` + `sig` carried across federation |

---

## 11.6. Message Editing & Deletion 🆕

| Feature | Status | Notes |
|---------|--------|-------|
| Message editing (`+draft/edit=<msgid>`) | ✅ | Server verifies authorship, stores with `replaces_msgid` |
| Message deletion (`+draft/delete=<msgid>`) | ✅ | Soft delete via TAGMSG (`deleted_at` timestamp) |
| Author or ops can delete | ✅ | Permission-checked |
| Edits update in-memory history | ✅ | Broadcasts to channel |
| Deleted messages excluded from history | ✅ | Excluded from CHATHISTORY and JOIN replay |

---

## 11.7. Pinned Messages 🆕

| Feature | Status | Notes |
|---------|--------|-------|
| `PIN <channel> <msgid>` command | ✅ | Ops can pin messages |
| `UNPIN <channel> <msgid>` command | ✅ | Ops can unpin messages |
| `PINS <channel>` command | ✅ | List pinned messages |
| REST API (`GET /api/v1/channels/{name}/pins`) | ✅ | Web client support |
| Duplicate pin prevention | ✅ | |

---

## 12. OAuth 2.0 (AT Protocol) 🆕

| Feature | Status | Notes |
|---------|--------|-------|
| Browser-based OAuth login | ✅ | Opens system browser |
| Authorization server discovery | ✅ | Protected resource metadata → AS metadata |
| Pushed Authorization Request (PAR) | ✅ | Required by Bluesky |
| PKCE (S256) | ✅ | |
| DPoP key generation (P-256 / ES256) | ✅ | |
| DPoP proof creation (RFC 9449) | ✅ | With `ath` claim |
| DPoP nonce discovery and retry | ✅ | |
| Token exchange | ✅ | |
| Token refresh | ✅ | `PdsSessionSigner` with `RwLock` interior mutability |
| Session caching to disk | ✅ | `~/.config/freeq-tui/<handle>.session.json` |
| Cached session validation | ✅ | Probes PDS on reuse |
| Restrictive file permissions (0600) | ✅ | |
| Handle → DID → PDS resolution | ✅ | |

---

## 13. TUI Client

### Buffers & Navigation

| Feature | Status | Notes |
|---------|--------|-------|
| Multi-buffer UI (status + channels + PMs) | ✅ | |
| Buffer switching (Ctrl-N/P, Alt-N/P, Shift-Tab) | ✅ | |
| Auto-buffer creation on JOIN/PM | ✅ | |
| P2P DM dedicated buffers | ✅ | `p2p:<short-id>` |
| Unread indicator (●) | ✅ | |
| PageUp/PageDown scroll | ✅ | |
| Channel member list in buffer | ✅ | |

### Input Editing

| Feature | Status | Notes |
|---------|--------|-------|
| Emacs keybindings (default) | ✅ | Full readline-style |
| Vi mode (`--vi`) | ✅ | Normal + Insert modes |
| Kill ring (Ctrl-K/U/W/Y) | ✅ | |
| Word motion (Alt-F/B/D) | ✅ | |
| Case transforms (Alt-U/L/C) | ✅ | |
| Transpose (Ctrl-T) | ✅ | |
| Tab nick completion | ✅ | |
| Input history (Up/Down) | ✅ | |

### Display

| Feature | Status | Notes |
|---------|--------|-------|
| Status bar (transport, nick, auth, uptime) | ✅ | |
| Transport badge (color-coded) | ✅ | Red=TCP, Green=TLS, Cyan=WS, Magenta=Iroh |
| Network info popup (`/net`) | ✅ | |
| Debug mode (`/debug`) | ✅ | Raw IRC lines |
| Rich media display (🖼 badge) | ✅ | Image/video/audio formatting |
| E2EE status display | ✅ | 🔒 prefix on encrypted channels |

### Commands (45+ total)

`/join`, `/part`, `/msg`, `/me`, `/topic`, `/mode`, `/op`, `/deop`, `/voice`, `/kick`, `/ban`, `/unban`, `/invite`, `/whois`, `/names`, `/who`, `/list`, `/away`, `/motd`, `/nick`, `/raw`, `/encrypt`, `/decrypt`, `/p2p start`, `/p2p id`, `/p2p connect`, `/p2p msg`, `/net`, `/debug`, `/quit`, `/help`, `/commands`, plus MODE variants (+o/-o, +v/-v, +b/-b, +i/-i, +t/-t, +k/-k, +n/-n, +m/-m).

---

## 14. SDK

| Feature | Status | Notes |
|---------|--------|-------|
| `(ClientHandle, Receiver<Event>)` pattern | ✅ | Any UI/bot can consume |
| Pluggable `ChallengeSigner` trait | ✅ | KeySigner, PdsSessionSigner, StubSigner |
| `PdsSessionSigner` with token refresh | ✅ | `RwLock` interior mutability, `new_with_refresh()` |
| `establish_connection()` pre-TUI | ✅ | Connection errors before UI starts |
| Iroh auto-discovery (`discover_iroh_id`) | ✅ | Probe CAP LS for iroh upgrade |
| Tagged message sending | ✅ | `send_tagged`, `send_media`, `send_reaction` |
| P2P DM subsystem | ✅ | Full lifecycle management |
| E2EE encrypt/decrypt | ✅ | Library functions |
| DID resolution | ✅ | HTTP and static resolvers |
| Crypto key generation and signing | ✅ | secp256k1 + ed25519 |
| PDS client (create session, verify) | ✅ | |
| Bluesky profile fetching | ✅ | Public API, no auth needed |
| Media upload to PDS | ✅ | With DPoP retry |
| Link preview fetching | ✅ | OpenGraph parsing |
| **🆕** Bot framework | ✅ | Command routing, permission levels (Anyone/Auth/Admin), auto-help |
| **🆕** DID-based E2EE (ENC2) | ✅ | Group key + ECDH DM encryption |
| Echo bot example | ✅ | `examples/echo_bot.rs` |
| Framework bot example | ✅ | `examples/framework_bot.rs` — commands with permissions |
| IRC message parser with tag support | ✅ | |

---

## 15. Testing

| Category | Count | Notes |
|----------|-------|-------|
| SDK unit tests | 35 | IRC parsing, crypto, DID, media, auth |
| Server unit tests | 33 | Parsing, SASL, channel state, DB, CRDT |
| Integration tests | 27 | End-to-end auth flows, channel ops, persistence |
| S2S acceptance tests | 39 | 16 single-server + 14 S2S + 9 netsplit/reconnect |
| **Total** | **134** | |

---

## 16. Configuration

| Option | Default | Notes |
|--------|---------|-------|
| `--listen-addr` | `127.0.0.1:6667` | Plain TCP |
| `--tls-listen-addr` | `127.0.0.1:6697` | TLS |
| `--tls-cert` / `--tls-key` | None | Enables TLS |
| `--server-name` | `freeq` | |
| `--challenge-timeout-secs` | `60` | |
| `--db-path` | None (in-memory) | |
| `--web-addr` | None | Enables HTTP/WS |
| `--iroh` | false | Enables iroh |
| `--iroh-port` | random | |
| `--s2s-peers` | empty | Comma-separated endpoint IDs |
| `--max-messages-per-channel` | None | Message pruning |
| `--plugin` | None | Load a plugin by name (repeatable) |
| `--plugin-dir` | None | Directory of `*.toml` plugin configs |

---

## 17. Plugin System 🆕

| Feature | Status | Notes |
|---------|--------|-------|
| `Plugin` trait with event hooks | ✅ | Extensible server behavior |
| `PluginManager` in SharedState | ✅ | Dispatches events to all loaded plugins |
| CLI activation (`--plugin name:k=v`) | ✅ | Inline config via key=value pairs |
| Directory loading (`--plugin-dir`) | ✅ | Each `*.toml` file = one plugin |
| TOML config format | ✅ | Supports multi-rule plugins |
| `on_auth` hook | ✅ | Override DID/handle after SASL auth |
| `identity-override` built-in plugin | ✅ | Match by handle or DID, replace display ID |
| Example: `examples/plugins/kurt.toml` | ✅ | TimeSync.bsky.social → 3\|337 |
