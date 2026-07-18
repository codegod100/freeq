import SwiftUI

struct BufferDetailView: View {
    @EnvironmentObject var watch: WatchSession
    @Environment(\.dismiss) var dismiss
    let bufferName: String

    @State private var sending = false
    @State private var lastError: String? = nil
    @State private var showingReplySheet = false
    @State private var replyText = ""

    private var messages: [WatchMessage] {
        watch.snapshot?.recent[bufferName] ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(messages) { m in
                            MessageRow(message: m, fromMe: m.from == watch.snapshot?.nick)
                                .id(m.msgid)
                        }
                    }
                    .padding(.horizontal, 6)
                }
                .onChange(of: messages.last?.msgid) { _, newId in
                    if let id = newId {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(id, anchor: .bottom)
                        }
                    }
                }
                .onAppear {
                    if let id = messages.last?.msgid {
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                }
            }

            // Reply via dictation/scribble. Sheet uses a TextField so the
            // user gets the system input method (which includes Dictate /
            // Scribble / emoji keyboard on watchOS).
            Button {
                replyText = ""
                showingReplySheet = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "mic.fill")
                    Text(sending ? "Sending…" : "Reply")
                        .font(.system(size: 13, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .disabled(sending)
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .padding(.horizontal, 6)
            .padding(.bottom, 4)
        }
        .navigationTitle(bufferName.hasPrefix("#") ? bufferName : "@\(bufferName)")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingReplySheet) {
            VStack(spacing: 8) {
                TextField("Reply", text: $replyText, axis: .vertical)
                    .lineLimit(1...4)
                Button("Send") {
                    let trimmed = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
                    showingReplySheet = false
                    guard !trimmed.isEmpty else { return }
                    Task {
                        await MainActor.run { sending = true }
                        let ok = await watch.sendMessage(target: bufferName, text: trimmed)
                        await MainActor.run {
                            sending = false
                            if !ok { lastError = "Couldn't send — check phone connection." }
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(8)
        }
        .alert("Send failed", isPresented: .constant(lastError != nil), actions: {
            Button("OK") { lastError = nil }
        }, message: { Text(lastError ?? "") })
    }
}

private struct MessageRow: View {
    let message: WatchMessage
    let fromMe: Bool

    var body: some View {
        VStack(alignment: fromMe ? .trailing : .leading, spacing: 2) {
            if !fromMe && !message.from.isEmpty {
                Text(message.from)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Text(message.text)
                .font(.system(size: 12))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(fromMe ? Color.green.opacity(0.25) : Color.gray.opacity(0.25))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .frame(maxWidth: .infinity, alignment: fromMe ? .trailing : .leading)
        }
    }
}
