# freeq-web4

Gleam Lightspeed LiveView port of `freeq-web3`. See `../freeq-web3/AGENTS.md`
for the Phoenix BFF this was ported from, and `../freeq-web2/AGENTS.md` for
the Rails/StimulusReflex origin.

## Scope (agents)

**Do not edit `freeq-server` (or other upstream packages) while working on this
client.** freeq-web4 is a BFF/client that talks to freeq-server over IRC
WebSocket + REST; treat the server as an external dependency.

| In scope | Out of scope |
|----------|----------------|
| `freeq-web4/**` | `freeq-server/**` |
| Client-side workarounds for server gaps | Protocol/API changes in freeq-server |
| Parsing/adapting tags the server already sends | New freeq-server endpoints, DB, or REST shape |

If a feature truly needs a server change: **stop**, document the gap (tag
missing from REST history, etc.), and only touch freeq-server in a **dedicated
server task** — never as a drive-by while implementing web4 UI/protocol
handling.

Same rule applies to sibling clients (`freeq-web2`, `freeq-web3`, `freeq-app`,
`freeq-webui`, native apps): client work stays in that client tree.


## Deploy to freeq.boxd

https://freeq.boxd.sh runs freeq-web4. The VM cannot pull from your laptop
(NAT); deploy rsyncs the tree and rebuilds on-box via `nix develop`.

```bash
# commit (if dirty) + rsync + gleam deps + restart + point proxy at :4004
nu freeq-web4/script/deploy-boxd.nu -m "Your message"

# leave freeq-web3 running (side-by-side debug)
nu freeq-web4/script/deploy-boxd.nu --keep-web3 --no-commit
```

| | |
|--|--|
| Host | SSH `freeq.boxd` → freeq.boxd.sh (user `boxd`) |
| App dir | `/home/boxd/freeq-web4` |
| Service | `systemctl --user restart freeq-web4` |
| Public URL | `https://freeq.boxd.sh` |
| Port | `4004` (proxy target) |
| Upstream IRC | `wss://irc.freeq.at/irc` (production freeq-server) |

Do **not** overwrite remote `freeq-web4.env` or `/home/boxd/data/web4-*`.
After deploy, smoke-check `/health` and `/chat`.

## Build

Workspace-sibling. From `freeq-web4/`:

```bash
nix develop          # preferred (gleam-preview + Erlang)
gleam deps download
gleam run            # http://127.0.0.1:4004
gleam test
```

Without the flake: Gleam 1.17+, OTP 26+.

## Architecture

| Path | Role |
|------|------|
| `src/freeq_web4.gleam` | Mist HTTP + `/live` WebSocket + static assets |
| `src/freeq_web4/live.gleam` | Stateful Lightspeed component (model/msg/render) |
| `src/freeq_web4/ws.gleam` | Live session host — protocol Event → handle → Diff |
| `src/freeq_web4/irc/upstream.gleam` | Stratus WS to freeq-server `/irc` (guest + SASL) |
| `src/freeq_web4/irc/render.gleam` | IRC parse + history rows (port of web3 `Irc.Render`) |
| `src/freeq_web4/rest.gleam` | REST client for channels + history + search + OG |
| `src/freeq_web4/link_preview.gleam` | YouTube / Bluesky / OpenGraph cards + image cache |
| `src/freeq_web4/auth.gleam` | OAuth login / callback / logout / client metadata |
| `src/freeq_web4/atproto/*` | DPoP, OAuth, SASL ATPROTO-CHALLENGE |
| `src/freeq_web4/cookie_session.gleam` | `freeq_session` cookie |
| `src/freeq_web4/pending_oauth_store.gleam` | PKCE state (disk) |
| `src/freeq_web4/session_store.gleam` | Persisted OAuth credentials (disk) |
| `src/freeq_web4/config.gleam` | Env: upstream, REST, PORT, public URL, store dirs |
| `priv/static/app.css` | freeq dark theme (from web3) |
| `priv/static/lightspeed.js` | Lightspeed browser runtime |

## Key decisions

- **Lightspeed over Phoenix**: typed msgs + fine-grained `diff` patches.
- **Server holds the upstream IRC WS** (BFF), same as web2/web3/webui.
- **One IRC connection per LiveView socket** (MVP). web3 uses a cookie
  session registry for multi-tab; that can land later as a Gleam actor
  registry.
- **Guest mode first**, with optional AT Protocol OAuth + SASL.
- **Client-authoritative channel list** in the LiveView model (`my_channels`).
  Only join/part/navigate mutates it; persisted under the session cookie
  (`session_store` `.channels` file) so refresh restores the sidebar + re-JOINs.
- **OAuth**: cookie `freeq_session` + disk stores under `.dev-data/web4-*`.
  Login at `/login`; callback at `/auth/callback`; client metadata at
  `/.well-known/oauth-client-metadata`. Upstream IRC runs SASL
  `ATPROTO-CHALLENGE` when credentials are present.

## Porting checklist (from freeq-web3)

- [x] Lightspeed session + Mist HTTP
- [x] Upstream IRC WS (guest CAP/NICK/USER)
- [x] Channel list + chat shell LiveView
- [x] Send / join / part / topic
- [x] REST history + channel list
- [x] Member roster (353 / JOIN / PART / QUIT)
- [x] freeq dark theme CSS
- [x] AT Protocol OAuth + SASL ATPROTO-CHALLENGE
- [x] Voice/video AV calls (TAGMSG signaling + MoQ media panel)
- [ ] Encrypted session store + multi-tab registry
- [x] Reactions (TAGMSG +react / unreact)
- [x] Message edit UI (`+draft/edit`, hover ✎, ArrowUp, (edited) badge)
- [x] Message delete UI (`+draft/delete` TAGMSG from edit banner, soft placeholder)
- [ ] DMs + E2EE
- [x] Link embeds / preview cache
- [x] Image paste / attach button + upload proxy (`POST /upload`)
- [x] Scroll-up load older history (`?before=` + CHATHISTORY BEFORE)
- [x] Message search (REST `/api/v1/search` modal)
- [x] System channel tab (connection status + server notices)
- [ ] PWA

## Idioms

```gleam
// verified route + live controller
endpoint.new(contract.allow_all("owner-1"), "/live")
|> endpoint.get_live(index, "freeq_view", fn(_conn) { initial_body(path) })

// stateful component (mount / handle / render / routes)
// see freeq_web4/live.gleam

// server-push IRC → model → plan_patches → protocol.Diff
```

## Nix-host notes

- **`nix develop`** is the recommended entry point (`freeq-web4/flake.nix`).
- Pure Nix flakes only see files in the **Git** tree. This monorepo uses
  colocated **jj**: finish a change that includes freeq-web4
  (`jj commit -m "…"`) so the flake can read sources. Prefer `jj` for all
  other VCS ops — see root `AGENTS.md` § Version control.
