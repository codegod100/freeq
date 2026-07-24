# freeq blog — launch editorial calendar

## The spine (read this first)

**Category, stated once, plainly:** freeq is a *programmable, cryptographically
rooted shared environment* in which humans, software agents, services, and
media participate as **identifiable peers**. IRC is the durable wire grammar
and compatibility layer — the narrow waist — **not** the product category. We
do not launch by asking people to admire our cryptography; we make them *want
the thing*, then show why it can be trusted.

**The six-week arc, in one sentence:**
> freeq begins as a strange shared world, reveals itself as an edge-owned
> protocol substrate, and ends as the place where signed human and agent
> intent causes regenerable systems to exist.

**It is one launch, not twelve posts.** Same persistent world, identities,
agents, rooms, and servers throughout. Each week adds a capability to the
environment the reader has already met:

1. Meet the world → 2. Inspect its architecture → 3. Verify an identity →
4. Watch an agent → 5. Encrypt a conversation → 6. Add a voice agent →
7. Route arbitrary media → 8. Pipe a real station through it → 9. Add a
policy → 10. Revoke a member and rotate keys → 11. Federate another world →
12. Let the conversation cause a system to regenerate.

---

## Editorial rules

- **Make a checkable claim, then let them check it.** Wire captures, real
  signatures, decoded events, hostile-server tests, interoperating clients,
  runnable demos — never architectural promises.
- **Two formats, one of each per week** (do NOT try to make every post go
  viral — that breeds overclaiming and HN fatigue):
  - **Field notes** — technical, precise, durable, reference-quality.
  - **Experiments** — visual, strange, runnable, easy to share.
- **Three honesty tiers for hands-on** (pick per post; never promise more than
  is true):
  - **See it in 30 seconds** (a clip / a curl).
  - **Run it in 5 minutes** (a command sequence against the public server).
  - **Extend it in 30 minutes** (write a participant / verifier / bridge).
- **Every flagship post ships an artifact package:** (1) a 15–30s demo clip;
  (2) one architecture diagram that draws the **trust boundary**; (3) a
  wire-/event-level example; (4) a runnable repo or exact commands; (5) an
  explicit **"what this does *not* protect / does *not* claim"** section;
  (6) a concrete extension challenge; (7) a link into the shared **builder
  channel** where the authors are visibly present. The post is not the
  product — the executable proof is.
- **Channels do different work** (not "everything to HN"):
  - **HN** — complete artifacts, the architecture manifesto, surprising demos.
  - **lobste.rs** — protocol design, Rust internals, security tradeoffs.
  - **Bluesky** — visual demos + the local-first/federated thesis (warmest crowd).
  - **r/rust** — genuinely Rust-specific engineering only.
  - **Cryptography communities** — threat models, specs, test vectors, audits;
    not product promotion.

## The one conversion that matters
> A reader runs freeq, joins the **builder channel** with a cryptographic
> identity, and builds or modifies **one** participant, verifier, client,
> bridge, or agent.

Track: completed quickstarts · successful authenticated connections · new
self-hosted nodes · third-party agents & verifiers · external PRs · returns to
the builder channel · independently published experiments. Stars and page
views are secondary.

---

## Week 1 — Reveal the category

### 1. "We hid a secure, federated communications system inside a retro MMO." — *experiment*
- **Job:** answer "what strange new thing is this?" before any term needs
  defining. freeqworld (`../freeqworld`) is the first encounter.
- **Show, don't explain:** rooms = channels, doors = policy, NPCs = agents,
  portals = federation, private rooms = encrypted spaces, ambient/voice media
  where available. Let people explore the artifact first.
- **Try it:** *See it (30s)* clip; *Run it (5 min)* — walk into the world, then
  open the **same** room in irssi and watch your speech bubbles arrive as plain
  IRC (the "it's really one substrate" proof).
- **Channel:** HN + Bluesky. Best broadly-shareable launch moment — it's
  understandable before it's technical.

### 2. "The server is the least interesting part of freeq." — *field notes*
- **Job:** the architectural manifesto. freeq is not a server accreting
  privileged features; the server relays a common **event grammar** while
  identity, signatures, encryption, policy, media, and increasingly
  intelligence live at the **edges**.
- **Absorbs** the old "modernize IRC without forking it" material: IRCv3 tags
  as the extensibility mechanism; graceful degradation; old and new clients
  sharing a room; IRC as a *narrow waist*, not a nostalgic UI; why media and
  agents need not become server-owned features.
- **Try it:** *Run it (5 min)* — raw-socket a room, watch the `+freeq.at/*`
  tags stream by; *Extend it (30 min)* — add a client-side feature keyed on a
  tag with zero server change.
- **Channel:** HN (architecture) + lobste.rs (protocol design).
- **Gives readers the mental model everything later depends on.**

---

## Week 2 — Identity and observable agents

