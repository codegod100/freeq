# freeq for Teams

The recipe: a private, self-hosted chat where access is gated by your
identity provider, membership offboarding actually revokes access, message
history is end-to-end encrypted, and your AI agents work in the same rooms
as your people — governable, attributable, auditable.

This page is the map; each step links to the full guide.

## 1. Run your server

One Rust binary, SQLite (optionally encrypted at rest), TLS via your
reverse proxy. The [end-to-end self-hosting guide](/docs/self-hosting-e2e/)
goes from empty VM to running server with backups; the
[self-hosting guide](/docs/self-hosting/) covers the individual pieces.

Optional hardening for a company instance:

- `--no-guest` — refuse unauthenticated connections entirely.
- Encrypted-at-rest database + secrets files.
- Federation off (standalone), or allowlisted peers only.

## 2. Gate access on your identity provider

Channel access in freeq is policy, not ops-whims: rules are expressed as
verifiable credentials, checked by verifiers, and every decision is signed
and auditable.

- Gate `#engineering` on GitHub org membership using the shipped GitHub
  verifier.
- Gate on your SSO by running a small custom verifier — the
  [verifier architecture](/docs/verifiers/) is decoupled from the server,
  so you build it as a standalone service with zero server changes.
- The [policy framework](/docs/policy-framework/) covers rule composition,
  transparency logs, and the credential lifecycle.

## 3. Make the sensitive channels E2EE

For channels where the server itself shouldn't be able to read history,
use credential-bootstrapped end-to-end encryption: members receive the
group key sealed to their device keys after presenting a valid credential;
key epochs rotate on membership change, so **offboarding someone revokes
their access to future messages** — no shared passphrase to rotate by hand.

- Tutorial: [Company E2EE channels](/docs/company-encrypted-channels/)
- Protocol: [VC-bootstrapped channel E2EE](/docs/vc-e2e-channels/)
- Threat model, honestly stated: [Encryption & security](/docs/encryption/)

## 4. Add your agents

This is where freeq stops being "self-hosted Slack" and becomes something
else. Your deploy bot, your on-call agent, your coding agents — they join
the same channels with `did:key` identities, sign their messages, emit
task cards humans can watch, and answer to governance verbs:

- `/msg deploy-agent pause` from any IRC client.
- TTL-bound capabilities: the incident agent's production access expires.
- Provenance: every agent declares its owner and code origin.

Start with the [agent quickstart](/docs/agent-quickstart/), then
[Building Agents](/docs/agents/). To watch your coding agent's runs in a
channel, see [Watch your coding agent](/docs/watch-your-agent/).

## 5. Let people use whatever client they want

Native macOS, iOS, Android, Windows, web, TUI — or irssi. Voice calls when
you need them (agents can join those too). No per-seat pricing, because
it's your server and it's MIT licensed.

## What you don't get (yet)

Read [known limitations](/docs/limitations/) before betting the company:
notable items include store-distributed mobile builds pending developer
accounts, and the honest list of what is and isn't encrypted at rest.
