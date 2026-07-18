import Foundation

/// Small snapshot the main app writes and the widget extension reads, over a
/// shared App Group container. The App Group entitlement
/// (`group.at.freeq.ios`) must be provisioned for live data to cross the
/// process boundary; until then `UserDefaults(suiteName:)` returns nil and
/// the widget shows its placeholder. Nothing here traps if the group is
/// absent — it degrades to empty.
public enum SharedStore {
    public static let appGroup = "group.at.freeq.ios"
    private static let key = "widget.snapshot.v1"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroup)
    }

    /// One row in the widget's channel list.
    public struct ChannelUnread: Codable, Hashable, Identifiable {
        public var name: String
        public var unread: Int
        public var id: String { name }
        public init(name: String, unread: Int) {
            self.name = name
            self.unread = unread
        }
    }

    /// Everything the widgets render.
    public struct Snapshot: Codable, Hashable {
        public var totalUnread: Int
        public var topChannels: [ChannelUnread]
        public var connected: Bool
        public var updatedAt: Date

        public init(totalUnread: Int, topChannels: [ChannelUnread], connected: Bool, updatedAt: Date) {
            self.totalUnread = totalUnread
            self.topChannels = topChannels
            self.connected = connected
            self.updatedAt = updatedAt
        }

        public static let empty = Snapshot(totalUnread: 0, topChannels: [], connected: false, updatedAt: .distantPast)
    }

    /// Write the current snapshot (called from the app on unread changes).
    public static func write(_ snapshot: Snapshot) {
        guard let defaults, let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: key)
    }

    /// Read the latest snapshot (called from the widget timeline provider).
    public static func read() -> Snapshot {
        guard let defaults,
              let data = defaults.data(forKey: key),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            return .empty
        }
        return snap
    }
}
