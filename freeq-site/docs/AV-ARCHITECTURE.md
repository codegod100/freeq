# AV Architecture

## Data Path: Browser-to-Browser Voice Call

```
┌─── Browser A ────────────────────────────────────────────────┐
│                                                               │
│  Microphone                                                   │
│    ↓ getUserMedia({ audio: true })                           │
│  moq-publish web component                                    │
│    ↓ Opus encode (libav-opus WASM)                           │
│    ↓ hang format (MoQ broadcast frames)                      │
│    ↓ MoQ ANNOUNCE + OBJECT frames                            │
│    ↓ qmux multiplexing                                       │
│    ↓ WebSocket binary (wss://host/av/moq)                    │
│                                                               │
└───────────────────────────┬───────────────────────────────────┘
                            │
                    ┌───────▼───────┐
                    │   TLS / TCP   │
                    └───────┬───────┘
                            │
┌───────────────────────────▼───────────────────────────────────┐
│                                                               │
│  freeq-server                                                 │
│                                                               │
│  axum WebSocket handler (/av/moq)                            │
│    ↓ axum WS ↔ tungstenite conversion                        │
│    ↓ qmux::ws::accept() — demux MoQ frames                  │
│    ↓                                                          │
│  moq_lite::Server                                             │
│    .with_consume(publisher)  ← takes client's published audio │
│    .with_publish(subscriber) → sends other clients' audio     │
│    ↓                                                          │
│  moq_relay::Cluster                                           │
│    ├─ In-memory routing by broadcast name                     │
│    ├─ session/alice → subscribers of session/alice             │
│    ├─ session/bob   → subscribers of session/bob              │
│    └─ No iroh involved — pure MoQ relay                       │
│                                                               │
└───────────────────────────┬───────────────────────────────────┘
                            │
                    ┌───────▼───────┐
                    │   TLS / TCP   │
                    └───────┬───────┘
                            │
┌───────────────────────────▼───────────────────────────────────┐
│                                                               │
│  Browser B                                                    │
│                                                               │
│  moq-watch web component (one per remote participant)         │
│    ↓ WebSocket binary ← qmux ← MoQ OBJECT frames            │
│    ↓ Opus decode (libav-opus WASM AudioWorklet)              │
│    ↓ Web Audio API (AudioContext → speaker)                   │
│  Speaker                                                      │
│                                                               │
└───────────────────────────────────────────────────────────────┘
```

## Protocol Stack (per WebSocket connection)

```
┌──────────────────────────┐
│  Opus audio frames       │  Codec layer
├──────────────────────────┤
│  hang format             │  MoQ broadcast catalog
├──────────────────────────┤
│  MoQ (ANNOUNCE, OBJECT)  │  Media transport
├──────────────────────────┤
│  qmux                    │  Stream multiplexing
├──────────────────────────┤
│  WebSocket (binary)      │  Transport
├──────────────────────────┤
│  TLS / TCP               │  Network
└──────────────────────────┘
```

## Where iroh IS and ISN'T used

```
                    ┌─────────────────────────────────┐
                    │         freeq-server             │
                    │                                  │
  Browser ◄──WS──► │  moq_relay::Cluster  ── NO iroh  │
                    │                                  │
  Native  ◄──WS──► │  moq_relay::Cluster  ── NO iroh  │
  (SFU mode)        │                                  │
                    │                                  │
  Native  ◄─QUIC─► │  moq_native (QUIC)   ── NO iroh  │
  (SFU mode)        │    (optional, may not bind)      │
                    │                                  │
  Peer    ◄─QUIC─► │  iroh endpoint        ── YES     │
  Server            │    └─ S2S federation (JSON)      │
                    │                                  │
  Native  ◄─QUIC─► │  iroh-live backend    ── YES     │
  (room mode)       │    └─ P2P audio rooms            │
                    │       (not used by browser)      │
                    └─────────────────────────────────┘
```

**For browser-to-browser calls: iroh is not in the audio path.**

iroh is used for:
- **S2S federation** — QUIC mesh between freeq servers for chat/presence
- **iroh-live rooms** — native-to-native P2P audio (alternative to SFU)
- **iroh endpoint** — cryptographic server identity

## Participant Discovery

Browser call pages discover other participants via REST API polling:

