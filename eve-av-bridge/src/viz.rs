//! Radio / slide video tile for freeq-av H.264.
//!
//! Default: waveform / spectrum bars + ICY StreamTitle (radio).
//! Slide mode: presentation card with headline + wrapped body (quiz slides).

use std::collections::VecDeque;
use std::sync::Arc;
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use anyhow::Result;
use bytes::Bytes;
use iroh_live::media::format::{PixelFormat, VideoFormat, VideoFrame};
use iroh_live::media::traits::VideoSource;

pub const VIDEO_W: u32 = 640;
pub const VIDEO_H: u32 = 360;
const FPS: u64 = 15;

/// Shared state written by the radio feeder / slide controller, read by the video source.
#[derive(Clone)]
pub struct RadioViz {
    inner: Arc<VizInner>,
}

struct VizInner {
    /// Recent mono samples for waveform (at analysis rate, downsampled).
    wave: Mutex<VecDeque<f32>>,
    /// Band energies 0..1 for bar graph (updated each feed).
    bands: Mutex<Vec<f32>>,
    /// ICY / StreamTitle (or fallback station label).
    title: Mutex<String>,
    station: Mutex<String>,
    /// Smoothed peak 0..1 for glow.
    peak: Mutex<f32>,
    /// When true, render a presentation slide instead of radio viz.
    slide_active: AtomicBool,
    slide_headline: Mutex<String>,
    slide_body: Mutex<String>,
    slide_footer: Mutex<String>,
    running: AtomicBool,
    latest: Mutex<Option<VideoFrame>>,
    started: AtomicBool,
}

const WAVE_LEN: usize = 256;
const BANDS: usize = 32;
const ANALYSIS_DOWNSAMPLE: usize = 4; // keep 1 of every N samples

impl RadioViz {
    pub fn new(station_label: impl Into<String>) -> Self {
        let label = station_label.into();
        Self {
            inner: Arc::new(VizInner {
                wave: Mutex::new(VecDeque::with_capacity(WAVE_LEN)),
                bands: Mutex::new(vec![0.0; BANDS]),
                title: Mutex::new(String::new()),
                station: Mutex::new(label),
                peak: Mutex::new(0.0),
                slide_active: AtomicBool::new(false),
                slide_headline: Mutex::new(String::new()),
                slide_body: Mutex::new(String::new()),
                slide_footer: Mutex::new(String::new()),
                running: AtomicBool::new(true),
                latest: Mutex::new(None),
                started: AtomicBool::new(false),
            }),
        }
    }

    pub fn set_station(&self, s: impl Into<String>) {
        *self.inner.station.lock().expect("station") = s.into();
    }

    pub fn set_title(&self, s: impl Into<String>) {
        let t = s.into();
        if !t.is_empty() {
            *self.inner.title.lock().expect("title") = t;
        }
    }

    pub fn title(&self) -> String {
        self.inner.title.lock().expect("title").clone()
    }

    /// Show a presentation slide on the freeq AV video tile.
    pub fn set_slide(
        &self,
        headline: impl Into<String>,
        body: impl Into<String>,
        footer: impl Into<String>,
    ) {
        *self.inner.slide_headline.lock().expect("slide_headline") = headline.into();
        *self.inner.slide_body.lock().expect("slide_body") = body.into();
        *self.inner.slide_footer.lock().expect("slide_footer") = footer.into();
        self.inner.slide_active.store(true, Ordering::Relaxed);
        self.ensure_renderer();
    }

    /// Return to radio (or idle) viz.
    pub fn clear_slide(&self) {
        self.inner.slide_active.store(false, Ordering::Relaxed);
        *self.inner.slide_headline.lock().expect("slide_headline") = String::new();
        *self.inner.slide_body.lock().expect("slide_body") = String::new();
        *self.inner.slide_footer.lock().expect("slide_footer") = String::new();
    }

    pub fn slide_active(&self) -> bool {
        self.inner.slide_active.load(Ordering::Relaxed)
    }

