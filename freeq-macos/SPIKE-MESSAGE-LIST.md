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
