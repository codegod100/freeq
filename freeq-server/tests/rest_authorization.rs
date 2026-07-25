//! REST authorization: private-channel data must not be readable by anonymous
//! HTTP callers.
//!
//! `/history`, `/export`, `/evidence` and `/messages/{msgid}` all funnel through
//! `authorize_channel_read`, which fails closed for a mode-restricted channel
//! (`+i`, `+k`, or encrypted-only) unless the bearer resolves to a member, op or
//! founder. Several sibling endpoints were added later and never wired to it —
//! some don't even accept `headers`, so they *cannot* authorize.
//!
//! These tests pin the rule for every channel-scoped read endpoint, and include
//! public-channel controls so a fix can't simply lock everything down.

use std::collections::HashMap;
use std::time::Duration;

use freeq_sdk::client::{self, ConnectConfig};
use freeq_sdk::event::Event;
use freeq_sdk::did::DidResolver;
use tokio::sync::mpsc;
use tokio::time::timeout;

async fn start_test_server_with_web(
    resolver: DidResolver,
) -> (
    std::net::SocketAddr,
    std::net::SocketAddr,
    tokio::task::JoinHandle<anyhow::Result<()>>,
) {
    let config = freeq_server::config::ServerConfig {
        listen_addr: "127.0.0.1:0".to_string(),
        web_addr: Some("127.0.0.1:0".to_string()),
        server_name: "test-rest-authz".to_string(),
        challenge_timeout_secs: 60,
        db_path: Some(":memory:".to_string()),
        ..Default::default()
    };
    freeq_server::server::Server::with_resolver(config, resolver)
        .start_with_web()
        .await
        .unwrap()
}

fn empty_resolver() -> DidResolver {
    DidResolver::static_map(HashMap::new())
}

async fn expect_event(
    events: &mut mpsc::Receiver<Event>,
    ms: u64,
    predicate: impl Fn(&Event) -> bool,
    what: &str,
) {
    let deadline = Duration::from_millis(ms);
    let start = tokio::time::Instant::now();
    loop {
        let left = deadline.saturating_sub(start.elapsed());
        assert!(!left.is_zero(), "timeout waiting for {what}");
        match timeout(left, events.recv()).await {
            Ok(Some(e)) if predicate(&e) => return,
            Ok(Some(_)) => continue,
            _ => panic!("stream ended waiting for {what}"),
        }
    }
}

/// Bring up a server + a `+k`-locked channel with a topic, and a public control
/// channel. Returns the web address.
async fn fixture() -> (
    std::net::SocketAddr,
    tokio::task::JoinHandle<anyhow::Result<()>>,
) {
    let (addr, web_addr, handle) = start_test_server_with_web(empty_resolver()).await;

    let config = ConnectConfig {
        server_addr: addr.to_string(),
        nick: "alice".to_string(),
        user: "alice".to_string(),
        realname: "Alice".to_string(),
        ..Default::default()
    };
    let (h, mut events) = client::connect(config, None);
    expect_event(
        &mut events,
        3000,
        |e| matches!(e, Event::Registered { .. }),
        "registered",
    )
    .await;

    // Private: mode-restricted via a channel key. The creator holds ops.
    h.join("#secretplan").await.unwrap();
    expect_event(
        &mut events,
        3000,
        |e| matches!(e, Event::Joined { .. }),
        "joined #secretplan",
    )
    .await;
    h.topic("#secretplan", "acquisition of Initech — do not leak")
        .await
        .unwrap();
    h.mode("#secretplan", "+k", Some("hunter2")).await.unwrap();

    // Public control channel.
    h.join("#townsquare").await.unwrap();
    h.topic("#townsquare", "welcome all").await.unwrap();

    // Let the mode/topic settle before anyone reads over HTTP.
    tokio::time::sleep(Duration::from_millis(300)).await;
    h.quit(None).await.ok();
    (web_addr, handle)
}

async fn get(web: std::net::SocketAddr, path: &str) -> (u16, String) {
    let r = reqwest::Client::new()
        .get(format!("http://{web}{path}"))
        .timeout(Duration::from_secs(5))
        .send()
        .await
        .unwrap();
    let status = r.status().as_u16();
    (status, r.text().await.unwrap_or_default())
}

#[tokio::test]
async fn private_channel_topic_is_not_public() {
    let (web, server) = fixture().await;
    let (status, body) = get(web, "/api/v1/channels/secretplan/topic").await;
    assert!(
        status == 403 || status == 404,
        "anonymous GET of a +k channel's topic returned {status}: {body}\n\
         api_channel_topic takes no headers, so it cannot authorize — it hands \
         out the topic of any channel, including mode-restricted ones."
    );
    assert!(
        !body.contains("Initech"),
        "private topic text leaked to an anonymous caller: {body}"
    );
    server.abort();
}

