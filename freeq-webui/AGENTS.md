# freeq-webui

Topcoat BFF web UI for freeq. Connects to freeq-server over WSS + REST.

## Build

Workspace member. From repo root:

```bash
cargo build -p freeq-webui
# Bundle assets into target/assets (requires topcoat CLI)
../topcoat/target/debug/topcoat asset bundle -p freeq-webui
```

Topcoat is a **path dependency** on `../../topcoat/crates/topcoat` (sibling
checkout of [tokio-rs/topcoat](https://github.com/tokio-rs/topcoat)).

## Run

```bash
FREEQ_UPSTREAM=https://irc.freeq.at \
FREEQ_WEBUI_BIND=127.0.0.1:8090 \
  cargo run -p freeq-webui
```

## Architecture

| Path | Role |
|------|------|
| `src/main.rs` | Bind + `topcoat::serve` |
| `src/app.rs` | Root layout, router, Tailwind shell |
| `src/app/chat*.rs` | Channel list + chat page |
| `src/app/events.rs` | SSE live stream |
| `src/app/actions.rs` | send/join/part/react/upload |
| `src/app/login.rs` / `auth.rs` | OAuth |
| `src/state.rs` | AppState, SessionHandle, encrypted session store |
| `src/upstream.rs` | WS bridge + REST client |
| `src/irc_render.rs` | IRC line → HTML |
| `src/oauth_flow.rs` | PreparedLogin (web + loopback) |
| `static/events.js` | EventSource bridge |

## Key decisions

- **SSE, not Topcoat shards**, for live IRC (push, not poll).
- **Server holds the IRC WebSocket** (BFF). Browser never opens `/irc` directly.
- **OAuth via freeq-sdk DPoP types** + in-crate `PreparedLogin` (main SDK has no PreparedLogin).
- **No DataStar / Tera** — Topcoat `view!` + Tailwind.
- **Assets**: run `topcoat asset bundle -p freeq-webui` after build so `events.js` + tailwind CSS resolve.

## Known limitations

- Access-token refresh is not implemented on main freeq-sdk `OAuthSession` (SASL 904 falls back to guest).
- Template/hot-reload: use `topcoat dev` or rebuild + rebundle.
- Channel path segments: `#` is omitted in URLs (`/chat/freeq` → `#freeq`).
