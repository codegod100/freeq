import SwiftUI

/// "What did I miss?" across every channel with unread messages — each summed
/// up in one on-device sentence. The Apple-Intelligence catch-up, but for your
/// whole freeq at once, and still entirely private (nothing leaves the phone).
struct CatchUpDigestSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss

    struct Item: Identifiable {
        let channel: String
        let unread: Int
        var summary: String?
        var id: String { channel }
    }

    @State private var items: [Item] = []
    @State private var done = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bgPrimary.ignoresSafeArea()
                RadialGradient(colors: [Theme.accent.opacity(0.12), .clear],
                               center: .top, startRadius: 0, endRadius: 300)
                    .ignoresSafeArea()

                if items.isEmpty && done {
                    EmptyStateView(icon: "checkmark.circle",
                                   title: "You're all caught up",
                                   message: "No unread channels to summarize.")
                } else {
                    ScrollView {
                        VStack(spacing: 10) {
                            ForEach(items) { item in
                                Button {
                                    dismiss()
                                    appState.pendingChannelNav = item.channel
                                } label: {
                                    row(item)
                                }
                                .buttonStyle(.plain)
                            }
                            HStack(spacing: 6) {
                                Image(systemName: "lock.fill").font(.system(size: 10))
                                Text("Summarized on your device with Apple Intelligence — nothing left the phone.")
                                    .font(.fqCaption2)
                            }
                            .foregroundColor(Theme.textMuted)
                            .padding(.top, 6)
                        }
                        .padding(Theme.Space.lg)
                    }
                }
            }
            .navigationTitle("Catch me up")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.foregroundColor(Theme.accent)
                }
                ToolbarItem(placement: .principal) {
                    Text("Catch me up")
                        .font(.fqHeadline).foregroundColor(Theme.textPrimary)
                }
            }
        }
        .preferredColorScheme(.dark)
        .task { await run() }
    }

    private func row(_ item: Item) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.accent.opacity(0.14)).frame(width: 40, height: 40)
                Text("#").font(.fqTitle3.weight(.bold)).foregroundColor(Theme.accent)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.channel)
                        .font(.fqSubheadline.weight(.semibold))
                        .foregroundColor(Theme.textPrimary)
                    Text("\(item.unread) new")
                        .font(.fqCaption2.weight(.bold))
                        .foregroundColor(Theme.accent)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Theme.accent.opacity(0.14), in: Capsule())
                    Spacer()
                }
                if let s = item.summary {
                    Text(s)
                        .font(.fqFootnote)
                        .foregroundColor(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.6).tint(Theme.textMuted)
                        Text("Reading the room…")
                            .font(.fqCaption).foregroundColor(Theme.textMuted)
                    }
                }
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.textMuted)
                .padding(.top, 2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(.thin)
    }

    private func run() async {
        // Seed rows immediately (with spinners), then fill summaries one channel
        // at a time — the on-device model runs best serially.
        let unread = appState.channels
            .compactMap { ch -> Item? in
                let n = appState.unreadCounts[ch.name] ?? 0
                return n > 0 ? Item(channel: ch.name, unread: n, summary: nil) : nil
            }
            .sorted { $0.unread > $1.unread }
        items = unread
        for (i, item) in unread.enumerated() {
            guard let ch = appState.channels.first(where: { $0.name == item.channel }) else { continue }
            let summary = await IntelligenceService.shared.summarize(ch.messages, in: item.channel)
            if i < items.count {
                items[i].summary = summary ?? "Couldn't summarize this one."
            }
        }
        done = true
    }
}
