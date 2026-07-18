import SwiftUI

/// App-layer half of the Command registry: key bindings, availability, and
/// execution against AppState. The menu bar and the ⌘K palette both call
/// through here, so an action can never exist in one and not the other.
@MainActor
enum CommandActions {
    static func keyboardShortcut(_ id: String) -> KeyboardShortcut? {
        switch id {
        case "nav.quickSwitcher": return .init("k", modifiers: .command)
        case "nav.search": return .init("f", modifiers: .command)
        case "nav.bookmarks": return .init("b", modifiers: [.command, .shift])
        case "nav.browseChannels": return .init("l", modifiers: [.command, .shift])
        case "nav.joinChannel": return .init("j", modifiers: .command)
        case "nav.newDM": return .init("n", modifiers: .command)
        case "nav.prevChannel": return .init(.upArrow, modifiers: .option)
        case "nav.nextChannel": return .init(.downArrow, modifiers: .option)
        case "nav.prevUnread": return .init(.upArrow, modifiers: [.option, .shift])
        case "nav.nextUnread": return .init(.downArrow, modifiers: [.option, .shift])
        case "view.toggleDetail": return .init("d", modifiers: [.command, .shift])
        case "call.toggleMute": return .init("m", modifiers: [.command, .shift])
        case "call.toggleCamera": return .init("v", modifiers: [.command, .shift])
        case "call.toggleScreen": return .init("s", modifiers: [.command, .shift])
        case "call.toggleExpand": return .init("e", modifiers: [.command, .shift])
        case "call.leave": return .init("h", modifiers: [.command, .shift])
        case "help.shortcuts": return .init("/", modifiers: .command)
        default: return nil
        }
    }

    static func isEnabled(_ id: String, _ app: AppState) -> Bool {
        switch id {
        case let cmd where cmd.hasPrefix("call."):
            return app.isInCall
        case "channel.toggleFavorite", "channel.toggleMute", "channel.leave":
            return app.activeChannel?.hasPrefix("#") == true
        case "presence.toggleAway":
            return app.connectionState == .registered
        default:
            return true
        }
    }

    /// Dynamic titles where state matters ("Mute" vs "Unmute").
    static func title(_ id: String, _ app: AppState) -> String {
        switch id {
        case "call.toggleMute": return app.isMuted ? "Unmute" : "Mute"
        case "call.toggleCamera": return app.isCameraOn ? "Stop Camera" : "Start Camera"
        case "call.toggleScreen": return app.isScreenSharing ? "Stop Sharing Screen" : "Share Screen"
        case "call.toggleExpand": return app.isCallExpanded ? "Collapse Call" : "Expand Call"
        case "presence.toggleAway": return app.selfAwayReason == nil ? "Set Away" : "Remove Away"
        case "channel.toggleFavorite":
            guard let ch = app.activeChannel else { return "Favorite Channel" }
            return app.favorites.contains(ch.lowercased()) ? "Unfavorite \(ch)" : "Favorite \(ch)"
        case "channel.toggleMute":
            guard let ch = app.activeChannel else { return "Mute Channel" }
            return app.mutedChannels.contains(ch.lowercased()) ? "Unmute \(ch)" : "Mute \(ch)"
        case "channel.leave":
            return app.activeChannel.map { "Leave \($0)" } ?? "Leave Channel"
        default:
            return CommandRegistry.command(id)?.title ?? id
        }
    }

    static func run(_ id: String, _ app: AppState) {
        switch id {
        case "nav.quickSwitcher": app.showQuickSwitcher = true
        case "nav.search": app.showSearch.toggle()
        case "nav.bookmarks": app.showBookmarks = true
        case "nav.browseChannels": app.showChannelList = true
        case "nav.joinChannel": app.showJoinSheet = true
        case "nav.newDM": app.showNewDM = true
        case "nav.prevChannel": app.switchToAdjacentChannel(.previous)
        case "nav.nextChannel": app.switchToAdjacentChannel(.next)
        case "nav.prevUnread": app.switchToAdjacentChannel(.previous, unreadOnly: true)
        case "nav.nextUnread": app.switchToAdjacentChannel(.next, unreadOnly: true)
        case "view.toggleDetail": app.showDetailPanel.toggle()
        case "call.toggleMute": app.toggleMute()
        case "call.toggleCamera": app.toggleCamera()
        case "call.toggleScreen": app.toggleScreenShare()
        case "call.toggleExpand": app.isCallExpanded.toggle()
        case "call.leave": app.leaveCall()
        case "presence.toggleAway": app.setAway(app.selfAwayReason == nil ? "AFK" : nil)
        case "channel.toggleFavorite": app.activeChannel.map { app.toggleFavorite($0) }
        case "channel.toggleMute": app.activeChannel.map { app.toggleMuted($0) }
        case "channel.leave": app.activeChannel.map { app.partChannel($0) }
        case "help.shortcuts": app.showHelp = true
        default: break
        }
    }
}
