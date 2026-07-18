# AV Sessions: Technical & Implementation Plan

**Status:** Draft
**Branch:** `av-sessions`
**Date:** 2026-04-02

---

## 1. What this is

A real-time session subsystem for freeq: voice, video, and screen sharing backed by iroh-live, with durable artifact attachment into freeq's existing identity, audit, and agent model.

The strategic value isn't "freeq has calls." It's:

> Real-time sessions whose outputs become part of the same durable graph as messages, tasks, audits, agents, and code context.

---

## 2. Architecture overview

```
                  ┌─────────────────────────────────────┐
                  │          freeq-server (Rust)         │
                  │                                      │
                  │  AvSessionManager                    │
                  │    ├── sessions: HashMap<id, AvSession>│
                  │    ├── iroh Live endpoint            │
                  │    └── artifact store (DB + PDS)     │
                  │                                      │
                  │  ────── existing ──────              │
                  │  SharedState, Channels, S2S, CRDT    │
                  │  Identity (DID), Policy, DB          │
                  └──────┬──────────┬───────────────────┘
                         │          │
              IRC/WS     │          │  iroh QUIC (native)
              control    │          │  WebTransport (browser)
                         │          │
                  ┌──────┴──┐  ┌───┴────────────┐
                  │ Web/TUI │  │  iroh-live      │
                  │ client  │  │  media streams  │
                  └─────────┘  └────────────────┘
```

**Key design decision:** Session control flows through IRC (TAGMSG + custom tags or a new command). Media flows through iroh-live. These are separate paths — no media over IRC.

---

## 3. What already exists (and what we reuse)

| Existing infrastructure | How AV sessions use it |
|---|---|
| `SharedState` (server.rs:417) | Add `av_sessions: HashMap<AvSessionId, AvSession>` |
| `ChannelState` (server.rs:23) | Add `active_session: Option<AvSessionId>` |
| `session_dids` (server.rs:426) | Auth gate for join — must have DID to join AV |
| `iroh::Endpoint` (iroh.rs:148) | Reuse for iroh-live media transport |
| `S2sMessage` enum (s2s.rs:112) | Add `AvSessionCreated`, `AvSessionEnded`, `AvSessionJoined` variants |
| CRDT doc (crdt.rs) | Persist session metadata for cross-server visibility |
| `db.rs` tables | New `av_sessions`, `av_participants`, `av_artifacts` tables |
| Policy engine (policy/types.rs) | Gate who can start/join sessions, access artifacts |
| `web.rs` REST API | New `/api/v1/sessions/*` endpoints |
| Frontend store (store.ts) | New `avSessions` state slice |
| Agent framework | Agents can observe sessions, generate artifacts |

---

## 4. iroh-live assessment

**Version:** Early alpha (repo created Nov 2025, actively developed)
**Transport:** QUIC via iroh, MoQ protocol (each track = independent QUIC stream)
**Codecs:** H.264 (openh264), AV1 (rav1e/rav1d), Opus — software + hardware accel
**Browser:** Via relay server (WebTransport). No WASM client. Relay has no auth yet.
**Rooms:** Functional but lightly tested. Uses iroh-gossip for peer discovery.
**Risk level:** High. API will change. Windows support incomplete. No auth on relay.

**Mitigation strategy:**
- Wrap iroh-live behind a `MediaBackend` trait so we can swap implementations
- Phase 1 targets native clients only (iroh QUIC direct)
- Browser support deferred to Phase 2 (relay + WebTransport)
- Keep session control on IRC so media backend is swappable

---

## 5. Data model

### 5.1 Rust types

