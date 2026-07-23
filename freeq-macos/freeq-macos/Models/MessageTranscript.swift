import Foundation

/// Builds clean, paste-friendly plain text from a run of chat messages.
///
/// The point is to be the opposite of what Slack/Discord drop on the
/// pasteboard: no avatars rendered as blank lines, no "(edited)" noise, no
/// reaction tallies, no per-message timestamp clutter unless asked. Just
/// `Name: message`, one logical message per entry, multi-line bodies
/// preserved — the thing you actually want when you paste a conversation into
/// notes, an issue, or a doc.
///
/// Pure so the formatting policy is unit-testable without the AppKit list or a
/// live profile cache.
enum MessageTranscript {

    struct Options: Equatable {
        /// Prefix each message with its local time, e.g. `Name [3:41 PM]: …`.
        var includeTimestamps: Bool = false
        /// Skip join/part/quit/reconnect lines (empty author) — presence noise.
        var skipSystem: Bool = true
        /// Skip deleted tombstones.
        var skipDeleted: Bool = true
        var timeStyle: DateFormatter.Style = .short
        init() {}
    }

    /// Render `messages` (already in display order) as plain text.
    ///
    /// - Parameters:
    ///   - messages: the selected messages, in chronological/display order.
    ///   - options: what to include/skip.
    ///   - displayName: resolves an author's wire nick to the name shown in the
    ///     UI (profile display name); defaults to the nick itself.
    static func plainText(
        _ messages: [ChatMessage],
        options: Options = Options(),
        displayName: (String) -> String = { $0 }
    ) -> String {
        let df = DateFormatter()
        df.dateStyle = .none
        df.timeStyle = options.timeStyle

        var lines: [String] = []
        for m in messages {
            if options.skipDeleted && m.isDeleted { continue }

            // System/presence line (no author).
            if m.from.isEmpty {
                if options.skipSystem { continue }
                lines.append(m.text)
                continue
            }

            let name = displayName(m.from)
            let stamp = options.includeTimestamps
                ? " [\(df.string(from: m.timestamp))]"
                : ""
            if m.isAction {
                // Emote: "* Name waves"
                lines.append("*\(stamp) \(name) \(m.text)")
            } else {
                lines.append("\(name)\(stamp): \(m.text)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
