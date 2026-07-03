import Foundation

/// Shell-style input history for the compose bar: ⌘↑ walks back through
/// prior sends, ⌘↓ walks forward and finally restores the unsent draft.
struct ComposeHistory: Equatable {
    private(set) var entries: [String] = []
    private var cursor: Int?
    private var stashedDraft: String = ""
    var limit: Int = 100

    var isRecalling: Bool { cursor != nil }

    /// Record a sent line. Consecutive duplicates collapse; recall state resets.
    mutating func record(_ entry: String) {
        let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if entries.last != trimmed {
            entries.append(trimmed)
            if entries.count > limit {
                entries.removeFirst(entries.count - limit)
            }
        }
        cursor = nil
        stashedDraft = ""
    }

    /// Step to the previous (older) entry. The first step stashes the
    /// in-progress draft so ⌘↓ can restore it. Returns nil at the oldest
    /// entry (or with no history) — the caller leaves the text unchanged.
    mutating func recallPrevious(draft: String) -> String? {
        guard !entries.isEmpty else { return nil }
        if let c = cursor {
            guard c > 0 else { return nil }
            cursor = c - 1
            return entries[c - 1]
        }
        stashedDraft = draft
        cursor = entries.count - 1
        return entries[entries.count - 1]
    }

    /// Step to the next (newer) entry; walking past the newest restores the
    /// stashed draft and ends recall. Returns nil when not recalling.
    mutating func recallNext() -> String? {
        guard let c = cursor else { return nil }
        if c + 1 < entries.count {
            cursor = c + 1
            return entries[c + 1]
        }
        cursor = nil
        let draft = stashedDraft
        stashedDraft = ""
        return draft
    }

    mutating func cancelRecall() {
        cursor = nil
        stashedDraft = ""
    }
}
