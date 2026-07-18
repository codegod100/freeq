import SwiftUI

struct BufferListView: View {
    @EnvironmentObject var watch: WatchSession

    var body: some View {
        NavigationStack {
            Group {
                if let snap = watch.snapshot, !snap.buffers.isEmpty {
                    List {
                        ForEach(sortedBuffers(snap.buffers)) { b in
                            NavigationLink(value: b.name) {
                                BufferRow(buffer: b)
                            }
                        }
                    }
                    .listStyle(.carousel)
                } else if watch.snapshot == nil {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("Connecting…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("No conversations yet")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("freeq")
            .navigationDestination(for: String.self) { name in
                BufferDetailView(bufferName: name)
            }
        }
    }

    private func sortedBuffers(_ buffers: [WatchBufferSummary]) -> [WatchBufferSummary] {
        buffers
            .filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
            .sorted { a, b in
                let aT = a.lastAt ?? .distantPast
                let bT = b.lastAt ?? .distantPast
                return aT > bT
            }
    }
}

private struct BufferRow: View {
    let buffer: WatchBufferSummary

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(buffer.isChannel ? Color.blue.opacity(0.25) : Color.green.opacity(0.25))
                    .frame(width: 28, height: 28)
                Text(buffer.isChannel ? "#" : "@")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(buffer.isChannel ? .blue : .green)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(buffer.isChannel ? buffer.name : "@\(buffer.name)")
                    .font(.system(size: 13, weight: buffer.unread > 0 ? .semibold : .regular))
                    .lineLimit(1)
                if let from = buffer.lastFrom, let text = buffer.lastText {
                    Text("\(from): \(text)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if buffer.unread > 0 {
                Text("\(buffer.unread)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.blue)
                    .clipShape(Capsule())
            }
        }
    }
}
