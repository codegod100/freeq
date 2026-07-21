//! freeq call → stream.place RTMP egress.
//!
//! Mixes remote freeq participants into a 720p grid, writes raw RGBA to ffmpeg
//! stdin, and pushes H.264+AAC to RTMP. Uses a quiet lavfi tone (not pure
//! silence) and an animated placeholder so stream.place keeps the session live
//! even when the freeq room is empty or tiles are static.

use std::collections::HashMap;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};
use freeq_av::{PcmFrame, VideoHandle, resample_mono};
use tracing::{info, warn};

const OUT_W: u32 = 1280;
const OUT_H: u32 = 720;
const FPS: u32 = 30;
const AUDIO_RATE: u32 = 48_000;
const MAX_AUDIO_RING: usize = AUDIO_RATE as usize * 2;

#[derive(Debug, Clone, serde::Serialize)]
pub struct EgressStatus {
    pub running: bool,
    pub rtmp: Option<String>,
    pub participants: usize,
    pub started_at_ms: Option<u64>,
    pub frames: u64,
    pub last_error: Option<String>,
    pub pid: Option<u32>,
}

struct Slot {
    nick: String,
    video: VideoHandle,
    audio: Vec<f32>,
    last_audio: Instant,
}

struct Inner {
    slots: HashMap<String, Slot>,
    rtmp: Option<String>,
    started: Option<Instant>,
    frames: u64,
    last_error: Option<String>,
    pid: Option<u32>,
}

pub struct CallEgress {
    inner: Arc<Mutex<Inner>>,
    stop: Arc<AtomicBool>,
    active: Arc<AtomicBool>,
}

impl Default for CallEgress {
    fn default() -> Self {
        Self::new()
    }
}

impl CallEgress {
    pub fn new() -> Self {
        Self {
            inner: Arc::new(Mutex::new(Inner {
                slots: HashMap::new(),
                rtmp: None,
                started: None,
                frames: 0,
                last_error: None,
                pid: None,
            })),
            stop: Arc::new(AtomicBool::new(false)),
            active: Arc::new(AtomicBool::new(false)),
        }
    }

    pub fn status(&self) -> EgressStatus {
        let g = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        EgressStatus {
            running: self.active.load(Ordering::Relaxed),
            rtmp: g.rtmp.as_ref().map(|u| redact_rtmp(u)),
            participants: g.slots.len(),
            started_at_ms: g.started.map(|t| t.elapsed().as_millis() as u64),
            frames: g.frames,
            last_error: g.last_error.clone(),
            pid: g.pid,
        }
    }

    pub fn upsert_participant(&self, path: String, nick: String, video: VideoHandle) {
        let mut g = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        g.slots
            .entry(path)
            .and_modify(|s| {
                s.nick = nick.clone();
                s.video = video.clone();
            })
            .or_insert_with(|| Slot {
                nick,
                video,
                audio: Vec::new(),
                last_audio: Instant::now(),
            });
    }

    pub fn remove_participant(&self, path: &str) {
        let mut g = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        g.slots.remove(path);
    }

    pub fn push_audio(&self, path: &str, frame: &PcmFrame) {
        let rate = frame.format.sample_rate;
        let ch = frame.format.channel_count.max(1) as usize;
        let mono: Vec<f32> = if ch == 1 {
            frame.samples.clone()
        } else {
            frame
                .samples
                .chunks(ch)
                .map(|c| c.iter().sum::<f32>() / ch as f32)
                .collect()
        };
        let pcm = if rate == AUDIO_RATE {
            mono
        } else {
            resample_mono(&mono, rate, AUDIO_RATE)
        };
        let mut g = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(slot) = g.slots.get_mut(path) {
            slot.audio.extend_from_slice(&pcm);
            if slot.audio.len() > MAX_AUDIO_RING {
                let drop_n = slot.audio.len() - MAX_AUDIO_RING;
                slot.audio.drain(..drop_n);
            }
            slot.last_audio = Instant::now();
        }
    }

