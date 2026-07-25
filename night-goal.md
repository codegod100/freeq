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
