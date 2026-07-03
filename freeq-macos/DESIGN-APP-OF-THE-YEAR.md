# freeq for Mac — App of the Year Plan

**Goal:** make the native macOS app the definitive freeq client — more complete than the web app, built to the standard of the most beloved Mac apps (Things, Mimestream, Fantastical, Ghostty), with AV that leads the industry on the axes we can honestly win.

**Revision:** v4 (final) — after three rounds of external UX critique (R1: 18 findings; R2: 15 findings, all fixes verified REAL in R3; R3: **GO-WITH-CONDITIONS** — conditions C1–C4 incorporated below: §7.6 App Review, Track D visual design, three spec-seam fixes, §7.7 distribution addendum). Matrix rows marked ✎ were corrected after code re-verification.

---

## 1. The Hero: what this app is known for

**One sentence:** freeq for Mac is the room where humans and AI agents work together — calls are ambient presence, not meetings, and agent work is visible, verifiable, and joinable.

No competitor can copy it, because it's the protocol, not the UI: cryptographically verified identity for humans *and* agents, coordination cards rendering live agent tasks, and an ambient call layer you drift in and out of. Slack bolted on huddles; Discord is for gaming; Zoom is a meeting. freeq is *presence you can trust*.

### The 30-second demo (the ADA video; every phase must feed it)
1. Cold launch → instantly inside a live channel (cached history in <400ms, live catch-up seam per §6.9) — teammates chatting, an agent's task card updating live ("⚙ Summarizing today's deploy logs… ✓ Done — verified"), its streaming output pulsing.
2. A teammate's tile glows in the ambient call strip — one click and you're in, no modal, no meeting URL. Their screen share opens in the spotlight; Presenter Overlay keeps their face over the deck.
3. ⌘K → "Hand off: cite three sources on X → @scholar" — a task card posts, marked **Verified — sent by you**. The agent accepts on-card. *(Card authoring is a scheduled deliverable — §6.10.)*
4. Close the window; the call follows as a floating mini panel; the menu bar shows the live timer. You never "joined a meeting."

**Voiceover rule:** zero protocol nouns. Never "DID/AT Protocol/signed TAGMSG" — say "verified," "runs under Chad's account," "can't be forged."

**Demo slice milestone (end of Phase 3):** cards + ambient strip running feature-flagged on the current message list; shoot a rough cut covering beats 1 and 3; its failures become Phase 4/5 requirements. Beats 2 and 4 (Presenter Overlay spotlight, mini panel) depend on Phase 5 — **the full video shoots in the window after Phase 5 exit**, stated here so video production is planned, not a Phase 6 surprise.

**Litmus for every matrix row:** does it feed this demo, protect its reliability, or close a trust-breaking gap? Everything else is Appendix backlog.

---

## 2. Design North Star

1. **Content is calm and opaque; controls float as glass.** Message list is a solid edge-to-edge reading surface; toolbars, call HUD, composer accessories are the Liquid Glass layer.
2. **Every action is one keystroke away and every keystroke is discoverable.** One Command registry drives menu bar, ⌘K palette, tooltips, and App Intents (§9).
3. **Calls are an ambient layer over chat, never a takeover.**

### ADA axes → our answer
| Axis | Our play |
|---|---|
| Innovation | Agent-native chat with verified coordination + native-AV-stack adoption (SCContentSharingPicker, Presenter Overlay, system Reactions, Voice Isolation, Continuity Camera) + App Intents spine |
| Interaction | Keyboard-first, one Command registry, springs/morphs, ambient call surfaces |
| Inclusivity | Full VoiceOver program (from zero labels today — §7.3), Reduce Motion/Transparency, Full Keyboard Access, call captions |
| Visuals | Liquid Glass (macOS 26+ — §7.2, with a real legacy-channel story), concentric radii, Icon Composer icon, SF Symbols 7 |
| Delight | Sound design (§6.6), reaction morphs, jumbomoji, voice messages with transcripts, warm empty states |

---

## 3. Feature Map

