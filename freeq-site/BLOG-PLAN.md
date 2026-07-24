# freeq blog — launch editorial calendar

**Goal:** attract early-adopter nerds — open-source cryptography people,
local-first / AT Protocol folks, and hackers who want to *build* on freeq.
**Cadence:** 2 posts/week for 5 weeks (10 posts), chronological below.
**Through-lines (every post hits at least one):** (a) the *decoupled*
architecture — the server is a dumb relay; identity, signing, policy, and
encryption all live at the edges; (b) end-to-end encryption; (c) message
signing. Agent coordination/handoff is deliberately **last** (it's the
payoff, not the on-ramp).

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

## Week 1 — trust primitives (the crypto hook)

### 1. "Every message is signed. Don't trust me — verify it."
- **Theme:** message signing (+ decoupling: the server never signs *for*
  you, it relays your signature untouched).
- **Angle:** impersonation is the original sin of IRC. freeq fixes it with a
  per-session ed25519 key: every PRIVMSG carries `+freeq.at/sig`, and the
  signer's public keys are published at `/api/v1/signing-keys/{did}`.
  Non-repudiation without trusting the server or even the sender's client.
- **Covers:** what's signed and how; per-session keys vs the DID; why the
  server can't forge (it only relays); how a federated message stays
  verifiable via `+freeq.at/origin`.
- **Try it:** pull a message + its `+freeq.at/sig` off the wire, `GET`
  the author's key, verify in ~20 lines (Python/TS/Rust). "The server could
  be evil and you'd still catch a forged message."
- **Why it lands:** concrete, curl-able, no account needed. Perfect opener.

### 2. "No passwords, no API tokens: log in by signing a challenge."
- **Theme:** decoupling identity from the server; local-first keys.
- **Angle:** `ATPROTO-CHALLENGE` SASL — the server sends a nonce, your device
  signs it. Humans authenticate with their Bluesky DID (`did:plc`), agents
  with a locally-minted `did:key`. Same mechanism, zero server-side account
  DB, keys never leave the device.
- **Covers:** the challenge/response on the wire; `did:key` vs `did:plc`; why
  "your key is your account" is the whole point for a local-first crowd; how
  this makes bots first-class (no token to leak).
- **Try it:** mint a `did:key`, connect a bot with it, and watch the
  challenge get signed — the 60-second agent quickstart.
- **Why it lands:** atproto/local-first bait; sets up every later post.

---

## Week 2 — encryption + protocol design

### 3. "Signal's ratchet on a 1988 protocol: E2EE DMs over IRC."
- **Theme:** E2EE.
- **Angle:** DMs use X3DH key agreement + the Double Ratchet for forward
  secrecy. The server routes an opaque `ENC3` blob; it literally cannot read
  your DMs. Prekey bundles published per device.
- **Covers:** the handshake, the ratchet, the `ENC3` wire format, what the
  server sees (nothing useful), device/prekey management.
- **Try it:** send an encrypted DM, sniff the ciphertext on the wire, then
  decrypt it client-side. "Here's the exact bytes the server relayed."
- **Why it lands:** crypto nerds love a ratchet; "bolted onto IRC" is a great
  hook.

### 4. "Modernize a 37-year-old protocol without forking it."
- **Theme:** decoupling / protocol design.
- **Angle:** reactions, edits, threads, pins, signing, voice, and agent
  events are all IRCv3 **message tags** in a documented `+freeq.at/*`
  namespace — so irssi from 1999 still connects and sees plain text, while
  modern clients light up. Extension, not schism.
- **Covers:** the tag registry as a public contract; how a tag-unaware client
  degrades gracefully; ATPROTO-CHALLENGE as the *one* new SASL mechanism.
- **Try it:** connect a raw socket, watch the tags stream by; add a new
  client-side feature keyed on a tag with no server change.
- **Why it lands:** protocol/local-first purists; the "don't fork, extend"
  ethos.

---

## Week 3 — the decoupling headliner + policy use cases

### 5. "Bring your own gatekeeper: channel access as pluggable verifiers."
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

### 6. "Six rooms you can only build with credential-gated channels."
- **Theme:** policy use cases (+ ties into signing & the transparency log).
- **Angle:** concrete, copyable recipes: a GitHub-org-only dev channel; a
  Bluesky-followers lounge; a company channel where **offboarding revokes
  access**; a conference-attendee room; a "prove you shipped" contributors
  channel; an agents-only channel gated on actor class. Every gate decision
  is signed and auditable.
- **Covers:** composing policies, the shipped GitHub verifier, auditability.
- **Try it:** stand up a GitHub-org-gated channel end to end.
- **Why it lands:** turns the abstract decoupling into "oh, I'd use that."

---

## Week 4 — advanced E2EE + distributed systems

### 7. "E2EE group channels that revoke on offboarding (no shared passphrase)."
- **Theme:** E2EE (deep) — and it *bridges* weeks 3→4 by fusing policy + crypto.
- **Angle:** credential-bootstrapped channel encryption: present a valid
  credential, receive the group key **sealed to your device key**; key epochs
  rotate on membership change, so leaving revokes access to future messages.
  No passphrase to leak or rotate by hand. `EG1`/`EGK1` wire formats.
- **Covers:** sealed group keys, epoch rotation, the SSO→credential→key flow,
  honest threat model (what is/isn't protected).
- **Try it:** run a private, SSO-gated, end-to-end-encrypted team channel.
- **Why it lands:** the "real company chat" story; crypto + policy in one.

### 8. "Federation without a coordinator: CRDTs over QUIC."
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

---

## Week 5 — the agent payoff (coordination/handoff last)

### 9. "Your coding agent, observable: watch Claude/pi from irssi."
- **Theme:** on-ramp to the agent story (light; the hook before the capstone).
- **Angle:** give a coding agent a `did:key` and a channel; it reports
  progress as signed messages you can watch from any client — even irssi over
  SSH from your phone. The scariest thing about long-running agents
  (invisibility) becomes a feed.
- **Covers:** the reporter pattern, agent identity, why "in a room" beats "in
  a black box."
- **Try it:** the "watch your coding agent" recipe — wire it in ~1 minute.
- **Why it lands:** every dev is running agents now; this is the shareable
  "whoa" demo.

### 10. "Humans and agents as peers: signed task cards, governance, handoff."
- **Theme:** coordination/handoff — the capstone that ties identity +
  signing + policy + E2EE + observability together.
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

## Sequencing rationale
- **Weeks 1–2** front-load the *individually shareable* crypto/protocol
  primitives (signing, challenge-auth, ratchet DMs, no-fork tags) — each is a
  standalone HN-worthy post and needs no prior context.
- **Week 3** is the decoupling headliner (verifiers) + its concrete payoff
  (policy recipes) — the "this is a platform you extend" turn.
- **Week 4** goes deep (VC-bootstrapped E2EE bridges policy+crypto;
  federation courts the local-first/distributed crowd + partner boosts).
- **Week 5** lands the agent arc last, because it *composes* everything
  before it — observability first (light, viral), then the full
  coordination/handoff capstone.

## Backlog / future posts (not in the 10)
- "AV over IRC: TAGMSG signaling + MoQ/iroh media" (great engineering flex;
  slot in once click-to-focus/effects parity lands).
- "Roaming state without a database you own: per-DID favorites over REST."
- "Six clients, one Rust core: the FFI story."
- "Writing an IRCv3 WG proposal for ATPROTO-CHALLENGE."
