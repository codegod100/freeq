# freeq blog — launch editorial calendar

**Goal:** attract early-adopter nerds — open-source cryptography people,
local-first / AT Protocol folks, and hackers who want to *build* on freeq.
**Cadence:** 2 posts/week for **6 weeks (12 posts)** — grew from 10 once AV +
agents + freeqworld earned their own slots (see "what changed" below).
**Weekly shape:** each week pairs **one foundation post** (a crypto / protocol
primitive a builder can implement) with **one flashy hack** (a jaw-dropper that
travels on HN/Bluesky). Deep + viral, every week.
**Through-lines (every post hits at least one):** (a) the *decoupled*
architecture — the server is a dumb relay; identity, signing, policy,
encryption, *and media* all live at the edges; (b) end-to-end encryption;
(c) message signing. Agent *coordination/handoff* stays **last** (the payoff),
but agents + AV now show up from week 1.

## Where AV & agents live (the killer stuff, no longer buried)
- **AV is a programmable media bus, not a video-call feature.** `AvSession`
  takes a pluggable **audio source** (publish arbitrary PCM) + a **video
  source**, and hands you **one decoded-PCM stream per participant** out. So
  you can pipe *anything* in (internet radio, a file, TTS, another stream) and
  *anything* out (record, transcribe, re-broadcast). That's the frame for the
  "programmable AV" hacks below (nandi's internet radio; stream.place in/out).
- **Agents are first-class in AV** — an agent joins the call, hears every
  participant (STT), and talks (TTS) via the same source/stream API.
- **freeqworld** (`../freeqworld`) is the showcase: a retro-MMO that's secretly
  a full freeq client — rooms = channels, doors = policy, NPCs = agents,
  portals = federation, secure rooms = E2EE. The "freeq is a programmable
  shared-reality substrate" post.
- Featured in: **W1** (radio-in), **W2** (voice agent), **W3** (stream.place
  bridge), **W4** (freeqworld), **W6** (coordination capstone).

**House rules for every post**
- Open with a claim a skeptic can *check*, then let them check it.
- Every post ends with a **copy-paste "try it in 5 minutes"** block — this
  crowd converts by running, not reading.
- Link the relevant `/docs/*` page and the `+freeq.at/*` tag registry.
- Keep the visual grammar: cyan = humans, pink = agents.
- Cross-post: HN (Show/deep-dive), lobste.rs, Bluesky thread (the atproto
  crowd is the warmest audience), r/rust + r/crypto where it fits. Ask
  iroh/Automerge to boost the federation post.

---

## Week 1 — trust + the first jaw-dropper

### 1. "Every message is signed. Don't trust me — verify it." *(foundation)*
- **Theme:** message signing (+ decoupling: the server never signs *for*
  you, it relays your signature untouched).
- **Angle:** impersonation is the original sin of IRC. freeq fixes it with a
  per-session ed25519 key: every PRIVMSG carries `+freeq.at/sig`, and the
  signer's public keys are published at `/api/v1/signing-keys/{did}`.
  Non-repudiation without trusting the server or even the sender's client.
- **Try it:** pull a message + its `+freeq.at/sig` off the wire, `GET` the
  author's key, verify in ~20 lines. "The server could be evil and you'd
  still catch a forged message."
- **Why it lands:** concrete, curl-able, no account needed. Perfect opener.

### 2. "Internet radio in a voice channel: freeq's AV is a programmable media bus." *(flashy hack)*
- **Theme:** decoupling (media lives at the edge) — the AV reveal.
- **Angle:** an `AvSession` publishes whatever **audio source** you hand it.
  Point that source at an internet-radio stream (decode to PCM) and the whole
  channel is now listening to your station — no special server support, it's
  just "a participant whose voice happens to be a radio." (nandi's hack.)
- **Covers:** signaling (IRC TAGMSG) vs media (MoQ/iroh-live) split; the
  source/stream API; why any client sees a normal call.
- **Try it:** ~40 lines: connect an `AvSession`, feed it a radio stream, join
  `#radio`. Bonus: a `/np` bot that announces the now-playing track.
- **Why it lands:** instantly gettable, delightful, screenshot/clip-able —
  and it teaches "AV is programmable" in one demo.

---

## Week 2 — identity + agents that talk

### 3. "No passwords, no API tokens: log in by signing a challenge." *(foundation)*
- **Theme:** decoupling identity from the server; local-first keys.
- **Angle:** `ATPROTO-CHALLENGE` SASL — the server sends a nonce, your device
  signs it. Humans authenticate with their Bluesky DID (`did:plc`), agents
  with a locally-minted `did:key`. Zero server-side account DB; keys never
  leave the device.
- **Try it:** mint a `did:key`, connect a bot, watch the challenge get
  signed — the 60-second agent quickstart.
- **Why it lands:** atproto/local-first bait; sets up every later post.

### 4. "An AI that joins the call, listens, and talks back." *(flashy — AV + agents)*
- **Theme:** AV + agents (the killer combo, shown early).
- **Angle:** because AV is a media bus, an agent uses the *same* API: its
  audio source is TTS output, and it receives one decoded-PCM stream per
  participant → STT → it hears you. `freeq-av` opens the session,
  `freeq-agent-kit` segments speech into utterances and detects when the
  agent is addressed.
- **Covers:** the `AvSession` + `VadSegmenter` loop; turn-taking; how the
  agent authenticates (its `did:key` from post #3).
- **Try it:** a voice agent that answers questions in `#voice` — the
  av-agents quickstart.
- **Why it lands:** "I put Claude in my Zoom call" energy, but open + hackable.

---

## Week 3 — E2EE + the restream hack

### 5. "Signal's ratchet on a 1988 protocol: E2EE DMs over IRC." *(foundation)*
- **Theme:** E2EE.
- **Angle:** DMs use X3DH key agreement + the Double Ratchet for forward
  secrecy. The server routes an opaque `ENC3` blob; it literally cannot read
  your DMs. Prekey bundles published per device.
- **Try it:** send an encrypted DM, sniff the ciphertext on the wire, then
  decrypt client-side. "Here's the exact bytes the server relayed."
- **Why it lands:** crypto nerds love a ratchet; "bolted onto IRC" hooks.

### 6. "Bridge a freeq call to stream.place — in *and* out." *(flashy hack)*
- **Theme:** decoupling (media at the edge), programmable AV part 2.
- **Angle:** consume the per-participant PCM/video streams, mix them, and push
  to an external broadcast (stream.place / RTMP) — a freeq call becomes a live
  show. Or the reverse: pull an external stream in as a participant. The call
  is just a media graph you wire up. (nandi's stream.place hack, both
  directions.)
- **Covers:** the out-path (per-participant streams → mixer → encoder →
  external sink), the in-path (external source → `AvSession` publish), and how
  signaling stays plain IRC the whole time.
- **Try it:** restream `#stage` to stream.place; then pipe a stream.place feed
  back into a different channel.
- **Why it lands:** "my group call is now a broadcast studio" — pure hacker
  candy; cements the media-bus mental model.

---

## Week 4 — the decoupling headliner + the showcase

### 7. "Bring your own gatekeeper: channel access as pluggable verifiers." *(foundation flagship)*
- **Theme:** decoupling (the flagship post).
- **Angle:** who may join a channel is a **verifiable credential** checked by
  a *verifier* that runs as its own service. The freeq server knows nothing
  about GitHub, Bluesky, or your SSO — it just checks signed credentials.
  Write a verifier in an afternoon; zero server changes; issue credentials
  for anything.
- **Covers:** the verifier contract, the signed-decision flow, the
  transparency log, why decoupling here means the platform is *yours* to
  extend.
- **Try it:** build a toy verifier that gates a channel on something fun —
  "owns this NFT", "solved my CTF", "typed the secret handshake."
- **Why it lands:** hackers see an open extension point and a weekend project.

### 8. "A retro MMO that's secretly a chat protocol: freeqworld." *(flashy showcase)*
- **Theme:** the whole decoupled substrate, made visible.
- **Angle:** `../freeqworld` is a browser top-down RPG that's a full freeq
  client — rooms = channels, speech bubbles = messages, **doors/keys =
  channel policy**, **NPCs = agents**, **portals/roads = federation**,
  **secure rooms = E2EE** decrypted only on the client. "freeq isn't a chat
  app; it's a programmable shared-reality substrate — here's one rendering."
- **Covers:** how each game element maps to a real freeq primitive; the same
  world rendered by a terminal, web chat, and the game at once.
- **Try it:** walk into freeqworld; then open the *same* room in irssi and
  watch your speech bubbles arrive as plain IRC.
- **Why it lands:** the HN front-page swing — instantly understandable,
  visually undeniable, and it recruits builders ("what would *you* render?").

---

## Week 5 — policy payoff + advanced E2EE

### 9. "Six rooms you can only build with credential-gated channels." *(foundation)*
- **Theme:** policy use cases (+ ties into signing & the transparency log).
- **Angle:** concrete, copyable recipes: a GitHub-org-only dev channel; a
  Bluesky-followers lounge; a company channel where **offboarding revokes
  access**; a conference-attendee room; a "prove you shipped" contributors
  channel; an agents-only channel gated on actor class. Every gate decision
  is signed and auditable.
- **Try it:** stand up a GitHub-org-gated channel end to end.
- **Why it lands:** turns the abstract decoupling into "oh, I'd use that."

### 10. "E2EE group channels that revoke on offboarding (no shared passphrase)." *(foundation, bridges policy+crypto)*
- **Theme:** E2EE (deep) — fuses policy + crypto.
- **Angle:** credential-bootstrapped channel encryption: present a valid
  credential, receive the group key **sealed to your device key**; key epochs
  rotate on membership change, so leaving revokes access to future messages.
  No passphrase to leak or rotate by hand. `EG1`/`EGK1` wire formats.
- **Covers:** sealed group keys, epoch rotation, the SSO→credential→key flow,
  honest threat model (what is/isn't protected).
- **Try it:** run a private, SSO-gated, end-to-end-encrypted team channel.
- **Why it lands:** the "real company chat" story; crypto + policy in one.

---

## Week 6 — distributed + the agent finale

### 11. "Federation without a coordinator: CRDTs over QUIC." *(foundation)*
- **Theme:** decoupling / local-first.
- **Angle:** server-to-server over **iroh** QUIC (NAT-traversing, no
  port-forwarding) with **Automerge** CRDT convergence for channel state — no
  central authority, no primary. Plus the guardrails: event dedup, per-peer
  rate limits, authorization checks on relayed ops.
- **Covers:** why CRDTs for chat state, the QUIC transport, the security
  guards, running standalone vs federated.
- **Try it:** federate two self-hosted freeq servers running on two laptops
  behind NAT.
- **Why it lands:** distributed-systems + local-first crowd; co-promote with
  iroh & Automerge (they're already in the credits bar).

### 12. "Humans and agents as peers: signed task cards, governance, handoff." *(flashy finale)*
- **Theme:** coordination/handoff — the capstone that ties identity +
  signing + policy + E2EE + AV + observability together.
- **Prelude (fold in the "watch your agent" hook):** give a coding agent a
  `did:key` and a channel; it reports progress as signed messages you watch
  from any client — even irssi over SSH. Then go further:
- **Angle:** typed coordination events and **signed `act` cards**
  (JCS-canonicalized, byte-identical across the Rust & TS SDKs via shared
  test vectors); governance verbs (pause / resume / revoke); TTL-bound
  capabilities; provenance manifests; signed heartbeats (no ghost agents).
- **Covers:** the act-signing canon, the governance model, a full worked
  multi-agent workflow that a human steers from a channel.
- **Try it:** build a governed two-agent handoff you can pause from your phone.
- **Why it lands:** the frontier crowd; the grand finale that makes the whole
  architecture click.

---

## What changed (from the first 10-post draft)
- **AV came out of the backlog and up front.** It's now the media-bus reveal
  (W1 radio), the agent-in-a-call demo (W2), and the stream.place bridge (W3).
- **Agents show up in week 1–2, not just the finale.** Voice agent in W2; the
  coordination/handoff capstone still lands last (W6) because it composes
  everything.
- **freeqworld is the W4 showcase** — the substrate made visible.
- **Grew 10 → 12 / 5 → 6 weeks** to fit without cutting the crypto spine. If
  you want to hold at 5 weeks, drop #10 (group E2EE folds a paragraph into #7)
  and #11 (federation → backlog).
- **Every week is now foundation + flashy** — a deep buildable post plus a
  clip-able jaw-dropper, so there's always something to share.

## Sequencing rationale
- **W1–W3** front-load shareable primitives (signing, challenge-auth, ratchet
  DMs) each paired with a killer AV hack (radio, voice agent, restream).
- **W4** is the decoupling headliner (verifiers) + the freeqworld showcase.
- **W5** is policy payoff + deep E2EE.
- **W6** lands distributed systems + the agent coordination finale.

## Backlog / "fun sprinkles" (rotate in, or replace a flashy slot)
- "Your call, transcribed + searchable" — pipe per-participant PCM to STT,
  index with FTS5 (programmable-AV part 3).
- "An NPC that runs your CI" — a freeqworld agent that reacts to real events.
- "AV over IRC, under the hood: TAGMSG signaling + MoQ/iroh media."
- "Roaming state without a database *you* own: per-DID favorites over REST."
- "Six clients, one Rust core: the FFI story."
- "Deterministic pixel-art avatars from a DID" (freeqworld character gen).
- "Writing an IRCv3 WG proposal for ATPROTO-CHALLENGE."