```
freeq for Mac
├── Identity & Trust — AT OAuth · guest · step-up auth · three-tier identity (§6.8) · signing · federation "via" · E2EE (channels + DMs) · safety numbers
├── Conversation — channels · DMs · P2P DMs · threads · reactions · pins · edits/deletes/replies · typing · presence
│   ├── Formatting: full markdown · code w/ highlighting · mention pills · jumbomoji · media · voice messages · link previews · embeds
│   └── Agent surface: coordination cards (render + AUTHOR §6.10) · streaming edits · actor classes · provenance chains
├── History & Search — CHATHISTORY · SQLite offline store · read-sync (§6.3, server track) · date dividers · ⌘F local · ⌘⇧F global · Spotlight
├── Calls — six governed surfaces (§6.5) · green-room-only-when-lost (§5.1.4) · active speaker · SCK share + Presenter Overlay · SLOs
├── Governance — policy editor · join gates · credential verifiers · roles · audit timeline · moderation
└── Platform — Command registry → menu bar/⌘K/App Intents/Spotlight/Focus filters/widgets · communication notifications · menu bar extra · multi-window · Handoff · TipKit · sandbox+MAS & Sparkle (Phase 1)
```

---

## 4. Feature Parity Matrix — macOS vs Web

Legend: ✅ complete · ⚠️ partial · ❌ missing · ✎ corrected after re-verification. **Bold** = feeds the hero demo or closes a trust gap. *Full re-audit of every row with file:line evidence is a Phase 0 exit gate — **completed 2026-07-03**: every ✅/⚠️ claim held (nothing overstated); rows marked ✎ below shipped ahead of the matrix and were flipped with fresh evidence.*

### Identity & auth
| Feature | macOS | Web | Notes |
|---|---|---|---|
| AT OAuth via broker | ✅ | ✅ | mac smoother (ASWebAuthenticationSession) |
| Guest mode + upgrade | ✅ | ✅ | three-tier presentation §6.8 |
| Session restore + backoff | ✅ keychain | ✅ localStorage | keychain re-validated under sandbox (§7.1) |
| **Step-up OAuth (upload/cross-post)** | ❌ | ✅ | mac uploads 403 dead-end; port |
| Verified / signed / via badges | ✅ | ✅ | re-styled per §6.8 |
| Safety numbers | ✅ | ✅ | |
| Channel E2EE (`/encrypt` ENC1) | ✅ ✎ (ChannelCrypto.swift, ChannelE2eeState.swift) | ✅ | Rust-interop-pinned; added 2026-07-02 |

### Messaging & formatting
| Feature | macOS | Web | Notes |
|---|---|---|---|
| Inline markdown | ✅ | ✅ | |
| **Full markdown (mime: fences/quotes/lists/tables)** | ❌ | ✅ GFM | agents send these; mac renders mush |
| **Syntax highlighting + copy** | ❌ | ⚠️ | leapfrog |
| Mention pills / jumbomoji | ❌ / ❌ | ❌ / ❌ | leapfrog |
| Edited indicator | ✅ ✎ (MessageListView.swift:391) | ✅ | v1 falsely claimed ❌ |
| Delete tombstone | ✅ ✎ (MessageListView.swift:203 DeletedMessageRow) | ✅ | shipped Phase 0 |
| **Streaming-edit rendering** | ❌ | ✅ | demo-critical; §6.4 notification rules |
| **Date separators** | ✅ ✎ (MessageTimeline.swift; MessageListView.swift:180) | ✅ | shipped Phase 0 |
| **Unread "New" line + read-sync** | ❌ (lastReadMsgId set, never rendered) | ⚠️ local-only in-memory | §6.3 — requires server track S1; **no local-only hack that lies across devices** |
| Input history / ↑-edit / who-reacted | ✅ ✎ ✅ ❌ | ✅ ✅ ✅ | history: ComposeHistory.swift (Phase 0) |
| Threads | ✅ fixed 320pt | ✅ | resizable split + pop-out; breakpoints §6.1 |
| Pins / voice messages / media / embeds | ✅ ✅ ✅ ✅ | ✅ ❌ ✅ ✅ | voice = mac lead |
| Upload / drafts / live composer md | ✅ ❌ ❌ | ✅ ❌ ❌ | drafts + live styling = leapfrog |
| Format toolbar | ✅ ✎ (FormatToolbar.swift:29 wraps live selection) | ✅ | shipped Phase 0 |

### Navigation & search
| Feature | macOS | Web | Notes |
|---|---|---|---|
| ⌘K | ✅ channels only | ✅ | → command palette (registry §9) |
| **Channel browser (real /LIST)** | ❌ fake | ✅ | needs SDK LIST events (R2) |
| Infinite scroll / ⌘F | ⚠️ button / ✅ | ✅ / ✅ | |
| **Global search** | ❌ unwired | ⚠️ memory | SQLite + server FTS5, chips; **E2EE scope rule §6.11** |
| Badge conventions / ⌥ nav / invite links | ⚠️ ✅ ✎ ❌ | ✅ ⚠️ ✅ | ⌥ nav: BufferNavigation.swift + App.swift:84 (Phase 0) |

