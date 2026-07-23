//! Broadcast-plane freeq tile: "ON THE AIR" slate (not a test pattern).
//!
//! stream-broadcast joins freeq only to run call-egress; the outbound mix is
//! RTMP. Peers in the freeq room still need a local tile — this is that slate.

use std::time::{Duration, Instant};

use anyhow::Result;
use bytes::Bytes;
use iroh_live::media::format::{PixelFormat, VideoFormat, VideoFrame};
use iroh_live::media::traits::VideoSource;

use crate::viz::{VIDEO_H, VIDEO_W, blend, draw_text, fill_rect};

const FPS: u64 = 15;

/// Static/animated "on the air" VideoSource for the broadcast plane.
pub struct OnAirSource {
    t0: Instant,
    frame_index: u64,
}

impl OnAirSource {
    pub fn new() -> Self {
        Self {
            t0: Instant::now(),
            frame_index: 0,
        }
    }

    fn render(&self, elapsed: Duration) -> VideoFrame {
        let w = VIDEO_W as usize;
        let h = VIDEO_H as usize;
        let mut rgba = vec![0u8; w * h * 4];
        let t = elapsed.as_secs_f32();

        // Deep near-black with subtle red ambient pulse.
        let pulse = 0.5 + 0.5 * (t * 2.2).sin();
        for y in 0..h {
            let fy = y as f32 / h as f32;
            for x in 0..w {
                let i = (y * w + x) * 4;
                rgba[i] = (12.0 + 28.0 * pulse * (1.0 - fy)).clamp(0.0, 255.0) as u8;
                rgba[i + 1] = 8;
                rgba[i + 2] = 12;
                rgba[i + 3] = 255;
            }
        }

        // Soft vignette
        let cx = w as f32 / 2.0;
        let cy = h as f32 / 2.0;
        for y in 0..h {
            for x in 0..w {
                let dx = (x as f32 - cx) / cx;
                let dy = (y as f32 - cy) / cy;
                let d = (dx * dx + dy * dy).sqrt().min(1.4) / 1.4;
                let a = d * 0.45;
                let i = (y * w + x) * 4;
                rgba[i] = blend(rgba[i], 0, a);
                rgba[i + 1] = blend(rgba[i + 1], 0, a);
                rgba[i + 2] = blend(rgba[i + 2], 0, a);
            }
        }

        // Red "ON AIR" pill in the center.
        let pill_w = 280usize;
        let pill_h = 72usize;
        let px = w.saturating_sub(pill_w) / 2;
        let py = h.saturating_sub(pill_h) / 2 - 24;
        let glow = (0.55 + 0.45 * pulse).clamp(0.0, 1.0);
        fill_rect(
            &mut rgba,
            w,
            h,
            px.saturating_sub(6),
            py.saturating_sub(6),
            pill_w + 12,
            pill_h + 12,
            (180.0 * glow) as u8,
            20,
            30,
            (40.0 + 50.0 * glow) as u8,
        );
        fill_rect(&mut rgba, w, h, px, py, pill_w, pill_h, 180, 24, 32, 240);

        // Recording dot (left of text)
        let dot_r = 10usize;
        let dx0 = px + 28;
        let dy0 = py + pill_h / 2;
        for yy in dy0.saturating_sub(dot_r)..=(dy0 + dot_r).min(h - 1) {
            for xx in dx0.saturating_sub(dot_r)..=(dx0 + dot_r).min(w - 1) {
                let ddx = xx as i32 - dx0 as i32;
                let ddy = yy as i32 - dy0 as i32;
                if ddx * ddx + ddy * ddy <= (dot_r * dot_r) as i32 {
                    let i = (yy * w + xx) * 4;
                    let hot = 0.7 + 0.3 * pulse;
                    rgba[i] = (255.0 * hot) as u8;
                    rgba[i + 1] = 40;
                    rgba[i + 2] = 40;
                    rgba[i + 3] = 255;
                }
            }
        }

        draw_text(
            &mut rgba,
            w,
            h,
            px + 56,
            py + 26,
            "ON THE AIR",
            255,
            245,
            245,
            3,
        );

        draw_text(
            &mut rgba,
            w,
            h,
            w.saturating_sub(320) / 2,
            py + pill_h + 28,
            "eve  ·  stream.place",
            160,
            150,
            160,
            2,
        );
        draw_text(
            &mut rgba,
            w,
            h,
            w.saturating_sub(380) / 2,
            py + pill_h + 52,
            "broadcasting the freeq call",
            110,
            100,
            115,
            1,
        );

        VideoFrame::new_rgba(Bytes::from(rgba), VIDEO_W, VIDEO_H, elapsed)
    }
}

impl Default for OnAirSource {
    fn default() -> Self {
        Self::new()
    }
}

impl VideoSource for OnAirSource {
    fn name(&self) -> &str {
        "eve-on-the-air"
    }
    fn format(&self) -> VideoFormat {
        VideoFormat {
            pixel_format: PixelFormat::Rgba,
            dimensions: [VIDEO_W, VIDEO_H],
        }
    }
    fn pop_frame(&mut self) -> Result<Option<VideoFrame>> {
        // Produce a frame every pull; encoder drives cadence.
        // Throttle slightly so we don't spin CPU if polled too fast.
        let elapsed = self.t0.elapsed();
        let target = Duration::from_millis(1000 / FPS);
        let due = Duration::from_millis(self.frame_index.saturating_mul(1000 / FPS));
        if elapsed + Duration::from_millis(2) < due {
            return Ok(None);
        }
        self.frame_index += 1;
        Ok(Some(self.render(elapsed)))
    }
    fn start(&mut self) -> Result<()> {
        self.t0 = Instant::now();
        self.frame_index = 0;
        Ok(())
    }
    fn stop(&mut self) -> Result<()> {
        Ok(())
    }
}
