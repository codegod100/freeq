import Foundation

/// Which nick to drop for an `av-state=left`. Prefer the per-device
/// instance (stable; matches the media path) over the actor nick, which
/// can differ for multi-nick accounts and miss.
///
/// The ghost-tile bug: a peer is added to the participant collections under
/// the *media-path* nick (e.g. the dot-stripped `chadfowlercom`), but the
/// server's fast `av-state=left` TAGMSG names the *actor* nick
/// (`chadfowler.com`). For a multi-nick account (same DID, two nicks) those
/// differ, so a nick-keyed removal misses and the tile lingers. Keying the
/// teardown on the stable per-device instance resolves back to the exact nick
/// the participant was added under.
///
/// - Returns: the mapped nick when `actorInstance` is present and known;
///   otherwise `actorNick` (legacy clients send no instance).
public func resolveAvLeftNick(
    instanceToNick: [String: String],
    actorNick: String,
    actorInstance: String?
) -> String? {
    if let instance = actorInstance, !instance.isEmpty,
       let mapped = instanceToNick[instance] {
        return mapped
    }
    return actorNick
}
