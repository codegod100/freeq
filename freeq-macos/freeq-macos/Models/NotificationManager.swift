import Foundation
import UserNotifications
import AppKit

/// Owns the macOS user-notification lifecycle: permission, delivery gating,
/// and interaction handling (click-to-focus + inline reply).
///
/// Delivery gating (the rule the old inline `sendNotification` lacked): a
/// notification only fires when the message is one the user can't already
/// see — i.e. the app is inactive, OR its target channel/DM isn't the one
/// on screen. A frontmost app showing #general never bells for #general.
///
/// The `freeq.notificationsEnabled` toggle is honored here (it was
/// previously dead — declared in Settings, read nowhere).
///
/// NOTE: reliable delivery needs a stably-signed bundle. Ad-hoc/unsigned
/// dev builds may have `requestAuthorization`/`add` silently no-op; that's
/// an environment limitation, not a code path issue (see
/// docs/DEVELOPER-ACCOUNT-TODO.md).
///
/// Not `@MainActor`-annotated: its mutating callers (`AppState.handleEvent`,
/// `configure` from init) already run on the main thread, and the system
/// delegate callbacks hop to the main actor explicitly for any AppState
/// access. AppKit calls here (`NSApp`, dock tile) therefore always land on
/// main.
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    /// Category id carrying the inline text-reply action.
    private static let replyCategory = "freeq.message"
    /// userInfo key holding the buffer (channel or DM nick) to route to.
    private static let targetKey = "freeq.target"

    private override init() { super.init() }

    /// Register the delegate + reply category and request permission. Call
    /// once at launch, before any notification is posted.
    func configure() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let reply = UNTextInputNotificationAction(
            identifier: "freeq.reply",
            title: "Reply",
            options: [],
            textInputButtonTitle: "Send",
            textInputPlaceholder: "Message"
        )
        let category = UNNotificationCategory(
            identifier: Self.replyCategory,
            actions: [reply],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// Whether a message for `target` should raise a notification right now.
    /// False when notifications are disabled, or when the user is already
    /// looking at that buffer in the frontmost app.
    func shouldNotify(target: String) -> Bool {
        guard UserDefaults.standard.object(forKey: "freeq.notificationsEnabled") == nil
            || UserDefaults.standard.bool(forKey: "freeq.notificationsEnabled") else {
            return false
        }
        let appActive = NSApp.isActive
        let viewing = AppState.current?.activeChannel?.lowercased() == target.lowercased()
        // On screen AND focused → the user sees it; don't interrupt.
        return !(appActive && viewing)
    }

    /// Post a message notification for `target`, subject to `shouldNotify`.
    /// `replyable` attaches the inline-reply action (channels + DMs both
    /// route replies back through `AppState.sendMessage`).
    ///
    /// `timeSensitive` marks DMs and mentions so they can pierce a Focus /
    /// Do-Not-Disturb the user has allowed freeq to break through; regular
    /// channel traffic stays `.active` and is silenced by Focus like any
    /// ordinary app. Messages from one target share a `threadIdentifier`, so
    /// Notification Center groups them instead of stacking N separate banners.
    func notifyMessage(
        target: String,
        title: String,
        body: String,
        replyable: Bool = true,
        timeSensitive: Bool = false
    ) {
        guard shouldNotify(target: target) else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = [Self.targetKey: target]
        content.threadIdentifier = target.lowercased()
        content.interruptionLevel = timeSensitive ? .timeSensitive : .active
        if replyable {
            content.categoryIdentifier = Self.replyCategory
        }
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// Post a non-message event notification (call started, kicked, etc.).
    /// Clicking routes to `target` if one is given. Not gated by
    /// `shouldNotify`'s focus rule beyond the enabled toggle + suppression
    /// when the app is active and already showing that target — these are
    /// events the user generally wants even in the foreground, so they use
    /// `.timeSensitive` and always present.
    func notifyEvent(
        title: String,
        body: String,
        target: String? = nil,
        threadId: String = "freeq.events",
        timeSensitive: Bool = true
    ) {
        guard UserDefaults.standard.object(forKey: "freeq.notificationsEnabled") == nil
            || UserDefaults.standard.bool(forKey: "freeq.notificationsEnabled") else {
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = threadId
        content.interruptionLevel = timeSensitive ? .timeSensitive : .active
        if let target { content.userInfo = [Self.targetKey: target] }
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// Bounce the dock icon once — used for mentions/DMs while the app is
    /// in the background. `.informationalRequest` bounces once; the OS
    /// upgrades to `.criticalRequest` semantics only if we asked for it.
    func requestAttentionIfBackground() {
        if !NSApp.isActive {
            NSApp.requestUserAttention(.informationalRequest)
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Show banners/sounds even while the app is frontmost — `shouldNotify`
    /// already decided this notification is worth surfacing (the target
    /// isn't the focused buffer), so respect that here rather than letting
    /// macOS suppress it for an active app.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// Click a notification → focus the app and switch to its buffer.
    /// Use the inline reply action → send the typed text to the buffer.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let target = userInfo[Self.targetKey] as? String
        let replyText = (response as? UNTextInputNotificationResponse)?.userText

        Task { @MainActor in
            guard let state = AppState.current, let target else {
                completionHandler(); return
            }
            if let replyText, !replyText.trimmingCharacters(in: .whitespaces).isEmpty {
                state.sendMessage(to: target, text: replyText)
            } else {
                // Plain click/open: bring the window forward and focus buffer.
                NSApp.activate(ignoringOtherApps: true)
                for window in NSApp.windows where window.canBecomeMain {
                    window.makeKeyAndOrderFront(nil)
                    break
                }
                state.activeChannel = target
            }
            completionHandler()
        }
    }
}
