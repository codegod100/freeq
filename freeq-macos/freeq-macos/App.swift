import SwiftUI

@main
struct FreeqApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            MainView()
                .environment(appState)
                .frame(minWidth: 700, minHeight: 400)
                .onAppear {
                    // Auto-reconnect if we have a saved session
                    if appState.hasSavedSession && appState.connectionState == .disconnected {
                        appState.reconnectIfSaved()
                    }
                }
        }
        .commands {
            CommandGroup(after: .sidebar) {
                Button("Toggle Detail Panel") {
                    appState.showDetailPanel.toggle()
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            }

            CommandGroup(replacing: .newItem) {
                Button("Join Channel…") {
                    appState.showJoinSheet = true
                }
                .keyboardShortcut("j", modifiers: .command)

                Divider()

                // Quick channel switching ⌘1–9
                ForEach(1...9, id: \.self) { i in
                    Button("Switch to Buffer \(i)") {
                        appState.switchToChannelByIndex(i - 1)
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(i)")), modifiers: .command)
                }
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
}