    pub fn start(&self, rtmp_url: String) -> Result<EgressStatus> {
        if rtmp_url.trim().is_empty() {
            bail!("empty rtmp_url");
        }
        self.stop_internal();

        let ffmpeg = which_ffmpeg()?;
        info!(%ffmpeg, rtmp = %redact_rtmp(&rtmp_url), "starting call egress (stdin video + quiet tone)");

        // Quiet sine keeps AAC alive; pure silence + static video can fail to
        // register as live on stream.place. Real freeq PCM is mixed into the
        // video path later — for now video grid is the freeq call view.
        let mut child = Command::new(&ffmpeg)
            .args([
                "-hide_banner",
                "-loglevel",
                "warning",
                "-y",
                "-f",
                "rawvideo",
                "-pix_fmt",
                "rgba",
                "-s",
                &format!("{OUT_W}x{OUT_H}"),
                "-framerate",
                &FPS.to_string(),
                "-i",
                "pipe:0",
                // very quiet tone (stream.place needs non-empty media)
                "-f",
                "lavfi",
                "-i",
                "sine=frequency=220:sample_rate=48000",
                "-filter:a",
                "volume=0.05",
                "-map",
                "0:v:0",
                "-map",
                "1:a:0",
                "-c:v",
                "libx264",
                "-preset",
                "veryfast",
                "-tune",
                "zerolatency",
                "-pix_fmt",
                "yuv420p",
                "-g",
                "30",
                "-keyint_min",
                "30",
                "-sc_threshold",
                "0",
                "-bf",
                "0",
                "-b:v",
                "2500k",
                "-maxrate",
                "2500k",
                "-bufsize",
                "5000k",
                "-c:a",
                "aac",
                "-b:a",
                "128k",
                "-ar",
                "48000",
                "-ac",
                "2",
                "-shortest",
                "-f",
                "flv",
                rtmp_url.as_str(),
            ])
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .spawn()
            .with_context(|| format!("spawn {ffmpeg}"))?;

        let pid = child.id();
        if let Some(mut stderr) = child.stderr.take() {
            std::thread::spawn(move || {
                use std::io::Read;
                let mut buf = [0u8; 1024];
                loop {
                    match stderr.read(&mut buf) {
                        Ok(0) | Err(_) => break,
                        Ok(n) => {
                            let line = String::from_utf8_lossy(&buf[..n]);
                            for l in line.lines() {
                                if !l.trim().is_empty() {
                                    warn!(target: "call_egress_ffmpeg", "{l}");
                                }
                            }
                        }
                    }
                }
            });
        }

        let mut v_out = child.stdin.take().context("ffmpeg stdin")?;

        {
            let mut g = self.inner.lock().unwrap_or_else(|e| e.into_inner());
            g.rtmp = Some(rtmp_url.clone());
            g.started = Some(Instant::now());
            g.frames = 0;
            g.last_error = None;
            g.pid = Some(pid);
        }

        self.stop.store(false, Ordering::SeqCst);
        self.active.store(true, Ordering::SeqCst);

        let inner = self.inner.clone();
        let stop = self.stop.clone();
        let active = self.active.clone();

        std::thread::Builder::new()
            .name("call-egress".into())
            .spawn(move || {
                let result = run_compositor(inner.clone(), stop.clone(), &mut v_out, &mut child);
                if let Err(e) = result {
                    warn!(error = %e, "call egress compositor ended with error");
                    if let Ok(mut g) = inner.lock() {
                        g.last_error = Some(e.to_string());
                    }
                }
                drop(v_out);
                let _ = child.kill();
                let _ = child.wait();
                active.store(false, Ordering::SeqCst);
                if let Ok(mut g) = inner.lock() {
                    g.pid = None;
                }
                info!("call egress stopped");
            })
            .context("spawn compositor thread")?;

        std::thread::sleep(Duration::from_millis(400));
        if !self.active.load(Ordering::Relaxed) {
            let err = self
                .inner
                .lock()
                .ok()
                .and_then(|g| g.last_error.clone())
                .unwrap_or_else(|| "egress failed to start".into());
            bail!("{err}");
        }
        Ok(self.status())
    }

