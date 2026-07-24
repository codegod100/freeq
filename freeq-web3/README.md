# freeq-web3

Phoenix LiveView port of [freeq-web2](../freeq-web2). Same BFF architecture
(server holds the upstream IRC WebSocket), reimplemented in Elixir/Phoenix
instead of Rails + StimulusReflex.

## Architecture

```
┌──────────┐   LiveView / PubSub   ┌────────────┐   WS /irc      ┌──────────────┐
│  browser │ ◀───────────────────▶ │ freeq-web3 │ ◀────────────▶ │ freeq-server │
│          │                       │ (Phoenix)  │   REST /api/v1 │              │
└──────────┘                       └────────────┘               └──────────────┘
```

One upstream WebSocket connection per browser session. The Phoenix process:

1. Holds a per-session `Session.Server` GenServer with an outbound queue.
2. Spawns an `Irc.Upstream` process that opens the upstream `/irc` WS via
   Mint + Mint.WebSocket, runs IRC registration (guest CAP/NICK/USER), and
   forwards inbound lines to the session.
3. The session parses each IRC line with `Irc.Render` and broadcasts
   structured events over Phoenix.PubSub to subscribed LiveViews.
4. Mutations (send / join / part / topic) arrive as LiveView `handle_event`
   callbacks and enqueue outbound IRC lines on the session.

## Stack

- **Phoenix 1.8** + **LiveView 1.2**
- **Bandit** HTTP server
- **Mint** + **Mint.WebSocket** for the upstream IRC WS
- **Req** for freeq-server REST (channel list, history)
- Tailwind / Inter font; freeq dark theme CSS (ported from freeq-web2)

## Build & run

**Recommended — `nix develop`** (provides Elixir, Erlang, Node):

```bash
cd freeq-web3
# Pure flakes only see the Git tree. With colocated jj, commit freeq-web3
# paths first (`jj commit`), or last-resort: `git add freeq-web3/`.
nix develop
mix setup
mix phx.server
```

**Without the flake** (requires Elixir 1.17+ / OTP 26+):

```bash
cd freeq-web3
mix setup
# Defaults point at production (irc.freeq.at). For a local freeq-server:
export FREEQ_UPSTREAM="ws://127.0.0.1:8080/irc"
export FREEQ_UPSTREAM_REST="http://127.0.0.1:8080"
mix phx.server
```

Open `http://127.0.0.1:4000` → LiveView channel list at `/chat`.

## Environment variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `FREEQ_UPSTREAM` | `wss://irc.freeq.at/irc` | Upstream IRC WebSocket URL |
| `FREEQ_UPSTREAM_REST` | `https://irc.freeq.at` | Upstream freeq-server REST base |
| `FREEQ_PUBLIC_URL` | request base URL | Public origin for OAuth client_id + redirect |
| `FREEQ_WEB3_PENDING_OAUTH_DIR` | `.dev-data/web3-pending-oauth` | In-flight OAuth PKCE/state store |
| `FREEQ_WEB3_SESSIONS_DIR` | `.dev-data/web3-sessions` | Encrypted OAuth + channel list (empty = off) |
| `FREEQ_WEB3_PREVIEW_CACHE_DIR` | `.dev-data/web3-preview-cache` | Downloaded link-preview images + meta |
| `PORT` | `4000` | HTTP listen port |

## HTTP surface

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/` | LiveView channel list (same as `/chat`) |
| GET | `/chat` | Channel list |
| GET | `/chat/:channel` | Chat shell for a channel |
| GET | `/login` | AT Protocol OAuth login form |
| GET | `/login/start` | Start OAuth (handle → PAR → redirect) |
| GET/POST | `/auth/callback` | OAuth redirect callback + SASL |
| GET/POST | `/logout` | Sign out (guest reconnect) |
| GET | `/.well-known/oauth-client-metadata` | Public OAuth client metadata |
| GET | `/api/v1/og?url=` | OpenGraph metadata proxy (used by server previews) |
| GET | `/preview-cache/:id` | Locally cached preview image bytes |
| GET | `/up` | Health check JSON |
| WS | `/live/websocket` | Phoenix LiveView |

## Relation to freeq-web2

This is a **core-chat** port of freeq-web2. What is ported:

- Channel list (`/chat`)
- Per-channel chat shell with sidebar, member panel, topic, compose
- Live message/member/topic updates via PubSub → LiveView
- Send / join / part / topic via LiveView events
- IRC line parsing (`Irc.Render`, Elixir port of web2 `IrcRender`)
- REST scrollback fetch on page load
- Upstream WS bridge (guest + authenticated SASL)
- AT Protocol OAuth login (`/login` → PAR → callback)
- SASL `ATPROTO-CHALLENGE` + `API-BEARER` capture on the BFF upstream
- Sign in / Sign out in the chat shell
- Link embeds (server-side: OG/YT/Bluesky images cached to disk, served as
  same-origin `/preview-cache/:id` so page load does not hit remote hosts)
- Dark theme from freeq-web2

What is **not** yet ported (track in AGENTS.md):

- DMs / E2EE
- Reactions UI + TAGMSG react
- Voice / video (MoQ)
- Media upload proxy
- PWA / service worker
- Channel policy modal

## Why LiveView?

freeq-web2 used StimulusReflex + CableReady over ActionCable for mutations
and DOM morphs. LiveView replaces both with a single stateful process:

- Mutations are `phx-submit` / `phx-click` events (no separate Reflex layer)
- Live updates are assign/stream changes pushed over the LiveView socket
- The browser stays thin — no client-side IRC state machine
