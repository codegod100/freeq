import Foundation

/// A call we were in when the connection dropped, captured so a reconnect can
/// rejoin the *same* AV session with the *same* instance — reactivating the
/// server's grace-held slot in place (see the server's AV teardown grace)
/// rather than starting a fresh call. Peers keyed on the instance see the
/// media continue seamlessly across the blip.
public struct PendingCallRejoin: Equatable {
    public let channel: String
    public let sessionId: String
    public let instance: String
    public let disconnectedAt: Date

    public init(channel: String, sessionId: String, instance: String, disconnectedAt: Date) {
        self.channel = channel
        self.sessionId = sessionId
        self.instance = instance
        self.disconnectedAt = disconnectedAt
    }
}

/// Whether a just-joined channel should trigger an automatic call rejoin.
/// Rejoin only when we have a pending call for THIS channel and the drop was
/// recent enough that the server's AV grace window can't have expired — past
/// that the slot (or the whole session, if we were the sole participant) is
/// gone and a rejoin would just fail.
///
/// `window` mirrors the server's `AV_GRACE_SECS` (30s).
public func shouldRejoinCall(
    pending: PendingCallRejoin?,
    joinedChannel: String,
    now: Date,
    window: TimeInterval = 30
) -> Bool {
    guard let pending else { return false }
    guard pending.channel.lowercased() == joinedChannel.lowercased() else { return false }
    return now.timeIntervalSince(pending.disconnectedAt) < window
}