### Governance & agents (hero surface)
| Feature | macOS | Web | Notes |
|---|---|---|---|
| Policy editor | ✅ (hardcoded defaults) | ✅ | |
| **Join-gate flow** | ⚠️ banner | ✅ | |
| **Audit timeline** | ❌ | ✅ | inspector stack |
| **Coordination cards — render** | ❌ | ✅ render-only | demo-critical |
| **Coordination cards — AUTHOR** | ❌ | ❌ | **neither client has it; §6.10; the demo's key beat** |
| **Agent badges + provenance** | ❌ | ✅ | |
| Moderation / WHOIS | ✅ / ✅ | ✅ / ✅ | ban-list UI needs R2 event |
| **User blocking (client-side)** | ❌ | ❌ | **App Review 1.2 requirement** (§7.6) — hide messages locally + server ignore; leapfrog both clients |
| **Content reporting** | ❌ | ❌ | **App Review 1.2 requirement** (§7.6) — report from message context menu → server/ops queue |

### Presence & notifications
| Feature | macOS | Web | Notes |
|---|---|---|---|
| Typing / presence / away | ✅ | ✅ | self-away visibility fix |
| **Communication notifications** | ⚠️ basic | ⚠️ tab-bound | §6.4; INSendMessageIntent ships with them (Phase 3a) |
| **Per-channel notification levels** | ❌ | ❌ | all/mentions/muted — §6.4 |
| **Focus filters** | ❌ | n/a | mac-only |
| Sounds | ⚠️ stock | ✅ | §6.6 |

### AV
| Feature | macOS | Web | Notes |
|---|---|---|---|
| Core call controls | ✅ | ✅ | |
| Screen share | ✅ SCK + system picker ✎ (ScreenSharePicker.swift; dedicated /screen broadcast) | ✅ | Presenter Overlay still planned |
| Mic processing / metering | ✅ / ✅ self | ⚠️ / ❌ | mac leads |
| **Output device picker** | ✅ ✎ (FFI set_output_device; CallView Speaker menu) | ❌ | mac leads |
| **Remote active-speaker** | ✅ ✎ AvEvent.AudioLevel emitted from the playout sink's smoothed peak (10 Hz, change-gated); speaking rings wired | ❌ | shipped 2026-07-03; multi-party visual check pending |
| **Frame transport** | ⚠️ [UInt8] FFI copies | n/a | §5.0 prerequisite, R2 |
| **Green room (when-lost only)** | ❌ | ❌ | §5.1.4 |
| **Reconnect under SLO** | ❌ dies (Reconnecting/Reconnected FFI events frozen ✎) | ⚠️ | §5.1.3 |
| Mini panel / menu-bar controls / pop-out | ❌ | n/a | §6.5 |
| End-for-all + roster | ❌ | ✅ | |
| System reactions / Voice Isolation / Continuity auto | ❌ | ❌/n/a | mac-only APIs |
| System audio share / AV E2EE / captions | ❌ | ❌ | §5.4 |
| Background blur / custom backgrounds | ✅ ✎ (CameraEffectsProcessor.swift — Vision segmentation) | ❌ | mac leads; added 2026-07-03 |

### Platform
| Feature | macOS | Web | Notes |
|---|---|---|---|
| Theme | ✅ ✎ (App.swift:4 AppearanceSetting system/light/dark) | ✅ | shipped ahead of Phase 1 |
| App Intents / Spotlight / widgets / menu bar extra / multi-window / Handoff / TipKit | ❌ | n/a | §9 |
| Accessibility | ❌ zero labels | ⚠️ | §7.3 program |
| Sandbox / MAS | ❌ off | n/a | Phase 1 |
| Auto-update | ❌ | ✅ toast | **Sparkle in Phase 1** (dogfood depends on it) |
| Offline persistence | ✅ SQLite | ⚠️ | mac edge; catch-up seam §6.9 |
| Multi-account/server readiness | ❌ singleton | ❌ | §6.12 — key by (server, DID) from Phase 1 |
| Hardcoded hosts | ⚠️ ✎ env-configurable, freeq.at default remains (ServerConfig.swift:7) | ✅ | rest folds into §6.12 |

---

## 5. AV Plan

**Honest claim:** the most *native* and most *trustworthy* calling in any chat app — measured reliability, system-stack integration Electron can't match, verified presence. Per-axis claims only where measured (§11).

