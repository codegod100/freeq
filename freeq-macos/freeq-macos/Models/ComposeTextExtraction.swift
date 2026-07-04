import Foundation

/// Normalizes composer text before it enters the send pipeline. Writing Tools
/// rewrites produce ordinary text (handled transparently), but an inserted
/// Genmoji reads back as U+FFFC (object-replacement char) in the plain string
/// — until there's an adaptive-image-glyph wire format across the server and
/// all clients, strip those placeholders so a message never carries a stray
/// box character.
enum ComposeTextExtraction {
    static let objectReplacement: Character = "\u{FFFC}"

    static func sendable(_ raw: String) -> String {
        guard raw.contains(objectReplacement) else { return raw }
        return String(raw.filter { $0 != objectReplacement })
    }
}
