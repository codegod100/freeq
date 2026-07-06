import SwiftUI

/// Shared autocomplete core for @mentions, /commands, and :emoji: — used by
/// both the visible `AutocompletePopup` and the composer's key handling so
/// that the keyboard (↑/↓ to move, Tab/Return to accept) operates on exactly
/// the suggestions the user sees. Keeping this in one place is what makes the
/// popup and the keyboard agree; when they were separate, Tab ran a different
/// matcher that didn't strip the leading "@" and silently did nothing.
enum ComposeAutocomplete {
    /// A mention candidate: the real IRC nick to insert, plus the names the
    /// user might actually type (Bluesky display name + handle). Members are
    /// shown in the sidebar by display name, so "@nandi" must match a member
    /// whose nick isn't literally "nandi".
    struct Member {
        let nick: String
        let aliases: [String]
    }

    enum Suggestion: Identifiable {
        case nick(String)
        case command(String, String)  // name, description
        case emoji(String, String)  // shortcode, emoji char

        var id: String {
            switch self {
            case .nick(let n): return "nick:\(n)"
            case .command(let c, _): return "cmd:\(c)"
            case .emoji(let s, _): return "emoji:\(s)"
            }
        }

        var display: String {
            switch self {
            case .nick(let n): return "@\(n)"
            case .command(let c, let d): return "/\(c) — \(d)"
            case .emoji(let s, let e): return "\(e)  :\(s):"
            }
        }
    }

    static let commands: [(String, String)] = [
        ("join", "Join a channel"),
        ("part", "Leave current channel"),
        ("topic", "Set channel topic"),
        ("nick", "Change nickname"),
        ("me", "Send an action"),
        ("msg", "Send a direct message"),
        ("kick", "Kick a user"),
        ("op", "Give operator status"),
        ("deop", "Remove operator status"),
        ("voice", "Give voice"),
        ("invite", "Invite user to channel"),
        ("away", "Set away status"),
        ("whois", "Look up user info"),
        ("mode", "Set channel/user mode"),
        ("raw", "Send raw IRC command"),
        ("av", "Start, join, or control a call"),
        ("encrypt", "Enable channel E2EE with a passphrase"),
        ("decrypt", "Disable channel E2EE"),
        ("p2p", "P2P commands"),
        ("help", "Show help"),
    ]

    static let commonEmoji: [(String, String)] = [
        ("thumbsup", "👍"), ("thumbsdown", "👎"), ("heart", "❤️"), ("fire", "🔥"),
        ("laugh", "😂"), ("smile", "😊"), ("thinking", "🤔"), ("eyes", "👀"),
        ("rocket", "🚀"), ("100", "💯"), ("tada", "🎉"), ("wave", "👋"),
        ("clap", "👏"), ("pray", "🙏"), ("star", "⭐"), ("check", "✅"),
        ("x", "❌"), ("warning", "⚠️"), ("bug", "🐛"), ("sparkles", "✨"),
        ("zap", "⚡"), ("skull", "💀"), ("sob", "😭"), ("rolling_eyes", "🙄"),
        ("shrug", "🤷"), ("sunglasses", "😎"), ("nerd", "🤓"), ("salute", "🫡"),
        ("brain", "🧠"), ("gem", "💎"), ("trophy", "🏆"), ("party", "🥳"),
    ]

    /// Build mention candidates from channel members, folding in each member's
    /// Bluesky display name + handle as searchable aliases.
    static func members(from infos: [MemberInfo]) -> [Member] {
        infos.map { info in
            var aliases: [String] = []
            if let p = ProfileCache.shared.profile(for: info.nick) {
                if let dn = p.displayName, !dn.isEmpty {
                    aliases.append(dn)                                   // "Jess Martin"
                    let compact = dn.replacingOccurrences(of: " ", with: "")
                    if compact != dn { aliases.append(compact) }         // "JessMartin"
                    if let first = dn.split(separator: " ").first { aliases.append(String(first)) }
                }
                if let h = p.handle, !h.isEmpty {
                    aliases.append(h)                                    // "nandi.uk"
                    if let label = h.split(separator: ".").first { aliases.append(String(label)) }  // "nandi"
                }
            }
            return Member(nick: info.nick, aliases: aliases)
        }
    }

