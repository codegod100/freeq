import SwiftUI

/// ⌘K palette — fuzzy search across channels, DMs, and every registered
/// command (the same set the menu bar shows, projected from
/// CommandRegistry/CommandActions).
struct QuickSwitcher: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var query: String = ""
    @FocusState private var isFocused: Bool
    @State private var selectedIndex: Int = 0

    private enum Item: Identifiable {
        case buffer(ChannelState)
        case command(AppCommand)

        var id: String {
            switch self {
            case .buffer(let ch): return "b:\(ch.name)"
            case .command(let cmd): return "c:\(cmd.id)"
            }
        }
    }

    private var results: [Item] {
        let all = appState.allBuffers
        if query.isEmpty {
            return all.map(Item.buffer)
        }
        let q = query.lowercased()
        // Match the key OR its display name — a DID-keyed DM matches by nick.
        let buffers = all.filter {
            $0.name.lowercased().contains(q)
                || appState.displayNameForKey($0.name).lowercased().contains(q)
        }.map(Item.buffer)
        let commands = CommandMatcher.rank(query: query, in: CommandRegistry.all)
            .filter { CommandActions.isEnabled($0.id, appState) }
            .map(Item.command)
        return buffers + commands
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search field
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Switch to channel — or type a command…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($isFocused)
                    .onSubmit { select() }
            }
            .padding(16)

            Divider()

            // Results
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                        row(for: item)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(index == selectedIndex ? Color.accentColor.opacity(0.15) : .clear)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                activate(item)
                            }
                    }
                }
            }
            .frame(maxHeight: 300)
        }
        .frame(width: 400)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 20)
        .onAppear { isFocused = true }
        .onKeyPress(.upArrow) {
            selectedIndex = max(0, selectedIndex - 1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            selectedIndex = min(results.count - 1, selectedIndex + 1)
            return .handled
        }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
        .onChange(of: query) { _, _ in
            selectedIndex = 0
        }
    }

    @ViewBuilder
    private func row(for item: Item) -> some View {
        switch item {
        case .buffer(let ch):
            HStack(spacing: 10) {
                if ch.isChannel {
                    Image(systemName: "number")
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                } else {
                    Circle()
                        .fill(appState.isNickOnline(appState.displayNameForKey(ch.name)) ? .green : Color.secondary.opacity(0.3))
                        .frame(width: 10, height: 10)
                        .frame(width: 20)
                }
                Text(ch.isChannel ? ch.name : appState.displayNameForKey(ch.name))
                    .lineLimit(1)
                Spacer()
                if let unread = appState.unreadCounts[ch.name.lowercased()], unread > 0 {
                    Text("\(unread)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.red))
                }
            }
        case .command(let cmd):
            HStack(spacing: 10) {
                Image(systemName: "command")
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                Text(CommandActions.title(cmd.id, appState))
                    .lineLimit(1)
                Text(cmd.category)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                if let shortcut = cmd.shortcutLabel {
                    Text(shortcut)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func activate(_ item: Item) {
        switch item {
        case .buffer(let ch):
            appState.activeChannel = ch.name
        case .command(let cmd):
            CommandActions.run(cmd.id, appState)
        }
        dismiss()
    }

    private func select() {
        guard selectedIndex < results.count else { return }
        activate(results[selectedIndex])
    }
}
