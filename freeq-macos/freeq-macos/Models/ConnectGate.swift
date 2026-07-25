import Foundation

/// Single-flight gate for IRC connection attempts.
///
/// Every reconnect trigger funnels through `beginAttempt()`:
///   - the SDK `disconnected` event,
///   - system wake,
///   - app foregrounding,
///   - the scheduled-retry timer (`ReconnectPolicy`),
///   - launch/session restore.
///
/// Only ONE attempt may be in flight at a time, and none may start while a
/// live connection already exists. This is what stops the reconnect *storm*
/// that opened a fresh TCP socket every few hundred milliseconds — each new
/// socket stranding the previous (now half-open) one, which lingered
/// server-side as a duplicate session. That storm is the root of the
/// "my message never went through" report: the typed PRIVMSG sat unsent in a
/// dying connection's send buffer (observed as bytes stuck in `FIN_WAIT_1`)
/// while the UI was already bound to the next socket.
///
/// Pure value type so the concurrency policy is unit-testable without booting
/// the SDK or a live server.
struct ConnectGate: Equatable {
    /// An attempt (broker fetch → connect → IRC registration) is running.
    private(set) var inFlight: Bool = false
    /// A live/registered connection currently exists.
    private(set) var live: Bool = false

    init() {}

    /// Try to start a new connection attempt. Returns `true` only when idle:
    /// no attempt already in flight AND not already connected. On `true` the
    /// gate latches `inFlight` until `settle()` or `drop()` is called, so any
    /// concurrent trigger is suppressed.
    mutating func beginAttempt() -> Bool {
        if inFlight || live { return false }
        inFlight = true
        return true
    }

    /// The attempt reached a live connection (IRC `registered`). Ends the
    /// in-flight window and marks the connection live so further triggers are
    /// ignored until it drops.
    mutating func settle() {
        inFlight = false
        live = true
    }

    /// The connection dropped, or the attempt failed/aborted. Clears both
    /// flags so the very next trigger may reconnect — never leaves the gate
    /// latched (which would strand reconnection forever, the mirror-image of
    /// the storm bug).
    mutating func drop() {
        inFlight = false
        live = false
    }

    /// Whether a trigger would currently be suppressed.
    var isBusy: Bool { inFlight || live }
}