### 5.0 Prerequisite: frame-transport rearchitecture (R2)
Frames cross UniFFI as copied `[UInt8]` (~250MB/s per 1080p30 participant). Before speaker view/PiP/captions: zero-copy — Rust decodes into IOSurface-backed CVPixelBuffers (or shares IOSurface IDs), Swift renders via AVSampleBufferDisplayLayer/Metal copy-free. **Exit gate: ≤5% CPU per 720p30 tile on M1.** `AvEvent.audioLevel` ships in R1 (interface frozen end of Phase 1 so Swift builds against stubs).

### 5.1 Reliability & feels-alive (before flash)
0. **Session scoping — client-side fixed 2026-07-03; server-side designed.** The SFU relays all sessions through one MoQ namespace and announces every broadcast to every consumer; the native FFI subscribed to all of them, so a client in call A played call B's audio/video (observed live: a #freeq participant received a #chadtest broadcast). Fixed client-side with a `{session-id}/` prefix filter in the FFI announce loop (`belongs_to_session`, unit-tested) — but that only protects patched clients; iOS/older builds still leak. **Durable server-side fix designed** (concrete plan in `freeq-server/src/av_sfu.rs` header): root each connection's moq_relay token at `s/{session_id}` from the dial URL and publish relative to it, so the relay scopes announcements per session for every client regardless of version. Coordinated client+server+iOS change; must re-test native/web interop (the root-path axis that caused the earlier disjoint-namespace bug). S2, own session.
1. **Remote active-speaker** (R1) — speaking ring, roster VU, auto speaker view.
2. **Output device picker** (R1) — route override + chevron.
3. **Reconnect under SLO** — drop → "Reconnecting…" tile + backoff; teardown after N failures. **SLOs: join ≥99%; reconnect <5s at 5% loss; published glass-to-glass latency.** Link Conditioner matrix + CI soak (Phase 3b deliverable).
4. **Green room — only when lost.** Default = instant join + 2s grace chip naming the auto-chosen device ("AirPods Pro · muted — ⌘⇧M"). Pre-flight card only when: first join on this device-configuration, OR previously-used device is *gone and the fallback is ambiguous*, OR ⌥-click. Dock/undock/AirPods reconnect never trigger it. Menu-bar/notification joins never show it.
5. **Roster + host end-for-all** — mute states, per-participant local volume.

### 5.2 Native-stack showcase
6. SCContentSharingPicker + Presenter Overlay (HUD reflects state). 7. System Reactions (+ `+freeq.at/av-react` cross-client). 8. Continuity Camera auto (`systemPreferredCamera`, undo toast). 9. Voice Isolation chip + TipKit hint. 10. Speaker view — dominant tile spring growth, filmstrip, share = content + face rail, per-tile pin.

### 5.3 Ambient layer
11. Mini call panel (NSPanel, trigger per §6.5). 12. MenuBarExtra live call controls. 13. Pop-out call window. 14. Push-to-talk (global shortcut, haptic on hold) + muted-while-talking hint.

### 5.4 Beyond
15. System audio share (SCK). 16. Live captions (SFSpeechRecognizer, local-only). 17. AV E2EE (SFrame-style over MoQ, keyed from DID E2EE sessions). 18. Call-quality HUD (⌥-click).

---

## 6. UX Specifications

### 6.1 Window anatomy & breakpoints
```
┌────────────────────────────────────────────────────────────────────┐
│ ⚫⚫⚫  [glass toolbar: channel · topic · call · search · ⋯]         │
├──────────┬───────────────────────────────┬───────────┬─────────────┤
│ SIDEBAR  │ MESSAGE LIST (opaque,         │ THREAD    │ INSPECTOR   │
│ (glass)  │  edge-to-edge, scroll-edge)   │ (split,   │ (nav stack) │
│ …        │  date divider · New line      │  pop-out) │ members→    │
│ 🎧 call  │  grouped rows · hover pill    │           │ profile ·   │
│ footer   │  cards · pills · reactions    │           │ pins · audit│
│ (global  ├───────────────────────────────┤           │             │
│  call    │ [typing] [composer]           │           │             │
│  surface)│                               │           │             │
└──────────┴───────────────────────────────┴───────────┴─────────────┘
```
**Breakpoints (calm > chrome):** thread and inspector never both open below 1200pt content width — opening one auto-collapses the other (reopens on close). Below 900pt the thread takes over the list (push, with back). Default state is list-only; panels are summoned, not resident. Density stays readable on a 13" MacBook — verified in the UI sweep at 1280×800.

