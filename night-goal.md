# Night goal — remarkable red/green TDD polishing for release

**Started:** 2026-07-24 ~22:00 · **Owner:** pi (autonomous overnight run)

## Goal

Raise release confidence in the code most likely to break, using **strict
red→green TDD**: every fix in this run starts with a test that *fails for the
right reason*, and the commit message records the red output.

This is explicitly **not** a coverage-number exercise. A test that passes the
moment it's written proves nothing about the code and only locks in current
behaviour. Where I add such tests deliberately (characterization, to pin
behaviour before a refactor) I label them as such.

## Why these targets

`AGENTS.md` names the hotspots and their test debt. Ordered by
gamma × test-debt:

| Target | Gamma | Test debt | Why it matters for release |
|---|---|---|---|
| `freeq-sdk/src/client.rs` | 104 | **ZERO unit tests** on the connection state machine | Every client (macOS, iOS, TUI, bots) reconnects through this. The reconnect-storm bug already shipped from here once. |
| `freeq-app/src/irc/client.ts` | 133 | **UNDERTESTED** | The web client's entire protocol layer: tag parsing, batches, signing, state. |
| `freeq-app/src/components/MessageList.tsx` | 103 | **UNDERTESTED** — Playwright only | Rendering/grouping/edit-delete correctness; Playwright can't cover the edge cases. |
| `freeq-server/src/{server,web}.rs` | 334 / 275 | Well tested (116 / 41) | Only touch if a test finds a real defect. |

## Approach (the discipline)

For each target, in order:

1. **Read** the unit under test and enumerate its edge cases and invariants.
2. **Write a test that should fail** — an invariant I believe is *violated*, or
   an edge case I believe is *unhandled*. Predict the failure first.
3. **Run it. Capture the red output.** If it passes unexpectedly, that's
   information: the code was already correct. Delete or relabel the test as
   characterization and move on — do **not** claim a red/green cycle I didn't
   have.
4. **Fix minimally.** Go green. Re-run the whole suite for regressions.
5. **Commit** the test + fix together, with the red output quoted in the
   message so the cycle is auditable.

## Rules for this run

- **No behaviour changes without a failing test first.** Refactors excepted,
  and only under existing green tests.
- **Never weaken a test to make it pass.**
- **Blocked → document in this file and move on.** Don't burn the night on one
  item.
- **Commit frequently** — every red/green pair, so progress survives.
- Run the full relevant suite before each commit: `cargo test -p <crate>`,
  `npx vitest run`, `swift test` (with `DEVELOPER_DIR`).
- Don't touch production infra overnight (no deploys, no server restarts).
  Deployable changes get committed and left for the morning.

## Log

Newest last. Each entry: what I predicted, what actually happened.

### 0. Fix `scripts/hotspots.sh` (blocked the whole method)
`AGENTS.md` says to run this at session start; it dies on stock macOS
(`declare -A` needs bash 4, macOS ships 3.2), so nobody has been able to run
it locally. Rewrote portably. Not TDD — it's the instrument, and I need it
working to choose targets honestly.

**What it revealed:** `AGENTS.md`'s hotspot list is stale. Current top gamma is
`freeq-eliza/src/irc.rs` (520), which isn't mentioned there at all; and the
claims of "ZERO unit tests" on `freeq-sdk/src/client.rs` (now 70) and
"UNDERTESTED" `irc/client.ts` (now 4 dedicated test files) are both out of
date. So I stopped trusting the notes and went hunting for defects directly.

### 1. RED→GREEN: a delete addressed to a DM could gut a channel message
`d43db033`

**Predicted:** `find_original_message`'s global msgid fallback has no target
constraint, so a `+draft/delete` sent to a DM can resolve a row in a channel;
`handle_delete` then writes the DB using the row's real channel but gates the
in-memory purge on `is_channel` (from the *wire* target) → desync.

**First run passed — my test was wrong, not the code.** The SDK negotiates
`echo-message`, so alice's own PRIVMSG was sitting unconsumed in her queue and
satisfied my "is it in history?" scan. Added `drain_events()` and anchored the
scan on the `chathistory` BATCH opener. That false positive is exactly how this
bug survived to production, so the helper is load-bearing.

**Then RED:** `CHATHISTORY(db-backed)=false vs JOIN-replay(memory-backed)=true`
— the row *was* soft-deleted in SQLite while the channel kept serving it from
memory, and no channel member was told. Gone from SEARCH at once and from
history after the next restart; still visible to everyone in the room.

