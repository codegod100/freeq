//! Auto-op on join must be announced *after* the JOIN.
//!
//! A user whose DID is in a channel's persistent `did_ops` is re-opped
//! automatically when they rejoin. The server was broadcasting
//! `MODE <chan> +o <nick>` *before* the `JOIN`, so members already in the channel
//! received an op change for someone they did not yet know was present.
//!
//! Clients defensively ignore modes for unknown members — they must, or a stray
//! MODE invents phantom members — so the op status was silently dropped. It
//! looked like "macOS says zapnap isn't op, web says he is": whoever connected
//! *after* the op existed saw it in their NAMES reply and was correct, while
//! anyone already sitting in the channel had discarded the MODE and was wrong,
//! until they reconnected.
//!
//! The fix is ordering, not client-side leniency: JOIN establishes presence,
//! then MODE modifies it.

use std::io::{BufRead, BufReader, Write};
use std::net::{SocketAddr, TcpStream};
use std::time::Duration;

use freeq_sdk::auth::{self, ChallengeSigner, KeySigner};
use freeq_sdk::crypto::PrivateKey;
use freeq_sdk::did::DidResolver;

async fn start() -> (SocketAddr, tokio::task::JoinHandle<anyhow::Result<()>>) {
    let tmp = tempfile::NamedTempFile::new().unwrap();
    let db = tmp.path().to_str().unwrap().to_string();
    std::mem::forget(tmp);
    let config = freeq_server::config::ServerConfig {
        listen_addr: "127.0.0.1:0".to_string(),
        server_name: "test-op-order".to_string(),
        challenge_timeout_secs: 60,
        db_path: Some(db),
        ..Default::default()
    };
    freeq_server::server::Server::with_resolver(config, DidResolver::static_map(Default::default()))
        .start()
        .await
        .unwrap()
}

struct C {
    reader: BufReader<TcpStream>,
    writer: TcpStream,
}

impl C {
    /// Authenticated connection with a self-resolving did:key.
    fn sasl(addr: SocketAddr, nick: &str) -> (Self, String) {
        let key = PrivateKey::generate_ed25519();
        let did = format!("did:key:{}", key.public_key_multibase());
        let s = TcpStream::connect(addr).unwrap();
        s.set_read_timeout(Some(Duration::from_secs(5))).ok();
        let w = s.try_clone().unwrap();
        let mut c = Self { reader: BufReader::new(s), writer: w };
        c.tx("CAP LS 302");
        c.tx(&format!("NICK {nick}"));
        c.tx(&format!("USER {nick} 0 * :test"));
        c.tx("CAP REQ :sasl message-tags server-time");
        c.rx(|l| l.contains("ACK"), "ACK");
        c.tx("AUTHENTICATE ATPROTO-CHALLENGE");
        let ch = c.rx(|l| l.starts_with("AUTHENTICATE "), "challenge");
        let bytes =
            auth::decode_challenge_bytes(ch.strip_prefix("AUTHENTICATE ").unwrap()).unwrap();
        let resp = KeySigner::new(did.clone(), key).respond(&bytes).unwrap();
        c.tx(&format!("AUTHENTICATE {}", auth::encode_response(&resp)));
        c.rx(|l| l.split_whitespace().nth(1) == Some("903"), "903");
        c.tx("CAP END");
        c.rx(|l| l.split_whitespace().nth(1) == Some("001"), "001");
        (c, did)
    }

