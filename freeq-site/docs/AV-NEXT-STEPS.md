# AV Next Steps

**Date:** 2026-04-03
**Branch:** `av-sessions`

## Where we are

**Working:**
- Session lifecycle (create/join/leave/end) — server, IRC, REST, S2S, DB
- Web UI — phone icon, session badge, participant count, leave/end buttons
- Native client audio — two `freeq-av` instances can call each other via iroh-live Rooms (proven working, heard audio)
- iroh-live Rooms on the server — server creates Room, native clients join via ticket, gossip discovery works
- SFU skeleton — moq_relay::Cluster + moq_native::Server compiles and accepts connections
- Miren staging deploys with `av-native` feature (iroh-live + SFU deps)
- Port 30443 exposed on Miren via `node_port`

**Not working:**
- Browser audio — the SFU web page is a placeholder, no actual WebTransport/MoQ code
- Native ↔ Browser — Room API (native) and MoQ Cluster (SFU) are separate systems with no bridge
- Cross-network native calls — iroh QUIC can't traverse Miren's NAT (works on same machine only)

## The core architecture problem

We have two media transport paths that don't talk to each other:

1. **iroh-live Rooms** — gossip-based peer discovery, QUIC streams. Works for native-to-native on the same network.
2. **MoQ Cluster (SFU)** — accepts WebTransport sessions, routes named broadcasts. Works for browser-to-browser through a relay.

The server is in both worlds but doesn't bridge them.

## Recommended path: MoQ everywhere

**Drop the Room API for media transport. Use MoQ through the SFU for all clients.**

Rooms are great for peer-to-peer discovery on a local network, but they don't work across NATs (as we discovered) and they don't interop with the MoQ Cluster. The SFU already solves NAT traversal (browsers connect to a known server) and routing (Cluster handles pub/sub).

The architecture becomes:

```
Native client ──MoQ/QUIC──→ SFU (Cluster) ←──WebTransport── Browser
                                ↕
                         Routes broadcasts
                         between all clients
```

No Room API. No gossip. All media flows through the SFU. The server is the routing point.

### What this means concretely:

**Server (av_sfu.rs):**
- SFU accepts both iroh QUIC connections (native) and WebTransport (browser) via moq_native::Server
- Cluster routes named broadcasts between sessions
- When a session starts, the SFU creates a broadcast namespace (session ID)
- Each participant publishes `{session_id}/{nick}/audio` and subscribes to all others

**Native client (freeq-av-client):**
- Connect to SFU via `Moq::connect(sfu_endpoint)` instead of `Room::new()`
- Publish audio as a named MoQ broadcast
- Subscribe to other participants' broadcasts
- Still uses iroh-live's `AudioBackend` + `LocalBroadcast` for mic capture/playback

**Browser client:**
- Use `@moq/publish` and `@moq/watch` npm packages (proven working in relay's web page)
- Connect to SFU via WebTransport on port 30443
- Same publish/subscribe pattern as native client

**Session management (unchanged):**
- IRC TAGMSG for session lifecycle
- REST API for session info
- Server tracks participants, distributes SFU connection details instead of Room tickets

## Implementation plan

### Step 1: SFU with browser audio (1 session)

Get two browsers hearing each other through the SFU.

- [ ] Integrate `@moq/publish` and `@moq/watch` into the freeq web client (or serve relay's pre-built web page from SFU)
- [ ] Browser captures mic, publishes via WebTransport to SFU
- [ ] SFU Cluster routes audio between browser sessions
- [ ] Browser receives and plays remote audio
- [ ] Wire into session UI — clicking "Audio" starts publish/subscribe

### Step 2: Native client via MoQ

Get native client connecting to SFU instead of Room.

- [ ] `freeq-av` connects to SFU via `Moq::connect(endpoint)`
- [ ] Publishes audio as MoQ broadcast
- [ ] Subscribes to other participants' MoQ broadcasts
- [ ] Test: native client + browser in same SFU session

### Step 3: Clean up

- [ ] Remove Room-based code from server (av_media.rs Room creation)
- [ ] Remove iroh-live Room dependency if only using MoQ
- [ ] Update session flow — server provides SFU endpoint address instead of Room ticket
- [ ] Update architecture doc

### Step 4: Integrate into channel UX

- [ ] Audio panel embedded in freeq web client (not popup)
- [ ] Participant audio indicators (speaking, muted)
- [ ] Proper leave/end cleanup (stop audio on session end)

## What to keep from current work

- All session management code (av.rs, messaging.rs TAGMSG handlers, S2S, REST API, DB)
- SFU skeleton (av_sfu.rs — just needs the Cluster wired to actual sessions)
- Native client CLI structure (just swap Room for MoQ connect)
- Web UI (SessionIndicator, TopBar integration)
- Miren deployment with av-native feature flag
- iroh-live for audio capture/encode/decode (AudioBackend, LocalBroadcast, codecs)

## What to change

- Media transport: Room API → MoQ through SFU
- Server: creates SFU namespace per session, not iroh-live Room
- Native client: MoQ::connect to SFU instead of Room::new
- Browser: WebTransport to SFU via @moq web components
- Tickets: SFU endpoint address + session name, not Room gossip ticket
