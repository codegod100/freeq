//! stream.place / HLS watch → freeq MoQ (audio + real video).
//!
//! Separate from [`crate::radio`]: no ICY, no spectrum viz, no radio/play API.
//! Controllers use `/v1/watch/play` and `/v1/watch/stop`.
//!
//! Performance notes (smoothness):
//! - **One ffmpeg** demuxes A+V (named-pipe outputs) so HLS isn't opened twice.
//! - **30 fps** matches `VideoPreset::P360` encoder cadence.
//! - **Hold-last-frame** with advancing PTS so encoder never starves mid-segment.
//! - Live demux flags cut default buffering stalls on HTTP(S)/HLS.

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

/// Tile size for freeq MoQ H.264 path (matches radio viz / P360).
pub const WATCH_W: u32 = 640;
pub const WATCH_H: u32 = 360;

/// Match `VideoPreset::P360` encoder framerate (iroh-live: all presets are 30).
const FPS: u32 = 30;

const CHUNK_SAMPLES: usize = SPEAK_RATE as usize / 10;
const CHUNK_BYTES: usize = CHUNK_SAMPLES * 4;
const MAX_QUEUE_SECS: f32 = 2.5;

const FRAME_BYTES: usize = (WATCH_W as usize) * (WATCH_H as usize) * 4;

/// Latest decoded pixels for the MoQ encoder (RGBA, held across stalls).
#[derive(Clone)]
pub struct WatchTile {
    inner: Arc<WatchInner>,
}

struct WatchInner {
    /// Most recent full frame; `Bytes` so clones are refcount-only.
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

    /// Store a full RGBA frame without an extra heap copy (moves `bytes`).
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
        // Pace at FPS with advancing PTS (SharedVideoSource + encoder both
        // follow timestamps). Re-emit the last pixels when decode stalls so
        // the MoQ track doesn't gap mid-HLS segment.
        let elapsed = self.tile.inner.t0.elapsed();
        let due = Duration::from_millis(self.frame_index.saturating_mul(1000 / u64::from(FPS)));
        if elapsed + Duration::from_millis(1) < due {
            return Ok(None);
        }

        let pixels = self
            .tile
            .inner
            .latest
            .lock()
            .expect("latest")
            .clone();
        let Some(pixels) = pixels else {
            return Ok(None);
        };

        self.frame_index = self.frame_index.saturating_add(1);
        Ok(Some(VideoFrame::new_rgba(
            pixels,
            WATCH_W,
            WATCH_H,
            due,
        )))
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

/// Shared live/HLS-friendly input flags (single demux).
fn live_input_args(url: &str) -> Vec<String> {
    [
        "-hide_banner",
        "-loglevel",
        "error",
        // Prefer low-latency demux over perfect A/V recovery.
        "-fflags",
        "nobuffer+genpts+discardcorrupt",
        "-flags",
        "low_delay",
        "-probesize",
        "32768",
        "-analyzeduration",
        "0",
        "-reconnect",
        "1",
        "-reconnect_streamed",
        "1",
        "-reconnect_on_network_error",
        "1",
        "-reconnect_delay_max",
        "2",
        "-i",
        url,
    ]
    .into_iter()
    .map(str::to_string)
    .collect()
}

/// Decode HLS/HTTP live URL → Speaker PCM + WatchTile RGBA (one ffmpeg).
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
    fs::create_dir_all(&run_dir)
        .with_context(|| format!("create {}", run_dir.display()))?;
    let video_fifo = run_dir.join("v.rgba");
    let audio_fifo = run_dir.join("a.f32le");
    mkfifo(&video_fifo)?;
    mkfifo(&audio_fifo)?;

    let stop_task = stop.clone();
    let run_dir_task = run_dir.clone();
    let video_fifo_task = video_fifo;
    let audio_fifo_task = audio_fifo;

    let task = tokio::spawn(async move {
        info!(%url, "watch demux (single ffmpeg A+V)");
        if let Err(e) = run_demux(
            &ffmpeg,
            &url,
            speaker,
            tile,
            stop_task,
            &mut session_alive,
            &video_fifo_task,
            &audio_fifo_task,
        )
        .await
        {
            warn!(error = %e, "watch demux ended");
        }
        let _ = fs::remove_dir_all(&run_dir_task);
    });

    Ok(WatchHandle {
        stop,
        _task: task,
        run_dir,
    })
}

