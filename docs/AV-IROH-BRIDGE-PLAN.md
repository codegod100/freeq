# AV iroh-live Bridge Plan

## Goal

Make iroh-live the primary media layer. Native clients connect directly via iroh QUIC (P2P when possible). Browser clients connect via MoQ WebSocket to the server, which bridges their audio into the iroh-live Room. The server is a bridge participant, not a relay for native clients.

## Demos

1. Native client joins a call and hears browser audio
2. Browser hears native client
3. Two native clients talk P2P (server not in media path)
4. Mixed call: 2 browsers + 1 native, everyone hears everyone
5. Latecomer joins mid-call, immediately hears audio
6. Participant disconnects ungracefully, others unaffected

---

## Demo 1: Native hears browser

### What we're proving
The server can take MoQ audio from a browser and republish it into an iroh-live Room so a native client hears it.

### Changes

**1. Create iroh-live Room on session start** (`connection/messaging.rs`, `av-start` handler)

Currently line 1670 says "No need to create iroh-live Rooms." Change this to:
- Call `backend.create_room(session_id)` to create a Room
- Store the `RoomTicket` string in `session.iroh_ticket`
- Persist to DB via `save_av_session`
- Send ticket to session creator via NOTICE
- The Room handle must be kept alive for the session's lifetime

`av_media.rs` already has the `create_room` method signature but it's a stub. Implement it:
```rust
async fn create_room(&self, session_id: &str) -> Result<String, String> {
    let ticket = RoomTicket::generate();
    let room = Room::new(self.live(), ticket.clone()).await?;
    let ticket_str = room.ticket().to_string();
    let (events, handle) = room.split();
    // Store handle + events in self.rooms
    self.rooms.lock().insert(session_id.to_string(), ActiveRoom { handle, events });
    Ok(ticket_str)
}
```

**2. Bridge MoQ→Room on the server** (new: `av_bridge.rs`)

When a browser publishes audio to the MoQ cluster, the server needs to take that audio and republish it into the iroh-live Room. The bridge:

- Spawns when the first browser participant joins
- Subscribes to MoQ broadcasts via `cluster.subscriber()` for the session namespace
- For each MoQ broadcast received, creates a `RemoteBroadcast` and uses `room_handle.publish()` to republish into the Room
- The key insight from `sfu.rs`: `BroadcastConsumer` is the common type between MoQ and iroh-live. `RemoteBroadcast::new(path, consumer)` wraps a MoQ stream for iroh-live consumption

Concretely:
```rust
// Subscribe to MoQ cluster announcements
let sub = cluster.subscriber(&token);
let origin = moq_lite::Origin::produce();
// ... wire sub into origin consumer
// Listen for announced broadcasts
while let Some((path, Some(consumer))) = consumer.announced().await {
    // Republish into iroh-live room
    room_handle.publish(&path, /* LocalBroadcast from consumer */).await;
}
```

**Challenge:** `room_handle.publish()` expects a `LocalBroadcast`, not a `BroadcastConsumer`. We may need to either:
- Create a `LocalBroadcast` that takes its data from the MoQ consumer instead of a microphone
- Or use the lower-level iroh-live broadcast API to publish raw frames

This is the riskiest part. Investigate iroh-live's `LocalBroadcast` API to see if it can be fed from a non-hardware source. If not, we may need to go lower-level and publish hang-formatted frames directly into the Room's gossip layer.

**Mitigation:** Before writing the full bridge, write a test that creates a `LocalBroadcast`, feeds it synthetic audio, and publishes to a Room. If this works, the bridge is straightforward. If `LocalBroadcast` only accepts hardware input, we need a different approach.

**3. Send RoomTicket to native client** (`connection/messaging.rs`, `av-join` handler)

When a native client sends `+freeq.at/av-join`, look up the session's `iroh_ticket` and send it back:
```irc
:server NOTICE nick :AV ticket: room1abc2def...
```

The native client already has room mode code that parses a RoomTicket and joins.

**4. Update native client** (`freeq-av-client/src/main.rs`)

Add a mode where the native client:
- Connects to the IRC server
- Sends `+freeq.at/av-join` TAGMSG
- Receives the RoomTicket from the NOTICE response
- Joins the Room directly (existing room mode code)

### What could go wrong

| Risk | Mitigation |
|------|------------|
| `LocalBroadcast` only accepts hardware audio input | Test early with synthetic input. Fallback: use raw iroh-live broadcast primitives |
| `BroadcastConsumer` format differs between MoQ cluster and iroh-live rooms | Both use hang format — verify by comparing frame headers |
| Room handle dropped too early | Store in `ActiveRoom` struct in `av_media.rs` rooms HashMap |
| RoomTicket not delivered before native client tries to connect | Native client should retry/poll if ticket not received within 5s |
| Bridge task panics | Wrap in tokio::spawn with error logging, don't crash the session |

