#if canImport(ActivityKit)
import ActivityKit
#endif
import Foundation

/// Live Activity payload describing an in-progress AV call. Compiled into
/// both the main app (so AppState can start/update/end the activity) and
/// the freeqLiveActivity widget extension (so the widget can render it).
/// ActivityKit is iOS-only, so the watchOS target sees this file but not
/// the ActivityAttributes conformance.
#if canImport(ActivityKit)
public struct CallActivityAttributes: ActivityAttributes {
    /// Mutable state — pushed to ActivityKit on every update.
    public struct ContentState: Codable, Hashable {
        public var participantCount: Int
        public var isMuted: Bool
        /// Wall-clock start time, used for the call-duration ticker. Stored
        /// here (instead of `attributes`) so we can backfill it once we
        /// have a confirmed session id.
        public var startedAt: Date

        public init(participantCount: Int, isMuted: Bool, startedAt: Date) {
            self.participantCount = participantCount
            self.isMuted = isMuted
            self.startedAt = startedAt
        }
    }

    /// Immutable identity of the call. Channel is the IRC name (`#room`),
    /// `sessionId` is the AV session id from the server's `+freeq.at/av-id`
    /// TAGMSG so we can deep-link back to the right thing if the user
    /// taps the activity.
    public let channel: String
    public let sessionId: String

    public init(channel: String, sessionId: String) {
        self.channel = channel
        self.sessionId = sessionId
    }
}
#endif
