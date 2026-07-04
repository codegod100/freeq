import SwiftUI

/// Inline rich text for message bodies rendered outside the main transcript —
/// thread replies, pinned rows, search results — which previously showed raw
/// `Text` with no formatting or tappable links.
///
/// Renders freeq's markdown subset (**bold**, *italic*, `code`, ~~strike~~,
/// [links](url)) plus bare-URL autolinking via SwiftUI's own markdown parser,
/// so these surfaces match the transcript instead of looking broken. Falls
/// back to plain text if parsing ever fails — never blank, never a crash.
struct MarkdownText: View {
    let raw: String
    var lineLimit: Int? = nil

    var body: some View {
        Text(attributed)
            .tint(Theme.accent)
            .lineLimit(lineLimit)
            .textSelection(.enabled)
    }

    private var attributed: AttributedString {
        // Autolink bare URLs first so "see example.com" becomes tappable, then
        // let the markdown parser handle emphasis/code/explicit links.
        let linked = Self.autolink(raw)
        var opts = AttributedString.MarkdownParsingOptions()
        opts.interpretedSyntax = .inlineOnlyPreservingWhitespace
        opts.failurePolicy = .returnPartiallyParsedIfPossible
        if var s = try? AttributedString(markdown: linked, options: opts) {
            // Tint any parsed links with the accent for a consistent affordance.
            for run in s.runs where run.link != nil {
                s[run.range].foregroundColor = Theme.accent
            }
            return s
        }
        return AttributedString(raw)
    }

    /// Wrap bare http(s) URLs in markdown link syntax so the parser makes them
    /// tappable. Already-linked `[text](url)` spans are left untouched.
    static func autolink(_ text: String) -> String {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return text
        }
        let ns = text as NSString
        let matches = detector.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var result = ""
        var cursor = 0
        for m in matches {
            guard let url = m.url else { continue }
            let r = m.range
            // Skip URLs already inside a markdown link "](...)".
            let precededByParen = r.location > 0 && ns.substring(with: NSRange(location: r.location - 1, length: 1)) == "("
            result += ns.substring(with: NSRange(location: cursor, length: r.location - cursor))
            let shown = ns.substring(with: r)
            if precededByParen {
                result += shown
            } else {
                result += "[\(shown)](\(url.absoluteString))"
            }
            cursor = r.location + r.length
        }
        result += ns.substring(from: cursor)
        return result
    }
}
