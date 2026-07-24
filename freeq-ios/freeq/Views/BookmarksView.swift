import SwiftUI

/// Saved messages (parity with web + macOS). Tap to jump to the message in
/// its channel; swipe to remove.
struct BookmarksView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    private var sorted: [AppState.Bookmark] {
        appState.bookmarks.sorted { $0.timestamp > $1.timestamp }
    }

    var body: some View {
        List {
            if appState.bookmarks.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "bookmark")
                        .font(.system(size: 34))
                        .foregroundColor(Theme.textMuted)
                    Text("No saved messages")
                        .font(.fqHeadline)
                        .foregroundColor(Theme.textSecondary)
                    Text("Long-press a message and tap Bookmark.")
                        .font(.fqFootnote)
                        .foregroundColor(Theme.textMuted)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 48)
                .listRowBackground(Color.clear)
            } else {
                ForEach(sorted, id: \.msgId) { bm in
                    Button {
                        appState.activeChannel = bm.channel
                        dismiss()
                    } label: {
                        bookmarkRow(bm)
                    }
                    .listRowBackground(Theme.bgSecondary)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            appState.bookmarks.removeAll { $0.msgId == bm.msgId }
                        } label: {
                            Label("Remove", systemImage: "bookmark.slash")
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bgPrimary)
        .navigationTitle("Saved Messages")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func bookmarkRow(_ bm: AppState.Bookmark) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(bm.from.isEmpty ? "system" : bm.from)
                    .font(.fqFootnote.weight(.semibold))
                    .foregroundColor(Theme.accent)
                Text(bm.channel)
                    .font(.fqCaption2)
                    .foregroundColor(Theme.textMuted)
                Spacer()
                Text(bm.timestamp, style: .date)
                    .font(.fqCaption2)
                    .foregroundColor(Theme.textMuted)
            }
            Text(bm.text)
                .font(.fqSubheadline)
                .foregroundColor(Theme.textPrimary)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
        }
    }
}
