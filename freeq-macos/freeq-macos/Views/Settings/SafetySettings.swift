import SwiftUI

// Safety UI (ported from the iOS client's Safety.swift): the report flow,
// the blocked-people manager, and the community-guidelines statement.
// The pure block-list decisions live in `Models/Safety.swift`.

extension View {
    /// A standard report flow: pick a reason → the content is hidden and the
    /// person blocked, and the report is recorded for moderation. Presented
    /// off an optional target binding.
    func reportDialog(_ target: Binding<ReportTarget?>,
                      onReport: @escaping (ReportTarget, String) -> Void) -> some View {
        confirmationDialog(
            "Report \(target.wrappedValue?.nick ?? "this")?",
            isPresented: Binding(get: { target.wrappedValue != nil },
                                 set: { if !$0 { target.wrappedValue = nil } }),
            titleVisibility: .visible,
            presenting: target.wrappedValue
        ) { t in
            ForEach(reportReasons, id: \.self) { reason in
                Button(reason, role: .destructive) {
                    onReport(t, reason)
                    target.wrappedValue = nil
                }
            }
            Button("Cancel", role: .cancel) { target.wrappedValue = nil }
        } message: { _ in
            Text("The content is hidden and this person is blocked. Reports are reviewed by our moderation team.")
        }
    }
}

/// Settings › Safety: manage blocked people and read the community guidelines.
struct SafetySettings: View {
    @Environment(AppState.self) private var appState

    private var blockedEntries: [String] {
        // Nicks are the human-readable handle; DIDs are the durable key. Show
        // nicks (there's always one when a block happened via the UI).
        appState.blockList.nicks.sorted()
    }

    var body: some View {
        Form {
            Section("Blocked") {
                if blockedEntries.isEmpty && appState.blockList.dids.isEmpty {
                    Text("No one blocked. People you block won't appear in channels or be able to DM you here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(blockedEntries, id: \.self) { nick in
                        HStack(spacing: 8) {
                            AvatarView(nick: nick, size: 22)
                            Text(nick)
                            Spacer()
                            Button("Unblock") {
                                appState.unblockUser(nick: nick, did: nil)
                            }
                        }
                    }
                }
            }

            Section("Community Guidelines") {
                Text("freeq has zero tolerance for objectionable content or abusive behavior.")
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)

                guideline("Be real", "Identity on freeq is verified. Impersonation, harassment, and hate have no place here.")
                guideline("No objectionable content", "Sexual, violent, illegal, or abusive content is prohibited and will be removed.")
                guideline("Report and block", "Anyone can report a message or block a person by right-clicking a message or from their profile. Reports are reviewed and abusive users are removed.")
                guideline("Consequences", "Accounts that violate these rules lose access. Because identity is a verified DID, bans are meaningful.")
            }

            Section("Report Abuse") {
                Link(destination: URL(string: "mailto:abuse@freeq.at")!) {
                    HStack(spacing: 6) {
                        Image(systemName: "envelope.fill")
                        Text("abuse@freeq.at")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func guideline(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption.weight(.semibold))
            Text(body)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
