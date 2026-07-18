import Foundation

/// Pure menu-bar view-model helpers (no AppKit) so the ranking + icon logic
/// is unit-testable independent of the SwiftUI view.
enum MenuBarModel {
    struct UnreadEntry: Equatable {
        let name: String
        let count: Int
        let mention: Bool
    }

    /// Unread targets (channels + DMs) with a positive count, mentions first,
    /// then by count descending, preserving the given order for ties.
    /// `unread`/`mentions` are keyed lowercase (as AppState stores them);
    /// `order` carries the display-cased names.
    static func entries(
        unread: [String: Int],
        mentions: [String: Int],
        order: [String]
    ) -> [UnreadEntry] {
        order.compactMap { name -> UnreadEntry? in
            let key = name.lowercased()
            let count = unread[key] ?? 0
            guard count > 0 else { return nil }
            return UnreadEntry(name: name, count: count, mention: (mentions[key] ?? 0) > 0)
        }
        .enumerated()
        .sorted { a, b in
            if a.element.mention != b.element.mention { return a.element.mention }
            if a.element.count != b.element.count { return a.element.count > b.element.count }
            return a.offset < b.offset  // stable: keep discovery order on ties
        }
        .map(\.element)
    }

    /// SF Symbol for the menu bar item, reflecting the most salient state.
    static func iconName(inCall: Bool, muted: Bool, unread: Bool, mention: Bool) -> String {
        if inCall { return muted ? "mic.slash.fill" : "waveform" }
        if mention { return "message.badge.filled.fill" }
        if unread { return "message.badge" }
        return "message"
    }
}
