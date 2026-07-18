import Foundation

/// A single top-level block parsed out of a message body.
///
/// Chat messages arrive as one flat string. Agents in particular post
/// GitHub-Flavored-Markdown: fenced code, block quotes, bullet/numbered
/// lists, and pipe tables. `MessageBlockParser` splits that string into an
/// ordered array of these blocks so the view layer can render each with the
/// right container instead of dumping everything through the inline path
/// (which turns fences/tables into mush).
///
/// Deliberately shallow: this is a *block* splitter, not a full CommonMark
/// tree. Inline styling (`**bold**`, `` `code` ``, links) is left to the
/// existing inline renderer, applied per-paragraph / per-cell / per-item.
enum MessageBlock: Equatable {
    /// Free text between blocks. Verbatim (inline markdown handled downstream).
    case paragraph(String)
    /// A ``` fenced code block. `language` is the info string after the
    /// opening fence (nil when absent). `code` is the raw inner text, verbatim.
    case codeFence(language: String?, code: String)
    /// One or more consecutive `>` quote lines, joined with newlines,
    /// with the leading `>`/`> ` markers stripped.
    case blockQuote(String)
    /// `-`/`*`/`+` bullet list. Each element is the item text after the marker.
    case unorderedList([String])
    /// `1.`/`1)` numbered list. Each element is the item text after the marker.
    case orderedList([String])
    /// A GitHub pipe table. `headers` is the first row; `rows` are the data
    /// rows (each padded/truncated to `headers.count` columns).
    case table(headers: [String], rows: [[String]])
}

/// Pure, dependency-free block splitter. No SwiftUI, no Foundation UI —
/// safe to unit-test under `swift test`.
enum MessageBlockParser {
    // MARK: - Public API

    /// Cheap pre-check: does this text contain any block-level markdown that
    /// warrants the block renderer? Callers use this to keep plain messages on
    /// the fast inline path. Scans lines once; allocates only line splits.
    static func containsBlockSyntax(_ text: String) -> Bool {
        let lines = text.components(separatedBy: .newlines)
        for (idx, raw) in lines.enumerated() {
            let t = leadingStripped(raw)
            if t.hasPrefix("```") { return true }
            if t.hasPrefix(">") { return true }
            if unorderedItem(raw) != nil { return true }
            if orderedItem(raw) != nil { return true }
            if raw.contains("|"), idx + 1 < lines.count, isTableSeparator(lines[idx + 1]) {
                return true
            }
        }
        return false
    }

    /// Split a message body into ordered blocks.
    ///
    /// Fast path: text with no block syntax returns a single `.paragraph`
    /// (line endings normalized to `\n`). Otherwise the body is scanned
    /// line-by-line, flushing accumulated paragraph text whenever a block
    /// starts. An unterminated fence runs to end of input; fence contents are
    /// never re-interpreted (markdown-looking lines stay verbatim).
    static func parse(_ text: String) -> [MessageBlock] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        guard containsBlockSyntax(normalized) else {
            return [.paragraph(normalized)]
        }