    pub fn stop(&self) -> EgressStatus {
        self.stop_internal();
        self.status()
    }

    fn stop_internal(&self) {
        self.stop.store(true, Ordering::SeqCst);
        std::thread::sleep(Duration::from_millis(80));
        self.active.store(false, Ordering::SeqCst);
    }
}

impl Drop for CallEgress {
    fn drop(&mut self) {
        self.stop_internal();
    }
}

fn run_compositor(
    inner: Arc<Mutex<Inner>>,
    stop: Arc<AtomicBool>,
    v_out: &mut impl Write,
    child: &mut Child,
) -> Result<()> {
    info!("call egress compositing freeq room → stream.place");
    let frame_period = Duration::from_secs_f64(1.0 / FPS as f64);
    let mut next = Instant::now();
    let mut canvas = vec![0u8; (OUT_W * OUT_H * 4) as usize];
    let mut frame_i: u64 = 0;

    while !stop.load(Ordering::Relaxed) {
        if let Ok(Some(status)) = child.try_wait() {
            bail!("ffmpeg exited: {status}");
        }

        let now = Instant::now();
        if now < next {
            std::thread::sleep(next - now);
        }
        next += frame_period;
        if Instant::now() > next + frame_period * 3 {
            next = Instant::now() + frame_period;
        }

        let snapshot: Vec<(String, VideoHandle)> = {
            let g = inner.lock().unwrap_or_else(|e| e.into_inner());
            g.slots
                .values()
                .map(|s| (s.nick.clone(), s.video.clone()))
                .collect()
        };

        // Animated base (prevents x264 all-skip streams that stream.place ignores)
        fill_animated_bg(&mut canvas, frame_i);

        let n = snapshot.len().max(1);
        let cols = (n as f32).sqrt().ceil() as u32;
        let rows = ((n as u32) + cols - 1) / cols.max(1);
        let cell_w = OUT_W / cols.max(1);
        let cell_h = OUT_H / rows.max(1);

        if snapshot.is_empty() {
            draw_waiting_tile(&mut canvas, OUT_W, 0, 0, OUT_W, OUT_H, frame_i);
        } else {
            for (i, (nick, video)) in snapshot.iter().enumerate() {
                let col = (i as u32) % cols.max(1);
                let row = (i as u32) / cols.max(1);
                let dx = col * cell_w;
                let dy = row * cell_h;
                if let Some(frame) = video.latest() {
                    let img = frame.rgba_image();
                    blit_scaled(
                        &mut canvas,
                        OUT_W,
                        img.as_raw(),
                        img.width(),
                        img.height(),
                        dx,
                        dy,
                        cell_w,
                        cell_h,
                    );
                    // nick bar
                    draw_bar(&mut canvas, OUT_W, dx, dy, cell_w, 6, 0x5b, 0x8d, 0xef);
                    let _ = nick;
                } else {
                    draw_waiting_tile(&mut canvas, OUT_W, dx, dy, cell_w, cell_h, frame_i);
                }
            }
        }

        v_out.write_all(&canvas).context("write video stdin")?;
        let _ = v_out.flush();
        frame_i = frame_i.wrapping_add(1);

        if let Ok(mut g) = inner.lock() {
            g.frames = g.frames.saturating_add(1);
        }
    }
    Ok(())
}

fn fill_animated_bg(dst: &mut [u8], frame_i: u64) {
    let t = frame_i as f32 * 0.05;
    let pulse = ((t.sin() * 0.5 + 0.5) * 20.0) as u8;
    for (i, px) in dst.chunks_exact_mut(4).enumerate() {
        let x = (i as u32) % OUT_W;
        let y = (i as u32) / OUT_W;
        let wave = (((x as f32 * 0.01 + t).sin() * 8.0)
            + ((y as f32 * 0.02 - t * 0.7).cos() * 6.0)) as i16;
        let b = 0x18u8.saturating_add(pulse).saturating_add_signed((wave.clamp(-10, 10) as i8));
        px[0] = b.saturating_sub(4);
        px[1] = b.saturating_sub(2);
        px[2] = b.saturating_add(8);
        px[3] = 0xff;
    }
}

