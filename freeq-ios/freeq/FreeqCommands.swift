import SwiftUI

/// Hardware-keyboard shortcuts (iPad and any device with a keyboard), mirroring
/// the macOS command set. Attached to the app's `WindowGroup` scene. On iPadOS
/// these register as key commands, discoverable by holding ⌘.
struct FreeqCommands: Commands {
    let appState: AppState

    var body: some Commands {
        CommandMenu("Navigate") {
            Button("Quick Switcher") { appState.showQuickSwitcher = true }
                .keyboardShortcut("k", modifiers: .command)
            Button("Search Messages") { appState.showSearchSheet = true }
                .keyboardShortcut("f", modifiers: .command)
            Button("Join Channel…") { appState.showJoinSheet = true }
                .keyboardShortcut("j", modifiers: .command)

            Divider()

            Button("Previous Channel") { appState.switchToAdjacentChannel(delta: -1) }
                .keyboardShortcut(.upArrow, modifiers: .option)
            Button("Next Channel") { appState.switchToAdjacentChannel(delta: 1) }
                .keyboardShortcut(.downArrow, modifiers: .option)
            Button("Previous Unread") { appState.switchToAdjacentChannel(delta: -1, unreadOnly: true) }
                .keyboardShortcut(.upArrow, modifiers: [.option, .shift])
            Button("Next Unread") { appState.switchToAdjacentChannel(delta: 1, unreadOnly: true) }
                .keyboardShortcut(.downArrow, modifiers: [.option, .shift])

            Divider()

            // ⌘1…⌘9 — switch to buffer N (sidebar order).
            ForEach(1...9, id: \.self) { n in
                Button("Switch to Buffer \(n)") { appState.switchToChannelByIndex(n - 1) }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
            }
        }

        CommandMenu("Favorites") {
            // ⌃⌘1…⌃⌘9 — go to favorite N.
            ForEach(1...9, id: \.self) { n in
                Button("Go to Favorite \(n)") { appState.switchToFavorite(n - 1) }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: [.control, .command])
            }
        }

        CommandGroup(replacing: .help) {
            Button("Keyboard Shortcuts") { appState.showShortcutsHelp = true }
                .keyboardShortcut("/", modifiers: .command)
        }
    }
}
