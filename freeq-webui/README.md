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
FREEQ_WEBUI_BIND=127.0.0.1:8090 \
  cargo run --bin freeq-webui
```

The proxy connects to a freeq-server reachable at `FREEQ_UPSTREAM`.
Default is the public deployment at `https://irc.freeq.at`.
For a local server, override with `FREEQ_UPSTREAM=http://127.0.0.1:8080`.

### Running behind tailscale funnel (for OAuth)

AT Protocol OAuth requires the browser and webui to share a host.
The default **loopback** flow binds `127.0.0.1:<random>` — works only
when the browser is on the same machine. To use OAuth from a remote
browser on your tailnet:

```bash
# 1. Start tailscale funnel (makes the service publicly reachable):
tailscale funnel 8090

# 2. Set FREEQ_PUBLIC_URL to the funnel FQDN:
FREEQ_PUBLIC_URL=https://myhost.tailnet.ts.net \
FREEQ_WEBUI_BIND=127.0.0.1:8090 \
  cargo run --bin freeq-webui
```

When `FREEQ_PUBLIC_URL` is set, the webui switches from loopback to
**web-based OAuth**:
- Serves `/.well-known/oauth-client-metadata` for PDS discovery
- Registers `{public_url}/auth/callback` as the redirect URI
- Bluesky's PDS fetches metadata from the public FQDN
- The callback endpoint exchanges the auth code for tokens

Without `FREEQ_PUBLIC_URL`, the webui uses the original loopback flow
(localhost-only) — no changes to existing dev workflows.


## Environment variables

| Variable            | Default                  | Purpose                                          |
|---------------------|--------------------------|--------------------------------------------------|
| `FREEQ_UPSTREAM`    | `https://irc.freeq.at`   | Base URL of the freeq-server to proxy            |
| `FREEQ_WEBUI_BIND`  | `127.0.0.1:8090`         | Where the proxy listens                          |
| `FREEQ_PUBLIC_URL`  | _(unset)_                | Public FQDN for web OAuth (e.g. tailscale funnel) |
| `RUST_LOG`          | `info`                   | Standard tracing-subscriber filter               |

## HTTP API

| Method | Path                              | Purpose                                    |
|--------|-----------------------------------|--------------------------------------------|
| GET    | `/`                               | Redirects to `/chat`                       |
| GET    | `/chat/{channel}`                 | Serves the DataStar HTML page              |
| GET    | `/chat/{channel}/events`          | SSE stream of IRC events                   |
| POST   | `/chat/{channel}/send`            | Sends a PRIVMSG (body: JSON `{msg: "…"}`)  |
| POST   | `/chat/{channel}/join`            | Join a channel                             |
| POST   | `/chat/{channel}/part`            | Part a channel                             |
| GET    | `/api/channels`                   | Proxies `GET /api/v1/channels` upstream    |
| GET    | `/.well-known/oauth-client-metadata` | OAuth client metadata (web flow only)   |
| GET    | `/auth/callback`                  | OAuth redirect callback (web flow only)    |
| GET    | `/auth/status`                    | JSON: `{authenticated, handle, did}`       |

## v1 limitations

- [x] AT Protocol OAuth (loopback + web via tailscale funnel)
- [x] Basic SASL handshake
- [ ] Channel list UI (render the proxied `/api/channels`)
- [ ] History backfill (CHATHISTORY or `/api/v1/channels/{name}/history`)
- [ ] Edits, deletes, reactions
- [ ] Reconnect with backoff when the upstream WS dies
- [ ] Per-session multi-channel
## Why a separate crate?

`freeq-server` exposes a clean WebSocket IRC transport and a JSON REST
API. Building the DataStar UI as a sibling binary (with its own
`Cargo.toml`, its own `[workspace]` marker) keeps the server's binary
small and lets the web UI evolve on its own release cadence. The
trade-off is one extra hop in the browser→IRC path; in practice the
SSE fragments are tiny and the round-trip is sub-millisecond on
localhost.