    /// Same as `sasl` but with a caller-supplied identity, for multi-device.
    fn sasl_with(addr: SocketAddr, nick: &str, did: &str, key: PrivateKey) -> Self {
        let s = TcpStream::connect(addr).unwrap();
        s.set_read_timeout(Some(Duration::from_secs(5))).ok();
        let w = s.try_clone().unwrap();
        let mut c = Self { reader: BufReader::new(s), writer: w };
        c.tx("CAP LS 302");
        c.tx(&format!("NICK {nick}"));
        c.tx(&format!("USER {nick} 0 * :test"));
        c.tx("CAP REQ :sasl message-tags server-time");
        c.rx(|l| l.contains("ACK"), "ACK");
        c.tx("AUTHENTICATE ATPROTO-CHALLENGE");
        let ch = c.rx(|l| l.starts_with("AUTHENTICATE "), "challenge");
        let bytes =
            auth::decode_challenge_bytes(ch.strip_prefix("AUTHENTICATE ").unwrap()).unwrap();
        let resp = KeySigner::new(did.to_string(), key).respond(&bytes).unwrap();
        c.tx(&format!("AUTHENTICATE {}", auth::encode_response(&resp)));
        c.rx(|l| l.split_whitespace().nth(1) == Some("903"), "903");
        c.tx("CAP END");
        c.rx(|l| l.split_whitespace().nth(1) == Some("001"), "001");
        c
    }

    fn tx(&mut self, l: &str) {
        writeln!(self.writer, "{l}\r").unwrap();
        self.writer.flush().ok();
    }

    fn rx(&mut self, p: impl Fn(&str) -> bool, what: &str) -> String {
        let mut b = String::new();
        loop {
            b.clear();
            match self.reader.read_line(&mut b) {
                Ok(0) => panic!("EOF waiting for {what}"),
                Ok(_) => {
                    let l = b.trim_end().to_string();
                    if l.starts_with("PING") {
                        let t = l.strip_prefix("PING ").unwrap_or(":x").to_string();
                        self.tx(&format!("PONG {t}"));
                        continue;
                    }
                    if p(&l) {
                        return l;
                    }
                }
                Err(e) => panic!("{what}: {e}"),
            }
        }
    }

    /// Collect lines until `stop` matches, returning everything seen in order.
    fn collect_until(&mut self, stop: impl Fn(&str) -> bool, what: &str) -> Vec<String> {
        let mut out = Vec::new();
        loop {
            let l = self.rx(|_| true, what);
            let done = stop(&l);
            out.push(l);
            if done {
                return out;
            }
        }
    }

    fn drain(&mut self, ms: u64) {
        self.writer.set_read_timeout(Some(Duration::from_millis(ms))).ok();
        let mut b = String::new();
        loop {
            b.clear();
            match self.reader.read_line(&mut b) {
                Ok(0) => break,
                Ok(_) => {
                    if b.starts_with("PING") {
                        let t = b.trim_end().strip_prefix("PING ").unwrap_or(":x").to_string();
                        let _ = writeln!(self.writer, "PONG {t}\r");
                        let _ = self.writer.flush();
                    }
                }
                Err(_) => break,
            }
        }
        self.writer.set_read_timeout(Some(Duration::from_secs(5))).ok();
    }
}

#[tokio::test]
async fn auto_op_mode_arrives_after_the_join() {
    let (addr, server) = start().await;
    tokio::task::spawn_blocking(move || {
        // Alice creates the channel, so she is founder + op.
        let (mut alice, _alice_did) = C::sasl(addr, "alice");
        alice.tx("JOIN #ops");
        alice.rx(|l| l.split_whitespace().nth(1) == Some("366"), "alice names end");

        // Bob joins and is granted ops by Alice, which persists his DID in did_ops.
        let (mut bob, _bob_did) = C::sasl(addr, "bob");
        bob.tx("JOIN #ops");
        bob.rx(|l| l.split_whitespace().nth(1) == Some("366"), "bob names end");
        alice.tx("MODE #ops +o bob");
        bob.rx(|l| l.contains("MODE") && l.contains("+o") && l.contains("bob"), "bob opped");
        alice.drain(300);

        // Bob leaves and rejoins. Now the auto-op path fires: his DID is in
        // did_ops, so the server re-ops him as part of the join.
        bob.tx("PART #ops");
        alice.rx(|l| l.contains("PART") && l.contains("bob"), "alice sees part");
        alice.drain(300);
        bob.tx("JOIN #ops");

        // What Alice — already in the channel — receives, in order.
        let lines = alice.collect_until(
            |l| l.contains("MODE") && l.contains("+o") && l.contains("bob"),
            "alice sees bob re-opped",
        );
        let join_at = lines
            .iter()
            .position(|l| l.contains("JOIN") && l.contains("bob"))
            .unwrap_or(usize::MAX);
        let mode_at = lines
            .iter()
            .position(|l| l.contains("MODE") && l.contains("+o") && l.contains("bob"))
            .expect("MODE +o bob");

        assert!(
            join_at != usize::MAX,
            "alice never saw bob's JOIN, only:\n  {}",
            lines.join("\n  ")
        );
        assert!(
            join_at < mode_at,
            "MODE +o arrived BEFORE the JOIN, so a member already in the channel \
             gets an op change for a nick it does not yet know and must discard it.\n  \
             lines in order:\n  {}",
            lines.join("\n  ")
        );

        alice.tx("QUIT");
        bob.tx("QUIT");
    })
    .await
    .unwrap();
    server.abort();
}

