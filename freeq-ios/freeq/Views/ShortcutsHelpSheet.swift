import SwiftUI

/// ⌘/ — a reference of the iPad hardware-keyboard shortcuts.
struct ShortcutsHelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    private struct Shortcut: Identifiable {
        let id = UUID()
        let keys: String
        let title: String
    }

    private struct ShortcutSection: Identifiable {
        let id = UUID()
        let title: String
        let items: [Shortcut]
    }

    private let sections: [ShortcutSection] = [
        .init(title: "Navigation", items: [
            .init(keys: "⌘K", title: "Quick switcher"),
            .init(keys: "⌘F", title: "Search messages"),
            .init(keys: "⌘J", title: "Join channel"),
            .init(keys: "⌥↑ / ⌥↓", title: "Previous / next channel"),
            .init(keys: "⌥⇧↑ / ⌥⇧↓", title: "Previous / next unread"),
            .init(keys: "⌘1…⌘9", title: "Switch to buffer 1–9"),
            .init(keys: "⌃⌘1…⌃⌘9", title: "Go to favorite 1–9"),
        ]),
        .init(title: "Compose", items: [
            .init(keys: "⌘↩", title: "Send message"),
        ]),
        .init(title: "Help", items: [
            .init(keys: "⌘/", title: "This shortcuts list"),
        ]),
    ]

    var body: some View {
        NavigationStack {
            List {
                ForEach(sections) { section in
                    Section(section.title) {
                        ForEach(section.items) { s in
                            HStack {
                                Text(s.title)
                                Spacer()
                                Text(s.keys)
                                    .font(.callout.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Keyboard Shortcuts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
        }
    }
}
