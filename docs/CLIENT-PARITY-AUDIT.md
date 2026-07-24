# Client Parity & Delight Audit — Web · macOS · iOS

Date: 2026-07-23. Method: source survey of `freeq-app/` (React/TS),
`freeq-macos/` (SwiftUI+AppKit / Rust core), `freeq-ios/` (SwiftUI / Rust
core), cross-checked against live behavior staged for the client
screenshots. Legend: ✅ full · ⚠️ partial/basic · ❌ absent · — n/a for
platform.

This is the basis for a parity + delight plan, not a shipping checklist yet.
Counts in parentheses are file-hit signals, not guarantees — statuses are the
considered call.

---

## 1. The grid

### Core messaging
| Feature | Web | macOS | iOS | Notes |
|---|:--:|:--:|:--:|---|
| Send / receive / history (CHATHISTORY) | ✅ | ✅ | ✅ | all hydrate from server history |
| Reactions | ✅ | ✅ | ✅ | web has the richest emoji picker; native uses a quick set |
| Threads / replies | ✅ | ✅ | ✅ | |
| Edit message | ✅ | ✅ | ✅ | iOS dedup on replay just fixed (2026-07-23) |
| Delete (tombstone) | ✅ | ✅ | ✅ | |
| Pins | ✅ | ✅ | ✅ | iOS pin UI is notably complete |
| In-buffer / server search | ✅ | ✅ | ✅ | all three have a search surface |
| Markdown + code / syntax highlight | ✅ | ✅ | ✅ | macOS has the deepest tokenizer (`SyntaxHighlighter`) |
| Bluesky post embeds | ✅ | ✅ | ✅ | |
| YouTube / link previews | ✅ | ✅ | ✅ | |
| Media upload (image/file) | ✅ | ✅ | ✅ | |
| Typing indicators | ✅ | ✅ | ✅ | |
| away-notify | ✅ | ✅ | ✅ | |
| Read markers (draft/read-marker) | ⚠️ | ⚠️ | ⚠️ | stored server-side; minimal "new" UI everywhere |
| Signed-message badge | ✅ | ✅ | ✅ | verified in the staged shots |
| Multi-message block copy → clean transcript | ❌ | ✅ | ❌ | **macOS-only** (shipped 2026-07-23) |

### Identity & trust
| Feature | Web | macOS | iOS | Notes |
|---|:--:|:--:|:--:|---|
| Bluesky OAuth login | ✅ | ✅ | ✅ | |
| Guest connect | ✅ | ✅ | ✅ | |
| Verified / DID badges | ✅ | ✅ | ✅ | |
| Channel E2EE (passphrase / VC) | ✅ | ✅ | ❌ | **iOS has none** — `ChannelE2ee`/`channelKey` absent |
| P2P (iroh) direct DMs | ❌ | ✅ | ❌ | **macOS-only** |
| Policy / join-gate UI | ✅ | ✅ | ❌ | **iOS shows no gate prompt** (`joingate`/`accessdenied` = 0) |

### Audio / video (sessions)
| Feature | Web | macOS | iOS | Notes |
|---|:--:|:--:|:--:|---|
| Voice call | ✅ | ✅ | ✅ | |
| Video / camera | ✅ | ✅ | ✅ | |
| Screen share | ✅ | ✅ | ⚠️ | iOS can view a share; broadcasting from iOS is limited |
| Camera effects / background blur | ❌ | ✅ | ❌ | **macOS-only** (`CameraEffectsProcessor`) |
| Call grid auto-layout (1→~30) | ⚠️ | ✅ | ⚠️ | macOS `CallLayoutPolicies` is the reference; **P1 TODO** to port to web/iOS |
| Click-to-focus a tile | ❌ | ❌ | ❌ | **P1 TODO everywhere** |
| CallKit (native call UI) | — | — | ✅ | **iOS-only**, appropriate |

### Agent & session observability — *the pitch surface*
| Feature | Web | macOS | iOS | Notes |
|---|:--:|:--:|:--:|---|
| Coordination cards (task_request/update/complete) | ✅ | ❌ | ❌ | **web-only** — the agent-native UI lives only on web |
| Task timeline | ✅ | ❌ | ❌ | web-only |
| Audit / governance timeline | ✅ | ❌ | ❌ | web-only |
| Session history browser | ✅ | ⚠️ | ⚠️ | web `SessionHistory`/`SessionIndicator`; native shows live call state only |

### AI & delight
| Feature | Web | macOS | iOS | Notes |
|---|:--:|:--:|:--:|---|
| On-device smart replies | ❌ | ❌ | ✅ | **iOS-only** (`IntelligenceService`) |
| Catch-up digest | ❌ | ❌ | ✅ | **iOS-only** (`CatchUpDigestSheet`) |
| Voice messages + transcription | ⚠️ | ✅ | ✅ | iOS deepest; web is basically `AudioTest` only |
| Sound design | ⚠️ | ✅ | ✅ | web is thin |
| Onboarding flow | ✅ | ✅ | ❌ | **iOS has none** |
| Jumbomoji (≤3 emoji → large) | ❌ | ❌ | ❌ | **nobody** — designed in DESIGN doc, unbuilt |

