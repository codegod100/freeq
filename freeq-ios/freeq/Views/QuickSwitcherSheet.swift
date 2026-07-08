import SwiftUI

/// ⌘K quick switcher — fuzzy-jump to any channel or DM. Favorites first, then
/// channels, then DMs. Autofocuses so a hardware-keyboard user can type
/// immediately and press Return to open the top match.
struct QuickSwitcherSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var fieldFocused: Bool

    /// Buffers in sidebar order (favorites, channels, DMs), de-duplicated.
    private var buffers: [ChannelState] {
        let favNames = Set(appState.favoritesOrder)
        let ordered = appState.favoriteBuffers
            + appState.channels.filter { !favNames.contains($0.name) }
            + appState.dmBuffers.filter { !favNames.contains($0.name) }
        var seen = Set<String>()
        return ordered.filter { seen.insert($0.name).inserted }
    }

    private var filtered: [ChannelState] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return buffers }
        return buffers.filter { $0.name.lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Jump to channel or DM…", text: $query)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .focused($fieldFocused)
                        .submitLabel(.go)
                        .onSubmit { if let first = filtered.first { pick(first.name) } }
                }
                .padding(12)
                Divider()

                List {
                    ForEach(filtered) { buf in
                        Button { pick(buf.name) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: buf.name.hasPrefix("#") ? "number" : "person.fill")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 18)
                                Text(buf.name).foregroundStyle(.primary)
                                Spacer()
                                if let u = appState.unreadCounts[buf.name], u > 0 {
                                    Text("\(u)")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                                if appState.favorites.contains(buf.name) {
                                    Image(systemName: "star.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.yellow)
                                }
                            }
                        }
                    }
                    if filtered.isEmpty {
                        Text("No matching channels").foregroundStyle(.secondary)
                    }
                }
                .listStyle(.plain)
            }
            .navigationTitle("Quick Switcher")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
        }
        .onAppear { fieldFocused = true }
    }

    private func pick(_ name: String) {
        appState.navigate(toBuffer: name)
        dismiss()
    }
}
