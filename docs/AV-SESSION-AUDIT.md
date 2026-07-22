# AV Session Deep-Dive Audit — "some can hear each other and some can't"

**Date:** 2026-07-22 · **Status:** fixes for F1–F5 shipped; F6–F9 documented + in test plan
**Symptom under investigation:** multiple people join a call; hearing/seeing is
split in *random directions*, and which client you're on seems to matter.

---

## 1. Why splits are even possible: two sources of truth

The single most important architectural fact found by this audit:

| Client | How it decides whom to subscribe to |
|---|---|
| **web** | **Roster-driven.** Polls `GET /api/v1/sessions/{id}` (1.2 s + on av-state change) and computes each peer's MoQ path `{session}/{nick}~{instance}` from the roster (`av-mesh.ts`). |
| **macOS / iOS / bots** | **Announcement-driven.** Subscribes to whatever broadcasts the SFU *announces*, filtered by `{session}/` prefix (`freeq-sdk-ffi/src/lib.rs: watch_announcements`). Never reads the roster. |

Any disagreement between *the roster* and *what is actually announced on the
SFU* therefore splits the call **asymmetrically**: native clients keep hearing
everyone (they follow the wire), web clients silently lose whoever the roster
misdescribes. That is precisely the reported symptom, including its apparent
randomness (it depends on *whose* roster entry went stale) and its client
dependence.

Every finding below is an instance of one of these three classes:

- **(A)** roster diverges from announcements → web-side one-way loss
- **(B)** session-identity diverges (participants end up in *different sessions*
  while one UI shows one call) → mutual pairwise silence
- **(C)** media lifecycle diverges from IRC lifecycle (media lives while IRC
  state dies, or vice versa)

---

## 1.5 Production evidence (Jul 21, #test) — diagnosis confirmed

From `journalctl -u freeq-server` on irc.freeq.at:

```
19:00:46  AV session created 01KY30TK… channel=#test (eve)
19:56:10  nandi.uk joined (inst 09ed413c)
20:03:58  eve joined (inst 2d3a7b14)
20:22:17  chadfowler.com joined (inst c0696925)
20:29:10  chadfowler.com re-joined (NEW inst a15ec406) … left 3 s later
20:38:28  chadfowler.com re-joined (NEW inst 59d3ae5d) … left 5 s later
20:57:16  Guest54100 joined
20:57:31  chadfowler.com re-joined (NEW inst 2f4caaad) … left 5 s later
21:04:25  "Auto-ended 1 stale AV sessions"        ← F1: 2h03m force-end,
          nandi.uk + eve + Guest54100 STILL ACTIVE (no left events before this)
22:15:33  av-join rejected … "Session 01KY30TK… not found"  ← F3: nandi.uk's
          client joins the dead session, gets only a NOTICE, ghosts
```

The 5-second join→leave→retry cycles from chadfowler.com are the human
signature of the split ("joined, heard nothing, left, tried again"). The
force-end of a live call (F1) plus the invisible join failure (F3) reproduce
the reported symptom exactly, and "Auto-ended stale AV sessions" fired 3×
in the last 14 days.

---

## 2. Findings

### F1 — CRITICAL (fixed): live calls force-ended at 2 h ⇒ class B
`server.rs` cleanup task (5-minute tick) auto-ended **any session older than
2 hours, even with active participants**. Everyone in a long-running call gets
`av-state=ended`; clients that see it tear down and later restart a **new**
session; any client that misses the TAGMSG (mid-blip, backgrounded) keeps
publishing into the **dead** session. Unscoped SFU + client-side
`belongs_to_session` prefix filtering means the ghosts and the new session's
members silently exclude each other → random pairwise deafness, biased by
client type and who rejoined first.

**Fix:** `av::should_auto_end` (unit-tested). A session with active
participants is *never* age-ended while any participant's instance is claimed
by a live IRC connection; the age arm only reaps resurrected ghost sessions
(e.g. reloaded after a server restart whose owners never returned).

### F2 — CRITICAL (fixed): join-time roster reaper bypassed the grace window ⇒ class A
`reap_orphan_slots` runs on **every av-join** and marked "left" any roster slot
whose instance wasn't claimed by a live IRC connection **right now** — including
participants inside the 30 s disconnect grace (IRC blipped; their MoQ media —
a *separate* connection — still flowing; rejoin imminent). The moment anyone
joined the call, a blipped participant vanished from the roster: web clients
dropped their tiles/audio, natives kept hearing them.

**Fix:** new `av_grace_pending` set in `SharedState`; disconnects register
their AV instances before the grace timer, the timer clears them, and the
reaper skips any slot whose instance is grace-pending (unit-tested:
`reap_orphan_slots_spares_grace_pending_instances`).

### F3 — CRITICAL (fixed): AV failures were invisible to code ⇒ class B, C
A rejected `av-join` (session ended / full) or a lost `av-start` race came back
only as a **human NOTICE**. But every client sets up its call state (and macOS
dials the SFU and starts publishing) *before* the join round-trips. Result: a
client whose join failed kept its in-call UI and its media, but was never in
the roster — in the call per its own screen, silent/invisible to web peers,
possibly parked in a dead session entirely.

**Fix:**
- Server now also sends a **machine-readable TAGMSG**:
  `@+freeq.at/av-error=<code>;+freeq.at/av-id=<sid>;+freeq.at/av-reason=<text>`
  with codes `join-failed` and `start-collision` (the latter names the
  **winning** session).
