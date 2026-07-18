# freeq-logger-bot

Reference bot built on `@freeq/sdk` that subscribes to **every** event the
SDK emits and writes them to stdout + a JSON-Lines file.

The bot:

1. Probes `/.well-known/agent.json` and logs the discovered capabilities.
2. Connects to the freeq IRC server over WebSocket as a guest.
3. Joins the configured channels.
4. Logs every typed event (43 of them) plus every raw IRC line.
5. Quits cleanly on SIGINT or after `FREEQ_QUIT_AFTER_MS`.

Use it as a starting point for a logger / archiver / observer bot, or
as a debugging aid when you're building a more complex bot and want to
see exactly what the server is sending.

## Run

```bash
cd examples/logger-bot
npm install
npm start
```

Defaults: connects to `wss://irc.freeq.at/irc`, joins `#freeq`, writes
to `./events.jsonl` next to `package.json`.

## Configure

| Env var | Default | Notes |
|---|---|---|
| `FREEQ_SERVER` | `wss://irc.freeq.at/irc` | Pass `ws://127.0.0.1:8080/irc` for local |
| `FREEQ_NICK` | `logbot-XXXX` (random) | Bot's IRC nick |
| `FREEQ_CHANNELS` | `#freeq` | Comma-separated `#channel` list |
| `FREEQ_LOGFILE` | `./events.jsonl` | Append-only JSONL |
| `FREEQ_QUIT_AFTER_MS` | (run forever) | Auto-disconnect after N ms (smoke tests) |

## Log format

One JSON object per line:

```json
{"ts":"2026-04-26T19:00:00.000Z","bot":"logbot-x4f1","kind":"message","payload":[...]}
```

`payload` is the SDK's variadic event args, with `Map`/`Set`/`Date`
converted to plain values so it stays JSON-serialisable.

## Tail the live feed

```bash
tail -f events.jsonl | jq .
```

## Events captured

Connection: `connectionStateChanged`, `registered`, `nickChanged`,
`authenticated`, `authError`, `ready`.

Channels: `channelJoined`, `channelLeft`, `memberJoined`, `memberLeft`,
`membersList`, `membersCleared`, `memberDid`, `topicChanged`,
`modeChanged`.

Users: `userQuit`, `userRenamed`, `userAway`, `userKicked`, `invited`,
`whois`.

Messages: `message`, `messageEdited`, `messageDeleted`, `reactionAdded`,
`reactionRemoved`, `typing`, `systemMessage`.

History + DMs: `historyBatch`, `dmTarget`.

Channel listing: `channelListEntry`, `channelListEnd`.

Pins: `pins`, `pinAdded`, `pinRemoved`.

AV sessions: `avSessionUpdate`, `avSessionRemoved`, `avTicket`.

Other: `joinGateRequired`, `motdStart`, `motd`, `error`, plus `raw`
(every IRC line received).

## Adding handlers

To do something with the messages instead of just logging:

```ts
client.on('message', (channel, msg) => {
  if (msg.text.startsWith('!ping')) {
    client.sendMessage(channel, 'pong');
  }
});
```

Adding it before `client.connect()` is enough — the SDK delivers events
to all listeners, in registration order.
