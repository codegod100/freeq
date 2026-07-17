# freeq-webui

Standalone [Topcoat](https://github.com/tokio-rs/topcoat) web UI for the
[freeq IRC server](https://github.com/chad/freeq). This is **not** embedded in
`freeq-server` — it's a BFF that connects to a running freeq-server over
WebSocket (live IRC) and REST (channel metadata), and serves server-rendered
HTML + SSE to the browser.

## Architecture

```
┌──────────┐   HTML / SSE / POST    ┌────────────┐   WS /irc      ┌──────────────┐
│  browser │ ◀────────────────────▶ │ freeq-webui│ ◀─────────────▶ │ freeq-server │
│ (Topcoat │   cookies              │  (Topcoat) │   REST /api/v1  │              │
│  runtime)│                        └────────────┘                  └──────────────┘
└──────────┘
```

One upstream WS connection per browser session. The proxy:

1. Holds a per-session `mpsc` for outbound IRC lines (PRIVMSG / JOIN / …).
2. Holds a per-session `broadcast` of inbound IRC lines, drained by SSE.
3. Spawns the upstream WS lazily on first SSE connect for a session.
4. Proxies selected REST endpoints (`/api/channels`, policy, upload).

## Stack

- **Topcoat** (path dependency: `../../topcoat/crates/topcoat`) — SSR, routes, cookies
- **Tailwind** via Topcoat build script
- **freeq-sdk** OAuth types + DPoP (web/loopback login helpers live in-crate)
- **tokio-tungstenite** — upstream IRC-over-WS

## Build & run

Requires a local Topcoat checkout at `../topcoat` (sibling of the freeq repo).

```bash
# From freeq repo root
cargo build -p freeq-webui

# Bundle CSS/JS assets (after first build, or whenever assets change)
/path/to/topcoat/target/debug/topcoat asset bundle -p freeq-webui
# or: cargo install --path ../topcoat/crates/topcoat-cli && topcoat asset bundle -p freeq-webui

FREEQ_UPSTREAM=http://127.0.0.1:8080 \
FREEQ_WEBUI_BIND=127.0.0.1:8090 \
  cargo run -p freeq-webui
```

Dev with live reload (optional):

```bash
cd freeq-webui
HOST=127.0.0.1 PORT=8090 topcoat dev
```

Default upstream is `http://127.0.0.1:8080`. Point at production with
`FREEQ_UPSTREAM=https://irc.freeq.at`.

### OAuth behind a public host (tailscale funnel, reverse proxy)

```bash
FREEQ_PUBLIC_URL=https://myhost.example \
FREEQ_WEBUI_BIND=127.0.0.1:8090 \
  cargo run -p freeq-webui
```

When `FREEQ_PUBLIC_URL` is set:

- Serves `/.well-known/oauth-client-metadata`
- Uses `{public_url}/auth/callback` as the OAuth redirect
- Without it, loopback OAuth is used (browser must share localhost with the webui)

## Environment variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `FREEQ_UPSTREAM` | `http://127.0.0.1:8080` | freeq-server base URL |
| `FREEQ_WEBUI_BIND` | `127.0.0.1:8090` | Listen address |
| `FREEQ_PUBLIC_URL` | _(unset)_ | Public origin for web OAuth |
| `FREEQ_WEBUI_SESSIONS_DIR` | `.dev-data/webui-sessions` | Encrypted OAuth session store (empty to disable) |
| `RUST_LOG` | `info` | Tracing filter |
| `HOST` / `PORT` | — | Used only if you call `topcoat::start` directly; this binary prefers `FREEQ_WEBUI_BIND` |

## HTTP surface

| Method | Path | Purpose |
|--------|------|---------|
| GET | `/` | Redirect → `/chat` |
| GET/POST | `/login` | AT Protocol OAuth |
| POST | `/logout` | Clear session |
| GET | `/chat` | Channel list |
| GET | `/chat/{channel}` | Chat shell |
| GET | `/chat/{channel}/events` | SSE live updates |
| POST | `/chat/{channel}/send` | PRIVMSG / slash commands |
| POST | `/chat/{channel}/join` | JOIN |
| POST | `/chat/{channel}/part` | PART |
| POST | `/chat/{channel}/topic` | TOPIC |
| POST | `/chat/{channel}/react` | TAGMSG reaction |
| POST | `/chat/{channel}/unreact` | Remove reaction |
| POST | `/upload` | Media upload proxy |
| GET | `/api/channels` | Channel list proxy |
| GET | `/auth/status` | Auth JSON |
| GET | `/auth/callback` | OAuth callback (web flow) |

## Why a separate crate?

`freeq-server` exposes IRC-over-WebSocket and a JSON REST API. Building the UI
as a sibling binary keeps the server lean and lets the web UI evolve on its own
cadence. The trade-off is one extra hop; SSE fragments are tiny and localhost
latency is negligible.

## Relation to freeq-app

`freeq-app` is the production React SPA at irc.freeq.at (browser WebSocket).
`freeq-webui` is the Topcoat BFF UI (server holds the IRC WS). They are
independent clients.
