import SwiftUI

/// iPad / regular-width root: a two-column NavigationSplitView (conversation
/// list ▸ detail) instead of the iPhone bottom TabView. Gated in ContentView on
/// horizontalSizeClass, so the compact (iPhone) experience is untouched.
struct SplitRootView: View {
    @EnvironmentObject var appState: AppState
    @State private var selection: String?

    var body: some View {
        NavigationSplitView {
            SidebarListView(selection: $selection)
        } detail: {
            if let sel = selection {
                NavigationStack {
                    ChatDetailView(channelName: sel)
                }
                .id(sel)  // rebuild the detail when the selection changes
            } else {
                EmptyStateView(
                    icon: "bubble.left.and.bubble.right",
                    title: "Select a conversation",
                    message: "Pick a channel or direct message from the sidebar."
                )
            }
        }
        // Keep the split selection and the app's active channel in sync both ways.
        .onChange(of: selection) { _, new in
            if appState.activeChannel != new { appState.activeChannel = new }
        }
        .onChange(of: appState.activeChannel) { _, new in
            if selection != new { selection = new }
        }
        .onChange(of: appState.pendingDMNick) { _, nick in
            guard let nick else { return }
            appState.pendingDMNick = nil
            selection = nick
        }
        .onAppear { selection = appState.activeChannel }
    }
}

/// The sidebar column: favorites, channels, and DMs with single selection.
private struct SidebarListView: View {
    @EnvironmentObject var appState: AppState
    @Binding var selection: String?
    @State private var searchText = ""
    @State private var showingJoin = false

    private var allConversations: [ChannelState] {
        let channels = appState.channels.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        let dms = appState.dmBuffers
            .filter { !appState.isBlocked(nick: $0.name) }
            .sorted { $0.lastActivity > $1.lastActivity }
        return channels + dms
    }

    private var filtered: [ChannelState] {
        guard !searchText.isEmpty else { return allConversations }
        return allConversations.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private func isChannel(_ name: String) -> Bool { name.hasPrefix("#") || name.hasPrefix("&") }
    private var favorites: [ChannelState] { filtered.filter { appState.isFavorite($0.name) } }
    private var channels: [ChannelState] {
        filtered.filter { !appState.isFavorite($0.name) && isChannel($0.name) }
    }
    private var dms: [ChannelState] {
        filtered.filter { !appState.isFavorite($0.name) && !isChannel($0.name) }
    }

    var body: some View {
        List(selection: $selection) {
            if !favorites.isEmpty && searchText.isEmpty {
                Section("Favorites") { ForEach(favorites, id: \.name) { row($0) } }
            }
            if !channels.isEmpty {
                Section("Channels") { ForEach(channels, id: \.name) { row($0) } }
            }
            if !dms.isEmpty {
                Section("Direct Messages") { ForEach(dms, id: \.name) { row($0) } }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $searchText, prompt: "Search")
        .navigationTitle("freeq")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showingJoin = true } label: {
                    Image(systemName: "square.and.pencil")
                }
                .accessibilityLabel("Join a channel")
            }
        }
        .sheet(isPresented: $showingJoin) {
            JoinChannelSheet()
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
    }

    @ViewBuilder
    private func row(_ conv: ChannelState) -> some View {
        ChatRow(conversation: conv, unreadCount: appState.unreadCounts[conv.name] ?? 0)
            .tag(conv.name)
            .contextMenu {
                Button {
                    appState.toggleFavorite(conv.name)
                } label: {
                    Label(appState.isFavorite(conv.name) ? "Remove from Favorites" : "Add to Favorites",
                          systemImage: appState.isFavorite(conv.name) ? "star.slash" : "star")
                }
                Button {
                    appState.toggleMute(conv.name)
                } label: {
                    Label(appState.isMuted(conv.name) ? "Unmute" : "Mute",
                          systemImage: appState.isMuted(conv.name) ? "bell" : "bell.slash")
                }
                Button { appState.markRead(conv.name) } label: {
                    Label("Mark as Read", systemImage: "checkmark.circle")
                }
                Divider()
                Button(role: .destructive) {
                    if isChannel(conv.name) { appState.partChannel(conv.name) }
                    else { appState.closeDM(conv.name) }
                } label: {
                    Label(isChannel(conv.name) ? "Leave Channel" : "Close",
                          systemImage: "arrow.right.square")
                }
            }
    }
}
