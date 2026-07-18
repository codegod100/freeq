# freeq-web2

StimulusReflex + CableReady port of [freeq-webui](../freeq-webui). Same BFF
architecture (server holds the upstream IRC WebSocket), reimplemented in
Ruby on Rails instead of Rust + Topcoat.

## Architecture

```
┌──────────┐   HTML / ActionCable   ┌────────────┐   WS /irc      ┌──────────────┐
│  browser │ ◀────────────────────▶ │ freeq-web2 │ ◀────────────▶ │ freeq-server │
│ (Stimulus│   StimulusReflex       │  (Rails)   │   REST /api/v1 │              │
│  Reflex) │                        └────────────┘               └──────────────┘
└──────────┘
```

One upstream WebSocket connection per browser session. The Rails process:

1. Holds a per-session `SessionState` with an outbound `Queue` (PRIVMSG / JOIN / …).
2. Spawns a background `Thread` per session that opens the upstream `/irc` WS
   via `websocket-driver` over a raw `TCPSocket`, runs IRC registration
   (CAP / NICK / USER, guest mode in the core port), and pushes inbound IRC
   lines onto an inbound `Queue`.
3. A broadcaster `Thread` per (session, channel) drains the inbound queue,
   parses each IRC line with `IrcRender`, and emits CableReady operations
   (`morph` / `append` / `text`) to `ChatChannel`.
4. Mutations (send / join / part / topic / react) arrive as StimulusReflex
   calls (`ChatReflex`) and enqueue outbound IRC lines on the session.

## Stack

- **Rails 8.1** + **ActionCable**
- **StimulusReflex 3.5** + **CableReady 5.0**
- **esbuild** JS pipeline, Tailwind CSS (core chat uses inline `<style>`)
- **websocket-driver** (already an ActionCable dep) for the upstream IRC WS

## Build & run

**Recommended — `nix develop`** (provides Ruby, Bundler, Node, gcc, make):

```bash
cd freeq-web2
git add freeq-web2/   # nix flakes only see git-tracked files; index only, no commit
nix develop
# inside the shell, deps are auto-installed; just run:
bin/rails server -b 127.0.0.1 -p 3000
```

**Without the flake** (requires Ruby 3.4 + Bundler + Node 22; on Nix, native
gem extensions need `make` on PATH):

```bash
cd freeq-web2
nix-shell -p gnumake --run 'bundle install'
npm install
npm run build          # esbuild → app/assets/builds/application.js

# Defaults point at production (irc.freeq.at). For a local freeq-server:
export FREEQ_UPSTREAM="ws://127.0.0.1:8080/irc"
export FREEQ_UPSTREAM_REST="http://127.0.0.1:8080"

nix-shell -p gnumake --run 'bin/rails server -b 127.0.0.1 -p 3000'
```

Open `http://127.0.0.1:3000` → redirects to `/chat`.

## Environment variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `FREEQ_UPSTREAM` | `wss://irc.freeq.at/irc` | Upstream IRC WebSocket URL (`ws://` or `wss://`) |
| `FREEQ_UPSTREAM_REST` | `https://irc.freeq.at` | Upstream freeq-server REST base (channels, history) |

## HTTP surface

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/` | Redirect → `/chat` |
| GET | `/chat` | Channel list |
| GET | `/chat/:channel` | Chat shell for a channel |
| WS | `/cable` | ActionCable (StimulusReflex + ChatChannel) |

Mutations are handled by StimulusReflex (`ChatReflex#send_message`,
`#join`, `#part`, `#set_topic`, `#react`, `#unreact`) — there are no POST
routes; the reflexes enqueue IRC lines on the per-session outbound queue.

## Relation to freeq-webui

This is a **core-chat-only** port of `freeq-webui`. What is ported:

- Channel list (`/chat`)
- Per-channel chat shell with sidebar, member panel, topic, compose
- Live message/member/topic/reaction updates via CableReady
- Send / join / part / topic / react / unreact via StimulusReflex
- IRC line rendering (`IrcRender`, a Ruby port of `irc_render.rs`)
- REST scrollback fetch on page load
- Upstream WS bridge (guest mode: no SASL/OAuth)
- The dark theme from `freeq-webui/src/app.rs` (inline CSS)

What is **not** ported (see AGENTS.md):

- AT Protocol OAuth login (guest mode only in the core port)
- SASL `ATPROTO-CHALLENGE` authentication
- DPoP nonce rotation / retry
- Encrypted on-disk session persistence
- Media upload proxy
- Channel policy view modal
- WHOIS rendering
- `wss://` upstream (only `ws://`)
- Standard IRC client guest-mode fallback verification

## Why StimulusReflex?

`freeq-webui` used server-rendered HTML + SSE for live updates. StimulusReflex
replaces both the SSE stream and the POST mutation routes with a single
ActionCable channel: mutations are Reflex calls, and live updates are
CableReady operations morphing the DOM from the server. The browser stays
thin — no client-side state machine, no fetch boilerplate.