import SwiftUI

/// Live channel from server API
struct ServerChannel: Identifiable {
    let name: String
    let topic: String
    let memberCount: Int
    var id: String { name }
}

enum DiscoverMode: Hashable { case channels, people }

/// Discovery — browse channels, or find people across the verified AT Protocol
/// graph.
struct DiscoverTab: View {
    @EnvironmentObject var appState: AppState
    @State private var mode: DiscoverMode = .channels
    @State private var channelInput = ""
    @State private var serverChannels: [ServerChannel] = []
    @State private var loading = true
    @State private var searchText = ""
    @State private var peopleChannels: [ChannelPeople] = []
    @FocusState private var joinFocused: Bool

    struct ChannelPeople: Identifiable {
        let channel: String
        let people: [FreeqPerson]
        var id: String { channel }
    }

    private var filteredChannels: [ServerChannel] {
        let channels = serverChannels
        if searchText.isEmpty { return channels }
        let q = searchText.lowercased()
        return channels.filter {
            $0.name.lowercased().contains(q) ||
            $0.topic.lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bgPrimary.ignoresSafeArea()

                VStack(spacing: 0) {
                    Picker("View", selection: $mode) {
                        Text("Channels").tag(DiscoverMode.channels)
                        Text("People").tag(DiscoverMode.people)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                    if mode == .people {
                        PeopleSearchView()
                    } else {
                    // Search bar (always visible at top)
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 15))
                            .foregroundColor(Theme.textMuted)

                        TextField("", text: $searchText, prompt: Text("Search channels...").foregroundColor(Theme.textMuted))
                            .foregroundColor(Theme.textPrimary)
                            .font(.fqCallout)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .submitLabel(.search)

                        if !searchText.isEmpty {
                            Button(action: { searchText = "" }) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 16))
                                    .foregroundColor(Theme.textMuted)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Theme.bgSecondary)
                    .cornerRadius(12)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 4)