```rust
/// Unique session identifier (ULID)
type AvSessionId = String;

/// Session lifecycle
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum AvSessionState {
    Active,
    Ended { ended_at: i64, ended_by: Option<String> },
}

/// A real-time AV session, optionally bound to a channel
#[derive(Debug, Clone)]
pub struct AvSession {
    pub id: AvSessionId,
    pub channel: Option<String>,           // #channel or None for ad-hoc
    pub created_by: String,                // DID of creator
    pub created_at: i64,                   // Unix timestamp
    pub state: AvSessionState,
    pub participants: HashMap<String, AvParticipant>, // DID → participant
    pub title: Option<String>,
    pub iroh_ticket: Option<String>,       // iroh-live connection ticket
    pub media_backend: MediaBackendType,
    pub recording_enabled: bool,           // Phase 2
    pub max_participants: Option<u32>,
}

#[derive(Debug, Clone)]
pub struct AvParticipant {
    pub did: String,
    pub nick: String,
    pub joined_at: i64,
    pub left_at: Option<i64>,
    pub role: ParticipantRole,
    pub tracks: Vec<TrackInfo>,            // What they're publishing
}

#[derive(Debug, Clone, Copy)]
pub enum ParticipantRole {
    Host,       // Can mute others, end session, manage recording
    Speaker,    // Can publish audio/video
    Listener,   // Can only receive (for large rooms, Phase 4)
}

#[derive(Debug, Clone)]
pub struct TrackInfo {
    pub kind: TrackKind,    // Audio, Video, Screen
    pub muted: bool,
}

#[derive(Debug, Clone, Copy)]
pub enum TrackKind { Audio, Video, Screen }

/// Swappable media backend
#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
pub enum MediaBackendType {
    IrohLive,   // Phase 1: native iroh QUIC
    // WebRTC,  // Future: browser fallback
}

/// Durable artifact from a session (Phase 2)
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AvArtifact {
    pub id: String,                        // ULID
    pub session_id: AvSessionId,
    pub kind: ArtifactKind,
    pub created_at: i64,
    pub created_by: Option<String>,        // DID (None = system-generated)
    pub content_ref: String,               // PDS blob CID or URL
    pub content_type: String,              // MIME type
    pub visibility: ArtifactVisibility,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum ArtifactKind {
    Transcript,
    Summary,
    Recording,
    Decisions,     // Phase 3: extracted decisions
    Tasks,         // Phase 3: extracted action items
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum ArtifactVisibility {
    Participants,  // Only session participants
    Channel,       // Anyone in the channel
    Public,        // Anyone with the link
}
```

### 5.2 Database tables

```sql
-- Core session table
CREATE TABLE av_sessions (
    id          TEXT PRIMARY KEY,
    channel     TEXT,                          -- NULL for ad-hoc sessions
    created_by  TEXT NOT NULL,                 -- DID
    created_at  INTEGER NOT NULL,
    ended_at    INTEGER,
    ended_by    TEXT,                          -- DID
    title       TEXT,
    iroh_ticket TEXT,
    backend     TEXT NOT NULL DEFAULT 'iroh-live',
    recording   BOOLEAN NOT NULL DEFAULT FALSE,
    max_participants INTEGER
);

-- Who participated (survives session end)
CREATE TABLE av_participants (
    session_id  TEXT NOT NULL REFERENCES av_sessions(id),
    did         TEXT NOT NULL,
    nick        TEXT NOT NULL,
    joined_at   INTEGER NOT NULL,
    left_at     INTEGER,
    role        TEXT NOT NULL DEFAULT 'speaker',
    PRIMARY KEY (session_id, did)
);

-- Durable artifacts (Phase 2)
CREATE TABLE av_artifacts (
    id          TEXT PRIMARY KEY,
    session_id  TEXT NOT NULL REFERENCES av_sessions(id),
    kind        TEXT NOT NULL,                 -- transcript, summary, recording, decisions, tasks
    created_at  INTEGER NOT NULL,
    created_by  TEXT,                          -- DID (NULL = system)
    content_ref TEXT NOT NULL,                 -- PDS blob CID or URL
    content_type TEXT NOT NULL,
    visibility  TEXT NOT NULL DEFAULT 'participants'
);
CREATE INDEX idx_av_artifacts_session ON av_artifacts(session_id);
```

---

## 6. IRC protocol extensions

Session control uses IRCv3 tags on TAGMSG. This keeps session signaling in the existing message path without a new transport.

### 6.1 Start session

```
@+freeq.at/av-start;+freeq.at/av-id=01HXY...;+freeq.at/av-title=standup :nick!u@h TAGMSG #channel
```

Server validates: sender is authenticated (has DID), channel exists, sender is member. Creates AvSession, broadcasts to channel.

### 6.2 Join session

```
@+freeq.at/av-join;+freeq.at/av-id=01HXY... :nick!u@h TAGMSG #channel
```

Server validates: DID authenticated, session exists and active. Adds participant, returns iroh ticket via NOTICE or a 3xx numeric.

### 6.3 Leave session

```
@+freeq.at/av-leave;+freeq.at/av-id=01HXY... :nick!u@h TAGMSG #channel
```

### 6.4 End session

```
@+freeq.at/av-end;+freeq.at/av-id=01HXY... :nick!u@h TAGMSG #channel
```

Only host or channel ops can end a session.

### 6.5 Session state notification (server → clients)

```
@+freeq.at/av-state;+freeq.at/av-id=01HXY...;+freeq.at/av-participants=3 :server TAGMSG #channel
```

Sent on participant changes so all channel members see the session indicator.

---

## 7. S2S federation

### 7.1 New S2S message variants

```rust
// Add to S2sMessage enum in s2s.rs
AvSessionCreated {
    event_id: String,
    session_id: String,
    channel: String,
    created_by_did: String,
    title: Option<String>,
    iroh_ticket: Option<String>,
    origin: String,
}
AvSessionJoined {
    event_id: String,
    session_id: String,
    did: String,
    nick: String,
    origin: String,
}
AvSessionLeft {
    event_id: String,
    session_id: String,
    did: String,
    origin: String,
}
AvSessionEnded {
    event_id: String,
    session_id: String,
    ended_by: Option<String>,
    origin: String,
}
```