fn draw_waiting_tile(
    dst: &mut [u8],
    dw: u32,
    dx: u32,
    dy: u32,
    cell_w: u32,
    cell_h: u32,
    frame_i: u64,
) {
    let sweep = ((frame_i as u32 * 4) % cell_w.max(1)) as u32;
    for y in 0..cell_h {
        for x in 0..cell_w {
            let di = (((dy + y) * dw + (dx + x)) * 4) as usize;
            if di + 3 >= dst.len() {
                continue;
            }
            let near = x.abs_diff(sweep) < 8;
            if near {
                dst[di] = 0x5b;
                dst[di + 1] = 0x8d;
                dst[di + 2] = 0xef;
            } else {
                dst[di] = 0x22;
                dst[di + 1] = 0x24;
                dst[di + 2] = 0x32;
            }
            dst[di + 3] = 0xff;
        }
    }
    draw_bar(dst, dw, dx, dy, cell_w, 8, 0x5b, 0x8d, 0xef);
}

fn draw_bar(dst: &mut [u8], dw: u32, dx: u32, dy: u32, w: u32, h: u32, r: u8, g: u8, b: u8) {
    for y in 0..h {
        for x in 0..w {
            let di = (((dy + y) * dw + (dx + x)) * 4) as usize;
            if di + 3 < dst.len() {
                dst[di] = r;
                dst[di + 1] = g;
                dst[di + 2] = b;
                dst[di + 3] = 0xff;
            }
        }
    }
}

fn blit_scaled(
    dst: &mut [u8],
    dw: u32,
    src: &[u8],
    sw: u32,
    sh: u32,
    dx: u32,
    dy: u32,
    cell_w: u32,
    cell_h: u32,
) {
    if sw == 0 || sh == 0 || cell_w == 0 || cell_h == 0 {
        return;
    }
    let src_aspect = sw as f32 / sh as f32;
    let cell_aspect = cell_w as f32 / cell_h as f32;
    let (tw, th, ox, oy) = if src_aspect > cell_aspect {
        let tw = cell_w;
        let th = (cell_w as f32 / src_aspect) as u32;
        (tw, th.max(1), 0u32, (cell_h.saturating_sub(th)) / 2)
    } else {
        let th = cell_h;
        let tw = (cell_h as f32 * src_aspect) as u32;
        (tw.max(1), th, (cell_w.saturating_sub(tw)) / 2, 0u32)
    };

    for y in 0..th {
        let sy = y * sh / th;
        for x in 0..tw {
            let sx = x * sw / tw;
            let si = ((sy * sw + sx) * 4) as usize;
            let di = (((dy + oy + y) * dw + (dx + ox + x)) * 4) as usize;
            if si + 3 < src.len() && di + 3 < dst.len() {
                dst[di] = src[si];
                dst[di + 1] = src[si + 1];
                dst[di + 2] = src[si + 2];
                dst[di + 3] = 0xff;
            }
        }
    }
}

fn which_ffmpeg() -> Result<String> {
    if let Ok(p) = std::env::var("FFMPEG_BIN") {
        if PathBuf::from(&p).is_file() {
            return Ok(p);
        }
    }
    if let Ok(path) = std::env::var("PATH") {
        for dir in path.split(':') {
            let p = PathBuf::from(dir).join("ffmpeg");
            if p.is_file() {
                return Ok(p.display().to_string());
            }
        }
    }
    for c in ["/usr/bin/ffmpeg", "/bin/ffmpeg"] {
        if Path::new(c).is_file() {
            return Ok(c.into());
        }
    }
    bail!("ffmpeg not found on PATH");
}

fn redact_rtmp(url: &str) -> String {
    if let Some(i) = url.rfind('/') {
        if i + 1 < url.len() {
            return format!("{}***", &url[..=i]);
        }
    }
    "***".into()
}
