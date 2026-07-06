import SwiftUI

/// Keyboard-shortcut cheat sheet + GUI feature guide.
///
/// The shortcut rows are projected from `CommandRegistry` (the single source
/// of truth the menu bar and ⌘K palette also use), plus a small set of
/// app-level bindings that live outside the registry (⌘1–9 buffer switch,
/// the ⌥⌘Space global quick-send hotkey). Keeping the command shortcuts
/// registry-driven means this sheet can't drift from the real bindings.
struct HelpView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var section: Section = .shortcuts

    enum Section: String, CaseIterable, Identifiable {
        case shortcuts = "Keyboard Shortcuts"
        case features = "Features & Gestures"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            searchBar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch section {
                    case .shortcuts: shortcutsContent
                    case .features: featuresContent
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 560, height: 620)
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: 12) {
            Image("Logo")
                .resizable().aspectRatio(contentMode: .fit)
                .frame(width: 22, height: 22)
            Text("freeq Help")
                .font(.headline)
            Spacer()
            Picker("", selection: $section) {
                ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 300)
            .labelsHidden()
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search shortcuts and features", text: $query)
                .textFieldStyle(.plain)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    // MARK: - Shortcuts

    /// App-level bindings not held in the CommandRegistry.
    private var extraGroups: [ShortcutGroup] {
        [
            ShortcutGroup("Buffers", [
                .init("Switch to channel 1–9", "⌘1 … ⌘9",
                      ["buffer", "number", "jump"]),
                .init("Go to favorite 1–9", "⌃⌘1 … ⌃⌘9",
                      ["favorite", "star", "pinned", "jump"]),
            ]),
            ShortcutGroup("Global", [
                .init("Quick send (from any app)", "⌥⌘Space",
                      ["hotkey", "global", "send", "compose"]),
                .init("Keyboard Shortcuts & Features", "⌘/",
                      ["help", "cheatsheet"]),
            ]),
        ]
    }

    /// Registry commands that carry a shortcut, grouped by category and
    /// filtered by the search query.
    private var registryGroups: [ShortcutGroup] {
        let order = [CommandRegistry.navigation, CommandRegistry.view,
                     CommandRegistry.call, CommandRegistry.channel,
                     CommandRegistry.presence]
        return order.compactMap { cat in
            let rows = CommandRegistry.category(cat)
                .map { ShortcutRow($0.title, $0.shortcutLabel ?? "⌘K palette",
                                   $0.keywords) }
            return rows.isEmpty ? nil : ShortcutGroup(cat, rows)
        }
    }

    private var filteredShortcutGroups: [ShortcutGroup] {
        let all = registryGroups + extraGroups
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.compactMap { group in
            let rows = group.rows.filter { $0.matches(q) }
            return rows.isEmpty ? nil : ShortcutGroup(group.title, rows)
        }
    }

    @ViewBuilder private var shortcutsContent: some View {
        let groups = filteredShortcutGroups
        if groups.isEmpty {
            emptyResults
        } else {
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 6) {
                    Text(group.title.uppercased())
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(group.rows) { row in
                        HStack {
                            Text(row.title)
                            Spacer(minLength: 24)
                            KeyCaps(row.keys)
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
            Text("Commands without a key can be run from the ⌘K Quick Switcher.")
                .font(.caption).foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
    }

    // MARK: - Features

    private var featureItems: [FeatureItem] {
        [
            .init("bolt.fill", "Quick Switcher",
                  "Press ⌘K to fuzzy-jump to any channel or run any command — mute, start a call, toggle away, and more.",
                  ["palette", "command", "jump", "switch"]),
            .init("square.and.pencil", "New direct message",
                  "Press ⌘N to start a DM. Type a name to fuzzy-match people in your channels and existing DMs, or enter any nickname directly — Return opens the conversation.",
                  ["dm", "pm", "message", "whisper", "private"]),
            .init("bell.badge.fill", "Notifications",
                  "Mentions and DMs notify by default; enable all-channel notifications in Settings. Click a notification to jump to the message, or reply inline without opening the app. DMs and mentions are time-sensitive so an allowed Focus can let them through.",
                  ["alerts", "reply", "focus", "dnd", "dm", "mention"]),
            .init("star.fill", "Favorite channels",
                  "Right-click a channel → Favorite to pin it to the top of the sidebar. Jump straight to a favorite with ⌃⌘1–9 (in the order shown under Favorites), or from the View → Go to Favorite menu.",
                  ["star", "pin", "sidebar", "shortcut", "navigate"]),
            .init("slider.horizontal.3", "Per-channel notification levels",
                  "Right-click a channel in the sidebar → Notifications to set All messages, Mentions only, or Muted.",
                  ["mute", "sidebar", "silence"]),
            .init("bubble.left.and.text.bubble.right.fill", "Message actions",
                  "Right-click any message to React, Reply, Open Thread, Copy text or message ID, Bookmark, or Pin (in channels).",
                  ["context", "react", "thread", "bookmark", "pin", "quote"]),
            .init("phone.fill", "Voice & video calls",
                  "Start or join a call from a channel. In-call: ⇧⌘M mute, ⇧⌘V camera, ⇧⌘S share screen, ⇧⌘E expand the grid, ⇧⌘H hang up.",
                  ["av", "screenshare", "meeting"]),
            .init("menubar.rectangle", "Menu bar & Dock",
                  "The menu bar item shows call and unread state and survives closing the window. Right-click the Dock icon to jump to the next unread channel, toggle away, or start a call. The Dock badge shows your total unread count.",
                  ["tray", "status", "badge"]),
            .init("magnifyingglass", "Search & history",
                  "⌘F searches messages in the current channel. Scroll up to load older history on demand. ⇧⌘B opens your bookmarks; ⇧⌘L browses channels.",
                  ["find", "chathistory", "scrollback"]),
            .init("bolt.horizontal.fill", "Global quick send",
                  "Press ⌥⌘Space from any app to pop a compose panel and fire a message into a channel without switching windows.",
                  ["hotkey", "compose", "background"]),
            .init("person.2.fill", "Detail panel",
                  "⇧⌘D toggles the member/detail panel on the right of the current channel.",
                  ["members", "inspector", "roster"]),
        ]
    }

    private var filteredFeatures: [FeatureItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return featureItems }
        return featureItems.filter { $0.matches(q) }
    }

    @ViewBuilder private var featuresContent: some View {
        let items = filteredFeatures
        if items.isEmpty {
            emptyResults
        } else {
            ForEach(items) { item in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: item.icon)
                        .font(.system(size: 16))
                        .foregroundStyle(.tint)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(.body.weight(.medium))
                        Text(item.detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var emptyResults: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28)).foregroundStyle(.tertiary)
            Text("No matches for “\(query)”").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 40)
    }
}

// MARK: - Row rendering

/// Renders a shortcut label like "⇧⌘M" or "⌘1 … ⌘9" as individual keycaps.
private struct KeyCaps: View {
    let label: String
    init(_ label: String) { self.label = label }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(tokens.enumerated()), id: \.offset) { _, tok in
                if tok == "…" {
                    Text("…").foregroundStyle(.secondary)
                } else {
                    Text(tok)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5)
                            .fill(Color.secondary.opacity(0.15)))
                        .overlay(RoundedRectangle(cornerRadius: 5)
                            .stroke(Color.secondary.opacity(0.25), lineWidth: 0.5))
                }
            }
        }
    }

    /// Split "⇧⌘M" into ["⇧", "⌘", "M"] and "⌘1 … ⌘9" into ["⌘1","…","⌘9"].
    private var tokens: [String] {
        if label.contains(" ") {
            return label.split(separator: " ").map(String.init)
        }
        // A run of modifier glyphs followed by a key.
        let mods: Set<Character> = ["⌘", "⇧", "⌥", "⌃"]
        var out: [String] = []
        var rest = Substring(label)
        while let first = rest.first, mods.contains(first) {
            out.append(String(first))
            rest = rest.dropFirst()
        }
        if !rest.isEmpty { out.append(String(rest)) }
        return out.isEmpty ? [label] : out
    }
}

// MARK: - Data

private struct ShortcutRow: Identifiable {
    let id = UUID()
    let title: String
    let keys: String
    let keywords: [String]
    init(_ title: String, _ keys: String, _ keywords: [String] = []) {
        self.title = title; self.keys = keys; self.keywords = keywords
    }
    func matches(_ q: String) -> Bool {
        title.lowercased().contains(q)
            || keys.lowercased().contains(q)
            || keywords.contains { $0.lowercased().contains(q) }
    }
}

private struct ShortcutGroup: Identifiable {
    let id = UUID()
    let title: String
    let rows: [ShortcutRow]
    init(_ title: String, _ rows: [ShortcutRow]) { self.title = title; self.rows = rows }
}

private struct FeatureItem: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let detail: String
    let keywords: [String]
    init(_ icon: String, _ title: String, _ detail: String, _ keywords: [String]) {
        self.icon = icon; self.title = title; self.detail = detail; self.keywords = keywords
    }
    func matches(_ q: String) -> Bool {
        title.lowercased().contains(q)
            || detail.lowercased().contains(q)
            || keywords.contains { $0.lowercased().contains(q) }
    }
}
