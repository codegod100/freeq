import Foundation

// Safety: blocking & reporting (ported from the iOS client).
// Pure decisions only — no UI, no UserDefaults. AppState owns persistence;
// the views own presentation. Testable under `swift test`.

/// Who/what is being reported. Carried into the reason picker.
struct ReportTarget: Identifiable, Equatable {
    let nick: String
    let did: String?
    var text: String? = nil
    var id: String { (did ?? nick) + (text ?? "") }
}

/// The standard report reasons, in presentation order.
let reportReasons = [
    "Spam or scam",
    "Harassment or hate",
    "Sexual or explicit content",
    "Violence or threats",
    "Impersonation",
    "Something else",
]

/// Pure block-list decisions. Blocked by DID when we have one (stable across
/// nick changes); by lowercased nick otherwise. Blocked people's messages are
/// hidden and their DMs suppressed.
struct BlockList: Equatable {
    private(set) var dids: Set<String>
    private(set) var nicks: Set<String>  // stored lowercased

    init(dids: Set<String> = [], nicks: Set<String> = []) {
        self.dids = dids
        self.nicks = Set(nicks.map { $0.lowercased() })
    }

    var isEmpty: Bool { dids.isEmpty && nicks.isEmpty }

    func isBlocked(nick: String, did: String? = nil) -> Bool {
        if let did, !did.isEmpty, dids.contains(did) { return true }
        return nicks.contains(nick.lowercased())
    }

    mutating func block(nick: String, did: String?) {
        if let did, !did.isEmpty { dids.insert(did) }
        nicks.insert(nick.lowercased())
    }

    mutating func unblock(nick: String?, did: String?) {
        if let did { dids.remove(did) }
        if let nick { nicks.remove(nick.lowercased()) }
    }

    /// The rows a message list may show: system lines (empty `from`) always
    /// pass; a blocked author's messages are hidden. `didFor` resolves
    /// nick → DID (the profile cache, in the app) so a nick change doesn't
    /// let a DID-blocked person back in.
    func visible(_ messages: [ChatMessage], didFor: (String) -> String?) -> [ChatMessage] {
        guard !isEmpty else { return messages }
        return messages.filter { m in
            m.from.isEmpty || !isBlocked(nick: m.from, did: didFor(m.from))
        }
    }
}
