import SwiftUI

/// ⌘N — start a direct message. Type a nick (fuzzy-matched against people in
/// your shared channels and existing DMs) or enter any nick directly, then
/// Return to open the conversation. Mirrors the QuickSwitcher's keyboard UX:
/// ↑/↓ to move, Return to open, Esc to cancel.
struct NewDMSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var isFocused: Bool

    /// Suggestions: known nicks filtered by the query (case-insensitive
    /// substring), prefix matches first. Empty query shows everyone.
    private var suggestions: [String] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let known = appState.knownNicks
        guard !q.isEmpty else { return known }
        let matches = known.filter { $0.lowercased().contains(q) }
        return matches.sorted { a, b in
            let ap = a.lowercased().hasPrefix(q), bp = b.lowercased().hasPrefix(q)
            if ap != bp { return ap }
            return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }
    }

    /// What Return opens: the highlighted suggestion, or the raw typed text
    /// when it doesn't exactly match one (so you can DM someone you share no
    /// channel with).
    private var targetForSubmit: String? {
        let typed = query.trimmingCharacters(in: .whitespaces)
        let list = suggestions
        if !list.isEmpty, selectedIndex < list.count { return list[selectedIndex] }
        return typed.isEmpty ? nil : typed
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "square.and.pencil").foregroundStyle(.secondary)
                TextField("Message someone — type a name…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($isFocused)
                    .onSubmit(open)
            }
            .padding(16)

            Divider()

            if suggestions.isEmpty && query.trimmingCharacters(in: .whitespaces).isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.badge.questionmark")
                        .font(.system(size: 28)).foregroundStyle(.tertiary)
                    Text("Type a nickname to start a DM")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 32)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        // Free-form "message <typed>" affordance when the
                        // typed text isn't already an exact known nick.
                        if let typed = freeformRow {
                            row(nick: typed, subtitle: "Send a new message",
                                highlighted: suggestions.isEmpty)
                                .onTapGesture { appState.openDM(with: typed); dismiss() }
                        }
                        ForEach(Array(suggestions.enumerated()), id: \.element) { index, nick in
                            row(nick: nick,
                                subtitle: appState.isNickOnline(nick) ? "Online" : nil,
                                highlighted: index == selectedIndex)
                                .onTapGesture { appState.openDM(with: nick); dismiss() }
                        }
                    }
                }
                .frame(maxHeight: 300)
            }
        }
        .frame(width: 400)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 20)
        .onAppear { isFocused = true }
        .onKeyPress(.upArrow) {
            selectedIndex = max(0, selectedIndex - 1); return .handled
        }
        .onKeyPress(.downArrow) {
            selectedIndex = min(suggestions.count - 1, selectedIndex + 1); return .handled
        }
        .onKeyPress(.escape) { dismiss(); return .handled }
        .onChange(of: query) { _, _ in selectedIndex = 0 }
    }

    /// The typed text as a free-form target, shown only when it isn't already
    /// an exact (case-insensitive) member of the suggestion list.
    private var freeformRow: String? {
        let typed = query.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty, !typed.hasPrefix("#") else { return nil }
        let exists = suggestions.contains { $0.caseInsensitiveCompare(typed) == .orderedSame }
        return exists ? nil : typed
    }

    private func row(nick: String, subtitle: String?, highlighted: Bool) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(appState.isNickOnline(nick) ? .green : Color.secondary.opacity(0.3))
                .frame(width: 10, height: 10).frame(width: 20)
            Text(nick).lineLimit(1)
            if let subtitle {
                Text(subtitle).font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(highlighted ? Color.accentColor.opacity(0.15) : .clear)
        .contentShape(Rectangle())
    }

    private func open() {
        guard let target = targetForSubmit else { return }
        appState.openDM(with: target)
        dismiss()
    }
}