### 6.2 Inspector & threads
Inspector = read-only context nav stack (Members → push Profile → back; Pins; Audit). Never holds composition state. Threads = dedicated resizable split (min 280pt, remembered) with pop-out; thread drafts survive inspector navigation, channel switch, restart. Who-reacted = popover on the chip.

### 6.3 Unread & read-state (multi-device) — **requires track S1**
- **Server-synced read markers**: IRCv3 `draft/read-marker` implemented in freeq-server + SDKs + web + iOS (track S1, owners in §10). Verified reality today: server has zero read-marker code; web is local-only in-memory. The Mac feature ships *with* S1 — **we do not ship a local-only New line that lies across devices.** Fallback when a server lacks the cap: local-only, visually identical.
- **Merge rule:** marker = max(msgid) by ULID ordering, monotonic; concurrent devices converge on max. **On connect: merge by max — push local if greater, adopt server if greater.** (Never server-wins: reading offline on a plane must not resurrect 150 read messages.)
- **Guests** (no DID to key markers to): read state is local-per-install, visually identical.
- **"Read" =** channel frontmost + window key + row rendered ≥1s, or explicit mark-read (Esc / context menu).
- **Mid-view rule:** badge clears immediately on marker advance (any device); the rendered New line *freezes in place* until the channel loses focus (Slack rule), then never reappears for that position.
- **Badges:** bold = unread; numeric = mentions/DMs only; muted = neither. Per-channel levels: **all / mentions (default) / muted** (§6.4).

### 6.4 Notification spec
Stated platform decision: **all notifications are local — the app must be running and connected; the menu bar extra is the resident keep-alive; no APNs at launch.** (Revisit only with an iOS companion.) The keep-alive is a real setting, not an accident: **SMAppService launch-at-login toggle** (default on, primed at first-run step 3 with plain words), and ⌘Q semantics stated in the quit confirm: "Quitting freeq stops notifications."

| Case | Behavior |
|---|---|
| **Self-echo (own message from another device)** | never badges, sounds, or notifies |
| Mention, app frontmost, channel visible | row highlight + subtle sound; no banner |
| Mention, app frontmost, other channel | badge + sound |
| Mention/DM, backgrounded | communication notification (avatar, conversation-grouped, inline reply + mark-read) |
| Channel set to "all activity" | every message as above; grouped per conversation |
| Read elsewhere (S1 marker) | withdraw delivered notifications *(inactive until S1 lands — explicitly)* |
| Streaming agent message | one notification at start; edits never re-notify; mid-edit mention notifies once |
| Thread reply | participants + explicit followers only |
| Incoming call | **exempt from all suppression** — surfaces via in-app path (call HUD chip + menu-bar pulse + ring sound), never a banner that can be queued; breaks Focus only via allowed-people |
| Muted channel | nothing, incl. mentions; DM from same person still notifies |
| **While screen sharing (SCK share active)** | message banners suppressed for this app (privacy — banners render into the shared screen); queued, delivered on share end. Calls exempt per the incoming-call row |
| E2EE message | banner shows sender + "Encrypted message" — never decrypted content in notification storage |

INSendMessageIntent donation ships **with** communication notifications (Phase 3a) — same work item.

### 6.5 Call-surface state machine
One `CallSession`; **six surfaces are projections**: (1) inline strip — *channel-local*, only in the call's channel; (2) expanded grid — same locality; (3) **sidebar call footer — the global surface**, always visible while in a call, whatever channel you're viewing; (4) pop-out window; (5) mini panel; (6) MenuBarExtra controls (auto-context: call controls during a call, unread glance otherwise — no user-facing mode toggle).

Transitions:
- **Channel switch during call:** strip/grid stay in the call's channel; the sidebar footer (leave/mute + channel name, click = return) carries the call globally. Nothing follows you into other channels' content areas.
- Strip ⇄ grid: user toggle, remembered per channel.
- **Mini panel trigger:** appears when *no visible surface hosts the call* — main window occluded/minimized/⌘W'd/other-space AND no pop-out visible. Dissolves back when any hosting surface reappears (glassEffectID morph).
- Pop-out open → main-window surfaces collapse to a "in call · 12:33" pill; closing the pop-out returns the call to the main window **if one is visible; with no main window, it hands off to the mini panel** (closing a small window must never conjure a big one). Never leaves the call.
- **Second call while in a call:** an *in-app* surface (call-footer banner + HUD chip — explicitly not a UserNotification, so §6.4 suppression can never eat it) with explicit Switch (leaves current, with confirm) or Dismiss. Never auto-hold, never two concurrent calls.
- Leave only via explicit control (HUD/footer/mini/menu bar/⌘⇧H). Quit with active call → confirm.
- Green room, when triggered, replaces the join affordance in place (inline card, not a sheet) — including its menu-bar-join variant (menu bar joins are always instant; §5.1.4).

