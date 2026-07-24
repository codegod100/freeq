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
//! 4. Video is best-effort hold-last-frame at a low encode cadence.

use std::fs;
use std::io::Read as _;
use std::path::{Path, PathBuf};
use std::process::{Command as StdCommand, Stdio as StdStdio};
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

/// Tile size for freeq MoQ H.264 (`VideoPreset::P180`).
pub const WATCH_W: u32 = 320;
pub const WATCH_H: u32 = 180;

/// Encoder pop cadence (hold-last-frame). Keep low so Opus isn't starved.
const FPS: u32 = 8;

const CHUNK_SAMPLES: usize = SPEAK_RATE as usize / 20; // 50ms
const CHUNK_BYTES: usize = CHUNK_SAMPLES * 4;

/// Prebuffer before MoQ starts hearing stream audio.
const PRIME_SECS: f32 = 0.8;
/// How far ahead of wall-clock we allow the speaker queue to run.
const MAX_AHEAD_SECS: f32 = 2.0;
/// Absolute safety valve (seconds of PCM in Speaker).
const MAX_QUEUE_SECS: f32 = 3.5;

const FRAME_BYTES: usize = (WATCH_W as usize) * (WATCH_H as usize) * 4;

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

fn hls_input_args(url: &str) -> Vec<String> {
    [
        "-hide_banner",
        "-loglevel",
        "error",
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
        // A few 1s segments of slack without dumping a huge backlog.
        "-live_start_index",
        "-3",
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
    let ffmpeg = which_ffmpeg()?;
    let stop = Arc::new(AtomicBool::new(false));
    let run_dir = std::env::temp_dir().join(format!("eve-watch-{}", uuid::Uuid::new_v4()));
    fs::create_dir_all(&run_dir).with_context(|| format!("create {}", run_dir.display()))?;

    let stop_task = stop.clone();
    let run_dir_task = run_dir.clone();

    let task = tokio::spawn(async move {
        info!(%url, "watch demux (split A/V; audio on OS thread)");

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
        _task: task,
        run_dir,
    })
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

/// Blocking audio demux on a dedicated thread — continuous playout.
fn run_audio_blocking(
    ffmpeg: &str,
    url: &str,
    speaker: &Speaker,
    stop: &AtomicBool,
    session_alive: &AtomicBool,
) -> Result<()> {
    let ar = SPEAK_RATE.to_string();
    let mut args = hls_input_args(url);
    args.extend(
        [
            "-map",
            "0:a:0?",
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

    let mut stdout = child.stdout.take().context("ffmpeg stdout")?;
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

        // Wall-clock pacing AFTER prime: don't enqueue faster than realtime + slack.
        if let Some(origin) = play_origin {
            let sent_secs = samples_sent as f32 / SPEAK_RATE as f32;
            let elapsed = origin.elapsed().as_secs_f32();
            let ahead = sent_secs - elapsed;
            if ahead > MAX_AHEAD_SECS {
                let sleep_ms = ((ahead - MAX_AHEAD_SECS) * 1000.0).clamp(5.0, 80.0) as u64;
                std::thread::sleep(Duration::from_millis(sleep_ms));
                continue; // re-check stop before next read
            }
        }

        // Safety: if MoQ is badly behind, wait rather than grow forever.
        // Still poll stop so we never hang a shutdown.
        let mut spins = 0u32;
        while speaker.queued_secs() > MAX_QUEUE_SECS {
            if stop.load(Ordering::Relaxed) || !session_alive.load(Ordering::Relaxed) {
                break;
            }
            spins += 1;
            if spins % 50 == 0 {
                warn!(
                    queue_secs = speaker.queued_secs(),
                    "watch audio: MoQ queue high — waiting (encoder drain?)"
                );
            }
            std::thread::sleep(Duration::from_millis(20));
        }

        let n = match stdout.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => n,
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
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
                let secs = stage.len() as f32 / SPEAK_RATE as f32;
                if secs >= PRIME_SECS {
                    speaker.enqueue(&stage, SPEAK_RATE);
                    samples_sent += stage.len() as u64;
                    stage.clear();
                    primed = true;
                    play_origin = Some(Instant::now());
                    info!(
                        queue_secs = speaker.queued_secs(),
                        "watch audio primed — continuous playout"
                    );
                }
                continue;
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
                "watch audio feed"
            );
            last_log = Instant::now();
        }
    }

    let _ = child.kill();
    let _ = child.wait();
    if let Some(mut err) = child.stderr.take() {
        let mut s = String::new();
        let _ = err.read_to_string(&mut s);
        let s = s.trim();
        if !s.is_empty() {
            warn!(stderr = %s.chars().take(400).collect::<String>(), "watch audio ffmpeg stderr");
        }
    }
    Ok(())
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

    // fps filter limited — less decode/scale load; hold-last covers gaps.
    let vf = format!(
        "scale={WATCH_W}:{WATCH_H}:force_original_aspect_ratio=decrease:flags=fast_bilinear,\
pad={WATCH_W}:{WATCH_H}:(ow-iw)/2:(oh-ih)/2:black,fps={FPS},format=rgba"
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
            info!(frames, fps = FPS, "watch video feed");
            last_log = Instant::now();
        }
    }

    let _ = child.kill().await;
    Ok(())
}
