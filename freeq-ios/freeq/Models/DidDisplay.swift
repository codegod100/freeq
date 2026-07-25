import Foundation

/// DID display + DM-thread identity helpers — the iOS port of the shared
/// model (web identity.ts, Android DidDisplay.kt, macOS DidDisplay.swift).
///
/// DM buffers are keyed by the SDK's `dm_key` — the peer's DID when known,
/// else their nick — so one person is one thread. These helpers keep a raw
/// `did:plc:…` / `did:key:…` key from ever being *rendered* (resolve to a
/// human name where possible, compact the DID as a last resort) and fold a
/// nick-keyed thread into its DID-keyed one once the binding is learned.
/// Binding logic for our OWN echoed DMs. The server echoes a sent DM back with
/// the wire `target` = the recipient's nick and `dm_key` = their canonical DID
/// (when resolved). Without adopting that binding, a thread the sender opened
/// by nick and the DID-keyed thread the echo lands in stay split — so the
/// sender never sees their own message. Pure + unit-tested. Mirrors macOS.
enum DmEcho {
    static func recipientBinding(isSelf: Bool, target: String, dmKey: String?) -> (nick: String, did: String)? {
        guard isSelf,
              let did = dmKey, DidDisplay.isDid(did),
              !target.hasPrefix("#"), !target.hasPrefix("&"),
              !DidDisplay.isDid(target),
              target.caseInsensitiveCompare(did) != .orderedSame
        else { return nil }
        return (target, did)
    }
}

enum DidDisplay {

    /// A syntactic DID: `did:<method>:<id>` with a non-empty alphanumeric
    /// method and non-empty id. No network, no id validation.
    static func isDid(_ s: String) -> Bool {
        let parts = s.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].lowercased() == "did",
              !parts[1].isEmpty, !parts[2].isEmpty,
              parts[1].allSatisfy({ $0.isLetter || $0.isNumber })
        else { return false }
        return true
    }

    /// Compact a DID for display: `did:plc:k2n3e2vsihf3farequ44t5j7` →
    /// `plc:k2n3…t5j7`. Non-DIDs pass through unchanged.
    static func shorten(_ s: String) -> String {
        guard isDid(s) else { return s }
        let parts = s.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        let method = parts[1]
        let id = parts[2]
        guard id.count > 12 else { return "\(method):\(id)" }
        return "\(method):\(id.prefix(4))…\(id.suffix(4))"
    }

    /// Human name for a thread key or identifier that may be a raw DID: the
    /// display binding (DID → nick), then a caller-supplied reverse resolver
    /// (e.g. AvatarCache's DID → nick map), then the compacted DID. Plain
    /// nicks pass through unchanged.
    static func displayName(
        key: String,
        bindings: [String: String],
        reverseNick: (String) -> String? = { _ in nil }
    ) -> String {
        guard isDid(key) else { return key }
        if let nick = bindings[key] { return nick }
        if let nick = reverseNick(key) { return nick }
        return shorten(key)
    }

    /// Fold a nick-keyed DM buffer into the DID-keyed one after the peer's
    /// DID is learned (a cold first DM keys by nick until then — without the
    /// merge, one person becomes two threads; an OFFLINE peer never emits a
    /// live MemberDid, so the conversation list's partner-did calls this
    /// too). Messages dedupe by id and stay time-ordered via
    /// `ChannelState.appendIfNew`; unread counts carry over (iOS keys its
    /// unread map by the buffer's exact name). Returns true when a merge
    /// happened — the caller repoints active-thread state from `nick` to
    /// `did`.
    @discardableResult
    static func mergeDmBuffers(
        dmBuffers: inout [ChannelState],
        unreadCounts: inout [String: Int],
        nick: String,
        did: String
    ) -> Bool {
        guard isDid(did),
              !nick.hasPrefix("#"), !nick.hasPrefix("&"),
              nick.caseInsensitiveCompare(did) != .orderedSame,
              let nickIdx = dmBuffers.firstIndex(where: { $0.name.lowercased() == nick.lowercased() })
        else { return false }
        let nickBuf = dmBuffers[nickIdx]

        if let didBuf = dmBuffers.first(where: { $0.name == did }) {
            for m in nickBuf.messages { didBuf.appendIfNew(m) }
            if nickBuf.lastActivity > didBuf.lastActivity {
                didBuf.lastActivity = nickBuf.lastActivity
            }
            dmBuffers.remove(at: nickIdx)
        } else {
            // Only the nick thread exists → re-key it. `ChannelState.name` is
            // immutable, so rebuild under the DID; adoptMessages carries the
            // transcript with its dedup set and index intact.
            let rekeyed = ChannelState(name: did)
            rekeyed.adoptMessages(from: nickBuf)
            rekeyed.members = nickBuf.members
            rekeyed.topic = nickBuf.topic
            rekeyed.pins = nickBuf.pins
            rekeyed.lastActivity = nickBuf.lastActivity
            dmBuffers[nickIdx] = rekeyed
        }

        // Unread carry — iOS keys unreadCounts by the exact buffer name.
        if let moved = unreadCounts.removeValue(forKey: nickBuf.name) {
            unreadCounts[did, default: 0] += moved
        }
        return true
    }
}