// ── Variants of the same class ───────────────────────────────────────────────
//
// The class: "a state change announced about an entity the receiver may not know
// about yet". Ordering is one failure mode (MODE before JOIN). Never announcing
// at all is the other. Both leave clients with a different picture of the room
// than the server has.

/// The channel creator is opped on creation. Their OWN client needs to be told,
/// after its own JOIN — otherwise the person who made the channel doesn't see
/// themselves as op and can't use op-only UI.
#[tokio::test]
async fn creator_sees_their_own_op_after_their_own_join() {
    let (addr, server) = start().await;
    tokio::task::spawn_blocking(move || {
        let (mut alice, _) = C::sasl(addr, "alice");
        alice.tx("JOIN #brandnew");
        let lines = alice.collect_until(
            |l| l.split_whitespace().nth(1) == Some("366"),
            "alice's own join completes",
        );
        let join_at = lines.iter().position(|l| l.contains("JOIN") && l.contains("alice"));
        let mode_at = lines
            .iter()
            .position(|l| l.contains("MODE") && l.contains("+o") && l.contains("alice"));
        assert!(join_at.is_some(), "no self JOIN:\n  {}", lines.join("\n  "));
        assert!(
            mode_at.is_some(),
            "the creator is op server-side but was never told:\n  {}",
            lines.join("\n  ")
        );
        assert!(
            join_at < mode_at,
            "self MODE +o before self JOIN:\n  {}",
            lines.join("\n  ")
        );
        alice.tx("QUIT");
    })
    .await
    .unwrap();
    server.abort();
}

/// The rejoining op must be told about their OWN op, too. Other members knowing
/// is not enough: zapnap's own client needs it to render op-only affordances.
#[tokio::test]
async fn rejoining_op_is_told_about_their_own_op() {
    let (addr, server) = start().await;
    tokio::task::spawn_blocking(move || {
        let (mut alice, _) = C::sasl(addr, "alice");
        alice.tx("JOIN #selfop");
        alice.rx(|l| l.split_whitespace().nth(1) == Some("366"), "alice joined");

        let (mut bob, _) = C::sasl(addr, "bob");
        bob.tx("JOIN #selfop");
        bob.rx(|l| l.split_whitespace().nth(1) == Some("366"), "bob joined");
        alice.tx("MODE #selfop +o bob");
        bob.rx(|l| l.contains("+o") && l.contains("bob"), "bob opped");

        bob.tx("PART #selfop");
        bob.drain(300);
        bob.tx("JOIN #selfop");
        let lines = bob.collect_until(
            |l| l.split_whitespace().nth(1) == Some("366"),
            "bob's rejoin completes",
        );
        assert!(
            lines.iter().any(|l| l.contains("MODE") && l.contains("+o") && l.contains("bob")),
            "bob was re-opped server-side but his own client was never told:\n  {}",
            lines.join("\n  ")
        );
        alice.tx("QUIT");
        bob.tx("QUIT");
    })
    .await
    .unwrap();
    server.abort();
}

