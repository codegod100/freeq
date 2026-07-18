import Foundation

/// Pure selection-wrapping math for the compose formatting toolbar.
/// Offsets are UTF-16 (NSRange-compatible) so the caller can feed
/// `NSTextView.selectedRange()` straight in.
enum ComposeFormatting {
    struct Result: Equatable {
        var text: String
        var selectionLocation: Int
        var selectionLength: Int
    }

    /// Wrap the selected range in `prefix`/`suffix`.
    ///
    /// - With a selection: the selection stays on the wrapped inner text so
    ///   repeated formatting composes; if `placeholder` occurs in `suffix`
    ///   (e.g. "url" in "](url)"), the placeholder is selected instead so the
    ///   user can type over it immediately.
    /// - Without a selection: the markers are inserted and the caret lands
    ///   between them.
    static func wrap(
        text: String,
        selectionLocation: Int,
        selectionLength: Int,
        prefix: String,
        suffix: String,
        placeholder: String? = nil
    ) -> Result {
        let ns = text as NSString
        let loc = max(0, min(selectionLocation, ns.length))
        let len = max(0, min(selectionLength, ns.length - loc))
        let selected = ns.substring(with: NSRange(location: loc, length: len))
        let replacement = prefix + selected + suffix
        let newText = ns.replacingCharacters(
            in: NSRange(location: loc, length: len), with: replacement)
        let prefixLen = (prefix as NSString).length
        let selectedLen = (selected as NSString).length

        if len > 0, let placeholder, !placeholder.isEmpty {
            let phRange = (suffix as NSString).range(of: placeholder)
            if phRange.location != NSNotFound {
                let base = loc + prefixLen + selectedLen
                return Result(
                    text: newText,
                    selectionLocation: base + phRange.location,
                    selectionLength: phRange.length)
            }
        }
        return Result(
            text: newText,
            selectionLocation: loc + prefixLen,
            selectionLength: len)
    }
}