- JS SDK emits `avError`; web tears down ghost call state on `join-failed`
  and converges onto the winner on `start-collision`.
- macOS/iOS: pure `resolveAvError` (unit-tested on both platforms) →
  `teardownAndRediscover` / `joinSession(winner)`.

### F4 — HIGH (fixed): iOS concurrent-start race (loser wedged) ⇒ class B
iOS only auto-joined when `av-state=started` had `actor == self`. The loser of
a simultaneous start (still pending, seeing the *winner's* nick) stayed wedged
outside the call. macOS fixed this earlier via `resolveAvStarted`; iOS now uses
the same unit-tested resolver ("if we were trying to start this channel's call
at all, converge on whatever session won").

### F5 — HIGH (fixed): mid-call rename orphans the web publisher ⇒ class A
The server can force-rename mid-call (custom-domain dot-strip on reconnect) or
the user can `/nick`. Web re-publishes under `{session}/{newNick}~{instance}`
(needed so instance-keyed peers can re-associate) — but **nothing updated the
roster**, so every roster-driven subscriber kept watching the old path forever.

**Fix:** after the rename republish, web re-sends `av-join` with the *same*
instance; `join_session` rejoins the slot in place and updates its nick, so the
roster follows the wire within one poll. (Native publishers never republish on
rename and never need this.)

### F6 — MEDIUM (documented, not yet fixed): IRC-dead / media-alive ghosts ⇒ class C
If a participant's IRC connection dies for > 30 s (grace expiry) but their MoQ
connection survives, the server marks them left: web drops them, natives keep
hearing them (the broadcast is still announced). Nothing revokes the media.
Symmetric inverse: SFU connect fails silently → roster lists a participant
nobody can hear ("silent tile").
**Direction:** enforce roster⇔media symmetry at the SFU — on roster-leave,
revoke the session's token / disconnect the broadcast (needs S2 scoped sessions
+ token enforcement). Until then this is a known, testable asymmetry.

### F7 — MEDIUM (landmine, documented): natives never dial with the AV token
`send_av_token` delivers `+freeq.at/av-token` after av-join; web appends
`?jwt=` and even re-dials when the token lands. macOS/iOS ignore the token
**and** dial before joining. The day `FREEQ_AV_REQUIRE_TOKEN=1` is set, every
native call breaks. Native must: join → await token → dial (or re-dial on
token arrival like web).

### F8 — LOW (documented): web self-subscription echo edge
`isSelf` (av-mesh.ts) keys on instance; if *our own* roster row lost its
instance (av-join tag stripped/legacy), rule 1 fails and we subscribe to our
own broadcast → self-echo. Roster rows without instances also collide at the
publish path. Covered in the test plan (matrix row "legacy/no-instance").

### F9 — LOW (documented): `av-state` fan-out requires channel presence
Roster changes reach clients as channel TAGMSGs; a client not currently joined
to the IRC channel (blip, slow rejoin) misses joined/left/ended transitions.
Web self-heals via the 1.2 s poll; macOS/iOS have no poll — they rely on
announcements for *media* (fine) but their participant strip can go stale.

---

## 3. Temporal-coupling map (who assumes what, when)

```
startCall (macOS/iOS):
  FreeqAv(dial SFU, publish)      ← t0   assumes join will succeed (F3: now handled by av-error)
  send av-join                    ← t1
  av-token arrives                ← t2   ignored by natives (F7)
  roster updated                  ← t1'  web sees us only after this

web joinAvSession:
  send av-join → build publisher (tokenless) → token TAGMSG → re-dial
  roster poll (1.2 s) drives subscriptions — correctness depends on roster
  freshness (F1/F2/F5 all broke this)

server:
  av-join → reap_orphan_slots (now grace-aware) → join_session → broadcast
  disconnect → 30 s grace (av_grace_pending) → leave + av-state=left
  cleanup 5-min tick → should_auto_end (now never ends live calls)
```

## 4. What shipped in this pass

| Change | Where | Tests |
|---|---|---|
| `should_auto_end` policy | `freeq-server/src/av.rs`, cleanup in `server.rs` | `should_auto_end_policy` |
| Grace-aware reaper | `av.rs`, `connection/mod.rs`, `server.rs` (`av_grace_pending`) | `reap_orphan_slots_spares_grace_pending_instances` |
| `+freeq.at/av-error` | `connection/messaging.rs` (`send_av_error`) | SDK-js parse tests |
| `avError` event | `freeq-sdk-js` (events + client) | 3 new client tests |
| web av-error handling | `freeq-app/src/irc/client.ts` | — (logic is thin dispatch) |
| web rename → roster re-join | `freeq-app/src/components/CallPanel.tsx` | manual (test plan §5.4) |
| macOS av-error handling | `AvStartRace.swift` + `CallController.swift` + `AppState.swift` | 6 new `AvErrorResolutionTests` |
| iOS av-error + start-race parity | `AvStartRace.swift` (new), `AppState.swift` | new `AvStartRaceTests` (10) |
| iOS test bundle resurrected | `project.yml` test scheme; stale tests fixed | all 100 iOS tests green + runnable |

**See `docs/AV-TEST-PLAN.md` for the full cross-client matrix that keeps this
fixed.**
