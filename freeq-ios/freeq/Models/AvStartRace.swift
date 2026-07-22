import Foundation

/// What to do when an `av-state=started` broadcast arrives.
/// iOS port of the macOS helper — same semantics, unit-tested.
enum AvStartedResolution: Equatable {
    /// (Re)join this session id — we were trying to start, so converge on
    /// whatever session actually won the race.
    case joinSession(String)
    /// A peer started a call we're not part of — surface a join nudge.
    case notifyPeerStarted
    /// Our own echo with nothing pending — no action.
    case ignore
}

/// Resolve an incoming `av-state=started`.
///
/// The subtle case is a **concurrent av-start race**: two people hit "join" at
/// the same instant, both see no existing session, and both send `av-start`.
/// The server allows one session per channel — one wins, the loser gets only a
/// `NOTICE`. Joining only when `actor == self` leaves the loser (still
/// `pendingStart`, but seeing the *winner's* nick as actor) wedged outside the
/// call — "we could never see/hear each other; rejoining sometimes fixed it."
///
/// Fix: if we were trying to start this channel's call at all, converge on the
/// winning session regardless of who created it. Join is idempotent for the
/// actual creator.
func resolveAvStarted(pendingStart: Bool, actorIsSelf: Bool, sessionId: String) -> AvStartedResolution {
    if pendingStart { return .joinSession(sessionId) }
    if !actorIsSelf { return .notifyPeerStarted }
    return .ignore
}

/// What to do when a `+freeq.at/av-error` TAGMSG arrives (the server's
/// machine-readable AV failure signal).
enum AvErrorResolution: Equatable {
    /// Our av-join was REJECTED (session ended/full) but we already set up
    /// call state and media optimistically — tear it down (we're not in the
    /// roster; peers will never subscribe to us) and re-discover the
    /// channel's real session.
    case teardownAndRediscover
    /// Our av-start lost a concurrent race; join the winning session.
    case joinSession(String)
    /// Error for a session we're not involved with — no action.
    case ignore
}

/// Resolve an incoming `+freeq.at/av-error`.
///
/// This closes the biggest "ghost caller" hole: the client dials the SFU and
/// flips its in-call UI BEFORE the av-join round-trips (fast setup), so a
/// rejected join used to leave it publishing media into a session the server
/// never admitted it to — in-call UI, roster absence, nobody hears them.
/// The join failure only came back as a human NOTICE that no code parsed.
func resolveAvError(
    code: String,
    errorSessionId: String,
    currentCallSessionId: String?,
    pendingStart: Bool
) -> AvErrorResolution {
    switch code {
    case "join-failed":
        if let current = currentCallSessionId,
           errorSessionId.isEmpty || errorSessionId == current {
            return .teardownAndRediscover
        }
        return .ignore
    case "start-collision":
        if pendingStart && !errorSessionId.isEmpty {
            return .joinSession(errorSessionId)
        }
        return .ignore
    default:
        return .ignore
    }
}
