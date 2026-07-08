import Foundation

/// Pure buffer-ordering + stepping logic for keyboard navigation (prev/next
/// channel, prev/next unread, jump-to-index). Kept free of SwiftUI/AppState so
/// it's unit-testable. Mirrors the sidebar order: favorites first (in favorite
/// order), then the remaining channels, then DMs.
enum BufferNavigation {
    /// The ordered list of buffer names as shown in the sidebar.
    static func sidebarOrder(channels: [String], favoriteOrder: [String], dms: [String]) -> [String] {
        let present = Set(channels).union(dms)
        let favs = favoriteOrder.filter { present.contains($0) }
        let favSet = Set(favs)
        let restChannels = channels.filter { !favSet.contains($0) }
        let restDms = dms.filter { !favSet.contains($0) }
        return favs + restChannels + restDms
    }

    /// The name to move to from `current`, stepping by `delta` (+1 next, -1
    /// prev) through `order`, wrapping around. When `unreadOnly` is set, only
    /// names in `unread` are landing spots (the nearest one in the step
    /// direction). Returns nil when there is nowhere to go.
    static func step(order: [String], current: String?, delta: Int,
                     unreadOnly: Bool = false, unread: Set<String> = []) -> String? {
        guard !order.isEmpty, delta != 0 else { return nil }
        let n = order.count

        if unreadOnly {
            let hasUnread = order.contains { unread.contains($0) }
            guard hasUnread else { return nil }
            var i = current.flatMap { order.firstIndex(of: $0) } ?? (delta > 0 ? -1 : 0)
            for _ in 0..<n {
                i = ((i + delta) % n + n) % n
                if unread.contains(order[i]), order[i] != current { return order[i] }
            }
            return nil
        }

        guard let cur = current, let curIdx = order.firstIndex(of: cur) else {
            return delta > 0 ? order.first : order.last
        }
        let next = ((curIdx + delta) % n + n) % n
        return next == curIdx ? nil : order[next]
    }

    /// The name at a 0-based index into the sidebar order (for ⌘1–9), or nil.
    static func atIndex(_ index: Int, order: [String]) -> String? {
        guard index >= 0, index < order.count else { return nil }
        return order[index]
    }
}
