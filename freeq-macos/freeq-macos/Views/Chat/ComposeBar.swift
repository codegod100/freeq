import SwiftUI

struct ComposeBar: View {
    @Environment(AppState.self) private var appState
    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    private var isEditing: Bool { appState.editingMessageId != nil }
    private var isReplying: Bool { appState.replyingToMessage != nil }

    var body: some View {
        VStack(spacing: 0) {
            // Reply/Edit banner
            if let reply = appState.replyingToMessage {
                HStack(spacing: 6) {
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .font(.caption)
                        .foregroundColor(.accentColor)
                    Text("Replying to **\(reply.from)**")
                        .font(.caption)
                    Text(reply.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button { appState.replyingToMessage = nil } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.05))
            }

            if isEditing {
                HStack(spacing: 6) {
                    Image(systemName: "pencil")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text("Editing message")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button {
                        appState.editingMessageId = nil
                        appState.editingText = nil
                        text = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.05))
            }

            HStack(alignment: .bottom, spacing: 8) {
                // Text editor
                ZStack(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Message \(appState.activeChannel ?? "")…")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 8)
                    }
                    ComposeTextView(text: $text, onSubmit: send, onUpArrow: editLastMessage)
                        .frame(minHeight: 32, maxHeight: 120)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(4)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
                )

                // Send button
                Button { send() } label: {
                    Image(systemName: isEditing ? "checkmark.circle.fill" : "arrow.up.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundColor(text.isEmpty ? .gray : (isEditing ? .orange : .accentColor))
                }
                .buttonStyle(.plain)
                .disabled(text.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(.bar)
        .onChange(of: text) { _, newValue in
            if !newValue.isEmpty, let target = appState.activeChannel {
                appState.sendTyping(target: target)
            }
        }
        .onChange(of: appState.editingText) { _, newValue in
            if let newValue {
                text = newValue
            }
        }
    }

    private func send() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let target = appState.activeChannel else { return }

        // Editing mode
        if let editId = appState.editingMessageId {
            appState.editMessage(target: target, msgId: editId, newText: trimmed)
            appState.editingMessageId = nil
            appState.editingText = nil
            text = ""
            return
        }

        // Handle slash commands
        if trimmed.hasPrefix("/") {
            handleCommand(trimmed, target: target)
            text = ""
            return
        }

        // Normal messages (split multi-line)
        let replyId = appState.replyingToMessage?.id
        for line in trimmed.components(separatedBy: .newlines) {
            let l = line.trimmingCharacters(in: .whitespaces)
            if !l.isEmpty {
                if let replyId {
                    appState.sendRaw("@+reply=\(replyId) PRIVMSG \(target) :\(l)")
                    appState.replyingToMessage = nil
                } else {
                    appState.sendMessage(to: target, text: l)
                }
            }
        }
        text = ""
    }

    private func editLastMessage() {
        guard text.isEmpty, let target = appState.activeChannel else { return }
        if let lastMsg = appState.lastOwnMessage(in: target) {
            appState.editingMessageId = lastMsg.id
            appState.editingText = lastMsg.text
            text = lastMsg.text
        }
    }

    private func handleCommand(_ input: String, target: String) {
        let parts = input.dropFirst().split(separator: " ", maxSplits: 1)
        let cmd = parts.first.map(String.init)?.lowercased() ?? ""
        let arg = parts.count > 1 ? String(parts[1]) : ""

        switch cmd {
        case "join", "j":
            arg.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .forEach { appState.joinChannel(String($0)) }
        case "part", "leave":
            appState.partChannel(arg.isEmpty ? target : arg)
        case "topic", "t":
            if !arg.isEmpty { appState.sendRaw("TOPIC \(target) :\(arg)") }
        case "nick":
            if !arg.isEmpty { appState.sendRaw("NICK \(arg)") }
        case "me", "action":
            if !arg.isEmpty { appState.sendAction(to: target, text: arg) }
        case "msg", "query":
            let mp = arg.split(separator: " ", maxSplits: 1)
            if mp.count == 2 {
                let dmTarget = String(mp[0])
                appState.sendMessage(to: dmTarget, text: String(mp[1]))
                let dm = appState.getOrCreateDM(dmTarget)
                appState.activeChannel = dm.name
            }
        case "kick", "k":
            let kp = arg.split(separator: " ", maxSplits: 1)
            if let user = kp.first {
                appState.kickUser(target, String(user), reason: kp.count > 1 ? String(kp[1]) : nil)
            }
        case "op":
            if !arg.isEmpty { appState.setMode(target, "+o", arg) }
        case "deop":
            if !arg.isEmpty { appState.setMode(target, "-o", arg) }
        case "voice":
            if !arg.isEmpty { appState.setMode(target, "+v", arg) }
        case "invite":
            if !arg.isEmpty { appState.inviteUser(target, arg) }
        case "away":
            appState.setAway(arg.isEmpty ? nil : arg)
        case "whois", "wi":
            if !arg.isEmpty { appState.sendWhois(arg) }
        case "mode", "m":
            if !arg.isEmpty {
                appState.sendRaw("MODE \(arg.hasPrefix("#") ? "" : "\(target) ")\(arg)")
            }
        case "raw", "quote":
            appState.sendRaw(arg)
        case "p2p":
            handleP2pCommand(arg)
        case "help":
            let ch = appState.activeChannelState
            let help = [
                "── Commands ──",
                "/join #channel · /part · /topic text",
                "/kick user · /op user · /voice user · /invite user",
                "/whois user · /away reason · /me action",
                "/msg user text · /mode +o user · /raw IRC_LINE",
                "/p2p start|id|connect|peers",
                "── Shortcuts ──",
                "⌘K quick switch · ⌘J join · ↑ edit last · Esc cancel edit"
            ]
            for line in help {
                ch?.appendIfNew(ChatMessage(
                    id: UUID().uuidString, from: "system", text: line,
                    isAction: false, timestamp: Date(), replyTo: nil
                ))
            }
        default:
            appState.sendRaw("\(cmd.uppercased())\(arg.isEmpty ? "" : " \(arg)")")
        }
    }

    private func handleP2pCommand(_ arg: String) {
        let parts = arg.split(separator: " ", maxSplits: 1)
        let subcmd = parts.first.map(String.init) ?? ""
        let ch = appState.activeChannelState

        switch subcmd {
        case "start":
            appState.startP2p()
            ch?.appendIfNew(ChatMessage(id: UUID().uuidString, from: "system",
                text: "P2P subsystem starting…", isAction: false, timestamp: Date(), replyTo: nil))
        case "id":
            if let id = appState.p2pEndpointId {
                ch?.appendIfNew(ChatMessage(id: UUID().uuidString, from: "system",
                    text: "Your iroh endpoint: \(id)", isAction: false, timestamp: Date(), replyTo: nil))
            } else {
                ch?.appendIfNew(ChatMessage(id: UUID().uuidString, from: "system",
                    text: "P2P not active. Use /p2p start", isAction: false, timestamp: Date(), replyTo: nil))
            }
        case "connect":
            if parts.count > 1 {
                appState.connectP2pPeer(String(parts[1]))
            }
        case "peers":
            let peers = appState.p2pConnectedPeers
            let msg = peers.isEmpty ? "No P2P peers connected" : "P2P peers: \(peers.joined(separator: ", "))"
            ch?.appendIfNew(ChatMessage(id: UUID().uuidString, from: "system",
                text: msg, isAction: false, timestamp: Date(), replyTo: nil))
        default:
            ch?.appendIfNew(ChatMessage(id: UUID().uuidString, from: "system",
                text: "P2P commands: start, id, connect <endpoint>, peers", isAction: false, timestamp: Date(), replyTo: nil))
        }
    }
}

/// NSTextView wrapper that handles Enter vs Shift+Enter and Up arrow.
struct ComposeTextView: NSViewRepresentable {
    @Binding var text: String
    var onSubmit: () -> Void
    var onUpArrow: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let textView = ComposeNSTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.submitAction = onSubmit
        textView.upArrowAction = onUpArrow

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? ComposeNSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
        textView.submitAction = onSubmit
        textView.upArrowAction = onUpArrow
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        let parent: ComposeTextView

        init(parent: ComposeTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}

class ComposeNSTextView: NSTextView {
    var submitAction: (() -> Void)?
    var upArrowAction: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        // Enter without Shift = send
        if event.keyCode == 36 && !event.modifierFlags.contains(.shift) {
            submitAction?()
            return
        }
        // Up arrow when cursor is at start and text is empty = edit last
        if event.keyCode == 126 && string.isEmpty {
            upArrowAction?()
            return
        }
        // Escape = cancel edit
        if event.keyCode == 53 {
            string = ""
            submitAction = nil  // Will be reset on next updateNSView
            // Post notification to cancel edit
            NotificationCenter.default.post(name: .cancelEdit, object: nil)
            return
        }
        super.keyDown(with: event)
    }
}

extension Notification.Name {
    static let cancelEdit = Notification.Name("cancelEdit")
}
