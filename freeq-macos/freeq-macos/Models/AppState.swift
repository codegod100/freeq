import Foundation
import SwiftUI

/// Connection transport type.
enum TransportType: Equatable {
    case tcp
    case tls
    case iroh
}

/// Connection state.
enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case registered
}

/// Main application state — bridges the Rust SDK to SwiftUI via @Observable.
@Observable
class AppState {
    // MARK: - Connection
    var connectionState: ConnectionState = .disconnected
    var transportType: TransportType = .tcp
    var nick: String = ""
    var serverAddress: String = "irc.freeq.at:6697"
    var authenticatedDID: String?
    var irohEndpointId: String?  // Server's iroh endpoint ID

    // MARK: - Channels & DMs
    var channels: [ChannelState] = []
    var dmBuffers: [ChannelState] = []
    var activeChannel: String? = nil
    var unreadCounts: [String: Int] = [:]
    var mentionCounts: [String: Int] = [:]
    var autoJoinChannels: [String] = ["#freeq"]

    // MARK: - P2P
    var p2pEndpointId: String?
    var p2pConnectedPeers: Set<String> = []
    var p2pDMActive: Set<String> = []  // nicks with active P2P connections

    // MARK: - UI State
    var showDetailPanel: Bool = true
    var showQuickSwitcher: Bool = false
    var showJoinSheet: Bool = false
    var errorMessage: String?

    // MARK: - Auth
    var authBrokerBase: String = "https://auth.freeq.at"
    var brokerToken: String?
    var pendingWebToken: String?

    // MARK: - Batches (CHATHISTORY)
    struct BatchBuffer {
        let target: String
        var messages: [ChatMessage]
    }
    var batches: [String: BatchBuffer] = [:]

    // MARK: - Names accumulator (353 lines come in multiple events)
    var pendingNames: [String: [MemberInfo]] = [:]

    // MARK: - Private
    private var client: FreeqClient?
    private var p2p: FreeqP2p?

    // MARK: - Computed

    var activeChannelState: ChannelState? {
        guard let name = activeChannel else { return nil }
        return channels.first { $0.name.lowercased() == name.lowercased() }
            ?? dmBuffers.first { $0.name.lowercased() == name.lowercased() }
    }

    var allBuffers: [ChannelState] {
        channels + dmBuffers
    }

    var totalUnread: Int {
        unreadCounts.values.reduce(0, +)
    }

    var isP2pActive: Bool { p2pEndpointId != nil }

    // MARK: - Init

    init() {
        loadSavedState()
    }

    private func loadSavedState() {
        if let saved = UserDefaults.standard.string(forKey: "freeq.nick") {
            nick = saved
        }
        if let saved = UserDefaults.standard.string(forKey: "freeq.server") {
            serverAddress = saved
        }
        if let saved = UserDefaults.standard.stringArray(forKey: "freeq.channels") {
            autoJoinChannels = saved
        }
        brokerToken = KeychainHelper.load(key: "brokerToken")
        authenticatedDID = KeychainHelper.load(key: "did")
    }

    // MARK: - Connection

    func connect(nick: String, webToken: String? = nil) {
        self.nick = nick
        connectionState = .connecting
        UserDefaults.standard.set(nick, forKey: "freeq.nick")

        let handler = AppEventHandler(appState: self)

        do {
            let c = try FreeqClient(
                server: serverAddress,
                nick: nick,
                handler: handler
            )
            self.client = c

            if let token = webToken ?? pendingWebToken {
                try c.setWebToken(token: token)
                pendingWebToken = nil
            }

            try c.setPlatform(platform: "macOS")
            try c.connect()
        } catch {
            connectionState = .disconnected
            errorMessage = "Connection failed: \(error.localizedDescription)"
        }
    }

    func disconnect() {
        client?.disconnect()
        client = nil
        connectionState = .disconnected
        shutdownP2p()
    }

    func reconnectIfSaved() {
        guard connectionState == .disconnected,
              !nick.isEmpty,
              brokerToken != nil else { return }

        Task {
            do {
                let session = try await BrokerAuth.fetchSession(
                    brokerBase: authBrokerBase,
                    brokerToken: brokerToken!
                )
                await MainActor.run {
                    self.pendingWebToken = session.token
                    self.authenticatedDID = session.did
                    KeychainHelper.save(key: "did", value: session.did)
                    self.connect(nick: session.nick)
                }
            } catch {
                // Silent retry later
            }
        }
    }

    // MARK: - Send

