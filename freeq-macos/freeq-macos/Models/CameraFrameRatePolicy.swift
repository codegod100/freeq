import CoreMedia

/// Picks a safe `activeVideoMinFrameDuration` for a capture device.
///
/// Setting a duration outside every supported frame-rate range makes
/// AVFoundation throw NSInvalidArgumentException — uncatchable from Swift,
/// so the app aborts (this crashed on cameras with fractional 29.97fps or
/// fixed-rate ranges, where truncating fps to an Int32 timescale produced
/// an out-of-range duration). Only ever return the desired duration when a
/// range provably contains it, else clamp to the range's own reported
/// CMTime bounds, which are valid by construction.
enum CameraFrameRatePolicy {
    /// The duration to set, or nil to leave the device untouched.
    /// `ranges` are (minFrameDuration, maxFrameDuration) pairs of the
    /// device's *active* format.
    static func targetMinFrameDuration(
        desiredFps: Int32,
        ranges: [(min: CMTime, max: CMTime)]
    ) -> CMTime? {
        guard desiredFps > 0, let first = ranges.first else { return nil }
        let desired = CMTime(value: 1, timescale: desiredFps)
        for range in ranges
        where CMTimeCompare(desired, range.min) >= 0
            && CMTimeCompare(desired, range.max) <= 0 {
            return desired
        }
        // Desired rate not representable: clamp to the nearest edge of the
        // first range (min = the device's fastest allowed, i.e. its native
        // fps cap; max = its slowest).
        return CMTimeCompare(desired, first.min) < 0 ? first.min : first.max
    }
}
