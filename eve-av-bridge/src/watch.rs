//! stream.place / HLS watch → freeq MoQ (audio + real video).
//!
//! Controllers use `/v1/watch/play` and `/v1/watch/stop`.
//!
//! Continuity design (top priority — do not regress):
//! 1. **Separate ffmpeg processes** for audio and video (video must never
//!    block the audio demux graph).
//! 2. **Audio pump runs on a dedicated OS thread** with blocking reads —
//!    H.264 encode on the tokio runtime must not starve the audio path.
//!    Audio uses a *comfortable* prebuffer + wall-clock paced enqueue so
//!    MoQ never underruns (do not tighten this — audio was already solid).
//! 3. **Video demux on a dedicated OS thread** is a pure pump. ffmpeg is
//!    started with **`-re`** so multi-second HLS segments play through at
//!    media time (without `-re`, a segment dumps in ms and “latest” freezes
//!    for ~8s). We do **not** sleep/pace in the demux loop — that starved
//!    the pipe and left watch-video nearly idle.
//! 4. **Encode only new demux frames** (seq counter), rate-capped at
//!    `WATCH_FPS`. Never re-encode the same held pixels.

use std::fs;
use std::io::Read;
use std::os::unix::io::AsRawFd;
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
use tokio::sync::watch;
use tracing::{info, warn};

/// Tile size for freeq MoQ H.264 (`VideoPreset::P180` → 320×180).
/// Must match watch-plane `AV_VIDEO_PRESET=180p` encoder dimensions.
pub const WATCH_W: u32 = 320;
pub const WATCH_H: u32 = 180;

/// Max encode rate for stream-watch (matches watch-plane `AV_VIDEO_FPS`).
/// Demux runs as fast as source delivers; we drop to this rate on encode.
pub const WATCH_FPS: u32 = 15;

const CHUNK_SAMPLES: usize = SPEAK_RATE as usize / 20; // 50ms
const CHUNK_BYTES: usize = CHUNK_SAMPLES * 4;

/// Prebuffer before MoQ starts hearing stream audio.
/// Large enough to absorb multi-second HLS / MoQ jitter.
/// (Matches production on eve.boxd — do not shrink; audio was already good.)
const PRIME_SECS: f32 = 2.0;
/// How far ahead of wall-clock we allow enqueued playout to run.
const MAX_AHEAD_SECS: f32 = 10.0;
/// Absolute safety valve (seconds of PCM in Speaker ring).
const MAX_QUEUE_SECS: f32 = 15.0;

/// RGBA frame length for a given tile size (pure helper for tests + demux).
#[inline]
pub fn rgba_frame_bytes(width: u32, height: u32) -> usize {
    (width as usize)
        .saturating_mul(height as usize)
        .saturating_mul(4)
}

/// Wall-clock due time (ms since start) for hold-last frame `frame_index` at `fps`.
#[inline]
pub fn frame_due_ms(frame_index: u64, fps: u32) -> u64 {
    let fps = u64::from(fps.max(1));
    frame_index.saturating_mul(1000 / fps)
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
    /// Latest demuxed RGBA + sequence (monotonic). Encode only advances when
    /// `seq` changes — never re-sends the same held frame.
    latest: Mutex<Option<(u64, Bytes)>>,
    seq: AtomicU64,
    t0: Instant,
}

impl WatchTile {
    pub fn new() -> Self {
        Self {
            inner: Arc::new(WatchInner {
                latest: Mutex::new(None),
                seq: AtomicU64::new(0),
                t0: Instant::now(),
            }),
        }
    }

    pub fn video_source(&self) -> WatchVideoSource {
        WatchVideoSource {
            tile: self.clone(),
            frame_index: 0,
            last_seq: 0,
            last_emit: Instant::now()
                .checked_sub(Duration::from_secs(1))
                .unwrap_or_else(|| Instant::now()),
        }
    }