    /// Feed mono PCM (any rate — we only need shape). Call from radio path.
    pub fn push_samples(&self, pcm: &[f32]) {
        if pcm.is_empty() {
            return;
        }
        let mut peak = 0.0f32;
        {
            let mut wave = self.inner.wave.lock().expect("wave");
            for (i, &s) in pcm.iter().enumerate() {
                peak = peak.max(s.abs());
                if i % ANALYSIS_DOWNSAMPLE == 0 {
                    wave.push_back(s);
                    while wave.len() > WAVE_LEN {
                        wave.pop_front();
                    }
                }
            }
        }
        {
            let mut p = self.inner.peak.lock().expect("peak");
            *p = if peak > *p {
                peak
            } else {
                *p * 0.92 + peak * 0.08
            };
        }
        // Band energy: split the latest WAVE_LEN samples into BANDS windows, RMS.
        let wave: Vec<f32> = self.inner.wave.lock().expect("wave").iter().copied().collect();
        if wave.len() < BANDS {
            return;
        }
        let chunk = wave.len() / BANDS;
        let mut bands = vec![0.0f32; BANDS];
        for b in 0..BANDS {
            let slice = &wave[b * chunk..(b + 1) * chunk];
            let rms = (slice.iter().map(|x| x * x).sum::<f32>() / slice.len() as f32).sqrt();
            // Smooth against previous.
            let prev = self.inner.bands.lock().expect("bands")[b];
            bands[b] = (prev * 0.55 + rms * 0.45).min(1.0);
        }
        *self.inner.bands.lock().expect("bands") = bands;
    }

    /// Stop the background renderer (session teardown / radio stop).
    pub fn stop(&self) {
        self.inner.running.store(false, Ordering::Relaxed);
    }

    /// Hand a cloneable VideoSource to AvSession::connect.
    /// Safe to call again after MoQ reconnect — each source is a fresh handle.
    pub fn video_source(&self) -> VizVideoSource {
        VizVideoSource {
            viz: self.clone(),
            frame_index: 0,
        }
    }

    /// Ensure the render loop is alive (idempotent; restarts after stop).
    pub fn ensure_renderer(&self) {
        // Allow restart after a previous stop (e.g. reconnect).
        if !self.inner.running.load(Ordering::Relaxed) {
            self.inner.running.store(true, Ordering::Relaxed);
            self.inner.started.store(false, Ordering::Relaxed);
        }
        if !self.inner.started.swap(true, Ordering::Relaxed) {
            self.spawn_renderer();
        }
    }

    /// Background render loop — writes frames into `latest` for the encoder.
    fn spawn_renderer(&self) {
        let viz = self.clone();
        std::thread::Builder::new()
            .name("radio-viz".into())
            .spawn(move || {
                #[cfg(target_os = "linux")]
                unsafe {
                    libc::nice(5);
                }
                viz.render_loop();
            })
            .expect("spawn radio-viz");
    }

    fn render_loop(&self) {
        let frame_ms = 1000 / FPS;
        let t0 = Instant::now();
        while self.inner.running.load(Ordering::Relaxed) {
            let start = Instant::now();
            let frame = self.render_frame(t0.elapsed());
            *self.inner.latest.lock().expect("latest") = Some(frame);
            let spent = start.elapsed();
            if let Some(rest) = Duration::from_millis(frame_ms).checked_sub(spent) {
                std::thread::sleep(rest);
            }
        }
    }