/// A joining client must see its own JOIN before the member list, or the NAMES
/// reply describes a channel it does not believe it is in yet.
#[tokio::test]
async fn joiner_sees_its_own_join_before_names() {
    let (addr, server) = start().await;
    tokio::task::spawn_blocking(move || {
        let (mut alice, _) = C::sasl(addr, "alice");
        alice.tx("JOIN #order");
        let lines = alice.collect_until(
            |l| l.split_whitespace().nth(1) == Some("366"),
            "names end",
        );
        let join_at = lines.iter().position(|l| l.contains("JOIN")).expect("self JOIN");
        let names_at = lines
            .iter()
            .position(|l| l.split_whitespace().nth(1) == Some("353"))
            .expect("353 names");
        assert!(
            join_at < names_at,
            "NAMES arrived before the client's own JOIN:\n  {}",
            lines.join("\n  ")
        );
        alice.tx("QUIT");
    })
    .await
    .unwrap();
    server.abort();
}

/// The auto-op MODE must reach channel members only. A user in a different
/// channel must not learn who got opped where.
#[tokio::test]
async fn auto_op_mode_does_not_leak_to_non_members() {
    let (addr, server) = start().await;
    tokio::task::spawn_blocking(move || {
        let (mut alice, _) = C::sasl(addr, "alice");
        alice.tx("JOIN #private-room");
        alice.rx(|l| l.split_whitespace().nth(1) == Some("366"), "alice joined");

        // Carol is elsewhere and must hear nothing about #private-room.
        let (mut carol, _) = C::sasl(addr, "carol");
        carol.tx("JOIN #somewhere-else");
        carol.rx(|l| l.split_whitespace().nth(1) == Some("366"), "carol joined");
        carol.drain(200);

        let (mut bob, _) = C::sasl(addr, "bob");
        bob.tx("JOIN #private-room");
        bob.rx(|l| l.split_whitespace().nth(1) == Some("366"), "bob joined");
        alice.tx("MODE #private-room +o bob");
        bob.rx(|l| l.contains("+o"), "bob opped");
        bob.tx("PART #private-room");
        bob.drain(200);
        bob.tx("JOIN #private-room");
        alice.rx(|l| l.contains("MODE") && l.contains("+o") && l.contains("bob"), "alice sees it");

        // Carol should have received nothing mentioning the other channel.
        carol.writer.set_read_timeout(Some(std::time::Duration::from_millis(600))).ok();
        let mut leaked = String::new();
        let mut buf = String::new();
        loop {
            buf.clear();
            match carol.reader.read_line(&mut buf) {
                Ok(0) => break,
                Ok(_) => {
                    if buf.contains("private-room") {
                        leaked = buf.trim_end().to_string();
                        break;
                    }
                }
                Err(_) => break,
            }
        }
        assert!(leaked.is_empty(), "leaked to a non-member: {leaked}");
        alice.tx("QUIT");
        bob.tx("QUIT");
        carol.tx("QUIT");
    })
    .await
    .unwrap();
    server.abort();
}