    pub fn push_rgba_bytes(&self, bytes: Bytes) {
        if !accepts_rgba_len(bytes.len(), WATCH_W, WATCH_H) {
            return;
        }
        let seq = self.inner.seq.fetch_add(1, Ordering::Relaxed) + 1;
        *self.inner.latest.lock().expect("latest") = Some((seq, bytes));
    }
}

pub struct WatchVideoSource {
    tile: WatchTile,
    frame_index: u64,
    last_seq: u64,
    last_emit: Instant,
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
        // Sample *latest demux* at a steady WATCH_FPS. Content advances because
        // demux continuously overwrites latest under `-re`. Steady encode cadence
        // keeps freeq clients from stalling between irregular demux arrivals.
        let min_gap = Duration::from_millis(1000 / u64::from(WATCH_FPS.max(1)));
        if self.last_emit.elapsed() + Duration::from_millis(1) < min_gap {
            return Ok(None);
        }

        let (seq, pixels) = {
            let g = self.tile.inner.latest.lock().expect("latest");
            match g.as_ref() {
                Some((seq, bytes)) => (*seq, bytes.clone()),
                None => return Ok(None),
            }
        };

        // Catch up timestamps if encode lagged.
        let elapsed = self.tile.inner.t0.elapsed();
        let period_ms = (1000 / WATCH_FPS.max(1)) as u64;
        let target_index = elapsed.as_millis() as u64 / period_ms.max(1);
        if target_index > self.frame_index {
            self.frame_index = target_index;
        }