    func sendMessage(to target: String, text: String) {
        // Try P2P first for DMs
        if !target.hasPrefix("#"),
           let peerEndpoint = p2pEndpointForNick(target) {
            try? p2p?.sendMessage(peerId: peerEndpoint, text: text)

            // Echo locally
            let msg = ChatMessage(
                id: UUID().uuidString,
                from: nick,
                text: text,
                isAction: false,
                timestamp: Date(),
                replyTo: nil
            )
            getOrCreateDM(target).appendIfNew(msg)
            return
        }

        // Server-relayed
        do {
            try client?.sendMessage(target: target, text: text)
        } catch {
            errorMessage = "Send failed: \(error.localizedDescription)"
        }
    }

    func joinChannel(_ channel: String) {
        do {
            try client?.join(channel: channel)
        } catch {
            errorMessage = "Join failed: \(error.localizedDescription)"
        }
    }

    func partChannel(_ channel: String) {
        do {
            try client?.part(channel: channel)
            channels.removeAll { $0.name == channel }
            if activeChannel == channel {
                activeChannel = channels.first?.name
            }
        } catch {
            errorMessage = "Part failed: \(error.localizedDescription)"
        }
    }

    func sendRaw(_ line: String) {
        try? client?.sendRaw(line: line)
    }

    // MARK: - P2P (iroh)

    func startP2p() {
        guard p2p == nil else { return }
        let handler = AppP2pHandler(appState: self)
        do {
            let p2p = try FreeqP2p(handler: handler)
            self.p2p = p2p
            self.p2pEndpointId = try p2p.endpointId()
        } catch {
            errorMessage = "P2P start failed: \(error.localizedDescription)"
        }
    }

    func shutdownP2p() {
        p2p?.shutdown()
        p2p = nil
        p2pEndpointId = nil
        p2pConnectedPeers.removeAll()
        p2pDMActive.removeAll()
    }

    func connectP2pPeer(_ endpointId: String) {
        do {
            try p2p?.connectPeer(endpointId: endpointId)
        } catch {
            errorMessage = "P2P connect failed: \(error.localizedDescription)"
        }
    }

    /// Resolve a nick to a P2P endpoint ID (from WHOIS metadata or cache).
    private func p2pEndpointForNick(_ nick: String) -> String? {
        // TODO: maintain a nick -> iroh endpoint ID mapping
        // populated from WHOIS, CTCP, or user metadata
        nil
    }

    // MARK: - Channel helpers

    func getOrCreateChannel(_ name: String) -> ChannelState {
        let lower = name.lowercased()
        if let ch = channels.first(where: { $0.name.lowercased() == lower }) {
            return ch
        }
        let ch = ChannelState(name: name)
        channels.append(ch)
        channels.sort { $0.name.lowercased() < $1.name.lowercased() }
        return ch
    }

    func getOrCreateDM(_ nick: String) -> ChannelState {
        let lower = nick.lowercased()
        if let dm = dmBuffers.first(where: { $0.name.lowercased() == lower }) {
            return dm
        }
        let dm = ChannelState(name: nick)
        dmBuffers.append(dm)
        return dm
    }

    func switchToChannelByIndex(_ index: Int) {
        let all = allBuffers
        guard index < all.count else { return }
        activeChannel = all[index].name
    }

    func incrementUnread(_ channel: String) {
        guard channel.lowercased() != activeChannel?.lowercased() else { return }
        unreadCounts[channel.lowercased(), default: 0] += 1
    }

    func clearUnread(_ channel: String) {
        unreadCounts[channel.lowercased()] = 0
        mentionCounts[channel.lowercased()] = 0
    }

    /// Check if a nick is online by scanning shared channel member lists.
    func isNickOnline(_ nick: String) -> Bool {
        let lower = nick.lowercased()
        return channels.contains { ch in
            ch.members.contains { $0.nick.lowercased() == lower }
        }
    }

    func awayStatus(for nick: String) -> String? {
        let lower = nick.lowercased()
        for ch in channels {
            if let m = ch.members.first(where: { $0.nick.lowercased() == lower }) {
                return m.awayMsg
            }
        }
        return nil
    }
}

// MARK: - IRC Event Handler

/// Bridges FreeqEvent callbacks to AppState on MainActor.
class AppEventHandler: EventHandler {
    private weak var appState: AppState?

    init(appState: AppState) {
        self.appState = appState
    }

    func onEvent(event: FreeqEvent) {
        DispatchQueue.main.async { [weak self] in
            guard let state = self?.appState else { return }
            state.handleEvent(event)
        }
    }
}

