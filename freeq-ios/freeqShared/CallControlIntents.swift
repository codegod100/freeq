// Interactive Live Activity controls. `LiveActivityIntent.perform()` runs in
// the APP's process (iOS launches it in the background if needed), so posting
// to NotificationCenter reaches the running AppState, which performs the
// actual mute/leave. iOS-only: LiveActivityIntent doesn't exist on watchOS,
// and freeqShared is also compiled into the watch target.
#if os(iOS)
import AppIntents
import Foundation

public extension Notification.Name {
    /// Posted by a Live Activity control intent; observed by AppState.
    static let freeqCallControl = Notification.Name("freeq.callControl")
}

public enum CallControlAction: String {
    case toggleMute
    case endCall
}

@available(iOS 17.0, *)
public struct ToggleMuteIntent: LiveActivityIntent {
    public static var title: LocalizedStringResource = "Toggle Mute"
    public init() {}
    public func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(
            name: .freeqCallControl, object: CallControlAction.toggleMute.rawValue)
        return .result()
    }
}

@available(iOS 17.0, *)
public struct EndCallIntent: LiveActivityIntent {
    public static var title: LocalizedStringResource = "End Call"
    public init() {}
    public func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(
            name: .freeqCallControl, object: CallControlAction.endCall.rawValue)
        return .result()
    }
}
#endif
