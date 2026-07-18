import SwiftUI

/// Three-column layout: Sidebar | Messages | Detail
struct MainView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Group {
            if appState.connectionState == .disconnected && appState.brokerToken == nil && appState.isLoadingSavedSession {
                restoringSessionView
            } else if appState.connectionState == .disconnected && appState.brokerToken == nil {
                ConnectView()
            } else if appState.connectionState == .connecting {
                connectingView
            } else {
                ZStack(alignment: .top) {
                    NavigationSplitView {
                        SidebarView()
                            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
                    } detail: {
                        VStack (spacing: 0) {
                            // Reconnect banner
                            if appState.connectionState == .disconnected && appState.hasSavedSession {
                                ReconnectBanner()
                            }

                            // Guest upgrade banner
                            if appState.connectionState == .registered && appState.authenticatedDID == nil {
                                GuestUpgradeBanner()
                            }
                            if appState.activeChannel != nil {
                                HStack(spacing: 0) {
                                    ChatView()
                                    if let threadRoot = appState.threadRootMessage,
                                       let channel = appState.activeChannel {
                                        Divider().overlay(Theme.borderSoft)
                                        ThreadView(rootMessage: threadRoot, channel: channel)
                                    }
                                    if appState.showDetailPanel {
                                        Divider().overlay(Theme.borderSoft)
                                        DetailPanel()
                                            .frame(width: 260)
                                    }
                                }
                            } else {
                                emptyState
                            }
                        }
                    }
                    .toolbar {
                        ToolbarItem(placement: .navigation) {
                            HStack(spacing: 8) {
                                Image("Logo")
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 20, height: 20)
                                    .accessibilityLabel("freeq")
                                connectionIndicator
                            }
                        }
                    }


                }
                .background(Theme.appBackground)
            }
        }
        .sheet(isPresented: Binding(
            get: { appState.showJoinSheet },
            set: { appState.showJoinSheet = $0 }
        )) {
            JoinChannelSheet()
        }
        .onReceive(NotificationCenter.default.publisher(for: .cancelEdit)) { _ in
            appState.editingMessageId = nil
            appState.editingText = nil
            appState.replyingToMessage = nil
        }
        .alert("Error", isPresented: Binding(
            get: { appState.errorMessage != nil },
            set: { if !$0 { appState.errorMessage = nil } }
        )) {
            Button("OK") { appState.errorMessage = nil }
        } message: {
            Text(appState.errorMessage ?? "")
        }
    }

    private var restoringSessionView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Restoring your session…")
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(32)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Theme.surface)
                .shadow(color: .black.opacity(0.06), radius: 18, y: 8)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.chatBackground)
    }

    private var connectingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Connecting to \(appState.serverAddress)…")
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(32)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Theme.surface)
                .shadow(color: .black.opacity(0.06), radius: 18, y: 8)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.chatBackground)
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(Theme.accentSoft)
                    .frame(width: 76, height: 76)
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
            VStack(spacing: 6) {
                Text("Choose a conversation")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Pick a channel or direct message from the sidebar.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }

            if appState.channels.isEmpty {
                Button {
                    appState.joinChannel("#freeq")
                } label: {
                    Label("Join #freeq", systemImage: "plus.bubble.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(Theme.accent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.chatBackground)
    }

    @ViewBuilder
    private var connectionIndicator: some View {
        HStack(spacing: 8) {
            Label {
                Text(statusText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.textSecondary)
            } icon: {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
            }

            if appState.isP2pActive || appState.transportType == .iroh {
                Divider()
                    .frame(height: 12)
                Label {
                    Text(p2pStatusText)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.textSecondary)
                } icon: {
                    Image(systemName: "lock.shield")
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Capsule().fill(Theme.surfaceSoft))
        .overlay(Capsule().strokeBorder(Theme.borderSoft, lineWidth: 1))
        .help(connectionHelp)
    }

    private var statusColor: Color {
        switch appState.connectionState {
        case .registered: Theme.success
        case .connected: Theme.warning
        case .connecting: Theme.warning
        // Quiet grey, not danger-red: disconnection auto-retries, and the
        // reconnect banner already says so. Red implies a terminal failure
        // that needs the user — this state doesn't.
        case .disconnected: Theme.textTertiary
        }
    }

    private var statusText: String {
        switch appState.connectionState {
        case .registered: "Online"
        case .connected: "Connected"
        case .connecting: "Connecting"
        case .disconnected: "Offline"
        }
    }

    private var p2pStatusText: String {
        let count = appState.p2pConnectedPeers.count
        if count == 1 { return "P2P 1 peer" }
        if count > 1 { return "P2P \(count) peers" }
        return "P2P ready"
    }

    private var connectionHelp: String {
        var parts = ["IRC \(statusText.lowercased()) via \(appState.transportType.label)"]
        if appState.isP2pActive {
            parts.append("P2P active via iroh")
        }
        return parts.joined(separator: " • ")
    }
}

private extension TransportType {
    var label: String {
        switch self {
        case .tcp: "TCP"
        case .tls: "TLS"
        case .iroh: "iroh"
        }
    }
}

// MARK: - Guest Upgrade Banner

struct GuestUpgradeBanner: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.badge.key")
                .font(.caption)
            Text("You're connected as a guest.")
                .font(.caption.weight(.medium))
            Text("Sign in with AT Protocol for DMs, history, and identity.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Sign In") {
                appState.disconnect()
                appState.brokerToken = nil
            }
            .font(.caption)
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.blue.opacity(0.1))
        .foregroundStyle(.blue)
    }
}

// MARK: - Reconnect Banner

/// Shown while the connection is down and auto-reconnect is running.
/// Deliberately calm: reconnection is automatic and usually succeeds in
/// seconds — the surface communicates *activity* (spinner + quiet text),
/// not emergency. A red wash here bled through the transparent titlebar
/// and made a routine blip look like an outage.
struct ReconnectBanner: View {
    @Environment(AppState.self) private var appState

    /// Repeated broker failures mean waiting won't help (wedged token or
    /// sign-in service down) — offer a fresh sign-in instead of spinning.
    private var brokerLooksStuck: Bool { appState.brokerFailureStreak >= 3 }

    var body: some View {
        HStack(spacing: 8) {
            if brokerLooksStuck {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                Text("Having trouble restoring your session.")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Button("Retry") {
                    appState.reconnectIfSaved()
                }
                .font(.caption)
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button("Sign In Again…") {
                    appState.logout()
                }
                .font(.caption)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            } else {
                ProgressView()
                    .controlSize(.small)
                Text("Reconnecting…")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.textSecondary)
                Text("You'll catch up automatically.")
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                Button("Retry Now") {
                    appState.reconnectIfSaved()
                }
                .font(.caption)
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(Theme.surfaceElevated)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}
