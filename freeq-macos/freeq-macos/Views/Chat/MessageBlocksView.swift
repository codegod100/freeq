import SwiftUI
import AppKit

/// Renders a message body as full block markdown: fenced code (with syntax
/// highlighting + copy), block quotes, bullet/numbered lists, and pipe tables.
/// Paragraphs (and the inline content of quotes/list-items/table-cells) go
/// through the SAME inline renderer `MessageListView` uses for plain text, so
/// inline styling (**bold**, `code`, links, mentions) stays identical.
///
/// Container-agnostic by design: message text in, a self-contained view out.
/// It does no layout beyond stacking its blocks, so a future AppKit list can
/// host it unchanged.
struct MessageBlocksView: View {
    let text: String
    /// Injected so paragraph/quote/list/cell inline styling matches the rest
    /// of the timeline exactly (single source of truth for inline markdown).
    let inlineRenderer: (String) -> AttributedString

    private var blocks: [MessageBlock] { MessageBlockParser.parse(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: MessageBlock) -> some View {
        switch block {
        case .paragraph(let s):
            Text(inlineRenderer(s))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .codeFence(let language, let code):
            CodeFenceView(language: language, code: code)
        case .blockQuote(let s):
            BlockQuoteView(text: s, inlineRenderer: inlineRenderer)
        case .unorderedList(let items):
            MarkdownListView(items: items, ordered: false, inlineRenderer: inlineRenderer)
        case .orderedList(let items):
            MarkdownListView(items: items, ordered: true, inlineRenderer: inlineRenderer)
        case .table(let headers, let rows):
            MarkdownTableView(headers: headers, rows: rows, inlineRenderer: inlineRenderer)
        }
    }
}

// MARK: - Code fence

/// A fenced code block: monospaced at ~88% body size, secondary fill, rounded
/// corners, language label + hover-reveal copy button top-right, and horizontal
/// scroll so long lines never wrap or blow out the row width (design §8.2).
struct CodeFenceView: View {
    let language: String?
    let code: String

    @State private var isHovered = false
    @State private var didCopy = false

    private var fontSize: CGFloat { NSFont.systemFontSize * 0.88 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView(.horizontal, showsIndicators: false) {
                Text(highlighted)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
        }
        .background(Theme.surfaceSoft)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Theme.borderSoft, lineWidth: 1)
        )
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            if let language, !language.isEmpty {
                Text(language.lowercased())
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
            }
            if isHovered {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    didCopy = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { didCopy = false }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                        Text(didCopy ? "Copied" : "Copy")
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(didCopy ? Theme.success : Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Copy code")
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 2)
        .frame(minHeight: 20)
    }

    /// Tokenize + colorize. Unknown languages return a single plain token, so
    /// the code stays legible (just uncolored). Losslessly reconstructs `code`.
    private var highlighted: AttributedString {
        let mono = Font.system(size: fontSize, design: .monospaced)
        let tokens = SyntaxHighlighter.highlight(code, language: language)
        guard !tokens.isEmpty else {
            var s = AttributedString(code)
            s.font = mono
            s.foregroundColor = Theme.textPrimary
            return s
        }
        var result = AttributedString()
        for token in tokens {
            var piece = AttributedString(token.text)
            piece.font = mono
            piece.foregroundColor = color(for: token.kind)
            result += piece
        }
        return result
    }

    private func color(for kind: SyntaxTokenKind) -> Color {
        switch kind {
        case .plain: return Theme.textPrimary
        case .keyword: return Theme.purple
        case .string: return Theme.success
        case .comment: return Theme.textTertiary
        case .number: return Theme.warning
        }
    }
}

// MARK: - Block quote

/// A `>` quote: leading accent bar + secondary-colored text. Multi-line quotes
/// arrive pre-joined with newlines, so a single Text renders the whole block.
struct BlockQuoteView: View {
    let text: String
    let inlineRenderer: (String) -> AttributedString

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(Theme.accent.opacity(0.55))
                .frame(width: 3)
            Text(inlineRenderer(text))
                .foregroundStyle(Theme.textSecondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 1)
    }
}

// MARK: - Lists

/// A bullet or numbered list with a fixed marker column, giving wrapped item
/// text a proper hanging indent.
struct MarkdownListView: View {
    let items: [String]
    let ordered: Bool
    let inlineRenderer: (String) -> AttributedString

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(marker(for: index))
                        .font(.body.monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                        .frame(minWidth: ordered ? 22 : 14, alignment: .trailing)
                    Text(inlineRenderer(item))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.leading, 2)
    }

    private func marker(for index: Int) -> String {
        ordered ? "\(index + 1)." : "•"
    }
}

// MARK: - Table

/// A GitHub pipe table. Grid gives real column alignment; the header row is
/// bold with a divider, a hairline border frames the whole grid, and the grid
/// scrolls horizontally when wider than the row.
struct MarkdownTableView: View {
    let headers: [String]
    let rows: [[String]]
    let inlineRenderer: (String) -> AttributedString

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    ForEach(Array(headers.enumerated()), id: \.offset) { _, cell in
                        Text(inlineRenderer(cell))
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                Divider()
                    .gridCellUnsizedAxes(.horizontal)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(inlineRenderer(cell))
                                .foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                }
            }
            .padding(10)
        }
        .background(Theme.surfaceSoft.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Theme.borderSoft, lineWidth: 1)
        )
    }
}