**Fix:** `dm_fallback_row_is_addressable()` — the fallback may only resolve a
`dm:` row whose participant list contains the caller's DID. + 5 unit tests
(incl. a substring-vs-participant case: `did:plc:alice` must not reach
`did:plc:alice2`'s threads).

**Also found:** message deletion had **zero** integration coverage.

### 2. RED→GREEN: TAGMSG ignored channel-name case
`(this commit)`

**Predicted:** `process_privmsg` normalizes its target (messaging.rs:1336) but
`handle_tagmsg` passes the raw wire target straight through, so every
TAGMSG-driven feature keys off an un-normalized name.

**RED:** a client that keeps the display case it joined with (`#Case`) cannot
delete its own message — the msgid lookup misses and the server answers
`MESSAGE_NOT_FOUND`. Same root cause orphans **reactions**: they persist under
the un-normalized key, detached from the message they annotate.

**Fix:** normalize the channel target once at the top of `handle_tagmsg`.

### 3. RED→GREEN: deleting an edited message left the edited text readable
`c8c131b2` — **worst find of the night**

**RED:** `delete of the original left revisions readable: ["secret v2"]`

An edit is a *new row* with `replaces_msgid`; clients keep the **original**
msgid as the message identity, so a delete names the original while the current
text lives in the edit row. `soft_delete_message` matched one exact msgid. So:
edit a message to redact something → delete it → server says OK, your client
removes it → **the newest text stays readable in CHATHISTORY and FTS search,
forever.** Fails in the worst possible direction.

**Fix:** `revision_family()` walks up to the root revision and collects every
revision that transitively replaces it; `soft_delete_message` sweeps all of it
(DB + FTS) from either end. Both walks bounded against `replaces_msgid` cycles.

### 4. RED→GREEN: deleting a pinned message left a dangling pin
`ed74fd94`

**RED:** `left: ["id-other", "id-pinned"]  right: ["id-other"]`

`handle_delete` purged only the in-memory `ch.pins`; the `pins` row outlived the
message and pins reload from the DB on boot, so after a restart the channel
advertised a pin resolving to nothing. Fix: sweep the family's pins in
`soft_delete_message`, which already owns "make this message gone".

### 5. RED→GREEN: private-channel data was world-readable over REST
`fb7c299f` — **release blocker**

**RED (5 tests):**
```
anonymous GET of a +k channel's topic returned 200:
  {"topic":"acquisition of Initech — do not leak", ...}
```

`/history`, `/export`, `/evidence`, `/messages/{msgid}` all funnel through
`authorize_channel_read`. Five siblings never did — and `topic`, `audit`,
`events` didn't even take a `HeaderMap`, so they *could not* authorize. No
bearer, no membership check, no mode check, for any channel on the instance:
topic, governance/audit timeline (actor DIDs + signatures + payloads), signed
coordination events, pinned text, and call membership.

**Fix:** all five through the one guard. Included two **control** tests so the
fix can't over-lock (already-guarded endpoints stay refused; a public channel
stays 200) — those passed before and after, which is what proves the harness
was detecting protection rather than just returning errors.

### 6. RED→GREEN: same hole in the governance endpoints
`3b8c10d7`

`/approvals`, `/budget`, `/spend`, `/agent-capabilities` also took no
`HeaderMap`: a private channel's spend, limits, agent permissions and pending
human decisions were public. Also pinned two properties that were already
correct so they can't regress (the channel *list* hides private channels; the
governance endpoints stay 200 for public channels).

Every channel-scoped read endpoint in `web.rs` now funnels through one guard.

### 7. RED→GREEN: unauthenticated artifact writes + a dead sessions lookup
`fa457e17` — two bugs, one commit

**7a.** `POST /api/v1/sessions/{id}/artifacts` took **no auth at all**.
RED: `anonymous POST of a session artifact returned 200`. Worse than a plain
write: `created_by` came from the **request body** (attribution forgery in the
one layer whose value proposition is verifiable authorship), and the handler
broadcasts a NOTICE into the session's channel using caller-supplied text —
unauthenticated message injection into a room the caller isn't in. Session ids
are not secret (channel members see them in `av-*` TAGMSGs).
Fix: require a bearer; authorize as participant, else fall back to the bound
channel's read rule; take `created_by` from the authenticated caller.

**7b.** `GET /channels/{name}/sessions` never found anything.
RED: `bare channel name found no active session, but one is running` — it
passed the raw path segment to `active_session_for_channel` while sessions are
stored `#`-prefixed, so it reported "no calls" for every channel unless the
caller URL-encoded the `#`. Found *accidentally*, while building the fixture for
7a — the test needed a real session and couldn't see one.

### 8. Follow-through: clients must send the bearer
`29d70d34` (web), `b4c9d187` (macOS + iOS)

Not an independent discovery — but the authorization fixes above would have been
a **silent release regression** without it. Every client called `/pins`,
`/audit`, `/sessions` with no `Authorization` header, so those features would
have kept working on public channels and started 403ing on private ones: the
case the people who most care about privacy actually use. This is the kind of
break that ships green and surfaces as "pins are broken for me".

- web: new `lib/api.ts` (`authHeaders`/`apiFetch`, 6 tests). `irc/client.ts`
  uses a local `authedFetch` instead — it owns the singleton client, so
  importing `lib/api` would be an import cycle.
- native: new `Models/ApiAuth.swift` in both clients (4 tests each), including
  "blank bearer is treated as absent" so a cleared session can't send
  `Bearer `.

### 9. RED→GREEN: reactions outlived the message they annotate
`ea648a45`

Completes the delete lifecycle: `soft_delete_message` now sweeps messages, FTS,
pins **and** reactions for the whole revision family. Mildest of the family (
nothing surfaces them today) but they retain a record of who reacted to content
the author deleted.

