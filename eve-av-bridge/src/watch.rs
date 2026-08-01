//! stream.place / HLS watch → freeq MoQ (audio + real video).
//!
//! Controllers use `/v1/watch/play` and `/v1/watch/stop`.
//!
//! Continuity design (top priority — do not regress):
//! 1. **Separate ffmpeg processes** for audio and video (video must never
//!    block the audio demux graph).
//! 2. **Audio pump runs on a dedicated OS thread** with blocking reads —
//!    H.264 encode on the tokio runtime must not starve the audio path.
//! 3. **Wall-clock paced enqueue** + small prebuffer so MoQ never underruns
//!    and we never dump a 6s HLS catch-up burst into the speaker queue.
//! 4. Video is best-effort drop-frame: demux keeps only the latest RGBA tile
//!    and the encoder takes each frame once (never re-encodes a held frame).
//!    Pop cadence is capped at `AV_VIDEO_FPS` / freeq preset dimensions.

use std::fs;
use std::io::Read as _;
use std::path::{Path, PathBuf};
use std::process::{Command as StdCommand, Stdio as StdStdio};
use std::sync::Arc;
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
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

/// Tile size for freeq MoQ H.264 (VideoPreset::P360 -> 640x360).
/// Must match watch-plane AV_VIDEO_PRESET=360p encoder dimensions.
pub const WATCH_W: u32 = 640;
pub const WATCH_H: u32 = 360;

/// Demux fps filter + drop-frame pop cadence + encoder target.
/// Aligned with watch-plane AV_VIDEO_FPS (default 20).
pub const WATCH_FPS: u32 = 20;

const CHUNK_SAMPLES: usize = SPEAK_RATE as usize / 20; // 50ms
const CHUNK_BYTES: usize = CHUNK_SAMPLES * 4;

/// Prebuffer before MoQ starts hearing stream audio.
/// Keep tiny — prefer drop-to-live over holding a multi-second ring.
const PRIME_SECS: f32 = 0.15;
/// How far ahead of wall-clock we allow enqueued playout to run.
const MAX_AHEAD_SECS: f32 = 0.25;
/// Absolute safety valve (seconds of PCM in Speaker ring). Trim hard.
const MAX_QUEUE_SECS: f32 = 0.45;
/// Target queue depth after a trim (stay near the live edge).
const TARGET_QUEUE_SECS: f32 = 0.2;

/// RGBA frame length for a given tile size (pure helper for tests + demux).
#[inline]
pub fn rgba_frame_bytes(width: u32, height: u32) -> usize {
    (width as usize)
        .saturating_mul(height as usize)
        .saturating_mul(4)
}

/// Wall-clock due time (ms since start) for drop-frame slot `frame_index` at `fps`.
#[inline]
pub fn frame_due_ms(frame_index: u64, fps: u32) -> u64 {
    let fps = u64::from(fps.max(1));
    frame_index.saturating_mul(1000).saturating_div(fps)
}

/// Wall-clock due time for drop-frame slot `frame_index` at `fps`.
#[inline]
fn frame_due(frame_index: u64, fps: u32) -> Duration {
    let fps = u128::from(fps.max(1));
    let nanos = u128::from(frame_index)
        .saturating_mul(1_000_000_000)
        .saturating_div(fps);
    Duration::from_nanos(nanos.min(u128::from(u64::MAX)) as u64)
}

/// Whether an RGBA buffer length matches the tile (rejects silent encoder drops).
#[inline]
pub fn accepts_rgba_len(len: usize, width: u32, height: u32) -> bool {
    len == rgba_frame_bytes(width, height)
}

const FRAME_BYTES: usize = (WATCH_W as usize) * (WATCH_H as usize) * 4;

#[derive(Clone)]
pub struct WatchTile {
    inner: Arc<WatchInner>,
}

struct WatchInner {
    latest: Mutex<Option<Bytes>>,
    pushed: std::sync::atomic::AtomicU64,
    popped: std::sync::atomic::AtomicU64,
    dropped: std::sync::atomic::AtomicU64,
}

