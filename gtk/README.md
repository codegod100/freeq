# freeq-gtk

Relm4 (GTK4 + libadwaita) **view renderer** for freeq. Gleam owns the UI model
and, on every update, sends a **complete view tree** over **Erlang distribution**.
GTK never invents widgets from chat protocol details — it only mounts whatever
snapshot arrived last, and ships UI events back.

```
┌──────────────────────────┐     full View snapshot      ┌─────────────────────┐
│  Gleam host              │  ─────────────────────────► │  freeq-gtk          │
│  freeq_gtk_view          │     {view, Title, …, Body}  │  (Relm4 renderer)   │
│                          │ ◄─────────────────────────  │  foreign dist node  │
│  freeq_view@localhost    │   {clicked|activate|…}      │  freeq_gtk@localhost│
└──────────────────────────┘                             └─────────────────────┘
```

## View protocol

One inbound message paints the whole window. Shape = native Gleam custom types
(see `gleam/src/freeq_gtk_view.gleam`):

```erlang
{view, Title :: binary(), Subtitle :: binary(),
       Width :: integer(), Height :: integer(),
       Body :: node()}

node() =
    {vbox, Id, Spacing, [node()]}
  | {hbox, Id, Spacing, [node()]}
  | {label, Id, Text, Dim :: boolean()}
  | {button, Id, Label, normal | suggested | destructive}
  | {entry, Id, Text, Placeholder, Password :: boolean()}
  | {list, Id, [binary()]}
  | {scrolled, Id, node()}
  | separator
  | spacer
```

### Events (GTK → Gleam)

Registered name on the host: **`freeq_view`** (override with `--peer-process`).

```erlang
{clicked, Id}
{activate, Id, Text}     %% entry Enter
{changed, Id, Text}      %% entry keystrokes (host may ignore remount)
{selected, Id, Index, Item}
```

Gleam should treat `changed` as draft state **without** pushing a new view on
every keystroke (avoids focus thrash). Push a full `View` after `activate` /
`clicked` (and whenever IRC/model state changes).

## Requirements

- Rust 1.93+, GTK 4, libadwaita, pkg-config
- Gleam ≥ 1.17 + Erlang/OTP (for the host)
- **epmd** running (any `erl -sname x` once)

```bash
nix-shell -p pkg-config gtk4 libadwaita rustc cargo gleam erlang
```

## Run (demo)

Terminal A — Gleam owns the view:

```bash
cd gtk/gleam
gleam run
# env: FREEQ_COOKIE freeq_dev
#      FREEQ_VIEW_NODE freeq_view@localhost
#      FREEQ_GTK_NODE freeq_gtk@localhost
```

Terminal B — GTK renderer:

```bash
cd gtk
cargo run -- --cookie freeq_dev --peer freeq_view@localhost
```

Type a message, press **Enter** or **Send**. Gleam appends a line and pushes a
new full `{view, …}` snapshot; GTK remounts from that structure alone.

### Pure Erlang peer (no Gleam)

```bash
./beam/demo.escript
cargo run -- --cookie freeq_dev --peer freeq_view@localhost
```

## CLI

| Flag / env | Default | Meaning |
|------------|---------|---------|
| `--node` / `FREEQ_GTK_NODE` | `freeq_gtk@localhost` | Local dist name |
| `--cookie` / `FREEQ_COOKIE` | `~/.erlang.cookie` or `freeq_dev` | Shared secret |
| `--peer` / `FREEQ_PEER` | _(last inbound peer)_ | Where to send events |
| `--peer-process` | `freeq_view` | Registered name on peer |
| `--published` | off | Non-hidden node |

## Layout

```
gtk/
  src/
    main.rs           # CLI
    app.rs            # Relm4 shell + remount
    view.rs           # View / Node / UiEvent + ETF decode
    render.rs         # View → GTK widgets
    dist/             # erl_dist foreign node
  gleam/
    src/freeq_gtk_view.gleam       # View DSL + chat_view helper
    src/freeq_gtk_view/host.gleam  # demo model loop
    src/freeq_gtk_view/dist.gleam  # push / recv
    src/freeq_gtk_view_ffi.erl     # net_kernel + event decode
  beam/demo.escript   # same protocol in pure Erlang
```

## Wiring freeq-web4

freeq-web4 owns the LiveView model and pushes a full `gtk_view.View` on every
model change. GTK events become `live.Msg` via the same session host.

```bash
# Terminal A — BFF (dist node web4@localhost, peer freeq_gtk@localhost)
cd freeq-web4
export FREEQ_GTK_NODE=freeq_gtk@localhost
export FREEQ_DIST_NODE=web4@localhost
export FREEQ_COOKIE=freeq_dev   # or $(cat ~/.erlang.cookie)
nix develop -c gleam run
# open http://127.0.0.1:4004/chat once so a Live session registers

# Terminal B — renderer
cd gtk
cargo run -- --cookie freeq_dev --peer web4@localhost
```

| Env (web4) | Default | Meaning |
|------------|---------|---------|
| `FREEQ_GTK_NODE` | _(empty = off)_ | freeq-gtk node to push Views to |
| `FREEQ_DIST_NODE` | `web4@localhost` | This BFF's dist name |
| `FREEQ_COOKIE` | `freeq_dev` | Shared with freeq-gtk |

Implementation: `freeq_web4/gtk_view.gleam` (View DSL + `from_model`),
`freeq_web4/gtk_bridge.gleam` (`freeq_view` process), hooks in `ws.gleam` /
`main`.

GTK stays a client renderer — it still does not speak IRC; the Gleam BFF does.

## Debugging dist (MCP)

Dev-dep [`erl_dist_mcp`](https://crates.io/crates/erl_dist_mcp) talks to BEAM
nodes over distribution (process lists, ETS, eval, etc.). Install the binary:

```bash
cargo install erl_dist_mcp --locked
```

Point an MCP client at it with Gleam-friendly output:

```json
{
  "mcpServers": {
    "erlang": {
      "command": "erl_dist_mcp",
      "args": ["--mode", "gleam"]
    }
  }
}
```

Then connect to e.g. `freeq_view@localhost` / `web4@localhost` with cookie
`freeq_dev` (same cookie as freeq-gtk).

## Notes

- Full snapshot replace is intentional (correctness first). Diff/patch can come later.
- Entry drafts are kept locally while focused so typing survives unrelated remounts;
  Gleam remains authoritative after `activate`.
- Distribution trusts the cookie — localhost / private network only unless you
  add proper transport security.