    fn render_frame(&self, elapsed: Duration) -> VideoFrame {
        if self.inner.slide_active.load(Ordering::Relaxed) {
            return self.render_slide_frame(elapsed);
        }

        let w = VIDEO_W as usize;
        let h = VIDEO_H as usize;
        let mut rgba = vec![0u8; w * h * 4];

        let peak = *self.inner.peak.lock().expect("peak");
        let bands = self.inner.bands.lock().expect("bands").clone();
        let wave: Vec<f32> = self.inner.wave.lock().expect("wave").iter().copied().collect();
        let title = self.inner.title.lock().expect("title").clone();
        let station = self.inner.station.lock().expect("station").clone();
        let t = elapsed.as_secs_f32();

        // Background gradient (deep purple → black), pulse with peak.
        let pulse = (0.15 + peak * 0.35).min(0.55);
        for y in 0..h {
            let fy = y as f32 / h as f32;
            for x in 0..w {
                let fx = x as f32 / w as f32;
                let i = (y * w + x) * 4;
                let r = ((20.0 + 40.0 * pulse) * (1.0 - fy) + 8.0 * (fx * 3.0 + t).sin().abs())
                    .clamp(0.0, 255.0) as u8;
                let g = ((8.0 + 20.0 * pulse) * (1.0 - fy)).clamp(0.0, 255.0) as u8;
                let b = ((40.0 + 80.0 * pulse) * (0.4 + 0.6 * (1.0 - fy))
                    + 15.0 * (fx * 2.0 - t * 0.5).sin().abs())
                .clamp(0.0, 255.0) as u8;
                rgba[i] = r;
                rgba[i + 1] = g;
                rgba[i + 2] = b;
                rgba[i + 3] = 255;
            }
        }

        // Spectrum bars (lower 55% of frame).
        let bar_top = (h as f32 * 0.42) as usize;
        let bar_bottom = (h as f32 * 0.88) as usize;
        let bar_area = bar_bottom.saturating_sub(bar_top).max(1);
        let n = bands.len().max(1);
        let gap = 2usize;
        let bar_w = ((w - gap * (n + 1)) / n).max(2);
        for (bi, &e) in bands.iter().enumerate() {
            let height = ((e.sqrt()) * bar_area as f32) as usize; // sqrt for visual balance
            let x0 = gap + bi * (bar_w + gap);
            let y0 = bar_bottom.saturating_sub(height);
            // Gradient teal → magenta by band.
            let hue = bi as f32 / n as f32;
            let (cr, cg, cb) = spectrum_color(hue, 0.55 + 0.45 * e);
            for y in y0..bar_bottom {
                let fade = 1.0 - (y - y0) as f32 / height.max(1) as f32;
                for x in x0..(x0 + bar_w).min(w) {
                    let i = (y * w + x) * 4;
                    let a = (0.35 + 0.65 * fade).clamp(0.0, 1.0);
                    rgba[i] = blend(rgba[i], cr, a);
                    rgba[i + 1] = blend(rgba[i + 1], cg, a);
                    rgba[i + 2] = blend(rgba[i + 2], cb, a);
                }
            }
        }

        // Waveform line across mid.
        if wave.len() >= 2 {
            let mid_y = (h as f32 * 0.35) as i32;
            let amp = (h as f32 * 0.12) * (0.4 + peak.min(1.0));
            let step = wave.len() as f32 / w as f32;
            for x in 0..w {
                let si = (x as f32 * step) as usize;
                let s = wave.get(si).copied().unwrap_or(0.0);
                let y = (mid_y as f32 - s * amp).round() as i32;
                let y = y.clamp(0, h as i32 - 1) as usize;
                // thick-ish stroke
                for dy in 0..2usize {
                    let yy = (y + dy).min(h - 1);
                    let i = (yy * w + x) * 4;
                    rgba[i] = 180;
                    rgba[i + 1] = 230;
                    rgba[i + 2] = 255;
                }
            }
        }

        // Header band
        fill_rect(&mut rgba, w, h, 0, 0, w, 52, 12, 10, 22, 220);
        // Station + title
        let header = if title.is_empty() {
            format!("eve radio  ·  {station}")
        } else {
            format!("{title}")
        };
        let sub = if title.is_empty() {
            "icy metadata pending…".to_string()
        } else {
            format!("eve radio  ·  {station}")
        };
        draw_text(&mut rgba, w, h, 16, 14, &header, 230, 235, 255, 2);
        draw_text(&mut rgba, w, h, 16, 34, &sub, 140, 160, 200, 1);

        // Peak meter right edge
        let meter_h = ((peak.min(1.0)) * (h as f32 * 0.5)) as usize;
        let mx = w - 14;
        for y in (h - 20 - meter_h)..(h - 20) {
            let i = (y * w + mx) * 4;
            let hot = (y as f32 / h as f32) < 0.35;
            rgba[i] = if hot { 255 } else { 80 };
            rgba[i + 1] = if hot { 80 } else { 220 };
            rgba[i + 2] = 120;
        }

        VideoFrame::new_rgba(
            Bytes::from(rgba),
            VIDEO_W,
            VIDEO_H,
            elapsed,
        )
    }

