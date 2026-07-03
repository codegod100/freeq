import SwiftUI

/// User appearance override: follow the system (default), or pin light/dark.
enum AppearanceSetting: String, CaseIterable {
    case system, light, dark

    static var current: AppearanceSetting {
        AppearanceSetting(rawValue: UserDefaults.standard.string(forKey: "freeq.appearance") ?? "") ?? .system
    }

    /// Applies app-wide (main window, Settings scene, sheets, menus alike).
    func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

@main
struct FreeqApp: App {
    @State private var appState = AppState()
    @State private var showQuickSwitcher = false
    @State private var showBookmarks = false
    @State private var showChannelList = false
    @State private var showOnboarding = !UserDefaults.standard.bool(forKey: "freeq.onboardingComplete")
    @AppStorage("freeq.appearance") private var appearanceRaw = "system"

    var body: some Scene {
        WindowGroup {
            MainView()
                .environment(appState)
                .frame(minWidth: 700, minHeight: 400)
                .sheet(isPresented: $showQuickSwitcher) {
                    QuickSwitcher()
                        .environment(appState)
                }
                .sheet(isPresented: $showBookmarks) {
                    BookmarksPanel()
                        .environment(appState)
                }
                .sheet(isPresented: $showChannelList) {
                    ChannelListBrowser()
                        .environment(appState)
                }
                .sheet(isPresented: $showOnboarding) {
                    OnboardingView()
                }
                .onAppear {
                    AppearanceSetting.current.apply()
                    if appState.hasSavedSession && appState.connectionState == .disconnected {
                        appState.reconnectIfSaved()
                    }
                }
                .onChange(of: appearanceRaw) { _, _ in
                    AppearanceSetting.current.apply()
                }
                .onChange(of: appState.activeChannel) { _, newValue in
                    updateWindowTitle(newValue)
                }
                .onChange(of: appState.totalUnread) { _, newValue in
                    NSApplication.shared.dockTile.badgeLabel = newValue > 0 ? "\(newValue)" : nil
                }
        }
        .commands {
            CommandGroup(after: .sidebar) {
                Button("Toggle Detail Panel") {
                    appState.showDetailPanel.toggle()
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])

                Divider()

                // Slack-compatible channel navigation muscle memory.
                Button("Previous Channel") {
                    appState.switchToAdjacentChannel(.previous)
                }
                .keyboardShortcut(.upArrow, modifiers: .option)

                Button("Next Channel") {
                    appState.switchToAdjacentChannel(.next)
                }
                .keyboardShortcut(.downArrow, modifiers: .option)

                Button("Previous Unread Channel") {
                    appState.switchToAdjacentChannel(.previous, unreadOnly: true)
                }
                .keyboardShortcut(.upArrow, modifiers: [.option, .shift])

                Button("Next Unread Channel") {
                    appState.switchToAdjacentChannel(.next, unreadOnly: true)
                }
                .keyboardShortcut(.downArrow, modifiers: [.option, .shift])
            }

            CommandGroup(replacing: .newItem) {
                Button("Quick Switcher") {
                    showQuickSwitcher = true
                }
                .keyboardShortcut("k", modifiers: .command)

                Button("Search Messages") {
                    appState.showSearch.toggle()
                }
                .keyboardShortcut("f", modifiers: .command)

                Button("Bookmarks") {
                    showBookmarks = true
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])

                Button("Browse Channels") {
                    showChannelList = true
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])

                Button("Join Channel…") {
                    appState.showJoinSheet = true
                }
                .keyboardShortcut("j", modifiers: .command)

                Divider()

                ForEach(1...9, id: \.self) { i in
                    Button("Switch to Buffer \(i)") {
                        appState.switchToChannelByIndex(i - 1)
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(i)")), modifiers: .command)
                }
            }

            // In-call controls (Zoom's muscle memory: ⇧⌘M / ⇧⌘V / ⇧⌘S).
            CommandMenu("Call") {
                Button(appState.isMuted ? "Unmute" : "Mute") {
                    appState.toggleMute()
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(!appState.isInCall)

                Button(appState.isCameraOn ? "Stop Camera" : "Start Camera") {
                    appState.toggleCamera()
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .disabled(!appState.isInCall)

                Button(appState.isScreenSharing ? "Stop Sharing Screen" : "Share Screen") {
                    appState.toggleScreenShare()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(!appState.isInCall)

                Divider()

                Button(appState.isCallExpanded ? "Collapse Call" : "Expand Call") {
                    appState.isCallExpanded.toggle()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!appState.isInCall)

                Button("Leave Call") {
                    appState.leaveCall()
                }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                .disabled(!appState.isInCall)
            }

            CommandGroup(replacing: .help) {
                Button("freeq Help") {
                    if let ch = appState.activeChannelState {
                        ch.appendIfNew(ChatMessage(
                            id: UUID().uuidString, from: "system",
                            text: "Type /help for a list of commands",
                            isAction: false, timestamp: Date(), replyTo: nil
                        ))
                    }
                }
            }
        }

        Settings {
            SettingsView()
                .environment(appState)
        }
    }

    private func updateWindowTitle(_ channel: String?) {
        DispatchQueue.main.async {
            if let channel {
                NSApplication.shared.mainWindow?.title = "\(channel) — freeq"
            } else {
                NSApplication.shared.mainWindow?.title = "freeq"
            }
        }
    }
}