/// Multi-device: opping a user must op the *user*, not one of their sockets.
///
/// `resolve_channel_target` returns a single session, and the mode is applied to
/// that session's id. A user signed in on two devices has two sessions, so the
/// other one keeps acting as a plain member even though the person is an op.
/// The attach path already handles the reverse case (a device connecting *after*
/// the op exists inherits it via DID authority), which is what makes this gap
/// easy to miss.
#[tokio::test]
async fn opping_a_multi_device_user_ops_all_their_devices() {
    let (addr, server) = start().await;
    tokio::task::spawn_blocking(move || {
        // Alice creates the channel: founder + op.
        let (mut alice, _) = C::sasl(addr, "alice");
        alice.tx("JOIN #multi");
        alice.rx(|l| l.split_whitespace().nth(1) == Some("366"), "alice joined");

        // Bob signs in on two devices BEFORE being opped, sharing one DID.
        // PrivateKey isn't Clone; round-trip the secret so both devices use the
        // same identity, which is exactly what two of your own clients do.
        let key = PrivateKey::generate_ed25519();
        let did = format!("did:key:{}", key.public_key_multibase());
        let secret = key.secret_bytes();
        let mut bob_a = C::sasl_with(addr, "bob", &did, key);
        bob_a.tx("JOIN #multi");
        bob_a.rx(|l| l.split_whitespace().nth(1) == Some("366"), "bob device A joined");
        // Device B is auto-attached to the DID's channels at registration (the
        // server synthesises the JOIN), so there is no second 366 to wait for.
        let mut bob_b =
            C::sasl_with(addr, "bob", &did, PrivateKey::ed25519_from_bytes(&secret).unwrap());
        bob_b.drain(500);
        bob_a.drain(200);
        bob_b.drain(200);

        // Alice ops bob (the person).
        alice.tx("MODE #multi +o bob");
        alice.rx(|l| l.contains("MODE") && l.contains("+o") && l.contains("bob"), "bob opped");
        bob_a.drain(300);
        bob_b.drain(300);

        // Device B exercises an op-only power. 482 = ERR_CHANOPRIVSNEEDED.
        bob_b.tx("MODE #multi +m");
        let reply = bob_b.rx(
            |l| {
                let n = l.split_whitespace().nth(1);
                n == Some("482") || (l.contains("MODE") && l.contains("+m"))
            },
            "device B mode result",
        );
        assert!(
            !reply.split_whitespace().nth(1).is_some_and(|n| n == "482"),
            "bob is an op, but his second device was refused an op action: {reply}\n\
             The mode was applied to one session id, so the person is only an op \
             on whichever socket happened to be resolved."
        );

        alice.tx("QUIT");
        bob_a.tx("QUIT");
        bob_b.tx("QUIT");
    })
    .await
    .unwrap();
    server.abort();
}

/// NAMES and permission checks must agree about who is an op.
///
/// Permissions consult the DID (`did_ops`), so any device of an op can act. But
/// NAMES builds its `@` prefix from the session-keyed `ch.ops`, and a MODE is
/// applied to the single session `resolve_channel_target` picked. With several
/// devices online, whichever session NAMES happens to enumerate first decides
/// whether the user renders as an op — so the member list can disagree with what
/// the server will actually let that user do.
#[tokio::test]
async fn names_shows_op_for_a_multi_device_user() {
    let (addr, server) = start().await;
    tokio::task::spawn_blocking(move || {
        let (mut alice, _) = C::sasl(addr, "alice");
        alice.tx("JOIN #namesmulti");
        alice.rx(|l| l.split_whitespace().nth(1) == Some("366"), "alice joined");

        // Four devices for bob; at most one session will carry the mode.
        let key = PrivateKey::generate_ed25519();
        let did = format!("did:key:{}", key.public_key_multibase());
        let secret = key.secret_bytes();
        let mut bob = C::sasl_with(addr, "bob", &did, key);
        bob.tx("JOIN #namesmulti");
        bob.rx(|l| l.split_whitespace().nth(1) == Some("366"), "bob joined");
        let mut extra: Vec<C> = (0..3)
            .map(|_| {
                let mut c = C::sasl_with(
                    addr, "bob", &did,
                    PrivateKey::ed25519_from_bytes(&secret).unwrap(),
                );
                c.drain(300);
                c
            })
            .collect();

        alice.tx("MODE #namesmulti +o bob");
        alice.rx(|l| l.contains("+o") && l.contains("bob"), "bob opped");
        alice.drain(300);

        alice.tx("NAMES #namesmulti");
        let names = alice.rx(|l| l.split_whitespace().nth(1) == Some("353"), "names");
        assert!(
            names.contains("@bob"),
            "bob is an op (all four of his devices can use op powers) but NAMES \
             renders him unopped: {names}\n\
             NAMES reads the session-keyed ch.ops while the MODE was applied to one \
             session, so the member list depends on which socket is enumerated first."
        );

        alice.tx("QUIT");
        bob.tx("QUIT");
        for c in extra.iter_mut() {
            c.tx("QUIT");
        }
    })
    .await
    .unwrap();
    server.abort();
}