impl WatchTile {
    pub fn new() -> Self {
        Self {
            inner: Arc::new(WatchInner {
                latest: Mutex::new(None),
                pushed: AtomicU64::new(0),
                popped: AtomicU64::new(0),
                dropped: AtomicU64::new(0),
            }),
        }
    }

    pub fn video_source(&self) -> WatchVideoSource {
        WatchVideoSource {
            tile: self.clone(),
            frame_index: 0,
            t0: Instant::now(),
        }
    }

    pub fn push_rgba_bytes(&self, bytes: Bytes) {
        if !accepts_rgba_len(bytes.len(), WATCH_W, WATCH_H) {
            return;
        }
        let mut slot = self.inner.latest.lock().expect("latest");
        if slot.is_some() {
            self.inner.dropped.fetch_add(1, Ordering::Relaxed);
        }
        *slot = Some(bytes);
        self.inner.pushed.fetch_add(1, Ordering::Relaxed);
    }
}

pub struct WatchVideoSource {
    tile: WatchTile,
    frame_index: u64,
    t0: Instant,
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
        // Take-only: never clone/hold-last. Downstream SharedVideoSource +
        // the H.264 pipeline already drop when the encoder polls faster than
        // demux, and WatchTile.push overwrites when demux is ahead. Do not
        // cadence-gate here — sleeping on due-time re-introduces hold latency
        // on the vshr thread.
        let pixels = self.tile.inner.latest.lock().expect("latest").take();
        let Some(pixels) = pixels else {
            // Brief yield so a parked-empty vshr loop does not burn a core.
            std::thread::sleep(Duration::from_millis(2));
            return Ok(None);
        };
        let elapsed = self.t0.elapsed();
        self.tile.inner.popped.fetch_add(1, Ordering::Relaxed);
        self.frame_index = self.frame_index.saturating_add(1);
        // Wall-clock PTS so SharedVideoSource does not sleep on a future
        // cadence slot (that sleep is what felt like "holding frames").
        Ok(Some(VideoFrame::new_rgba(pixels, WATCH_W, WATCH_H, elapsed)))
    }
    fn start(&mut self) -> Result<()> {
        self.frame_index = 0;
        // Re-anchor when the encoder (re)subscribes so PTS starts near zero
        // instead of "seconds since tile birth" (that made vshr sleep/hold).
        self.t0 = Instant::now();
        Ok(())
    }
    fn stop(&mut self) -> Result<()> {
        Ok(())
    }
}

pub struct WatchHandle {
    stop: Arc<AtomicBool>,
    task: Option<tokio::task::JoinHandle<()>>,
    run_dir: PathBuf,
}

impl WatchHandle {
    pub fn stop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(t) = self.task.take() {
            t.abort();
        }
    }
}

impl Drop for WatchHandle {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(t) = self.task.take() {
            t.abort();
        }
        // Best-effort cleanup; demux tasks may still exit async.
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
    let out = StdCommand::new("sh")
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
        || StdCommand::new(path)
            .arg("-version")
            .stdout(StdStdio::null())
            .stderr(StdStdio::null())
            .status()
            .map(|s| s.success())
            .unwrap_or(false)
}

fn is_whep_url(url: &str) -> bool {
    let u = url.to_ascii_lowercase();
    u.contains("place.stream.playback.whep")
}