### 7.2 What federates vs what doesn't

| Federates | Doesn't federate |
|---|---|
| Session existence (created/ended) | Media streams (iroh-live handles its own transport) |
| Who participated | Track state (muted/unmuted) |
| Artifacts (references) | Live media negotiation |
| Session metadata (title, channel) | Recording data |

The host server owns the iroh-live room. Remote participants connect directly to the iroh-live endpoint using the ticket.

---

## 8. REST API

```
POST   /api/v1/sessions                    Create session
GET    /api/v1/sessions                    List active sessions
GET    /api/v1/sessions/{id}               Session details + participants
POST   /api/v1/sessions/{id}/join          Join (returns iroh ticket)
POST   /api/v1/sessions/{id}/leave         Leave
POST   /api/v1/sessions/{id}/end           End session (host/ops only)
GET    /api/v1/sessions/{id}/artifacts     List artifacts (Phase 2)
POST   /api/v1/sessions/{id}/artifacts     Attach artifact (Phase 2)
GET    /api/v1/channels/{name}/sessions    Sessions in a channel (active + recent)
```

All endpoints require DID authentication.

---

## 9. Frontend changes

### 9.1 Store additions (`store.ts`)

```typescript
interface AvSession {
  id: string;
  channel: string | null;
  createdBy: string;           // DID
  createdByNick: string;
  title?: string;
  participants: Map<string, AvParticipant>;
  state: 'active' | 'ended';
  startedAt: Date;
}

interface AvParticipant {
  did: string;
  nick: string;
  role: 'host' | 'speaker' | 'listener';
  tracks: { kind: 'audio' | 'video' | 'screen'; muted: boolean }[];
}

// New state
avSessions: Map<string, AvSession>;        // session_id → session
activeAvSession: string | null;            // session we're in
localTracks: { audio: boolean; video: boolean; screen: boolean };
```

### 9.2 UI components

| Component | Purpose | Phase |
|---|---|---|
| `SessionIndicator` | Badge in channel header showing active session + participant count | 1 |
| `SessionBar` | Floating bar when in a session: mute/unmute, video on/off, screen share, leave, end | 1 |
| `SessionPanel` | Side panel with participant grid (video tiles) | 1 |
| `JoinPrompt` | Toast/banner when a session starts in your channel | 1 |
| `SessionHistory` | List of past sessions with duration, participants | 2 |
| `ArtifactViewer` | View transcript, summary, decisions from a session | 2 |
| `SessionDetail` | Full session page: timeline, artifacts, participants | 2 |

### 9.3 Sidebar changes

Add to channel button: a small phone/video icon when a session is active in that channel. Clicking it joins.

---

## 10. Implementation phases

### Phase 1: Session MVP (prove the architecture)

**Goal:** Users can start a voice/video session in a channel. Other channel members see it and can join. Session lifecycle is visible in the channel.

**Build:**
1. `AvSessionManager` in server.rs — session CRUD, participant tracking
2. DB tables: `av_sessions`, `av_participants`
3. IRC TAGMSG handlers for `+freeq.at/av-*` tags
4. REST endpoints: create, join, leave, end, list
5. iroh-live integration: `MediaBackend` trait, `IrohLiveBackend` impl
6. S2S variants: `AvSessionCreated`, `AvSessionEnded`, `AvSessionJoined`, `AvSessionLeft`
7. Frontend: `SessionIndicator`, `SessionBar`, `JoinPrompt`
8. Zustand: `avSessions` slice, TAGMSG handlers

