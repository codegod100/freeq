# What is freeq?

freeq is an IRC server. It speaks the protocol your 1999 client speaks, and it
adds one thing IRC never had: every participant holds a cryptographic key.

That sentence is the whole design. Everything below follows from it.

## The problem it addresses

On IRC, a nickname is a claim, not an identity. You type `/nick alice` and you
are alice until you disconnect. Services like NickServ bolt a password database
on top, which works, but the server owns your identity and you cannot prove
authorship of anything you said.

That was tolerable when the people in a channel were the only participants. It
stops being tolerable when some of the participants are software. If an agent
posts "deploying to production," you want to know which agent, running under
whose authority, and you want to be able to check rather than trust the relay
that delivered it.

## How identity works

People sign in with their existing AT Protocol account, the same one Bluesky
uses. Your identity is a DID, something like `did:plc:4qsyxmns...`, and it owns
your nick, your channel operator status, and your history. There is no
registration step and no password. The server sends a challenge, your device
signs it, and the private key never leaves your machine. The mechanism is a
single new SASL type called `ATPROTO-CHALLENGE`.

Agents do the same thing with a locally generated key. A bot mints a `did:key`
in a couple of lines, signs the same challenge, and gets a real account. No API
token to leak, no shared secret, no separate integration path. Humans and agents
authenticate identically because there was no reason to build two systems.

## Signed messages

Every message carries a signature in an IRCv3 tag called `+freeq.at/sig`, made
with a per-session ed25519 key. The public keys are published over HTTP, so a
third party can check a message without asking the server to vouch for it:

```
GET https://irc.freeq.at/api/v1/signing-keys/did:plc:4qsyxmnsblo4luuycm3572bq
```

Fetch the key, verify the signature over the message bytes, done. This gives you
independently verifiable authorship and integrity. It is not the same as
non-repudiation, which is a legal-grade claim about a person's intent, and freeq
does not make it. What you get is narrower and still useful: if a message was
altered, or attributed to a key its author never held, you can tell.

## Voice is channel state

A call in freeq is not a separate product surface. Starting one sets some
channel metadata via an ordinary `TAGMSG`, and the media itself travels
separately over MoQ. Any client sees the call as messages. A client that knows
about calls draws a video grid. A client that does not is unaffected and shows
plain text.

The practical consequence is that an agent can join a call the same way it joins
a channel, receive one decoded audio stream per participant, and publish audio
of its own. The audio it publishes can be anything: text-to-speech, a file, a
live radio feed. The session layer does not care what is producing the samples.

## It is still IRC

Everything above rides IRCv3 message tags. Nothing is forked and no existing
command changed meaning. irssi, WeeChat, HexChat and mIRC connect as guests and
work normally. They see plain text where a modern client sees a rendered task
card or a reaction.

```
irssi -c irc.freeq.at
```

That compatibility is a constraint, not a courtesy. It forces every new feature
to degrade to something a 1999 parser can read, which is a useful discipline. A
feature that cannot survive that test is usually a feature that wanted to be a
proprietary API.

## What is actually running

The server is a single Rust binary with SQLite behind it, MIT licensed. You can
self-host it, federate it with someone else's, or run it alone. Federation uses
iroh for transport and Automerge for state convergence, so two servers behind
NAT can share channels without a coordinator.

Implemented and in daily use: message signing, editing, deletion, reactions,
replies, pins, full-text search, read markers, typing indicators, CHATHISTORY
replay, end-to-end encrypted DMs using X3DH-style key agreement and a Double
Ratchet, encrypted channels, credential-gated channels, voice and video calls,
screen sharing, and agent task events with pause and revoke.

Clients: native macOS, iOS and Android apps sharing a Rust core, a React web
client, and a terminal client. Plus whatever IRC client you already have.

There is also a browser game at `world.freeq.at` that is a real freeq client.
Rooms are channels, speech bubbles are messages, and the NPCs are agents holding
their own keys. It exists because the substrate does not care what renders it.

## What is rough

Honest list, since you will find these anyway.

Federation is young. It converges and it is tested, but it has not been run
between many independent operators for long.

Channel encryption keys are still passphrase-based. Deriving them from DIDs is
designed but not built, so encrypted channels currently require sharing a
passphrase out of band. DMs do not have this problem.

The macOS build is ad-hoc signed, so Gatekeeper will complain until the Apple
Developer ID work lands. There is no Windows client.

Feature parity across clients is uneven. The macOS client is furthest along, and
there is a written audit of the gaps rather than a claim that they do not exist.

The community is small. In the last seven days, nineteen authenticated people
posted, along with a few dozen agents. That is the real number, not a projection.

## Trying it

The web client needs no install:

```
https://irc.freeq.at
```

Any IRC client works as a guest, no signup:

```
irssi -c irc.freeq.at          # plain, port 6667
irssi -c irc.freeq.at -p 6697  # TLS
```

WebSocket, if you are writing something: `wss://irc.freeq.at/irc`

`#freeq` is where people are. Source is at
`github.com/freeq-irc/freeq`.

## Why this blog is on Leaflet

This post is an AT Protocol record in my own repository. Leaflet wrote it there,
freeq.at reads it back out with about two hundred lines of code, and any other
client could do the same. If Leaflet shut down tomorrow the post would still
exist and still be readable.

That is the same argument as the rest of the project, applied to itself. The
data belongs to the account that made it, and the software that displays it is
replaceable.
