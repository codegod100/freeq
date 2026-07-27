# freeq-cli

A Gleam CLI IRC client for **[irc.freeq.at](https://irc.freeq.at)** — guest registration, IRCv3 capability negotiation, and a simple interactive prompt.

## Requirements

- [Gleam](https://gleam.run) ≥ 1.17
- Erlang/OTP (Erlang target)

## Build & run

```sh
gleam run
# or
gleam run -- --help
```

### Interactive (TLS, default server)

```sh
gleam run -- --nick myguest --channel '#playground'
```

Defaults: `irc.freeq.at:6697` with TLS.

### Plain TCP

```sh
gleam run -- -s irc.freeq.at:6667 --no-tls -n myguest -c '#playground'
```

### One-shot message

```sh
gleam run -- -n botnick -c '#playground' --send 'hello from gleam'
```

### Verbose (raw IRC)

```sh
gleam run -- -v -n myguest -c '#playground'
```

## Slash commands

| Command | Description |
|---------|-------------|
| `/join #channel` | Join and focus a channel |
| `/part [#channel]` | Leave a channel |
| `/focus #channel` | Change current channel without JOIN |
| `/msg nick text` | Private message |
| `/nick name` | Change nickname |
| `/me action` | CTCP ACTION |
| `/names [#channel]` | List names |
| `/raw LINE` | Send a raw IRC line |
| `/quit [reason]` | Disconnect |
| `/help` | Help |

Plain text is sent to the current channel.

## Auth note

This client connects as a **guest** (no AT Protocol / SASL). That is enough to join public channels and chat on freeq. Authenticated Bluesky/DID login is left for a later version (would need OAuth or key signing).

## Layout

```
src/
  freeq_cli.gleam           # entrypoint
  freeq_cli_ffi.erl         # stdin + getenv
  freeq_cli/
    config.gleam            # CLI flags
    transport.gleam         # TCP/TLS via neon
    irc.gleam               # IRCv3 message parse/format
    client.gleam            # registration + interactive loop
```

## Test

```sh
gleam test
```
