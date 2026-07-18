import AppKit
import SwiftUI

/// Minimal AppKit delegate for the two surfaces pure SwiftUI can't express:
/// the Dock right-click menu and a branded About panel. Everything else
/// stays SwiftUI-native (`App.swift`).
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Dock right-click menu: jump to the next unread channel, toggle away,
    /// and start/join a call in the active channel. Rebuilt each time the
    /// user right-clicks (menus are snapshots), so item titles/availability
    /// reflect current state.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard let app = AppState.current else { return nil }
        let menu = NSMenu()

        if app.totalUnread > 0 {
            let unread = NSMenuItem(
                title: "Next Unread (\(app.totalUnread))",
                action: #selector(nextUnread), keyEquivalent: ""
            )
            unread.target = self
            menu.addItem(unread)
            menu.addItem(.separator())
        }

        let away = NSMenuItem(
            title: app.selfAwayReason == nil ? "Set Away" : "Clear Away",
            action: #selector(toggleAway), keyEquivalent: ""
        )
        away.target = self
        menu.addItem(away)

        // Start or join a call in the channel currently on screen.
        if let channel = app.activeChannel, channel.hasPrefix("#"), !app.isInCall {
            let joinable = app.activeAvSessions[channel.lowercased()] != nil
            let call = NSMenuItem(
                title: joinable ? "Join Call in \(channel)" : "Start Call in \(channel)",
                action: #selector(startOrJoinCall), keyEquivalent: ""
            )
            call.target = self
            menu.addItem(call)
        }

        return menu
    }

    @objc private func nextUnread() {
        guard let app = AppState.current else { return }
        Self.activate()
        app.switchToAdjacentChannel(.next, unreadOnly: true)
    }

    @objc private func toggleAway() {
        guard let app = AppState.current else { return }
        app.setAway(app.selfAwayReason == nil ? "AFK" : nil)
    }

    @objc private func startOrJoinCall() {
        guard let app = AppState.current, let channel = app.activeChannel else { return }
        Self.activate()
        app.startOrJoinVoice(channel: channel)
    }

    /// Branded About panel using the (new dark-plate) app icon and the
    /// bundle's version/build.
    @objc func showAbout(_ sender: Any?) {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        let credits = NSAttributedString(
            string: "IRC with AT Protocol identity.\nSigned messages, credential-gated channels, "
                + "end-to-end encryption, and voice/video over QUIC.",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "freeq",
            .applicationVersion: "Version \(version) (\(build))",
            .credits: credits,
        ])
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func activate() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
            break
        }
    }
}
