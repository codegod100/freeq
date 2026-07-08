import Foundation

/// What to do when an `av-state=started` broadcast arrives.
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
/// `NOTICE`. The old logic joined only when `actor == self`, so the loser (who
/// is still `pendingStart` but sees the *winner's* nick as actor) fell through
/// to a notification and stayed wedged, never in the call — "we could never
/// see/hear each other; rejoining sometimes fixed it."
///
/// Fix: if we were trying to start this channel's call at all, converge on the
/// winning session regardless of who created it. We (re)join it; join is
/// idempotent for the actual creator.
func resolveAvStarted(pendingStart: Bool, actorIsSelf: Bool, sessionId: String) -> AvStartedResolution {
    if pendingStart { return .joinSession(sessionId) }
    if !actorIsSelf { return .notifyPeerStarted }
    return .ignore
}