                    // Quick join bar
                    HStack(spacing: 8) {
                        Text("#")
                            .font(.fqMono.weight(.medium))
                            .foregroundColor(Theme.textMuted)

                        TextField("", text: $channelInput, prompt: Text("Join by name...").foregroundColor(Theme.textMuted))
                            .foregroundColor(Theme.textPrimary)
                            .font(.fqSubheadline)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .submitLabel(.join)
                            .focused($joinFocused)
                            .onSubmit { joinCustom() }

                        if !channelInput.isEmpty {
                            Button(action: joinCustom) {
                                Text("Join")
                                    .font(.fqFootnote.weight(.semibold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 6)
                                    .background(Theme.accent)
                                    .cornerRadius(8)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Theme.bgSecondary.opacity(0.5))

                    Rectangle().fill(Theme.border).frame(height: 1)

                    // Channel list
                    if loading && serverChannels.isEmpty {
                        Spacer()
                        VStack(spacing: 12) {
                            ProgressView().tint(Theme.accent).scaleEffect(1.1)
                            Text("Loading channels...")
                                .font(.fqFootnote)
                                .foregroundColor(Theme.textMuted)
                        }
                        Spacer()
                    } else if filteredChannels.isEmpty {
                        Spacer()
                        VStack(spacing: 12) {
                            Image(systemName: searchText.isEmpty ? "bubble.left.and.bubble.right" : "magnifyingglass")
                                .font(.system(size: 36))
                                .foregroundColor(Theme.textMuted)
                            if searchText.isEmpty {
                                Text("No active channels")
                                    .font(.fqCallout.weight(.medium))
                                    .foregroundColor(Theme.textSecondary)
                            } else {
                                Text("No channels matching \"\(searchText)\"")
                                    .font(.fqSubheadline)
                                    .foregroundColor(Theme.textSecondary)
                                Button("Create #\(searchText)") {
                                    channelInput = searchText
                                    joinCustom()
                                }
                                .font(.fqFootnote.weight(.medium))
                                .foregroundColor(Theme.accent)
                            }
                        }
                        Spacer()
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                // "Where your people are" — channels your freeq
                                // follows are in. The graph, pointing you at rooms.
                                if searchText.isEmpty && !peopleChannels.isEmpty {
                                    peopleChannelsSection
                                }

                                // Result count
                                if !searchText.isEmpty {
                                    HStack {
                                        Text("\(filteredChannels.count) result\(filteredChannels.count == 1 ? "" : "s")")
                                            .font(.fqCaption)
                                            .foregroundColor(Theme.textMuted)
                                        Spacer()
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.top, 8)
                                    .padding(.bottom, 4)
                                }

                                if searchText.isEmpty && !peopleChannels.isEmpty {
                                    sectionLabel("All channels")
                                }
                                ForEach(filteredChannels) { ch in
                                    channelRow(ch)
                                }
                            }
                            .padding(.bottom, 16)
                        }
                        .refreshable { await fetchChannels(); await loadPeopleChannels() }
                    }
                    } // end mode == .channels
                }
            }
            .navigationTitle("Discover")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .task { await fetchChannels() }
        .task { await loadPeopleChannels() }
    }

    // MARK: - Where your people are

    private var peopleChannelsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("Where your people are")
            ForEach(peopleChannels) { cp in
                Button {
                    channelInput = cp.channel
                    joinCustom()
                } label: {
                    HStack(spacing: 12) {
                        facepile(cp.people)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(cp.channel)
                                .font(.fqSubheadline.weight(.semibold))
                                .foregroundColor(Theme.textPrimary)
                            Text(peopleSummary(cp.people))
                                .font(.fqCaption)
                                .foregroundColor(Theme.textMuted)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.right.circle")
                            .font(.system(size: 18))
                            .foregroundColor(Theme.accent)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func facepile(_ people: [FreeqPerson]) -> some View {
        HStack(spacing: -10) {
            ForEach(Array(people.prefix(3))) { p in
                BskyAvatar(urlString: p.actor.avatar, seed: p.actor.handle, size: 32)
                    .overlay(Circle().strokeBorder(Theme.bgPrimary, lineWidth: 2))
            }
        }
    }

    private func peopleSummary(_ people: [FreeqPerson]) -> String {
        let names = people.prefix(2).map { $0.actor.title }
        let extra = people.count - names.count
        let base = names.joined(separator: ", ")
        if extra > 0 { return "\(base) +\(extra) you follow" }
        return "\(base) you follow"
    }

    private func sectionLabel(_ text: String) -> some View {
        HStack {
            Text(text.uppercased())
                .font(.fqCaption2.weight(.bold))
                .foregroundColor(Theme.textMuted)
                .kerning(0.6)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private func loadPeopleChannels() async {
        guard let myDID = appState.authenticatedDID else { return }
        let follows = await BlueskyGraph.follows(of: myDID, limit: 100)
        let people = await PeopleResolver.resolve(follows, viewer: myDID).filter { $0.onFreeq }
        // Accumulate: channel -> the people I follow who are in it.
        var byChannel: [String: [FreeqPerson]] = [:]
        for person in people {
            for ch in person.identity?.channels ?? [] where ch.hasPrefix("#") {
                byChannel[ch, default: []].append(person)
            }
        }
        // Rank by how many of my people are there; surface the top handful.
        let ranked = byChannel
            .map { ChannelPeople(channel: $0.key, people: $0.value) }
            .sorted { $0.people.count > $1.people.count }
            .prefix(6)
        peopleChannels = Array(ranked)
    }

    private func channelRow(_ ch: ServerChannel) -> some View {
        let joined = appState.channels.contains { $0.name.lowercased() == ch.name.lowercased() }

        return Button(action: {
            appState.joinChannel(ch.name)
            // Switch to Chats tab
            if joined {
                appState.activeChannel = ch.name
            }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }) {
            HStack(spacing: 12) {
                // Channel icon
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Theme.accent.opacity(joined ? 0.2 : 0.1))
                        .frame(width: 48, height: 48)
                    Text("#")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundColor(Theme.accent.opacity(joined ? 1 : 0.7))
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(ch.name)
                            .font(.fqCallout.weight(.medium))
                            .foregroundColor(Theme.textPrimary)

                        HStack(spacing: 3) {
                            Image(systemName: "person.2.fill")
                                .font(.system(size: 9))
                            Text("\(ch.memberCount)")
                                .font(.fqCaption)
                        }
                        .foregroundColor(Theme.textMuted)
                    }

                    if !ch.topic.isEmpty {
                        Text(ch.topic)
                            .font(.fqFootnote)
                            .foregroundColor(Theme.textSecondary)
                            .lineLimit(2)
                    }
                }

                Spacer()

                if joined {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(Theme.success)
                } else {
                    Text("Join")
                        .font(.fqFootnote.weight(.semibold))
                        .foregroundColor(Theme.accent)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background(Theme.accent.opacity(0.12))
                        .cornerRadius(8)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
    }

    private func fetchChannels() async {
        loading = true
        defer { loading = false }

        guard let url = URL(string: "\(ServerConfig.apiBaseUrl)/api/v1/channels") else { return }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 8
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                let channels = json.compactMap { ch -> ServerChannel? in
                    guard let name = ch["name"] as? String else { return nil }
                    let topic = ch["topic"] as? String ?? ""
                    let members = ch["member_count"] as? Int ?? ch["members"] as? Int ?? 0
                    return ServerChannel(name: name, topic: topic, memberCount: members)
                }
                .filter { $0.memberCount > 0 }
                .sorted { $0.memberCount > $1.memberCount }

                await MainActor.run { serverChannels = channels }
            }
        } catch { }
    }

    private func joinCustom() {
        let name = channelInput.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let channel = name.hasPrefix("#") ? name : "#\(name)"
        appState.joinChannel(channel)
        channelInput = ""
        joinFocused = false
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        ToastManager.shared.show("Joining \(channel)", icon: "number")
    }
}
