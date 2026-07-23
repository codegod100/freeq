# AV Multi-User Test Plan — the launch gate

**Companion to `docs/AV-SESSION-AUDIT.md`** (read it first: it explains the two
subscription models — roster-driven web vs. announcement-driven native — and
the confirmed failure classes A/B/C every test below targets).

**Definition of done:** every cell in §2 passes, every scenario in §5 passes,
and the automated layers in §3–4 are green in CI. Until then, no launch.

---

## 1. Invariants under test

For every pair of participants (X, Y) in a call, after ≤ 5 s of settling:

- **I1 — hear:** X hears Y when Y speaks unmuted, and vice versa (no one-way pairs).
- **I2 — see-roster:** X's participant UI lists exactly the live participants.
- **I3 — see-video:** if Y's camera is on, X renders Y's tile (and screen share likewise).
- **I4 — leave:** when Y leaves/crashes, X stops hearing Y and Y's tile drops within grace+5 s.
- **I5 — one-session:** all participants who believe they're "in the channel's call" are in the **same** session id.
- **I6 — self:** X never subscribes to its own broadcast (no self-echo).

A failure of I1/I3 in exactly one direction is class A (roster/announce
divergence); a failure of I5 is class B; a failure of I4 is class C.

## 2. Client-pair matrix

Clients: **web** (Chrome + Safari), **macOS**, **iOS**, **Windows**, **bot**
(freeq-av agent). For each unordered pair (including same-type pairs), verify
I1–I6 in a 2-party call, then in a 3-party call with a third client of a
*different* type:

| | web | macOS | iOS | Windows | bot |
|---|---|---|---|---|---|
| **web** | ☐ | ☐ | ☐ | ☐ | ☐ |
| **macOS** | | ☐ | ☐ | ☐ | ☐ |
| **iOS** | | | ☐ | ☐ | ☐ |
| **Windows** | | | | ☐ | ☐ |
| **bot** | | | | | ☐ |

Pay special attention to mixed pairs: the two subscription models only
disagree when a roster entry goes stale, so every §5 scenario must be run at
least once with a web client AND a native client observing the same event.

Codec sub-matrix (I3): web publishes H.264 (`avc1`); native publishes H.264;
browser screen-share may negotiate AV1 → verify Windows (no HW AV1 decode
path; software rav1d) and iOS (AV1 feature just enabled) both render it.

## 3. Automated: server layer (exists — extend)

Unit tests in `freeq-server/src/av.rs` + `connection/messaging.rs` (run in CI
via `cargo test -p freeq-server`):

- ✅ `should_auto_end_policy` — live calls never age-ended (F1).
- ✅ `reap_orphan_slots_spares_grace_pending_instances` (F2).
- ✅ reaper live-set / multi-device / rejoin-in-place suite (pre-existing).
- ✅ e2e: join rejection emits `+freeq.at/av-error=join-failed` + av-id
  (`tests/av_error_signal.rs`, real server + real SDK client).
- ✅ e2e: start collision emits `start-collision` naming the winning session
  (`tests/av_error_signal.rs`).
- ✅ sweeper policy is the pure `should_auto_end` (unit-tested); the
  grace-pending path is pinned by the reaper test above.

## 4. Automated: client layers (exists — extend)

- **JS SDK** (`freeq-sdk-js`, vitest): ✅ `avError` parse (3 tests).
- **web** (`freeq-app`, vitest): ✅ `av-mesh.test.ts` mesh reachability +
  self-echo edge (F8, 3 cases); ✅ `client-av.test.ts` avError dispatch
  (join-failed teardown, start-collision convergence, wrong-session no-op)
  + the 4 rotted `startAvSession` tests resurrected (injectable poll pacing).
- **macOS** (`swift test`): ✅ `AvStartRaceTests` (4) + `AvErrorResolutionTests` (6).
- **iOS** (`xcodebuild test`, scheme now includes freeqTests): ✅
  `AvStartRaceTests` (10) incl. concurrent-start convergence; 100 tests green.
  **iOS tests must stay in CI — this bundle had rotted unrunnable, which is
  how the start-race divergence survived.**
- **bot/e2e** (`freeq-av-client/examples/*_e2e.rs`): audio flow e2e exists;
  ☐ TODO wire into CI against a local server (`sfu_only_test`, `audio_e2e`).

## 5. Scenario suite (manual until scripted; each maps to a finding)

Run each with: 1 web + 1 macOS + 1 iOS in #test unless stated. "✓" = all
invariants I1–I6 hold afterward.

### 5.1 Long call (F1) — REGRESSION GATE
Start a call; keep 2+ participants in it **> 2 h 10 m** (or temporarily lower
the threshold in a test build). ✓ the session survives; nobody is ejected; no
`ended` broadcast. Then all leave → session ends within one cleanup tick.