fn which_whep_demux() -> Result<String> {
    if let Ok(p) = std::env::var("WHEP_DEMUX_PATH") {
        if !p.is_empty() && Path::new(&p).exists() {
            return Ok(p);
        }
    }
    for candidate in [
        "/home/boxd/my-agent/scripts/whep-watch-demux.py",
        "/home/boxd/bin/whep-watch-demux.py",
    ] {
        if Path::new(candidate).exists() {
            return Ok(candidate.to_string());
        }
    }
    bail!("whep-watch-demux.py not found (set WHEP_DEMUX_PATH)")
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

/// Prefer stream.place AAC media playlist (track=3) over the master.
/// Master demux with multi-audio is fragile; the AAC rendition is reliable.
fn resolve_audio_hls_url(master_url: &str) -> String {
    let body = match std::process::Command::new("curl")
        .args(["-fsS", "--max-time", "5", master_url])
        .output()
    {
        Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout).into_owned(),
        _ => return master_url.to_string(),
    };
    let mut aac_uri: Option<String> = None;
    for line in body.lines() {
        if !line.starts_with("#EXT-X-MEDIA:") || !line.contains("TYPE=AUDIO") {
            continue;
        }
        let is_aac = line.contains("mp4a") || line.contains("AAC");
        let uri = line.split("URI=\"").nth(1).and_then(|s| s.split('"').next());
        if let (true, Some(u)) = (is_aac, uri) {
            aac_uri = Some(u.to_string());
            if line.contains("DEFAULT=YES") {
                break;
            }
        }
    }
    let Some(uri) = aac_uri else {
        return master_url.to_string();
    };
    if uri.starts_with("http://") || uri.starts_with("https://") {
        return uri;
    }
    if let Ok(base) = url::Url::parse(master_url) {
        if let Ok(joined) = base.join(&uri) {
            return joined.to_string();
        }
    }
    format!("https://stream.place{uri}")
}


fn hls_input_args(url: &str) -> Vec<String> {
    [
        "-hide_banner",
        "-loglevel",
        "error",
        // Do NOT use discardcorrupt — on stream.place fMP4 it drops every
        // audio packet ("Nothing was written into output file").
        "-fflags",
        "+genpts+flush_packets",
        "-flags",
        "low_delay",
        "-probesize",
        "1000000",
        "-analyzeduration",
        "500000",
        "-reconnect",
        "1",
        "-reconnect_streamed",
        "1",
        "-reconnect_on_network_error",
        "1",
        "-reconnect_delay_max",
        "5",
        // Latest segment — drop to live edge instead of holding backlog.
        "-live_start_index",
        "-1",
        "-i",
        url,
    ]
    .into_iter()
    .map(str::to_string)
    .collect()
}

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
    if is_whep_url(&url) {
        return start_whep_watch(url, speaker, session_alive, tile);
    }
    let ffmpeg = which_ffmpeg()?;
    let stop = Arc::new(AtomicBool::new(false));
    let run_dir = std::env::temp_dir().join(format!("eve-watch-{}", uuid::Uuid::new_v4()));
    fs::create_dir_all(&run_dir).with_context(|| format!("create {}", run_dir.display()))?;

    let stop_task = stop.clone();
    let run_dir_task = run_dir.clone();

    let task = tokio::spawn(async move {
        info!(%url, "watch demux HLS (split A/V; audio on OS thread)");

        // --- Audio: dedicated OS thread (must not share tokio with H.264) ---
        let stop_a = stop_task.clone();
        let alive_flag = Arc::new(AtomicBool::new(true));
        let alive_flag_a = alive_flag.clone();
        let speaker_a = speaker.clone();
        let ffmpeg_a = ffmpeg.clone();
        let url_a = url.clone();
        let audio_thread = std::thread::Builder::new()
            .name("watch-audio".into())
            .spawn(move || {
                audio_thread_main(ffmpeg_a, url_a, speaker_a, stop_a, alive_flag_a);
            })
            .expect("spawn watch-audio thread");

        // --- Video: async best-effort on tokio ---
        let stop_v = stop_task.clone();
        let mut alive_v = session_alive.clone();
        let tile_v = tile.clone();
        let ffmpeg_v = ffmpeg.clone();
        let url_v = url.clone();
        let run_dir_v = run_dir_task.clone();
        let video = tokio::spawn(async move {
            video_loop(ffmpeg_v, url_v, tile_v, stop_v, &mut alive_v, run_dir_v).await;
        });

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
        alive_flag.store(false, Ordering::Relaxed);
        let _ = video.await;
        let _ = audio_thread.join();
        let _ = fs::remove_dir_all(&run_dir_task);
    });

    Ok(WatchHandle {
        stop,
        task: Some(task),
        run_dir,
    })
}


