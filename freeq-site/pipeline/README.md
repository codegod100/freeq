# freeq launch-post pipeline

The writing lane for the **"freeq in twelve proofs"** launch series. Same idea as
the *Regenerative Software* book pipeline — deterministic gates + LLM review
passes that encode the campaign's editorial rules — retargeted from a literary
manuscript to an HN-facing technical launch.

**The whole point:** make the *writing* so fast and so honest that all the launch
risk lives in the artifacts (the runnable demos), never in the prose.

## The lane

```
issue (the brief)            ../freeq (what's real)        BLOG-PLAN.md (the spine)
   github.com/chad/freeq-launch      source of truth            + existing post (voice)
        │                               │                              │
        └──────────────┬────────────────┴──────────────────────────────┘
                       ▼
        draft  (prompts/draft_launch_post.md)
                       ▼
        deterministic gates  ──►  lint_title.py · lint_hedge.py · check_artifact_package.py
                       ▼
        HN-skeptic review  (prompts/hn_skeptic_review.md)     ← the "Mike" pass, retargeted
                       ▼
        cross-proof coherence  (prompts/cross_proof_coherence.md)  ← "one launch, not twelve"
                       ▼
        blog/<slug>.md  ──►  deploy.sh
```

## Gates (deterministic, run on any `blog/*.md`)

- **`lint_title.py`** — rejects audit-bait adjectives (secure/federated/encrypted/…)
  and "MMO" in the title. Make them *want* the thing before they can audit it.
- **`lint_hedge.py`** — rejects hedging / vaporware ("where available", future-tense
  features, "should", "coming soon"). A capability is demonstrably there or absent.
  (The freeq inversion of the book's stance gate.)
- **`check_artifact_package.py`** — checklist: date, the See/Run/Extend ladder, a
  runnable command or **real** wire example, a "what this does NOT claim/protect"
  section, a builder-channel link. The "does NOT claim" section and at least one
  checkable artifact are never optional.

Run all three:

```bash
pipeline/run_gates.sh blog/some-proof.md      # or no args -> all of blog/*.md
```

## Review passes (LLM prompts in `prompts/`)

- **`draft_launch_post.md`** — draft a proof from its issue, in the existing post's
  voice, grounded in `../freeq`, honoring the hard rules.
- **`hn_skeptic_review.md`** — an adversarial pre-mortem: play the top skeptical HN
  comment and fix it before it's written.
- **`cross_proof_coherence.md`** — the "one launch, not twelve posts" continuity
  check: recurring cast, back/forward links, the arc building in order, and the
  Phoenix (provenance-layer) endgame earned by proof 12 rather than stapled on.

## Rules of the road (from the issues + `BLOG-PLAN.md`)

- **Make a checkable claim, then let them check it** — real captures, not promises.
- **The post is not the product; the executable proof is.** Ship the artifact package.
- **One launch, not twelve.** Reuse the same identities, rooms, agents, nodes.
- **Show the astonishing thing first; explain the primitive second.**
- **The issue supersedes `BLOG-PLAN.md`** on specifics (e.g. titles).
- The book's *long literary cadence* and its steelman pass are intentionally **not**
  here: posts want to be terse and HN-native, and the "what this does NOT claim"
  section already *is* the steelman.
