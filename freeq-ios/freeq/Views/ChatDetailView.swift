import SwiftUI

/// Full-screen chat view — pushed from the chat list.
struct ChatDetailView: View {
    @EnvironmentObject var appState: AppState
    let channelName: String
    @State private var showingSearch = false
    // On-device "catch me up" summary.
    @State private var showingSummary = false
    @State private var summaryText: String? = nil
    @State private var summarizing = false
    @Environment(\.dismiss) var dismiss

    private var channelState: ChannelState? {
        appState.channels.first { $0.name == channelName }
            ?? appState.dmBuffers.first { $0.name == channelName }
    }

    private var isChannel: Bool { channelName.hasPrefix("#") }

    /// True when an AV call is active in *this* channel.
    private var isCallActiveHere: Bool {
        appState.isInCall && isChannel
            && appState.currentCallChannel?.lowercased() == channelName.lowercased()
    }

    var body: some View {
        ZStack {
            Theme.bgPrimary.ignoresSafeArea()

            VStack(spacing: 0) {
                // Connection status bar — always offer a Sign out escape
                // hatch when not registered, so a stuck saved session (bad
                // broker token, revoked refresh, etc.) doesn't trap the user.
                if appState.connectionState != .registered {
                    HStack(spacing: 8) {
                        if appState.connectionState == .connecting || appState.connectionState == .connected {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(0.7)
                        } else {
                            Image(systemName: "wifi.slash")
                                .font(.system(size: 12))
                        }
                        Text(appState.connectionState == .disconnected ? "Disconnected — pull down to reconnect" :
                             appState.connectionState == .connecting ? "Connecting..." : "Registering...")
                            .font(.fqFootnote.weight(.medium))
                        Spacer()
                        Button("Sign out") { appState.logout() }
                            .font(.fqFootnote.weight(.semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Color.white.opacity(0.18))
                            .clipShape(Capsule())
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(appState.connectionState == .disconnected ? Theme.danger : Theme.warning)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .animation(.easeInOut(duration: 0.3), value: appState.connectionState)
                }

                // Voice/video call panel — pinned above the message list
                // when an AV session is active in this channel.
                if isCallActiveHere {
                    CallView(channel: channelName)
                }

                // Message list + composer — hidden while the call is
                // expanded to fill the screen.
                if !(isCallActiveHere && appState.isCallExpanded) {
                    if let channel = channelState {
                        ZStack {
                            MessageListView(channel: channel)
                                .onTapGesture {
                                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                                }

                            // Member list slide-in
                            if appState.showMemberList {
                                HStack(spacing: 0) {
                                    Spacer()
                                    Color.black.opacity(0.3)
                                        .ignoresSafeArea()
                                        .onTapGesture { appState.showMemberList = false }
                                    MemberListView(channel: channel)
                                        .frame(width: 260)
                                        .transition(.move(edge: .trailing))
                                }
                                .animation(.easeInOut(duration: 0.2), value: appState.showMemberList)
                            }
                        }

                        ComposeView()
                    } else {
                        Spacer()
                        Text("Channel not found")
                            .foregroundColor(Theme.textMuted)
                        Spacer()
                    }
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        // Handoff: advertise the open conversation so it can resume on the
        // user's Mac/iPad. Routed by freeqApp's onContinueUserActivity.
        .userActivity(FreeqActivity.channel, isActive: !channelName.isEmpty) { activity in
            activity.title = channelName
            activity.userInfo = ["channel": channelName]
            activity.isEligibleForHandoff = true
            activity.targetContentIdentifier = channelName
        }
        .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(channelName)
                        .font(.fqCallout.weight(.semibold))
                        .foregroundColor(Theme.textPrimary)

                    if let channel = channelState {
                        if !channel.activeTypers.isEmpty {
                            Text(typingText(channel.activeTypers))
                                .font(.fqCaption2)
                                .foregroundColor(Theme.accent)
                        } else if !channel.topic.isEmpty {
                            Text(channel.topic)
                                .font(.fqCaption2)
                                .foregroundColor(Theme.textMuted)
                                .lineLimit(1)
                        } else if isChannel {
                            Text("\(channel.uniqueMemberCount) members")
                                .font(.fqCaption2)
                                .foregroundColor(Theme.textMuted)
                        }
                    }
                }
            }

            ToolbarItemGroup(placement: .topBarTrailing) {
                // Favorite toggle — pins this conversation to the top of the
                // list. Available for channels and DMs.
                Button(action: { appState.toggleFavorite(channelName) }) {
                    Image(systemName: appState.isFavorite(channelName) ? "star.fill" : "star")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(appState.isFavorite(channelName) ? .yellow : Theme.textSecondary)
                }
                .accessibilityLabel(appState.isFavorite(channelName) ? "Remove from favorites" : "Add to favorites")

                if isChannel {
                    // Voice call — green when in this call, accent when a
                    // session is active but we haven't joined, muted otherwise.
                    Button(action: { appState.startOrJoinVoice(channel: channelName) }) {
                        let inThisCall = appState.isInCall
                            && appState.currentCallChannel?.lowercased() == channelName.lowercased()
                        let sessionActive = appState.activeAvSessions[channelName.lowercased()] != nil
                        Image(systemName: inThisCall ? "speaker.wave.2.fill" : "speaker.wave.2")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(
                                inThisCall ? Theme.success
                                : (sessionActive ? Theme.accent : Theme.textSecondary)
                            )
                    }

                    Button(action: { showingSearch = true }) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 14))
                            .foregroundColor(Theme.textSecondary)
                    }

                    Button(action: { appState.showMemberList.toggle() }) {
                        Image(systemName: "person.2")
                            .font(.system(size: 14))
                            .foregroundColor(Theme.textSecondary)
                    }

                    // Catch me up — on-device summary of the recent conversation.
                    if IntelligenceService.shared.isAvailable {
                        Button(action: generateSummary) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Theme.signalGradient)
                        }
                        .accessibilityLabel("Catch me up")
                    }
                }
            }
        }
        .sheet(isPresented: $showingSummary) {
            CatchMeUpSheet(summary: summaryText, loading: summarizing)
                .presentationDetents([.height(260)])
                .presentationBackground(.ultraThinMaterial)
        }
        .onAppear {
            appState.activeChannel = channelName
            // Snapshot how much you missed BEFORE markRead clears it, so the
            // "while you were away" card knows there's a backlog to summarize.
            appState.awayCardCounts[channelName] = appState.unreadCounts[channelName] ?? 0
            appState.markRead(channelName)
        }
        .onDisappear {
            // Clear activeChannel so unread counting works for this channel
            if appState.activeChannel == channelName {
                appState.activeChannel = nil
            }
        }
        .sheet(isPresented: $showingSearch) {
            SearchSheet()
                .presentationDetents([.large])
        }
    }

    private func typingText(_ typers: [String]) -> String {
        switch typers.count {
        case 1: return "\(typers[0]) is typing..."
        case 2: return "\(typers[0]) and \(typers[1]) are typing..."
        default: return "Several people are typing..."
        }
    }

    private func generateSummary() {
        guard let messages = channelState?.messages, messages.count > 1 else {
            summaryText = "Not enough here to summarize yet."
            showingSummary = true
            return
        }
        summaryText = nil
        summarizing = true
        showingSummary = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task { @MainActor in
            // Stream it — the sentence types itself out live.
            let result = await IntelligenceService.shared.summarizeStreaming(messages, in: channelName) { partial in
                summaryText = partial
                summarizing = false
            }
            summarizing = false
            if (summaryText?.isEmpty ?? true) {
                summaryText = result ?? "Couldn't summarize this one."
            }
        }
    }
}

/// The "catch me up" result — a single on-device sentence, with a clear note
/// that inference never left the phone (freeq's whole ethos).
private struct CatchMeUpSheet: View {
    let summary: String?
    let loading: Bool

    var body: some View {
        VStack(spacing: Theme.Space.lg) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.signalGradient)
                Text("Catch me up")
                    .font(.fqTitle3.weight(.semibold))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
            }

            Group {
                if loading {
                    HStack(spacing: 10) {
                        ProgressView().tint(Theme.accent)
                        Text("Reading the room…")
                            .font(.fqSubheadline)
                            .foregroundColor(Theme.textSecondary)
                        Spacer()
                    }
                } else if let summary {
                    Text(summary)
                        .font(.fqBody)
                        .foregroundColor(Theme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10))
                Text("Summarized on your device — nothing left the phone.")
                    .font(.fqCaption)
            }
            .foregroundColor(Theme.textMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Theme.Space.xl)
    }
}
