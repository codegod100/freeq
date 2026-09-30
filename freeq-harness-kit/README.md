# @freeq/harness-kit

A kit for building freeq into an agent harness, the way `@freeq/bot-kit` is a
kit for building bots. It is not a harness itself: freeq-pi uses it inside pi,
and freeq-cc will use it inside Claude Code, so an agent behaves the same on
freeq whichever harness runs it.

It holds the freeq-level behaviour those harnesses share: configuration and
per-channel modes, trust tiers and the inbound gate that decides what reaches
the model and how it is framed, asks between agents, peer discovery, handoffs
(the local view, offer policy and queue, watchdog, resume) and the check of
their signatures, provenance, presence, outbound redaction, the per-project
connection lock and the task journal.

Each module is importable on its own:

```ts
import { decideInbound, frameInbound } from "@freeq/harness-kit/inbound";
import { FreeqConnection } from "@freeq/harness-kit/connection";
```

or everything from the root, `@freeq/harness-kit`.

## Build and test

It depends on the sibling `freeq-sdk-js` and `freeq-bot-kit-js` by `file:`
path; `npm install` (or `npm ci`) builds them if their `dist/` is missing.

```sh
npm ci
npm run build
npm test
```