```
call.html  ──GET /api/v1/sessions/{id}──►  freeq-server
           ◄── { participants: [{nick: "bob"}, ...] }

For each remote participant:
  create <moq-watch name="session/bob" url="wss://host/av/moq">
```

The native client uses MoQ announce-based discovery instead:
```rust
while let Some((path, announce)) = sub_consumer.announced().await {
    // Auto-subscribe to announced broadcasts
}
```

## Session Control (separate from media)

```
IRC WebSocket (/irc)              Media WebSocket (/av/moq)
─────────────────────             ────────────────────────
TAGMSG +freeq.at/av-start   →    (no direct link)
TAGMSG +freeq.at/av-join    →    moq-publish connects
TAGMSG +freeq.at/av-leave   →    moq-publish disconnects
TAGMSG +freeq.at/av-state   ←    (broadcast to channel)
```

Session control flows through IRC. Media flows through MoQ.
They are intentionally decoupled — the media backend is swappable.

---

## Technical Reference

### Session lifecycle (IRC protocol)

All session control uses TAGMSG with `+freeq.at/av-*` tags on the channel.

#### Start a session

```irc
@+freeq.at/av-start;+freeq.at/av-title=standup TAGMSG #channel
```

Server broadcast (to channel, TAGMSG for rich clients + NOTICE fallback):
```irc
@+freeq.at/av-state=started;+freeq.at/av-id=01KN7X...;+freeq.at/av-participants=1;+freeq.at/av-actor=nick :server TAGMSG #channel
```

#### Join a session

```irc
@+freeq.at/av-join;+freeq.at/av-id=01KN7X... TAGMSG #channel
```

or without an ID (joins the channel's active session):

```irc
@+freeq.at/av-join TAGMSG #channel
```

#### Leave / End

```irc
@+freeq.at/av-leave;+freeq.at/av-id=01KN7X... TAGMSG #channel
@+freeq.at/av-end;+freeq.at/av-id=01KN7X... TAGMSG #channel
```

Sessions auto-end when the last participant leaves.

### REST API

```
GET  /api/v1/sessions                    Active sessions
GET  /api/v1/sessions/{id}               Session detail + participants
GET  /api/v1/sessions/{id}/artifacts     Session artifacts
POST /api/v1/sessions/{id}/artifacts     Create artifact
GET  /api/v1/channels/{name}/sessions    Active + recent sessions for channel
```

### S2S federation

Session lifecycle events federate via the existing S2S protocol:

```
AvSessionCreated  { session_id, channel, created_by_did, title, origin }
AvSessionJoined   { session_id, did, nick, origin }
AvSessionLeft     { session_id, did, origin }
AvSessionEnded    { session_id, ended_by, origin }
```

### Database schema

```sql
CREATE TABLE av_sessions (
    id TEXT PRIMARY KEY, channel TEXT, created_by TEXT NOT NULL,
    created_at INTEGER NOT NULL, ended_at INTEGER, ended_by TEXT,
    title TEXT, iroh_ticket TEXT, backend TEXT, recording BOOLEAN,
    max_participants INTEGER
);

CREATE TABLE av_participants (
    session_id TEXT NOT NULL, did TEXT NOT NULL, nick TEXT NOT NULL,
    joined_at INTEGER NOT NULL, left_at INTEGER, role TEXT,
    PRIMARY KEY (session_id, did)
);

CREATE TABLE av_artifacts (
    id TEXT PRIMARY KEY, session_id TEXT NOT NULL, kind TEXT NOT NULL,
    created_at INTEGER NOT NULL, created_by TEXT, content_ref TEXT NOT NULL,
    content_type TEXT NOT NULL, visibility TEXT, title TEXT
);
```

### Security (current state)

**Not production-ready.** The MoQ SFU has no authentication:
- `auth_config.public = Some("/")` — all paths public
- No channel membership check on WebSocket upgrade
- No session participant verification
- Broadcast names are guessable (`{session_id}/{nick}`)

Before production: add JWT tokens issued on session join, validated on SFU connect.

### Feature flags

- **Default (no features):** Session management works, no SFU. Suitable for container deployment.
- **`av-native`:** Adds moq-relay SFU (WebSocket + optional QUIC), iroh-live backend for native P2P rooms. Requires `libasound2-dev` and `cmake` on Linux.
