# freeq-web2

StimulusReflex + CableReady port of `freeq-webui`. See `../freeq-webui/AGENTS.md`
for the original Rust/Topcoat BFF this was ported from.

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
- **No media upload proxy** — `/upload` route not ported.
- **No channel policy view** — the policy modal + `/api/policy/:channel`
  endpoint not ported.
- **No WHOIS rendering** — `/whois` slash command enqueues but the result
  numerics aren't rendered to the message pane.
- **No msgid dedup on CHATHISTORY batch** — `freeq-webui` suppresses JOIN
  chathistory replay via BATCH tracking; this port relies on REST scrollback
  + `check_and_mark_msgid` for live lines but doesn't track BATCH ids.
- **Reaction live updates** — `ChatReflex#react`/`#unreact` enqueue the
  TAGMSG but the broadcaster doesn't yet parse `parse_tagmsg_reaction` to
  emit `reaction` CableReady events. Client-side optimistic toggle is
  wired in `chat_controller.js` but server-echoed reactions are a TODO.
- **Reactions cache** — `freeq-webui` caches reactions in localStorage so
  chips survive refresh; not ported.
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
- Nix flakes only see git-tracked files. Run `git add freeq-web2/` (index
  only, no commit needed) so `nix develop` can read the flake + sources.