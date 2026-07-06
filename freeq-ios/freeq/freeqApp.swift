import CoreSpotlight
import SwiftUI

/// Handoff / Continuity activity types.
enum FreeqActivity {
    /// Advertised while viewing a channel/DM so it can resume on another device.
    static let channel = "at.freeq.channel"
}

/// Delegate to handle notification taps and navigate to the right channel.
class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    weak var appState: AppState?

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let channel = response.notification.request.content.userInfo["channel"] as? String
        let replyText = (response as? UNTextInputNotificationResponse)?.userText

        DispatchQueue.main.async { [weak self] in
            guard let state = self?.appState, let channel else { completionHandler(); return }
            switch response.actionIdentifier {
            case "freeq.reply":
                // Inline reply — send straight to the channel/DM without opening.
                if let replyText, !replyText.trimmingCharacters(in: .whitespaces).isEmpty {
                    _ = state.sendMessage(target: channel, text: replyText)
                }
            case "freeq.markread":
                state.markRead(channel)
            default:
                // Plain tap (or open) → route to the conversation.
                if channel.hasPrefix("#") {
                    state.activeChannel = channel
                } else {
                    state.pendingDMNick = channel
                }
            }
            completionHandler()
        }
    }

    // Show notifications even when app is in foreground (for non-active channels)
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let channel = notification.request.content.userInfo["channel"] as? String
        if channel != appState?.activeChannel {
            completionHandler([.banner, .sound])
        } else {
            completionHandler([])
        }
    }
}

@main
struct FreeqApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var networkMonitor = NetworkMonitor()
    @Environment(\.scenePhase) private var scenePhase
    private let notificationDelegate = NotificationDelegate()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environmentObject(networkMonitor)
                .onAppear {
                    networkMonitor.bind(to: appState)
                    notificationDelegate.appState = appState
                    UNUserNotificationCenter.current().delegate = notificationDelegate
                    NotificationManager.shared.registerCategories()
                    PhoneWatchBridge.shared.attach(appState)
                    // Automation hook (mirrors macOS FREEQ_TEST_NICK): auto-
                    // connect as a guest so simulator/CI runs can drive the
                    // signed-in UI without tapping through the login screen.
                    // Never fires in normal use — gated on the env var.
                    if let guest = ProcessInfo.processInfo.environment["FREEQ_TEST_GUEST"],
                       appState.connectionState == .disconnected {
                        appState.serverAddress = ServerConfig.ircServer
                        appState.connect(nick: guest.isEmpty ? "ipadverify" : guest)
                        // Optionally auto-open a channel once joined, so a
                        // verification/CI run lands inside a conversation with
                        // no dialogs. FREEQ_TEST_OPEN=#general.
                        if let open = ProcessInfo.processInfo.environment["FREEQ_TEST_OPEN"] {
                            func tryOpen(_ attempt: Int) {
                                guard attempt < 20 else { return }
                                if appState.channels.contains(where: { $0.name == open }) {
                                    appState.pendingChannelNav = open
                                } else {
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { tryOpen(attempt + 1) }
                                }
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { tryOpen(0) }
                        }
                    }
                }
                .onChange(of: appState.channels.count) { PhoneWatchBridge.shared.push() }
                .onChange(of: appState.dmBuffers.count) { PhoneWatchBridge.shared.push() }
                .onChange(of: appState.connectionState) { PhoneWatchBridge.shared.push() }
                .onOpenURL { url in
                    // Widget / deep-link routing: freeq://open?target=<channel|nick>.
                    if url.scheme == "freeq", url.host == "open" {
                        let target = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                            .queryItems?.first(where: { $0.name == "target" })?.value
                        if let target, !target.isEmpty {
                            if target.hasPrefix("#") || target.hasPrefix("&") {
                                appState.activeChannel = target
                            } else {
                                appState.pendingDMNick = target
                            }
                        }
                        return
                    }
                    appState.handleAuthCallback(url)
                }
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    // User tapped a freeq channel/DM in iOS Spotlight.
                    guard let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return }
                    if id.hasPrefix("#") || id.hasPrefix("&") {
                        appState.activeChannel = id
                    } else {
                        appState.pendingDMNick = id
                    }
                }
                .onContinueUserActivity(FreeqActivity.channel) { activity in
                    // Handoff from another device — resume the same conversation.
                    guard let target = activity.userInfo?["channel"] as? String else { return }
                    if target.hasPrefix("#") || target.hasPrefix("&") {
                        appState.activeChannel = target
                    } else {
                        appState.pendingDMNick = target
                    }
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            appState.handleScenePhase(newPhase)
        }
    }

}
