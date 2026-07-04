import AppKit
import SwiftUI

/// Content of the always-present menu bar item. Makes freeq's "ambient
/// presence" real at the OS level: the call and unread state live in the
/// menu bar, and you can mute / leave / jump to a conversation without the
/// main window — closing the window no longer loses the call.
struct MenuBarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Group {
            statusHeader

            if appState.isInCall {
                Divider()
                callControls
            }

            Divider()
            unreadSection

            Divider()
            Button("Open freeq") { Self.activateMainWindow() }
            Button("Quick Switcher…") {
                Self.activateMainWindow()
                appState.showQuickSwitcher = true
            }
            .keyboardShortcut("k", modifiers: .command)

            if appState.connectionState == .registered {
                Button(appState.selfAwayReason == nil ? "Set Away" : "Clear Away") {
                    appState.setAway(appState.selfAwayReason == nil ? "AFK" : nil)
                }
            }

            Divider()
            Button("Quit freeq") { NSApp.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var statusHeader: some View {
        switch appState.connectionState {
        case .registered:
            Text(appState.selfAwayReason.map { "\(appState.nick) — away (\($0))" }
                ?? "\(appState.nick) — online")
        case .connected, .connecting:
            Text("Connecting…")
        case .disconnected:
            Text(appState.hasSavedSession ? "Reconnecting…" : "Signed out")
        }
    }

    @ViewBuilder
    private var callControls: some View {
        let channel = appState.currentCallChannel ?? "call"
        let others = appState.callParticipants.count
        Text("On a call in \(channel) · \(others + 1) here")

        Button(appState.isMuted ? "Unmute" : "Mute") {
            appState.toggleMute()
        }
        .keyboardShortcut("m", modifiers: [.command, .shift])

        Button(appState.isScreenSharing ? "Stop Sharing Screen" : "Share Screen") {
            Self.activateMainWindow()
            appState.toggleScreenShare()
        }

        Button("Leave Call") { appState.leaveCall() }
            .keyboardShortcut("h", modifiers: [.command, .shift])
    }

    @ViewBuilder
    private var unreadSection: some View {
        let unread = MenuBarModel.entries(
            unread: appState.unreadCounts,
            mentions: appState.mentionCounts,
            order: appState.channels.map(\.name) + appState.dmBuffers.map(\.name)
        )
        if unread.isEmpty {
            Text("No unread messages").foregroundStyle(.secondary)
        } else {
            let total = unread.reduce(0) { $0 + $1.count }
            Text("\(total) unread in \(unread.count) channel\(unread.count == 1 ? "" : "s")")
            ForEach(unread.prefix(8), id: \.name) { entry in
                Button {
                    Self.activateMainWindow()
                    appState.activeChannel = entry.name
                } label: {
                    Text("\(entry.mention ? "@ " : "")\(entry.name)  (\(entry.count))")
                }
            }
        }
    }

    /// Bring the main window forward (menu bar actions must un-hide + focus it).
    static func activateMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
            break
        }
    }
}

