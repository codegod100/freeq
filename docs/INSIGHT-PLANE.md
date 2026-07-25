# The Insight Plane — pluggable, provider-run enrichment for freeq

Status: **DRAFT / thinking artifact** (2026-07-19). Nothing here is committed.
This doc proposes an architecture; §9 is a phased reference-implementation plan.

---

## 1. What this is (and is not)

**Idea.** Some channels/servers want *derived* metadata that plain IRC never
carries — ML-mined **channel topics**, an **n-dimensional similarity map**
("if you like #rust you might like #zig"), and **people affinity** ("you and
this person overlap"). This unlocks composable features: discovery, "related
channels," and app-level constructs like a quest game that needs to know which
channels are *related* to send you to.

**The key decision: this is NOT in the protocol.** Mining is a *derived,
out-of-band layer* produced by **providers** (agents/services) the server
operator chooses to run. The wire protocol and message semantics never change.
freeq stays freeq (permissionless IRC + AT identity); insight is an **add-on**.

**Non-goals**
- No new wire verbs, no message-format changes, no server-side ML.
- Not mandatory: a server with zero providers behaves exactly as today.
- Not a surveillance system: see §6. Encrypted content is opaque by design.

**Why an architecture doc first:** the *value* is a **standard record format**
so providers are interchangeable and apps are provider-agnostic — that's the
"protocol for the information" that also enables a commercial market (§7).

---

## 2. Substrate — reuse what already exists

freeq already ships everything the insight plane needs. We add a **schema
convention + a provider role**, not new plumbing.

| Need | Existing primitive |
|---|---|
| A signed, DID-attributed, channel-scoped, ordered, typed record store | **`coordination_events`** (`event_id` ULID, `event_type`, `actor_did`, `channel`, `ref_id`, `payload_json`, `signature`, `timestamp`) |
| Publish a record | `PRIVMSG/TAGMSG` with `+freeq.at/event=<type>` → `store_coordination_event` (already DID-attributed + signable) |
| Read/query records | `GET /api/v1/channels/{name}/events?event_type=&ref_id=&actor=&since=&limit=` → `query_coordination_events` |
| Who is a provider / provenance | **`agent_manifests`** (`registered_by`), `/api/v1/agents/manifests` |
| Authorize a provider | `agent_capability_grants` (+ policy framework) |
| Read observable channel data to mine | `CHATHISTORY`, `/api/v1/channels/{name}/history`, `/api/v1/search` |
| Per-actor surface (people metadata) | `ref_id` = a DID; `/api/v1/actors/{did}` |
| Federate (or not) | S2S `relay_coordination_tags` already rides app coordination tags |
| Billing hook (commercial) | `agent_spend`, `channel_budgets` |

**Consequence:** an "insight record" is just a `coordination_event` whose
`event_type` is `freeq.insight/<kind>@vN`, whose `actor_did` is the provider,
whose `payload_json` is a standard schema, and whose `signature` proves the
provider made the claim. Provenance and trust fall out for free (this directly
answers the "who created this bot / can we trust it" problem — every insight
is signed by a named DID you can choose to trust or ignore).

---

## 3. Three roles

```
  observable data              standard signed records            apps
  ┌──────────────┐   read     ┌───────────────────────┐  read   ┌───────────┐
  │ public chans │──────────▶ │  PRODUCER (provider)   │────────▶│ coordination
  │ CHATHISTORY  │            │  reads → embeds → labels│  publish│  _events   │
  │ /search      │            │  → clusters → publishes │────────▶│ (the store)│
  └──────────────┘            └───────────────────────┘         └─────┬─────┘
                                                                       │ read
                                                        ┌──────────────▼───────────────┐
                                                        │ CONSUMER (web/app/quest game) │
                                                        │ GET events?event_type=…       │
                                                        │ or SDK client.getInsights()   │
                                                        └───────────────────────────────┘
```

1. **Producers (providers).** External agents (SDK/bot-kit) with a registered
   manifest and a `freeq.insight.publish` capability. They read *observable*
   channel data, compute embeddings/labels/clusters, and publish signed insight
   records. **Pluggable:** the operator enables 0..N providers; multiple can
   coexist and compete (different models/quality). This is the "pluggable
   system … specific plugins up to the provider."

2. **The record standard.** A small, versioned set of namespaced schemas (§4).
   This is the interoperability contract: any provider that emits `channel.
   topics@v1` is a drop-in for any other, and any consumer reads them the same.

3. **Consumers.** Clients/apps read records via the events REST endpoint
   (filtered by `event_type`) or a thin SDK helper. They pick which provider
   (`actor` filter) to trust. The quest game reads `channel.neighbors` to pick
   quest targets.

---

## 4. The record standard (finite surface)

The surface is deliberately small and finite — **channel**, **actor**, and
**edge** — versioned (`@v1`) so it can evolve without breaking consumers.

### 4.1 `freeq.insight/channel.topics@v1` (channel-scoped)
```jsonc
{
  "schema": "freeq.insight/channel.topics@v1",
  "channel": "#rust",
  "labels": [ {"term": "async runtimes", "weight": 0.82},
              {"term": "borrow checker", "weight": 0.61} ],
  "embedding": { "model": "nomic-embed-text-v1.5", "dim": 768,
                 "vector_ref": "blob:sha256:…" },   // vector stored as blob, not inline
  "window": { "from": 1784300000, "to": 1784400000, "messages": 512 },
  "method": "bertopic|nmf|llm-label",
  "produced_at": 1784400123
}
```

### 4.2 `freeq.insight/channel.neighbors@v1` (channel-scoped)
```jsonc
{
  "schema": "freeq.insight/channel.neighbors@v1",
  "channel": "#rust",
  "neighbors": [ {"channel": "#zig",  "score": 0.91, "why": ["systems", "wasm"]},
                 {"channel": "#embedded", "score": 0.77} ],
  "space": "nomic-embed-text-v1.5",   // which embedding space these came from
  "produced_at": 1784400130
}
```

### 4.3 `freeq.insight/actor.affinity@v1` (actor-scoped, `ref_id = <did>`, **opt-in only**)
```jsonc
{
  "schema": "freeq.insight/actor.affinity@v1",
  "subject": "did:plc:…",              // the person (must have consented)
  "consent_ref": "01K…",               // ULID of the subject's signed consent event
  "interests": [ {"term": "distributed systems", "weight": 0.7} ],
  "similar_actors": [ {"did": "did:plc:…", "score": 0.83} ],  // k-anonymity gated
  "basis": "public-channel-cooccurrence",  // NEVER private message content
  "produced_at": 1784400140
}
```

### 4.4 Control records (any subject)
- `freeq.insight/opt-out@v1` — a channel op or a DID revokes indexing; providers
  MUST stop and tombstone existing records for that subject.
- `freeq.insight/consent@v1` — a DID grants `actor.*` mining of themselves.

Conventions: vectors go in the **blob store** (`/api/v1/blob`) referenced by
hash, never inline (keeps events small, dedups, lets consumers fetch on demand).
Records are **signed** by the provider DID; consumers verify via `/api/v1/signing-keys/{did}`.

---

## 5. Trust & provenance

Because every record is a signed `coordination_event`:
- **Attribution:** you always know *which provider* made a claim (`actor_did`).
- **Verifiability:** the signature proves it (reuse existing MSGSIG/verify).
- **Provider choice:** consumers filter by `actor` — trust provider A, ignore B.
- **Competition:** two providers can both label `#rust`; the app/user picks.

This is the same trust model as the rest of freeq (DID + signature), so the
"is this bot legit?" question has a real answer here: an insight is only as
trusted as the named, manifest-registered DID that signed it.

---

## 6. Privacy — the crux (defaults must be safe)

1. **You cannot mine what you cannot see.** E2EE channels (ENC1/ENC3) and DMs
   are ciphertext to a provider by construction — **inherently excluded**. This
   is the strongest guarantee and it's free.
2. **Opt-in per channel.** A channel is indexable only if it is public
   (not `+s`/`+i`/`+k`) **and** the operator/policy has enabled indexing
   (a `freeq.insight/opt-out` absence + an explicit allow, or a `+insight`
   channel mode). Private channels default **off**.
3. **People metadata is strictly opt-in + self-consented.** `actor.affinity`
   about a DID requires a signed `consent@v1` from *that* DID. Never
   auto-profile individuals. Ship channel-level first; actor-level last.
4. **Aggregate, don't surveil.** Similarity derives from *public channel
   co-membership / topic overlap*, not message content. Apply **k-anonymity**
   thresholds (no edges for tiny groups) and store **labels/vectors, not raw
   text**.
5. **Transparency + erasure.** Records are queryable and DID-attributed, so a
   subject can *see* what's claimed and publish `opt-out@v1` to force deletion
   (tombstone). Providers MUST honor opt-out.
6. **Retention/minimization.** TTL on records; no raw-text retention;
   vectors are hashes/blobs, prunable.

A conservative default profile: **channel topics + neighbors for public,
opted-in channels only; no actor mining unless the person consents.**

---

## 7. Pluggability & the commercial model

- The **server operator** decides which providers run (capability grant). One
  operator runs a free local provider; another buys a premium provider with a
  curated taxonomy or cross-server graph. Same standard records either way.
- Because the **record schema is standard**, a provider is a *value-added
  service*: better embeddings, richer labels, a global similarity graph across
  federated servers. Apps consume via the standard interface, provider-agnostic.
- `agent_spend`/`channel_budgets` give a metering hook if a provider wants to
  charge per index/query. This is the "commercial opportunity … protocol for
  the information is standard, different ways to provide it."

---

## 7a. Where server changes are justified (compute out, index in)

The external provider is the golden approach for **production (the ML)** — but
server changes are the right call for **general primitives that speed up every
provider**. The discriminator:

> Does the change help **any** provider's output (general infra), or encode
> **one** plugin's domain logic?
> General (index, fast query, streaming ingest, storage) → **server**.
> Specific (embedding model, taxonomy, clustering) → **provider**.

| Concern | Where | Why |
|---|---|---|
| Embeddings / labeling / clustering | **Provider (out-of-proc)** | No ML deps in the IRC server (memory, crash blast-radius); keeps it pluggable + a market. |
| Store signed records | **Server (exists)** | `coordination_events`, no change. |
| **Fast neighbor / similarity query** | **Server (new, general)** | The optimization: an in-process index over the *standard* records + a `/neighbors` endpoint beats "fetch all embeddings, cosine client-side". Understands the schema, not a provider. |
| Live ingest feed | **Server (exists)** | Bots already get the live stream over the SDK; no polling. |

**Rule:** providers compute + publish signed records; the server **indexes the
standard records** and serves fast reads. The server owns *the standard + the
index* ("what makes freeq freeq"); operators own *the providers* ("specific
plugins up to the provider").

**Deferred (Phase 5, not now):** a full in-process **server-plugin ABI**
(WASM/dynamic hooks for operator-custom logic). Powerful but a large, risky
surface (sandboxing/stability/versioning); the index+query primitive already
delivers the optimization, so we don't need it for topics/neighbors/affinity.

## 8. Federation

Insight records are `coordination_events`; `relay_coordination_tags` already
lets app coordination ride S2S. Two modes (operator choice):
- **Local:** insight stays on the origin server (default; simplest privacy story).
- **Federated:** providers publish network-wide, enabling a **cross-server
  similarity map** ("channels like #rust *anywhere on the network*"). Gated by
  the same opt-in rules per channel.

---

## 9. Reference implementation — phased

Smallest-useful-first, matching the repo philosophy ("if it feels too clever,
it's wrong"). Each phase is independently shippable and reversible.

- **Phase 0 — the standard.** This doc + JSON Schemas for the record kinds in
  `docs/schemas/insight/`. No code. (Lets other apps target it immediately.)

- **Phase 1 — `channel.topics` provider + read path** *(the composable primitive)*.
  - `freeq-insight` bot (Rust SDK or `@freeq/bot-kit`): reads public, opted-in
    channels via CHATHISTORY/REST; embeds with a **local model** (this box has
    Ollama/MLX — `nomic-embed-text` for embeddings, a small LLM or NMF for
    labels — see the `local-llm` skill); publishes `channel.topics@v1`.
  - Consume: `GET /api/v1/channels/{name}/events?event_type=freeq.insight/channel.topics@v1`
    plus an SDK helper `client.getChannelTopics(channel)`.
  - **This alone answers the quest question** partially: a channel now has
    machine-readable topics.

- **Phase 2 — `channel.neighbors` + the server-side index (the optimization).**
  - *Provider (out-of-proc):* pairwise cosine over channel embeddings → top-k
    → publishes `channel.neighbors@v1`.
  - *Server (new, general — per §7a):* a small **in-process index** over the
    standard insight records (topics/neighbors, and later a vector index for
    ad-hoc nearest-channel queries), served via `GET /api/v1/channels/{name}/neighbors`
    and an `INSIGHT <channel>` IRC command; `client.getRelatedChannels(channel)`.
    General infra (understands the schema, not any provider); this is where the
    server change earns its keep on read latency.
  - **Quest game unlock:** "quest = visit a related channel and come back" now
    has a real, fast target list (`getRelatedChannels("#rust")`).

- **Phase 3 — `actor.affinity` (opt-in, hardest privacy).**
  - Consent flow (`consent@v1`), co-membership/topic-overlap affinity,
    k-anonymity, opt-out honoring. Only after 1–2 are solid.

Deliberately deferred: cross-server federated graph (Phase 4), premium/metered
providers (Phase 5).

---

## 10. Composability example (the quest game)

```
// today: how do I know which channels a quest should point at? → you don't.
// with the insight plane:
const related = await client.getRelatedChannels("#rust");   // channel.neighbors@v1
quest.addObjective(`Visit ${related[0].channel}, then return to #rust`);
// topics also drive quest *flavor*:
const topics = await client.getChannelTopics(related[0].channel);
quest.describe(`They talk a lot about ${topics.labels[0].term} over there…`);
```
The game never knows about ML; it reads a standard, signed record. Any other
app (discovery sidebar, "similar people" panel, onboarding) reads the same.

---

## 11. Open questions (don't commit yet)

- **Vector storage:** blob-by-hash (proposed) vs a dedicated vector column/table
  vs external vector DB. Blob keeps the core clean; revisit if query needs grow.
- **Recompute cadence & freshness:** event `window` + TTL vs streaming updates.
- **Channel mode vs policy-framework** for opt-in — which is the right knob?
- **k-anonymity thresholds** for actor edges — pick concrete numbers with a
  privacy review before Phase 3.
- **Who runs the default provider** on `irc.freeq.at`, and under what capability?
- **Federated identity of providers** across servers (one DID, many servers?).

---

## 12. One-paragraph recommendation

Build the insight plane as a **schema convention + provider role on top of the
existing `coordination_events` log** — signed, DID-attributed, capability-gated,
never in the wire protocol. Ship **Phase 1 (`channel.topics`)** first as the
composable primitive, then **Phase 2 (`channel.neighbors`)** to light up the
similarity map and the quest use case, and treat **actor affinity** as a
separate, consent-gated Phase 3. Encrypted channels are excluded for free;
public channels are opt-in. The standard record format is the durable asset —
it's what makes providers interchangeable and a value-added-service market
possible.
