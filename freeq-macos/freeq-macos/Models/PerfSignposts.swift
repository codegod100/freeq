import Foundation
import os

/// os_signpost instrumentation for the perf receipts the plan calls for
/// (§11 / §7.5 — "receipts are our own numbers"). Signposts are effectively
/// free when Instruments isn't recording, so these can live on the hot paths
/// permanently. Open Instruments → os_signpost to see connect time, history
/// load, send latency, and call-start intervals.
enum Perf {
    static let subsystem = "at.freeq.macos"
    static let signposter = OSSignposter(subsystem: subsystem, category: "perf")

    /// Begin a named interval. Hold the returned token and pass it to `end`.
    @discardableResult
    static func begin(_ name: StaticString) -> OSSignpostIntervalState {
        let id = signposter.makeSignpostID()
        return signposter.beginInterval(name, id: id)
    }

    static func end(_ name: StaticString, _ state: OSSignpostIntervalState) {
        signposter.endInterval(name, state)
    }

    /// A one-shot event marker (no duration).
    static func event(_ name: StaticString) {
        signposter.emitEvent(name)
    }
}
