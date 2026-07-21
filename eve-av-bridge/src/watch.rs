//! stream.place / HLS watch → freeq MoQ (audio + real video).
//!
//! Separate from [`crate::radio`]: no ICY, no spectrum viz, no radio/play API.
//! Controllers use `/v1/watch/play` and `/v1/watch/stop`.

use std::process::Stdio;
use std::sync::Arc;
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};
use bytes::Bytes;
use freeq_av::{SPEAK_RATE, Speaker};
use iroh_live::media::format::{PixelFormat, VideoFormat, VideoFrame};
use iroh_live::media::traits::VideoSource;
use tokio::io::AsyncReadExt;
use tokio::process::Command;
use tokio::sync::watch;
use tracing::{info, warn};

/// Tile size for freeq MoQ H.264 path (matches radio viz for encoder stability).
pub const WATCH_W: u32 = 640;
pub const WATCH_H: u32 = 360;

const CHUNK_SAMPLES: usize = SPEAK_RATE as usize / 10;
const CHUNK_BYTES: usize = CHUNK_SAMPLES * 4;
const MAX_QUEUE_SECS: f32 = 2.5;

/// Latest decoded frame for the MoQ encoder.
#[derive(Clone)]
pub struct WatchTile {
    inner: Arc<WatchInner>,
}

struct WatchInner {
    latest: Mutex<Option<VideoFrame>>,
    t0: Instant,
    running: AtomicBool,
}

impl WatchTile {
    pub fn new() -> Self {
        Self {
            inner: Arc::new(WatchInner {
                latest: Mutex::new(None),
                t0: Instant::now(),
                running: AtomicBool::new(true),
            }),
        }
    }

    pub fn video_source(&self) -> WatchVideoSource {
        WatchVideoSource {
            tile: self.clone(),
        }
    }

    pub fn push_rgba(&self, rgba: Vec<u8>) {
        if rgba.len() != (WATCH_W as usize) * (WATCH_H as usize) * 4 {
            return;
        }
        let frame = VideoFrame::new_rgba(
            Bytes::from(rgba),
            WATCH_W,
            WATCH_H,
            self.inner.t0.elapsed(),
        );
        *self.inner.latest.lock().expect("latest") = Some(frame);
    }

    pub fn stop(&self) {
        self.inner.running.store(false, Ordering::Relaxed);
    }
}

pub struct WatchVideoSource {
    tile: WatchTile,
}

impl VideoSource for WatchVideoSource {
    fn name(&self) -> &str {
        "eve-stream-watch"
    }
    fn format(&self) -> VideoFormat {
        VideoFormat {
            pixel_format: PixelFormat::Rgba,
            dimensions: [WATCH_W, WATCH_H],
        }
    }
    fn pop_frame(&mut self) -> Result<Option<VideoFrame>> {
        Ok(self.tile.inner.latest.lock().expect("latest").take())
    }
    fn start(&mut self) -> Result<()> {
        Ok(())
    }
    fn stop(&mut self) -> Result<()> {
        Ok(())
    }
}

pub struct WatchHandle {
    stop: Arc<AtomicBool>,
    _audio: tokio::task::JoinHandle<()>,
    _video: tokio::task::JoinHandle<()>,
}

