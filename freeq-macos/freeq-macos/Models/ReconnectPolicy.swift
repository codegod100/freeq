import Foundation

/// IRC reconnect pacing. Most disconnects happen with a healthy network
/// (server restart, idle timeout, brief blip), so the first retry is
/// near-instant; only sustained failure backs off, capped at 30s.
enum ReconnectPolicy {
    /// Seconds to wait before retry number `attempt` (1-based):
    /// 0.5, 2, 4, 8, 16, then 30 flat.
    static func delay(afterAttempt attempt: Int) -> TimeInterval {
        guard attempt > 1 else { return 0.5 }
        let exponent = min(attempt - 1, 5)
        return min(Double(1 << exponent), 30.0)
    }
}