### 6.6 Sound & haptics
Commissioned 6-sound set (stock system sounds only as interim): message-in (message vs mention pitches), send tick, call join/leave chirps, reaction pop, ring (loopable, Focus-aware), PTT engage/release. Haptics: **PTT hold only** (force-trackpad gimmick threshold respected). Gates: system settings, per-channel levels, "sounds only when backgrounded" toggle. Dock bounce: never for messages, once for direct calls.

### 6.7 First-run (60 seconds)
1. ConnectScreen: live server stats, two clear paths (guest = one field; OAuth = handle + domain autocomplete).
2. First connect lands in #freeq — live because its resident agents do *real* production jobs (deploy watches, CI summaries, log digests). **Demo activity is real work, or it's out** (§12).
3. Permission priming: notifications after first mention (with pre-prompt); mic/cam at first call join; never at launch.
4. Guest: quiet persistent upgrade affordance; TipKit contextual discovery; no deck.

### 6.8 Three-tier identity presentation
The room is mostly guests; absence of a badge must not read as a warning label.
- **Verified human** — subtle ✓ tint on name; popover: "Verified — @handle, can't be forged."
- **Verified agent** — ⚙ chip + "runs under @owner" one-liner; provenance chain one click deep; presence states (executing/idle/blocked).
- **Guest** — neutral-warm: plain name, no deficit iconography, popover: "Guest — identity not verified. Anyone can use this name." Upgrade affordance lives in *your own* footer, not on other people's names.
Badges reward verification; they never shame its absence. Federated "via server" chip stays (different trust statement).

### 6.9 Cold-launch catch-up seam
<400ms paint is *cached* SQLite history; live socket + SASL + CHATHISTORY catch-up takes seconds. Spec: cached rows render immediately at full fidelity; a hairline progress glow under the toolbar (not a spinner, not skeletons over real content) until caught up; new rows append without scroll jumps (anchor preserved); the New line positions only after catch-up completes. Never block input on catch-up — sends queue.

### 6.10 Task handoff authoring (the demo's key beat — neither client has it today)
- ⌘K parameterized command: "Hand off…" → title → assignee (agent-entity autocomplete: @scholar ⚙, capability chips) → optional deadline/context blob.
- Composer path: `/handoff @scholar Cite three sources on X`.
- Posts a `task_request` coordination card (existing `+freeq.at/event` schema), signed like any message; card shows **Verified — sent by you**; accept/complete render on-card live (web already renders these).
- Card states: requested → accepted → running (streaming updates) → done/failed; failures show reason + retry affordance for the requester.

### 6.11 E2EE boundaries (stated, not silent)
- Global search: server FTS covers plaintext channels only; E2EE channels/DMs search **device-local SQLite only**; results are merged with a scope label ("local · encrypted"); the client never sends E2EE-channel queries to the server.
- Notifications for E2EE content per §6.4 (no decrypted content at rest in notification storage).
- AV E2EE per §5.4; until shipped, call UI never displays a lock.

### 6.12 Multi-account readiness
Launch scope: one active account. But from Phase 1, AppState/SQLite/keychain are keyed by (server, DID) so multi-server/multi-account is a feature later, not a rewrite. (Self-hosting + irc.freeq.at is the first power-user config; hardcoded-host fixes in Phase 0 are step zero of this.)

---

## 7. Quality Gates

### 7.1 Sandbox + distribution first (Phase 1)
Sandbox on before the redesign: keychain accessibility re-validation, SQLite container migration (+ migration test), iroh `network.server`, SCK/drag-drop deltas, MAS target without Sparkle. **Sparkle 2 (sandboxed, XPC) ships in Phase 1 too — the dogfood channel depends on it.** CI build matrix: {MAS, Direct} × {debug, release}.

### 7.2 Minimum OS: macOS 26 — with an operational story
New app targets macOS 26+. Legacy channel: Phase 0 honesty fixes ship to the current app, then it **freezes** with an in-app EOL notice and date. One Sparkle appcast using `sparkle:minimumSystemVersion` serves both. Support matrix published. MAS serves pre-26 users the last compatible version only if previously downloaded — stated plainly on the site. Revisit only if dogfood data shows meaningful pre-26 demand.