fn start_whep_watch(
    url: String,
    speaker: Speaker,
    mut session_alive: watch::Receiver<bool>,
    tile: WatchTile,
) -> Result<WatchHandle> {
    let demux = which_whep_demux()?;
    let stop = Arc::new(AtomicBool::new(false));
    let run_dir = std::env::temp_dir().join(format!("eve-watch-{}", uuid::Uuid::new_v4()));
    fs::create_dir_all(&run_dir).with_context(|| format!("create {}", run_dir.display()))?;

    let stop_task = stop.clone();
    let run_dir_task = run_dir.clone();

    let task = tokio::spawn(async move {
        info!(%url, demux = %demux, "watch demux WHEP (WebRTC → rgba + f32le)");
        let alive_flag = Arc::new(AtomicBool::new(true));

        while !stop_task.load(Ordering::Relaxed) && *session_alive.borrow() {
            let video_fifo = run_dir_task.join("v.rgba");
            let _ = fs::remove_file(&video_fifo);
            if let Err(e) = mkfifo(&video_fifo) {
                warn!(error = %e, "whep mkfifo");
                tokio::time::sleep(Duration::from_millis(500)).await;
                continue;
            }
            let Some(fifo_str) = video_fifo.to_str().map(str::to_string) else {
                warn!("whep fifo path not utf8");
                break;
            };

            // std::process so audio thread can take ChildStdout (AsRawFd + Read).
            let mut child = match StdCommand::new(&demux)
                .args(["--whep-url", &url, "--video-fifo", &fifo_str])
                .stdin(StdStdio::null())
                .stdout(StdStdio::piped())
                .stderr(StdStdio::piped())
                .spawn()
            {
                Ok(c) => c,
                Err(e) => {
                    warn!(error = %e, "spawn whep demux");
                    tokio::time::sleep(Duration::from_millis(500)).await;
                    continue;
                }
            };

            if let Some(mut err) = child.stderr.take() {
                std::thread::spawn(move || {
                    let mut buf = [0u8; 2048];
                    loop {
                        match err.read(&mut buf) {
                            Ok(0) | Err(_) => break,
                            Ok(n) => {
                                let line = String::from_utf8_lossy(&buf[..n]);
                                for l in line.lines() {
                                    if !l.trim().is_empty() {
                                        info!(target: "whep_demux", "{l}", l = l);
                                    }
                                }
                            }
                        }
                    }
                });
            }

            let stop_a = stop_task.clone();
            let alive_a = alive_flag.clone();
            let speaker_a = speaker.clone();
            let stdout = match child.stdout.take() {
                Some(s) => s,
                None => {
                    warn!("whep demux missing stdout");
                    let _ = child.kill();
                    break;
                }
            };
            let audio_thread = std::thread::Builder::new()
                .name("watch-whep-audio".into())
                .spawn(move || {
                    if let Err(e) =
                        pump_f32le_audio(stdout, &speaker_a, &stop_a, &alive_a, "whep")
                    {
                        warn!(error = %e, "whep audio pump ended");
                    }
                })
                .expect("spawn whep audio");

            let stop_v = stop_task.clone();
            let mut alive_v = session_alive.clone();
            let tile_v = tile.clone();
            let v_path = video_fifo.clone();
            let video = tokio::spawn(async move {
                if let Err(e) = read_rgba_fifo(v_path, tile_v, stop_v, &mut alive_v, "whep").await
                {
                    warn!(error = %e, "whep video pump ended");
                }
            });

            loop {
                if stop_task.load(Ordering::Relaxed) || !*session_alive.borrow() {
                    break;
                }
                match child.try_wait() {
                    Ok(Some(status)) => {
                        warn!(?status, "whep demux exited");
                        break;
                    }
                    Ok(None) => {}
                    Err(e) => {
                        warn!(error = %e, "whep demux wait");
                        break;
                    }
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

            let _ = child.kill();
            let _ = child.wait();
            let _ = video.await;
            let _ = audio_thread.join();
            let _ = fs::remove_file(&video_fifo);

            if stop_task.load(Ordering::Relaxed) || !*session_alive.borrow() {
                break;
            }
            info!("whep demux restart in 500ms");
            tokio::time::sleep(Duration::from_millis(500)).await;
        }

        alive_flag.store(false, Ordering::Relaxed);
        let _ = fs::remove_dir_all(&run_dir_task);
    });

    Ok(WatchHandle {
        stop,
        task: Some(task),
        run_dir,
    })
}


fn set_pipe_size(file: &std::fs::File, want: usize) {
    use std::os::unix::io::AsRawFd;
    // Linux fcntl F_SETPIPE_SZ / F_GETPIPE_SZ
    const F_SETPIPE_SZ: i32 = 1031;
    const F_GETPIPE_SZ: i32 = 1032;
    let fd = file.as_raw_fd();
    let rc = unsafe { libc::fcntl(fd, F_SETPIPE_SZ, want as libc::c_int) };
    if rc < 0 {
        warn!(
            error = %std::io::Error::last_os_error(),
            want,
            "F_SETPIPE_SZ failed"
        );
    } else {
        let got = unsafe { libc::fcntl(fd, F_GETPIPE_SZ) };
        info!(want, got, "video fifo pipe size");
    }
}

async fn read_rgba_fifo(
    video_fifo: PathBuf,
    tile: WatchTile,
    stop: Arc<AtomicBool>,
    session_alive: &mut watch::Receiver<bool>,
    label: &str,
) -> Result<()> {
    let v_path = video_fifo.clone();
    let open_v = tokio::task::spawn_blocking(move || fs::OpenOptions::new().read(true).open(v_path));
    let v_std = match tokio::time::timeout(Duration::from_secs(30), async {
        let joined = open_v.await.context("join video fifo open")?;
        let f = joined.context("open video fifo")?;
        Ok::<_, anyhow::Error>(f)
    })
    .await
    {
        Ok(Ok(f)) => f,
        Ok(Err(e)) => bail!("open {label} video fifo: {e}"),
        Err(_) => bail!("timeout opening {label} video fifo"),
    };
    // One full RGBA tile must fit (else short writes → wave tear). pipe-max is often 1MiB.
    set_pipe_size(&v_std, FRAME_BYTES.max(512 * 1024).min(1024 * 1024));
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
                return Ok(());
            }
            match v_reader.read(&mut buf[filled..]).await {
                Ok(0) => return Ok(()),
                Ok(n) => filled += n,
                Err(e) => {
                    warn!(error = %e, label, "video read");
                    return Ok(());
                }
            }
        }
        let frame = std::mem::replace(&mut buf, vec![0u8; FRAME_BYTES]);
        tile.push_rgba_bytes(Bytes::from(frame));
        frames += 1;
        if last_log.elapsed().as_secs() >= 10 {
            let pushed = tile.inner.pushed.load(Ordering::Relaxed);
            let popped = tile.inner.popped.load(Ordering::Relaxed);
            let dropped = tile.inner.dropped.load(Ordering::Relaxed);
            let demux_fps = frames as f32 / last_log.elapsed().as_secs_f32().max(0.001);
            info!(
                frames_in = frames,
                demux_fps,
                pushed,
                popped,
                dropped,
                label,
                "video feed (latest-drop)"
            );
            frames = 0;
            last_log = Instant::now();
        }
    }
    Ok(())
}