    /// Presentation slide: dark card, headline, wrapped body, footer.
    fn render_slide_frame(&self, elapsed: Duration) -> VideoFrame {
        let w = VIDEO_W as usize;
        let h = VIDEO_H as usize;
        let mut rgba = vec![0u8; w * h * 4];
        let t = elapsed.as_secs_f32();
        let headline = self.inner.slide_headline.lock().expect("slide_headline").clone();
        let body = self.inner.slide_body.lock().expect("slide_body").clone();
        let footer = self.inner.slide_footer.lock().expect("slide_footer").clone();

        // Deep slate gradient with slow color drift.
        for y in 0..h {
            let fy = y as f32 / h as f32;
            for x in 0..w {
                let fx = x as f32 / w as f32;
                let i = (y * w + x) * 4;
                let drift = (fx * 2.0 + t * 0.15).sin().abs() * 12.0;
                rgba[i] = (14.0 + 28.0 * (1.0 - fy) + drift * 0.4).clamp(0.0, 255.0) as u8;
                rgba[i + 1] = (10.0 + 18.0 * (1.0 - fy) + drift * 0.2).clamp(0.0, 255.0) as u8;
                rgba[i + 2] = (32.0 + 55.0 * (1.0 - fy) + drift).clamp(0.0, 255.0) as u8;
                rgba[i + 3] = 255;
            }
        }

        // Outer frame accent
        fill_rect(&mut rgba, w, h, 0, 0, w, 4, 90, 200, 255, 255);
        fill_rect(&mut rgba, w, h, 0, h - 4, w, 4, 90, 200, 255, 200);

        // Card panel
        let card_x = 28usize;
        let card_y = 36usize;
        let card_w = w.saturating_sub(56);
        let card_h = h.saturating_sub(72);
        fill_rect(
            &mut rgba, w, h, card_x, card_y, card_w, card_h, 18, 16, 36, 230,
        );
        // Accent bar under headline
        fill_rect(
            &mut rgba,
            w,
            h,
            card_x + 18,
            card_y + 46,
            card_w.saturating_sub(36),
            3,
            120,
            90,
            220,
            255,
        );

        // Brand chip
        draw_text(
            &mut rgba, w, h, card_x + 18, card_y + 12, "EVE  SLIDE", 160, 180, 230, 2,
        );

        // Headline (e.g. SLIDE 1/10)
        let head = if headline.is_empty() {
            "QUESTION".to_string()
        } else {
            headline.to_uppercase()
        };
        draw_text(
            &mut rgba,
            w,
            h,
            card_x + 18,
            card_y + 58,
            &head,
            240,
            245,
            255,
            2,
        );

        // Body — wrap to card width at scale 3 (glyph ~18px wide)
        let scale = 3usize;
        let char_w = 6 * scale;
        let max_chars = ((card_w.saturating_sub(40)) / char_w).max(8);
        let lines = wrap_text(&body, max_chars);
        let line_h = 7 * scale + 8;
        let mut y = card_y + 100;
        for line in lines.iter().take(7) {
            if y + line_h > card_y + card_h - 40 {
                break;
            }
            draw_text(
                &mut rgba, w, h, card_x + 22, y, line, 235, 240, 255, scale,
            );
            y += line_h;
        }

        // Footer strip
        fill_rect(
            &mut rgba,
            w,
            h,
            card_x,
            card_y + card_h.saturating_sub(34),
            card_w,
            34,
            10,
            12,
            24,
            240,
        );
        let foot = if footer.is_empty() {
            "answer in the freeq channel".to_string()
        } else {
            footer
        };
        draw_text(
            &mut rgba,
            w,
            h,
            card_x + 18,
            card_y + card_h.saturating_sub(22),
            &foot,
            150,
            200,
            255,
            2,
        );

        VideoFrame::new_rgba(Bytes::from(rgba), VIDEO_W, VIDEO_H, elapsed)
    }
}

/// Word-wrap `text` to lines of at most `max_chars` (ASCII-ish width).
fn wrap_text(text: &str, max_chars: usize) -> Vec<String> {
    let max_chars = max_chars.max(4);
    let mut lines = Vec::new();
    let mut cur = String::new();
    for word in text.split_whitespace() {
        if word.chars().count() > max_chars {
            if !cur.is_empty() {
                lines.push(std::mem::take(&mut cur));
            }
            let mut chunk = String::new();
            for ch in word.chars() {
                if chunk.chars().count() >= max_chars {
                    lines.push(std::mem::take(&mut chunk));
                }
                chunk.push(ch);
            }
            if !chunk.is_empty() {
                cur = chunk;
            }
            continue;
        }
        let next_len = cur.chars().count() + if cur.is_empty() { 0 } else { 1 } + word.chars().count();
        if !cur.is_empty() && next_len > max_chars {
            lines.push(std::mem::take(&mut cur));
        }
        if !cur.is_empty() {
            cur.push(' ');
        }
        cur.push_str(word);
    }
    if !cur.is_empty() {
        lines.push(cur);
    }
    if lines.is_empty() {
        lines.push(String::new());
    }
    lines
}

/// VideoSource the H.264 encoder pulls — latest rendered frame.
pub struct VizVideoSource {
    viz: RadioViz,
    frame_index: u64,
}

