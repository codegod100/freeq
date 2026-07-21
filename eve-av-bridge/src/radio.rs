//! Internet radio → continuous PCM → freeq-av Speaker + RadioViz.
//!
//! Prefer `ffmpeg` (handles icy/shoutcast, mp3, aac). A parallel HTTP
//! connection with `Icy-MetaData: 1` pulls StreamTitle for the video tile.

use std::process::Stdio;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use anyhow::{Context, Result, bail};
use freeq_av::{SPEAK_RATE, Speaker};
use futures_util::StreamExt;
use tokio::io::AsyncReadExt;
use tokio::process::Command;
use tokio::sync::watch;
use tracing::{info, warn};

use crate::viz::RadioViz;

/// Max seconds of audio allowed in the MoQ speak queue while radio plays.
/// Above this we pause reading so we don't lag infinitely if the SFU stalls.
const MAX_QUEUE_SECS: f32 = 2.5;

/// Samples per feed chunk (~100 ms @ 48 kHz mono f32).
const CHUNK_SAMPLES: usize = SPEAK_RATE as usize / 10;
const CHUNK_BYTES: usize = CHUNK_SAMPLES * 4;

pub struct RadioHandle {
    stop: Arc<AtomicBool>,
    viz: Option<RadioViz>,
    /// Latest ICY StreamTitle (shared with the icy task).
    last_title: Arc<std::sync::Mutex<Option<String>>>,
    _task: tokio::task::JoinHandle<()>,
    _icy: tokio::task::JoinHandle<()>,
}

impl RadioHandle {
    pub fn stop(&self) {
        self.stop.store(true, Ordering::Relaxed);
    }

    pub fn title(&self) -> Option<String> {
        self.last_title
            .lock()
            .ok()
            .and_then(|g| g.clone())
            .filter(|t| !t.is_empty())
            .or_else(|| self.viz.as_ref().map(|v| v.title()).filter(|t| !t.is_empty()))
    }
}

/// Spawn a background task that pulls `url` through ffmpeg and enqueues PCM.
/// Always runs an ICY metadata reader for StreamTitle; when `viz` is set, also
/// feeds DSP samples and paints the title on the video tile.
/// `title_tx` receives each new non-empty StreamTitle (song changes).
pub fn start_radio(
    url: String,
    speaker: Speaker,
    mut session_alive: watch::Receiver<bool>,
    viz: Option<RadioViz>,
    title_tx: Option<tokio::sync::mpsc::UnboundedSender<String>>,
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

    if let Some(ref v) = viz {
        v.set_station(station_label(&url));
        v.ensure_renderer();
    }

    let stop = Arc::new(AtomicBool::new(false));
    let stop_task = stop.clone();
    let stop_icy = stop.clone();
    let viz_pcm = viz.clone();
    let viz_icy = viz.clone();
    let url_icy = url.clone();
    let mut alive_icy = session_alive.clone();
    let last_title = Arc::new(std::sync::Mutex::new(None));
    let last_title_icy = last_title.clone();

    let task = tokio::spawn(async move {
        info!(%url, ?ffmpeg, "starting radio decode");
        if let Err(e) =
            run_ffmpeg_pipe(&ffmpeg, &url, speaker, stop_task, &mut session_alive, viz_pcm)
                .await
        {
            warn!(error = %e, "radio stream ended with error");
        } else {
            info!("radio stream ended");
        }
    });

    let icy = tokio::spawn(async move {
        // Brief delay so ffmpeg claims the stream first; icy is a second GET.
        tokio::time::sleep(std::time::Duration::from_millis(400)).await;
        if let Err(e) = run_icy_meta(
            &url_icy,
            viz_icy,
            last_title_icy,
            title_tx,
            stop_icy,
            &mut alive_icy,
        )
        .await
        {
            warn!(error = %e, "icy metadata reader ended");
        }
    });

    Ok(RadioHandle {
        stop,
        viz,
        last_title,
        _task: task,
        _icy: icy,
    })
}

