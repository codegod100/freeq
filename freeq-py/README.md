# freeq-textual

Python `textual` TUI for freeq backed by the Rust `freeq-sdk` through `PyO3`.

## Build

```sh
cd freeq-py
maturin develop
```

## Run

### Guest connection (no auth):

```sh
freeq-textual --server irc.freeq.at:6697 --nick guest --channel '#freeq' --tls
```

### Authenticated connection (AT Protocol DID):

```sh
# Interactive browser auth on startup
freeq-textual --auth-handle you.bsky.social --channel '#freeq' --tls

# Or with cached session
freeq-textual --session-path ~/.freeq/session.json --channel '#freeq' --tls

# Or with web token
freeq-textual --web-token <token> --channel '#freeq' --tls
```

## Features

- ✅ **AT Protocol authentication** - Browser-based OAuth with session caching
- ✅ **Guest connections** - Connect without authentication
- ✅ **Channel support** - Join, part, and manage channels
- ✅ **Member lists** - Live channel member list with away status
- ✅ **Message history** - IRCv3 CHATHISTORY support with pagination
- ✅ **Replies & threads** - Threaded conversation view with reply navigation
- ✅ **Message editing** - Edit sent messages inline
- ✅ **Emoji reactions** - Add/view reactions on messages
- ✅ **Rich rendering** - Syntax-highlighted code blocks, URLs, mentions
- ✅ **Emoji picker** - Interactive emoji selection with search
- ✅ **TLS support** - Secure connections with cert verification
- ✅ **Layout system** - Customizable panel layouts
- ✅ **Debug tools** - Built-in logging and diagnostics panels

## CLI Options

| Option | Description |
|--------|-------------|
| `--server` | IRC server host:port (default: irc.freeq.at:6697) |
| `--nick` | Nickname to use (default: textual) |
| `--channel` | Channel to auto-join on connect |
| `--auth-handle` | ATProto handle for browser auth on startup |
| `--session-path` | Path to cached broker session JSON |
| `--web-token` | One-time web token for authenticated connect |
| `--broker-url` | External auth broker base URL |
| `--freeq-server-url` | Freeq server URL for broker web-token minting |
| `--tls` | Connect with TLS |
| `--tls-insecure` | Skip TLS certificate verification |
| `--config-path` | Path to UI config JSON |

## Environment Variables

- `FREEQ_BROKER_URL` - Auth broker URL
- `FREEQ_SESSION_PATH` - Default session file path
- `FREEQ_WEB_TOKEN` - Web token for auth
- `FREEQ_SERVER_URL` - Server URL for broker
- `BROKER_SHARED_SECRET` - Shared secret for embedded broker

## Keyboard Shortcuts

| Key | Action |
|-----|--------|
| `Tab` | Focus next input |
| `Shift+Tab` | Focus previous input |
| `Ctrl+L` | Focus message input |
| `Ctrl+J` | Join channel prompt |
| `Ctrl+P` | Open emoji picker |
| `Ctrl+R` | Reply to message under cursor |
| `Ctrl+E` | Edit selected message |
| `Ctrl+D` | Delete selected message |
| `Ctrl+T` | Toggle thread panel |
| `Ctrl+N` | Next buffer |
| `Ctrl+B` | Previous buffer |
| `F1` | Toggle debug panel |

## Architecture

The app uses a component-based architecture:

- **`app.py`** - Main application logic, event handling, message routing
- **`bootstrap.py`** - App factory with dependency injection
- **`client.py`** - freeq-sdk wrapper for IRC connection
- **`components/`** - Swappable UI components registry
- **`widgets/`** - Textual widgets (message panels, emoji picker, thread view)
- **`formatting.py`** - Message rendering and syntax highlighting

Components are registered in `components/all.py` and can be swapped at runtime via the registry pattern.

## Development

```sh
# Quick dev loop
just dev-textual

# Or manually
cd freeq-py && maturin develop && python -m freeq_textual --tls --channel '#test'
```
