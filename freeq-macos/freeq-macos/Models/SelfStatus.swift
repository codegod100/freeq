import Foundation

/// Pure emoji + text composition for the custom-status editor. The status is
/// stored (and broadcast over IRC AWAY) as one "emoji text" string; the editor
/// presents the two halves separately.
enum SelfStatus {
    /// "emoji text" with empty/whitespace-only parts dropped.
    static func combined(emoji: String, text: String) -> String {
        [emoji.trimmingCharacters(in: .whitespaces), text.trimmingCharacters(in: .whitespaces)]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Split a saved "emoji text" status back into editor fields. Only a
    /// genuinely emoji-presenting first character is treated as the emoji —
    /// digits and letters (which Unicode marks isEmoji for keycap purposes)
    /// stay in the text.
    static func split(_ status: String) -> (emoji: String, text: String) {
        guard let first = status.first, isEmoji(first) else { return ("", status) }
        return (String(first), String(status.dropFirst()).trimmingCharacters(in: .whitespaces))
    }

    private static func isEmoji(_ ch: Character) -> Bool {
        guard let scalar = ch.unicodeScalars.first else { return false }
        return scalar.properties.isEmojiPresentation
            || (scalar.properties.isEmoji && scalar.value >= 0x1F000)
    }
}