**Not in Phase 1:** Recording, transcripts, artifacts, browser media (browser users see session indicator but can't join media), large rooms.

**Native clients get media via iroh-live direct QUIC. Web clients see the session UI but get "Open in desktop app to join" until Phase 2.**

**Estimated scope:** ~2000 lines Rust, ~500 lines TypeScript

### Phase 2: Durable artifacts

**Goal:** Sessions produce useful output after they end.

**Build:**
1. Recording pipeline: iroh-live → local file → PDS blob upload
2. Transcript generation (Whisper API or similar, behind trait)
3. Summary generation (LLM, behind trait)
4. `av_artifacts` table + REST endpoints
5. Artifact posts visible in channel (system messages with links)
6. `SessionHistory` and `ArtifactViewer` UI
7. Browser relay for iroh-live (WebTransport)
8. Consent model: opt-in recording, visible indicator

**Estimated scope:** ~3000 lines Rust, ~1500 lines TypeScript

### Phase 3: Agent usefulness

**Goal:** Strategic differentiation — sessions feed the work graph.

**Build:**
1. Decision extraction from transcripts (agent/LLM)
2. Task generation from action items
3. Session references in coordination events
4. Retrieval over transcripts/summaries (FTS5 or embedding search)
5. Policy-gated agent access to session data
6. Agent-generated session summaries posted to channel

### Phase 4: Hardening

**Goal:** Production confidence.

**Build:**
1. Browser parity (relay auth, WebTransport hardening)
2. Room scaling (SFU mode for >8 participants)
3. Retention policies (auto-delete recordings after N days)
4. Observability (session metrics, quality monitoring)
5. Cost controls (recording storage, transcription costs)
6. Moderation/reporting
7. Rate limiting on session creation

---

## 11. Risks and mitigations

| Risk | Severity | Mitigation |
|---|---|---|
| iroh-live maturity | **High** | `MediaBackend` trait allows swapping. Phase 1 is native-only (simplest path). Keep session control on IRC so media backend is replaceable. |
| Browser parity | Medium | Defer to Phase 2. Web users see session indicator + artifacts but can't join media in Phase 1. Relay auth is required before browser media. |
| Overcoupling to IRC transport | Medium | Session control uses TAGMSG (which is IRC) but the actual session state lives in `AvSessionManager` — a standalone component. REST API provides non-IRC access. |
| Storage/processing creep | Medium | Strict phasing. No recording until Phase 2. No AI features until Phase 3. Each phase has a clear "done" boundary. |
| Privacy/compliance | **High** | Design consent model in Phase 1 (even without recording). Visible "session active" indicators. Recording requires explicit opt-in. Artifact visibility is participant-scoped by default. Deletion API from day 1. |
| iroh-live depends on unreleased crates | Medium | Pin specific git revisions. Vendor if needed. The `[patch.crates-io]` approach from iroh-live's own Cargo.toml works. |

---

## 12. Open questions

1. **Should sessions outlive the channel?** A session started in `#standup` — if everyone leaves the channel, does the session end? Recommendation: yes, end it. Orphan sessions are confusing.

2. **Ad-hoc sessions (DM calls)?** Phase 1 could support 1:1 DM sessions with minimal extra work. Same machinery, channel field is None, participants are the two DM nicks.

3. **Screen share as a separate track or session type?** Recommendation: separate track within same session (matches iroh-live's model where each source is an independent QUIC stream).

4. **Who pays for transcription/recording storage?** The session creator's PDS stores the blobs. Agent budget system can gate AI-generated artifacts. This needs explicit design before Phase 2.

5. **Should session TAGMSG events appear in CHATHISTORY?** Recommendation: no. Session lifecycle is stored in the `av_sessions` table. Channel history shows system messages ("chad started a voice session") but not the raw TAGMSG control traffic.

---

## 13. File-level change map (Phase 1)

| File | Changes |
|---|---|
| `freeq-server/src/server.rs` | Add `AvSessionManager` to `SharedState`, add `av_sessions` field |
| `freeq-server/src/av.rs` | **New.** `AvSessionManager`, `AvSession`, `AvParticipant`, lifecycle methods |
| `freeq-server/src/av_media.rs` | **New.** `MediaBackend` trait, `IrohLiveBackend` impl |
| `freeq-server/src/db.rs` | Add `av_sessions`, `av_participants` tables, CRUD methods |
| `freeq-server/src/connection/messaging.rs` | Handle `+freeq.at/av-*` tags in TAGMSG |
| `freeq-server/src/web.rs` | Add `/api/v1/sessions/*` endpoints |
| `freeq-server/src/s2s.rs` | Add `AvSession*` S2S message variants |
| `freeq-server/src/crdt.rs` | Add `"av_session:{channel}"` key for session existence |
| `freeq-server/Cargo.toml` | Add `iroh-live` dependency (git pin) |
| `freeq-app/src/store.ts` | Add `avSessions`, `activeAvSession`, `localTracks` |
| `freeq-app/src/irc/client.ts` | Handle `+freeq.at/av-*` TAGMSG tags |
| `freeq-app/src/components/SessionIndicator.tsx` | **New.** Channel header badge |
| `freeq-app/src/components/SessionBar.tsx` | **New.** Floating session controls |
| `freeq-app/src/components/JoinPrompt.tsx` | **New.** Session start notification |
| `freeq-app/src/components/Sidebar.tsx` | Add session indicator to channel buttons |
| `freeq-app/src/components/TopBar.tsx` | Add session indicator/join button |

---

## 14. Success criteria

### Phase 1 done when:
- [ ] Two native users can start a voice session in a channel
- [ ] Other channel members see "Session active (2 participants)"
- [ ] Users can join/leave the session
- [ ] Session ends when last participant leaves or host ends it
- [ ] Web users see session indicator (but can't join media)
- [ ] Session existence federates to peer servers
- [ ] Session lifecycle is persisted in DB
- [ ] Session info visible via REST API
