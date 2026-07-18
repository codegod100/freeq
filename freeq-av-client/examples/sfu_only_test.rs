//! Minimal test: two MoQ WebSocket clients through the SFU cluster.
//! Client A publishes a synthetic broadcast, Client B subscribes to it.
//! No iroh-live Room involved — tests pure MoQ cluster routing.

use std::time::Duration;
use tokio::time::timeout;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let _ = rustls::crypto::aws_lc_rs::default_provider().install_default();
    tracing_subscriber::fmt()
        .with_env_filter("info,moq=debug")
        .init();

    let web_url = std::env::args()
        .position(|a| a == "--web-url")
        .and_then(|i| std::env::args().nth(i + 1))
        .unwrap_or_else(|| "http://127.0.0.1:18080".to_string());

    let moq_url: url::Url = format!("{web_url}/av/moq").parse()?;
    let broadcast_name = "test-session/alice";

    println!("=== SFU-only Test ===");
    println!("  URL: {moq_url}");
    println!("  Broadcast: {broadcast_name}");

    // ── Client A: Publisher ───────────────────────────────────────
    println!("\n[1/3] Client A: Publishing synthetic broadcast...");

    let mut client_config = moq_native::ClientConfig::default();
    client_config.tls.disable_verify = Some(true);
    client_config.backend = Some(moq_native::QuicBackend::Noq);
    let client_a = client_config.init()?;

    let mut producer = moq_lite::Broadcast::produce();
    let catalog_track = moq_lite::Track::new("catalog.json");
    let mut cw = producer.create_track(catalog_track)?;
    let mut g = cw.create_group(moq_lite::Group { sequence: 0 })?;
    g.write_frame(moq_lite::bytes::Bytes::from_static(b"{\"test\":true}"))?;
    g.finish().ok();

    let audio_track = moq_lite::Track::new("audio");
    let mut aw = producer.create_track(audio_track)?;
    for seq in 0..5u64 {
        let mut g = aw.create_group(moq_lite::Group { sequence: seq })?;
        g.write_frame(moq_lite::bytes::Bytes::from(vec![0xFFu8; 100]))?;
        g.finish().ok();
    }

    let origin_a = moq_lite::Origin::produce();
    origin_a.publish_broadcast(broadcast_name, producer.consume());

    let sub_origin_a = moq_lite::Origin::produce();

    let session_a = client_a
        .with_publish(origin_a.consume())
        .with_consume(sub_origin_a)
        .connect(moq_url.clone())
        .await?;
    println!("  Client A connected, published: {broadcast_name}");

    // Give the announce flow time to propagate
    tokio::time::sleep(Duration::from_secs(2)).await;

    // ── Client B: Subscriber ──────────────────────────────────────
    println!("\n[2/3] Client B: Subscribing...");

    let mut client_config_b = moq_native::ClientConfig::default();
    client_config_b.tls.disable_verify = Some(true);
    client_config_b.backend = Some(moq_native::QuicBackend::Noq);
    let client_b = client_config_b.init()?;

    let pub_origin_b = moq_lite::Origin::produce();
    let sub_origin_b = moq_lite::Origin::produce();
    let mut sub_consumer_b = sub_origin_b.consume();

    let session_b = client_b
        .with_publish(pub_origin_b.consume())
        .with_consume(sub_origin_b)
        .connect(moq_url.clone())
        .await?;
    println!("  Client B connected, listening for broadcasts...");

    // ── Check if Client B sees Client A's broadcast ───────────────
    println!("\n[3/3] Waiting for broadcast...");
    let result = timeout(Duration::from_secs(10), async {
        while let Some((path, announce)) = sub_consumer_b.announced().await {
            let path_str = path.to_string();
            println!("  Announced: {path_str}");

            if path_str == broadcast_name {
                if let Some(consumer) = announce {
                    let audio_track = moq_lite::Track::new("audio");
                    let track_result: Result<moq_lite::TrackConsumer, _> =
                        consumer.subscribe_track(&audio_track);
                    match track_result {
                        Ok(mut track) => {
                            let group_result: Result<Option<moq_lite::GroupConsumer>, _> =
                                track.next_group().await;
                            if let Ok(Some(mut group)) = group_result {
                                let frame_result: Result<Option<bytes::Bytes>, _> =
                                    group.read_frame().await;
                                if let Ok(Some(frame)) = frame_result {
                                    println!(
                                        "  Got audio frame: {} bytes (0x{:02X})",
                                        frame.len(),
                                        frame[0]
                                    );
                                    return true;
                                }
                            }
                        }
                        Err(e) => println!("  subscribe failed: {e}"),
                    }
                    return true;
                }
            }
        }
        false
    })
    .await;

    match result {
        Ok(true) => println!("\n  PASS: SFU cluster routing works!"),
        Ok(false) => println!("\n  FAIL: No broadcast received"),
        Err(_) => println!("\n  FAIL: Timeout waiting for broadcast"),
    }

    drop(session_a);
    drop(session_b);
    Ok(())
}