#[allow(clippy::too_many_arguments)]
async fn run_demux(
    ffmpeg: &str,
    url: &str,
    speaker: Speaker,
    tile: WatchTile,
    stop: Arc<AtomicBool>,
    session_alive: &mut watch::Receiver<bool>,
    video_fifo: &Path,
    audio_fifo: &Path,
) -> Result<()> {
    let vf = format!(
        "scale={WATCH_W}:{WATCH_H}:force_original_aspect_ratio=decrease,\
pad={WATCH_W}:{WATCH_H}:(ow-iw)/2:(oh-ih)/2:black,fps={FPS},format=rgba"
    );

    let mut args = live_input_args(url);
    // Video → FIFO
    args.extend(
        [
            "-an",
            "-vf",
            &vf,
            "-pix_fmt",
            "rgba",
            "-f",
            "rawvideo",
            video_fifo.to_str().context("video fifo utf8")?,
        ]
        .into_iter()
        .map(str::to_string),
    );
    // Audio → FIFO (same demux)
    args.extend(
        [
            "-vn",
            "-ac",
            "1",
            "-ar",
            &SPEAK_RATE.to_string(),
            "-f",
            "f32le",
            audio_fifo.to_str().context("audio fifo utf8")?,
        ]
        .into_iter()
        .map(str::to_string),
    );

    // Open FIFOs in parallel *before* ffmpeg writers fully attach.
    // Blocking open waits for the peer; spawn_blocking avoids stalling the runtime.
    let v_path = video_fifo.to_path_buf();
    let a_path = audio_fifo.to_path_buf();
    let open_v = tokio::task::spawn_blocking(move || {
        // O_RDONLY; optional nonblock then clear — plain open is fine with peer spawn.
        fs::OpenOptions::new().read(true).open(v_path)
    });
    let open_a = tokio::task::spawn_blocking(move || {
        fs::OpenOptions::new().read(true).open(a_path)
    });

    let mut child = Command::new(ffmpeg)
        .args(&args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .with_context(|| format!("spawn {ffmpeg} watch demux"))?;

    let v_std = open_v
        .await
        .context("join video fifo open")?
        .context("open video fifo")?;
    let a_std = open_a
        .await
        .context("join audio fifo open")?
        .context("open audio fifo")?;

    let mut v_reader = tokio::fs::File::from_std(v_std);
    let mut a_reader = tokio::fs::File::from_std(a_std);

    let stop_a = stop.clone();
    let stop_v = stop.clone();
    let mut alive_a = session_alive.clone();
    let mut alive_v = session_alive.clone();
    let tile_v = tile;

    let audio = tokio::spawn(async move {
        if let Err(e) = pump_audio(&mut a_reader, speaker, stop_a, &mut alive_a).await {
            warn!(error = %e, "watch audio pump");
        }
    });
    let video = tokio::spawn(async move {
        if let Err(e) = pump_video(&mut v_reader, tile_v, stop_v, &mut alive_v).await {
            warn!(error = %e, "watch video pump");
        }
    });

    // Tear down when either pump ends, session dies, or stop is requested.
    loop {
        if stop.load(Ordering::Relaxed) || !*session_alive.borrow() {
            break;
        }
        if audio.is_finished() || video.is_finished() {
            break;
        }
        tokio::select! {
            _ = tokio::time::sleep(Duration::from_millis(50)) => {}
            _ = session_alive.changed() => {
                if !*session_alive.borrow() {
                    break;
                }
            }
        }
    }

    stop.store(true, Ordering::Relaxed);
    let _ = child.kill().await;
    let _ = audio.await;
    let _ = video.await;
    Ok(())
}

async fn pump_audio(
    stdout: &mut tokio::fs::File,
    speaker: Speaker,
    stop: Arc<AtomicBool>,
    session_alive: &mut watch::Receiver<bool>,
) -> Result<()> {
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
    Ok(())
}

async fn pump_video(
    stdout: &mut tokio::fs::File,
    tile: WatchTile,
    stop: Arc<AtomicBool>,
    session_alive: &mut watch::Receiver<bool>,
) -> Result<()> {
    // Double-buffer: fill `buf`, freeze into tile, allocate next — no mid-frame clone.
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
                return Ok(());
            }
            match stdout.read(&mut buf[filled..]).await {
                Ok(0) => return Ok(()),
                Ok(n) => filled += n,
                Err(e) => {
                    warn!(error = %e, "watch video read");
                    return Ok(());
                }
            }
        }
        // Move buffer into Bytes (no clone), replace with a fresh alloc.
        let frame = std::mem::replace(&mut buf, vec![0u8; FRAME_BYTES]);
        tile.push_rgba_bytes(Bytes::from(frame));
        frames += 1;
        if last_log.elapsed().as_secs() >= 10 {
            info!(frames, fps = FPS, "watch video feed");
            last_log = Instant::now();
        }
    }
    Ok(())
}
