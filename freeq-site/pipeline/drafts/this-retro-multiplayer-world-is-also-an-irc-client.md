# This retro multiplayer world is also an IRC client

*2026-07-26*

Open [freeqworld](https://world.freeq.at) and you land in a top-down pixel
world that looks like it fell out of 1992. There's a lobby. There are people
standing around in it, rendered as little sprites. Walk up to someone and type,
and a speech bubble appears over your head.

Now open irssi, join the same room, and watch that speech bubble arrive as a
plain IRC message.

Not a bridge. Not a webhook relaying between two systems. The same room. The
world is a freeq client — the sprites are participants, the lobby is a channel,
and the message you typed was an ordinary IRC event the whole time.

**Rooms are channels.** The room you spawn into is `#lobby`. Walking through a
door doesn't "open a chat overlay" — it joins you to a channel. Walking out
parts you from it. Your position in the world is your membership in a room, and
the room existed before the graphics did.

**The sprites are identities.** Each character is drawn deterministically from
the participant's DID — the same DID that owns their nick, their ops, and their
message history. You aren't looking at a username with a costume. You're looking
at a rendering of a cryptographic identity, and two clients that have never met
will draw the same person the same way.

**The NPCs are agents.** The things standing around that aren't people are
running processes with their own `did:key` identities, joined to the same
channels through the same mechanism you did. `cartographer` and `archivist` are
in `#lobby` as you read this, and their hostmasks say `freeq/key/z6Mkp5we` and
`freeq/key/z6Mku6cV` — the same shape of identity a human gets, minted from a
different kind of key. There is no bot API here that differs from the human API.
An agent in the world and an agent in irssi are the same participant.

**Doors are policy.** A room you can't enter isn't a locked graphic; it's a
channel whose policy you don't satisfy. The door is the honest UI for a
membership decision that happens in the protocol.

That's the whole trick, and it isn't a trick: the world is not a game with chat
bolted on, and it is not a chat app with a game skin. It's one substrate with
two renderings. A pixel world and a terminal are equally valid views of the same
rooms, because the rooms were never owned by either one.

## The wire

Here's what your speech bubble looks like on the way out — the same event, seen
from a raw socket instead of a canvas:

```
@account=did:plc:4qsyxmnsblo4luuycm3572bq;msgid=01KTC7AY5JPAZ8GXQVYTVJG327;\
+freeq.at/sig=qSFPlTzaA4w7dKktQDZsP6S-f5pL4Vm8ja-5y1sYyS_lYoT2TyddGlq-XkZH3fTNMIv2tl-EY9JH7TE0hVLdDA \
:chadfowler.com!chadfowler.com@freeq/plc/4qsyxmns PRIVMSG #lobby :this server is lit
```

That's a real line off the wire, not an illustration. The `account` tag is my
Bluesky DID. The `sig` is the signature over the message. The hostmask says
`freeq/plc/4qsyxmns` — the server is telling every client in the room which
identity produced this, in a field old clients have always known how to ignore.

An old client ignores the tags and shows you a sentence. A freeq client reads
them and knows who signed it. Same bytes, two audiences — which is the reason
any of this works at all, and the subject of the next proof.

## Try it

**See it (30 seconds).** [The clip](#) — the world on the left, irssi on the
right, one message crossing between them.

**Run it (5 minutes).** Open [freeqworld](https://world.freeq.at), walk into
the lobby, say something. Then point any IRC client at the same room:

```
/connect -tls irc.freeq.at 6697
/join #lobby
```

Say something from irssi. Watch it appear over your sprite's head.

**Extend it (30 minutes).** The world is just a client. Write another one — read
the channel, draw the room however you like. Or put an object in the lobby that
posts to the channel when someone touches it. Both are ordinary IRC programs.

## What this does not claim

This post is a demonstration of one idea: that a room can be rendered two
completely different ways because the room is protocol, not product. It is not a
security claim.

- **The world does not prove anything is private.** `#lobby` is a public channel.
  Encrypted rooms exist in freeq and are a separate proof — don't infer them from
  this one.
- **Signatures are shown, not audited.** You can see that messages carry
  identity. Whether that identity chain holds up under an adversary is proof 3's
  job, and it deserves the scrutiny.
- **The sprite is not an authentication factor.** A deterministic avatar makes
  identities recognizable to humans. It is not a substitute for checking a DID.
- **Nothing here says the server is trustworthy.** It relays events. The next
  proof is about how little it is allowed to matter.

## Come in

The builder channel is `#freeq-dev`, on the same server, and we're in it. If you
render a room, write a participant, or break something, that's where to bring it.

Next proof: **the server is the least interesting part.** We'll open a raw socket
and show you the event grammar this world is standing on.
