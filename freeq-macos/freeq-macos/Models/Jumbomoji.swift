import Foundation

/// Jumbomoji: a message that is nothing but 1–3 emoji renders large. Shared
/// policy with the web + iOS clients so every client agrees on what's "jumbo".
/// Pure/Foundation → unit-testable.
enum Jumbomoji {
    /// Font point size for a jumbo message, or nil if it isn't one.
    /// 1 emoji → 48, 2 → 40, 3 → 34. Anything with letters/numbers/punctuation,
    /// or more than 3 emoji, is a normal message.
    static func size(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var count = 0
        for ch in trimmed {
            if ch.isWhitespace { continue }       // spaces between emoji are fine
            guard ch.isEmojiGrapheme else { return nil }
            count += 1
            if count > 3 { return nil }
        }
        switch count {
        case 1: return 48
        case 2: return 40
        case 3: return 34
        default: return nil
        }
    }

    static func isJumbomoji(_ text: String) -> Bool { size(text) != nil }
}

private extension Character {
    /// True for an emoji grapheme (single-scalar emoji with emoji presentation,
    /// or any multi-scalar cluster like ZWJ sequences, skin tones, flags).
    /// Excludes ASCII digits/`#`/`*` which carry `isEmoji` but aren't rendered
    /// as emoji on their own.
    var isEmojiGrapheme: Bool {
        guard let first = unicodeScalars.first else { return false }
        if unicodeScalars.count > 1 {
            return unicodeScalars.contains { $0.properties.isEmoji }
        }
        return first.properties.isEmojiPresentation
    }
}