    /// Suggestions for the current draft, given the channel's members.
    static func suggestions(text t: String, members: [Member]) -> [Suggestion] {
        // @mention — match the nick OR any alias (display name / handle), but
        // always insert the real nick.
        if let atRange = t.range(of: "@", options: .backwards),
           t.distance(from: atRange.lowerBound, to: t.endIndex) <= 20,
           (atRange.lowerBound == t.startIndex || t[t.index(before: atRange.lowerBound)] == " ") {
            let prefix = String(t[atRange.upperBound...]).lowercased()
            return members
                .filter { m in
                    prefix.isEmpty
                        || m.nick.lowercased().hasPrefix(prefix)
                        || m.aliases.contains { $0.lowercased().hasPrefix(prefix) }
                }
                .prefix(8)
                .map { .nick($0.nick) }
        }

        // /command
        if t.hasPrefix("/") && !t.contains(" ") {
            let prefix = String(t.dropFirst()).lowercased()
            return commands
                .filter { prefix.isEmpty || $0.0.hasPrefix(prefix) }
                .prefix(8)
                .map { .command($0.0, $0.1) }
        }

        // :emoji:
        if let colonRange = t.range(of: ":", options: .backwards),
           t.distance(from: colonRange.lowerBound, to: t.endIndex) >= 2,
           t.distance(from: colonRange.lowerBound, to: t.endIndex) <= 15,
           (colonRange.lowerBound == t.startIndex || t[t.index(before: colonRange.lowerBound)] == " ") {
            let prefix = String(t[colonRange.upperBound...]).lowercased()
            guard !prefix.isEmpty else { return [] }
            return commonEmoji
                .filter { $0.0.contains(prefix) }
                .prefix(8)
                .map { .emoji($0.0, $0.1) }
        }

        return []
    }

    /// The draft text after accepting `item` (replaces the in-progress token).
    static func accept(_ item: Suggestion, in text: String) -> String {
        switch item {
        case .nick(let nick):
            if let atRange = text.range(of: "@", options: .backwards) {
                return String(text[..<atRange.lowerBound]) + "@\(nick) "
            }
            return text
        case .command(let cmd, _):
            return "/\(cmd) "
        case .emoji(_, let char):
            if let colonRange = text.range(of: ":", options: .backwards) {
                return String(text[..<colonRange.lowerBound]) + char
            }
            return text
        }
    }

    /// Shortcode → emoji lookup (the same curated set the popup offers).
    static let emojiByShortcode: [String: String] =
        Dictionary(commonEmoji.map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a })

    /// Replace complete `:shortcode:` tokens with their emoji — what users
    /// expect when they type the Slack-style form with both colons (the popup
    /// only helps with the partial `:wave` form). Applied on send.
    static func replacingShortcodes(_ text: String) -> String {
        guard text.contains(":") else { return text }
        guard let regex = try? NSRegularExpression(pattern: ":([a-z0-9_+-]+):", options: [.caseInsensitive]) else {
            return text
        }
        let ns = text as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let code = ns.substring(with: match.range(at: 1)).lowercased()
            guard let emoji = emojiByShortcode[code] else { continue }
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            result += emoji
            last = match.range.location + match.range.length
        }
        guard last > 0 else { return text }
        result += ns.substring(from: last)
        return result
    }
}

/// Autocomplete popup for @mentions, /commands, and :emoji:. Purely presents
/// `ComposeAutocomplete.suggestions`; the composer drives selection + accept so
/// mouse and keyboard stay in sync.
struct AutocompletePopup: View {
    @Environment(AppState.self) private var appState
    @Binding var text: String
    @Binding var selectedIndex: Int
    /// True when the user pressed Esc to dismiss — hides the popup until the
    /// draft changes again.
    var suppressed: Bool

    var body: some View {
        let members = ComposeAutocomplete.members(from: appState.activeChannelState?.members ?? [])
        let items = suppressed ? [] : ComposeAutocomplete.suggestions(text: text, members: members)
        if !items.isEmpty {
            let sel = min(max(0, selectedIndex), items.count - 1)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    Button {
                        text = ComposeAutocomplete.accept(item, in: text)
                        selectedIndex = 0
                    } label: {
                        HStack {
                            Text(item.display)
                                .font(.system(.body, design: .default))
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(index == sel ? Color.accentColor.opacity(0.15) : Color.clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 350)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .shadow(color: .black.opacity(0.15), radius: 8, y: -4)
            .padding(.horizontal, 16)
            .padding(.bottom, 4)
        }
    }
}