impl VideoSource for VizVideoSource {
    fn name(&self) -> &str {
        "eve-radio-viz"
    }
    fn format(&self) -> VideoFormat {
        VideoFormat {
            pixel_format: PixelFormat::Rgba,
            dimensions: [VIDEO_W, VIDEO_H],
        }
    }
    fn pop_frame(&mut self) -> Result<Option<VideoFrame>> {
        // Ensure renderer is running (start() may not be called first on all paths).
        self.viz.ensure_renderer();
        let frame = self.viz.inner.latest.lock().expect("latest").take();
        if frame.is_some() {
            self.frame_index += 1;
        }
        Ok(frame)
    }
    fn start(&mut self) -> Result<()> {
        self.viz.ensure_renderer();
        Ok(())
    }
    fn stop(&mut self) -> Result<()> {
        // Do not kill the shared RadioViz — MoQ reconnects create a new
        // VideoSource handle and keep feeding the same renderer.
        Ok(())
    }
}

pub(crate) fn blend(dst: u8, src: u8, a: f32) -> u8 {
    ((dst as f32) * (1.0 - a) + (src as f32) * a).round() as u8
}

fn spectrum_color(hue: f32, v: f32) -> (u8, u8, u8) {
    // Rough HSV→RGB: H in [0,1] teal→violet.
    let h = 0.55 + hue * 0.35;
    let s = 0.75;
    let c = v * s;
    let x = c * (1.0 - ((h * 6.0) % 2.0 - 1.0).abs());
    let m = v - c;
    let (r, g, b) = match (h * 6.0) as u32 {
        0 => (c, x, 0.0),
        1 => (x, c, 0.0),
        2 => (0.0, c, x),
        3 => (0.0, x, c),
        4 => (x, 0.0, c),
        _ => (c, 0.0, x),
    };
    (
        ((r + m) * 255.0) as u8,
        ((g + m) * 255.0) as u8,
        ((b + m) * 255.0) as u8,
    )
}

pub(crate) fn fill_rect(
    rgba: &mut [u8],
    w: usize,
    h: usize,
    x0: usize,
    y0: usize,
    rw: usize,
    rh: usize,
    r: u8,
    g: u8,
    b: u8,
    a: u8,
) {
    let x1 = (x0 + rw).min(w);
    let y1 = (y0 + rh).min(h);
    let af = a as f32 / 255.0;
    for y in y0..y1 {
        for x in x0..x1 {
            let i = (y * w + x) * 4;
            rgba[i] = blend(rgba[i], r, af);
            rgba[i + 1] = blend(rgba[i + 1], g, af);
            rgba[i + 2] = blend(rgba[i + 2], b, af);
        }
    }
}