/// De-opping must take the `@` away everywhere, not just from the one session
/// the mode was applied to.
#[tokio::test]
async fn deop_clears_the_prefix_for_a_multi_device_user() {
    let (addr, server) = start().await;
    tokio::task::spawn_blocking(move || {
        let (mut alice, _) = C::sasl(addr, "alice");
        alice.tx("JOIN #deopmulti");
        alice.rx(|l| l.split_whitespace().nth(1) == Some("366"), "alice joined");

        let key = PrivateKey::generate_ed25519();
        let did = format!("did:key:{}", key.public_key_multibase());
        let secret = key.secret_bytes();
        let mut bob = C::sasl_with(addr, "bob", &did, key);
        bob.tx("JOIN #deopmulti");
        bob.rx(|l| l.split_whitespace().nth(1) == Some("366"), "bob joined");
        let mut extra: Vec<C> = (0..3)
            .map(|_| {
                let mut c = C::sasl_with(
                    addr, "bob", &did,
                    PrivateKey::ed25519_from_bytes(&secret).unwrap(),
                );
                c.drain(300);
                c
            })
            .collect();

        alice.tx("MODE #deopmulti +o bob");
        alice.rx(|l| l.contains("+o") && l.contains("bob"), "opped");
        alice.drain(200);
        alice.tx("MODE #deopmulti -o bob");
        alice.rx(|l| l.contains("-o") && l.contains("bob"), "de-opped");
        alice.drain(200);

        alice.tx("NAMES #deopmulti");
        let names = alice.rx(|l| l.split_whitespace().nth(1) == Some("353"), "names");
        assert!(
            !names.contains("@bob"),
            "bob was de-opped but still renders as an op: {names}\n\
             The -o cleared one session from ch.ops; his other sessions remain in \
             it, so the prefix survives the de-op."
        );

        alice.tx("QUIT");
        bob.tx("QUIT");
        for c in extra.iter_mut() {
            c.tx("QUIT");
        }
    })
    .await
    .unwrap();
    server.abort();
}

// ── The same asymmetry at the other read sites ───────────────────────────────
//
// `ops`/`voiced` are keyed by SESSION; identity is keyed by DID. Every place
// that renders membership has to reconcile the two, and each one did it
// differently (or not at all). NAMES is fixed; these cover WHO and WHOIS.

/// WHO lists users, not sockets. A person signed in twice must appear once.
#[tokio::test]
async fn who_lists_a_multi_device_user_once() {
    let (addr, server) = start().await;
    tokio::task::spawn_blocking(move || {
        let (mut alice, _) = C::sasl(addr, "alice");
        alice.tx("JOIN #whodup");
        alice.rx(|l| l.split_whitespace().nth(1) == Some("366"), "alice joined");

        let key = PrivateKey::generate_ed25519();
        let did = format!("did:key:{}", key.public_key_multibase());
        let secret = key.secret_bytes();
        let mut bob = C::sasl_with(addr, "bob", &did, key);
        bob.tx("JOIN #whodup");
        bob.rx(|l| l.split_whitespace().nth(1) == Some("366"), "bob joined");
        let mut bob2 =
            C::sasl_with(addr, "bob", &did, PrivateKey::ed25519_from_bytes(&secret).unwrap());
        bob2.drain(400);
        alice.drain(300);

        alice.tx("WHO #whodup");
        let lines = alice.collect_until(
            |l| l.split_whitespace().nth(1) == Some("315"),
            "end of WHO",
        );
        let bob_rows: Vec<&String> = lines
            .iter()
            .filter(|l| l.split_whitespace().nth(1) == Some("352") && l.contains(" bob "))
            .collect();
        assert_eq!(
            bob_rows.len(),
            1,
            "bob is one person on two devices but WHO returned {} rows for him:\n  {}",
            bob_rows.len(),
            bob_rows.iter().map(|s| s.as_str()).collect::<Vec<_>>().join("\n  ")
        );

        alice.tx("QUIT");
        bob.tx("QUIT");
        bob2.tx("QUIT");
    })
    .await
    .unwrap();
    server.abort();
}

