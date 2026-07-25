//! End-to-end acceptance tests for the machine-readable AV failure signal
//! (`+freeq.at/av-error` TAGMSG — docs/AV-SESSION-AUDIT.md F3).
//!
//! Real TCP server + real SDK clients. These pin the exact wire behavior the
//! clients' ghost-teardown logic depends on: a rejected av-join and a lost
//! av-start race must each produce a machine-readable TAGMSG (the human
//! NOTICE alone is invisible to code — that gap produced production ghost
//! callers publishing into sessions they were never admitted to).

use std::collections::HashMap;
use std::time::Duration;

use freeq_sdk::client::{self, ClientHandle, ConnectConfig};
use freeq_sdk::did::DidResolver;
use freeq_sdk::event::Event;
use tokio::sync::mpsc;
use tokio::time::timeout;

async fn start_test_server() -> (
    std::net::SocketAddr,
    tokio::task::JoinHandle<anyhow::Result<()>>,
) {
    let config = freeq_server::config::ServerConfig {
        listen_addr: "127.0.0.1:0".to_string(),
        server_name: "test-server".to_string(),
        challenge_timeout_secs: 60,
        ..Default::default()
    };
    let server = freeq_server::server::Server::with_resolver(
        config,
        DidResolver::static_map(HashMap::new()),
    );
    server.start().await.unwrap()
}

async fn connect_guest(
    addr: std::net::SocketAddr,
    nick: &str,
) -> (ClientHandle, mpsc::Receiver<Event>) {
    let config = ConnectConfig {
        server_addr: addr.to_string(),
        nick: nick.to_string(),
        user: nick.to_string(),
        realname: nick.to_string(),
        ..Default::default()
    };
    let (handle, mut events) = client::connect(config, None);
    expect_event(
        &mut events,
        3000,
        |e| matches!(e, Event::Registered { .. }),
        "Registered",
    )
    .await;
    (handle, events)
}

async fn expect_event(
    events: &mut mpsc::Receiver<Event>,
    timeout_ms: u64,
    predicate: impl Fn(&Event) -> bool,
    description: &str,
) -> Event {
    let deadline = Duration::from_millis(timeout_ms);
    let start = tokio::time::Instant::now();
    loop {
        match timeout(deadline.saturating_sub(start.elapsed()), events.recv()).await {
            Ok(Some(event)) => {
                if predicate(&event) {
                    return event;
                }
            }
            Ok(None) => panic!("Channel closed while waiting for: {description}"),
            Err(_) => panic!("Timeout waiting for: {description}"),
        }
    }
}

fn av_error_tags(e: &Event) -> Option<&HashMap<String, String>> {
    match e {
        Event::TagMsg { tags, .. } if tags.contains_key("+freeq.at/av-error") => Some(tags),
        _ => None,
    }
}

/// av-join for a session that doesn't exist → `av-error=join-failed` with the
/// session id, so the client can tear down its optimistic call state instead
/// of ghost-publishing (the exact production failure from Jul 21: a client
/// joined a pruned session, got only a NOTICE, and sat in a dead call).
#[tokio::test]
async fn rejected_join_emits_machine_readable_av_error() {
    let (addr, _server) = start_test_server().await;
    let (handle, mut events) = connect_guest(addr, "ghost").await;

    handle.join("#av-err").await.unwrap();
    expect_event(
        &mut events,
        3000,
        |e| matches!(e, Event::Joined { channel, .. } if channel == "#av-err"),
        "joined #av-err",
    )
    .await;

    handle
        .raw("@+freeq.at/av-join;+freeq.at/av-id=01DEADSESSIONID;+freeq.at/av-instance=abc12345 TAGMSG #av-err")
        .await
        .unwrap();

    let err = expect_event(
        &mut events,
        3000,
        |e| av_error_tags(e).is_some(),
        "+freeq.at/av-error TAGMSG",
    )
    .await;
    let tags = av_error_tags(&err).unwrap();
    assert_eq!(
        tags.get("+freeq.at/av-error").map(String::as_str),
        Some("join-failed"),
        "code must be machine-readable join-failed"
    );
    assert_eq!(
        tags.get("+freeq.at/av-id").map(String::as_str),
        Some("01DEADSESSIONID"),
        "av-id must name the failed session so clients match it to their call"
    );
    assert!(
        tags.get("+freeq.at/av-reason").is_some(),
        "human-readable reason present"
    );
}

/// Concurrent av-start: the loser gets `av-error=start-collision` whose av-id
/// names the WINNING session, so it can converge immediately instead of
/// sitting wedged in a dead solo call (audit F3/F4).
#[tokio::test]
async fn start_collision_names_the_winning_session() {
    let (addr, _server) = start_test_server().await;
    let (alice, mut alice_events) = connect_guest(addr, "alice").await;
    let (bob, mut bob_events) = connect_guest(addr, "bob").await;

    alice.join("#race").await.unwrap();
    bob.join("#race").await.unwrap();
    expect_event(
        &mut bob_events,
        3000,
        |e| matches!(e, Event::Joined { channel, .. } if channel == "#race"),
        "bob joined #race",
    )
    .await;

    // Alice starts first and wins.
    alice
        .raw("@+freeq.at/av-start;+freeq.at/av-instance=aaaa1111 TAGMSG #race")
        .await
        .unwrap();
    // Wait until the session exists (alice sees the started broadcast).
    let started = expect_event(
        &mut alice_events,
        3000,
        |e| matches!(e, Event::TagMsg { tags, .. } if tags.get("+freeq.at/av-state").map(String::as_str) == Some("started")),
        "av-state=started",
    )
    .await;
    let winner_id = match &started {
        Event::TagMsg { tags, .. } => tags.get("+freeq.at/av-id").cloned().unwrap(),
        _ => unreachable!(),
    };

    // Bob's start loses the race.
    bob.raw("@+freeq.at/av-start;+freeq.at/av-instance=bbbb2222 TAGMSG #race")
        .await
        .unwrap();

    let err = expect_event(
        &mut bob_events,
        3000,
        |e| av_error_tags(e).is_some(),
        "+freeq.at/av-error TAGMSG for bob",
    )
    .await;
    let tags = av_error_tags(&err).unwrap();
    assert_eq!(
        tags.get("+freeq.at/av-error").map(String::as_str),
        Some("start-collision")
    );
    assert_eq!(
        tags.get("+freeq.at/av-id").cloned(),
        Some(winner_id),
        "av-id must name the WINNING session so the loser can join it"
    );
}
