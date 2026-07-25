# freeq-web4

Gleam [Lightspeed](https://hexdocs.pm/lightspeed) LiveView port of
[freeq-web3](../freeq-web3). Same BFF architecture (server holds the
upstream IRC WebSocket), reimplemented with typed Gleam on the BEAM
instead of Phoenix LiveView.

## Architecture

```
┌──────────┐   Lightspeed WS (/live)   ┌────────────┐   WS /irc      ┌──────────────┐
│  browser │ ◀────────────────────────▶ │ freeq-web4 │ ◀────────────▶ │ freeq-server │
│          │                            │ (Lightspeed│   REST /api/v1 │              │
│          │                            │  + Mist)   │                │              │
└──────────┘                            └────────────┘                └──────────────┘
```

One upstream IRC WebSocket per browser LiveView socket:

1. Mist serves the HTML shell and upgrades `/live` to the Lightspeed protocol.
2. The LiveView session mounts a stateful component and starts a Stratus
   client to freeq-server `/irc` (guest CAP/NICK/USER).
3. Inbound IRC lines are parsed (`irc/render`) and applied as model msgs;
   fine-grained `diff` patches update the browser.
4. Mutations (send / join / part / topic) are Lightspeed events that
   enqueue outbound IRC lines on the upstream client.
5. Channel list and scrollback come from freeq-server REST (`gleam_httpc`).

## Stack

- **Gleam** on Erlang/OTP
- **Lightspeed** 1.1+ (LiveView-style stateful components + patch protocol)
- **Mist** HTTP + WebSocket server
- **Stratus** upstream IRC WebSocket client
- **gleam_httpc** for freeq-server REST
- freeq dark theme CSS (ported from freeq-web3)

## Build & run

**Recommended — `nix develop`:**

```bash
cd freeq-web4
nix develop
gleam deps download
gleam run
```

Open `http://127.0.0.1:4004` → channel list at `/chat`.

**Without the flake** (requires Gleam 1.17+ / OTP 26+):

```bash
cd freeq-web4
gleam deps download
# Defaults point at production (irc.freeq.at). For a local freeq-server:
export FREEQ_UPSTREAM="ws://127.0.0.1:8080/irc"
export FREEQ_UPSTREAM_REST="http://127.0.0.1:8080"
gleam run
```

## Environment variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `FREEQ_UPSTREAM` | `wss://irc.freeq.at/irc` | Upstream IRC WebSocket URL |
| `FREEQ_UPSTREAM_REST` | `https://irc.freeq.at` | Upstream freeq-server REST base |
| `PORT` | `4004` | HTTP listen port |

## HTTP surface

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/` | Redirect → `/chat` |
| GET | `/chat` | LiveView channel list |
| GET | `/chat/:channel` | LiveView chat shell |
| GET | `/health` | Health check (`ok`) |
| GET | `/up` | Health check JSON |
| GET | `/assets/*` | CSS + Lightspeed client |
| WS | `/live` | Lightspeed protocol |

## Relation to freeq-web3

This is a **core-chat** port of freeq-web3 (itself a port of freeq-web2):

**Ported**

- Channel list (`/chat`)
- Per-channel chat shell with sidebar, members, topic, compose
- Live message/member/topic updates via Lightspeed patches
- Send / join / part / topic
- IRC line parsing (`irc/render`)
- REST scrollback + channel list
- Upstream WS bridge (guest CAP/NICK/USER)
- freeq dark theme CSS

**Not yet ported** (track in AGENTS.md)

- AT Protocol OAuth + SASL `ATPROTO-CHALLENGE`
- Encrypted session store / multi-tab session registry
- Reactions UI, edit/delete, DMs/E2EE
- Voice/video, link-preview cache, upload proxy, PWA

## Why Lightspeed?

freeq-web3 used Phoenix LiveView. Lightspeed is the Gleam equivalent:

- Typed model / msg / routes instead of dynamic assigns + string events
- Deterministic patch protocol (`diff` streams) instead of HEEx morphs
- Same BFF shape: browser stays thin; IRC lives on the server