### 3. "Your identity signs in — and signs what it says." — *field notes*
- **Job:** one coherent trust chain (combines challenge-auth + message signing;
  two adjacent crypto posts would repeat each other). The reader should be able
  to answer: *can I determine who produced an event without trusting the relay
  that delivered it?*
  ```
  DID → challenge auth (ATPROTO-CHALLENGE) → session key
      → signed event (+freeq.at/sig) → independently verifiable author
  ```
- **Must cover** (this is where crypto readers judge us): session-key **binding
  to the DID**, who signs that binding, **key rotation**, **revocation**, key
  **discovery** (`/api/v1/signing-keys/{did}` *and* how you resolve the DID
  document without trusting the relay), and how it holds across federation.
- **Language guardrails:** say **"independently verifiable message authorship
  and integrity,"** not "non-repudiation." The "hostile server" claim is only
  valid once the key binding is verifiable independently of the server — show
  exactly how (DID doc resolution + rotation + revocation), or don't make it.
- **Try it:** *30s* verify a real signature; *5 min* verify one you can't have
  forged; *30 min* write a standalone verifier that flags any message whose
  key binding it can't independently confirm.
- **Channel:** lobste.rs + crypto communities (with test vectors).

### 4. "Watch a coding agent work — from irssi." — *experiment*
- **Job:** agents first appear here, as **ordinary observable peers**. A coding
  agent with a cryptographic identity reports objective, actions, tool use,
  blockers, artifacts, completion/failure.
- **The real point:** not "irssi can render it" but that the agent is a
  *visible participant in a shared environment*, not an invisible process
  bound to one proprietary UI.
- **Try it:** *30s* clip (agent narrates a task in a channel you watch on your
  phone); *5 min* wire your own coding agent to report into a channel.
- **Channel:** HN + Bluesky.

---

## Week 3 — Private communication and voice agents

### 5. "What an encrypted freeq message actually puts on the wire." — *field notes*
- **Job:** the E2EE-DM story told as a wire dissection, not a product boast.
  Show: plaintext → exact transmitted event → ciphertext + **exposed
  metadata** → key agreement → ratchet evolution → decryption at the receiving
  edge → what a compromise at different moments reveals.
- **Language guardrails:**
  - Say **"X3DH-style key agreement and the Double Ratchet,"** or name the
    exact specs implemented — **not** "Signal's ratchet" (unless we implement
    the Signal protocol as such). Publish **test vectors**; get the design
    reviewed *before* this post.
  - **Do not** say "the server sees nothing useful." Enumerate what remains
    exposed: sender/recipient identifiers, timing, event size, channel/routing
    context, connection metadata, traffic patterns. State plainly which
    *content* is hidden and which *metadata* is not.
  - Include an explicit **threat model** distinguishing confidentiality,
    authenticity, metadata exposure, forward secrecy, and compromise recovery.
- **Try it:** *30s* watch the server relay an opaque `ENC3` blob; *5 min*
  decrypt at the edge; *30 min* diff what changes under a simulated key
  compromise.
- **Channel:** crypto communities + lobste.rs.

### 6. "An AI joined our voice call as an ordinary participant." — *experiment*
- **Job:** the human/agent **same-participation-model** demo, shown not
  narrated. An agent that joins via the normal identity mechanism, receives
  separate per-participant audio, transcribes/reasons, speaks through the same
  programmable source interface, and stays visible + governable as an agent.
- **Frame:** not "AI meeting assistant." The point is one participation model
  for humans and agents alike.
- **Try it:** *30s* clip; *5 min* run the reference voice agent in `#voice`;
  *30 min* swap its brain.
- **Channel:** HN + Bluesky.

---

## Week 4 — Programmable media

### 7. "AV is a media bus, not a video-call feature." — *field notes*
- **Job:** the foundational reframe. `AvSession` takes pluggable sources and
  yields **one decoded stream per participant**:
  ```
  arbitrary audio source ─┐
                          ├─→ AvSession ─→ per-participant decoded streams
  arbitrary video source ─┘
  ```
  Consequences: files, TTS, and internet radio become *participants*; streams
  can be recorded or transcribed; rooms can bridge other media systems; agents
  listen and speak with no bespoke conferencing integration. freeq transports
  **participation**, not camera/mic calls.
- **Language guardrail:** be clear the signaling stays plain IRC `TAGMSG`;
  media rides MoQ/iroh-live. Draw the boundary in the diagram.
- **Try it:** *5 min* publish a file as a participant; *30 min* write a sink
  that transcribes every participant stream.
- **Channel:** HN (architecture) + lobste.rs.

### 8. "We piped an internet-radio station into a room — and sent it somewhere else." — *experiment*
- **Job:** one absurdly concrete result (post 7 already made the architecture
  argument, so this stays a clean demo). The most visually legible of the
  nandi / stream.place hacks: a station in, a room's mix out.
- **Try it:** *30s* clip; *5 min* run `#radio`; *30 min* bridge a room to an
  external stream and back.
- **Channel:** Bluesky + HN.

---

## Week 5 — Programmable policy and secure groups