### How to test

1. Start freeq-server locally with `--features av-native`
2. Open browser, sign in, join channel, start voice session
3. Verify browser audio works (existing MoQ path)
4. Run native client: `cargo run -p freeq-av-client -- room --ticket <TICKET_FROM_NOTICE>`
5. Speak in browser — native client should hear audio

---

## Demo 2: Browser hears native

### What we're proving
The reverse bridge: iroh-live Room audio reaches browser clients through MoQ.

### Changes

**1. Bridge Room→MoQ** (extend `av_bridge.rs`)

When a native client publishes audio to the Room, the server needs to take that audio and publish it into the MoQ cluster:

- Listen for `RoomEvent::BroadcastSubscribed` events from the Room
- For each new broadcast, get the `BroadcastConsumer` via `broadcast.consume()` (or the hang-formatted stream)
- Create a `moq_lite::Origin::produce()` and call `origin.publish_broadcast(path, consumer)`
- Register the origin with the cluster so browser subscribers see it

This is the exact pattern from `sfu.rs` lines 46-49:
```rust
let origin = moq_lite::Origin::produce();
origin.publish_broadcast(&broadcast_name, broadcast.consume());
```

But instead of a local microphone, the source is a remote participant's Room broadcast.

**2. Browser call page discovers Room participants** (already done)

The call page already polls `/api/v1/sessions/{id}` for participants and creates per-participant moq-watch elements. Native participants show up in the participant list, so browsers will auto-subscribe.

### What could go wrong

| Risk | Mitigation |
|------|------------|
| MoQ cluster publisher API differs from client-side `Origin` | Test by creating a server-side Origin and publishing a static broadcast |
| Browser's moq-watch doesn't recognize server-published broadcasts | Use same naming convention: `{session_id}/{nick}` |
| Bridge introduces latency (Room→decode→re-encode→MoQ) | No re-encoding needed — hang format is shared. Just pipe the BroadcastConsumer through |
| Multiple native clients = multiple bridge tasks | One bridge task per Room handles all participants via RoomEvent stream |

### How to test

1. Same setup as Demo 1
2. Speak into native client's microphone
3. Browser should hear audio through the MoQ path

---

## Demo 3: Two native clients P2P

### What we're proving
iroh-live handles direct P2P connections. The server creates the Room and distributes tickets but is NOT in the audio path.

### Changes

Minimal — this should work once Demo 1 is complete:

**1. Second native client joins same Room**

Both clients have the RoomTicket. iroh-live handles peer discovery via gossip and establishes direct QUIC connections. Audio flows peer-to-peer.

**2. Verify server is not in the media path**

Check server logs — there should be no bridge activity when two native clients are talking. The server only sees the IRC session control messages (join/leave), not audio data.

### What could go wrong

| Risk | Mitigation |
|------|------------|
| iroh can't establish direct connection (NAT/firewall) | iroh has relay fallback built in — audio will flow through iroh relay, still not through freeq server |
| Both clients try to bridge (if running on same machine) | Room mode doesn't bridge — only the server bridges |
| Audio feedback (hearing yourself) | Each client filters own broadcast by name, existing code in sfu.rs line 82 |

### How to test

1. Start two native clients on different machines (or different terminals)
2. Both join same room via ticket
3. Speak on one, hear on the other
4. Check server logs — no media bridge activity

---

## Demo 4: Mixed call (2 browsers + 1 native)

### What we're proving
Full N-party interop through the bridge. Every participant hears every other participant.

### Changes

None — this is a test of Demos 1+2 combined. The bridge handles:
- Browser A → MoQ → bridge → Room → Native C
- Browser B → MoQ → bridge → Room → Native C  
- Native C → Room → bridge → MoQ → Browser A + B
- Browser A → MoQ → Browser B (existing direct MoQ path)

### What could go wrong

| Risk | Mitigation |
|------|------------|
| Bridge publishes browser audio back to browsers (echo) | Bridge must only publish into the Room, not back into MoQ. Browser-to-browser stays on MoQ path |
| Native client hears its own audio bounced through bridge | Bridge should filter: don't republish Room broadcasts back into the Room |
| Participant list inconsistent between Room and session API | Session API is authoritative — Room participants are supplementary |
| Audio sync issues between MoQ and iroh-live paths | Both use Opus at 48kHz with similar jitter buffers — should be fine |

### How to test

1. Two browser tabs + one native client, all in same session
2. Each speaks in turn
3. Verify all three hear each other
4. Verify no echo or feedback loops

---

## Demo 5: Latecomer joins mid-call

### What we're proving
A participant joining after the call started gets audio immediately, with no manual intervention.

### Changes

**1. Bridge handles dynamic participants**