### Platform-native reach
| Feature | Web | macOS | iOS | Notes |
|---|:--:|:--:|:--:|---|
| Menu-bar app / quick-send / global hotkey | — | ✅ | — | macOS-only, appropriate |
| Share extension (send-to-freeq) | — | ✅ | ❌ | **iOS could have this; doesn't** |
| App Intents / Siri Shortcuts | — | ✅ | ✅ | macOS deepest (18 intents); iOS present (8) |
| Live Activity (call on lock screen) | — | — | ✅ | iOS-only |
| Home-screen widgets | — | — | ✅ | iOS-only |
| Apple Watch app | — | — | ✅ | iOS-only |
| PWA install / offline shell | ✅ | — | — | web-only |
| MetricKit / perf signposts | — | ✅ | ⚠️ | macOS instruments hitches |

### Navigation & power-user
| Feature | Web | macOS | iOS | Notes |
|---|:--:|:--:|:--:|---|
| Quick switcher (⌘K) | ✅ | ✅ | ✅ | |
| Slash-command UI | ⚠️ | ✅ | ❌ | macOS `CommandRegistry` richest; **iOS none** |
| Bookmarks | ✅ | ✅ | ❌ | **iOS none** |
| Keyboard shortcuts panel | ✅ | ✅ | ⚠️ | |

### Engineering quality (tested surface)
| | Web | macOS | iOS |
|---|:--:|:--:|:--:|
| Unit/logic test files | 22 vitest | 35 core | **8 core** |
| E2E / integration | 18 Playwright specs | ui-sweep + core | thin |

---

## 2. Where each client is *best*

**Web** — the agent & governance story (coordination cards, task + audit
timelines, session history), the richest emoji picker, join-gate UX, PWA
install, and the broadest test coverage. It is currently the *only* place the
agent-native pitch is visible in-product.

**macOS** — the craft flagship: camera effects/blur, call-grid auto-layout
(the reference impl), P2P iroh DMs, channel E2EE, multi-message block copy,
menu-bar + global hotkey + share extension, 18 App Intents, syntax
highlighting, MetricKit perf discipline, most core tests.

**iOS** — the delight leader: on-device smart replies + catch-up digest
(unique AI), deepest voice-message/transcription, CallKit, Live Activity,
widgets, Watch app. Punches above its weight on ambient/mobile-native feel —
but is the thinnest on messaging breadth and tests.

---

## 3. Gaps to close (parity) — ranked

**P0 — the pitch is invisible off-web.** Coordination cards, task timeline,
and audit/governance timeline exist *only* on web. For an "agent-native"
product, macOS and iOS showing agent work as plain text undercuts the whole
story. Port the card renderer (it's pure tag→view; the wire data already
arrives on every client).

**P1 — iOS is missing whole columns.**
- Channel E2EE (web+mac have it; iOS can't read/write encrypted channels).
- Policy / join-gate UI (iOS silently fails gated joins).
- Bookmarks, slash-command UI, onboarding.
- iOS test coverage (8 files) needs to roughly triple to match the others.

**P1 — AV parity both directions.**
- Call-grid auto-layout → web + iOS (macOS is the reference).
- Click-to-focus a tile → *all three* (nobody has it; open P1 TODO).
- Camera effects/blur → web + iOS (macOS-only today).

**P2 — cross-pollinate the unique wins.**
- iOS's smart replies + catch-up digest → macOS (and web where feasible).
- macOS's block-copy transcript → web + iOS.
- macOS P2P DMs → iOS.
- iOS share extension (macOS has one; iOS doesn't).
- Read-marker "new messages" UI → finish on all three.

---

## 4. Delight opportunities (net-new, raise the ceiling everywhere)

- **Jumbomoji** — designed, built nowhere. Cheap, high-charm. Do it in the
  shared render policy so all three inherit it.
- **Reaction morphs / micro-animations** on add.
- **Agent presence as a first-class visual** — the pink/verified identity is
  great; extend it to a live "agent working" shimmer on the card (ties into
  the P0 card port).
- **Voice-message waveform + inline transcript** unified across clients
  (iOS has the pieces; lift them).
- **Sound design** parity on web (native feels alive; web is quiet).
- **Onboarding** on iOS; make all three teach the agent trick
  (watch-your-agent) in first-run.

---

## 5. Suggested sequencing

1. **Card port (P0):** shared spec doc → macOS renderer → iOS renderer.
   Single biggest strategic win; makes every client tell the pitch.
2. **iOS parity sprint (P1):** E2EE, join-gate UI, bookmarks, slash commands,
   onboarding + a test-coverage push.
3. **AV parity (P1):** grid auto-layout to web/iOS; click-to-focus everywhere;
   camera effects to web/iOS.
4. **Delight pass (P2):** jumbomoji + reaction morphs in shared policy;
   smart-replies/catch-up to macOS; block-copy to web/iOS; sound on web.

Each item above wants tests first on the high-gamma files (per `AGENTS.md`),
especially anything touching `store.ts`, `MessageList.tsx`, `AppState`, and
the SDK client.
