import CoreSpotlight
import SwiftUI

/// Delegate to handle notification taps and navigate to the right channel.
class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    weak var appState: AppState?

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let channel = response.notification.request.content.userInfo["channel"] as? String {
            DispatchQueue.main.async { [weak self] in
                guard let state = self?.appState else { return }
                if channel.hasPrefix("#") {
                    state.activeChannel = channel
                } else {
                    state.pendingDMNick = channel
                }
            }
        }
        completionHandler()
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
                    PhoneWatchBridge.shared.attach(appState)
                }
                .onChange(of: appState.channels.count) { PhoneWatchBridge.shared.push() }
                .onChange(of: appState.dmBuffers.count) { PhoneWatchBridge.shared.push() }
                .onChange(of: appState.connectionState) { PhoneWatchBridge.shared.push() }
                .onOpenURL { url in
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
        }
        .onChange(of: scenePhase) { _, newPhase in
            appState.handleScenePhase(newPhase)
        }
    }

}
