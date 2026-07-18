# freeq-full-validation-bot

The flagship demo of the freeq validation surface used at full power.

A bot that:

1. **Generates a fresh did:key** (or imports a saved seed) — no PDS,
   no OAuth, no broker, no external service.
2. **Authenticates via SASL ATPROTO-CHALLENGE** using the new
   `crypto` method + signer callback in `@freeq/sdk`.
3. **Captures the API-BEARER NOTICE** the server emits on SASL
   success (via `client.apiBearer`).
4. **Calls every advertised diagnostic tool** with that bearer and
   uses the structured answers to drive its behaviour:

   | Stage | Tool | Bot uses the answer to… |
   |---|---|---|
   | preflight | `discovery` | confirm tools available |
   | preflight | `validate_client_config` | gate startup |
   | post_auth | `inspect_my_session` | sanity-check the server's view |
   | join_failure | `diagnose_join_failure` | structured cause + fix on a failed JOIN |
   | pre_send | `predict_message_outcome` | skip the send if the predictor says it would fail |
   | on_reconnect | `replay_missed_messages` | gap report on each rejoin |
   | on_mention | `explain_message_routing` | parse + classify a real wire line (false-positive guard for mentions) |

5. Logs every request + response to `validation.log` as JSONL.

The bot is **anonymous-but-cryptographically-identified** — its DID is
controlled solely by the keypair on disk in `./seed.bin`. Keep it to
keep the same identity between runs, delete it to rotate.

## Run

```bash
cd examples/full-validation-bot
npm install
npm start
```

Defaults: `wss://irc.freeq.at/irc`, `#dev`, random nick. Override
via env. **Note:** as of this writing, prod has the API-BEARER
NOTICE deployment-pending — until it ships, the bot will reach
`[ready]` but `client.apiBearer` will stay `null` and the SELF_ONLY
tools will deny. Run against a freshly-built local server to see
the full surface.

## Live transcript

`sample-validation.jsonl` is a real captured session showing every
diagnostic call the bot made during a 45-second smoke run:

```
1 preflight    -> discovery                  (no-diagnosis)
1 preflight    -> validate_client_config     (CONFIG_OK)
1 post_auth    -> inspect_my_session         (SESSION_REPORTED)
3 pre_send     -> predict_message_outcome    (PREDICTED_ACCEPTED)
3 explain      -> explain_message_routing    (ROUTING_EXPLAINED)
```

Compare with the anonymous-bot transcript from `karma-bot/`:

```
1 preflight    -> discovery                  (no-diagnosis)
1 preflight    -> validate_client_config     (CONFIG_OK)
1 join_failure -> diagnose_join_failure      (DIAGNOSE_JOIN_FAILURE_SELF_ONLY)
5 pre_send     -> predict_message_outcome    (PREDICT_MESSAGE_OUTCOME_SELF_ONLY)
```

Same SDK, same calls — auth flips the bottom 3 lines from `*_SELF_ONLY`
denials to `SESSION_REPORTED` / `PREDICTED_ACCEPTED` / `ROUTING_EXPLAINED`,
which the bot then acts on.

## Sample inspect_my_session response

What the server actually told the bot about itself:

```json
{
  "ok": true,
  "diagnosis": { "code": "SESSION_REPORTED", … },
  "safe_facts": [
    "Account `did:key:z6Mkodd…` has 1 active session(s).",
    "Current nick: `valbot5475`.",
    "Declared actor class: `human`.",
    "AWAY: not set.",
    "Client signing key registered: yes.",
    "Negotiated capabilities: message-tags, server-time, batch, echo-message, account-notify, extended-join, away-notify, multi-prefix",
    "Joined channels (1): `#dev`."
  ]
}
```

Drift between this and what the bot's local state thinks is the most
common bug source for long-running bots — the server's view is
authoritative.

## Configure

| Env var | Default | Notes |
|---|---|---|
| `FREEQ_SERVER` | `wss://irc.freeq.at/irc` | use `ws://127.0.0.1:8090/irc` for local |
| `FREEQ_NICK` | `valbot-XXXX` | random |
| `FREEQ_CHANNELS` | `#dev` | comma-separated |
| `FREEQ_SEED_FILE` | `./seed.bin` | identity persistence |
| `FREEQ_VALIDATION_LOG` | `./validation.log` | JSONL of every diagnostic call |
| `FREEQ_BEARER` | (auto from SASL) | manual override (skip auth, paste a bearer) |
| `FREEQ_QUIT_AFTER_MS` | (run forever) | smoke-run timeout |

## Test it yourself

In another shell with the bot running:

```bash
# DM commands
> /msg valbot-xxxx !inspect       # bot sends back its server-view facts
# In a channel
> !ping                           # → pong
> !whoami                         # → I am did:key:z6Mk… (nick=valbot-xxxx)
> !validate-help                  # → list of commands
```

Watch `validation.log` simultaneously:

```bash
tail -f validation.log | jq -c '{stage, tool, code: .response.diagnosis.code}'
```

Every reply preceded by a `pre_send → predict_message_outcome` call —
the bot is asking the server "would this go through?" before sending.
If the channel were +m and the bot weren't voiced, the predictor
would say `PREDICTED_REJECTED` and the bot would log + skip the send,
not blast a message that's going to bounce.

## Architecture

```
                            ┌─────────────────────────────────┐
       ed25519 keypair  →   │   generateDidKey()              │
                            │   • multibase pubkey            │
                            │   • signer(bytes) → base64url   │
                            └────────────┬────────────────────┘
                                         │ did:key:z6Mk…
                                         ▼
                            ┌─────────────────────────────────┐
                            │   FreeqClient ctor              │
                            │   sasl: { method: "crypto",     │
                            │           did, signer }         │
                            └────────────┬────────────────────┘
                                         │ ws upgrade
                                         ▼
                                   freeq-server
                            ┌─────────────────────────────────┐
                            │ AUTHENTICATE ATPROTO-CHALLENGE  │
                            │ → 903 SASL success              │
                            │ → NOTICE * :API-BEARER <sid>    │
                            └────────────┬────────────────────┘
                                         │
                            ┌────────────▼────────────────────┐
                            │ client.apiBearer = <sid>        │
                            │   ↓                             │
                            │ POST /agent/tools/<tool>        │
                            │   Authorization: Bearer <sid>   │
                            └─────────────────────────────────┘
```

No PDS, no OAuth, no broker, no `transition:generic` scope. Bot owns
its identity locally, server resolves did:key in-process, diagnostic
surface is fully unlocked. The auth-flow is verified end-to-end in
`freeq-server/tests/agent_assist_authenticated.rs::did_key_sasl_resolves_locally_without_pds`.
