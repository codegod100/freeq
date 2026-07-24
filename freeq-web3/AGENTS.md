# freeq-web3

Phoenix LiveView port of `freeq-web2`. See `../freeq-web2/AGENTS.md` for the
Rails/StimulusReflex BFF this was ported from, and `../freeq-webui/AGENTS.md`
for the original Rust/Topcoat implementation.

## Build

Workspace-sibling. From `freeq-web3/`:

```bash
nix develop          # preferred
mix setup            # deps + assets
mix phx.server       # http://127.0.0.1:4000
```

Without the flake: Elixir 1.17+, OTP 26+, Node for assets.

## Architecture

| Path | Role |
|------|------|
| `lib/freeq_web3/session/server.ex` | Per-browser GenServer: channels, members, outbound queue |
| `lib/freeq_web3/session/supervisor.ex` | DynamicSupervisor for sessions |
| `lib/freeq_web3/irc/upstream.ex` | Mint WebSocket client to freeq-server `/irc` |
| `lib/freeq_web3/irc/render.ex` | IRC parse + history row maps (port of `IrcRender`) |
| `lib/freeq_web3/rest.ex` | REST client for channels + history |
| `lib/freeq_web3_web/live/chat_index_live.ex` | `/chat` channel list |
| `lib/freeq_web3_web/live/chat_live.ex` | `/chat/:channel` shell |
| `lib/freeq_web3_web/live/user_session.ex` | `on_mount` → freeq_session cookie + start Session |
| `assets/css/app.css` | freeq dark theme (ported from web2 layout CSS) |

## Key decisions

- **LiveView over StimulusReflex**: mutations are `handle_event`, live IRC
  updates are PubSub → stream/assign pushes. No CableReady morph layer.
- **Server holds the upstream IRC WS** (BFF), same as web2/webui. The browser
  never opens `/irc` directly.
- **Mint + Mint.WebSocket** for the upstream client (OTP-friendly, no native
  deps beyond Erlang SSL).
- **Client-authoritative channel list**: `Session.Server` owns `channels`
  (My Channels). Only explicit join intent (`join` event / channel page visit
  via `add_channel`) mutates it. `ensure_upstream` only tracks routing.
- **Guest mode first**: SASL / OAuth / disk session store are deliberately
  out of the first cut so the LiveView + Upstream path is auditable alone.

## Porting checklist (from freeq-web2)

- [x] Session registry + per-session GenServer
- [x] Upstream IRC WS (guest CAP/NICK/USER)
- [x] Channel list + chat shell LiveViews
- [x] Send / join / part / topic
- [x] REST history + channel list
- [x] Member roster (353 / JOIN / PART / QUIT / MODE)
- [x] freeq dark theme CSS
- [ ] AT Protocol OAuth (`/login`, callback, client metadata)
- [ ] SASL ATPROTO-CHALLENGE + API-BEARER
- [ ] Encrypted session store (disk) + channel list persistence
- [ ] Reactions (TAGMSG +react / unreact)
- [ ] Message edit/delete UI
- [ ] DMs + E2EE key proxy
- [ ] Voice/video (call controller + MoQ)
- [ ] Link embeds + upload proxy
- [ ] PWA manifest + service worker
- [ ] Policy modal

## Nix-host notes

- **`nix develop`** is the recommended entry point (`freeq-web3/flake.nix`).
- Pure Nix flakes only see files in the **Git** tree. This monorepo uses
  colocated **jj**: finish a change that includes freeq-web3
  (`jj commit -m "…"`) so the flake can read sources, or as a last resort
  `git add freeq-web3/`. Prefer `jj` for all other VCS ops — see root
  `AGENTS.md` § Version control.

## Phoenix guidelines

See the generated Phoenix `AGENTS.md` sections below for LiveView/CSS rules.
Prefer structured assigns + streams over raw HTML morphs when extending chat.

---

This is a web application written using the Phoenix web framework.

## Project guidelines

- Use `mix precommit` alias when you are done with all changes and fix any pending issues
- Use the already included and available `:req` (`Req`) library for HTTP requests