### 7.3 Accessibility program (from zero)
Labels/hints as views are touched (PR gate); rows read "Sender, time, message, N reactions"; unread/mentions rotor; polite live announcements; Full Keyboard Access per surface; Reduce Motion/Transparency/Increase Contrast per phase; text scaling; captions (§5.4). ~15% of every phase + a VoiceOver hardening week before submission.

### 7.4 Localization
String Catalogs as views are converted (Phase 1+; Phase 0 exempt). Launch English; RTL smoke in Phase 2 sweep; locales Phase 7.

### 7.5 Performance budgets
Cold launch <400ms to cached content; hitch rate <1% on the §11 harness; call CPU per §5.0 gate. MetricKit + os_signpost from Phase 1. **Receipts are our own numbers** (launch, hitch, CPU per release) — no competitor-comparison benchmarketing; reviewers can run the comparisons.

### 7.6 App Review readiness (workstream from Phase 1 — not a Phase 6 bullet)
A chat client on an open network with user-generated content hits Guideline 1.2 head-on. Requirements, scheduled so a rejection can't land inside the award window:
- **User blocking** (client-side hide + server-side ignore) and **content reporting** (message context menu → report → ops queue with audit trail) — built in Phase 4 with the hero surface (matrix rows above); they're also just good product.
- Content filtering mechanism + published support contact (site + app).
- **Guideline 4.8 assessment written down in Phase 1**: AT Protocol OAuth is a decentralized identity protocol, not a third-party social login; guest mode provides the no-account path. Pre-check with App Review via App Store Connect if possible; do not improvise this argument in a rejection appeal.
- **Export compliance for E2EE** (encryption declaration, French declaration) prepared in Phase 1; privacy nutrition labels + privacy policy drafted with the §6.4/§6.11 decisions as source of truth.

### 7.7 Being noticed (distribution addendum — due before Phase 4)
This document is the product plan; awards are Apple-editorial. A one-page companion addendum is due before Phase 4 exit, covering: **pricing** (also gates the MAS listing — current lean: free client for an open network, no IAP at launch), **launch timing** against the ~November App Store Awards cycle (full video shoots after Phase 5 → public launch lands with margin before the cycle), **App Store product page** (screenshots/preview video from the demo material), **feature-pitch via App Store Connect** promotional submission, and the user-growth story beyond the dogfood cohort (irc.freeq.at community, self-hosters, agent-platform developers). Thin is acceptable; absent is not.

---

## 8. Formatting Perfection Checklist
1. Full markdown for `mime=text/markdown` (blocks/tables/quotes/fences), golden-file tests. 2. Code fences: SF Mono 88%, secondary fill, concentric radius, language label, hover copy, h-scroll, real highlighting. 3. Mention pills + self-mention row tint. 4. Jumbomoji ≤3 → 2.5×. 5. Timestamps: tabular figures, tertiary, relative + hover-absolute, date separators, viewer-local. 6. Delete tombstone. 7. Streaming edits per §6.4, reader-respecting scroll pinning. 8. LPLinkView-style cards, first link, sender-removable. 9. Composer: live token styling, fixed selection wrap, per-channel drafts + sidebar dot. 10. System palette + full-index `:query` autocomplete. 11. Quieter system lines; collapsed join/part groups. 12. Harness stress: RTL, 10k-line fence, 500 reactions, zalgo, unbroken strings.

---

## 9. Command Registry & Platform Spine
Phase 1: Command registry — one definition (name/icon/shortcut/availability/handler) projecting into menu bar (complete → Help search free), ⌘K palette (fuzzy, frecency, parameterized — §6.10 uses this), context menus, tooltips. Phase 6 projects it into App Intents: Send/JoinCall/ToggleMute/SetStatus/Search/OpenConversation (+ `IndexedEntity` channels/people; message indexing opt-in), `SetFocusFilterIntent`, AppShortcutsProvider, Spotlight actions + Quick Keys. Universal links + Handoff per conversation/call. Widgets: unread summary, pinned conversation. Menu bar extra per §6.5(6).

---

## 10. Roadmap — four tracks

**Track D (visual design; named owner required before Phase 1 exits — engineering gates alone cannot win the Visuals axis):**
- D1 (exit-gate for Phase 2): key-screen mockups — message list, coordination cards, call strip/grid, three-tier identity, ConnectScreen — the visual target the list rewrite builds against; the "UI sweep" gate sweeps against these, not vibes.
- D2 (commissioned with dates + budget line at Phase 1 exit): Icon Composer icon (all six variants) and the §6.6 six-sound set.
- D3 (Phase 5): Liquid Glass surface audit against the mockups; final icon/sound integration.