fn audio_thread_main(
    ffmpeg: String,
    url: String,
    speaker: Speaker,
    stop: Arc<AtomicBool>,
    session_alive: Arc<AtomicBool>,
) {
    while !stop.load(Ordering::Relaxed) && session_alive.load(Ordering::Relaxed) {
        if let Err(e) = run_audio_blocking(&ffmpeg, &url, &speaker, &stop, &session_alive) {
            warn!(error = %e, "watch audio demux ended");
        }
        if stop.load(Ordering::Relaxed) || !session_alive.load(Ordering::Relaxed) {
            break;
        }
        warn!("watch audio demux restart in 200ms");
        std::thread::sleep(Duration::from_millis(200));
    }
}


/// Shared paced f32le mono → Speaker pump (HLS ffmpeg stdout or WHEP demux stdout).
fn pump_f32le_audio(
    mut stdout: impl std::io::Read + std::os::unix::io::AsRawFd,
    speaker: &Speaker,
    stop: &AtomicBool,
    session_alive: &AtomicBool,
    label: &str,
) -> Result<()> {
    {
        use std::os::unix::io::AsRawFd;
        let fd = stdout.as_raw_fd();
        let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
        if flags >= 0 {
            unsafe {
                libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK);
            }
        }
    }
    let mut buf = vec![0u8; CHUNK_BYTES];
    let mut carry: Vec<u8> = Vec::new();
    let mut stage: Vec<f32> = Vec::new();
    let mut primed = false;
    let mut play_origin: Option<Instant> = None;
    let mut samples_sent: u64 = 0;
    let mut last_log = Instant::now();
    let mut bytes_in: u64 = 0;

    loop {
        if stop.load(Ordering::Relaxed) || !session_alive.load(Ordering::Relaxed) {
            break;
        }
        let n = match stdout.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => n,
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                std::thread::sleep(Duration::from_millis(50));
                continue;
            }
            Err(e) => {
                warn!(error = %e, label, "audio read");
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
                let secs = stage.len() as f32 / SPEAK_RATE as f32;
                if secs >= PRIME_SECS {
                    speaker.enqueue(&stage, SPEAK_RATE);
                    samples_sent += stage.len() as u64;
                    stage.clear();
                    primed = true;
                    play_origin = Some(Instant::now());
                    info!(
                        queue_secs = speaker.queued_secs(),
                        label,
                        "audio primed — continuous playout"
                    );
                }
                continue;
            }

            let origin = play_origin.expect("primed");
            let sent_secs = samples_sent as f32 / SPEAK_RATE as f32;
            let elapsed = origin.elapsed().as_secs_f32();
            if sent_secs - elapsed > MAX_AHEAD_SECS {
                if speaker.queued_secs() > TARGET_QUEUE_SECS {
                    speaker.trim_to_secs(TARGET_QUEUE_SECS);
                }
                continue;
            }

            if speaker.queued_secs() > MAX_QUEUE_SECS {
                speaker.trim_to_secs(TARGET_QUEUE_SECS);
            }

            speaker.enqueue(&pcm, SPEAK_RATE);
            samples_sent += pcm.len() as u64;
        }

        if last_log.elapsed().as_secs() >= 10 {
            info!(
                bytes_in,
                samples_sent,
                primed,
                queue_secs = speaker.queued_secs(),
                label,
                "audio feed"
            );
            last_log = Instant::now();
        }
    }
    Ok(())
}

