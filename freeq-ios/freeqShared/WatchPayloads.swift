import Foundation

/// Compact representations the phone sends to the watch over WatchConnectivity.
/// Kept minimal so updateApplicationContext stays under the small payload cap
/// — bytes burn battery on the watch radio.

public struct WatchBufferSummary: Codable, Hashable, Identifiable {
    public var id: String { name }
    public let name: String          // buffer key: `#room`, peer nick, or peer DID
    /// Human name for DID-keyed DM buffers; nil when `name` is already human.
    public let displayName: String?
    public let unread: Int
    public let lastFrom: String?
    public let lastText: String?
    public let lastAt: Date?
    public let isChannel: Bool

    /// What the watch renders — never a raw DID.
    public var title: String { displayName ?? name }

    public init(name: String, displayName: String? = nil, unread: Int, lastFrom: String?,
                lastText: String?, lastAt: Date?, isChannel: Bool) {
        self.name = name
        self.displayName = displayName
        self.unread = unread
        self.lastFrom = lastFrom
        self.lastText = lastText
        self.lastAt = lastAt
        self.isChannel = isChannel
    }
}

public struct WatchMessage: Codable, Hashable, Identifiable {
    public var id: String { msgid }
    public let msgid: String
    public let from: String
    public let text: String
    public let at: Date

    public init(msgid: String, from: String, text: String, at: Date) {
        self.msgid = msgid
        self.from = from
        self.text = text
        self.at = at
    }
}

/// Top-level snapshot pushed on every meaningful state change.
public struct WatchSnapshot: Codable, Hashable {
    public let nick: String
    public let connected: Bool
    public let buffers: [WatchBufferSummary]
    /// Latest N messages per buffer, keyed by buffer name.
    public let recent: [String: [WatchMessage]]

    public init(nick: String, connected: Bool, buffers: [WatchBufferSummary], recent: [String: [WatchMessage]]) {
        self.nick = nick
        self.connected = connected
        self.buffers = buffers
        self.recent = recent
    }
}

/// Watch → phone: send a message via the phone's existing FreeqClient.
public struct WatchSendRequest: Codable, Hashable {
    public let target: String
    public let text: String

    public init(target: String, text: String) {
        self.target = target
        self.text = text
    }
}

/// WatchConnectivity message-key constants — single source of truth on both sides.
public enum WatchKeys {
    public static let snapshot = "freeq.snapshot"
    public static let sendRequest = "freeq.send"
}
