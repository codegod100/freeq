import SwiftUI

/// Avatar for a Bluesky actor resolved straight from the graph (we already have
/// the avatar URL, so no nick round-trip). Falls back to a gradient initial.
struct BskyAvatar: View {
    let urlString: String?
    let seed: String
    var size: CGFloat = 46

    var body: some View {
        Group {
            if let s = urlString, let url = URL(string: s) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    initials
                }
            } else {
                initials
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.white.opacity(0.10), lineWidth: 1))
    }

    private var initials: some View {
        let color = Theme.nickColor(for: seed)
        return ZStack {
            LinearGradient(colors: [color, color.opacity(0.72)], startPoint: .top, endPoint: .bottom)
            Text(String(seed.prefix(1)).uppercased())
                .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                .foregroundColor(Color(hex: "04121a").opacity(0.88))
        }
    }
}

/// One person in a graph list — avatar, verified name, handle, bio snippet.
struct BskyActorRow: View {
    let actor: BskyActor

    var body: some View {
        HStack(spacing: 12) {
            BskyAvatar(urlString: actor.avatar, seed: actor.handle, size: 46)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(actor.title)
                        .font(.fqSubheadline.weight(.semibold))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                    // Every AT Protocol account is a real, DID-anchored identity.
                    VerifiedBadge(size: 12)
                }
                Text("@\(actor.handle)")
                    .font(.fqMonoCaption)
                    .foregroundColor(Theme.textMuted)
                    .lineLimit(1)
                if let d = actor.description?.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty {
                    Text(d)
                        .font(.fqCaption)
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(2)
                        .padding(.top, 1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

/// A scrollable list of people from the graph: search results, or anyone's
/// followers / following. Tapping a person opens their profile.
struct GraphListView: View {
    enum Source: Equatable {
        case followers(actor: String)
        case follows(actor: String)
    }

    let title: String
    let source: Source

    @State private var actors: [BskyActor] = []
    @State private var loading = true
    @State private var selected: BskyActor? = nil

    var body: some View {
        ZStack {
            Theme.bgPrimary.ignoresSafeArea()
            if loading {
                ProgressView().tint(Theme.accent)
            } else if actors.isEmpty {
                EmptyStateView(icon: "person.2",
                               title: "No one here yet",
                               message: "This list is empty on Bluesky.")
            } else {
                List {
                    ForEach(actors) { actor in
                        Button { selected = actor } label: { BskyActorRow(actor: actor) }
                            .buttonStyle(.plain)
                            .listRowBackground(Theme.bgSecondary)
                            .listRowSeparatorTint(Theme.border)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .task { await load() }
        .sheet(item: $selected) { actor in
            UserProfileSheet(nick: actor.handle, directActor: actor.did)
        }
    }

    private func load() async {
        let result: [BskyActor]
        switch source {
        case .followers(let a): result = await BlueskyGraph.followers(of: a)
        case .follows(let a): result = await BlueskyGraph.follows(of: a)
        }
        actors = result
        loading = false
    }
}

/// People search over the verified AT Protocol graph — the human counterpart
/// to channel discovery. Find anyone by name or handle; tap to their profile.
struct PeopleSearchView: View {
    @State private var query = ""
    @State private var results: [BskyActor] = []
    @State private var searching = false
    @State private var selected: BskyActor? = nil
    @State private var searchTask: Task<Void, Never>? = nil

    var body: some View {
        ZStack {
            Theme.bgPrimary.ignoresSafeArea()

            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                EmptyStateView(
                    icon: "person.crop.circle.badge.magnifyingglass",
                    title: "Find people",
                    message: "Search anyone on the AT Protocol network by name or handle — every result is a real, verified identity."
                )
            } else if searching && results.isEmpty {
                ProgressView().tint(Theme.accent)
            } else if results.isEmpty {
                EmptyStateView(icon: "magnifyingglass",
                               title: "No people found",
                               message: "Try a different name or handle.")
            } else {
                List {
                    ForEach(results) { actor in
                        Button { selected = actor } label: { BskyActorRow(actor: actor) }
                            .buttonStyle(.plain)
                            .listRowBackground(Theme.bgSecondary)
                            .listRowSeparatorTint(Theme.border)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search people")
        .onChange(of: query) { runSearch() }
        .sheet(item: $selected) { actor in
            UserProfileSheet(nick: actor.handle, directActor: actor.did)
        }
    }

    private func runSearch() {
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { results = []; searching = false; return }
        searching = true
        searchTask = Task {
            // Small debounce so we don't fire a request per keystroke.
            try? await Task.sleep(nanoseconds: 280_000_000)
            if Task.isCancelled { return }
            let found = await BlueskyGraph.searchActors(q)
            if Task.isCancelled { return }
            results = found
            searching = false
        }
    }
}
