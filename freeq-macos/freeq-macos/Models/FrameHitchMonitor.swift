import Foundation

/// Main-thread stall monitor for the message-list architecture spike.
///
/// A 120Hz heartbeat timer on the main runloop: when layout/render work
/// stalls the main thread, the beat fires late, and the lateness is the
/// stall duration a user would feel as a hitch. (CVDisplayLink would be
/// wrong here — it ticks on the display's clock even while the app hangs.)
final class FrameHitchMonitor {
    static let shared = FrameHitchMonitor()

    private var timer: Timer?
    private var lastBeat: CFAbsoluteTime = 0
    private var samples = 0
    private var stalls: [Double] = []
    private var startedAt: CFAbsoluteTime = 0

    /// Intervals above this are counted as user-visible hitches
    /// (2+ dropped frames at 60Hz).
    private let hitchThreshold = 0.034

    func start() {
        stop(report: false)
        samples = 0
        stalls = []
        startedAt = CFAbsoluteTimeGetCurrent()
        lastBeat = startedAt
        let t = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = CFAbsoluteTimeGetCurrent()
            let interval = now - self.lastBeat
            self.lastBeat = now
            self.samples += 1
            if interval > self.hitchThreshold {
                self.stalls.append(interval)
            }
        }
        t.tolerance = 0
        RunLoop.main.add(t, forMode: .common)
        timer = t
        NSLog("[hitch] monitoring started")
    }

    func stop(report: Bool = true) {
        timer?.invalidate()
        timer = nil
        guard report, samples > 0 else { return }
        let elapsed = CFAbsoluteTimeGetCurrent() - startedAt
        let worst = (stalls.max() ?? 0) * 1000
        let totalStall = stalls.reduce(0, +) * 1000
        let hitchRatio = elapsed > 0 ? (stalls.reduce(0, +) / elapsed) * 100 : 0
        NSLog(String(
            format: "[hitch] SUMMARY elapsed=%.1fs beats=%d stalls>34ms=%d worst=%.0fms totalStall=%.0fms hitchTime=%.2f%%",
            elapsed, samples, stalls.count, worst, totalStall, hitchRatio))
    }
}