/// WHO must agree with NAMES and with what the server will let the user do.
#[tokio::test]
async fn who_shows_op_flag_for_a_multi_device_op() {
    let (addr, server) = start().await;
    tokio::task::spawn_blocking(move || {
        let (mut alice, _) = C::sasl(addr, "alice");
        alice.tx("JOIN #whoop");
        alice.rx(|l| l.split_whitespace().nth(1) == Some("366"), "alice joined");

        let key = PrivateKey::generate_ed25519();
        let did = format!("did:key:{}", key.public_key_multibase());
        let secret = key.secret_bytes();
        let mut bob = C::sasl_with(addr, "bob", &did, key);
        bob.tx("JOIN #whoop");
        bob.rx(|l| l.split_whitespace().nth(1) == Some("366"), "bob joined");
        let mut extra: Vec<C> = (0..3)
            .map(|_| {
                let mut c = C::sasl_with(
                    addr, "bob", &did,
                    PrivateKey::ed25519_from_bytes(&secret).unwrap(),
                );
                c.drain(300);
                c
            })
            .collect();

        alice.tx("MODE #whoop +o bob");
        alice.rx(|l| l.contains("+o") && l.contains("bob"), "opped");
        alice.drain(300);

        alice.tx("WHO #whoop");
        let lines = alice.collect_until(
            |l| l.split_whitespace().nth(1) == Some("315"),
            "end of WHO",
        );
        let bob_row = lines
            .iter()
            .find(|l| l.split_whitespace().nth(1) == Some("352") && l.contains(" bob "))
            .expect("a WHO row for bob");
        assert!(
            bob_row.contains("H@") || bob_row.contains("G@"),
            "bob is an op but his WHO flags omit @: {bob_row}"
        );

        alice.tx("QUIT");
        bob.tx("QUIT");
        for c in extra.iter_mut() {
            c.tx("QUIT");
        }
    })
    .await
    .unwrap();
    server.abort();
}

/// WHOIS lists a *remote* user's channels with an `@` for ops, but the local
/// branch emits no 319 at all — so `/whois` on someone on your own server tells
/// you nothing about where they are or what they can do.
#[tokio::test]
async fn whois_lists_channels_for_a_local_user() {
    let (addr, server) = start().await;
    tokio::task::spawn_blocking(move || {
        let (mut alice, _) = C::sasl(addr, "alice");
        alice.tx("JOIN #whoischan");
        alice.rx(|l| l.split_whitespace().nth(1) == Some("366"), "alice joined");

        let (mut bob, _) = C::sasl(addr, "bob");
        bob.tx("JOIN #whoischan");
        bob.rx(|l| l.split_whitespace().nth(1) == Some("366"), "bob joined");
        alice.tx("MODE #whoischan +o bob");
        alice.rx(|l| l.contains("+o"), "bob opped");
        alice.drain(300);

        alice.tx("WHOIS bob");
        let lines = alice.collect_until(
            |l| l.split_whitespace().nth(1) == Some("318"),
            "end of WHOIS",
        );
        let chans = lines
            .iter()
            .find(|l| l.split_whitespace().nth(1) == Some("319"));
        assert!(
            chans.is_some(),
            "WHOIS on a local user listed no channels (no 319). A remote user's \
             WHOIS does list them, with @ for ops:\n  {}",
            lines.join("\n  ")
        );
        assert!(
            chans.unwrap().contains("@#whoischan"),
            "bob is an op in #whoischan but WHOIS does not mark it: {}",
            chans.unwrap()
        );

        alice.tx("QUIT");
        bob.tx("QUIT");
    })
    .await
    .unwrap();
    server.abort();
}