/// Blocking audio demux on a dedicated thread — continuous playout.
fn run_audio_blocking(
    ffmpeg: &str,
    url: &str,
    speaker: &Speaker,
    stop: &AtomicBool,
    session_alive: &AtomicBool,
) -> Result<()> {
    let ar = SPEAK_RATE.to_string();
    // Prefer the AAC media playlist — much more reliable than master multi-audio.
    let audio_url = resolve_audio_hls_url(url);
    if audio_url != url {
        info!(%audio_url, "watch audio using AAC media playlist");
    }
    let mut args = hls_input_args(&audio_url);
    // Single-rendition playlist: one audio stream at 0:a:0.
    args.extend(
        [
            "-map",
            "0:a:0",
            "-vn",
            "-ac",
            "1",
            "-ar",
            &ar,
            "-f",
            "f32le",
            "pipe:1",
        ]
        .into_iter()
        .map(str::to_string),
    );

    let mut child = StdCommand::new(ffmpeg)
        .args(&args)
        .stdin(StdStdio::null())
        .stdout(StdStdio::piped())
        .stderr(StdStdio::piped())
        .spawn()
        .with_context(|| format!("spawn {ffmpeg} watch audio"))?;

    let stdout = child.stdout.take().context("ffmpeg stdout")?;
    let pump_res = pump_f32le_audio(stdout, speaker, stop, session_alive, "watch");

    let _ = child.kill();
    match child.wait() {
        Ok(status) => {
            if !status.success() {
                info!(?status, "watch audio ffmpeg exited");
            }
        }
        Err(e) => warn!(error = %e, "watch audio ffmpeg wait"),
    }
    if let Some(mut err) = child.stderr.take() {
        let mut s = String::new();
        let _ = err.read_to_string(&mut s);
        let s = s.trim();
        if !s.is_empty() {
            warn!(stderr = %s.chars().take(400).collect::<String>(), "watch audio ffmpeg stderr");
        }
    }
    pump_res
}


