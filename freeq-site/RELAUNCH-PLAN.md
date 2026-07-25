# freeq.at Relaunch Plan — "The room where humans and agents work"

Status: PROPOSED (2026-07-23)
Owner: site relaunch
Scope: positioning, homepage redesign, docs restructure, imagery, demos, launch.

---

## 1. Diagnosis — what the current site does and doesn't do

The live site (freeq.at, `380e651`) is clean, honest, and *small*. It sells
**"IRC, rebuilt with identity"** — the 2024 story. Sign in with Bluesky, DID
owns your nick, standard clients still work. All true, all table stakes.

What the repo actually contains in mid-2026, and the site barely whispers:

| Capability | On the site today? |
|---|---|
| **Agent-native protocol** — did:key auth, task cards, pause/resume/revoke, provenance, heartbeats, spawning (5 phases, shipped) | One card that says "Bots. LLM personas in 50 lines." |
| **AV sessions** — voice/video calls as IRC TAGMSGs + MoQ SFU; *agents can join calls and speak* | Not mentioned at all |
| **Signed messages by default** — per-session ed25519, verifiable at REST endpoints | Not mentioned |
| **E2EE** — X3DH + Double Ratchet DMs, passphrase channels | Buried in docs |
| **Policy system** — verifiable-credential gates, custom verifiers, signed auditable decisions | One card, undersold as "moderation" |
| **CRDT federation** — Automerge convergence over iroh QUIC | One card, no diagram |
| **P2P** — iroh direct DMs where possible | Not mentioned |
| **Six clients** — native macOS, iOS, Android, Windows (WinUI), web, TUI | Lists four, calls the desktop app "Tauri" (it's native AppKit/SwiftUI now) |
| **Two agent SDKs** — `@freeq/bot-kit` (TS), `freeq-agent-kit` (Rust) + Claude/pi skills | "Rust SDK" only |
| **IRCv3 modernization** — msgid, chathistory, editing, deletion, reactions, pins, search, read markers, multiline, `+freeq.at/*` tag namespace, ATPROTO-CHALLENGE SASL | A single bullet |

**The core problem is positioning, not polish.** "Identity for IRC" answers a
question nobody in Silicon Valley is asking. The question they *are* asking,
daily, in 2026: *"my agents are black boxes — how do I watch them, coordinate
them, trust them, and pull the plug?"* freeq has a complete, shipped,
protocol-level answer, and the homepage doesn't say so.

---

## 2. Positioning

### One-liner

> **freeq — the room where humans and agents work.**

Alternates for testing: "Chat infrastructure for the agent era." /
"Give your agents a room, an identity, and rules." / "One protocol.
Humans, agents, voice."

### The narrative (the HN comment we want people to write for us)

Every agent framework gives you an SDK and a black box. freeq gives you a
**shared, observable room**: your agents authenticate with ed25519 DIDs, every
action is a signed message in a channel, coordination is typed events humans
can read, and governance is built in — pause, resume, revoke, TTL-bound
capabilities — from *any* IRC client, including irssi over SSH from your
phone. Agents join voice calls and talk. Humans sign in with Bluesky. Servers
federate over QUIC with CRDT convergence. And a 1999 IRC client still
connects, because it's still IRC.

**The kicker that earns engineering respect:** none of this forked the
protocol. It's IRCv3 message tags + a documented `+freeq.at/*` namespace + one
new SASL mechanism. The whole modernization is an *extension*, not a schism.

### Pitch architecture — five pillars, in this order

1. **Agent-native** *(the hook)* — identity (did:key), observability (rooms,
   task cards), governance (pause/revoke/TTL, approvals), provenance +
   liveness. Two SDKs. Claude Code/pi skills exist today.
2. **Trust all the way down** — humans via Bluesky OAuth (keys never leave
   device), agents via did:key; every message signed; channel policies as
   verifiable credentials with signed, auditable decisions; E2EE DMs.
3. **Sessions & voice** — calls are channel metadata (TAGMSG signaling, MoQ
   media). Drift in and out. Agents participate. AV is the *first* session
   type, not the last.
4. **Protocol, not product** — IRCv3 extensions documented like RFCs; CRDT
   federation over iroh; P2P where possible; single Rust binary self-host;
   irssi/WeeChat work unchanged. No walled garden, definitionally.
5. **Craft** — six clients (native macOS, iOS, Android, Windows, web, TUI),
   Rust server, 400+ server tests, real security audits in the repo.

### Anti-positioning (say it explicitly; devs trust products that draw lines)

- Not a Slack replacement pitch — it's *infrastructure*.
- Not a crypto/token thing — DIDs are identifiers, not assets.
- Not another agent framework — your agent keeps its brain; freeq is where it
  shows up to work.

---

## 3. Audience & channels

**Primary:** SV/startup engineers building or operating agents (Claude Code,
Codex, pi, custom LLM stacks). They evaluate in one sitting: land → run a
copy-paste command → see something alive → star/join.

**Secondary:** protocol/infra nerds (Rust, local-first, CRDT, Bluesky/atproto
community — who are *literally the identity provider*, a distribution gift),
IRC diaspora, self-hosters.

**Channels:** HN (Show HN + technical deep-dives), lobste.rs, Bluesky (native
audience), X, r/rust + r/selfhosted, atproto community calls, agent-eng
newsletters/podcasts. Bluesky is special: every freeq login is an atproto
flex — court that community hard.

---

## 4. Site information architecture

```
freeq.at
├── /               Homepage (rewritten — see §5)
├── /agents/        NEW · the agent pitch page (the ad for the hook)
├── /protocol/      NEW · the engineering flex page (specs index, diagrams)
├── /clients/       NEW · six clients, real screenshots, download/connect
├── /connect/       (keep) quick-connect matrix
├── /sdk/           Expand: Rust SDK + @freeq/bot-kit + agent-kit + skills
├── /about/         (keep, refresh components table)
├── /blog/          NEW · launch series lives here (see §9)
└── /docs/          Restructured (see §7)
```

Keep Flask + markdown. No framework change needed — speed of iteration
matters more than the stack. Add OG images per page (see §6).

---

## 5. Homepage redesign (section-by-section)

Keep the terminal aesthetic — black, mono, cyan/pink. It *is* the brand and
it reads "engineer-made." Elevate it with real product imagery and one live
element. Kill emoji icons (🌐🖥📱) — they read hobby-project; replace with
line-art glyphs or real screenshots.

### 5.1 Hero

```
freeq
The room where humans and agents work.

IRC, rebuilt for 2026: cryptographic identity for every participant —
people via Bluesky, agents via did:key. Signed messages. Verifiable
channel policies. Voice calls agents can join. CRDT federation. E2EE.
And your 1999 IRC client still connects.

[ Open the web client ]  [ Give an agent a room → ]      (two CTAs, two audiences)

$ npx @freeq/bot-kit create my-agent && my-agent join '#playground'
  ← one copy-paste line under the CTAs, terminal-styled, with a copy button
```

### 5.2 The money shot (directly under hero)

One wide image/animation: **the macOS client showing a channel where a human,
an agent (verified badge, task card rendering), and an active voice call grid
coexist** — with an irssi window showing *the same channel as plain text*
beside it. That one frame states the entire thesis: modern + agents + voice,
and it's still IRC. (Imagery spec in §6.)

### 5.3 "Agents are first-class" section

Three-step mini-demo with real code (from bot-kit README, kept honest):

1. **Identity** — `FreeqBot.create({ name })` mints a did:key; the server has
   never seen it; it authenticates via SASL. No API tokens.
2. **Work in the open** — agent emits task lifecycle events; humans see cards
   in modern clients, plain text in irssi.
3. **Governance** — `/pause my-agent` from any client. TTL capabilities.
   Provenance manifest. Signed heartbeats — no ghost agents.

CTA → /agents/ and /docs/agents/.

### 5.4 "Trust all the way down" section

Four tight rows with glyphs, not cards: Bluesky OAuth for humans · ed25519
signed messages (with `curl` verify example) · policy credentials with signed
decisions · E2EE DMs (X3DH/Double Ratchet). CTA → /protocol/.

### 5.5 "Voice is part of the protocol" section

Call-grid screenshot + the four TAGMSG lines that start a call. Copy: "A call
is channel metadata. Any client sees it; modern clients join it; agents can
too." CTA → /docs/av-protocol/.

### 5.6 "Six clients, one protocol" section

Real screenshots in a row: macOS, iOS, Android, Windows, web, TUI — plus an
irssi screenshot labeled "and yours." Replaces the emoji platform grid.

### 5.7 "Protocol, not product" section

The engineering-flex checklist (rewrite of the current table, tightened):
IRCv3 extensions list, ATPROTO-CHALLENGE, `+freeq.at/*` namespace doc link,
iroh QUIC federation + Automerge CRDT, P2P DMs, single-binary self-host,
MIT. CTA → /protocol/ and /docs/self-hosting/.

### 5.8 Footer

Keep credits bar (iroh, Automerge, Blue Yard, Miren). Add: join `#freeq`,
Bluesky, GitHub, RSS for /blog/.

---

## 6. Imagery & design assets to produce

| Asset | Purpose | Notes |
|---|---|---|
| **Hero composite** — macOS client (channel + agent card + call grid) beside irssi showing same channel | §5.2 money shot | Stage in #demo channel with 2 humans + 1 agent + live call; screenshot both clients; composite on black. Optional: 15s screen recording → muted looping video |
| Six client screenshots (consistent channel/content) | /clients/ + §5.6 | Same conversation staged in all six for visual rhyme |
| **Architecture diagram** — clients → server (policy/session/persistence) → federation (iroh+CRDT) → atproto identity plane | /protocol/ | Dark-bg SVG, mono labels, cyan/pink accents; draw once, reuse in docs |
| **Agent lifecycle diagram** — mint key → SASL → announce → task events → pause/revoke | /agents/ | Same style |
| Terminal GIF/asciinema — `npx @freeq/bot-kit …` agent joins + first task card | §5.3, README | asciinema + agg to GIF; also embed in GitHub README |
| OG images per page | link unfurls on Bluesky/X/Slack | Generate from a template (black, logo, page title, one accent line) |
| Favicon/logo | keep | Already good |

Style rules: black backgrounds only, SF-Mono-family text in images, cyan for
humans, pink for agents (consistent color-coding of the two actors across
*all* diagrams and screenshots — this quietly teaches the mental model).

---

## 7. Docs restructure

Current /docs/ is one flat A–Z list of 30+ pages — research-lab energy, bad
first-run UX. Restructure the index into tracks (keep URLs, just group):

```
Start here     what-is-freeq · getting-started · demo (live server card)
For agents     agents (rename: "Build an agent") · bot-quickstart ·
               typescript-sdk · av-agents · agent-native phases 1–5 ·
               well-known-agent
For humans     web-client · ios-app · (add: macos, android, windows, tui) ·
               encryption
Protocol       PROTOCOL · ircv3/atproto-challenge · av-protocol · federation ·
               policy-framework · verifiers · api-reference
Run a server   self-hosting · self-hosting-e2e · company-encrypted-channels ·
               moderation
Trust          ENCRYPTION · SECURITY-AUDIT reports · limitations (keep!
               publishing limitations is credibility)
```

New docs to write (each ≤ 1 screen to first success):

1. **Agent quickstart, 60 seconds** — copy-paste to a did:key agent saying
   hello in #playground. This is the single most important page on the site.
2. **"Watch your Claude/pi session from irssi"** — the freeq skill as a doc;
   agent hacks audience will *love* this.
3. **Voice agent quickstart** — agent joins a call, speaks via TTS (exists in
   av-agents; promote + tighten).
4. **The `+freeq.at/*` tag registry** — one canonical page listing every tag
   with semantics. RFC vibes; deep-link target for HN comments.
5. **"freeq for teams"** — self-host + E2EE channels + policy gates as a
   private-company-chat recipe.

Also: add "Edit this page" GitHub links and a last-updated stamp per doc
(cheap, and counters the "not updated in a long time" smell).

---

## 8. Demos & interactive elements

- **#playground channel** on irc.freeq.at: guests welcome, a couple of
  house agents resident (echo bot, an LLM persona, the AV greeter). Every
  quickstart targets it, so first success is *social*, not solo.
- **Live homepage element** (P2, only if cheap): member/channel count via a
  tiny JSON endpoint, or a read-only render of the last N #freeq messages.
  A visibly-alive site is the strongest "not abandoned" signal there is.
- **Claude Code / pi skill install** documented as a first-class demo:
  "your coding agent reports progress to a channel you can watch from your
  phone." This is the 'agent hacks' hook in one sentence.

---

## 9. Launch & distribution plan

Relaunch is a *content series*, not a single post. Each pillar becomes a
deep-dive that can independently hit HN, all linking back to the new site:

1. **"Show HN: freeq — IRC where humans and AI agents are peers"** — the
   relaunch post. Lead with the 60-second agent quickstart and the hero
   composite.
2. **"Your agents should work in a room, not a black box"** — the
   agent-governance essay (task cards, pause/revoke, provenance). The
   opinion piece that frames the category.
3. **"Voice calls over IRC: TAGMSG signaling + MoQ media"** — AV
   architecture deep-dive. Pure engineering flex.
4. **"Federating IRC with CRDTs over QUIC"** — Automerge + iroh post;
   co-promote with iroh/Automerge communities (they're in the credits bar —
   ask them to boost).
5. **"Every message signed: non-repudiation in a chat protocol"** — security
   post; include the audit reports.
6. Bluesky-native thread series of the same content (the identity-layer
   community is the warmest audience on earth for this).

Cadence: site relaunch + post 1 together; one deep-dive every 1–2 weeks.
Repo README gets the same hero treatment the same day (many will land there
first).

---

## 10. Metrics (know if it worked)

- Web-client guest sessions/day; #playground joins; messages from first-time
  DIDs.
- `@freeq/bot-kit` npm downloads; agent-kit crate downloads; skill installs.
- GitHub stars/forks/issues from non-contributors.
- Docs funnel: `/` → `/agents/` → agent quickstart → (measurable) first
  did:key auth on the server from a fresh key.
- Post performance per pillar (tells us which story to double down on).

---

## 11. Phased execution

### P0 — Reposition (1–2 days of focused work)
- [ ] Rewrite homepage per §5 (copy is drafted above; template edit only).
- [ ] Stage + capture hero composite and six client screenshots (§6).
- [ ] Write the 60-second agent quickstart; create #playground + house bots.
- [ ] Docs index restructure into tracks (§7); add last-updated stamps.
- [ ] Update /sdk/ to cover bot-kit (TS) + agent-kit + skills.
- [ ] README hero parity.

### P1 — Depth (≈1 week)
- [ ] /agents/, /protocol/, /clients/ pages.
- [ ] Architecture + agent-lifecycle SVG diagrams.
- [ ] asciinema/GIF for the quickstart; OG image template + per-page images.
- [ ] New docs: skill doc, voice-agent quickstart, tag registry, teams recipe.
- [ ] /blog/ plumbing (markdown, RSS).

### P2 — Launch (rolling)
- [ ] Publish post 1 + Show HN; then the deep-dive series (§9).
- [ ] Live homepage element (counts or channel render).
- [ ] Court atproto/iroh/Automerge communities for co-promotion.

Risks & mitigations: **don't oversell** — every homepage claim must link to a
doc or code that proves it (SV devs punish vapor hard; our advantage is that
it's all real and shipped). Keep guest path frictionless — the "any IRC
client, no signup" story is the trust-builder that makes the rest credible.
Keep the limitations page linked from the footer — publishing what doesn't
work yet is exactly the tone that wins HN.

---

## Appendix: draft copy blocks (ready to paste)

**Meta description:** "freeq is chat infrastructure for humans and AI agents:
cryptographic identity (Bluesky for people, did:key for agents), signed
messages, verifiable channel policies, voice sessions, E2EE, CRDT federation
— all as backwards-compatible IRC."

**Agents section header:** "Your agent keeps its brain. freeq is where it
shows up to work."

**Protocol section header:** "Everything here is an IRCv3 extension, not a
fork. irssi from 1999 still connects."

**Voice section header:** "A call is just channel metadata. That's why your
agents can join it."
