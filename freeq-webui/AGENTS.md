# freeq-webui

Standalone DataStar web UI proxy for the freeq IRC server. Connects to `irc.freeq.at` over WSS + REST.

## Build

Part of the root Cargo workspace. Build from the repo root:

```bash
cd ~/code/freeq
devenv shell webui-dev          # provides rustc, gcc, openssl; sets RUST_LOG=freeq_webui=debug
cargo build -p freeq-webui       # workspace member, compiles once, cached in target/
```

Or build from the crate directory:

```bash
cd ~/code/freeq/freeq-webui
devenv shell webui-dev
cargo build
```

**Do NOT use `nix shell nixpkgs#gcc`** — the temp cc path invalidates cargo's fingerprint cache, causing `ring` (and all C deps) to recompile every build.
## Run

```bash
FREEQ_UPSTREAM=https://irc.freeq.at \
FREEQ_WEBUI_BIND=100.115.154.32:8090 \
  ./target/debug/freeq-webui
```

Or via devenv script:
```bash
devenv shell
webui-dev   # auto-detects tailscale IP, sets RUST_LOG=debug
```

## Architecture

- `src/main.rs` — axum router, SSE event streaming, IRC line parsing, member tracking, login flow
- `src/upstream.rs` — WS bridge to `wss://irc.freeq.at/irc`, REST calls, LOGIN command
- `src/state.rs` — AppState, SessionHandle, MemberEntry
- `templates/chat.html.tera` — Tera template with flexbox layout, EventSource SSE, DataStar forms
- `templates/login.html.tera` — Login page (handle-only, no private key)
- `static/datastar.js` — Self-hosted DataStar v1.0.2 IIFE bundle (export stripped)

## Key decisions

- **EventSource, not data-init**: DataStar's `@get` doesn't handle persistent SSE cleanly. We use raw `EventSource` and manually dispatch DataStar events.
- **ExecuteScript for member panel**: DataStar's `PatchElements` with `mode inner` didn't reliably update `#member-panel`. We use `ExecuteScript` with direct `innerHTML` assignment.
- **Server handles OAuth**: The freeq server has a full `LOGIN <handle>` → OAuth flow. The webui just passes the handle through — no crypto needed.
- **Bypass ring rebuilds**: Run inside `devenv shell`. The `gcc` package gives cargo a stable `cc` path.

## Known issues

- Template changes require restart (Tera loads at startup, no hot-reload in dev)
- Browser hard-refresh (`Ctrl+Shift+R`) often needed after JS/CSS changes
- The `#` in channel names must be URL-encoded (`%23`) when calling REST endpoints
- `async_stream` generator drops don't reliably fire destructors — avoid Drop guards in stream blocks
