import Foundation

/// DID display + DM-thread identity helpers — the macOS port of the Android
/// reference implementation (DidDisplay.kt), same semantics as the web client
/// and the TUI.
///
/// DM buffers are keyed by the SDK's `dm_key` — the peer's DID when known,
/// else their nick — so one person is one thread. These helpers keep a raw
/// `did:plc:…` / `did:key:…` key from ever being *rendered* (resolve to a
/// human name where possible, compact the DID as a last resort) and fold a
/// nick-keyed thread into its DID-keyed one once the binding is learned.
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
    /// (e.g. ProfileCache's DID → nick map), then the compacted DID. Plain
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
    /// merge, one person becomes two threads). Messages dedupe by id and stay
    /// time-ordered via `ChannelState.appendIfNew`; unread and mention counts
    /// carry over (lowercased keys, matching AppState's maps). Returns true
    /// when a merge happened — the caller repoints any active-thread state
    /// from `nick` to `did` and migrates external stores (MessageStore).
    @discardableResult
    static func mergeDmBuffers(
        dmBuffers: inout [ChannelState],
        unreadCounts: inout [String: Int],
        mentionCounts: inout [String: Int],
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
            // immutable, so rebuild under the DID and carry the state over.
            let rekeyed = ChannelState(name: did)
            for m in nickBuf.messages { rekeyed.appendIfNew(m) }
            rekeyed.members = nickBuf.members
            rekeyed.topic = nickBuf.topic
            rekeyed.topicSetBy = nickBuf.topicSetBy
            rekeyed.lastActivity = nickBuf.lastActivity
            dmBuffers[nickIdx] = rekeyed
        }

        let nickKey = nick.lowercased()
        let didKey = did.lowercased()
        if let moved = unreadCounts.removeValue(forKey: nickKey) {
            unreadCounts[didKey, default: 0] += moved
        }
        if let moved = mentionCounts.removeValue(forKey: nickKey) {
            mentionCounts[didKey, default: 0] += moved
        }
        return true
    }
}
