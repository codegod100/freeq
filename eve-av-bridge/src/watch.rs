//! stream.place / HLS watch → freeq MoQ (audio + real video).
//!
//! Controllers use `/v1/watch/play` and `/v1/watch/stop`.
//!
//! Continuity design (top priority):
//! - **Separate ffmpeg processes** for audio and video so the video path can
//!   never block/stall the audio path (dual-output single-process was bursty
//!   and cut out every few seconds on 1s HLS).
//! - **Audio** uses a single-output pipe (same shape as radio) with a playout
//!   buffer (min fill, max cap) so MoQ never underruns into silence.
//! - **Video** is best-effort: hold-last-frame at a low encode cadence.

use std::fs;
use std::path::{Path, PathBuf};
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

/// Tile size for freeq MoQ H.264 path (matches `VideoPreset::P180`).
pub const WATCH_W: u32 = 320;
pub const WATCH_H: u32 = 180;

/// Encoder pop cadence (hold-last-frame). Independent of demux frame rate.
const FPS: u32 = 15;

const CHUNK_SAMPLES: usize = SPEAK_RATE as usize / 10; // 100ms
const CHUNK_BYTES: usize = CHUNK_SAMPLES * 4;

/// Keep this much audio queued so HLS segment jitter never underruns MoQ.
const MIN_QUEUE_SECS: f32 = 1.25;
/// Cap so reconnect/catch-up doesn't grow unbounded latency.
const MAX_QUEUE_SECS: f32 = 4.0;

const FRAME_BYTES: usize = (WATCH_W as usize) * (WATCH_H as usize) * 4;

/// Latest decoded pixels for the MoQ encoder (RGBA, held across stalls).
#[derive(Clone)]
pub struct WatchTile {
    inner: Arc<WatchInner>,
}

struct WatchInner {
    latest: Mutex<Option<Bytes>>,
    t0: Instant,
}

impl WatchTile {
    pub fn new() -> Self {
        Self {
            inner: Arc::new(WatchInner {
                latest: Mutex::new(None),
                t0: Instant::now(),
            }),
        }
    }

    pub fn video_source(&self) -> WatchVideoSource {
        WatchVideoSource {
            tile: self.clone(),
            frame_index: 0,
        }
    }

    pub fn push_rgba_bytes(&self, bytes: Bytes) {
        if bytes.len() != FRAME_BYTES {
            return;
        }
        *self.inner.latest.lock().expect("latest") = Some(bytes);
    }
}

pub struct WatchVideoSource {
    tile: WatchTile,
    frame_index: u64,
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
        // Pace at FPS; re-emit last pixels so MoQ video never gaps.
        let elapsed = self.tile.inner.t0.elapsed();
        let due = Duration::from_millis(self.frame_index.saturating_mul(1000 / u64::from(FPS)));
        if elapsed + Duration::from_millis(1) < due {
            return Ok(None);
        }

        let pixels = self.tile.inner.latest.lock().expect("latest").clone();
        let Some(pixels) = pixels else {
            return Ok(None);
        };

        self.frame_index = self.frame_index.saturating_add(1);
        Ok(Some(VideoFrame::new_rgba(pixels, WATCH_W, WATCH_H, due)))
    }
    fn start(&mut self) -> Result<()> {
        self.frame_index = 0;
        Ok(())
    }
    fn stop(&mut self) -> Result<()> {
        Ok(())
    }
}

pub struct WatchHandle {
    stop: Arc<AtomicBool>,
    _task: tokio::task::JoinHandle<()>,
    run_dir: PathBuf,
}

impl WatchHandle {
    pub fn stop(&self) {
        self.stop.store(true, Ordering::Relaxed);
    }
}

impl Drop for WatchHandle {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        let _ = fs::remove_dir_all(&self.run_dir);
    }
}