extension AppState {
    func handleEvent(_ event: FreeqEvent) {
        switch event {
        case .connected:
            connectionState = .connected

        case .registered(let registeredNick):
            connectionState = .registered
            nick = registeredNick
            // Auto-join channels
            for ch in autoJoinChannels {
                joinChannel(ch)
            }
            // Request DM targets
            sendRaw("CHATHISTORY TARGETS * * 50")
            // Start P2P subsystem
            startP2p()

        case .authenticated(let did):
            authenticatedDID = did
            KeychainHelper.save(key: "did", value: did)

        case .authFailed(let reason):
            errorMessage = "Auth failed: \(reason)"

        case .joined(let channel, let joinNick):
            if joinNick.lowercased() == nick.lowercased() {
                let ch = getOrCreateChannel(channel)
                ch.members.removeAll()  // Clear stale members before NAMES
                pendingNames[channel.lowercased()] = []
                if activeChannel == nil || activeChannel == "server" {
                    activeChannel = ch.name
                }
            } else {
                if let ch = channels.first(where: { $0.name.lowercased() == channel.lowercased() }) {
                    if !ch.members.contains(where: { $0.nick.lowercased() == joinNick.lowercased() }) {
                        ch.members.append(MemberInfo(nick: joinNick, isOp: false, isHalfop: false, isVoiced: false, awayMsg: nil, did: nil))
                    }
                }
            }

        case .parted(let channel, let partNick):
            if partNick.lowercased() == nick.lowercased() {
                channels.removeAll { $0.name.lowercased() == channel.lowercased() }
            } else {
                if let ch = channels.first(where: { $0.name.lowercased() == channel.lowercased() }) {
                    ch.members.removeAll { $0.nick.lowercased() == partNick.lowercased() }
                }
            }

        case .message(let msg):
            let isAction = msg.isAction
            let message = ChatMessage(
                id: msg.msgid ?? UUID().uuidString,
                from: msg.fromNick,
                text: msg.text,
                isAction: isAction,
                timestamp: Date(timeIntervalSince1970: Double(msg.timestampMs) / 1000.0),
                replyTo: msg.replyTo,
                isEdited: msg.editOf != nil
            )

            // Handle batch (CHATHISTORY)
            if let batchId = msg.batchId, var batch = batches[batchId] {
                batch.messages.append(message)
                batches[batchId] = batch
                return
            }

            // Handle edit
            if let editOf = msg.replacesMsgid ?? msg.editOf {
                let target = msg.target
                let ch = target.hasPrefix("#")
                    ? channels.first { $0.name.lowercased() == target.lowercased() }
                    : dmBuffers.first { $0.name.lowercased() == target.lowercased() }
                ch?.applyEdit(originalId: editOf, newId: msg.msgid, newText: msg.text)
                return
            }

            // Route to channel or DM
            let target = msg.target
            if target.hasPrefix("#") {
                let ch = getOrCreateChannel(target)
                ch.appendIfNew(message)
                incrementUnread(target)
            } else {
                // DM — use sender's nick as buffer name (unless it's from us)
                let bufName = msg.fromNick.lowercased() == nick.lowercased() ? target : msg.fromNick
                let dm = getOrCreateDM(bufName)
                dm.appendIfNew(message)
                incrementUnread(bufName)
            }

        case .tagMsg(let tagMsg):
            // Handle typing, reactions, deletes via tag messages
            for tag in tagMsg.tags {
                if tag.key == "+draft/typing" {
                    let target = tagMsg.target
                    if let ch = channels.first(where: { $0.name.lowercased() == target.lowercased() }) {
                        ch.typingUsers[tagMsg.from] = Date()
                    }
                } else if tag.key == "+draft/react" {
                    // TODO: apply reaction
                } else if tag.key == "+draft/delete" {
                    let msgId = tag.value
                    for ch in allBuffers {
                        ch.applyDelete(msgId: msgId)
                    }
                }
            }

        case .names(let channel, let memberList):
            // 353 lines come in multiple events — accumulate until NamesEnd (366)
            let key = channel.lowercased()
            var existing = pendingNames[key] ?? []
            existing.append(contentsOf: memberList.map { m in
                MemberInfo(
                    nick: m.nick,
                    isOp: m.isOp,
                    isHalfop: m.isHalfop,
                    isVoiced: m.isVoiced,
                    awayMsg: m.awayMsg,
                    did: nil
                )
            })
            pendingNames[key] = existing

        case .topicChanged(let channel, let topic):
            if let ch = channels.first(where: { $0.name.lowercased() == channel.lowercased() }) {
                ch.topic = topic.text
                ch.topicSetBy = topic.setBy
            }

        case .modeChanged(_, _, _, _):
            break // TODO

        case .kicked(let channel, let kickedNick, _, _):
            if kickedNick.lowercased() == nick.lowercased() {
                channels.removeAll { $0.name.lowercased() == channel.lowercased() }
            } else {
                if let ch = channels.first(where: { $0.name.lowercased() == channel.lowercased() }) {
                    ch.members.removeAll { $0.nick.lowercased() == kickedNick.lowercased() }
                }
            }

        case .nickChanged(let oldNick, let newNick):
            if oldNick.lowercased() == nick.lowercased() {
                nick = newNick
            }
            for ch in allBuffers {
                if let idx = ch.members.firstIndex(where: { $0.nick.lowercased() == oldNick.lowercased() }) {
                    let old = ch.members[idx]
                    ch.members[idx] = MemberInfo(nick: newNick, isOp: old.isOp, isHalfop: old.isHalfop, isVoiced: old.isVoiced, awayMsg: old.awayMsg, did: old.did)
                }
            }

        case .awayChanged(let awayNick, let awayMsg):
            for ch in allBuffers {
                if let idx = ch.members.firstIndex(where: { $0.nick.lowercased() == awayNick.lowercased() }) {
                    let old = ch.members[idx]
                    ch.members[idx] = MemberInfo(nick: old.nick, isOp: old.isOp, isHalfop: old.isHalfop, isVoiced: old.isVoiced, awayMsg: awayMsg, did: old.did)
                }
            }

        case .userQuit(let quitNick, _):
            for ch in channels {
                ch.members.removeAll { $0.nick.lowercased() == quitNick.lowercased() }
            }

        case .batchStart(let id, _, let target):
            batches[id] = BatchBuffer(target: target, messages: [])

        case .batchEnd(let id):
            guard let batch = batches.removeValue(forKey: id) else { return }
            let target = batch.target
            let ch = target.hasPrefix("#") ? getOrCreateChannel(target) : getOrCreateDM(target)
            for msg in batch.messages.sorted(by: { $0.timestamp < $1.timestamp }) {
                ch.appendIfNew(msg)
            }

        case .chatHistoryTarget(let targetNick, _):
            let _ = getOrCreateDM(targetNick)

        case .notice(let text):
            // NamesEnd signal — flush pending members and request history
            if text.hasPrefix("__NAMES_END__") {
                let channel = String(text.dropFirst("__NAMES_END__".count))
                let key = channel.lowercased()
                if let members = pendingNames.removeValue(forKey: key),
                   let ch = channels.first(where: { $0.name.lowercased() == key }) {
                    ch.members = members
                }
                // Request chat history
                sendRaw("CHATHISTORY LATEST \(channel) * 50")
                break
            }
            if text.isEmpty { break }
            // Show in active channel or as system
            if let ch = activeChannelState {
                ch.appendIfNew(ChatMessage(
                    id: UUID().uuidString,
                    from: "server",
                    text: text,
                    isAction: false,
                    timestamp: Date(),
                    replyTo: nil
                ))
            }

        case .disconnected(let reason):
            connectionState = .disconnected
            if !reason.contains("intentional") {
                // Auto-reconnect after delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    self?.reconnectIfSaved()
                }
            }
        }
    }
}

// MARK: - P2P Event Handler

class AppP2pHandler: P2pEventHandler {
    private weak var appState: AppState?

    init(appState: AppState) {
        self.appState = appState
    }

    func onP2pEvent(event: P2pEvent) {
        DispatchQueue.main.async { [weak self] in
            guard let state = self?.appState else { return }
            state.handleP2pEvent(event)
        }
    }
}

extension AppState {
    func handleP2pEvent(_ event: P2pEvent) {
        switch event {
        case .endpointReady(let endpointId):
            p2pEndpointId = endpointId

        case .peerConnected(let peerId):
            p2pConnectedPeers.insert(peerId)

        case .peerDisconnected(let peerId):
            p2pConnectedPeers.remove(peerId)

        case .directMessage(let peerId, let text):
            let short = String(peerId.prefix(8))
            let dm = getOrCreateDM("p2p:\(short)")
            dm.appendIfNew(ChatMessage(
                id: UUID().uuidString,
                from: short,
                text: text,
                isAction: false,
                timestamp: Date(),
                replyTo: nil
            ))
            incrementUnread("p2p:\(short)")

        case .error(let message):
            errorMessage = "P2P: \(message)"
        }
    }
}
