import Foundation

/// Classifies a server NOTICE as a channel access-denial (invite-only, +k bad
/// key, banned, auth required, full, …) so the client can surface *why* a join
/// failed instead of silently doing nothing. Pure/Foundation → unit-testable.
/// Mirrors the macOS `ServerNoticeRouter.channelAccessDenied` policy.
enum ChannelAccessNotice {
    /// The denial phrases the server uses in its NOTICE text. Kept in sync
    /// with the macOS router so both clients recognize the same messages.
    private static let denialPhrases = [
        "requires authentication",
        "cannot join",
        "invite",
        "banned",
        "bad channel key",
        "channel is full",
        "not authorized",
        "permission",
    ]

    /// Parse `#channel <reason>` denial notices. Returns nil for any notice
    /// that isn't a recognized channel access-denial.
    static func parse(_ text: String) -> (channel: String, reason: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2 else { return nil }
        let channel = String(parts[0])
        guard channel.hasPrefix("#") || channel.hasPrefix("&") else { return nil }
        let reason = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = reason.lowercased()
        guard denialPhrases.contains(where: { normalized.contains($0) }) else { return nil }
        return (channel, reason)
    }
}
