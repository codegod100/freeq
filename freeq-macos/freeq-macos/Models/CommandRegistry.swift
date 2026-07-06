import Foundation

/// One user-facing action. The registry is the single source of truth that
/// the menu bar, the ⌘K palette, tooltips, and (later) App Intents all
/// project from — four hand-synced action lists would drift; one registry
/// cannot. Pure data: execution and key bindings live in the app layer
/// (CommandActions), keeping this SwiftPM-testable.
struct AppCommand: Identifiable, Equatable, Hashable {
    let id: String
    let title: String
    let category: String
    /// Display form, e.g. "⌥⇧↓" — the actual KeyboardShortcut lives with
    /// the action map in the app layer.
    let shortcutLabel: String?
    /// Extra match terms for the palette ("dm", "mute", …).
    let keywords: [String]

    init(_ id: String, _ title: String, category: String,
         shortcut: String? = nil, keywords: [String] = []) {
        self.id = id
        self.title = title
        self.category = category
        self.shortcutLabel = shortcut
        self.keywords = keywords
    }
}

enum CommandRegistry {
    static let navigation = "Navigation"
    static let view = "View"
    static let call = "Call"
    static let presence = "Presence"
    static let channel = "Channel"
    static let help = "Help"

    static let all: [AppCommand] = [
        // Navigation
        AppCommand("nav.quickSwitcher", "Quick Switcher", category: navigation,
                   shortcut: "⌘K", keywords: ["palette", "jump", "switch"]),
        AppCommand("nav.search", "Search Messages", category: navigation,
                   shortcut: "⌘F", keywords: ["find"]),
        AppCommand("nav.bookmarks", "Bookmarks", category: navigation,
                   shortcut: "⇧⌘B", keywords: ["saved"]),
        AppCommand("nav.browseChannels", "Browse Channels", category: navigation,
                   shortcut: "⇧⌘L", keywords: ["list", "discover"]),
        AppCommand("nav.joinChannel", "Join Channel…", category: navigation,
                   shortcut: "⌘J", keywords: ["add"]),
        AppCommand("nav.newDM", "New Direct Message…", category: navigation,
                   shortcut: "⌘N", keywords: ["dm", "message", "pm", "whisper", "person"]),
        AppCommand("nav.prevChannel", "Previous Channel", category: navigation,
                   shortcut: "⌥↑", keywords: ["up"]),
        AppCommand("nav.nextChannel", "Next Channel", category: navigation,
                   shortcut: "⌥↓", keywords: ["down"]),
        AppCommand("nav.prevUnread", "Previous Unread Channel", category: navigation,
                   shortcut: "⌥⇧↑", keywords: ["unread"]),
        AppCommand("nav.nextUnread", "Next Unread Channel", category: navigation,
                   shortcut: "⌥⇧↓", keywords: ["unread"]),

        // View
        AppCommand("view.toggleDetail", "Toggle Detail Panel", category: view,
                   shortcut: "⇧⌘D", keywords: ["members", "inspector", "sidebar"]),

        // Call
        AppCommand("call.toggleMute", "Toggle Mute", category: call,
                   shortcut: "⇧⌘M", keywords: ["microphone", "unmute"]),
        AppCommand("call.toggleCamera", "Toggle Camera", category: call,
                   shortcut: "⇧⌘V", keywords: ["video"]),
        AppCommand("call.toggleScreen", "Share Screen", category: call,
                   shortcut: "⇧⌘S", keywords: ["screenshare", "present"]),
        AppCommand("call.toggleExpand", "Expand Call", category: call,
                   shortcut: "⇧⌘E", keywords: ["grid", "collapse"]),
        AppCommand("call.leave", "Leave Call", category: call,
                   shortcut: "⇧⌘H", keywords: ["hangup", "end"]),

        // Presence
        AppCommand("presence.toggleAway", "Toggle Away", category: presence,
                   keywords: ["afk", "status", "back"]),

        // Channel (acts on the active buffer)
        AppCommand("channel.toggleFavorite", "Toggle Favorite for Channel", category: channel,
                   keywords: ["star", "pin"]),
        AppCommand("channel.toggleMute", "Toggle Mute for Channel", category: channel,
                   keywords: ["silence", "notifications"]),
        AppCommand("channel.leave", "Leave Channel", category: channel,
                   keywords: ["part", "close"]),

        // Help
        AppCommand("help.shortcuts", "Keyboard Shortcuts & Features", category: help,
                   shortcut: "⌘/", keywords: ["help", "keys", "cheatsheet", "guide"]),
    ]

    static func command(_ id: String) -> AppCommand? {
        all.first { $0.id == id }
    }

    static func category(_ name: String) -> [AppCommand] {
        all.filter { $0.category == name }
    }
}

/// Fuzzy matcher for the palette. Ranking: title prefix > word-boundary
/// prefix > keyword prefix > subsequence. Ties keep registry order.
enum CommandMatcher {
    static func rank(query: String, in commands: [AppCommand]) -> [AppCommand] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        return commands
            .compactMap { cmd -> (AppCommand, Int)? in
                guard let s = score(query: q, command: cmd) else { return nil }
                return (cmd, s)
            }
            .enumerated()
            .sorted { a, b in
                a.element.1 != b.element.1
                    ? a.element.1 > b.element.1
                    : a.offset < b.offset
            }
            .map { $0.element.0 }
    }

    static func score(query q: String, command: AppCommand) -> Int? {
        let title = command.title.lowercased()
        if title.hasPrefix(q) { return 100 }
        // Word-boundary prefix ("mute" matches "Toggle Mute").
        let words = title.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if words.contains(where: { $0.hasPrefix(q) }) { return 80 }
        if command.keywords.contains(where: { $0.lowercased().hasPrefix(q) }) { return 60 }
        if isSubsequence(q, of: title) { return 30 }
        return nil
    }

    /// Every character of `needle` appears in order within `haystack`.
    static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var it = needle.startIndex
        for ch in haystack {
            if it == needle.endIndex { return true }
            if ch == needle[it] { it = needle.index(after: it) }
        }
        return it == needle.endIndex
    }
}
