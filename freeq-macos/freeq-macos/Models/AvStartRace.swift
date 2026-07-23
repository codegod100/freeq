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

/// A media dial held until the server's `+freeq.at/av-token` arrives (or a
/// short fallback fires, for servers that don't mint tokens). Dialing AFTER
/// av-join is what lets the dial carry the token at all — the old
/// dial-then-join order could never be authenticated, which would have
/// broken every native call the day token enforcement turns on (audit F7).
struct PendingMediaDial: Equatable {
    let channel: String
    let sessionId: String
    let instance: String
}

/// The SFU dial URL. Always self-declares the per-call instance (`inst=`,
/// which keys server-side media revocation on roster teardown — audit F6)
/// and carries the per-session token when the server minted one.
func mediaDialUrl(base: String, instance: String, token: String?) -> String {
    var url = "\(base)?inst=\(instance)"
    if let token, !token.isEmpty {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let enc = token.addingPercentEncoding(withAllowedCharacters: allowed) ?? token
        url += "&jwt=\(enc)"
    }
    return url
}

/// Should an arriving `+freeq.at/av-token` trigger the held media dial?
/// Only when it names the session we're holding a dial for — a token for a
/// stale/other session must not dial into the wrong call.
func shouldDialOnToken(pending: PendingMediaDial?, tokenSessionId: String) -> Bool {
    guard let pending else { return false }
    return pending.sessionId == tokenSessionId
}

/// Should the tokenless fallback timer still dial? Only if the SAME dial is
/// still pending (token may have dialed already; the call may have been torn
/// down by av-error or leave; a new call may have replaced it).
func shouldDialOnFallback(pending: PendingMediaDial?, expected: PendingMediaDial) -> Bool {
    pending == expected
}

/// A roster row as returned by `GET /api/v1/sessions/{id}` (active only).
struct AvRosterEntry: Equatable {
    let nick: String
    let instance: String?
}

/// Rebuild the visible participant strip from the server roster (audit F9:
/// av-state TAGMSGs are missed while out of the channel, so the strip can go
/// stale — media is announcement-driven and unaffected; this is display).
/// Excludes SELF by instance when both sides have one (nick fallback for
/// legacy rows), dedupes case-insensitively, and preserves roster order.
func reconcileCallParticipants(
    roster: [AvRosterEntry],
    myNick: String,
    myInstance: String?
) -> [String] {
    var seen = Set<String>()
    var out: [String] = []
    for entry in roster {
        let isSelf: Bool
        if let mi = myInstance, let ei = entry.instance, !ei.isEmpty {
            isSelf = ei == mi
        } else {
            isSelf = entry.nick.caseInsensitiveCompare(myNick) == .orderedSame
        }
        if isSelf { continue }
        let key = entry.nick.lowercased()
        if seen.insert(key).inserted {
            out.append(entry.nick)
        }
    }
    return out
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
        // Matches the call we think we're in (or the error has no id and we
        // have a call up from an optimistic join) → tear down the ghost.
        if let current = currentCallSessionId,
           errorSessionId.isEmpty || errorSessionId == current {
            return .teardownAndRediscover
        }
        return .ignore
    case "start-collision":
        // Only meaningful while we were trying to start; the tag names the
        // session that won.
        if pendingStart && !errorSessionId.isEmpty {
            return .joinSession(errorSessionId)
        }
        return .ignore
    default:
        return .ignore
    }
}
