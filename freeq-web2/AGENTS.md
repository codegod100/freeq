# freeq-web2

StimulusReflex + CableReady port of `freeq-webui`. See `../freeq-webui/AGENTS.md`
for the original Rust/Topcoat BFF this was ported from.

## Deploy to freeq.boxd (required)

**Any change you make under `freeq-web2/` must be deployed to `freeq.boxd`
before you consider the work done** — not only when the user asks. Live users
hit `https://freeq.boxd.sh`; local fixes that never ship leave the bug in
production.

```bash
# From freeq-web2/ (builds JS if needed, rsyncs, precompiles, restarts puma):
./script/deploy-boxd.sh
```

| | |
|--|--|
| Host | SSH `freeq.boxd` → `freeq.boxd.sh:10223` (user `boxd`) |
| App dir | `/home/boxd/freeq-web2` |
| Service | `sudo systemctl restart freeq-web2` |
| Public URL | `https://freeq.boxd.sh` |
| Upstream IRC | `wss://irc.freeq.at/irc` (production freeq-server) |

Do **not** overwrite remote `.env`, `.dev-data/`, `log/`, `tmp/`, or
`vendor/bundle`. The tree on boxd is **not** a git checkout — rsync is the
ship path. After deploy, smoke-check `/chat` (200) and that the change is
visible (grep remote sources or hit the UI).

## Build

Workspace-sibling. From `freeq-web2/`:

```bash
nix-shell -p gnumake --run 'bundle install'
npm install
npm run build
```

`make` must be on PATH for native-extension gems (websocket-driver, puma
native parts) on this Nix host. `npm run build` bundles
`app/javascript/application.js` → `app/assets/builds/application.js` via
esbuild. Rebuild after changing JS.

## Run

```bash
# defaults already point at irc.freeq.at; override only for a local server:
# export FREEQ_UPSTREAM="ws://127.0.0.1:8080/irc"
# export FREEQ_UPSTREAM_REST="http://127.0.0.1:8080"
nix-shell -p gnumake --run 'bin/rails server -b 127.0.0.1 -p 3000'
```

## Architecture

| Path | Role |
|------|------|
| `app/controllers/chat_controller.rb` | `/chat` index + `/chat/:channel` show; spawns upstream WS + broadcaster thread |
| `app/reflexes/chat_reflex.rb` | StimulusReflex: send/join/part/topic/react/unreact |
| `app/channels/chat_channel.rb` | ActionCable channel the browser subscribes to for CableReady broadcasts |
| `app/channels/application_cable/connection.rb` | Identifies connections by `freeq_session` cookie |
| `lib/session_registry.rb` | Global per-session state registry + disk-backed auth restore |
| `lib/session_store.rb` | AES-256-GCM OAuth session files (FREEQ_WEB2_SESSIONS_DIR) |
| `lib/session_state.rb` | Per-session state: outbound/inbound queues, upstream WS task, member tracking |
| `app/javascript/controllers/chat_controller.js` | Stimulus controller: ChatChannel subscription, reaction picker, sidebar toggles |
| `app/javascript/controllers/call_controller.js` | Voice call UI: start/join/leave, mute/camera, MoQ publish/subscribe |
| `app/javascript/link_embeds.js` | YouTube / Bluesky / OpenGraph cards under message URLs |
| `app/javascript/av/` | Mesh paths, MoQ loader, session API helpers |
| `app/javascript/config/stimulus_reflex.js` | StimulusReflex JS bootstrap |
| `app/views/chat/index.html.erb` | Channel list |
| `app/views/chat/show.html.erb` | Chat shell |
| `app/views/layouts/application.html.erb` | Root layout + dark theme CSS |
| `config/initializers/stimulus_reflex.rb` | Relax caching sanity check (dev) |
| `config/initializers/session_store.rb` | Cookie session store |

## Key decisions

- **StimulusReflex over SSE**: live IRC updates are CableReady operations
  (`morph`/`append`/`text`) broadcast to `ChatChannel`, not an SSE stream.
- **Server holds the upstream IRC WS** (BFF), same as `freeq-webui`. The
  browser never opens `/irc` directly.
- **`websocket-driver` over raw `TCPSocket` / `OpenSSL::SSL::SSLSocket`** for
  the upstream WS (avoids the native openssl gem that `async-websocket`
  drags in). Supports both `ws://` and `wss://`.
- **AT Protocol OAuth + disk persistence**: login via `/login`, SASL on the
  upstream WS when authenticated. OAuth blobs AES-GCM encrypted under
  `FREEQ_WEB2_SESSIONS_DIR` (default `.dev-data/web2-sessions`) so identity
  survives process restart; encrypted cookie is a secondary path.
