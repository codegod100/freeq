import Foundation

/// Restore the last-open conversation on launch. Reopens where you left off,
/// falling back to the first channel (then the first DM) when that target is
/// gone, so a left/renamed channel never lands you on nothing.
enum LastChannel {
    /// UserDefaults key for the persisted target name.
    static let key = "freeq.lastChannel"

    static func restore(saved: String?, channels: [String], dms: [String]) -> String? {
        if let saved {
            let match = (channels + dms).first { $0.caseInsensitiveCompare(saved) == .orderedSame }
            if let match { return match }
        }
        return channels.first ?? dms.first
    }
}

/// Which of the author's own actions the freeq server relays to OTHER members
/// but does NOT echo back to the author, so the author's client must apply the
/// effect locally (optimistically) or their own view never updates. TAGMSG
/// actions (delete, react) are skipped for the sender server-side; PRIVMSG
/// actions (plain message, edit) come back via the `echo-message` cap.
enum SelfActionEcho {
    enum Action: Equatable {
        case plainMessage
        case edit
        case delete
        case react
        case unreact
    }

    static func needsOptimisticLocalApply(_ action: Action) -> Bool {
        switch action {
        case .delete, .react, .unreact: true
        case .plainMessage, .edit: false
        }
    }
}

/// Pure decisions for author actions on messages — target resolution,
/// authorization, and search visibility — so AppState delegates instead of
/// duplicating them inline.
enum MessageActions {
    /// The message an author-initiated edit/delete with no explicit id should
    /// target: the author's most recent message that is neither deleted nor an
    /// action line (a tombstone must not be re-targeted; an action line carries
    /// no editable msgid).
    static func lastEditable(messages: [ChatMessage], nick: String) -> ChatMessage? {
        let me = nick.lowercased()
        return messages.last {
            $0.from.lowercased() == me && !$0.isDeleted && !$0.isAction
        }
    }

    /// Whether `nick` may delete `message`: the author always, an op anyone —
    /// but never an already-deleted message.
    static func canDelete(_ message: ChatMessage, by nick: String, isOp: Bool) -> Bool {
        guard !message.isDeleted else { return false }
        return isOp || message.from.lowercased() == nick.lowercased()
    }

    /// In-buffer search matches (text or sender contains the query), excluding
    /// deleted messages. Empty query matches nothing.
    static func searchMatches(_ messages: [ChatMessage], query: String) -> [ChatMessage] {
        let q = query.lowercased()
        guard !q.isEmpty else { return [] }
        return messages.filter {
            !$0.isDeleted && ($0.text.lowercased().contains(q) || $0.from.lowercased().contains(q))
        }
    }
}
