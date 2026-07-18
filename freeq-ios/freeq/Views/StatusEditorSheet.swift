import SwiftUI

/// Set a custom status — an emoji + a line — that rides freeq's native presence
/// (IRC AWAY) so everyone in your shared channels sees it on your avatar,
/// member row, and profile. Real presence for real identities.
struct StatusEditorSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss

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

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bgPrimary.ignoresSafeArea()
                VStack(spacing: Theme.Space.xl) {
                    // Live preview
                    HStack(spacing: 12) {
                        UserAvatar(nick: appState.nick, size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(appState.nick)
                                .font(.fqSubheadline.weight(.semibold))
                                .foregroundColor(Theme.textPrimary)
                            Text(combined.isEmpty ? "No status" : combined)
                                .font(.fqCaption)
                                .foregroundColor(combined.isEmpty ? Theme.textMuted : Theme.textSecondary)
                        }
                        Spacer()
                    }
                    .padding(14)
                    .glassCard(.thin)

                    // Editor
                    HStack(spacing: 10) {
                        TextField("😀", text: $emoji)
                            .font(.system(size: 22))
                            .multilineTextAlignment(.center)
                            .frame(width: 52, height: 46)
                            .background(Theme.bgSecondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .onChange(of: emoji) { emoji = String(emoji.prefix(2)) }
                        TextField("What's your status?", text: $text)
                            .font(.fqCallout)
                            .foregroundColor(Theme.textPrimary)
                            .focused($focused)
                            .padding(.horizontal, 14)
                            .frame(height: 46)
                            .background(Theme.bgSecondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .onChange(of: text) { text = String(text.prefix(60)) }
                    }

                    // Presets
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
                        ForEach(presets, id: \.text) { p in
                            Button {
                                emoji = p.emoji; text = p.text
                            } label: {
                                HStack(spacing: 6) {
                                    Text(p.emoji)
                                    Text(p.text).font(.fqFootnote).foregroundColor(Theme.textPrimary)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(Theme.bgSecondary, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Spacer()

                    Button(action: save) {
                        Text("Set status")
                            .font(.fqCalloutSemibold)
                            .foregroundColor(Color(hex: "04121a"))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Theme.signalGradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .disabled(combined.isEmpty)
                    .opacity(combined.isEmpty ? 0.5 : 1)
                }
                .padding(Theme.Space.xl)
            }
            .navigationTitle("Status")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundColor(Theme.textSecondary)
                }
                if appState.selfStatus != nil {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Clear") { appState.setStatus(nil); dismiss() }
                            .foregroundColor(Theme.danger)
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear(perform: prime)
    }

    private var combined: String {
        [emoji.trimmingCharacters(in: .whitespaces), text.trimmingCharacters(in: .whitespaces)]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func prime() {
        guard let current = appState.selfStatus, !current.isEmpty else { return }
        // Split a leading emoji off the saved "emoji text" form.
        if let first = current.unicodeScalars.first, first.properties.isEmoji,
           let firstChar = current.first {
            emoji = String(firstChar)
            text = String(current.dropFirst()).trimmingCharacters(in: .whitespaces)
        } else {
            text = current
        }
    }

    private func save() {
        appState.setStatus(combined)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        dismiss()
    }
}