The bridge task must handle new participants joining the Room after it's started:
- `RoomEvent::BroadcastSubscribed` fires for each new peer — bridge picks it up
- New MoQ publisher added to cluster for the new participant
- Browser call page's 3-second polling picks up new participants automatically

**2. Native latecomer gets existing audio**

When a native client joins a Room that already has publishers, iroh-live fires `BroadcastSubscribed` for each existing broadcast. The native client starts hearing immediately.

**3. Browser latecomer**

Already works — the call page polls participants and creates moq-watch elements for each. As long as the MoQ cluster has the broadcasts (from the bridge), new browsers hear existing participants.

### What could go wrong

| Risk | Mitigation |
|------|------------|
| Bridge doesn't detect late-joining native clients | Test that RoomEvent stream continues producing events after initial setup |
| MoQ cluster drops old broadcasts before latecomer subscribes | MoQ is live-streaming, not recorded — latecomer hears from join point forward. This is expected |
| Stale moq-watch elements from previous participants | Call page already removes watch elements for participants who left |

### How to test

1. Start call with browser A
2. Wait 30 seconds
3. Join with native client — should hear browser A immediately
4. Wait 30 seconds
5. Join with browser B — should hear both A and native

---

## Demo 6: Ungraceful disconnect

### What we're proving
The system handles crashes without affecting other participants.

### Changes

Already implemented in this session:
- `cleanup_session_state` calls `leave_all_for_did` on disconnect
- Session auto-ends when last participant leaves
- Periodic pruning catches stuck sessions

**Additional for iroh-live:**

**1. Room event handling for peer disconnect**

`RoomEvent::PeerLeft` fires when an iroh-live peer disconnects. The bridge should:
- Remove the corresponding MoQ publisher from the cluster
- Clean up the bridge task for that peer

**2. Bridge task crash recovery**

If the bridge task itself panics or errors, the session should still function:
- Browser-to-browser: still works via MoQ (bridge failure only affects cross-protocol)
- Native-to-native: still works via Room (bridge failure only affects cross-protocol)
- Log the error and attempt to restart the bridge

### What could go wrong

| Risk | Mitigation |
|------|------------|
| iroh-live Room collapses when creator leaves | Room should persist as long as any participant is in it — verify this |
| Bridge task holds Room handle, dropping it kills Room | Arc-wrap the Room handle so it's shared between bridge and session manager |
| MoQ cluster doesn't clean up publisher on disconnect | Dropping the publisher handle should deregister — verify |
| Ghost participants in UI | Session API cleanup (already implemented) removes them within periodic pruning cycle |

### How to test

1. Start 3-party mixed call (2 browsers + 1 native)
2. Kill browser A's tab (not graceful close)
3. Verify B and native still hear each other
4. Kill native client process
5. Verify browser B continues without error
6. Check session participant count updates correctly

---

## Implementation Order

```
Phase 1: Server creates Rooms (foundation)
  ├─ Implement create_room in av_media.rs
  ├─ Wire into av-start handler in messaging.rs
  ├─ Send RoomTicket via NOTICE
  ├─ Store ticket in session + DB
  └─ Keep Room handle alive for session lifetime

Phase 2: MoQ→Room bridge (Demo 1)
  ├─ Write av_bridge.rs
  ├─ Subscribe to MoQ cluster for session broadcasts
  ├─ Republish into iroh-live Room
  ├─ *** TEST: can LocalBroadcast accept non-hardware input? ***
  └─ Test: browser speaks, native hears

Phase 3: Room→MoQ bridge (Demo 2)
  ├─ Listen for RoomEvent::BroadcastSubscribed
  ├─ Publish Room broadcasts into MoQ cluster
  ├─ Test: native speaks, browser hears

Phase 4: Integration testing (Demos 3-6)
  ├─ P2P native-to-native
  ├─ Mixed N-party call
  ├─ Latecomer scenarios
  └─ Crash recovery

Phase 5: Cleanup
  ├─ Close Room on session end
  ├─ Clean up bridge tasks on participant leave
  └─ Update architecture docs
```

## Key Risk: LocalBroadcast Input Source

The single biggest unknown is whether `iroh_live::media::publish::LocalBroadcast` can accept audio from a non-hardware source (i.e., from a MoQ `BroadcastConsumer`). 

If YES: the bridge is straightforward — pipe MoQ consumer into LocalBroadcast, publish to Room.

If NO: we need to either:
1. Use lower-level iroh-live APIs to publish raw hang-formatted frames into the Room
2. Decode Opus from MoQ, re-encode into whatever iroh-live accepts
3. Ask the iroh-live maintainers if there's a programmatic input API

**Action: Test this FIRST before writing any bridge code.** Write a 20-line program that creates a LocalBroadcast, tries to feed it synthetic Opus frames, and publishes to a Room. If it compiles and runs, we're clear. If not, investigate alternatives before proceeding.