### 5.2 Blip + joiner (F2)
A (native) in call. Kill A's IRC connection only (e.g. `pfctl` block port 6667
/ toggle Wi-Fi briefly) while its media WS lives. Within the 30 s grace, B
(web) **joins** the call. ✓ A keeps its roster slot (web still hears A);
A rejoins IRC and the call continues. Repeat with A = web (tab network
throttle) and observer = macOS.

### 5.3 Join a dead session (F3)
A starts a call solo, waits for the session to end (leave from a second
device or `/av end`), then — with the stale session id cached — av-joins it
(easiest: two devices, end from one while the other backgrounds, then
foreground the other and hit join). ✓ the joining client receives
`av-error=join-failed`, tears down, re-discovers, and lands in a *new/real*
session — never a silent ghost. Verify on macOS, iOS, web.

### 5.4 Mid-call rename (F5)
A (web) + B (web) + C (macOS) in call. Rename A mid-call (`/nick`), or force
the dot-strip path by reconnecting a custom-domain identity. ✓ within ~2 s B
still hears/sees A (roster followed the republish); C unaffected throughout.

### 5.5 Concurrent start (F4)
A (macOS) and B (iOS) hit "join" within < 1 s of each other in a channel with
no call. ✓ exactly one session exists; both are in it (loser converged via
`av-error=start-collision` or `started` convergence); a web observer joining
third sees both.

### 5.6 Server restart mid-call (F1×F3 chain from production)
3-party call; `systemctl restart freeq-server`. All clients auto-reconnect.
✓ within grace+rejoin, everyone is back in ONE session hearing each other
(rejoin-in-place), or — if the session was lost — every client lands in the
same new session. No client left ghost-publishing into the old id.

### 5.7 IRC-dead / media-alive (F6 — HARD requirement, revocation shipped)
A (native) in call; block A's IRC for > 35 s (grace expiry) with media alive.
✓ at grace expiry the server closes A's media connection (`SFU: session
revoked` in the log): native peers stop hearing A within seconds of the
roster drop — web and native now converge. A's own client tears down and can
rejoin fresh.

### 5.8 Same account, two devices
One DID joins from macOS and iOS (different instances). ✓ each device is a
separate tile for others; the two devices hear each other; leaving on one
doesn't tear down the other.

### 5.9 Same nick, two people (guest collision)
Guest "chad" (web) + authed "chad" (macOS). ✓ neither client disowns the
other (instance/DID-based self-check); both are heard by a third.

### 5.10 Mute/camera/screen churn
Rapidly toggle mute ×5, camera ×5, screen share on/off ×3 on each client in a
3-party call. ✓ final state correct everywhere; no stuck "muted-but-heard" or
black tiles; peers' track events converge.

### 5.11 Token flip rehearsal (F7 — ordering shipped; rehearse before the flag)
On a staging server set `FREEQ_AV_REQUIRE_TOKEN=1`. Natives now dial
join → token → dial with `?jwt=…&inst=…` (2 s tokenless fallback for
token-less servers); web re-dials on token arrival. ✓ all clients complete
calls with enforcement ON. Run this rehearsal once on staging before setting
the flag in production — it is expected to pass now.

### 5.12 Scale/layout
1 → 5 → 10 → 30 participants (script bots via `freeq-av-client`). ✓ audio
mesh holds (spot-check pairs), roster correct, and layout remains usable
(backlog: web auto-layout, click-to-focus).

## 6. Diagnostic tooling (build as needed)

- ✅ `cargo run -p freeq-sdk --example av_live_probe` — one-shot LIVE probe
  against production (guest connect → dead-session join → asserts
  `av-error=join-failed` → real av-start → asserts `started` + `av-token` →
  clean `av-end`). Run after every server deploy; exits non-zero on failure.
- `freeq-av-client` bot flag `--assert-hears=<nick>`: subscribe, verify
  non-silent audio frames from a named peer within N s, exit non-zero
  otherwise — turns any §5 scenario into a scriptable check.
- Server: `GET /api/v1/sessions/{id}` already exposes the roster; add
  `?debug=1` to include announced-broadcast paths from the SFU so class-A
  divergence (roster ≠ announcements) is visible in one request.
- Client logging: all clients log their computed subscribe set on every
  roster/announce change (`[call] poll:` on web; `AV: participant broadcast`
  in FFI) — capture these in every manual run.

## 7. Standing rule

Any new AV bug gets: (1) a root-cause entry in `AV-SESSION-AUDIT.md`, (2) a
unit test at the layer that owns the decision, (3) a scenario row here if it
implicates cross-client behavior.