*Process note:* my first version of this test failed for the **wrong reason** — I
had `store_reaction`'s first two arguments swapped. Fixed the call so the failure
was the real one before writing any fix. A red test that's red for the wrong
reason is worse than no test.

### 10. Strengthened a test that was buying false confidence
`6b6de9a8`

`edit_delete_adversarial.rs` **already had** a `delete_after_edit` test. Cycle 3's
bug walked straight past it, because all it asserted was that the delete TAGMSG
got relayed:

```rust
assert!(del.is_some(), "Delete after edit should succeed");
```

Relaying the TAGMSG isn't the contract; removing the content is. Now asserts
neither revision returns from CHATHISTORY — and I **verified the new assertion
has teeth** rather than passing vacuously (an absence-check trivially passes if
the query returns nothing) by reverting `soft_delete_message` to its pre-fix
behaviour and watching it fail with the leaked wire line, then restoring.

### 11. RED→GREEN: the same delete-after-edit bug in *every* client
`4005179d` (web, macOS, iOS), `05eca625` (TUI)

One conceptual mistake replicated across four surfaces: **treating a message's
identity as its latest revision's id.** Every client's edit path re-keys the
message to the edit's msgid; every client's delete path matched on that id alone.
Deletes always name the *original* msgid, so a delete of an edited message
matched nothing and **left it on screen** after the server had removed it.

Each client's *edit* path had already learned to match "id OR chain-root"; only
the delete path hadn't. Fixed in all four, with per-client tests including
"reaching the line via the alias must not bypass the author check" (that check is
the defence against spoofed peer wire events). TUI needed a new `edit_of` field —
its `edit_aliases` set records *that* an id was seen, not which line owns it. Also
verified non-vacuous by reverting the lookup and re-running.

### 12. Repaired the workspace build (pre-existing)
`9dfc814c`

`cargo test --workspace` couldn't complete at all: `AvConfig` grew an
`audio_only` field and two initializers (`freeq-av-image`, plus a **doctest**)
were never updated. Confirmed pre-existing — reproduces 13 commits back, and I
never touched those crates. Found only because I ran the *whole* workspace at the
end instead of just the crates I'd been in: **a crate that doesn't compile is
invisible to per-crate test runs.**

## Scoreboard

| | before | after |
|---|---|---|
| Rust workspace | *did not build* | **2125 passing** |
| freeq-server | 1105 | **1123** |
| web (vitest) | 787 | **796** |
| macOS core | 472 | **479** |
| iOS core | 114 | **121** |
| freeq-tui | 86 | **90** |

**11 real defects found and fixed**, each caught by a test that failed first, plus
one pre-existing build breakage and one false-confidence test corrected.

Release blockers among them:
1. **Delete left the edited text readable** (server DB) — fails in the worst
   direction: you redact something, delete it, and the redacted text persists.
2. **Private-channel data world-readable over REST** — topic, audit/governance
   timeline, coordination events, pins, call membership, spend, agent
   permissions. No bearer required.
3. **Unauthenticated artifact writes** with body-supplied `created_by` —
   attribution forgery plus message injection into a channel.

Areas swept: the message delete/edit lifecycle end to end (DB, in-memory, FTS,
pins, reactions, and all four clients), TAGMSG target normalization, the entire
channel-scoped REST surface (reads *and* writes), and client bearer propagation.

## Patterns worth keeping

- **The same bug lived in four clients** because each was written against `id`
  while the edit path had already learned better. When a fix touches identity
  semantics, grep the other surfaces before closing.
- **Two of my own tests were initially wrong** (a stale echo-message match; a
  swapped argument). Both would have "passed" and hidden real bugs. When a test
  passes on the first run, suspect the test.
- **Absence assertions need proving.** "X is not in history" passes trivially if
  the query returns nothing. I verified by reverting the fix each time.

## Not done / notes for the morning

- **Nothing deployed.** Everything is committed and pushed; the server has not
  been restarted, per the no-overnight-infra rule. **Deploy the server and the
  clients together** — the REST authorization fixes make private-channel
  endpoints require a bearer, and the client commits are what start sending it.
  Server-only deploy = private-channel pins/audit/calls break in older clients.
- **`addReaction`/`removeReaction` still match on `id` only** (web + native), the
  same narrow match I fixed for delete. I could not construct a failing case (a
  reaction is sent against the id the client currently holds, so it round-trips),
  and I won't change behaviour without a failing test. Worth a deliberate look.
- **`AGENTS.md` hotspot notes are stale** (see item 0): top gamma is now
  `freeq-eliza/src/irc.rs` (520), unlisted, and the "ZERO unit tests" /
  "UNDERTESTED" claims for `sdk/client.rs` and `irc/client.ts` are out of date. I
  left AGENTS.md alone — editing the instructions I'm working from felt like your
  call, not mine.
- **`freeq-eliza/src/irc.rs` never got swept.** It's the #1 hotspot by gamma and
  I spent the night where the user-facing risk was (data loss, then
  authorization). It's the obvious next target.
