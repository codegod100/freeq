# Draft a freeq launch post ("proof")

You are drafting one post in the **"freeq in twelve proofs"** launch series for freeq.at.

## Inputs — read all before writing
- **The issue** (the brief): the `chad/freeq-launch` GitHub issue for this proof — its *claim*, *job in the arc*, suggested titles, framing warnings, the *Try-it* ladder, and the artifact package. The issue is authoritative; where it disagrees with BLOG-PLAN.md (especially titles), **the issue wins** (the plan's draft titles predate the anti-audit-bait discipline).
- **`BLOG-PLAN.md`**: the campaign spine — the category statement, the six-week arc, the editorial rules, and the freeq↔Phoenix (provenance-layer) endgame.
- **`blog/the-room-where-humans-and-agents-work.md`**: the voice/format template. Match it — `# Title`, then `*YYYY-MM-DD*`, then body. Short (field-notes ~500–900 words; experiments can be shorter). Problem-first opening, bold lead-ins for key claims, concrete nouns (`ed25519`, `did:key`, IRCv3 tags, `/msg deploy-agent pause`).
- **`../freeq`**: the source of truth for what is real. Never describe a capability that isn't in the code and deployed.

## Hard rules (the gates enforce the first three mechanically)
- **Reveal before you audit.** No audit-bait adjectives (secure / federated / encrypted / cryptographic) and no "MMO" in the **title**. Let the post *reveal* that it is signed, encrypted, federated, policy-governed.
- **A capability is demonstrably there or absent.** No hedging — no "where available", no future tense for features, no "should", no "coming soon". If it isn't deployed and runnable now, don't mention it.
- **Ship the artifact package:** the *See-it (30s) / Run-it (5min) / Extend-it (30min)* ladder as appropriate to the format, a runnable command or a **real** wire/event/signature example (captured bytes, never illustrative pseudo-output), a note that draws the **trust boundary**, a **"what this does NOT claim / protect"** section, and a link into the **builder channel**.
- **Make a checkable claim, then let them check it** — real captures and runnable commands, never architectural promises.
- **One launch, not twelve posts.** Reuse the SAME identities, rooms, agents, and nodes established in earlier proofs; link backward to the prior proof and forward to the next. Do not invent a fresh demo universe.
- **Show the astonishing thing first; explain the primitive second.** Experiments reveal; field-notes explain. Resist product framing ("an AI meeting assistant") — it collapses the architectural claim.
- **The Phoenix thread is earned, not stapled.** Land "freeq is the provenance layer *Regenerative Software* says nobody has built" only at/near proof 12; earlier posts may gesture, never lecture.

## Output
1. The finished post as markdown, ready to drop into `blog/`.
2. A short **build list**: exactly which artifacts the human must still produce and verify on a clean machine (clip, diagram, exact commands from a fresh run, repo). The post must not claim any of them work until they do.