// Minimal 5×7 font for A–Z a–z 0–9 and punctuation (bitmap rows, 5 bits used).
pub(crate) fn glyph(c: char) -> [u8; 7] {
    match c {
        'A' | 'a' => [0x0E, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11],
        'B' | 'b' => [0x1E, 0x11, 0x11, 0x1E, 0x11, 0x11, 0x1E],
        'C' | 'c' => [0x0E, 0x11, 0x10, 0x10, 0x10, 0x11, 0x0E],
        'D' | 'd' => [0x1E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x1E],
        'E' | 'e' => [0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x1F],
        'F' | 'f' => [0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x10],
        'G' | 'g' => [0x0E, 0x11, 0x10, 0x17, 0x11, 0x11, 0x0E],
        'H' | 'h' => [0x11, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11],
        'I' | 'i' => [0x0E, 0x04, 0x04, 0x04, 0x04, 0x04, 0x0E],
        'J' | 'j' => [0x01, 0x01, 0x01, 0x01, 0x11, 0x11, 0x0E],
        'K' | 'k' => [0x11, 0x12, 0x14, 0x18, 0x14, 0x12, 0x11],
        'L' | 'l' => [0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x1F],
        'M' | 'm' => [0x11, 0x1B, 0x15, 0x15, 0x11, 0x11, 0x11],
        'N' | 'n' => [0x11, 0x19, 0x15, 0x13, 0x11, 0x11, 0x11],
        'O' | 'o' => [0x0E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E],
        'P' | 'p' => [0x1E, 0x11, 0x11, 0x1E, 0x10, 0x10, 0x10],
        'Q' | 'q' => [0x0E, 0x11, 0x11, 0x11, 0x15, 0x12, 0x0D],
        'R' | 'r' => [0x1E, 0x11, 0x11, 0x1E, 0x14, 0x12, 0x11],
        'S' | 's' => [0x0E, 0x11, 0x10, 0x0E, 0x01, 0x11, 0x0E],
        'T' | 't' => [0x1F, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04],
        'U' | 'u' => [0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E],
        'V' | 'v' => [0x11, 0x11, 0x11, 0x11, 0x11, 0x0A, 0x04],
        'W' | 'w' => [0x11, 0x11, 0x11, 0x15, 0x15, 0x1B, 0x11],
        'X' | 'x' => [0x11, 0x11, 0x0A, 0x04, 0x0A, 0x11, 0x11],
        'Y' | 'y' => [0x11, 0x11, 0x0A, 0x04, 0x04, 0x04, 0x04],
        'Z' | 'z' => [0x1F, 0x01, 0x02, 0x04, 0x08, 0x10, 0x1F],
        '0' => [0x0E, 0x11, 0x13, 0x15, 0x19, 0x11, 0x0E],
        '1' => [0x04, 0x0C, 0x04, 0x04, 0x04, 0x04, 0x0E],
        '2' => [0x0E, 0x11, 0x01, 0x06, 0x08, 0x10, 0x1F],
        '3' => [0x1F, 0x01, 0x02, 0x06, 0x01, 0x11, 0x0E],
        '4' => [0x02, 0x06, 0x0A, 0x12, 0x1F, 0x02, 0x02],
        '5' => [0x1F, 0x10, 0x1E, 0x01, 0x01, 0x11, 0x0E],
        '6' => [0x06, 0x08, 0x10, 0x1E, 0x11, 0x11, 0x0E],
        '7' => [0x1F, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08],
        '8' => [0x0E, 0x11, 0x11, 0x0E, 0x11, 0x11, 0x0E],
        '9' => [0x0E, 0x11, 0x11, 0x0F, 0x01, 0x02, 0x0C],
        ' ' => [0; 7],
        '-' => [0x00, 0x00, 0x00, 0x1F, 0x00, 0x00, 0x00],
        '.' => [0x00, 0x00, 0x00, 0x00, 0x00, 0x0C, 0x0C],
        ',' => [0x00, 0x00, 0x00, 0x00, 0x0C, 0x04, 0x08],
        ':' => [0x00, 0x0C, 0x0C, 0x00, 0x0C, 0x0C, 0x00],
        '\'' => [0x0C, 0x0C, 0x08, 0x00, 0x00, 0x00, 0x00],
        '"' => [0x1B, 0x1B, 0x00, 0x00, 0x00, 0x00, 0x00],
        '/' => [0x01, 0x02, 0x04, 0x04, 0x08, 0x10, 0x10],
        '(' => [0x04, 0x08, 0x10, 0x10, 0x10, 0x08, 0x04],
        ')' => [0x08, 0x04, 0x02, 0x02, 0x02, 0x04, 0x08],
        '&' => [0x0C, 0x12, 0x14, 0x08, 0x15, 0x12, 0x0D],
        '+' => [0x00, 0x04, 0x04, 0x1F, 0x04, 0x04, 0x00],
        '·' | '•' => [0x00, 0x00, 0x0C, 0x0C, 0x00, 0x00, 0x00],
        _ => [0x1F, 0x11, 0x11, 0x11, 0x11, 0x11, 0x1F], // box for unknown
    }
}

pub(crate) fn draw_text(
    rgba: &mut [u8],
    w: usize,
    h: usize,
    x0: usize,
    y0: usize,
    text: &str,
    r: u8,
    g: u8,
    b: u8,
    scale: usize,
) {
    let scale = scale.max(1);
    let mut x = x0;
    for ch in text.chars().take(48) {
        let rows = glyph(ch);
        for (row, bits) in rows.iter().enumerate() {
            for col in 0..5 {
                if bits & (1 << (4 - col)) != 0 {
                    for dy in 0..scale {
                        for dx in 0..scale {
                            let px = x + col * scale + dx;
                            let py = y0 + row * scale + dy;
                            if px < w && py < h {
                                let i = (py * w + px) * 4;
                                rgba[i] = r;
                                rgba[i + 1] = g;
                                rgba[i + 2] = b;
                            }
                        }
                    }
                }
            }
        }
        x += 6 * scale;
        if x + 6 * scale >= w {
            break;
        }
    }
}
