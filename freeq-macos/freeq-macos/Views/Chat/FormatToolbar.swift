import SwiftUI

/// Inline formatting toolbar — bold, italic, code, strikethrough, link.
/// Wraps the composer's actual selection (via the focused ComposeNSTextView);
/// with no selection the markers are inserted at the caret.
struct FormatToolbar: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 2) {
            FormatButton(icon: "bold", tooltip: "Bold") {
                apply(prefix: "**", suffix: "**")
            }
            FormatButton(icon: "italic", tooltip: "Italic") {
                apply(prefix: "_", suffix: "_")
            }
            FormatButton(icon: "chevron.left.forwardslash.chevron.right", tooltip: "Code") {
                apply(prefix: "`", suffix: "`")
            }
            FormatButton(icon: "strikethrough", tooltip: "Strikethrough") {
                apply(prefix: "~~", suffix: "~~")
            }
            FormatButton(icon: "link", tooltip: "Link") {
                apply(prefix: "[", suffix: "](url)", placeholder: "url")
            }
        }
    }

    private func apply(prefix: String, suffix: String, placeholder: String? = nil) {
        if let textView = ComposeNSTextView.activeInstance {
            textView.applyFormat(prefix: prefix, suffix: suffix, placeholder: placeholder)
        } else {
            // No live composer (shouldn't happen in practice) — append at the end.
            let result = ComposeFormatting.wrap(
                text: text,
                selectionLocation: (text as NSString).length,
                selectionLength: 0,
                prefix: prefix, suffix: suffix, placeholder: placeholder)
            text = result.text
        }
    }
}

struct FormatButton: View {
    let icon: String
    let tooltip: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.clear))
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }
}