- **Client-authoritative channel list**: freeq-web2 owns the user's
  joined-channel list (`SessionState#channels`), persisted encrypted as
  `<sid>.channels` in the sessions dir. The upstream server is a dumb
  relay — on every fresh WS connect we re-assert the whole list, and
  MY CHANNELS renders from our list, never from upstream room state.
  Only explicit join intent mutates the list (`add_channel!` from
  chat#show real visits + ChatReflex#join; part removes).
  `spawn_upstream_if_needed` only tracks `@joined` for IRC routing —
  never promotes into My Channels. Turbo prefetch of `/chat/:channel`
  is disabled (meta + headers) so hover prefetches cannot pollute the
  list.
- **`morph :nothing` on redirecting reflexes**: StimulusReflex re-renders
  the current page after a reflex by default; without opting out, a part
  reflex's re-render re-adds the parted channel via `show` →
  `spawn_upstream_if_needed` → `add_channel!`.
- **Per-session Thread for upstream WS + per-(session,channel) broadcaster
  Thread**, mirroring `freeq-webui`'s tokio tasks.
- **Inline CSS in the layout** (ported from `app.rs`), not Tailwind classes,
  to keep the dark theme identical to `freeq-webui` without a Tailwind build
  step for core chat.

## Known limitations (core port scope)

- **Encrypted OAuth session persistence** — ✅ ported. Authenticated
  sessions are AES-256-GCM encrypted under `FREEQ_WEB2_SESSIONS_DIR`
  (default `.dev-data/web2-sessions`), keyed by the browser's signed
  `freeq_session` cookie. Registry `get` restores on first touch after
  restart; login also writes an encrypted `oauth_session` cookie as a
  secondary path. Set `FREEQ_WEB2_SESSIONS_DIR=` empty to disable.
- **No DPoP nonce rotation end-to-end** — nonce is captured + re-persisted
  during SASL, but a full re-login is still required if the access token
  itself expires.
- **Voice / video calls** — ✅ ported (UI + signaling + MoQ media).
  Stimulus `call` controller: discover/start/join/leave via `/api/av/*`
  TAGMSG enqueue; roster/token proxies; `moq-publish`/`moq-watch` from
  `/av/assets/*` (proxied). Media dials the freeq-server SFU at
  `{FREEQ_UPSTREAM_REST}/av/moq` (WebSocket). Requires signed-in DID.
  Screen share and device pickers not yet ported; reconnect rejoin is
  best-effort only.
- **No WHOIS rendering** — `/whois` slash command enqueues but the result
  numerics aren't rendered to the message pane.
- **CHATHISTORY fallback for protected channels** — REST scrollback is the
  primary backlog source; when it fails (403 on +i/+k/auth-gated channels),
  the JOIN chathistory replay renders instead (or an explicit
  `CHATHISTORY LATEST` when already joined). Join-failure numerics
  (471/473/474/475/477) render as error notices in the message pane.
- **Reaction live updates** — server-echoed reactions via
  `freeq:reaction` CableReady events are wired; localStorage reaction
  cache (freeq-app) is not ported.
- **Link embeds** — ✅ ported (YouTube thumb, Bluesky post card, OpenGraph
  preview via same-origin `/api/v1/og` → freeq-server). Client hydrates
  from `data-text` on history load and live CableReady appends. Inline
  images remain server-rendered via `IrcRender#linkify_urls`.
- **Connection limits** — `freeq-webui` enforces 20 per-IP; Rails/Puma
  connection limits are not configured here.

## Nix-host notes

- **`nix develop`** is the recommended entry point. The flake
  (`freeq-web2/flake.nix`) provides Ruby 3.4, Bundler, Node 22, gcc, make,
  pkg-config, openssl.dev, watchexec, and curl — everything needed for
  `bundle install` (native gem extensions build with the bundled gcc+make)
  and `npm run build`. Gems install into `.bundle/vendor` (project-local,
  not the user's global gem dir).
- Without the flake, `make` is not on the default PATH; run bundle/native
  builds inside `nix-shell -p gnumake --run '...'`.
- Pure Nix flakes only see files in the **Git** tree. This monorepo uses
  colocated **jj**: finish a change that includes freeq-web2
  (`jj commit -m "…"`) so the flake can read sources, or as a last resort
  `git add freeq-web2/` (index only) for a local flake eval. Prefer `jj`
  for all other VCS ops — see root `AGENTS.md` § Version control.