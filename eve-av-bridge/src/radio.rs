//! Internet radio → continuous PCM → freeq-av Speaker.
//!
//! Prefer `ffmpeg` (handles icy/shoutcast, mp3, aac). Falls back to a clear
//! error if ffmpeg is missing.

use std::process::Stdio;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use anyhow::{Context, Result, bail};
use freeq_av::{SPEAK_RATE, Speaker};
use tokio::io::AsyncReadExt;
use tokio::process::Command;
use tokio::sync::watch;
use tracing::{info, warn};

/// Max seconds of audio allowed in the MoQ speak queue while radio plays.
/// Above this we pause reading so we don't lag infinitely if the SFU stalls.
const MAX_QUEUE_SECS: f32 = 2.5;

/// Samples per feed chunk (~100 ms @ 48 kHz mono f32).
const CHUNK_SAMPLES: usize = SPEAK_RATE as usize / 10;
const CHUNK_BYTES: usize = CHUNK_SAMPLES * 4;

pub struct RadioHandle {
    stop: Arc<AtomicBool>,
    _task: tokio::task::JoinHandle<()>,
}

impl RadioHandle {
    pub fn stop(&self) {
        self.stop.store(true, Ordering::Relaxed);
    }
}

/// Spawn a background task that pulls `url` through ffmpeg and enqueues PCM.
pub fn start_radio(
    url: String,
    speaker: Speaker,
    mut session_alive: watch::Receiver<bool>,
) -> Result<RadioHandle> {
    if url.trim().is_empty() {
        bail!("empty radio url");
    }
    // Basic SSRF guard: only http(s).
    let lower = url.to_ascii_lowercase();
    if !(lower.starts_with("http://") || lower.starts_with("https://")) {
        bail!("radio url must be http(s)");
    }

    let ffmpeg = which_ffmpeg().context(
        "ffmpeg not found — install ffmpeg (e.g. nix-shell -p ffmpeg) to stream internet radio",
    )?;

    let stop = Arc::new(AtomicBool::new(false));
    let stop_task = stop.clone();

    let task = tokio::spawn(async move {
        info!(%url, ?ffmpeg, "starting radio decode");
        if let Err(e) = run_ffmpeg_pipe(&ffmpeg, &url, speaker, stop_task, &mut session_alive).await
        {
            warn!(error = %e, "radio stream ended with error");
        } else {
            info!("radio stream ended");
        }
    });

    Ok(RadioHandle { stop, _task: task })
}

fn which_ffmpeg() -> Result<String> {
    if let Ok(p) = std::env::var("FFMPEG_PATH") {
        if !p.is_empty() && std::path::Path::new(&p).exists() {
            return Ok(p);
        }
    }
    for candidate in ["ffmpeg", "/usr/bin/ffmpeg", "/run/current-system/sw/bin/ffmpeg"] {
        if which_ok(candidate) {
            return Ok(candidate.to_string());
        }
    }
    // `command -v` style via `which` crate not available — try `std::process`
    let out = std::process::Command::new("sh")
        .arg("-c")
        .arg("command -v ffmpeg")
        .output();
    if let Ok(o) = out {
        if o.status.success() {
            let s = String::from_utf8_lossy(&o.stdout).trim().to_string();
            if !s.is_empty() {
                return Ok(s);
            }
        }
    }
    bail!("ffmpeg binary not found in PATH")
}

fn which_ok(path: &str) -> bool {
    std::path::Path::new(path).is_file()
        || std::process::Command::new(path)
            .arg("-version")
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .map(|s| s.success())
            .unwrap_or(false)
}

async fn run_ffmpeg_pipe(
    ffmpeg: &str,
    url: &str,
    speaker: Speaker,
    stop: Arc<AtomicBool>,
    session_alive: &mut watch::Receiver<bool>,
) -> Result<()> {
    let mut child = Command::new(ffmpeg)
        .args([
            "-hide_banner",
            "-loglevel",
            "error",
            "-reconnect",
            "1",
            "-reconnect_streamed",
            "1",
            "-reconnect_delay_max",
            "5",
            "-i",
            url,
            "-vn",
            "-ac",
            "1",
            "-ar",
            &SPEAK_RATE.to_string(),
            "-f",
            "f32le",
            "pipe:1",
        ])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .with_context(|| format!("spawn {ffmpeg}"))?;

    let mut stdout = child.stdout.take().context("ffmpeg stdout")?;
    let mut buf = vec![0u8; CHUNK_BYTES];
    let mut carry = Vec::new();
    let mut bytes_in: u64 = 0;
    let mut samples_out: u64 = 0;
    let mut last_log = std::time::Instant::now();
    let mut peak: f32 = 0.0;

    loop {
        if stop.load(Ordering::Relaxed) {
            break;
        }
        if !*session_alive.borrow() {
            info!("session ended — stopping radio");
            break;
        }

        // Backpressure: don't enqueue if the MoQ queue is already full.
        while speaker.queued_secs() > MAX_QUEUE_SECS {
            if stop.load(Ordering::Relaxed) || !*session_alive.borrow() {
                break;
            }
            if last_log.elapsed().as_secs() >= 5 {
                info!(
                    bytes_in,
                    samples_out,
                    peak,
                    queue_secs = speaker.queued_secs(),
                    "radio feed (backpressured — encoder draining)"
                );
                peak = 0.0;
                last_log = std::time::Instant::now();
            }
            tokio::time::sleep(std::time::Duration::from_millis(40)).await;
        }

        let n = match stdout.read(&mut buf).await {
            Ok(0) => break,
            Ok(n) => n,
            Err(e) => {
                warn!(error = %e, "ffmpeg stdout read");
                break;
            }
        };
        bytes_in += n as u64;
        carry.extend_from_slice(&buf[..n]);

        while carry.len() >= 4 {
            // Align to f32
            let usable = carry.len() - (carry.len() % 4);
            if usable == 0 {
                break;
            }
            // Feed in CHUNK_BYTES-sized slices when possible
            let take = usable.min(CHUNK_BYTES).max(4);
            let take = take - (take % 4);
            if take < 4 {
                break;
            }
            let chunk = &carry[..take];
            let mut pcm = Vec::with_capacity(take / 4);
            for w in chunk.chunks_exact(4) {
                let s = f32::from_le_bytes([w[0], w[1], w[2], w[3]]);
                peak = peak.max(s.abs());
                pcm.push(s);
            }
            samples_out += pcm.len() as u64;
            speaker.enqueue(&pcm, SPEAK_RATE);
            carry.drain(..take);
            if carry.len() < CHUNK_BYTES {
                break;
            }
        }

        if last_log.elapsed().as_secs() >= 5 {
            info!(
                bytes_in,
                samples_out,
                peak,
                queue_secs = speaker.queued_secs(),
                "radio feed"
            );
            peak = 0.0;
            last_log = std::time::Instant::now();
        }
    }

    stop.store(true, Ordering::Relaxed);
    let _ = child.kill().await;
    let _ = child.wait().await;
    Ok(())
}