fn which_ffmpeg() -> Result<String> {
    if let Ok(p) = std::env::var("FFMPEG_PATH") {
        if !p.is_empty() && Path::new(&p).exists() {
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
    Path::new(path).is_file()
        || std::process::Command::new(path)
            .arg("-version")
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .map(|s| s.success())
            .unwrap_or(false)
}

fn mkfifo(path: &Path) -> Result<()> {
    use std::ffi::CString;
    use std::os::unix::ffi::OsStrExt;
    let c = CString::new(path.as_os_str().as_bytes())
        .with_context(|| format!("mkfifo path {}", path.display()))?;
    let rc = unsafe { libc::mkfifo(c.as_ptr(), 0o600) };
    if rc != 0 {
        bail!(
            "mkfifo {}: {}",
            path.display(),
            std::io::Error::last_os_error()
        );
    }
    Ok(())
}

/// HLS input flags tuned for continuous playout (not ultra-low-latency edge).
fn hls_input_args(url: &str) -> Vec<String> {
    [
        "-hide_banner",
        "-loglevel",
        "error",
        // Prefer recovery over cutting the live edge.
        "-fflags",
        "+genpts+discardcorrupt+igndts",
        "-probesize",
        "5000000",
        "-analyzeduration",
        "3000000",
        "-reconnect",
        "1",
        "-reconnect_streamed",
        "1",
        "-reconnect_on_network_error",
        "1",
        "-reconnect_delay_max",
        "5",
        // Several 1s segments behind → absorb network/decode jitter.
        "-live_start_index",
        "-6",
        "-i",
        url,
    ]
    .into_iter()
    .map(str::to_string)
    .collect()
}

/// Decode HLS → Speaker PCM + WatchTile RGBA (two independent ffmpeg procs).
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

    let run_dir = std::env::temp_dir().join(format!("eve-watch-{}", uuid::Uuid::new_v4()));
    fs::create_dir_all(&run_dir).with_context(|| format!("create {}", run_dir.display()))?;

    let stop_task = stop.clone();
    let run_dir_task = run_dir.clone();

    let task = tokio::spawn(async move {
        info!(%url, "watch demux (split audio + video ffmpeg)");

        let mut alive_a = session_alive.clone();
        let mut alive_v = session_alive.clone();
        let stop_a = stop_task.clone();
        let stop_v = stop_task.clone();
        let speaker_a = speaker.clone();
        let tile_v = tile.clone();
        let ffmpeg_a = ffmpeg.clone();
        let ffmpeg_v = ffmpeg.clone();
        let url_a = url.clone();
        let url_v = url.clone();
        let run_dir_v = run_dir_task.clone();

        let audio = tokio::spawn(async move {
            audio_loop(ffmpeg_a, url_a, speaker_a, stop_a, &mut alive_a).await;
        });
        let video = tokio::spawn(async move {
            video_loop(ffmpeg_v, url_v, tile_v, stop_v, &mut alive_v, run_dir_v).await;
        });

        // End when session dies or stop — both loops exit on the same flags.
        loop {
            if stop_task.load(Ordering::Relaxed) || !*session_alive.borrow() {
                break;
            }
            tokio::select! {
                _ = tokio::time::sleep(Duration::from_millis(200)) => {}
                _ = session_alive.changed() => {
                    if !*session_alive.borrow() {
                        break;
                    }
                }
            }
        }
        stop_task.store(true, Ordering::Relaxed);
        let _ = audio.await;
        let _ = video.await;
        let _ = fs::remove_dir_all(&run_dir_task);
    });

    Ok(WatchHandle {
        stop,
        _task: task,
        run_dir,
    })
}

/// Continuous audio: restart forever until stop/session end.
async fn audio_loop(
    ffmpeg: String,
    url: String,
    speaker: Speaker,
    stop: Arc<AtomicBool>,
    session_alive: &mut watch::Receiver<bool>,
) {
    while !stop.load(Ordering::Relaxed) && *session_alive.borrow() {
        match run_audio_demux(&ffmpeg, &url, speaker.clone(), stop.clone(), session_alive).await {
            Ok(()) => {}
            Err(e) => warn!(error = %e, "watch audio demux ended"),
        }
        if stop.load(Ordering::Relaxed) || !*session_alive.borrow() {
            break;
        }
        // Short gap only — keep restarts snappy for continuity.
        warn!("watch audio demux restart in 250ms");
        tokio::time::sleep(Duration::from_millis(250)).await;
    }
}

/// Best-effort video: restart forever; hold-last-frame covers gaps.
async fn video_loop(
    ffmpeg: String,
    url: String,
    tile: WatchTile,
    stop: Arc<AtomicBool>,
    session_alive: &mut watch::Receiver<bool>,
    run_dir: PathBuf,
) {
    while !stop.load(Ordering::Relaxed) && *session_alive.borrow() {
        match run_video_demux(
            &ffmpeg,
            &url,
            tile.clone(),
            stop.clone(),
            session_alive,
            &run_dir,
        )
        .await
        {
            Ok(()) => {}
            Err(e) => warn!(error = %e, "watch video demux ended"),
        }
        if stop.load(Ordering::Relaxed) || !*session_alive.borrow() {
            break;
        }
        info!("watch video demux restart in 500ms");
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
}

async fn run_audio_demux(
    ffmpeg: &str,
    url: &str,
    speaker: Speaker,
    stop: Arc<AtomicBool>,
    session_alive: &mut watch::Receiver<bool>,
) -> Result<()> {
    let ar = SPEAK_RATE.to_string();
    let mut args = hls_input_args(url);
    // Prefer AAC (default) audio rendition when master playlist has multiple.
    args.extend(
        [
            "-map",
            "0:a:0?",
            "-vn",
            "-ac",
            "1",
            "-ar",
            &ar,
            // Continuous PCM; no video graph to stall us.
            "-f",
            "f32le",
            "pipe:1",
        ]
        .into_iter()
        .map(str::to_string),
    );

    let mut child = Command::new(ffmpeg)
        .args(&args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .with_context(|| format!("spawn {ffmpeg} watch audio"))?;

    let mut stdout = child.stdout.take().context("ffmpeg stdout")?;
    let mut buf = vec![0u8; CHUNK_BYTES];
    let mut carry = Vec::new();
    let mut primed = false;
    let mut bytes_in: u64 = 0;
    let mut enqueued_samples: u64 = 0;
    let mut dropped_chunks: u64 = 0;
    let mut last_log = Instant::now();

    // Stage samples until MIN_QUEUE_SECS so MoQ never starts on an empty queue.
    let mut stage: Vec<f32> = Vec::new();

    loop {
        if stop.load(Ordering::Relaxed) || !*session_alive.borrow() {
            break;
        }

        // Single-output: backpressure is safe (just slows the HTTP demux).
        // Prefer backpressure over drop once primed — drop causes audible cuts.
        while primed && speaker.queued_secs() > MAX_QUEUE_SECS {
            if stop.load(Ordering::Relaxed) || !*session_alive.borrow() {
                break;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }

        let n = match stdout.read(&mut buf).await {
            Ok(0) => break,
            Ok(n) => n,
            Err(e) => {
                warn!(error = %e, "watch audio read");
                break;
            }
        };
        bytes_in += n as u64;
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
            carry.drain(..take);

            if !primed {
                stage.extend_from_slice(&pcm);
                let staged_secs = stage.len() as f32 / SPEAK_RATE as f32;
                if staged_secs >= MIN_QUEUE_SECS {
                    speaker.enqueue(&stage, SPEAK_RATE);
                    enqueued_samples += stage.len() as u64;
                    stage.clear();
                    primed = true;
                    info!(
                        queue_secs = speaker.queued_secs(),
                        "watch audio primed — continuous playout"
                    );
                }
                continue;
            }

            // After prime: if somehow still over max after wait, drop oldest
            // path is "don't enqueue this chunk" only as last resort.
            if speaker.queued_secs() > MAX_QUEUE_SECS {
                dropped_chunks = dropped_chunks.saturating_add(1);
                continue;
            }
            speaker.enqueue(&pcm, SPEAK_RATE);
            enqueued_samples += pcm.len() as u64;
        }

        if last_log.elapsed().as_secs() >= 10 {
            info!(
                bytes_in,
                enqueued_samples,
                dropped_chunks,
                primed,
                queue_secs = speaker.queued_secs(),
                "watch audio feed"
            );
            dropped_chunks = 0;
            last_log = Instant::now();
        }
    }

    let _ = child.kill().await;
    let stderr = drain_stderr(&mut child).await;
    if !stderr.is_empty() {
        warn!(%stderr, "watch audio ffmpeg stderr");
    }
    Ok(())
}

async fn run_video_demux(
    ffmpeg: &str,
    url: &str,
    tile: WatchTile,
    stop: Arc<AtomicBool>,
    session_alive: &mut watch::Receiver<bool>,
    run_dir: &Path,
) -> Result<()> {
    let video_fifo = run_dir.join("v.rgba");
    let _ = fs::remove_file(&video_fifo);
    mkfifo(&video_fifo)?;

    // No fps filter — native timestamps; WatchVideoSource holds last frame at FPS.
    // That avoids blocking the demux graph on pacing (audio is a separate process).
    let vf = format!(
        "scale={WATCH_W}:{WATCH_H}:force_original_aspect_ratio=decrease:flags=fast_bilinear,\
pad={WATCH_W}:{WATCH_H}:(ow-iw)/2:(oh-ih)/2:black,format=rgba"
    );
    let v_out = video_fifo.to_str().context("video fifo utf8")?.to_string();

    let mut args = hls_input_args(url);
    args.insert(0, "-y".to_string()); // overwrite FIFO path bookkeeping
    args.extend(
        [
            "-map",
            "0:v:0",
            "-an",
            "-vf",
            &vf,
            "-pix_fmt",
            "rgba",
            "-f",
            "rawvideo",
            &v_out,
        ]
        .into_iter()
        .map(str::to_string),
    );

    let v_path = video_fifo.to_path_buf();
    let open_v = tokio::task::spawn_blocking(move || {
        fs::OpenOptions::new().read(true).open(v_path)
    });

    let mut child = Command::new(ffmpeg)
        .args(&args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .with_context(|| format!("spawn {ffmpeg} watch video"))?;

    let open_timeout = Duration::from_secs(20);
    let v_std = match tokio::time::timeout(open_timeout, async {
        open_v.await.context("join video fifo open")?
    })
    .await
    {
        Ok(Ok(f)) => f,
        Ok(Err(e)) => {
            let _ = child.kill().await;
            let err = drain_stderr(&mut child).await;
            bail!("open watch video fifo: {e}{err}");
        }
        Err(_) => {
            let _ = child.kill().await;
            let err = drain_stderr(&mut child).await;
            bail!("timeout opening watch video fifo{err}");
        }
    };

    let mut v_reader = tokio::fs::File::from_std(v_std);
    let mut buf = vec![0u8; FRAME_BYTES];
    let mut frames = 0u64;
    let mut last_log = Instant::now();

    loop {
        if stop.load(Ordering::Relaxed) || !*session_alive.borrow() {
            break;
        }
        let mut filled = 0usize;
        while filled < FRAME_BYTES {
            if stop.load(Ordering::Relaxed) || !*session_alive.borrow() {
                let _ = child.kill().await;
                return Ok(());
            }
            match v_reader.read(&mut buf[filled..]).await {
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
        let frame = std::mem::replace(&mut buf, vec![0u8; FRAME_BYTES]);
        tile.push_rgba_bytes(Bytes::from(frame));
        frames += 1;
        if last_log.elapsed().as_secs() >= 10 {
            info!(frames, "watch video feed");
            last_log = Instant::now();
        }
    }

    let _ = child.kill().await;
    let stderr = drain_stderr(&mut child).await;
    if !stderr.is_empty() {
        warn!(%stderr, "watch video ffmpeg stderr");
    }
    Ok(())
}

async fn drain_stderr(child: &mut tokio::process::Child) -> String {
    let Some(mut err) = child.stderr.take() else {
        return String::new();
    };
    let mut buf = Vec::new();
    let _ = tokio::io::AsyncReadExt::read_to_end(&mut err, &mut buf).await;
    let s = String::from_utf8_lossy(&buf).trim().to_string();
    if s.is_empty() {
        String::new()
    } else {
        format!("; ffmpeg: {}", s.chars().take(400).collect::<String>())
    }
}
