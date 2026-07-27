//! Client scroll stickiness for full-snapshot remounts.
//!
//! Full remounts destroy the ScrolledWindow every View push. Pinning to the
//! live tail is the default. Leaving the tail requires a clear user scroll-up
//! (value drops while upper is stable). Content growth never clears stick.

use std::sync::atomic::{AtomicU64, Ordering};

/// Global generation so stale pin timeouts from a previous remount stop.
static PIN_GEN: AtomicU64 = AtomicU64::new(0);

pub fn bump_pin_gen() -> u64 {
    PIN_GEN.fetch_add(1, Ordering::SeqCst) + 1
}

pub fn current_pin_gen() -> u64 {
    PIN_GEN.load(Ordering::SeqCst)
}

/// Survives remounts; owned by [`crate::app::AppModel`].
#[derive(Debug, Clone)]
pub struct ScrollState {
    /// Following the live tail (default). Cleared only by user scroll-up.
    pub stick_to_bottom: bool,
    pub channel_key: String,
    /// Distance from bottom when reading history (px).
    pub offset_from_bottom: f64,
    pub last_upper: f64,
    pub last_value: f64,
}

impl Default for ScrollState {
    fn default() -> Self {
        Self {
            stick_to_bottom: true,
            channel_key: String::new(),
            offset_from_bottom: 0.0,
            last_upper: 0.0,
            last_value: 0.0,
        }
    }
}

impl ScrollState {
    pub fn on_channel_change(&mut self, key: &str) {
        if key != self.channel_key {
            self.channel_key = key.to_string();
            self.force_stick();
            self.last_upper = 0.0;
            self.last_value = 0.0;
        }
    }

    pub fn force_stick(&mut self) {
        self.stick_to_bottom = true;
        self.offset_from_bottom = 0.0;
    }

    /// User scrolled up: only when value drops and upper is not growing.
    pub fn note_user_scroll(&mut self, value: f64, upper: f64, page: f64) {
        if upper <= page + 1.0 {
            return;
        }
        let max = (upper - page).max(0.0);
        let dist = (max - value).max(0.0);

        // Content growth — keep stick, update geometry only.
        if self.last_upper > 1.0 && upper > self.last_upper + 4.0 {
            self.last_upper = upper;
            if self.stick_to_bottom {
                self.offset_from_bottom = 0.0;
                self.last_value = max;
            } else {
                self.offset_from_bottom = dist;
                self.last_value = value;
            }
            return;
        }

        // Near bottom → re-stick.
        if dist < 96.0 {
            self.stick_to_bottom = true;
            self.offset_from_bottom = 0.0;
            self.last_value = value;
            self.last_upper = upper;
            return;
        }

        // Clear stick only if value moved up the log while upper stable.
        if self.last_upper > 1.0
            && (upper - self.last_upper).abs() < 4.0
            && value + 24.0 < self.last_value
        {
            self.stick_to_bottom = false;
            self.offset_from_bottom = dist;
        }

        self.last_value = value;
        self.last_upper = upper;
    }
}
