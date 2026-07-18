import Foundation

/// Mic level meter + speaking detector. Pure math over PCM buffers so the
/// whole thing is unit-testable: callers feed f32 samples plus a monotonic
/// timestamp and get back a normalized level and a debounced speaking flag.
///
/// Speaking uses attack/release hysteresis: two consecutive above-threshold
/// buffers to turn on (a single transient like a keyboard click stays off),
/// then a hang time so inter-word pauses don't flicker the indicator.
struct AudioLevelMeter {
    /// Quietest representable level; also returned for empty/silent buffers.
    static let floorDb: Float = -100
    /// dBFS above which a buffer counts as voice.
    static let speakingThresholdDb: Float = -45
    /// Consecutive loud buffers required to enter speaking.
    static let attackBuffers = 2
    /// Seconds of quiet before speaking releases.
    static let releaseSeconds = 0.8
    /// Levels are normalized over this dynamic range (floor → 0 dBFS).
    static let displayRangeDb: Float = 60

    private var loudStreak = 0
    private var speaking = false
    private var lastLoudAt: Double = -.infinity

    struct Update: Equatable {
        /// 0…1, suitable for a meter bar (0 = ≤ -60 dBFS, 1 = full scale).
        let level: Float
        /// dBFS of the buffer's RMS, floored at `floorDb`.
        let db: Float
        let isSpeaking: Bool
    }

    /// Process one capture buffer. `time` is any monotonic clock in seconds.
    mutating func process(samples: [Float], at time: Double) -> Update {
        let db = Self.dbfs(of: samples)

        if db >= Self.speakingThresholdDb {
            loudStreak += 1
            if loudStreak >= Self.attackBuffers { speaking = true }
            if speaking { lastLoudAt = time }
        } else {
            loudStreak = 0
            if speaking && time - lastLoudAt > Self.releaseSeconds {
                speaking = false
            }
        }

        let level = max(0, min(1, (db + Self.displayRangeDb) / Self.displayRangeDb))
        return Update(level: level, db: db, isSpeaking: speaking)
    }

    static func dbfs(of samples: [Float]) -> Float {
        guard !samples.isEmpty else { return floorDb }
        var sum: Float = 0
        for s in samples { sum += s * s }
        let rms = (sum / Float(samples.count)).squareRoot()
        guard rms > 0 else { return floorDb }
        return max(floorDb, 20 * log10(rms))
    }
}