        let due = Duration::from_millis(frame_due_ms(self.frame_index, WATCH_FPS));
        self.frame_index = self.frame_index.saturating_add(1);
        self.last_seq = seq;
        self.last_emit = Instant::now();
        Ok(Some(VideoFrame::new_rgba(pixels, WATCH_W, WATCH_H, due)))
    }
    fn start(&mut self) -> Result<()> {
        self.frame_index = 0;
        self.last_seq = 0;
        self.last_emit = Instant::now()
            .checked_sub(Duration::from_secs(1))
            .unwrap_or_else(|| Instant::now());
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


/// Audio demux HLS flags — comfortable buffer, do not tighten (audio was good).
fn hls_input_args(url: &str) -> Vec<String> {
    [
        "-hide_banner",
        "-loglevel",
        "error",
        "-nostdin",
        // Do NOT use discardcorrupt — on stream.place fMP4 it drops every
        // audio packet ("Nothing was written into output file").
        "-fflags",
        "+genpts",
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
        // Stay further behind live edge so the audio ring can fill smoothly.
        "-live_start_index",
        "-2",
        "-i",
        url,
    ]
    .into_iter()
    .map(str::to_string)
    .collect()
}

/// Video-only HLS flags.
///
/// stream.place uses ~8s fMP4 segments. Without realtime pacing, ffmpeg
/// decodes an entire segment as fast as the CPU allows; a “latest frame”
/// consumer then shows one still until the next segment. `-re` / `-readrate 1`
/// makes decode follow presentation timestamps so motion plays through.
fn hls_video_input_args(url: &str) -> Vec<String> {
    [
        "-hide_banner",
        "-loglevel",
        "error",
        // Critical: without this, ffmpeg spins on read(stdin)→/dev/null EOF
        // and never emits video (freeq holds a still forever). Confirmed via
        // strace: read(0,"",1)=0 in a tight loop.
        "-nostdin",
        // Do NOT use -re here: with this HLS source it stalls after connect
        // and writes zero rawvideo frames (watch-video stuck in pipe_read).
        // Realtime pacing is done with the `realtime` filter after decode.
        "-fflags",
        "+genpts+flush_packets",
        "-flags",
        "low_delay",
        "-probesize",
        "2000000",
        "-analyzeduration",
        "1000000",
        "-reconnect",
        "1",
        "-reconnect_streamed",
        "1",
        "-reconnect_on_network_error",
        "1",
        "-reconnect_delay_max",
        "5",
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
    let ffmpeg = which_ffmpeg()?;
    let stop = Arc::new(AtomicBool::new(false));
    let run_dir = std::env::temp_dir().join(format!("eve-watch-{}", uuid::Uuid::new_v4()));
    fs::create_dir_all(&run_dir).with_context(|| format!("create {}", run_dir.display()))?;

    let stop_task = stop.clone();
    let run_dir_task = run_dir.clone();

    let task = tokio::spawn(async move {
        info!(%url, "watch demux (split A/V; both demuxes on OS threads)");

        // Shared "session still live" flag for the OS threads (watch channel
        // is not Sync across std threads without a clone+poll task).
        let alive_flag = Arc::new(AtomicBool::new(true));
        let alive_watch = session_alive.clone();
        let alive_flag_poll = alive_flag.clone();
        let stop_poll = stop_task.clone();
        let alive_poll = tokio::spawn(async move {
            let mut rx = alive_watch;
            loop {
                if stop_poll.load(Ordering::Relaxed) || !*rx.borrow() {
                    alive_flag_poll.store(false, Ordering::Relaxed);
                    break;
                }
                tokio::select! {
                    _ = tokio::time::sleep(Duration::from_millis(100)) => {}
                    _ = rx.changed() => {}
                }
            }
            alive_flag_poll.store(false, Ordering::Relaxed);
        });

        // --- Audio: dedicated OS thread (must not share tokio with H.264) ---
        let stop_a = stop_task.clone();
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

        // --- Video: dedicated OS thread — drain pipe, keep only latest ---
        let stop_v = stop_task.clone();
        let alive_flag_v = alive_flag.clone();
        let tile_v = tile.clone();
        let ffmpeg_v = ffmpeg.clone();
        let url_v = url.clone();
        let run_dir_v = run_dir_task.clone();
        let video_thread = std::thread::Builder::new()
            .name("watch-video".into())
            .spawn(move || {
                video_thread_main(ffmpeg_v, url_v, tile_v, stop_v, alive_flag_v, run_dir_v);
            })
            .expect("spawn watch-video thread");

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
        let _ = alive_poll.await;
        let _ = audio_thread.join();
        let _ = video_thread.join();
        let _ = fs::remove_dir_all(&run_dir_task);
    });

    Ok(WatchHandle {
        stop,
        task: Some(task),
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

    let mut stdout = child.stdout.take().context("ffmpeg stdout")?;
    // Non-blocking so we can honor `stop` every ~100ms instead of hanging forever
    // on a stalled HLS demux (which looks like "watch never started").
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

        // ALWAYS read — never pause the demux for pacing. Pausing freezes HLS
        // on the live edge and was the multi-second cutout loop.
        let n = match stdout.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => n,
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                std::thread::sleep(Duration::from_millis(50));
                continue;
            }
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

            // Pace *enqueue* to wall-clock (drop excess), not the demux read.
            let origin = play_origin.expect("primed");
            let sent_secs = samples_sent as f32 / SPEAK_RATE as f32;
            let elapsed = origin.elapsed().as_secs_f32();
            if sent_secs - elapsed > MAX_AHEAD_SECS {
                // Drop this chunk — keep demux live, keep MoQ queue stable.
                continue;
            }

            if speaker.queued_secs() > MAX_QUEUE_SECS {
                speaker.trim_to_secs(MAX_QUEUE_SECS * 0.75);
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
    Ok(())
}

fn video_thread_main(
    ffmpeg: String,
    url: String,
    tile: WatchTile,
    stop: Arc<AtomicBool>,
    session_alive: Arc<AtomicBool>,
    run_dir: PathBuf,
) {
    while !stop.load(Ordering::Relaxed) && session_alive.load(Ordering::Relaxed) {
        if let Err(e) = run_video_blocking(&ffmpeg, &url, &tile, &stop, &session_alive, &run_dir) {
            warn!(error = %e, "watch video demux ended");
        }
        if stop.load(Ordering::Relaxed) || !session_alive.load(Ordering::Relaxed) {
            break;
        }
        info!("watch video demux restart in 500ms");
        std::thread::sleep(Duration::from_millis(500));
    }
}

/// Blocking video demux on a dedicated thread — pure pump via **stdout pipe**
/// (same pattern as audio). Named fifos were leaving watch-video asleep with
/// no data while freeq held a still.
///
/// ffmpeg `-re` is the only clock so multi-second HLS segments play through.
fn run_video_blocking(
    ffmpeg: &str,
    url: &str,
    tile: &WatchTile,
    stop: &AtomicBool,
    session_alive: &AtomicBool,
    _run_dir: &Path,
) -> Result<()> {
    // `realtime` slows emission to media timestamps so ~8s HLS segments play
    // through instead of dumping into a single “latest” still. No `fps=` —
    // that invents/duplicates frames and freezes motion.
    let vf = format!(
        "scale={WATCH_W}:{WATCH_H}:force_original_aspect_ratio=decrease:flags=fast_bilinear,\
pad={WATCH_W}:{WATCH_H}:(ow-iw)/2:(oh-ih)/2:black,format=rgba,realtime=speed=1"
    );

    let mut args = hls_video_input_args(url);
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
            "pipe:1",
        ]
        .into_iter()
        .map(str::to_string),
    );

    let mut child = StdCommand::new(ffmpeg)
        .args(&args)
        .stdin(StdStdio::null())
        .stdout(StdStdio::piped())
        // MUST drain or null stderr: a full stderr pipe stalls ffmpeg forever
        // (looks like "holding frames" — no new RGBA ever arrives).
        .stderr(StdStdio::piped())
        .spawn()
        .with_context(|| format!("spawn {ffmpeg} watch video"))?;

    if let Some(mut err) = child.stderr.take() {
        std::thread::Builder::new()
            .name("watch-v-err".into())
            .spawn(move || {
                let mut buf = [0u8; 512];
                loop {
                    match err.read(&mut buf) {
                        Ok(0) | Err(_) => break,
                        Ok(n) => {
                            let line = String::from_utf8_lossy(&buf[..n]);
                            for l in line.lines() {
                                if !l.trim().is_empty() {
                                    warn!(target: "watch_video_ffmpeg", "{l}");
                                }
                            }
                        }
                    }
                }
            })
            .ok();
    }

    let mut v_reader = child.stdout.take().context("ffmpeg video stdout")?;
    // Blocking reads: -re already paces; non-blocking + sleep starved the pump.
    // Enlarge pipe for a few frames of jitter under encode load.
    {
        let fd = v_reader.as_raw_fd();
        let want = (FRAME_BYTES * 8 + 4096) as libc::c_int;
        let _ = unsafe { libc::fcntl(fd, libc::F_SETPIPE_SZ, want) };
    }

    let mut buf = vec![0u8; FRAME_BYTES];
    let mut frames_in: u64 = 0;
    let mut last_log = Instant::now();
    let mut log_t0 = Instant::now();

    loop {
        if stop.load(Ordering::Relaxed) || !session_alive.load(Ordering::Relaxed) {
            break;
        }

        // Blocking read of one full frame (ffmpeg `-re` is the clock).
        if let Err(e) = read_exact_blocking(&mut v_reader, &mut buf, stop, session_alive) {
            if e.kind() == std::io::ErrorKind::UnexpectedEof
                || e.kind() == std::io::ErrorKind::Interrupted
            {
                break;
            }
            warn!(error = %e, "watch video read");
            break;
        }
        frames_in += 1;
        let frame = std::mem::replace(&mut buf, vec![0u8; FRAME_BYTES]);
        tile.push_rgba_bytes(Bytes::from(frame));

        if last_log.elapsed().as_secs() >= 5 {
            let secs = log_t0.elapsed().as_secs_f32().max(0.001);
            let demux_fps = frames_in as f32 / secs;
            info!(
                frames_in,
                demux_fps,
                seq = tile.inner.seq.load(Ordering::Relaxed),
                "watch video feed (stdout -re pump)"
            );
            frames_in = 0;
            log_t0 = Instant::now();
            last_log = Instant::now();
        }
    }

    let _ = child.kill();
    let _ = child.wait();
    Ok(())
}

/// Blocking read of exactly `buf.len()` bytes. Polls `stop` between partial
/// reads. Prefer this over non-blocking+sleep: WouldBlock sleep starved the
/// demux (watch-video stuck in nanosleep, freeq held a still).
fn read_exact_blocking(
    r: &mut impl Read,
    buf: &mut [u8],
    stop: &AtomicBool,
    session_alive: &AtomicBool,
) -> std::io::Result<()> {
    use std::io::ErrorKind;
    let mut filled = 0usize;
    while filled < buf.len() {
        if stop.load(Ordering::Relaxed) || !session_alive.load(Ordering::Relaxed) {
            return Err(std::io::Error::new(ErrorKind::Interrupted, "watch stop"));
        }
        match r.read(&mut buf[filled..]) {
            Ok(0) => {
                return Err(std::io::Error::new(
                    ErrorKind::UnexpectedEof,
                    "video pipe eof",
                ));
            }
            Ok(n) => filled += n,
            Err(e) if e.kind() == ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use iroh_live::media::traits::VideoSource;
    use std::thread;

    #[test]
    fn rgba_frame_bytes_matches_p180_tile() {
        // VideoPreset::P180 is 320×180; wrong size → silent encoder frame drops.
        assert_eq!(WATCH_W, 320);
        assert_eq!(WATCH_H, 180);
        assert_eq!(rgba_frame_bytes(WATCH_W, WATCH_H), 320 * 180 * 4);
        assert_eq!(rgba_frame_bytes(WATCH_W, WATCH_H), FRAME_BYTES);
        assert!(accepts_rgba_len(FRAME_BYTES, WATCH_W, WATCH_H));
        assert!(!accepts_rgba_len(FRAME_BYTES - 1, WATCH_W, WATCH_H));
        assert!(!accepts_rgba_len(640 * 360 * 4, WATCH_W, WATCH_H)); // 360p mismatch
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
        // 15 fps → 1000/15 = 66 ms between frames (integer division).
        assert_eq!(frame_due_ms(0, 15), 0);
        assert_eq!(frame_due_ms(1, 15), 66);
        assert_eq!(frame_due_ms(2, 15), 132);
        assert_eq!(frame_due_ms(15, 15), 990);
        // fps=0 clamps to 1 to avoid div-by-zero.
        assert_eq!(frame_due_ms(3, 0), 3000);
    }

    #[test]
    fn push_rejects_wrong_sized_rgba() {
        let tile = WatchTile::new();
        tile.push_rgba_bytes(Bytes::from(vec![0u8; FRAME_BYTES - 4]));
        let mut src = tile.video_source();
        src.start().unwrap();
        // No frame stored → pop yields None.
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
    fn pop_samples_latest_at_fps_cap() {
        let tile = WatchTile::new();
        let mut src = tile.video_source();
        src.start().unwrap();

        tile.push_rgba_bytes(Bytes::from(vec![42u8; FRAME_BYTES]));
        assert!(src.pop_frame().unwrap().is_some());
        // fps cap — not due yet
        assert!(src.pop_frame().unwrap().is_none());

        let period = Duration::from_millis(1000 / u64::from(WATCH_FPS) + 5);
        thread::sleep(period);
        // Still has latest (hold for cadence) even without a new demux push.
        assert!(src.pop_frame().unwrap().is_some());
    }
}
