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
