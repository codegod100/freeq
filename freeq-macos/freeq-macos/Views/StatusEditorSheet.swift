import SwiftUI

/// Set a custom status — an emoji + a line — that rides freeq's native
/// presence (IRC AWAY) so everyone in your shared channels sees it on your
/// member row and profile. Real presence for real identities.
struct StatusEditorSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var emoji: String = ""
    @State private var text: String = ""
    @FocusState private var focused: Bool

    private let presets: [(emoji: String, text: String)] = [
        ("🛠️", "Building"),
        ("🎧", "In a call"),
        ("🧠", "Focusing"),
        ("☕️", "Coffee"),
        ("🌙", "Away"),
        ("🌴", "Out"),
    ]

    private var combined: String { SelfStatus.combined(emoji: emoji, text: text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Status")
                .font(.headline)

            // Live preview
            HStack(spacing: 10) {
                AvatarView(nick: appState.nick, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(appState.nick)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(combined.isEmpty ? "No status" : combined)
                        .font(.caption)
                        .foregroundStyle(combined.isEmpty ? Theme.textTertiary : Theme.textSecondary)
                }
                Spacer()
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surfaceSoft))

            // Editor
            HStack(spacing: 8) {
                TextField("😀", text: $emoji)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.center)
                    .frame(width: 44)
                    .onChange(of: emoji) { _, _ in emoji = String(emoji.prefix(2)) }
                TextField("What's your status?", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onChange(of: text) { _, _ in text = String(text.prefix(60)) }
                    .onSubmit { if !combined.isEmpty { save() } }
            }

            // Presets
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 6)], spacing: 6) {
                ForEach(presets, id: \.text) { p in
                    Button {
                        emoji = p.emoji
                        text = p.text
                    } label: {
                        HStack(spacing: 5) {
                            Text(p.emoji)
                            Text(p.text)
                                .font(.caption)
                                .foregroundStyle(Theme.textPrimary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Theme.surfaceSoft))
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()

            HStack {
                if appState.selfStatus != nil {
                    Button("Clear Status", role: .destructive) {
                        appState.setStatus(nil)
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Set Status") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(combined.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 340)
        .onAppear(perform: prime)
    }

    private func prime() {
        guard let current = appState.selfStatus, !current.isEmpty else {
            focused = true
            return
        }
        (emoji, text) = SelfStatus.split(current)
    }

    private func save() {
        appState.setStatus(combined)
        dismiss()
    }
}
