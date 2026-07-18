# AV Bridge Status (2026-04-05)

## What's working

- Browser-to-browser audio via MoQ SFU (fully working)
- iroh-live Room creation on session start
- RoomTicket delivery via IRC NOTICE
- Native client connecting via WebSocket IRC, receiving ticket, joining Room
- Native client publishes mic audio to Room
- Server bridge sees MoQ cluster broadcasts (announce/unannounce)
- Native client sees server's peer in Room and subscribes to bridged broadcasts

## What's NOT working

### MoQ→Room (browser audio to native client)
The bridge uses `RemoteBroadcast::new(name, consumer)` which reads and consumes the
catalog.json track during construction. When the bridge then tries to re-forward through
a new BroadcastProducer with dynamic track forwarding, the catalog is already consumed
from the source. The native client gets a broken catalog and drops the subscription.

**Fix:** Don't wrap in RemoteBroadcast. Pass the raw BroadcastConsumer directly to the
Room's MoQ transport. Use `Live::publish_broadcast_producer()` or the session's
`.publish(name, consumer)` method instead of going through the high-level Room API.

### Room→MoQ (native audio to browser)  
No RoomEvents are being received by the bridge. The server creates the Room but the
native client may not be able to reach the server's iroh endpoint through Miren's proxy
(iroh QUIC traffic on port 4443 may be blocked). If the Room's gossip layer can't
establish a connection, no peer events will fire.

**Fix:** Either:
1. Expose port 4443 UDP on Miren for iroh QUIC traffic
2. Or configure iroh relay so the native client can reach the server through a relay
3. Or test locally first where ports aren't blocked

## Architecture note

The bridge is the hardest part because it sits between two different MoQ transport
layers (WebSocket MoQ via moq_relay::Cluster and iroh QUIC MoQ via iroh-live rooms).
Both use moq_lite types (BroadcastConsumer, BroadcastProducer) but they run on
different connections with different routing semantics.

The cleanest approach may be to have the server join its own Room as a peer (using
iroh-live's API) and then use the MoqSession directly to publish/subscribe, rather
than going through the Room's high-level publish_producer API.
