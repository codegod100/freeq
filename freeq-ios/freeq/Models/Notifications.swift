import UserNotifications
import UIKit

/// Handles local notification permissions, categories, and delivery.
/// Permission is deferred until the first mention/DM to avoid a reflexive "Block".
class NotificationManager {
    static let shared = NotificationManager()

    // Category ids carry the inline actions the delegate handles.
    static let channelCategory = "channel_message"
    static let dmCategory = "dm_message"

    /// Register notification categories (inline reply + mark-as-read). Call
    /// once at launch. Idempotent.
    func registerCategories() {
        let reply = UNTextInputNotificationAction(
            identifier: "freeq.reply",
            title: "Reply",
            options: [],
            textInputButtonTitle: "Send",
            textInputPlaceholder: "Message"
        )
        let markRead = UNNotificationAction(
            identifier: "freeq.markread",
            title: "Mark as Read",
            options: []
        )
        let channel = UNNotificationCategory(
            identifier: Self.channelCategory,
            actions: [reply, markRead],
            intentIdentifiers: [],
            options: []
        )
        let dm = UNNotificationCategory(
            identifier: Self.dmCategory,
            actions: [reply, markRead],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([channel, dm])
    }

    /// Request notification permission (idempotent — only asks once).
    func requestPermissionIfNeeded() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func sendMessageNotification(from: String, text: String, channel: String, isMention: Bool = false) {
        let content = UNMutableNotificationContent()
        if channel.hasPrefix("#") {
            content.title = channel
            content.subtitle = from
        } else {
            content.title = from
        }
        content.body = text
        content.sound = isMention ? .defaultCritical : .default
        // Mentions and DMs are time-sensitive so an allowed Focus can let them
        // through; regular channel traffic stays passive.
        let isDM = !channel.hasPrefix("#")
        content.interruptionLevel = (isMention || isDM) ? .timeSensitive : .active
        // Group by channel/DM so Notification Center collapses a burst.
        content.threadIdentifier = channel
        content.categoryIdentifier = isDM ? Self.dmCategory : Self.channelCategory
        content.userInfo = ["channel": channel, "from": from]
        content.summaryArgument = isDM ? from : channel

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        deliver(request)
    }

    /// Deliver a request, resolving the first-mention permission race: if
    /// authorization hasn't been decided yet, request it and add the request
    /// on grant — previously the first mention was dropped because the async
    /// `requestAuthorization` hadn't returned when we synchronously checked a
    /// cached `authorized` flag. Foreground vs. focused-channel suppression is
    /// handled by the `willPresent` delegate, NOT here (dropping the request
    /// here was what made that delegate dead code).
    private func deliver(_ request: UNNotificationRequest) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                center.add(request)
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                    if granted { center.add(request) }
                }
            case .denied:
                break
            @unknown default:
                break
            }
        }
    }

    func clearBadge() {
        UNUserNotificationCenter.current().setBadgeCount(0)
    }
}
