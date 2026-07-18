# Agent Assistance

The freeq agent assistance interface is a structured diagnostic surface that lets a bot ask the server **why** something happened — instead of guessing from raw IRC numerics, log files, or trial-and-error.

It's a small set of HTTP tools at `/agent/tools/*`, advertised at `/.well-known/agent.json`. Each tool returns a **conclusion** (a typed `diagnosis` code), a short summary a human can read, and machine-actionable fields a bot can branch on. No raw state, no leaks — answers are filtered by who's asking.

This guide walks through a real session captured against `irc.freeq.at` on 2026-04-26, using the bot in [`examples/full-validation-bot/`](https://github.com/chad/freeq/tree/main/examples/full-validation-bot) as the canonical implementation.

## What it's for

A standard IRC bot reacts to wire-level events. When a JOIN fails, you get numeric `477` and a string. When a PRIVMSG bounces, you get nothing — silence, sometimes a NOTICE. To build a bot that handles edge cases without a spec sheet open in another window, you have to either:

- **hard-code numerics** and hope the server's interpretation matches yours, or
- **ask the server** what it actually meant.

Agent assistance is the second option.

A practical bot loop looks like:

| Stage | Tool | Why |
|---|---|---|
| boot | `discovery` (`/.well-known/agent.json`) | confirm tools available |
| boot | `validate_client_config` | gate startup if your CAPs are wrong |
| post-auth | `inspect_my_session` | sanity-check the server's view of you |
| join failure | `diagnose_join_failure` | structured cause + fix |
| pre-send | `predict_message_outcome` | skip sends that would be rejected (rate-limit, +m, not in channel) |
| reconnect | `replay_missed_messages` | gap report |
| on mention | `explain_message_routing` | classify wire lines without parsing them yourself |

Every tool returns the same envelope:

```json
{
  "ok": true,
  "diagnosis": { "code": "SESSION_REPORTED", "summary": "..." },
  "safe_facts": [ "...", "..." ],
  "suggested_action": "..."
}
```

## Discovery

```bash
$ curl -s https://irc.freeq.at/.well-known/agent.json
```

```json
{
  "service": "Freeq",
  "version": "0.1.0",
  "description": "Agent-facing assistance interface for Freeq client validation and diagnostic queries. Returns conclusions, never raw state.",
  "assistance_endpoint": "/agent/tools",
  "capabilities": [
    "validate_client_config",
    "diagnose_message_ordering",
    "diagnose_sync",
    "inspect_my_session",
    "diagnose_join_failure",
    "diagnose_disconnect",
    "replay_missed_messages",
    "predict_message_outcome",
    "explain_message_routing"
  ],
  "auth": { "required": false, "methods": ["bearer"] }
}
```

Anyone can call any tool. **Whether you get a useful answer depends on who you are.** Most tools have a SELF_ONLY filter: if you're not authenticated, or if the question is about a session/account that isn't yours, the server returns a `*_SELF_ONLY` denial and no facts. That's the security model — the surface is public; the disclosure is gated.

## Authentication: bridging SASL → HTTP

The tools live at `/agent/tools/*` (HTTPS). Your IRC connection lives at `wss://irc.freeq.at/irc`. Bridging the two is the **API-BEARER NOTICE**:

```
:server NOTICE * :API-BEARER stream-9...
```

The server emits this once, immediately after SASL `903`. The token names your IRC stream session. Send it as `Authorization: Bearer stream-9...` on `/agent/tools/*` calls and the server resolves the bearer back to your DID and your live session — so SELF_ONLY tools answer fully.

In `@freeq/sdk` (TypeScript) the SDK captures this for you:

```typescript
client.on('connectionStateChanged', async (state) => {
  if (state === 'connected') {
    // brief delay for the post-SASL NOTICE to land
    await new Promise(r => setTimeout(r, 1500));
    if (client.apiBearer) {
      // use client.apiBearer as the Authorization: Bearer ... value
    }
  }
});
```

## A live session against `irc.freeq.at`

Below is the verbatim transcript of a fresh did:key bot connecting to production, joining `#dev` (succeeds), trying `#freeq` (fails, gated by policy), and using the assistance surface to understand why and what to do.

The bot's source is `examples/full-validation-bot/index.ts`. Run it yourself with `npm install && npm start` from that directory.

### 1. Discover what the server offers

```
GET /.well-known/agent.json →
  • validate_client_config
  • diagnose_message_ordering
  • diagnose_sync
  • inspect_my_session
  • diagnose_join_failure
  • diagnose_disconnect
  • replay_missed_messages
  • predict_message_outcome
  • explain_message_routing
```

### 2. Pre-flight: is my client config sane?

`validate_client_config` is **public** — no auth needed. Call it before you connect. If it warns about missing CAPs, fix them or refuse to boot.

```
POST /agent/tools/validate_client_config
  diagnosis: CONFIG_OK
  summary:   Client configuration looks compatible with current server expectations.
```

### 3. SASL with did:key, capture the bearer

The bot generates an ed25519 keypair, encodes the public key as `did:key:z6Mk…`, and authenticates via SASL ATPROTO-CHALLENGE with `method: "crypto"` (no PDS, no OAuth). On success the server emits the API-BEARER NOTICE and the SDK exposes it as `client.apiBearer`.

```
nick:    demobotzmf
DID:     did:key:z6MkrvPv3FVcpffV721SY27f72hDXmvRXAhARsJAxXMWTuqU
bearer:  captured (stream-9…)
```

### 4. `inspect_my_session` — what does the server actually see?

This is the single most useful tool for a long-running bot. Drift between your local state and the server's authoritative state is the #1 source of "why did my bot do X?" bugs. Ask, don't guess:

```
POST /agent/tools/inspect_my_session  { "account": "did:key:z6Mk..." }
Authorization: Bearer stream-9...

  diagnosis: SESSION_REPORTED
    • Account `did:key:z6Mkrv...TuqU` has 1 active session(s).
    • Current nick: `demobotzmf`.
    • Declared actor class: `human`.
    • AWAY: not set.
    • Client signing key registered: yes.
    • Negotiated capabilities: message-tags, server-time, batch, echo-message,
      account-notify, extended-join, away-notify, multi-prefix
    • Joined channels (1): `#dev`.
```

Without authentication this same call returns `INSPECT_MY_SESSION_SELF_ONLY` and an empty `safe_facts: []`. With the bearer, the bot now knows: it's signed in once, on the right nick, with the CAPs it expects, and the message-signing key it just registered is live.

### 5. Try to join `#freeq` — fails — `diagnose_join_failure` explains it

The bot tries to JOIN `#freeq`. The SDK fires `joinGateRequired`. Without the assistance surface the bot would just see numeric `477` and stop. Instead:

```
POST /agent/tools/diagnose_join_failure  { "account": "...", "channel": "#freeq", "observed_numeric": "477" }

  diagnosis: JOIN_DENIED
  summary:   2 reason(s) prevent did:key:z6Mk... from joining `#freeq`.
    • Channel `#freeq` exists with 2 local member(s).
    • Channel `#freeq` may have a join policy. Fetch /api/v1/policy/#freeq
      for the full requirement set.
    • Observed IRC numeric 477: ERR_NOCHANMODES (freeq usage) — channel
      requires policy proof acceptance.
  suggested:  GET /api/v1/policy/#freeq to see what proofs are required.
```

The bot now has a concrete next action: pull the policy, decide whether it can satisfy the proof requirements, and either present a credential or give up gracefully — instead of retrying the JOIN forever or silently dropping the channel from its config.

### 6. Who's in the channel I did join?

The bot calls `inspect_my_session` and learns it's in `#dev` only. To enumerate members, the SDK uses RPL_NAMREPLY:

```
#dev:
  • oauth_scopes
  • chadfowler.com
  • demobotzmf  (← that's the bot)
```

### 7. Who's in `#freeq`, even though we couldn't join?

For channels where membership is gated, the public REST API (`/api/v1/users`) reports recently-active accounts without joining. The bot uses this to learn what humans are around without bouncing off the policy:

```
recently active in #freeq: nandi.latha.org
```

This is intentional: discovery is public, participation is gated.

### 8. `predict_message_outcome` — gate every send

Before sending, ask: would this reply succeed? The predictor knows the channel modes (`+m`, `+b`, `+r`), the rate limiter's current state for this session, and whether the bot is even a member.

```
POST /agent/tools/predict_message_outcome  { "account": "...", "target": "#dev" }

  target #dev:    PREDICTED_ACCEPTED — A PRIVMSG to `#dev` from did:key:... should be accepted.
  target #freeq:  PREDICTED_ACCEPTED
    • Sender has 1 live session(s); best one has 0 send(s) in the last 2s window
      (limit 5/2s, so 5 send(s) of headroom).
```

If the predictor returns `PREDICTED_REJECTED`, the bot logs the reason and **doesn't send** — instead of blasting a message destined to bounce.

```typescript
async function safeSend(client, did, target, text) {
  const pred = await callTool('predict_message_outcome', { account: did, target });
  if (pred?.diagnosis?.code === 'PREDICTED_REJECTED') {
    console.warn(`[pre_send] BLOCKED: ${target} — ${pred.diagnosis.summary}`);
    return false;
  }
  client.sendMessage(target, text);
  return true;
}
```

### 9. `explain_message_routing` — interpret a wire line without parsing it

Useful when building mention-detection or routing logic. Hand the server a raw IRC line and let it tell you what it is:

```
POST /agent/tools/explain_message_routing
  { "wire_line": ":alice!u@h PRIVMSG #dev :hey demobot can you help with X?",
    "my_nick": "demobotzmf" }

  diagnosis: ROUTING_EXPLAINED
    • Command: `PRIVMSG`.
    • Sender:  `alice`.
    • Target:  `#dev` (channel).
    • Buffer to route into: `#dev` (bot logic should display the message there).
```

False-positive guard: if the bot's mention heuristic says "looks like me" but `explain_message_routing` says it isn't, trust the server.

## Anonymous vs authenticated, side by side

Same SDK, same calls, same channel — the only difference is the bearer:

```
Anonymous (no bearer):
  preflight    -> discovery                  (no-diagnosis)
  preflight    -> validate_client_config     (CONFIG_OK)
  join_failure -> diagnose_join_failure      (DIAGNOSE_JOIN_FAILURE_SELF_ONLY)  ← denied
  pre_send     -> predict_message_outcome    (PREDICT_MESSAGE_OUTCOME_SELF_ONLY) ← denied

Authenticated (bearer captured from API-BEARER NOTICE):
  preflight    -> discovery                  (no-diagnosis)
  preflight    -> validate_client_config     (CONFIG_OK)
  post_auth    -> inspect_my_session         (SESSION_REPORTED)
  pre_send     -> predict_message_outcome    (PREDICTED_ACCEPTED)
  explain      -> explain_message_routing    (ROUTING_EXPLAINED)
```

The SELF_ONLY denials aren't bugs — they're the disclosure model. Public surface, gated answers.

## Adding it to your own bot

Three pieces:

1. **Generate a did:key** (or load an existing seed):

   ```typescript
   import { generateDidKey, importDidKey } from '@freeq/sdk';
   const id = fs.existsSync('./seed.bin')
     ? await importDidKey(new Uint8Array(fs.readFileSync('./seed.bin')))
     : await generateDidKey();
   if (!fs.existsSync('./seed.bin'))
     fs.writeFileSync('./seed.bin', await id.exportSeed(), { mode: 0o600 });
   ```

2. **Authenticate via the crypto SASL method**:

   ```typescript
   const client = new FreeqClient({
     url: 'wss://irc.freeq.at/irc',
     nick: 'mybot',
     channels: ['#dev'],
     sasl: { method: 'crypto', did: id.did, signer: id.signer, token: '', pdsUrl: '' },
   });
   ```

3. **Capture the bearer + call tools**:

   ```typescript
   client.on('connectionStateChanged', async (state) => {
     if (state === 'connected') {
       await new Promise(r => setTimeout(r, 1500));
       const bearer = client.apiBearer;
       const r = await fetch('https://irc.freeq.at/agent/tools/inspect_my_session', {
         method: 'POST',
         headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${bearer}` },
         body: JSON.stringify({ account: id.did }),
       });
       console.log(await r.json());
     }
   });
   ```

That's it — no PDS, no OAuth flow, no broker. The bot's identity is the keypair on disk; the server resolves `did:key:z…` in-process.

## Logging for production

The full-validation-bot writes every request/response pair to `validation.log` as JSONL. In production you want this — drift between what your bot thinks happened and what the server reports is invaluable when triaging "why did my bot stop replying?":

```bash
tail -f validation.log | jq -c '{stage, tool, code: .response.diagnosis.code}'
```

## Reference

- **Canonical bot:** [`examples/full-validation-bot/index.ts`](https://github.com/chad/freeq/tree/main/examples/full-validation-bot) — exercises every tool and acts on the answers.
- **SDK helpers:** `generateDidKey`, `importDidKey`, `client.apiBearer` in [`@freeq/sdk`](/docs/typescript-sdk/).
- **Discovery:** [`https://irc.freeq.at/.well-known/agent.json`](https://irc.freeq.at/.well-known/agent.json).
- **Server tests proving the round-trip:** `freeq-server/tests/agent_assist_authenticated.rs::did_key_sasl_resolves_locally_without_pds`.
