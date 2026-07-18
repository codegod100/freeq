# RFC v0.4: `freeq.at/act` — stateful, signed, addressed actions for IRCv3

*(with `handoff` as the first action kind)*

**Status:** draft / request for comments · **Authors:** Chad Fowler & zapnap (freeq) · **Audience:** agent-coordination builders, IRCv3, AT Protocol

This is a casual RFC. Poke holes in it.

> **What changed since v0.3** (thanks to review feedback): (1) **Invalid ≠ unverifiable.** The validator now distinguishes a *bad* signature (reject, like an illegal transition) from an *unverifiable* one (the key's origin server is unreachable — **defer and retry**, never reject). v0.3 conflated a forgery with a third-party outage and turned transient network blips into permanent, silent action loss. The same stall-not-fork stance we already took for an unreachable minting server now applies to key lookup. (2) **The canonical is no longer a fixed field list.** The signature covers *every* `act-*` tag present, sorted — so new kinds can add fields without a canonical version bump, and there is no such thing as an unsigned kind-specific tag riding a signed action. This dissolves most of v0.3's "canonical versioning" open question. (3) **`act-to` is un-overloaded.** It only ever names an assignee DID. Open/claimable actions simply *omit* it — unassigned is the natural encoding of unassigned — and the posting venue comes from the message target, where it always actually was. (4) **Orphaned actions are specced, not implied.** If a minting server dies, its actions stall — but peers may now mark them **`orphaned` in their local view** (non-authoritative, reversible), and an assignee's terminal event is still *recorded* in the signed log even when it can't yet be *ordered*. Done work is never silently lost; it's just not yet authoritative. (5) **The nick→DID stamp is flagged as unauthenticated** — it's origin-asserted, and because DM persistence keys off the DID, a bad stamp has a *durable* blast radius, unlike today's ephemeral nick spoofing. Receivers verify-when-possible; actions never depend on the stamp (the assignee DID is inside the sender-signed canonical). (6) **Two asymmetries are now owned instead of implicit:** the offerer wins cancel-vs-accept ties by construction (the serializer is its own origin — and cancel-biased ties are the safe default), and under interim key lookup, claim ordering is really "first *verified*," which depends on each claimant's origin responding. (7) **Deadline enforcement gets an explicit skew grace window** — everything else in the design avoids wall clocks; the one place we compare against one shouldn't assume synchronized clocks (we have the drift incident scars to prove it). (8) Four of v0.3's open questions are **decided** (see *Decided in v0.4*).

---

## TL;DR

A typed, addressed, signed, **stateful** message: an action with a lifecycle (`offer → accept/decline → progress → complete/fail/cancel`), distinguished from chat by an `act` kind tag and correlated by a ULID. Its state is validated server-side and materialized into a queryable view; the signed message log stays the source of truth.

`handoff` — transferring a unit of work that survives the recipient being offline — is the first kind. The same substrate carries `approval`, `grant`, and friends later. If those reuse it without reinventing, the shape is right.

## Motivation

AI agents call tools fine but coordinate badly *across time*: when an agent goes offline, in-flight work and context evaporate. The common answer (e.g. AIRC) is a separate HTTP registry + inbox just for agents.

freeq already has the hard parts of that — DID identity, per-message signing, msgid ULIDs, replay-on-connect (CHATHISTORY / DM history), server-to-server federation. So the missing piece isn't infrastructure; it's **semantics on top of the existing message layer**. Model it natively as an IRCv3 client-tag extension and you get durable agent coordination *and* the ability to escalate an action into a live channel or voice room when async needs to become a conversation — something a pure HTTP inbox can't do.

One caveat on that "already has," and it's why this RFC runs longer than a tag spec. A couple of those rails were built for **chat**, where the bar is lower than for a durable, signed, addressed *object* — and a handoff leans on them anyway. Addressing resolves *per-server*: fine for "message bob now," wrong for "this task is bob's and has to reach him on whatever server he's on." Signing keys live only as long as a *session*: fine for a line that scrolls past, wrong for an offer accepted next week. So two of the sections below — **Addressing**, and the key half of **Signing** — aren't handoff features; they're preconditions the headline quietly assumes ("addressed to an identity," "signed," "survives offline") and that don't actually hold until we firm them up. Everything else really is reuse.

## The reframing: an action substrate, not a handoff inbox

Once a handoff is a typed, signed, stateful action on a message, it stops looking unique. Reactions/edits/deletes/pins/replies are already "actions on a message." Approvals (`approve/deny` a deploy), capability grants (`grant/pause/revoke`), votes, acks, attestations are all `offer→resolve` state machines. They all want the same three things:

1. a **verb-tagged typed message**,
2. a **transition validator** (who may move it to which state),
3. a **materialized view** of current state.

So the wire uses generic `act-*` tags with the kind as a value. `handoff` is one kind — here directed to a specific DID, posted in-channel so the room can watch:

```
@+freeq.at/act=handoff;+freeq.at/act-verb=offer;+freeq.at/act-id=01JABC…;
 +freeq.at/act-to=did:plc:scholar;+freeq.at/act-title=Cite 3 sources on X;
 +freeq.at/act-ctx=freeq:blob/cap/abc;+freeq.at/act-ctx-h=sha256:9f…;
 +freeq.at/act-caps=freeq.at/web-search;+freeq.at/act-deadline=1788000000;
 +freeq.at/sig=ed25519:kid:… TAGMSG #ops
```

…the *open/claimable* variant is the same wire with **no `act-to`** — unassigned means unassigned, and the channel it's posted to is the queue:

```
@+freeq.at/act=handoff;+freeq.at/act-verb=offer;+freeq.at/act-id=01JXYZ…;
 +freeq.at/act-title=Summarize today's S2S logs;+freeq.at/act-ctx-h=sha256:2c…;
 +freeq.at/act-caps=freeq.at/log-analysis;+freeq.at/sig=… TAGMSG #swarm
```

…and a deploy approval is the *same substrate*, different kind:

```
@+freeq.at/act=approval;+freeq.at/act-verb=request;+freeq.at/act-id=01KDEF…;
 +freeq.at/act-to=did:plc:opslead;+freeq.at/act-title=Deploy factory-bot v12;
 +freeq.at/act-ctx-h=sha256:1a…;+freeq.at/sig=… TAGMSG #ops
```

Same `act-id` correlation key, same `act-ref` to link replies, same validator mechanics, same view, same REST shape. The kind is a row in a registry, not a subsystem.

**Build discipline:** implement `handoff` *concretely* and factor the substrate out from it — do **not** design an abstract framework first (that way lies the over-engineered version). Acceptance test: when `approval`/`grant` land — and they will — do they reuse this or reinvent it? Reuse obvious ⇒ shape is right. "handoff" welded into storage/wire ⇒ it isn't.

> **Important caveat on generality:** the substrate generalizes the *plumbing* (wire, validator mechanics, view, REST), **not the policy**. Each `kind` must ship its own **transition table + authorization rules** as a first-class artifact — those differ per kind and are the actual hard design. "handoff is just a verb-set" is true for the plumbing and undersells the policy. (And per the signing section: a kind may add its own `act-*` fields — `grant` will want a scope/resource field on day one — and they're covered by the signature automatically, because the canonical covers whatever is present, not a fixed list.)

## Addressing: DIDs, not nicks

A handoff is addressed to *an identity*, and stays valid until that identity acts on it — maybe from another server, maybe after a reconnect. A nick can't carry that promise. A nick is unique only *per server*, so the same nick on two peers can be two different people, and a cross-server DM to a nick has no well-defined recipient: each receiving server maps it to whoever *it* thinks that is, and the sender never learns which identity actually received it. A DID is globally unique, so it resolves to the same identity everywhere. So directed actions address a DID (`act-to=did:plc:…`), resolved identically on every server. Concretely:

- **DID-addressed delivery is uniform.** Every server applies one rule: deliver to local sessions bound to the target DID **and** relay to peers, who do the same — so a multi-homed DID gets the event on every device, deduped by `msgid`. No per-server interpretation, no collision. This wants **DID targets at the wire level** (`PRIVMSG did:plc:x`, and likewise for the `TAGMSG` an action rides — CHATHISTORY already accepts `did:` targets, so there's precedent), so an agent can address a peer by DID and never has to resolve a nick or reason about a collision.
- **Persistence and validation key off the same DID**, so the sender's own stored copy of a directed action matches what was delivered.
- **Nick DMs still work** (humans type nicks): the sender's server resolves nick→DID *once* at send time and stamps the resolved recipient DID onto the relayed event; receivers honor that stamp rather than re-resolving. The stamp is best-effort — absent for legacy peers or an unresolvable nick (e.g. a guest), receivers fall back to today's nick handling.

> **The stamp is origin-asserted, and DID-keyed persistence raises its stakes.** The stamp is minted by the *sending server*, not the sender — nothing the receiver can cryptographically check. Today's nick handling has spoofing problems too, but they scroll away; once persistence is keyed by DID, a malicious or buggy origin stamping the wrong DID doesn't just misdeliver a line — it writes into the *durable DM history* of two identities who never spoke. So: receivers **verify-when-possible** (if the stamped DID is known locally, cross-check it against local resolution; discrepancy ⇒ log + fall back to nick handling rather than persist under the stamped DID), and the stamp's trust bound is stated plainly: honest-origin, same as the rest of the trust section. **Actions never depend on the stamp**: `act-to` sits inside the *sender-signed* canonical, so the assignee identity is attested by the participant, not the relay. Guests have no durable identity to persist under anyway, and action participants are DIDs by definition, so actions never hit the nick fallback at all.

## Two orthogonal axes

DM-vs-channel conflates two independent knobs. Keep them separate:

- **Assignment** — *who does it.* Carried by `act-to`, which only ever holds a DID:
  - **directed**: `act-to=did:plc:bob` → starts assigned to Bob.
  - **open / claimable**: **no `act-to`** + `act-caps=…` → starts unassigned; any capable agent `claim`s it; first valid claim wins.
- **Visibility** — *where the event is posted.* Carried by the message target, as it always was:
  - **channel**: `TAGMSG #ops` — visible to the room, logged in channel history. An open action's channel *is* its queue.
  - **direct**: `TAGMSG did:plc:bob` — addressed to two DIDs, delivered over the DM layer.

(v0.3 allowed `act-to=#swarm` for open actions, which stuffed a venue into the assignee slot and duplicated the message target — and left "what does `act-to=#a` on a TAGMSG to `#b` mean?" undefined. Gone. `act-to` is an assignee or absent.)

These compose. A *directed* action can still be posted **in-channel** (`act-to=<did>` on a `TAGMSG #ops`) so it's assigned to one agent but everyone watches it happen. An **open direct action** (no `act-to`, DM target) is legal but pointless — there's exactly one other participant to claim it — so implementations may reject it as malformed.

**Channel is the default for multi-agent**, because it gives observability + logging for free (channel history already persists the whole `offer→complete` stream), enables an orchestrator agent to watch/reassign/escalate live, and enables claimable work queues. Direct is the two-participant special case (direct, not private — see the visibility note under Storage).

## Lifecycle & the transition validator

`handoff` verb-set and its rules:

| verb | who may send | precondition |
|---|---|---|
| `offer` | anyone | mints `act-id` |
| `accept` | the addressed DID (directed) | state = offered, before deadline |
| `claim` | any DID matching `act-caps` (open) | state = open; **first valid wins** |
| `decline` | the addressed DID | state = offered |
| `progress` | the assignee | state = assigned |
| `complete` | the assignee | state = assigned |
| `fail` | the assignee | state = assigned |
| `cancel` | the offerer | state = offered/assigned, before complete |

The validator, on each incoming event, **checks the signature first** — and the outcome is three-way, not two:

- **Valid** → look up prior events for `act-id`, check the verb is a legal transition **and** the sender is authorized, then store + route it like any message. Reject otherwise.
- **Invalid** (the canonical rebuilds but the signature doesn't verify against the resolved key, or a covered tag was added/stripped in transit) → **reject**, exactly like an illegal transition. This is evidence of tampering or forgery.
- **Unverifiable** (the canonical rebuilds fine, but the *key can't currently be fetched* — the signer's key-origin server is unreachable) → **defer, don't reject.** Park the event, retry the key lookup with backoff, apply it when the key resolves. A five-minute blip at a third server must not permanently destroy a valid `accept`.

That third branch is the same stall-not-fork stance the rest of the design takes: an outage stalls *ordering*, it never converts into a *verdict*. Deferral rules: the parked queue is bounded per origin (evict oldest, log loudly); a deferred event enters the serializer's ordering **when it verifies, not when it arrived** — so an outage at your key-origin can cost you your place in a race (see Claim semantics), which is a fairness cost we accept and state, not a correctness bug. Note this whole branch is an artifact of the *interim* key-lookup model; DID-document-anchored keys (below) make keys resolvable without any freeq server in the loop, and the defer branch withers to near-dead code.

**Deadline checks tolerate skew.** `act-deadline` is the one wall-clock comparison in the design (everything else signs and orders by ULID). Validators enforce it with an explicit grace window — recommended **±120s** — because federated servers do not have synchronized clocks (we have production scars: a drifted NTT once broke every auth handshake with a 60s window on this very stack). Deadlines are coarse-grained business facts (minutes to days), so the grace window is harmless; anyone using `act-deadline` as a fine-grained lock ordering primitive is misusing it.

**One tie is biased by construction, and that's fine:** the offerer can `cancel` at the same instant the assignee `accept`s, and the serializer that orders them is the offerer's *own origin* — zero hops away. So the offerer reliably wins photo-finishes. We keep it: cancel-biased ties are the safe default (a cancelled task nobody works on beats a task worked on after the offerer withdrew it), and the alternative — a neutral serializer — reintroduces the ownership problem the minting-server rule was chosen to avoid. Owned, not hidden.

### Claim semantics (open/claimable)

`claim` is just a verb with one extra rule: **first valid claim wins, atomically** — which takes one server to order the competing claims. A directed action has its own version of the same problem (the cancel/accept race above), and either way, one authority orders the conflicting events. A federated channel can't be that authority: freeq channel state is symmetric peer-merge, no owner, so two peers would each award a local claim and the task runs twice.

So the serializer is **the server that minted the `act-id`** — the offerer's origin — for every action, directed or open. It's deterministic from the wire (every relayed event names its origin), needs no channel-ownership concept, and stays well-defined when the recipient is multi-homed: a DID logged into several servers has no single home, but an `act-id` has exactly one origin. Transitions relay to it; it emits the authoritative ordering; every other view follows. If it's unreachable, transitions **stall rather than fork** — the correct failure for "first valid wins."

**"First valid" means first *verified*, and honesty requires spelling that out:** the minting server can only award a claim it has verified, and under interim key lookup, verifying claimant B's signature may mean asking B's origin server for the key. So the race is really "first claim whose signature the serializer could check" — a claimant whose key-origin is slow or briefly down loses ground through no fault of their own. Deferred claims (see the validator) enter the ordering at verification time. This is another cost charged to the interim lookup model and another argument for DID-document key anchoring, which takes third-party freeq servers out of the claim path entirely.

## Storage & delivery: ride what already exists

There is **no new inbox/store.** Delivery and durability come from the message layer freeq already has:

- A **channel** action is in channel history; replayed via CHATHISTORY on reconnect.
- A **directed** action rides the DM store (keyed by the two participant DIDs — see Addressing), replayed on reconnect.
- An **open** action lives in the target channel's history, claimable while non-terminal.

Net-new code is two small things, identical whether it's handoff/approval/grant:

1. **A transition validator** (above).
2. **A materialized view** — a read-side index (`act-id → latest state, assignee, caps, deadline`) so you can answer "actions assigned to me" / "open actions I can claim" without scanning the log. **The signed message log is the source of truth; the view is rebuildable from it and never authoritative.**

> **Visibility — what the server can and can't see:** the substrate *depends* on the server reading the `act-*` tags to validate transitions and build the view. So in **every** mode — channel or direct — the server sees the action's existence, both participant DIDs, the title, caps, deadline, and the full state timeline; with freeq-hosted context (the default) it sees the payload too. freeq's E2EE only ever covers a freeform message body, never tags. **A direct action is therefore *direct*, not *private*.** The one thing that *can* be hidden later: the validator only needs `act-id`/verb/DIDs/deadline — never the title or context — so an **encrypted-content mode** (encrypted `act-title`/`act-ctx`, cleartext lifecycle) is possible with no wire change, at the cost of caps-based routing and human-readable audit. What can never be hidden is existence, participants, and timeline. (Same footnote as the trust section: DM prekeys are server-served today, so even that encrypted body holds only against an honest server — one more consumer of the same root-of-trust gap.)

## Context (`act-ctx` / `act-ctx-h`)

The real axis is **not payload size — it's whether the bytes live somewhere freeq commits to keeping.** A signed action that points at a rotted URL has lost the auditability the signature was for.

- **Default: freeq-hosted** context (capability URL), lifecycle tied to the action's retention. Only setup where the audit guarantee holds.
- **External refs** (gist, S3, an AT-Proto record on another PDS) are allowed but **explicitly best-effort**: ref dies, guarantee dies — caller's call.
- **The signature always covers a content hash** (`act-ctx-h`), so whatever you fetch later is checkable against what was signed — tamper-evidence wherever the bytes live, and the only integrity check you get at all for external refs.
- Tiny payloads may be inlined as a convenience; that's not a durability story, just an optimization.

## Signing & canonicalization

⚠️ freeq's current PRIVMSG signing isn't sufficient for a signed action. Its canonical is `{sender_did}\0{target}\0{text}\0{timestamp}` — it assumes a message body (a body-less `TAGMSG` has no `text`) and folds in a wall-clock `timestamp` that's minted at send and never stored or relayed, so a downstream server can't reconstruct it to verify. `act` therefore defines a canonical built to survive federation:

- **Canonical: deterministic JSON (JCS / RFC 8785) over *every* `+freeq.at/act-*` tag present on the message**, keys sorted, plus `act-from`. Not a fixed field list. v0.3 enumerated ten fields, which was secretly handoff-shaped: the first kind needing one more field (`grant` wants a scope/resource on day one) would have forced either a canonical version bump or — worse — *unsigned* kind-specific tags riding a signed action, a tampering surface that quietly defeats the point. Sign-what's-present fixes both, and it's self-policing: **adding** an `act-*` tag in transit changes the receiver's rebuilt canonical (sig fails), and **stripping** one does too (sig fails). Tag add/strip are both detected as invalid, so no separate covered-fields declaration (DKIM's `h=`) is needed — S2S must relay the tags verbatim anyway. (If a future kind genuinely needs a *mutable* tag, that's the moment to introduce an exclusion list — not before.)
- **Sign over the ULID (`act-id`), not a wall-clock timestamp.** A ULID embeds its own creation time, is immutable, and already travels as a first-class tag — so the receiver rebuilds the exact signed bytes rather than re-minting a timestamp it can't match.
- **The sig tag carries algorithm, key-id, signature:** `+freeq.at/sig=ed25519:<kid>:<base64url sig>`, where **`kid` is a truncated hash of the public key** (recommended: first 16 bytes of SHA-256, base64url). A hash-derived kid is self-certifying: whatever key a lookup returns can be checked against the kid, so a key server can't *substitute* a different key for an old signature — the substitution is detectable by construction. (It can still lie at *registration* time about which key belongs to a DID; that's the binding gap in the trust section.)
- **S2S relays the signed tags verbatim** and the **receiver rebuilds the canonical from them — never re-mints.** Since DID and ULID are both already tags, this is far more achievable than retrofitting PRIVMSG.

**This is meant to be freeq's signing model, not an `act`-only special case.** The same weakness — a signed wall-clock timestamp that never crosses S2S — means **PRIVMSG signatures don't survive federation today either**: a receiver can't rebuild the canonical, so it can't actually check the sig — the 🔒 a federated client shows just means a signature is attached, not that anyone verified it. `act` gets the fix first because it's greenfield (no deployed clients signing the old way, no stored history to keep verifiable) and because non-repudiation is load-bearing for a durable action, where on an ephemeral chat line it's near-cosmetic. But there's no principled reason chat stays on the old path: sign a hash of the freeform body, sign the **wire** bytes (ciphertext when E2EE, so encryption and verification stay orthogonal), and carry the signed fields verbatim over S2S. This RFC proposes that **all message signing — PRIVMSG included — should eventually migrate onto this canonical**, as follow-on work. The end state we're arguing for is one signing path, not two; `act` just proves it first.

### The harder problem: key existence + key lookup

Reconstructing the signed bytes is only half of verification; you also need **the public key that made the sig**, and today that key doesn't survive. Two problems compound:

- **Keys are per-session and overwritten.** Clients mint a fresh ed25519 keypair each session and register it (`MSGSIG`); the key store keeps one key per DID and *overwrites* on re-register. So the moment a signer reconnects, every signature from a prior session becomes unverifiable. Chat tolerates this; actions are *specifically* long-lived, so "verify an offer signed in a session that has since ended" is the **normal** case, and the current model can't do it at all.
- **Even a retained key has to be *findable*.** A verifier needs to know who to ask.

The fix is two matching parts — and as of v0.4 the sequencing is **decided** (was an open question):

1. **Key existence** — the key store becomes **append-only** (history, not overwrite), keyed by `(DID, kid)`, so the exact key that signed always resolves. The `kid` in the sig tag is hash-derived (above), so a resolved key is checkable against the signature that named it.
2. **Key lookup — ship the origin-server path now, anchor in DID documents next.** Interim: sessions register keys where they lived, every relayed event names its origin, so the lookup is `(origin, DID, kid)` — no new "home server" concept. The costs, plainly: verification is hostage to that origin being **reachable** (hence the validator's *defer* branch — outage means *not yet verifiable*, never *rejected*) and **honest at registration time** (the hash-kid stops retroactive key substitution, but not a lie about the original DID↔key binding). The real answer is DID-document anchoring (next section): a key resolvable from the DID alone removes the origin server from verification, from the defer branch, and from the claim race all at once. The kid is in the sig format from day one specifically so the wire doesn't change when the lookup authority moves.

## Trust & non-repudiation — today vs goal

Stated plainly so nobody over-reads the guarantee:

- **Canonicalization makes the signature *reconstructable*, not *trustless*.**
- The **DID↔signing-key binding is unattested today.** `MSGSIG` registers a bare ed25519 pubkey, and the server is the one publishing per-DID keys (`/api/v1/signing-keys/{did}` is local, server-controlled). A malicious server could publish its own key as yours and forge. The hash-derived `kid` narrows this — a key server can no longer *swap* keys under an existing signature without detection — but it cannot attest the original binding.
- The **nick→DID stamp** on cross-server DMs sits under the same bound (see Addressing): origin-asserted, unauthenticated, and now feeding a durable DID-keyed store — which is why receivers cross-check it when they can and actions carry the assignee inside the signed canonical instead of relying on it.
- **Net: non-repudiation holds against an *honest origin server*, not a malicious one** — until key distribution is server-independent.
- **Goal / path to real E2E non-repudiation:** anchor the signing key in the **DID document** (attest the ed25519 key via the AT-Proto identity — did:plc/did:web), so any party verifies the key independently of the freeq server. This is the same root-of-trust gap the broader "identity = DID, never the server's say-so" work cares about, and it's also what retires the defer branch, the claim-race latency asymmetry, and the origin-reachability dependence in one move. It's a prerequisite for trustworthy cross-server claimable queues and for verifiable long-lived actions generally.

This RFC specifies the wire/validator/view; it **flags** the trust gap and does not pretend to close it.

## Capabilities (`act-caps`)

Freeform, and **the server never interprets them** (it can't verify an agent really does `web-search` anyway). Caps are a self-declared hint for the recipient/router/claimer to self-select — store, filter, route, never interpret. Fuzzy/semantic matching belongs in the agents.

- No protocol-baked capability registry (it'd be stale in months and a governance chore).
- The one convention worth fixing now is **namespacing** — reverse-DNS / AT-style (`freeq.at/web-search`) — with meanings converging socially. Reserve well-known names later if needed; starting loose costs nothing.

## Liveness, backpressure, retention

Modeling actions as messages in the existing store dissolves most of this:

- **Flooding** — offers are messages, already under freeq's flood throttle + per-IP/connection limits. No new quota machinery.
- **Storage growth** — same message/DM/channel store under existing retention. The view stays small by construction (indexes only non-terminal actions) and is rebuildable.
- **The one genuinely new policy is liveness, not storage:** an action stuck in `accepted/progress` that never reaches a terminal state. `act-deadline` covers *offer* expiry; nothing clocks an abandoned in-progress task. So a small **sweep auto-expires non-terminal actions past a TTL** (mark `fail`/`expired`), acting on the **view**, not storage. The sweep is owned by the action's serializer (its `act-id`-minting server) and broadcast as a normal terminal event, so peers garbage-collect their views by relay rather than each computing expiry locally.

### Orphaned actions: when the sweeper is the casualty

v0.3 left a hole here: the TTL sweep exists to handle abandoned actions, and it's owned by the minting server — which is also the single authority whose *permanent* death is the main way actions get abandoned. If the origin dies for good, its actions freeze **and the janitor died with them**. Left implicit, every implementation would invent its own incompatible cleanup. So v0.4 specs it:

- **Peers may mark an action `orphaned` in their local view** once its minting server has been unreachable past an orphan TTL (recommended: 24h, configurable). `orphaned` is a **view-only, non-authoritative, reversible** annotation — it is *never* emitted as a lifecycle event, never relayed, and never enters the signed log. It exists so views can stop advertising claimable/assigned work whose authority is gone, and so REST clients see honest state (`state=orphaned`) instead of a forever-fresh `offered`.
- **If the origin returns, authority resumes and the annotation dissolves:** the origin's authoritative ordering (including any sweep events it emits on catch-up) replaces the local marking. Stall, not fork — the annotation never made anyone an authority.
- **Done work is recorded even when it can't be ordered.** An assignee who finishes while the origin is down still emits its signed `complete` — it's a message, it lands in channel/DM history and relays like any other, it just isn't *authoritative* until the origin orders it. The signed log and the ordering authority are separate things: **an outage stalls ordering; it never loses the record.** Peers' views may display such an event as `complete (unconfirmed)`. When the origin returns, it processes the queued/replayed transitions and confirms; if it never returns, the signed, timestamped `complete` in the log is still the audit trail a human or orchestrator needs to settle the question out-of-band. Done-but-unrecordable would have been the nastiest state in the system; done-but-not-yet-ordered is merely annoying.

## Federation

Action events propagate over S2S like any tagged message, preserving `act-id`, all `act-*` tags, and `sig`. A directed action to a DID on a remote server routes to that DID's sessions (see Addressing); the **`act-id`-minting server owns claim serialization and TTL expiry** for that action. Receivers **rebuild and verify** the canonical from the relayed tags before applying it (see Signing) — deferring, not rejecting, when the key is temporarily unfetchable — so cross-server verification and cross-server claimable both remain gated on the key-store + trust work.

## REST query interface (over the view)

A query surface over the materialized view — *not* a parallel table that owns data — so non-IRC agents and interop bridges can use it:

- `GET /api/v1/actions?kind=&to=&state=&caps=` — my inbox / claimable queue (`state=orphaned` included, so clients see honest liveness)
- `GET /api/v1/actions/{act-id}` — current state + context ref + event log (unconfirmed events flagged)
- `POST /api/v1/actions` — emit an `offer`/`request`
- `POST /api/v1/actions/{act-id}/{verb}` — a transition

This shape maps cleanly onto AIRC-style `POST /messages` + payloads, so an interop bridge is a thin adapter.

## Orchestration pattern (why channel-default matters)

Put a supervisor/orchestrator agent in the channel. It watches the live `act-*` event stream and can reassign a stalled task, enforce deadlines, fan work out, or escalate an open queue — including noticing `orphaned` actions and re-offering them under a fresh `act-id` on a live server. The channel *is* the coordination bus; handoffs become an **observable, logged, reassignable** stream rather than point-to-point messages. CHATHISTORY gives you the audit log for free.

## What's actually new to build

1. The `act-*` tag set + `freeq.at/act` CAP + TAGMSG handling.
2. A **transition validator** — per-kind transition table + authz, **with three-way signature checking as its first gate** (valid / invalid-reject / unverifiable-**defer**), a bounded defer queue with retry, and a **±120s skew grace** on deadline checks; for open actions this includes **claim serialization at the `act-id`-minting server** — claims route to it, it atomically assigns (in verification order) and rejects the rest.
3. A **materialized view** + the REST query interface + reconnect replay (reusing CHATHISTORY/DM replay), including the **`orphaned` local annotation** and unconfirmed-event flagging.
4. A **liveness sweep** for non-terminal actions past TTL, owned by the `act-id`-minting server, plus the peer-side orphan TTL.
5. The **new canonical — JCS over all `act-*` tags present, signed over the ULID** — and S2S relaying the signed tags verbatim.
6. **A durable signing-key model** — hash-derived `kid` in the sig tag, an append-only per-DID key history (never overwrite), origin-server lookup `(origin, DID, kid)` now, DID-document anchoring as the follow-on.
7. **DID-native addressing** — DID targets at the wire level, and the resolve-once-at-sender-and-stamp path for nick DMs, with receiver-side cross-checking of the (unauthenticated) stamp.

Everything else (delivery transport, durability, identity, msgid, flood limits, federation transport) is reuse.

## Non-goals

- Not a workflow engine / DAG executor — it's a transfer + state primitive; orchestration lives above it.
- Not a replacement for chat — actions are *tracked* units, not conversation.
- Not re-doing identity — it rides whatever identity the server already verifies (AT-Proto DIDs).
- Not (yet) solving server-independent key distribution — flagged, sequenced (origin-server lookup now, DID-doc anchoring next), but not closed here.

## Decided in v0.4

Four of v0.3's open questions, closed:

- **Substrate now, or handoff-first?** → **Handoff-first, factor the substrate out.** The acceptance test ("does `approval` reuse it or reinvent it?") is the forcing function. The one thing pulled forward is the wire decision that would have been expensive to retrofit: sign-what's-present replaces the fixed canonical field set *now*.
- **Key lookup (a) origin-server vs (b) DID-document?** → **Ship (a) now, with the hash-derived `kid` in the sig from day one; migrate to (b).** (a) makes signatures mean something immediately; the kid means the wire doesn't change when the authority moves; (b) retires the defer branch, the claim-latency asymmetry, and the reachability dependence.
- **Claim fairness beyond first-wins?** → **Keep it dumb.** Bidding, priority, and capability scoring are orchestrator policy, per the substrate/policy split: the substrate generalizes plumbing, not policy. An orchestrator that wants an auction runs one *above* the primitive and then issues a directed offer.
- **Minting-server outage: stall, or hand authority to the assignee's server at `accept`?** → **Stall rather than fork, kept.** A mid-lifecycle authority handoff is a new distributed-systems problem grafted on to avoid an old one already accepted everywhere else in the stack. The orphan annotation + recorded-but-unordered terminal events (see Liveness) make the stall survivable without making anyone a second authority.

## Open questions

- **Per-kind authz spec format** — how do we declare each kind's transition table + rules so it's reviewable and not ad-hoc? (A table like handoff's, checked in as data the validator loads, is the current hunch.)
- **Defer-queue and orphan parameters** — bounds, backoff curve, orphan TTL default. Numbers above are recommendations; operational experience should set them before anything freezes.
- **The encrypted-content mode** — encrypted `act-title`/`act-ctx` with cleartext lifecycle needs no wire change, but when is it worth the loss of caps-routing and readable audit?
- **External context refs** — allow AT-Proto records as a first-class (best-effort) ref type, or discourage entirely?
- **WG venue** — keep `+freeq.at/*` until the trust pieces are solid, then pitch IRCv3 WG? (Design the wire to be de-vendorable now regardless.)

---

*Feedback welcome — comment on the gist, or find me on freeq (`irc.freeq.at`) / Bluesky.*