impl WatchHandle {
    pub fn stop(&self) {
        self.stop.store(true, Ordering::Relaxed);
    }
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

/// Decode HLS/HTTP live URL → Speaker PCM + WatchTile RGBA.
pub fn start_watch(
    url: String,
    speaker: Speaker,
    mut session_alive: watch::Receiver<bool>,
    tile: WatchTile,
) -> Result<WatchHandle> {
    if url.trim().is_empty() {
        bail!("empty watch url");
    }
    let lower = url.to_ascii_lowercase();
    if !(lower.starts_with("http://") || lower.starts_with("https://")) {
        bail!("watch url must be http(s)");
    }
    let ffmpeg = which_ffmpeg()?;
    let stop = Arc::new(AtomicBool::new(false));

    let stop_a = stop.clone();
    let stop_v = stop.clone();
    let ffmpeg_a = ffmpeg.clone();
    let ffmpeg_v = ffmpeg;
    let url_a = url.clone();
    let url_v = url;
    let mut alive_a = session_alive.clone();
    let mut alive_v = session_alive;
    let tile_v = tile;

    let audio = tokio::spawn(async move {
        info!(%url_a, "watch audio decode");
        if let Err(e) = run_audio(&ffmpeg_a, &url_a, speaker, stop_a, &mut alive_a).await {
            warn!(error = %e, "watch audio ended");
        }
    });
    let video = tokio::spawn(async move {
        info!(%url_v, "watch video decode");
        if let Err(e) = run_video(&ffmpeg_v, &url_v, tile_v, stop_v, &mut alive_v).await {
            warn!(error = %e, "watch video ended");
        }
    });

    Ok(WatchHandle {
        stop,
        _audio: audio,
        _video: video,
    })
}

async fn run_audio(
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
        .with_context(|| format!("spawn {ffmpeg} watch audio"))?;

    let mut stdout = child.stdout.take().context("stdout")?;
    let mut buf = vec![0u8; CHUNK_BYTES];
    let mut carry = Vec::new();

    loop {
        if stop.load(Ordering::Relaxed) || !*session_alive.borrow() {
            break;
        }
        while speaker.queued_secs() > MAX_QUEUE_SECS {
            if stop.load(Ordering::Relaxed) || !*session_alive.borrow() {
                break;
            }
            tokio::time::sleep(Duration::from_millis(40)).await;
        }
        let n = match stdout.read(&mut buf).await {
            Ok(0) => break,
            Ok(n) => n,
            Err(e) => {
                warn!(error = %e, "watch audio read");
                break;
            }
        };
        carry.extend_from_slice(&buf[..n]);
        while carry.len() >= 4 {
            let take = (carry.len() - (carry.len() % 4)).min(CHUNK_BYTES);
            if take < 4 {
                break;
            }
            let mut pcm = Vec::with_capacity(take / 4);
            for w in carry[..take].chunks_exact(4) {
                pcm.push(f32::from_le_bytes([w[0], w[1], w[2], w[3]]));
            }
            speaker.enqueue(&pcm, SPEAK_RATE);
            carry.drain(..take);
            if carry.len() < CHUNK_BYTES {
                break;
            }
        }
    }
    let _ = child.kill().await;
    Ok(())
}

async fn run_video(
    ffmpeg: &str,
    url: &str,
    tile: WatchTile,
    stop: Arc<AtomicBool>,
    session_alive: &mut watch::Receiver<bool>,
) -> Result<()> {
    let frame_bytes = (WATCH_W as usize) * (WATCH_H as usize) * 4;
    let vf = format!(
        "scale={WATCH_W}:{WATCH_H}:force_original_aspect_ratio=decrease,\
pad={WATCH_W}:{WATCH_H}:(ow-iw)/2:(oh-ih)/2:black,fps=15,format=rgba"
    );
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
            "-an",
            "-vf",
            &vf,
            "-pix_fmt",
            "rgba",
            "-f",
            "rawvideo",
            "pipe:1",
        ])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .with_context(|| format!("spawn {ffmpeg} watch video"))?;

    let mut stdout = child.stdout.take().context("stdout")?;
    let mut buf = vec![0u8; frame_bytes];
    let mut frames = 0u64;
    let mut last_log = Instant::now();

    loop {
        if stop.load(Ordering::Relaxed) || !*session_alive.borrow() {
            break;
        }
        let mut filled = 0usize;
        while filled < frame_bytes {
            if stop.load(Ordering::Relaxed) || !*session_alive.borrow() {
                let _ = child.kill().await;
                return Ok(());
            }
            match stdout.read(&mut buf[filled..]).await {
                Ok(0) => {
                    let _ = child.kill().await;
                    return Ok(());
                }
                Ok(n) => filled += n,
                Err(e) => {
                    warn!(error = %e, "watch video read");
                    let _ = child.kill().await;
                    return Ok(());
                }
            }
        }
        tile.push_rgba(buf.clone());
        frames += 1;
        if last_log.elapsed().as_secs() >= 10 {
            info!(frames, "watch video feed");
            last_log = Instant::now();
        }
    }
    let _ = child.kill().await;
    Ok(())
}
