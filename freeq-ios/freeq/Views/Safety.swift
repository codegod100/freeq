import SwiftUI

/// Who/what is being reported. Carried into the reason picker.
struct ReportTarget: Identifiable {
    let nick: String
    let did: String?
    var text: String? = nil
    var id: String { (did ?? nick) + (text ?? "") }
}

let reportReasons = [
    "Spam or scam",
    "Harassment or hate",
    "Sexual or explicit content",
    "Violence or threats",
    "Impersonation",
    "Something else",
]

extension View {
    /// A standard report flow: pick a reason → the content is hidden and the
    /// person blocked, and the report is recorded for moderation. Presented off
    /// an optional target binding.
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

/// Manage the people you've blocked. Reachable from Settings.
struct BlockedUsersView: View {
    @EnvironmentObject var appState: AppState

    private var entries: [String] {
        // Nicks are the human-readable handle; DIDs are the durable key. Show
        // nicks (there's always one when a block happened via the UI).
        appState.blockedNicks.sorted()
    }

    var body: some View {
        ZStack {
            Theme.bgPrimary.ignoresSafeArea()
            if entries.isEmpty && appState.blockedDIDs.isEmpty {
                EmptyStateView(icon: "hand.raised",
                               title: "No one blocked",
                               message: "People you block won't appear in channels or be able to DM you here.")
            } else {
                List {
                    ForEach(entries, id: \.self) { nick in
                        HStack(spacing: 12) {
                            UserAvatar(nick: nick, size: 36)
                            Text(nick)
                                .font(.fqSubheadline)
                                .foregroundColor(Theme.textPrimary)
                            Spacer()
                            Button("Unblock") {
                                appState.unblockUser(nick: nick, did: nil)
                            }
                            .font(.fqFootnote.weight(.semibold))
                            .foregroundColor(Theme.accent)
                        }
                        .listRowBackground(Theme.bgSecondary)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("Blocked")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }
}

/// The community-guidelines / no-tolerance statement App Review expects a UGC
/// app to surface, plus the abuse contact.
struct CommunityGuidelinesView: View {
    var body: some View {
        ZStack {
            Theme.bgPrimary.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    Text("freeq has zero tolerance for objectionable content or abusive behavior.")
                        .font(.fqTitle3.weight(.bold))
                        .foregroundColor(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)

                    Group {
                        guideline("Be real", "Identity on freeq is verified. Impersonation, harassment, and hate have no place here.")
                        guideline("No objectionable content", "Sexual, violent, illegal, or abusive content is prohibited and will be removed.")
                        guideline("Report and block", "Anyone can report a message or block a person from the ••• menu on a message or from their profile. Reports are reviewed and abusive users are removed.")
                        guideline("Consequences", "Accounts that violate these rules lose access. Because identity is a verified DID, bans are meaningful.")
                    }

                    Divider().background(Theme.border)

                    Text("Report abuse")
                        .font(.fqHeadline).foregroundColor(Theme.textPrimary)
                    Link(destination: URL(string: "mailto:abuse@freeq.at")!) {
                        HStack(spacing: 8) {
                            Image(systemName: "envelope.fill").foregroundColor(Theme.accent)
                            Text("abuse@freeq.at").font(.fqSubheadline).foregroundColor(Theme.accent)
                        }
                    }
                }
                .padding(Theme.Space.xl)
            }
        }
        .navigationTitle("Community Guidelines")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }

    private func guideline(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.fqSubheadline.weight(.semibold)).foregroundColor(Theme.textPrimary)
            Text(body).font(.fqFootnote).foregroundColor(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