fn station_label(url: &str) -> String {
    url::Url::parse(url)
        .ok()
        .and_then(|u| u.host_str().map(|h| h.to_string()))
        .unwrap_or_else(|| "radio".into())
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

async fn run_ffmpeg_pipe(
    ffmpeg: &str,
    url: &str,
    speaker: Speaker,
    stop: Arc<AtomicBool>,
    session_alive: &mut watch::Receiver<bool>,
    viz: Option<RadioViz>,
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
            let usable = carry.len() - (carry.len() % 4);
            if usable == 0 {
                break;
            }
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
            if let Some(ref v) = viz {
                v.push_samples(&pcm);
            }
            speaker.enqueue(&pcm, SPEAK_RATE);
            carry.drain(..take);
            if carry.len() < CHUNK_BYTES {
                break;
            }
        }

        if last_log.elapsed().as_secs() >= 5 {
            let title = viz.as_ref().map(|v| v.title()).unwrap_or_default();
            info!(
                bytes_in,
                samples_out,
                peak,
                queue_secs = speaker.queued_secs(),
                %title,
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

/// Parallel ICY metadata reader — second HTTP GET with `Icy-MetaData: 1`.
async fn run_icy_meta(
    url: &str,
    viz: Option<RadioViz>,
    last_title: Arc<std::sync::Mutex<Option<String>>>,
    title_tx: Option<tokio::sync::mpsc::UnboundedSender<String>>,
    stop: Arc<AtomicBool>,
    session_alive: &mut watch::Receiver<bool>,
) -> Result<()> {
    let client = reqwest::Client::builder()
        .user_agent("eve-av-bridge/1.0 (radio-viz)")
        .timeout(std::time::Duration::from_secs(30))
        .connect_timeout(std::time::Duration::from_secs(15))
        .build()
        .context("reqwest client")?;

    // Reconnect loop — some stations drop the meta connection periodically.
    while !stop.load(Ordering::Relaxed) && *session_alive.borrow() {
        match icy_session(
            &client,
            url,
            viz.as_ref(),
            &last_title,
            title_tx.as_ref(),
            &stop,
            session_alive,
        )
        .await
        {
            Ok(()) => {
                if stop.load(Ordering::Relaxed) || !*session_alive.borrow() {
                    break;
                }
                info!("icy session ended cleanly — reconnecting in 3s");
            }
            Err(e) => {
                if stop.load(Ordering::Relaxed) || !*session_alive.borrow() {
                    break;
                }
                warn!(error = %e, "icy session error — retry in 5s");
            }
        }
        tokio::time::sleep(std::time::Duration::from_secs(5)).await;
    }
    Ok(())
}

async fn icy_session(
    client: &reqwest::Client,
    url: &str,
    viz: Option<&RadioViz>,
    last_title_shared: &std::sync::Mutex<Option<String>>,
    title_tx: Option<&tokio::sync::mpsc::UnboundedSender<String>>,
    stop: &AtomicBool,
    session_alive: &mut watch::Receiver<bool>,
) -> Result<()> {
    let resp = client
        .get(url)
        .header("Icy-MetaData", "1")
        .send()
        .await
        .context("icy GET")?;

    if !resp.status().is_success() {
        bail!("icy HTTP {}", resp.status());
    }

    // Station name from icy-name / ice-name / icy-description.
    for key in ["icy-name", "ice-name", "icy-description"] {
        if let Some(v) = resp.headers().get(key) {
            if let Ok(s) = v.to_str() {
                let s = s.trim();
                if !s.is_empty() {
                    if let Some(v) = viz {
                        v.set_station(s);
                    }
                    info!(station = %s, "icy station name");
                    break;
                }
            }
        }
    }

    let metaint = resp
        .headers()
        .get("icy-metaint")
        .or_else(|| resp.headers().get("Icy-MetaInt"))
        .and_then(|v| v.to_str().ok())
        .and_then(|s| s.parse::<usize>().ok())
        .unwrap_or(0);

    if metaint == 0 {
        // No interleaved meta — still try once from content-type only.
        warn!("no icy-metaint on stream — song titles unavailable");
        // Hold the connection briefly then exit so we don't waste bandwidth.
        let mut stream = resp.bytes_stream();
        let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(10);
        while tokio::time::Instant::now() < deadline {
            if stop.load(Ordering::Relaxed) || !*session_alive.borrow() {
                break;
            }
            tokio::select! {
                chunk = stream.next() => {
                    if chunk.is_none() { break; }
                }
                _ = tokio::time::sleep(std::time::Duration::from_millis(200)) => {}
            }
        }
        return Ok(());
    }

    info!(metaint, "icy metadata stream open");
    let mut stream = resp.bytes_stream();
    let mut buf: Vec<u8> = Vec::with_capacity(metaint + 512);
    let mut audio_needed = metaint;
    let mut last_title = String::new();

    loop {
        if stop.load(Ordering::Relaxed) || !*session_alive.borrow() {
            break;
        }

        let chunk = match stream.next().await {
            Some(Ok(c)) => c,
            Some(Err(e)) => bail!("icy body: {e}"),
            None => break,
        };
        buf.extend_from_slice(&chunk);

        while !buf.is_empty() {
            if audio_needed > 0 {
                let take = audio_needed.min(buf.len());
                buf.drain(..take);
                audio_needed -= take;
                if audio_needed > 0 {
                    break;
                }
            }

            // Meta length byte
            if buf.is_empty() {
                break;
            }
            let len_byte = buf[0] as usize;
            buf.drain(..1);
            let meta_len = len_byte * 16;
            if meta_len == 0 {
                audio_needed = metaint;
                continue;
            }
            if buf.len() < meta_len {
                // Need more data — put length back conceptually by waiting.
                // We already drained the length byte; stash it via pending.
                // Simpler: keep meta_len and wait for more bytes in outer loop.
                // Restore: we can't easily; buffer partial meta.
                // Use a small state machine via remaining.
                while buf.len() < meta_len {
                    match stream.next().await {
                        Some(Ok(c)) => buf.extend_from_slice(&c),
                        Some(Err(e)) => bail!("icy body: {e}"),
                        None => return Ok(()),
                    }
                    if stop.load(Ordering::Relaxed) {
                        return Ok(());
                    }
                }
            }
            let meta = String::from_utf8_lossy(&buf[..meta_len]).to_string();
            buf.drain(..meta_len);
            if let Some(title) = parse_stream_title(&meta) {
                if title != last_title {
                    info!(%title, "icy StreamTitle");
                    if let Some(v) = viz {
                        v.set_title(&title);
                    }
                    if let Ok(mut g) = last_title_shared.lock() {
                        *g = Some(title.clone());
                    }
                    if let Some(tx) = title_tx {
                        let _ = tx.send(title.clone());
                    }
                    last_title = title;
                }
            }
            audio_needed = metaint;
        }
    }
    Ok(())
}

/// Parse `StreamTitle='…';` (or double-quoted) from an ICY metadata block.
fn parse_stream_title(meta: &str) -> Option<String> {
    let lower = meta.to_ascii_lowercase();
    let key = "streamtitle=";
    let idx = lower.find(key)?;
    let rest = &meta[idx + key.len()..];
    let rest = rest.trim_start();
    let (q, end_pat) = if rest.starts_with('\'') {
        ('\'', "';")
    } else if rest.starts_with('"') {
        ('"', "\";")
    } else {
        return None;
    };
    let body = &rest[1..];
    let end = body
        .find(end_pat)
        .or_else(|| body.find(q))
        .unwrap_or(body.len());
    let title = body[..end].trim();
    if title.is_empty() {
        None
    } else {
        Some(title.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::parse_stream_title;

    #[test]
    fn stream_title_single_quote() {
        let m = "StreamTitle='Artist - Song';StreamUrl='http://x';";
        assert_eq!(parse_stream_title(m).as_deref(), Some("Artist - Song"));
    }

    #[test]
    fn stream_title_empty() {
        assert!(parse_stream_title("StreamTitle='';").is_none());
    }
}