**Track S (server/SDK; owner: server team):**
- S1 (needed by Phase 3a): `draft/read-marker` in freeq-server + SDK + **web + iOS adoption** (read-sync is a network feature or it is nothing).
- S2: FTS search API hardening for §6.11 scope rules; audit/pins REST already exist.

**Track R (Rust core; owner: SDK team; FFI interfaces frozen end of Phase 1):**
- R1 (needed by 3b): `AvEvent.audioLevel`, reconnect events, output-route API.
- R2 (needed by 5): zero-copy frames (§5.0), LIST replies, ban-list events.
- R3: AV E2EE, SCK system-audio.

**Track A (app):**
- **Phase 0 — Honesty (1 wk):** toolbar wrap · hardcoded hosts · matrix re-audit (exit gate) · tombstone · date separators · self-away · ⌥ nav · input history. Ships to legacy channel too, which then freezes (§7.2).
- **Phase 1 — Foundations (3–4 wks):** sandbox + build matrix + **Sparkle channel live** · system appearance + semantic colors · **message-list spike + hitch harness (exit gate: LazyVStack vs NSTableView/NSCollectionView decision)** · Command registry + complete menus + palette · MetricKit/signposts · (server, DID) keying (§6.12) · String Catalogs begin · a11y PR gate on · R/S interface freeze · **App Review workstream opens (§7.6: 4.8 assessment written, export compliance, privacy labels)** · Track D owner named + D2 commissioned.
- **Phase 2 — Formatting & list (3–4 wks):** list rewrite if spike says · §8 · golden files · RTL smoke · **dogfood cohort starts — recruited from existing irc.freeq.at web/iOS users so channels are alive cross-client.**
- **Phase 3a — Read-sync & notifications (2–3 wks, needs S1, no R1):** §6.3 + §6.4 + communication notifications + INSendMessageIntent + per-channel levels.
- **Phase 3b — AV reliability (3–4 wks, needs R1):** §5.1 · SLO rig + CI soak. *(3a and 3b run in parallel if S1/R1 land as scheduled; either proceeds alone if the other track slips.)*
- **→ Demo slice milestone:** cards + strip feature-flagged; rough-cut video; failures feed 4/5.
- **Phase 4 — Hero surface (3–4 wks):** coordination cards render + **authoring (§6.10)** · streaming edits · identity presentation (§6.8) · provenance · join-gate flow · audit timeline · step-up OAuth · global search (§6.11) · who-reacted · real channel browser (R2 LIST) · **blocking + reporting (§7.6)** · distribution addendum (§7.7) due at exit.
- **Phase 5 — Native AV + Liquid Glass (4–5 wks, needs R2):** §5.2 + §5.3 (§6.5 machine) · glass adoption · icon · SF Symbols 7 · sound palette v1 · mini panel/pop-out/menu-bar.
- **Phase 6 — Platform spine (2–3 wks):** App Intents projection · Spotlight · Focus filters · universal links/Handoff · widgets · TipKit · MAS submission.
- **Phase 7 — Beyond:** captions · system audio · AV E2EE · quality HUD · locales · custom sections · multi-file upload.

Phase exits: model tests · hitch harness · VoiceOver pass · UI sweep (incl. 1280×800) · dogfood review · end-to-end drive. Realistic total: ~6 months with all three tracks staffed; the schedule survives a single-track slip (3a/3b decoupling), not a two-track slip.

---

## 11. Instrumentation & Validation
MetricKit + signposts + crash-reporting decision (privacy/sandbox-compatible) Phase 1 · hitch harness in CI (10k messages, media, streaming storm) · AV rig (loss/jitter/bandwidth matrix; join-success + reconnect-time per build; cross-client harness extended for speaker events/reactions) · dogfood cohort per Phase 2 note · perf receipts per §7.5.

## 12. What we deliberately do NOT do
No custom fonts · no glass on content · no bubbles · no onboarding deck · no features missing perf/a11y gates · no hiding the channel list behind modes · no competitor benchmarketing · **no fake UI, claims, or activity** — matrix rows carry file:line evidence; #freeq's agents do real production work or they're removed from the first-run path; "industry standard" is asserted per-axis only where measured.

## Appendix — Backlog
Login server stats · hover-shows-original edit history · sidebar custom sections · forwarding · scheduled send · reminders · per-channel keywords · Desk View · SharePlay · iOS Handoff continuity · APNs (with iOS companion) · multi-account UI.
