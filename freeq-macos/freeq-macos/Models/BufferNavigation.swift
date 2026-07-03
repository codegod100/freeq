import Foundation

/// Sidebar-order buffer navigation for ⌥↑/⌥↓ (prev/next channel) and
/// ⌥⇧↑/⌥⇧↓ (prev/next unread). Pure so the wrap/skip rules are testable.
enum BufferNavigation {
    enum Direction {
        case previous
        case next
    }

    /// The order the sidebar draws: favorite channels, remaining channels,
    /// then DMs (caller passes DMs already sorted by activity).
    static func sidebarOrder(
        channels: [String],
        favorites: Set<String>,
        dms: [String]
    ) -> [String] {
        let favs = channels.filter { favorites.contains($0.lowercased()) }
        let rest = channels.filter { !favorites.contains($0.lowercased()) }
        return favs + rest + dms
    }

    /// The buffer to activate next. Wraps around the list. With an
    /// `isUnread` predicate, skips read buffers (and the current one);
    /// returns nil when nothing qualifies.
    static func target(
        from current: String?,
        order: [String],
        direction: Direction,
        isUnread: ((String) -> Bool)? = nil
    ) -> String? {
        guard !order.isEmpty else { return nil }
        let count = order.count
        let step = direction == .next ? 1 : -1
        let currentIdx = current.flatMap { c in
            order.firstIndex { $0.lowercased() == c.lowercased() }
        }
        // Unknown current buffer: enter the list from the matching end.
        let anchor = currentIdx ?? (direction == .next ? -1 : count)

        for offset in 1...count {
            let i = (((anchor + step * offset) % count) + count) % count
            let name = order[i]
            if let isUnread {
                if name.lowercased() != current?.lowercased(), isUnread(name) {
                    return name
                }
            } else if name.lowercased() != current?.lowercased() {
                return name
            }
        }
        return nil
    }
}