#[tokio::test]
async fn private_channel_audit_log_is_not_public() {
    let (web, server) = fixture().await;
    let (status, body) = get(web, "/api/v1/channels/secretplan/audit").await;
    assert!(
        status == 403 || status == 404,
        "anonymous GET of a +k channel's AUDIT timeline returned {status}: {body}\n\
         api_channel_audit takes no headers. The audit timeline carries \
         coordination events, actor DIDs, signatures and payloads — the \
         governance history of a private room."
    );
    server.abort();
}

#[tokio::test]
async fn private_channel_coordination_events_are_not_public() {
    let (web, server) = fixture().await;
    let (status, body) = get(web, "/api/v1/channels/secretplan/events").await;
    assert!(
        status == 403 || status == 404,
        "anonymous GET of a +k channel's coordination events returned {status}: {body}\n\
         api_channel_events takes no headers — signed task cards and agent \
         activity for a private channel are world-readable."
    );
    server.abort();
}

#[tokio::test]
async fn private_channel_pins_are_not_public() {
    let (web, server) = fixture().await;
    let (status, body) = get(web, "/api/v1/channels/secretplan/pins").await;
    assert!(
        status == 403 || status == 404,
        "anonymous GET of a +k channel's pins returned {status}: {body}"
    );
    server.abort();
}

#[tokio::test]
async fn private_channel_sessions_are_not_public() {
    let (web, server) = fixture().await;
    let (status, body) = get(web, "/api/v1/channels/secretplan/sessions").await;
    assert!(
        status == 403 || status == 404,
        "anonymous GET of a +k channel's session/member list returned {status}: {body}\n\
         membership of a private channel is itself sensitive."
    );
    server.abort();
}

/// Control: the endpoints that were already wired to `authorize_channel_read`
/// must keep refusing. If this ever fails, the shared guard regressed.
#[tokio::test]
async fn private_channel_history_and_export_stay_locked() {
    let (web, server) = fixture().await;
    for path in [
        "/api/v1/channels/secretplan/history",
        "/api/v1/channels/secretplan/export",
    ] {
        let (status, body) = get(web, path).await;
        assert!(
            status == 403 || status == 404,
            "{path} should be locked for anonymous callers, got {status}: {body}"
        );
    }
    server.abort();
}

/// Control: locking the private endpoints must not break public channels.
#[tokio::test]
async fn public_channel_reads_still_work() {
    let (web, server) = fixture().await;
    let (status, body) = get(web, "/api/v1/channels/townsquare/topic").await;
    assert_eq!(
        status, 200,
        "public channel topic must stay readable, got {status}: {body}"
    );
    assert!(
        body.contains("welcome all"),
        "public topic missing from response: {body}"
    );
    for path in [
        "/api/v1/channels/townsquare/events",
        "/api/v1/channels/townsquare/audit",
        "/api/v1/channels/townsquare/pins",
    ] {
        let (status, body) = get(web, path).await;
        assert_eq!(
            status, 200,
            "public channel {path} must stay readable, got {status}: {body}"
        );
    }
    server.abort();
}

/// The governance family: approvals, budget, spend and agent capabilities.
/// None of these accepted a `HeaderMap` either, so a private channel's
/// operational state — what its agents may do, what it has spent, what is
/// awaiting a human decision — was readable by anyone.
#[tokio::test]
async fn private_channel_governance_endpoints_are_not_public() {
    let (web, server) = fixture().await;
    for path in [
        "/api/v1/channels/secretplan/approvals",
        "/api/v1/channels/secretplan/budget",
        "/api/v1/channels/secretplan/spend",
        "/api/v1/channels/secretplan/agent-capabilities",
    ] {
        let (status, body) = get(web, path).await;
        assert!(
            status == 403 || status == 404,
            "anonymous GET {path} returned {status}: {body}"
        );
    }
    server.abort();
}

/// Control: the same governance endpoints must keep working for a public
/// channel, so the fix doesn't blind legitimate dashboards.
#[tokio::test]
async fn public_channel_governance_endpoints_still_work() {
    let (web, server) = fixture().await;
    for path in [
        "/api/v1/channels/townsquare/approvals",
        "/api/v1/channels/townsquare/budget",
        "/api/v1/channels/townsquare/spend",
        "/api/v1/channels/townsquare/agent-capabilities",
    ] {
        let (status, body) = get(web, path).await;
        assert_eq!(status, 200, "public {path} returned {status}: {body}");
    }
    server.abort();
}

/// The unauthenticated channel *list* must not name a private channel.
/// (`api_channels` already filters on `channel_is_discoverable`; this pins it,
/// because it's the one place a private channel's existence would leak wholesale.)
#[tokio::test]
async fn channel_list_hides_private_channels() {
    let (web, server) = fixture().await;
    let (status, body) = get(web, "/api/v1/channels").await;
    assert_eq!(status, 200, "channel list should be public: {body}");
    assert!(
        !body.contains("secretplan"),
        "private channel leaked into the public channel list: {body}"
    );
    assert!(
        body.contains("townsquare"),
        "public channel missing from the list: {body}"
    );
    server.abort();
}
