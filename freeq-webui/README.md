# freeq-webui

Standalone [DataStar](https://data-star.dev)-based web UI for the [freeq IRC
server](https://github.com/chad/freeq). This is **not** embedded in
`freeq-server` — it's a thin proxy that connects to a running freeq-server
over WebSocket (for live IRC traffic) and REST (for channel metadata),
and serves DataStar HTML + SSE fragments to the browser.

## Architecture

```
┌──────────┐    HTML + SSE      ┌────────────┐    WS /irc      ┌──────────────┐
│  browser │ ◀───────────────▶ │  freeq-webui│ ◀──────────────▶ │  freeq-server │
│ (DataStar)│   form POSTs      │  (axum)    │   REST /api/v1  │              │
└──────────┘                    └────────────┘                  └──────────────┘
```

One upstream WS connection per browser session. The proxy:

1. Holds a per-session `mpsc::Sender<String>>` for outbound IRC lines
   (PRIVMSG / JOIN / etc) — fed by form POSTs.
2. Holds a per-session `broadcast::Sender<String>>` of inbound IRC lines
   — fed by the WS read loop, drained by every SSE subscriber.
3. Spawns the upstream WS connection lazily on the first SSE connect
   for a session; uses a `take_irc_rx()` pattern to hand the receiver
   half to the WS task exactly once.
4. Forwards `/api/v1/channels` (and any future REST endpoints) through
   to the upstream unchanged.

## Build & run

Inside the repo's [devenv](../devenv.nix) shell:

```bash
devenv shell webui-dev
# or, manually:
cd freeq-webui
FREEQ_UPSTREAM=https://irc.freeq.at \
FREEQ_WEBUI_BIND=100.115.154.32:8090 \
  cargo run --bin freeq-webui
```

The proxy connects to a freeq-server reachable at `FREEQ_UPSTREAM`.
Default is the public deployment at `https://irc.freeq.at`.
For a local server, override with `FREEQ_UPSTREAM=http://127.0.0.1:8080`.


## Environment variables

| Variable            | Default                  | Purpose                                |
|---------------------|--------------------------|----------------------------------------|
| `FREEQ_UPSTREAM`    | `https://irc.freeq.at`     | Base URL of the freeq-server to proxy  |
| `FREEQ_WEBUI_BIND`  | `100.115.154.32:8090`         | Where the proxy listens                |
| `RUST_LOG`          | `info`                   | Standard tracing-subscriber filter     |

## HTTP API

| Method | Path                              | Purpose                                    |
|--------|-----------------------------------|--------------------------------------------|
| GET    | `/`                               | Redirects to `/chat`                       |
| GET    | `/chat`                           | Serves the DataStar HTML page              |
| GET    | `/chat/{channel}/events`          | SSE stream of IRC events                   |
| POST   | `/chat/{channel}/send`            | Sends a PRIVMSG (body: JSON `{msg: "…"}`)  |
| GET    | `/api/channels`                   | Proxies `GET /api/v1/channels` upstream    |

## v1 limitations

This is the first cut — guest-mode only, no SASL, no channel list UI,
no history backfill. The TODO list is in `../AGENTS.md`; relevant items:

- [ ] SASL handshake via the existing `/auth/login` flow
- [ ] Channel list UI (render the proxied `/api/channels`)
- [ ] History backfill (CHATHISTORY or `/api/v1/channels/{name}/history`)
- [ ] Edits, deletes, reactions
- [ ] Reconnect with backoff when the upstream WS dies
- [ ] Per-session multi-channel (the current `joined` set is single-channel)

## Why a separate crate?

`freeq-server` exposes a clean WebSocket IRC transport and a JSON REST
API. Building the DataStar UI as a sibling binary (with its own
`Cargo.toml`, its own `[workspace]` marker) keeps the server's binary
small and lets the web UI evolve on its own release cadence. The
trade-off is one extra hop in the browser→IRC path; in practice the
SSE fragments are tiny and the round-trip is sub-millisecond on
localhost.