### 9. "Bring your own gatekeeper." — *field notes*
- **Job:** the platform post. A **verifier** is not merely an access plugin: it
  turns **external facts into signed capabilities** freeq can act on *without
  learning the external system*. The extension point is the hero.
- **Examples (as capabilities, not recipes):** GitHub-org member, conference
  credential holder, repo contributor, currently-employed SSO subject,
  permitted agent actor-class.
- **Try it:** *5 min* gate a channel with the shipped GitHub verifier; *30 min*
  write a verifier for something of your own.
- **Channel:** HN + lobste.rs.

### 10. "Offboard someone from an encrypted room — without changing the server." — *experiment → field notes hybrid*
- **Job:** one complete, credible scenario beats six hypotheticals. The full
  chain, demonstrated:
  ```
  SSO status → verifier decision → signed credential → channel admission
    → group key sealed to device → membership revoked → new epoch
    → former member cannot read FUTURE traffic
  ```
- **Language guardrail:** revocation removes access to **future keys and
  messages**. It cannot make someone forget plaintext already read or destroy
  keys they previously copied. Say so explicitly. Name the wire formats
  (sealed group keys, epoch rotation) and keep the threat model honest.
- **Try it:** *5 min* watch a revocation rotate the epoch; *30 min* stand up
  your own SSO-gated, E2EE team channel.
- **Channel:** crypto communities + HN.

---

## Week 6 — Federation and the payoff

### 11. "Two laptops behind NAT become one network." — *experiment*
- **Job:** make federation physical. Two independent installs, no public
  inbound ports, distinct admin control, iroh connectivity, shared channel
  state, a disconnection, reconnection + convergence, a conflicting op if
  possible, and **policy enforcement on relayed events**.
- **Language guardrail:** don't let "CRDTs" become a magic word. Be precise
  about what is decentralized vs. **scoped-authoritative** — transport,
  discovery, and state replication converge; **channel ownership, policy
  authority, identity resolution, and conflict resolution have owners.** "No
  global coordinator, but scoped authorities" is the correct, defensible story.
- **Try it:** *30s* clip of two laptops converging; *30 min* federate your own
  node with a friend's behind NAT.
- **Channel:** lobste.rs + Bluesky; co-promote with iroh & Automerge.

### 12. "Conversation is the commit." — *field notes (capstone)*
- **Job:** the payoff that reveals what freeq is *for*, and the honest bridge to
  Phoenix. Demonstrate a complete causal chain, all signed and in-room:
  ```
  human intent → signed request → governed agent act → agent→agent handoff
    → generated/modified system → provenance manifest → evaluation result
    → deployment observation → signed result returned to the room
  ```
  Then show pause, resume, revoke, expiration, replacement.
- **The message:** not "agents can coordinate in chat," but that **conversation
  becomes a durable, signed, causally-connected part of a system's construction
  and operation.** freeq is the coordination + provenance substrate where human
  and machine intent is preserved; Phoenix is the regenerative execution
  architecture that can compile/regenerate implementations from that substrate.
- **Honesty note:** demonstrate what's real today (signed act cards —
  JCS-canonical, cross-SDK vectors; governance verbs; provenance; heartbeats)
  and frame the Phoenix regeneration step as the direction, clearly marked as
  vision where it isn't yet runnable. **Ground the Phoenix specifics before
  drafting.**
- **Channel:** HN + lobste.rs.

---

## Demoted / combined (and why)
- **"Six rooms you can only build…"** → documentation cookbook or a later
  collection. One deeply-demonstrated room (post 10) beats six imagined ones;
  the list reads as content marketing, not revelation.
- **"Modernize a 37-year-old protocol without forking it"** → folded into the
  Week-1 manifesto (post 2). Standalone + early, it wrongly defines freeq as an
  *IRC-modernization effort*. Later, spin the deeper version into a lobste.rs
  essay: "adding modern semantics to an old protocol without breaking its
  installed base."
- **Separate auth vs signing posts** → combined for launch (post 3). Split into
  reference-quality articles *later*, once readers know why the trust chain
  matters.

## Fun sprinkles / backlog (rotate into an experiment slot)
- "Your call, transcribed + searchable" (per-participant PCM → STT → FTS5).
- "An NPC that runs your CI" (a freeqworld agent reacting to real events).
- "Deterministic pixel-art avatars from a DID" (freeqworld character gen).
- "Roaming state without a database *you* own: per-DID favorites over REST."
- "Six clients, one Rust core: the FFI story" (r/rust).
- "An IRCv3 WG proposal for ATPROTO-CHALLENGE" (protocol thought leadership).

## Prerequisites before publishing
- **Cryptographic review + published test vectors** for the signing chain
  (post 3) and the E2EE design (posts 5, 10) — these posts invite exactly the
  audience that will find weak claims.
- **Confirm freeqworld is demo-ready** at a public URL before post 1.
- **Stand up the builder channel** (the funnel target) with the authors
  present, and the house agents/rooms the series reuses.
- **Ground the Phoenix bridge** (post 12) in what's actually runnable.