        let lines = normalized.components(separatedBy: "\n")
        var blocks: [MessageBlock] = []
        var paragraph: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph.removeAll(keepingCapacity: true)
        }

        var i = 0
        while i < lines.count {
            let line = lines[i]

            // --- Fenced code block ---
            if let language = fenceLanguage(line) {
                flushParagraph()
                var code: [String] = []
                i += 1
                while i < lines.count {
                    if leadingStripped(lines[i]).hasPrefix("```") {
                        i += 1  // consume the closing fence
                        break
                    }
                    code.append(lines[i])
                    i += 1
                }
                // Unterminated fence: loop above simply ran to end (i == count).
                blocks.append(.codeFence(language: language.isEmpty ? nil : language,
                                         code: code.joined(separator: "\n")))
                continue
            }

            // --- Block quote ---
            if blockQuoteContent(line) != nil {
                flushParagraph()
                var quote: [String] = []
                while i < lines.count, let content = blockQuoteContent(lines[i]) {
                    quote.append(content)
                    i += 1
                }
                blocks.append(.blockQuote(quote.joined(separator: "\n")))
                continue
            }

            // --- Pipe table (header row + separator row) ---
            if line.contains("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                flushParagraph()
                let headers = parseCells(line)
                i += 2  // skip header + separator
                var rows: [[String]] = []
                while i < lines.count {
                    let rowLine = lines[i]
                    if rowLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { break }
                    if !rowLine.contains("|") { break }
                    if leadingStripped(rowLine).hasPrefix("```") { break }
                    var cells = parseCells(rowLine)
                    if cells.count < headers.count {
                        cells += Array(repeating: "", count: headers.count - cells.count)
                    } else if cells.count > headers.count {
                        cells = Array(cells.prefix(headers.count))
                    }
                    rows.append(cells)
                    i += 1
                }
                blocks.append(.table(headers: headers, rows: rows))
                continue
            }

            // --- Unordered list ---
            if unorderedItem(line) != nil {
                flushParagraph()
                var items: [String] = []
                while i < lines.count, let item = unorderedItem(lines[i]) {
                    items.append(item)
                    i += 1
                }
                blocks.append(.unorderedList(items))
                continue
            }

            // --- Ordered list ---
            if orderedItem(line) != nil {
                flushParagraph()
                var items: [String] = []
                while i < lines.count, let item = orderedItem(lines[i]) {
                    items.append(item)
                    i += 1
                }
                blocks.append(.orderedList(items))
                continue
            }

            // --- Blank line: paragraph boundary ---
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                flushParagraph()
                i += 1
                continue
            }

            // --- Plain paragraph line ---
            paragraph.append(line)
            i += 1
        }
        flushParagraph()

        // Defensive: if we somehow produced nothing, fall back to one paragraph
        // so the caller always has something to render.
        return blocks.isEmpty ? [.paragraph(normalized)] : blocks
    }

    // MARK: - Line classifiers

    private static func leadingStripped(_ s: String) -> String {
        String(s.drop(while: { $0 == " " || $0 == "\t" }))
    }

    /// Returns the fence info string (possibly empty) if `line` opens a fence,
    /// else nil. Empty string means "fence, no language".
    private static func fenceLanguage(_ line: String) -> String? {
        let t = leadingStripped(line)
        guard t.hasPrefix("```") else { return nil }
        let after = t.drop(while: { $0 == "`" })
        return after.trimmingCharacters(in: .whitespaces)
    }

    /// If `line` is a quote line, returns its content with the `>`/`> ` marker
    /// stripped; else nil.
    private static func blockQuoteContent(_ line: String) -> String? {
        let t = leadingStripped(line)
        guard t.hasPrefix(">") else { return nil }
        var rest = String(t.dropFirst())
        if rest.hasPrefix(" ") { rest.removeFirst() }
        return rest
    }

    /// If `line` is a bullet item, returns its text after the marker; else nil.
    private static func unorderedItem(_ line: String) -> String? {
        let t = leadingStripped(line)
        guard let first = t.first, first == "-" || first == "*" || first == "+" else { return nil }
        let second = t.index(after: t.startIndex)
        guard second < t.endIndex, t[second] == " " else { return nil }
        return String(t[t.index(after: second)...])
    }

    /// If `line` is a numbered item (`N.` or `N)`), returns its text after the
    /// marker; else nil.
    private static func orderedItem(_ line: String) -> String? {
        let t = leadingStripped(line)
        var idx = t.startIndex
        var sawDigit = false
        while idx < t.endIndex, t[idx].isNumber {
            sawDigit = true
            idx = t.index(after: idx)
        }
        guard sawDigit, idx < t.endIndex, t[idx] == "." || t[idx] == ")" else { return nil }
        let afterPunct = t.index(after: idx)
        guard afterPunct < t.endIndex, t[afterPunct] == " " else { return nil }
        return String(t[t.index(after: afterPunct)...])
    }

    // MARK: - Table helpers

    /// A separator row like `| --- | :--: |`. Requires at least one pipe (so a
    /// bare `---` horizontal rule is not mistaken for a table) and every cell
    /// to be dashes with optional alignment colons.
    private static func isTableSeparator(_ line: String) -> Bool {
        guard line.contains("|") else { return false }
        let cells = parseCells(line)
        guard !cells.isEmpty else { return false }
        for cell in cells {
            var body = cell
            if body.hasPrefix(":") { body.removeFirst() }
            if body.hasSuffix(":") { body.removeLast() }
            guard !body.isEmpty, body.allSatisfy({ $0 == "-" }) else { return false }
        }
        return true
    }

    /// Split a table row on unescaped pipes, dropping the optional outer pipes
    /// and trimming each cell.
    private static func parseCells(_ line: String) -> [String] {
        var s = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        let placeholder = "\u{0000}"
        s = s.replacingOccurrences(of: "\\|", with: placeholder)
        return s.components(separatedBy: "|").map {
            $0.replacingOccurrences(of: placeholder, with: "|")
              .trimmingCharacters(in: .whitespaces)
        }
    }
}
