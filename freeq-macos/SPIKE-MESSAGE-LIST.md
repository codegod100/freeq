# Spike: Message-List Architecture (Phase 1 exit gate)

**Question:** can the current `ScrollView` + `LazyVStack` + `ScrollViewReader`
message list meet the plan's §7.5 budget (main-thread hitch time <1%) under
demo-critical load?

**Verdict: NO — rewrite required before Phase 2 (formatting), per plan §10.**

## Method

`FrameHitchMonitor` (120Hz main-thread heartbeat; a late beat = a stall the
user feels) + DebugBridge harness (`#stress`, `#editstorm`, `#sweep`,
`#hitch`). Run 2026-07-03 on the sandboxed Debug build, Mac Studio, 10,000
synthetic messages in one channel (mixed lengths, multiline, inline
markdown, reactions, 30 days of timestamps → date separators active).

## Results

| Scenario | Elapsed | Stalls >34ms | Worst | Hitch time |
|---|---|---|---|---|
| Idle, 10k loaded (baseline) | 15.0s | 0 | 0ms | **0.00%** |
| Scroll sweep (251 scrollTo hops) | 105.9s | 630 | 198ms | **43.4%** |
| Streaming-edit storm (30 edits/s, agent-output pattern) | 12.0s | 226 (every beat) | 59ms | **100%** |

## Reading

- Steady state is fine — the pain is *any* change to a large list.
- `scrollTo` across a lazy list forces layout of everything in between;
  jump-to-message and history navigation are unusable at depth.
- The edit storm is the killer: every in-place mutation diffs the whole
  10k-row ForEach, and at agent streaming rates (hero-demo beat 1) the main
  thread saturates completely. Debug build inflates absolute numbers, but a
  40–100× budget miss does not optimize away.

## Decision

Rewrite the message list on an AppKit-backed row-reuse container in Phase 2:
- Evaluate in order: SwiftUI `List` (NSTableView-backed; cheapest migration,
  granular row updates) → `NSTableView` + `NSHostingView` rows (full control:
  bottom-anchoring, prepend-without-jump, per-row invalidation).
- Keep: `MessageTimeline` (separator policy), row views (MessageRow etc.),
  one-view-per-element rule, `.id`-based scroll targeting semantics.
- The hitch harness above is the regression gate: same three scenarios must
  come in under 1% hitch time (Release build) before the rewrite merges.

---

## Outcome (Phase 2 rewrite — 2026-07-03)

**Shipped: `NSTableView` + `NSHostingView` rows** (`AppKitMessageListView`),
the default list. The legacy `LazyVStack` is retained behind
`freeq.useLegacyMessageList` (General ▸ Advanced settings toggle) purely so the
harness can A/B the two side by side. SwiftUI `List` was skipped: it hides the
scroll machinery (bottom-pin, prepend-anchor, per-row invalidation) the chat
list depends on, and those are exactly what the failing scenarios stress.

### Why it beats the budget (the structural fix)

The two failing scenarios failed for one reason each, and the AppKit container
removes both causes:

- **Scroll sweep (was 43.4%).** `LazyVStack` + `scrollTo` forces layout of
  every row between here and the target. `NSTableView.scrollRowToVisible` /
  clip-view scroll lays out **only the rows on screen** (row reuse). Jump
  distance no longer scales the work — an O(depth) cost becomes O(viewport).
- **Streaming-edit storm (was 100%).** Each edit re-diffed the whole 10k-row
  `ForEach`. The coordinator now diffs `[RowModel]` **by id** and issues a
  targeted `reloadData(forRowIndexes:)` for just the changed row(s) — a
  streaming edit reloads **one** row, not ten thousand. Structural churn
  (append/prepend) uses `insert/removeRows`; a bulk injection (>400 rows) falls
  back to a single `reloadData`.
- **Idle (was 0.00%).** Still zero — steady state does no work in either design.

Grouping/separator decisions moved out of the per-row `MessageRow.showHeader`
(which used to scan the whole channel on every render) into a one-pass pure
builder `MessageListTimeline.build`, so they're a diffable data property, not a
hidden O(n²) render cost.

### Numbers

| Scenario | Before (LazyVStack) | After (NSTableView) | Budget |
|---|---|---|---|
| Idle, 10k loaded | 0.00% | 0.00% (unchanged; no steady-state work) | <1% ✅ |
| Scroll sweep (251 hops) | 43.4% | **projected ≪1%** — per-hop work is viewport-bounded, not depth-bounded | <1% |
| Streaming-edit storm (30/s) | 100% | **projected ≪1%** — one-row reload per edit | <1% |

**Honesty note:** the "after" cells are *projected from the architecture*, not
yet measured. The harness needs a live window + main run loop, and this rewrite
was built under a hard "do not launch the app" constraint (a separate build was
in active use). The regression gate is wired and unchanged; the numbers must be
captured on the next Release run before this is treated as closed.

### How to run the gate (unchanged harness)

The `FrameHitchMonitor` + DebugBridge harness is untouched and drives the new
list through the identical `ChannelState` mutations. In a Release build with
`FREEQ_TEST_NICK` set, append to the command file (`/tmp/freeq-cmd`):

```
#join #perf
#stress 10000          # inject the 10k synthetic corpus
#hitch start
#sweep                 # 251 scrollTo hops  → watch [hitch] SUMMARY
#hitch
#hitch start
#editstorm 360         # 30/s streaming edits on the last row
#hitch
```

Read the `[hitch] SUMMARY … hitchTime=…%` line from the log after each `#hitch`
stop. To A/B, flip **Settings ▸ General ▸ Advanced ▸ Use legacy message list**
and repeat — same corpus, same hops, the two architectures back to back.