async fn video_loop(
    ffmpeg: String,
    url: String,
    tile: WatchTile,
    stop: Arc<AtomicBool>,
    session_alive: &mut watch::Receiver<bool>,
    run_dir: PathBuf,
) {
    while !stop.load(Ordering::Relaxed) && *session_alive.borrow() {
        match run_video_demux(&ffmpeg, &url, tile.clone(), stop.clone(), session_alive, &run_dir)
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

    // No fps= filter here — that holds/duplicates frames inside ffmpeg.
    // Demux pushes every decoded frame; WatchTile keeps only latest; pop
    // takes at WATCH_FPS. That is real drop-to-live, not hold-last.
    let vf = format!(
        "scale={WATCH_W}:{WATCH_H}:force_original_aspect_ratio=decrease:flags=fast_bilinear,\
pad={WATCH_W}:{WATCH_H}:(ow-iw)/2:(oh-ih)/2:black,format=rgba"
    );
    let v_out = video_fifo.to_str().context("video fifo utf8")?.to_string();

    let mut args = hls_input_args(url);
    args.insert(0, "-y".to_string());
    args.extend(
        [
            "-map",
            "0:v:0",
            "-an",
            "-vf",
            &vf,
            "-pix_fmt",
            "rgba",
            "-fps_mode",
            "passthrough",
            "-f",
            "rawvideo",
            &v_out,
        ]
        .into_iter()
        .map(str::to_string),
    );

    let v_path = video_fifo.to_path_buf();
    let open_v =
        tokio::task::spawn_blocking(move || fs::OpenOptions::new().read(true).open(v_path));

    let mut child = Command::new(ffmpeg)
        .args(&args)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .with_context(|| format!("spawn {ffmpeg} watch video"))?;

    let v_std = match tokio::time::timeout(Duration::from_secs(20), async {
        let joined = open_v.await.context("join video fifo open")?;
        let f = joined.context("open video fifo")?;
        Ok::<_, anyhow::Error>(f)
    })
    .await
    {
        Ok(Ok(f)) => f,
        Ok(Err(e)) => {
            let _ = child.kill().await;
            bail!("open watch video fifo: {e}");
        }
        Err(_) => {
            let _ = child.kill().await;
            bail!("timeout opening watch video fifo");
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
                let _ = child.wait().await;
                return Ok(());
            }
            match v_reader.read(&mut buf[filled..]).await {
                Ok(0) => {
                    let _ = child.kill().await;
                    let _ = child.wait().await;
                    return Ok(());
                }
                Ok(n) => filled += n,
                Err(e) => {
                    warn!(error = %e, "watch video read");
                    let _ = child.kill().await;
                    let _ = child.wait().await;
                    return Ok(());
                }
            }
        }
        let frame = std::mem::replace(&mut buf, vec![0u8; FRAME_BYTES]);
        tile.push_rgba_bytes(Bytes::from(frame));
        frames += 1;
        if last_log.elapsed().as_secs() >= 10 {
            let pushed = tile.inner.pushed.load(Ordering::Relaxed);
            let popped = tile.inner.popped.load(Ordering::Relaxed);
            let dropped = tile.inner.dropped.load(Ordering::Relaxed);
            let demux_fps = frames as f32 / last_log.elapsed().as_secs_f32().max(0.001);
            info!(
                frames_in = frames,
                demux_fps,
                pushed,
                popped,
                dropped,
                "watch video feed (latest-drop)"
            );
            frames = 0;
            last_log = Instant::now();
        }
    }

    let _ = child.kill().await;
    let _ = child.wait().await;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use iroh_live::media::traits::VideoSource;
    use std::thread;

    #[test]
    fn rgba_frame_bytes_matches_p360_tile() {
        // VideoPreset::P360 is 640×360; wrong size → silent encoder frame drops.
        assert_eq!(WATCH_W, 640);
        assert_eq!(WATCH_H, 360);
        assert_eq!(rgba_frame_bytes(WATCH_W, WATCH_H), 640 * 360 * 4);
        assert_eq!(rgba_frame_bytes(WATCH_W, WATCH_H), FRAME_BYTES);
        assert!(accepts_rgba_len(FRAME_BYTES, WATCH_W, WATCH_H));
        assert!(!accepts_rgba_len(FRAME_BYTES - 1, WATCH_W, WATCH_H));
        assert!(!accepts_rgba_len(320 * 180 * 4, WATCH_W, WATCH_H)); // 180p mismatch
    }

    #[test]
    fn watch_fps_is_at_least_15() {
        assert!(
            WATCH_FPS >= 15,
            "watch demux/pop cadence must be ≥15 fps (got {WATCH_FPS})"
        );
    }

    #[test]
    fn frame_due_ms_produces_target_fps_interval() {
        // 15 fps uses precise frame-index math, rounded down to milliseconds.
        assert_eq!(frame_due_ms(0, 15), 0);
        assert_eq!(frame_due_ms(1, 15), 66);
        assert_eq!(frame_due_ms(2, 15), 133);
        assert_eq!(frame_due_ms(15, 15), 1000);
        // fps=0 clamps to 1 to avoid div-by-zero.
        assert_eq!(frame_due_ms(3, 0), 3000);
    }

    #[test]
    fn push_rejects_wrong_sized_rgba() {
        let tile = WatchTile::new();
        tile.push_rgba_bytes(Bytes::from(vec![0u8; FRAME_BYTES - 4]));
        let mut src = tile.video_source();
        src.start().unwrap();
        // No frame stored → pop yields None even though due time is 0.
        assert!(src.pop_frame().unwrap().is_none());

        tile.push_rgba_bytes(Bytes::from(vec![1u8; FRAME_BYTES]));
        let f = src.pop_frame().unwrap();
        assert!(f.is_some());
        let frame = f.unwrap();
        assert_eq!(frame.dimensions, [WATCH_W, WATCH_H]);
        let img = frame.rgba_image();
        assert_eq!(img.width(), WATCH_W);
        assert_eq!(img.height(), WATCH_H);
        assert_eq!(img.as_raw().len(), FRAME_BYTES);
    }

    #[test]
    fn drop_frame_pop_emits_each_tile_once() {
        let tile = WatchTile::new();
        tile.push_rgba_bytes(Bytes::from(vec![42u8; FRAME_BYTES]));
        let mut src = tile.video_source();
        src.start().unwrap();

        // Frame 0 is due immediately and consumes the tile.
        assert!(src.pop_frame().unwrap().is_some());
        // Same tile must not be re-emitted (no hold-last).
        assert!(src.pop_frame().unwrap().is_none());

        let period = Duration::from_millis(frame_due_ms(1, WATCH_FPS) + 5);
        thread::sleep(period);
        // Still nothing new → drop/skip, do not hold prior frame.
        assert!(src.pop_frame().unwrap().is_none());

        tile.push_rgba_bytes(Bytes::from(vec![7u8; FRAME_BYTES]));
        assert!(src.pop_frame().unwrap().is_some());
        // Consumed again.
        assert!(src.pop_frame().unwrap().is_none());
    }

    #[test]
    fn drop_frame_push_keeps_only_latest() {
        let tile = WatchTile::new();
        let mut src = tile.video_source();
        src.start().unwrap();
        tile.push_rgba_bytes(Bytes::from(vec![1u8; FRAME_BYTES]));
        tile.push_rgba_bytes(Bytes::from(vec![2u8; FRAME_BYTES]));
        let f = src.pop_frame().unwrap().expect("latest frame");
        assert_eq!(f.rgba_image().as_raw()[0], 2);
        assert!(src.pop_frame().unwrap().is_none());
    }
}
