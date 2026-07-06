import Foundation
import SwiftUI
import AVFoundation

extension ISO8601DateFormatter {
    static let freeqTargets: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

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
    var serverAddress: String = ServerConfig.ircServer
    var authenticatedDID: String?
    var irohEndpointId: String?
    var reconnectAttempts: Int = 0

    // MARK: - Channels & DMs
    var channels: [ChannelState] = []
    var dmBuffers: [ChannelState] = []
    var activeChannel: String? = nil {
        didSet {
            // Persist so the app reopens the last conversation on next launch —
            // but ONLY after launch restore has settled. During connect the
            // first-joined channel auto-selects (see `.joined`), and persisting
            // that transient pick would clobber the real last-open channel we
            // still need to restore.
            if didRestoreLastChannel, let activeChannel {
                UserDefaults.standard.set(activeChannel, forKey: LastChannel.key)
            }
        }
    }
    /// True once we've restored the last-open channel this launch, so a later
    /// channel joining doesn't re-hijack the user's current selection.
    @ObservationIgnored private var didRestoreLastChannel = false
    /// Guards the one-shot delayed fallback so it's scheduled only once.
    @ObservationIgnored private var restoreFallbackScheduled = false
    /// The last-open channel as persisted at launch, captured up front so the
    /// connect-time auto-selection can't overwrite it before we restore.
    @ObservationIgnored private var pendingRestoreTarget: String? =
        UserDefaults.standard.string(forKey: LastChannel.key)
    var unreadCounts: [String: Int] = [:]
    var mentionCounts: [String: Int] = [:]
    var autoJoinChannels: [String] = ["#freeq"]
    var closedDMs: Set<String> = [] {
        didSet { UserDefaults.standard.set(Array(closedDMs), forKey: "freeq.closedDMs") }
    }
    /// Passphrase channel E2EE (ENC1). Keys persist in the keychain; the
    /// policy itself is the unit-tested `ChannelE2eeState`.
    @ObservationIgnored var channelE2ee = ChannelE2eeState()

    // MARK: - Favorites, Muted, Bookmarks
    var favorites: Set<String> = []  // lowercase channel names
    var mutedChannels: Set<String> = []  // lowercase channel names
    /// Channels set to notify on mentions only (lowercase). The middle tier
    /// between "all" (default) and fully `mutedChannels`: regular messages
    /// don't notify, but a mention still does.
    var mentionOnlyChannels: Set<String> = []
    /// Our own away state (nil = present). Set optimistically on /away and
    /// confirmed by the server's away-notify echo.
    var selfAwayReason: String?
    /// The user's own custom status (emoji + text), carried over IRC AWAY so
    /// it broadcasts to everyone in shared channels natively. Persists across
    /// launches and is re-broadcast after each (re)connect.
    var selfStatus: String? = UserDefaults.standard.string(forKey: "freeq.status")

    // MARK: - Safety: blocking & reporting
    /// Blocked people — by DID when known (stable across nick changes) and by
    /// lowercased nick. Their messages are hidden from every list and their
    /// DMs suppressed. The pure decisions live in `BlockList`.
    var blockList = BlockList(
        dids: Set(UserDefaults.standard.stringArray(forKey: "freeq.blockedDIDs") ?? []),
        nicks: Set(UserDefaults.standard.stringArray(forKey: "freeq.blockedNicks") ?? [])
    ) {
        didSet {
            UserDefaults.standard.set(Array(blockList.dids), forKey: "freeq.blockedDIDs")
            UserDefaults.standard.set(Array(blockList.nicks), forKey: "freeq.blockedNicks")
        }
    }
    var bookmarks: [Bookmark] = []
    var lastReadMsgId: [String: String] = [:]  // lowercase channel → last read msgid
    /// draft/read-marker (S1): lowercase target → ISO8601 read-up-to
    /// timestamp, synced across this account's devices. Consumed by the
    /// unread "New" line (later phase).
    var readMarkers: [String: String] = [:]

    struct Bookmark: Identifiable, Codable {
        var id: String { msgId }
        let channel: String
        let msgId: String
        let from: String
        let text: String
        let timestamp: Date
    }

    // MARK: - P2P
    var p2pEndpointId: String?
    var p2pConnectedPeers: Set<String> = []
    var p2pDMActive: Set<String> = []

    // MARK: - AV (voice/video calls)
    var isInCall: Bool = false
    var isMuted: Bool = false
    var isCameraOn: Bool = false
    var isScreenSharing: Bool = false
    var isCallExpanded: Bool = false
    var callParticipants: [String] = []
    /// channel (lowercased) → active session id, populated from `+freeq.at/av-state` TAGMSGs
    var activeAvSessions: [String: String] = [:]
    var currentCallChannel: String? = nil
    var currentCallSessionId: String? = nil
    /// Nicks for which at least one video frame has arrived this call.
    var participantsWithVideo: Set<String> = []
    /// Nicks with a live screen-share broadcast ({peer}/screen path).
    var participantsWithScreen: Set<String> = []
    /// Remote playout levels (lowercased nick → 0…1) from AvEvent.audioLevel;
    /// drives remote active-speaker rings once the SDK emits them (R1).
    var remoteAudioLevels: [String: Float] = [:]
    /// Quiet in-call transport status ("Reconnecting…"); shown inline in the
    /// call bar, never as a modal — reconnection is automatic.
    var callTransportStatus: String? = nil
    /// Local mic level (0…1) for the in-call meter, ~25 Hz while capturing.
    var localMicLevel: Float = 0
    /// Debounced local voice-activity flag (drives the self-tile speaking
    /// ring and the "talking while muted" hint).
    var isLocalSpeaking: Bool = false
    /// Sticky mic selection (CoreAudio UID; nil = system default).
    var preferredMicUID: String? = UserDefaults.standard.string(forKey: "freeq.av.micUID") {
        didSet { UserDefaults.standard.set(preferredMicUID, forKey: "freeq.av.micUID") }
    }
    /// Sticky camera selection (AVCaptureDevice.uniqueID; nil = default).
    var preferredCameraUID: String? = UserDefaults.standard.string(forKey: "freeq.av.cameraUID") {
        didSet { UserDefaults.standard.set(preferredCameraUID, forKey: "freeq.av.cameraUID") }
    }
    /// Sticky speaker selection for remote audio (Rust cpal device id;
    /// nil = system default). Applied on call start + live switch.
    var preferredOutputDeviceId: String? = UserDefaults.standard.string(forKey: "freeq.av.outputId") {
        didSet { UserDefaults.standard.set(preferredOutputDeviceId, forKey: "freeq.av.outputId") }
    }
    /// Camera background effect (none / blur / custom image). Sticky, and
    /// applies live to a running camera.
    var cameraBackgroundEffect = VideoBackgroundEffect(
        encoded: UserDefaults.standard.string(forKey: "freeq.av.bgEffect") ?? "none"
    ) {
        didSet {
            UserDefaults.standard.set(cameraBackgroundEffect.encoded, forKey: "freeq.av.bgEffect")
            cameraCapture?.effects.effect = cameraBackgroundEffect
        }
    }
    @ObservationIgnored var avSession: FreeqAv? = nil
    /// Channels where we sent `av-start` and are waiting on the server's `started` echo.
    @ObservationIgnored var pendingAvStart: Set<String> = []
    /// Per-call instance id sent on av-join/av-leave (`+freeq.at/av-instance`).
    @ObservationIgnored var currentAvInstance: String? = nil
    @ObservationIgnored var cameraCapture: CallCameraCapture? = nil
    @ObservationIgnored var screenCapture: CallScreenCapture? = nil
    @ObservationIgnored var micCapture: CallMicCapture? = nil
    /// Per-nick remote video display layers (lowercased nick → layer, weakly held).
    @ObservationIgnored var remoteVideoLayers =
        NSMapTable<NSString, AVSampleBufferDisplayLayer>.strongToWeakObjects()
    /// Per-nick remote screen-share layers (lowercased nick → layer, weakly held).
    @ObservationIgnored var remoteScreenLayers =
        NSMapTable<NSString, AVSampleBufferDisplayLayer>.strongToWeakObjects()
    var localPreviewCapture: CallCameraCapture? { cameraCapture }

    // MARK: - UI State
    var showDetailPanel: Bool = true
    var showQuickSwitcher: Bool = false
    var showJoinSheet: Bool = false
    var showBookmarks: Bool = false
    var showChannelList: Bool = false
    var errorMessage: String?

    // MARK: - Compose state (editing/replying)
    var editingMessageId: String?
    var editingText: String?
    var replyingToMessage: ChatMessage?
    var scrollToMessageId: String?
    /// Test-only: forces a message row into its hovered state (DebugBridge
    /// `#hover <id>`) so the hover action bar can be screenshot-verified.
    var debugForceHoverMsgId: String?
    var showSearch: Bool = false
    var showHelp: Bool = false
    var showNewDM: Bool = false
    var motd: String = ""
    var showMotd: Bool = false
    var threadRootMessage: ChatMessage?

    // MARK: - Auth
    var authBrokerBase: String = ServerConfig.authBrokerBase
    var brokerToken: String?
    var pendingWebToken: String?
    var apiBearerSessionId: String?
    var isLoadingSavedSession: Bool = false
    /// Consecutive broker /session failures during auto-reconnect. Past a
    /// small threshold the reconnect banner offers a fresh sign-in — a
    /// wedged broker token must not trap the user in "Reconnecting…".
    var brokerFailureStreak: Int = 0

    // MARK: - Batches (CHATHISTORY)
    var batches: [String: HistoryBatchBuffer] = [:]

    // MARK: - Names accumulator (353 lines come in multiple events)
    var pendingNames: [String: [MemberInfo]] = [:]

    // MARK: - Profile cache
    var profileCache = ProfileCache.shared

    // MARK: - Typing debounce
    private var lastTypingSent: [String: Date] = [:]

    // MARK: - Compose hooks
    /// Set by ComposeBar so the `/media` command can open a file picker.
    /// nil in headless/test contexts.
    @ObservationIgnored var onComposeMediaRequest: (() -> Void)?
    /// Test-mode debug command bridge (file-driven). Held so it isn't deinited.
    @ObservationIgnored var debugBridge: DebugBridge?

    // MARK: - Private
    private var client: FreeqClient?
    private var p2p: FreeqP2p?
    @ObservationIgnored private var didRequestDmTargets = false
    @ObservationIgnored private var explicitWhoisRequests: Set<String> = []

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

    var hasSavedSession: Bool {
        brokerToken != nil && !nick.isEmpty
    }

    /// The running app's state, for OS-integration surfaces (menu bar extra,
    /// global hotkey, App Intents) that live outside the SwiftUI environment
    /// and need to reach the one live instance. Set in `init`.
    @ObservationIgnored static weak var current: AppState?

    // MARK: - Init

    init() {
        AppState.current = self
        loadSavedState()
        requestNotificationPermission()
        // In test mode the SwiftUI view lifecycle may never run `.onAppear`
        // (e.g. the screen is locked during automated runs), so kick off the
        // guest connect + DebugBridge from init, independent of any view.
        if ProcessInfo.processInfo.environment["FREEQ_TEST_NICK"] != nil {
            DispatchQueue.main.async { [weak self] in self?.startupConnect() }
        } else {
            loadSavedCredentialsAsync()
        }
    }

    private func loadSavedState() {
        reconcileDeploymentChange()
        if let saved = UserDefaults.standard.string(forKey: "freeq.nick") {
            nick = saved
        }
        if let saved = UserDefaults.standard.string(forKey: "freeq.server") {
            serverAddress = saved
        }
        if let saved = UserDefaults.standard.stringArray(forKey: "freeq.channels"), !saved.isEmpty {
            autoJoinChannels = saved
        }
        closedDMs = Set(UserDefaults.standard.stringArray(forKey: "freeq.closedDMs") ?? [])
        favorites = Set(UserDefaults.standard.stringArray(forKey: "freeq.favorites") ?? [])
        mutedChannels = Set(UserDefaults.standard.stringArray(forKey: "freeq.muted") ?? [])
        mentionOnlyChannels = Set(UserDefaults.standard.stringArray(forKey: "freeq.mentionOnly") ?? [])
        if let data = UserDefaults.standard.data(forKey: "freeq.bookmarks"),
           let saved = try? JSONDecoder().decode([Bookmark].self, from: data) {
            bookmarks = saved
        }

        // Wake from sleep → reconnect
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.connectionState == .disconnected, self.hasSavedSession else { return }
            Log.irc.info("System wake detected — reconnecting")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.reconnectIfSaved()
            }
        }
    }

    /// Drops saved auth + server-scoped state when the build has been
    /// retargeted at a different deployment since the last run. The
    /// default freeq.at build never trips this — its deployment id is
    /// stable — so anyone who doesn't touch deployment config is
    /// unaffected. It only fires when the baked `IRC_SERVER` /
    /// `AUTH_BROKER_BASE` change (e.g. switching to a zerosum build),
    /// where the bundle-shared keychain/UserDefaults would otherwise
    /// carry a freeq.at token and session into the new host.
    private func reconcileDeploymentChange() {
        let current = ServerConfig.deploymentID
        let key = "freeq.deployment"
        let previous = UserDefaults.standard.string(forKey: key)
        defer { UserDefaults.standard.set(current, forKey: key) }
        guard let previous, previous != current else { return }

        Log.auth.info(
            "Deployment changed (\(previous, privacy: .public) -> \(current, privacy: .public)); clearing saved session"
        )
        KeychainHelper.delete(key: "brokerToken")
        KeychainHelper.delete(key: "did")
        for staleKey in [
            "freeq.nick", "freeq.server", "freeq.channels",
            "freeq.closedDMs", "freeq.favorites", "freeq.muted",
            "freeq.bookmarks",
        ] {
            UserDefaults.standard.removeObject(forKey: staleKey)
        }
    }

    private func loadSavedCredentialsAsync() {
        isLoadingSavedSession = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.isLoadingSavedSession, self.brokerToken == nil else { return }
            self.isLoadingSavedSession = false
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard self != nil else { return }
            let savedBrokerToken = KeychainHelper.load(key: "brokerToken")
            let savedDID = KeychainHelper.load(key: "did")

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.brokerToken = savedBrokerToken
                self.authenticatedDID = AuthSessionState.confirmedDidFromSavedCredentials(savedDID)
                self.isLoadingSavedSession = false
                if self.connectionState == .disconnected, self.hasSavedSession {
                    self.reconnectIfSaved()
                }
            }
        }
    }

    private func requestNotificationPermission() {
        NotificationManager.shared.configure()
    }

    // MARK: - Connection

    func connect(nick: String, webToken: String? = nil) {
        Perf.event("connect.start")
        Log.irc.info("Connecting as \(nick, privacy: .public)")
        self.nick = nick
        connectionState = .connecting
        authenticatedDID = nil
        didRequestDmTargets = false
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
            // Auto-reconnect must survive a throwing connect() too, or a
            // failed attempt strands the retry chain.
            if hasSavedSession { scheduleReconnect() }
        }
    }

    func disconnect() {
        client?.disconnect()
        client = nil
        connectionState = .disconnected
        authenticatedDID = nil
        didRequestDmTargets = false
        apiBearerSessionId = nil
        selfAwayReason = nil
        shutdownP2p()
    }

    func logout() {
        disconnect()
        brokerToken = nil
        authenticatedDID = nil
        pendingWebToken = nil
        apiBearerSessionId = nil
        KeychainHelper.delete(key: "brokerToken")
        KeychainHelper.delete(key: "did")
        channels.removeAll()
        dmBuffers.removeAll()
        activeChannel = nil
        closedDMs.removeAll()
    }

    /// Called once on launch. Honors a test/guest auto-connect env var, then
    /// falls back to restoring a saved session.
    func startupConnect() {
        if let testNick = ProcessInfo.processInfo.environment["FREEQ_TEST_NICK"],
           !testNick.isEmpty, connectionState == .disconnected {
            // Deterministic guest connect + file-driven command bridge for UI
            // testing against the real server.
            let bridge = DebugBridge(appState: self)
            debugBridge = bridge
            bridge.start()
            connect(nick: testNick)
            return
        }
        if hasSavedSession && connectionState == .disconnected {
            reconnectIfSaved()
        }
    }

    /// Schedule the next auto-reconnect attempt. First retry is near-instant
    /// (most drops happen with a healthy network — server restart, idle
    /// timeout); sustained failure backs off to 30s (`ReconnectPolicy`).
    func scheduleReconnect() {
        reconnectAttempts += 1
        let delay = ReconnectPolicy.delay(afterAttempt: reconnectAttempts)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.connectionState == .disconnected, self.hasSavedSession else { return }
            self.reconnectIfSaved()
        }
    }

    func reconnectIfSaved() {
        guard connectionState == .disconnected, hasSavedSession else { return }
        guard let token = brokerToken, !token.isEmpty else {
            // Saved-session bit was set but the token is gone (keychain
            // wiped, etc.). Fall back to fresh login instead of crashing
            // the way `brokerToken!` did. `hasSavedSession` is computed
            // from brokerToken + nick, so clearing the token + erasing
            // the keychain copy flips it false.
            self.brokerToken = nil
            KeychainHelper.delete(key: "brokerToken")
            self.errorMessage = "Saved session is no longer valid — please sign in again."
            return
        }

        Task {
            do {
                let session = try await BrokerAuth.fetchSession(
                    brokerBase: authBrokerBase,
                    brokerToken: token
                )
                await MainActor.run {
                    self.brokerFailureStreak = 0
                    self.pendingWebToken = session.token
                    self.authenticatedDID = AuthSessionState.confirmedDidFromSavedCredentials(session.did)
                    if !KeychainHelper.save(key: "did", value: session.did) {
                        self.errorMessage = "Could not store credentials in Keychain — login will not persist across restarts."
                    }
                    self.connect(nick: session.nick)
                }
            } catch BrokerError.invalidToken {
                // The stored broker token has been revoked/expired. Clear it so
                // the UI drops to the sign-in screen instead of looping forever
                // on "Disconnected — reconnecting…".
                await MainActor.run {
                    self.brokerToken = nil
                    self.authenticatedDID = nil
                    KeychainHelper.delete(key: "brokerToken")
                    self.errorMessage = "Your session expired. Please sign in again."
                }
            } catch {
                // Transient (network/5xx) — keep the saved session AND
                // reschedule. Nothing else will: the disconnect event that
                // drives the retry chain already fired, so returning here
                // without scheduling used to stall reconnection forever
                // (the "stuck on Reconnecting… until Retry Now" bug).
                await MainActor.run {
                    self.brokerFailureStreak += 1
                    self.scheduleReconnect()
                }
            }
        }
    }

    // MARK: - Send

    func sendMessage(to target: String, text: String) {
        if !target.hasPrefix("#") {
            closedDMs.remove(target.lowercased())
        }

        // Try P2P first for DMs
        if !target.hasPrefix("#"),
           let peerEndpoint = p2pEndpointForNick(target) {
            try? p2p?.sendMessage(peerId: peerEndpoint, text: text)
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

        // Channel E2EE: when this channel has a key, relay ciphertext with the
        // `+encrypted` tag (matches the web client's wire behavior). The echo
        // cache inside ChannelE2eeState restores our plaintext on server echo.
        if target.hasPrefix("#"), let wire = channelE2ee.outgoing(text: text, channel: target) {
            sendRaw("@+encrypted PRIVMSG \(target) :\(wire)")
            return
        }

        // Server-relayed
        do {
            try client?.sendMessage(target: target, text: text)
        } catch {
            errorMessage = "Send failed: \(error.localizedDescription)"
        }
    }

    func sendAction(to target: String, text: String) {
        sendRaw("PRIVMSG \(target) :\u{01}ACTION \(text)\u{01}")
    }

    func editMessage(target: String, msgId: String, newText: String) {
        if target.hasPrefix("#"), let wire = channelE2ee.outgoing(text: newText, channel: target) {
            sendRaw("@+draft/edit=\(msgId);+encrypted PRIVMSG \(target) :\(wire)")
        } else {
            sendRaw("@+draft/edit=\(msgId) PRIVMSG \(target) :\(newText)")
        }
    }

    func deleteMessage(target: String, msgId: String) {
        // Apply optimistically: the server relays the delete TAGMSG to other
        // members but never echoes it back to the author (see SelfActionEcho),
        // so without this the deleter's own view never tombstones the message
        // — the "delete didn't work" bug. Mirrors the optimistic reaction path.
        let ch = channels.first { $0.name.lowercased() == target.lowercased() }
            ?? dmBuffers.first { $0.name.lowercased() == target.lowercased() }
        if SelfActionEcho.needsOptimisticLocalApply(.delete) {
            ch?.applyDelete(msgId: msgId)
            Task { await MessageStore.shared.markDeleted(msgId: msgId) }
        }
        sendRaw("@+draft/delete=\(msgId) TAGMSG \(target)")
    }

    func sendReaction(target: String, msgId: String, emoji: String) {
        // Toggle based on our current local state, and apply optimistically —
        // the server relays the TAGMSG to other members but does not echo it
        // back to us, so without this our own reaction would never appear.
        let ch = channels.first { $0.name.lowercased() == target.lowercased() }
            ?? dmBuffers.first { $0.name.lowercased() == target.lowercased() }
        let already = ch?.hasReaction(msgId: msgId, emoji: emoji, from: nick) ?? false
        if already {
            ch?.removeReaction(msgId: msgId, emoji: emoji, from: nick)
            sendRaw("@+freeq.at/unreact=\(emoji);+reply=\(msgId) TAGMSG \(target)")
        } else {
            ch?.addReaction(msgId: msgId, emoji: emoji, from: nick)
            sendRaw("@+react=\(emoji);+reply=\(msgId) TAGMSG \(target)")
        }
    }

    func sendTyping(target: String) {
        let now = Date()
        let key = target.lowercased()
        if let last = lastTypingSent[key], now.timeIntervalSince(last) < 3 { return }
        lastTypingSent[key] = now
        sendRaw("@+typing=active TAGMSG \(target)")
    }

    func joinChannel(_ channel: String) {
        let ch = channel.hasPrefix("#") ? channel : "#\(channel)"
        do {
            try client?.join(channel: ch)
        } catch {
            errorMessage = "Join failed: \(error.localizedDescription)"
        }
    }

    func partChannel(_ channel: String) {
        do {
            try client?.part(channel: channel)
            channels.removeAll { $0.name.lowercased() == channel.lowercased() }
            autoJoinChannels.removeAll { $0.lowercased() == channel.lowercased() }
            UserDefaults.standard.set(autoJoinChannels, forKey: "freeq.channels")
            if activeChannel?.lowercased() == channel.lowercased() {
                activeChannel = channels.first?.name
            }
        } catch {
            errorMessage = "Part failed: \(error.localizedDescription)"
        }
    }

    func sendRaw(_ line: String) {
        try? client?.sendRaw(line: line)
    }

    private func requestDmTargetsIfReady() {
        guard DmTargetBootstrap.shouldRequest(
            isRegistered: connectionState == .registered,
            authenticatedDID: authenticatedDID,
            alreadyRequested: didRequestDmTargets
        ) else { return }

        didRequestDmTargets = true
        sendRaw(DmTargetBootstrap.command)
    }

    func requestHistory(channel: String, before: Date? = nil) {
        if let before {
            let iso = ISO8601DateFormatter().string(from: before)
            sendRaw("CHATHISTORY BEFORE \(channel) timestamp=\(iso) 50")
        } else {
            sendRaw("CHATHISTORY LATEST \(channel) * 50")
        }
    }

    /// Populate a channel's pinned-messages bar from the server's REST pins
    /// endpoint. Called on join and after a pin/unpin. (The IRC PIN/UNPIN/PINS
    /// flow drives the server; the REST list is the source of truth for display.)
    func fetchPins(channel: String) {
        guard channel.hasPrefix("#") else { return }
        let host = serverAddress.split(separator: ":").first.map(String.init) ?? "irc.freeq.at"
        let encoded = channel.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? channel
        guard let url = URL(string: "https://\(host)/api/v1/channels/\(encoded)/pins") else { return }
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pins = json["pins"] as? [[String: Any]] else { return }
            let msgs: [ChatMessage] = pins.compactMap { p in
                guard let msgid = p["msgid"] as? String, let text = p["text"] as? String else { return nil }
                let fromRaw = (p["from"] as? String) ?? ""
                let author = fromRaw.split(separator: "!").first.map(String.init) ?? fromRaw
                let ts = (p["pinned_at"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? Date()
                return ChatMessage(id: msgid, from: author, text: text,
                                   isAction: false, timestamp: ts, replyTo: nil)
            }
            await MainActor.run {
                if let ch = self.channels.first(where: { $0.name.lowercased() == channel.lowercased() }) {
                    ch.pinnedMessages = msgs
                }
            }
        }
    }

    /// Pin/unpin a message and refresh the pinned bar (the server applies it
    /// async, so re-fetch shortly after).
    func pin(msgId: String, in channel: String) { pinAction("PIN", msgId, channel) }
    func unpin(msgId: String, in channel: String) { pinAction("UNPIN", msgId, channel) }

    private func pinAction(_ verb: String, _ msgId: String, _ channel: String) {
        sendRaw("\(verb) \(channel) \(msgId)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.fetchPins(channel: channel)
        }
    }

    func setAway(_ reason: String?) {
        if let reason {
            sendRaw("AWAY :\(reason)")
        } else {
            sendRaw("AWAY")
        }
        // Optimistic — the server's away-notify echo (if any) confirms it.
        selfAwayReason = reason
        // Clearing away supersedes any saved custom status — otherwise the
        // old status would silently re-broadcast on the next reconnect.
        if reason == nil, selfStatus != nil {
            selfStatus = nil
            UserDefaults.standard.removeObject(forKey: "freeq.status")
        }
    }

    /// Set (or clear, with nil/empty) the custom status. Rides IRC AWAY —
    /// same wire mechanism as `setAway`, plus persistence so the status
    /// survives restarts and re-broadcasts after each (re)connect.
    func setStatus(_ text: String?) {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let t = trimmed, !t.isEmpty {
            selfStatus = t
            UserDefaults.standard.set(t, forKey: "freeq.status")
            sendRaw("AWAY :\(t)")
            selfAwayReason = t  // optimistic; away-notify echo confirms
        } else {
            selfStatus = nil
            UserDefaults.standard.removeObject(forKey: "freeq.status")
            sendRaw("AWAY")
            selfAwayReason = nil
        }
    }

    /// Re-broadcast a saved status after (re)connect so others see it again.
    func reapplyStatusIfNeeded() {
        if let s = selfStatus, !s.isEmpty {
            sendRaw("AWAY :\(s)")
            selfAwayReason = s
        }
    }

    // MARK: - Safety: blocking & reporting

    func isBlocked(nick: String, did: String? = nil) -> Bool {
        guard !blockList.isEmpty else { return false }
        return blockList.isBlocked(nick: nick, did: did ?? profileCache.did(for: nick))
    }

    func blockUser(nick: String, did: String?) {
        blockList.block(nick: nick, did: did ?? profileCache.did(for: nick))
    }

    func unblockUser(nick: String?, did: String?) {
        blockList.unblock(nick: nick, did: did ?? nick.flatMap { profileCache.did(for: $0) })
    }

    /// Record a user's report of a message/user. There's no server report
    /// endpoint yet, so we hide the content immediately and block the author —
    /// report-and-block — which is the user-visible remedy. The reason is
    /// logged for the eventual moderation pipeline.
    func reportUser(nick: String, did: String?, reason: String) {
        Log.irc.notice("user report: nick=\(nick, privacy: .public) reason=\(reason, privacy: .public)")
        blockUser(nick: nick, did: did)
    }

    /// ⌥↑/⌥↓ and ⌥⇧↑/⌥⇧↓ — move through buffers in sidebar order,
    /// optionally skipping to the next one with unread activity.
    func switchToAdjacentChannel(_ direction: BufferNavigation.Direction, unreadOnly: Bool = false) {
        let order = BufferNavigation.sidebarOrder(
            channels: channels.map(\.name),
            favorites: favorites,
            dms: dmBuffers.sorted(by: { $0.lastActivity > $1.lastActivity }).map(\.name)
        )
        let target = BufferNavigation.target(
            from: activeChannel,
            order: order,
            direction: direction,
            isUnread: unreadOnly
                ? { [weak self] name in
                    guard let self else { return false }
                    let key = name.lowercased()
                    return (unreadCounts[key] ?? 0) > 0 || (mentionCounts[key] ?? 0) > 0
                }
                : nil
        )
        if let target { activeChannel = target }
    }

    func kickUser(_ channel: String, _ nick: String, reason: String? = nil) {
        if let reason {
            sendRaw("KICK \(channel) \(nick) :\(reason)")
        } else {
            sendRaw("KICK \(channel) \(nick)")
        }
    }

    func setMode(_ channel: String, _ mode: String, _ nick: String) {
        sendRaw("MODE \(channel) \(mode) \(nick)")
    }

    func inviteUser(_ channel: String, _ nick: String) {
        sendRaw("INVITE \(nick) \(channel)")
    }

    func sendWhois(_ nick: String, display: Bool = true) {
        if display {
            explicitWhoisRequests.insert(nick.lowercased())
        }
        sendRaw("WHOIS \(nick)")
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
            // P2P is optional — don't show error
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

    private func p2pEndpointForNick(_ nick: String) -> String? {
        nil // TODO: maintain nick -> iroh endpoint ID mapping
    }

    // MARK: - Channel helpers

    func getOrCreateChannel(_ name: String) -> ChannelState {
        let lower = name.lowercased()
        if let ch = channels.first(where: { $0.name.lowercased() == lower }) {
            return ch
        }
        let ch = ChannelState(name: name)
        restoreChannelKeyIfSaved(name)
        ch.isEncrypted = channelE2ee.hasKey(channel: name)
        // Pre-populate from local DB
        Task {
            let cached = await MessageStore.shared.loadMessages(channel: name, limit: 100)
            await MainActor.run {
                for msg in cached { ch.appendIfNew(msg) }
            }
        }
        channels.append(ch)
        channels.sort { $0.name.lowercased() < $1.name.lowercased() }
        attemptRestoreLastChannel()
        return ch
    }

    /// Reopen the conversation the user was last in (persisted in `didSet`).
    /// Called as channels/DMs load after connect: selects the saved target
    /// once it's present, or falls back to the first channel once all the
    /// auto-join channels have loaded and the saved one didn't reappear (it
    /// was left). Runs at most once per launch.
    private func attemptRestoreLastChannel() {
        guard !didRestoreLastChannel else { return }
        // Use the target captured at launch, not the live UserDefaults value —
        // the latter gets clobbered by connect-time auto-selection.
        let saved = pendingRestoreTarget
        let names = channels.map(\.name) + dmBuffers.map(\.name)

        // The last-open conversation has joined — reopen it right away. Flip the
        // flag FIRST so the didSet persists this (intended) selection.
        if let saved,
           let match = names.first(where: { $0.caseInsensitiveCompare(saved) == .orderedSame }) {
            didRestoreLastChannel = true
            activeChannel = match
            return
        }

        // It isn't here yet. Channels join incrementally and out of order, so a
        // count-based fallback used to land us on the alphabetically-first
        // channel before the real one finished joining. Instead, give the joins
        // a moment to settle, then fall back through favorites → #freeq.
        scheduleRestoreFallback()
    }

    /// One-shot delayed fallback: if the last-open channel never reappears,
    /// land on the first favorite, then the #freeq lobby, then any channel.
    private func scheduleRestoreFallback() {
        guard !restoreFallbackScheduled else { return }
        restoreFallbackScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, !self.didRestoreLastChannel else { return }
            let target = LastChannel.restore(
                saved: self.pendingRestoreTarget,
                channels: self.channels.map(\.name),
                dms: self.dmBuffers.map(\.name),
                favorites: self.favorites)
            self.didRestoreLastChannel = true
            if let target { self.activeChannel = target }
        }
    }

    // MARK: - Channel E2EE key lifecycle

    private static func channelKeyKeychainKey(_ channel: String) -> String {
        "e2ee.channel.\(channel.lowercased())"
    }

    func setChannelKey(_ channel: String, passphrase: String) {
        channelE2ee.setKey(channel: channel, passphrase: passphrase)
        if let exported = channelE2ee.exportKey(channel: channel) {
            KeychainHelper.save(key: Self.channelKeyKeychainKey(channel), value: exported)
        }
        getOrCreateChannel(channel).isEncrypted = true
    }

    func removeChannelKey(_ channel: String) {
        channelE2ee.removeKey(channel: channel)
        KeychainHelper.delete(key: Self.channelKeyKeychainKey(channel))
        channels.first { $0.name.lowercased() == channel.lowercased() }?.isEncrypted = false
    }

    /// Rehydrate a channel key from the keychain (saved by a prior /encrypt).
    func restoreChannelKeyIfSaved(_ channel: String) {
        guard !channelE2ee.hasKey(channel: channel),
              let b64 = KeychainHelper.load(key: Self.channelKeyKeychainKey(channel)) else { return }
        channelE2ee.importKey(channel: channel, base64: b64)
    }

    func getOrCreateDM(_ nick: String) -> ChannelState {
        let lower = nick.lowercased()
        if let dm = dmBuffers.first(where: { $0.name.lowercased() == lower }) {
            return dm
        }
        let dm = ChannelState(name: nick)
        // Pre-populate from local DB
        Task {
            let cached = await MessageStore.shared.loadMessages(channel: nick, limit: 100)
            await MainActor.run {
                for msg in cached { dm.appendIfNew(msg) }
            }
        }
        dmBuffers.append(dm)
        attemptRestoreLastChannel()
        return dm
    }

    /// Open (creating if needed) a DM buffer with `nick` and make it active.
    /// Reuses an existing buffer, un-hides a previously closed one, and is the
    /// shared entry point for the ⌘N picker and the "Send Message" buttons.
    func openDM(with nick: String) {
        let trimmed = nick.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return }
        closedDMs.remove(trimmed.lowercased())
        let dm = getOrCreateDM(trimmed)
        activeChannel = dm.name
    }

    /// Nicks the ⌘N picker suggests: everyone visible in a shared channel
    /// plus anyone you already have a DM with, minus yourself. Deduped
    /// case-insensitively, sorted for stable display.
    var knownNicks: [String] {
        var seen = Set<String>()
        var out: [String] = []
        let me = nick.lowercased()
        for ch in channels {
            for m in ch.members {
                let key = m.nick.lowercased()
                if key != me, !key.isEmpty, seen.insert(key).inserted {
                    out.append(m.nick)
                }
            }
        }
        for dm in dmBuffers {
            let key = dm.name.lowercased()
            if key != me, seen.insert(key).inserted { out.append(dm.name) }
        }
        return out.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func closeDM(_ nick: String) {
        let lower = nick.lowercased()
        closedDMs.insert(lower)
        dmBuffers.removeAll { $0.name.lowercased() == lower }
        unreadCounts.removeValue(forKey: lower)
        mentionCounts.removeValue(forKey: lower)
        if activeChannel?.lowercased() == lower {
            activeChannel = channels.first?.name
        }
    }

    func switchToChannelByIndex(_ index: Int) {
        let all = allBuffers
        guard index < all.count else { return }
        activeChannel = all[index].name
    }

    /// Favorited channels in the same order the sidebar shows them (channel
    /// order, filtered to favorites) — so ⌃⌘1…9 lines up with what the user
    /// sees under the Favorites header.
    var favoriteChannels: [ChannelState] {
        channels.filter { favorites.contains($0.name.lowercased()) }
    }

    /// Jump to the Nth favorite (0-based). No-op if fewer favorites exist.
    func switchToFavorite(_ index: Int) {
        let favs = favoriteChannels
        guard index < favs.count else { return }
        activeChannel = favs[index].name
    }

    func incrementUnread(_ channel: String) {
        guard channel.lowercased() != activeChannel?.lowercased() else { return }
        unreadCounts[channel.lowercased(), default: 0] += 1
    }

    func clearUnread(_ channel: String) {
        unreadCounts[channel.lowercased()] = 0
        mentionCounts[channel.lowercased()] = 0
        // Track read position
        let ch = channels.first(where: { $0.name.lowercased() == channel.lowercased() })
            ?? dmBuffers.first(where: { $0.name.lowercased() == channel.lowercased() })
        if let lastMsg = ch?.messages.last {
            lastReadMsgId[channel.lowercased()] = lastMsg.id
        }
    }

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

    // MARK: - Sounds

    enum SoundType { case mention, dm, connect, disconnect }

    func playSound(_ type: SoundType) {
        guard UserDefaults.standard.bool(forKey: "freeq.soundsEnabled") != false else { return }
        let name: String
        switch type {
        case .mention: name = "Ping"
        case .dm: name = "Tink"
        case .connect: name = "Pop"
        case .disconnect: name = "Basso"
        }
        NSSound(named: NSSound.Name(name))?.play()
    }

    func toggleFavorite(_ channel: String) {
        let key = channel.lowercased()
        if favorites.contains(key) { favorites.remove(key) } else { favorites.insert(key) }
        UserDefaults.standard.set(Array(favorites), forKey: "freeq.favorites")
    }

    func toggleMuted(_ channel: String) {
        let key = channel.lowercased()
        if mutedChannels.contains(key) { mutedChannels.remove(key) } else { mutedChannels.insert(key) }
        UserDefaults.standard.set(Array(mutedChannels), forKey: "freeq.muted")
    }

    /// Notification tiers for a channel. `all` (default): mentions + regular
    /// (regular gated by the global `notifyAllMessages`). `mentionsOnly`:
    /// only mentions. `muted`: nothing.
    enum ChannelNotifyLevel: String { case all, mentionsOnly, muted }

    func notifyLevel(_ channel: String) -> ChannelNotifyLevel {
        let key = channel.lowercased()
        if mutedChannels.contains(key) { return .muted }
        if mentionOnlyChannels.contains(key) { return .mentionsOnly }
        return .all
    }

    func setNotifyLevel(_ level: ChannelNotifyLevel, for channel: String) {
        let key = channel.lowercased()
        mutedChannels.remove(key)
        mentionOnlyChannels.remove(key)
        switch level {
        case .all: break
        case .mentionsOnly: mentionOnlyChannels.insert(key)
        case .muted: mutedChannels.insert(key)
        }
        UserDefaults.standard.set(Array(mutedChannels), forKey: "freeq.muted")
        UserDefaults.standard.set(Array(mentionOnlyChannels), forKey: "freeq.mentionOnly")
    }

    func addBookmark(channel: String, msg: ChatMessage) {
        guard !bookmarks.contains(where: { $0.msgId == msg.id }) else { return }
        bookmarks.append(Bookmark(channel: channel, msgId: msg.id, from: msg.from, text: msg.text, timestamp: msg.timestamp))
        saveBookmarks()
    }

    func removeBookmark(msgId: String) {
        bookmarks.removeAll { $0.msgId == msgId }
        saveBookmarks()
    }

    private func saveBookmarks() {
        if let data = try? JSONEncoder().encode(bookmarks) {
            UserDefaults.standard.set(data, forKey: "freeq.bookmarks")
        }
    }

    /// Get the last message from self in the active channel (for edit-last).
    func lastOwnMessage(in target: String) -> ChatMessage? {
        let ch = channels.first { $0.name.lowercased() == target.lowercased() }
            ?? dmBuffers.first { $0.name.lowercased() == target.lowercased() }
        guard let ch else { return nil }
        return MessageActions.lastEditable(messages: ch.messages, nick: nick)
    }

    // MARK: - WHOIS for DID discovery

    private var whoisedNicks: Set<String> = []
    private var whoisQueue: [String] = []
    private var whoisTimerActive = false

    /// Queue WHOIS for members we haven't checked yet (to discover DIDs).
    func whoisMembers(_ nicks: [String]) {
        for nick in nicks {
            let lower = nick.lowercased()
            guard !whoisedNicks.contains(lower), lower != self.nick.lowercased() else { continue }
            whoisedNicks.insert(lower)
            whoisQueue.append(nick)
        }
        startWhoisDrain()
    }

    /// Drain the WHOIS queue one at a time, 2 seconds apart.
    private func startWhoisDrain() {
        guard !whoisTimerActive, !whoisQueue.isEmpty else { return }
        whoisTimerActive = true
        drainNextWhois()
    }

    private func drainNextWhois() {
        guard !whoisQueue.isEmpty else {
            whoisTimerActive = false
            return
        }
        let nick = whoisQueue.removeFirst()
        sendWhois(nick, display: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.drainNextWhois()
        }
    }

    // Message notifications now live in NotificationManager (permission,
    // active/focus gating, click-to-focus, inline reply). See
    // handleEvent(_:) message routing for the call sites.
}

// MARK: - IRC Event Handler

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
        case .readMarker(let target, let timestamp):
            // draft/read-marker (S1) — cross-device read state. The unread
            // "New" line UI that consumes this is a later phase (§6.3);
            // store the latest marker (forward-only, enforced server-side)
            // so that work has it. No UI effect yet.
            if let timestamp { readMarkers[target.lowercased()] = timestamp }

        case .connected:
            connectionState = .connected

        case .registered(let registeredNick):
            Perf.event("connect.registered")
            Log.irc.info("Registered as \(registeredNick, privacy: .public)")
            connectionState = .registered
            reconnectAttempts = 0
            playSound(.connect)
            nick = registeredNick
            // Auto-join channels
            for ch in autoJoinChannels {
                joinChannel(ch)
            }
            requestDmTargetsIfReady()
            // Re-broadcast a saved custom status so shared channels see it
            // again after the reconnect.
            reapplyStatusIfNeeded()
            // Self-avatar: prime the profile cache with our own DID so
            // our avatar resolves immediately, without waiting for one
            // of our own messages to round-trip the server and come
            // back with an account-tag.
            if let did = authenticatedDID {
                profileCache.setDid(did, for: registeredNick)
            }
            // Start P2P subsystem
            startP2p()

        case .authenticated(let did):
            authenticatedDID = did
            if !KeychainHelper.save(key: "did", value: did) {
                Log.auth.error("Could not persist authenticated DID")
            }
            requestDmTargetsIfReady()
            // Once we know our DID, seed the profile cache so our own
            // avatar shows in the sidebar / member list before any
            // self-message echoes back.
            if !nick.isEmpty {
                profileCache.setDid(did, for: nick)
            }

        case .authFailed(let reason):
            authenticatedDID = AuthSessionState.didAfterAuthFailure(current: authenticatedDID)
            pendingWebToken = nil
            errorMessage = "Auth failed: \(reason)"

        case .joined(let channel, let joinNick):
            if joinNick.lowercased() == nick.lowercased() {
                let ch = getOrCreateChannel(channel)
                ch.members.removeAll()
                ch.accessDeniedReason = nil
                ch.messages.removeAll { $0.id.hasPrefix("channel-access-denied-\(channel)-") }
                pendingNames[channel.lowercased()] = []
                if activeChannel == nil || activeChannel == "server" {
                    activeChannel = ch.name
                }
                // Save to auto-join
                if !autoJoinChannels.contains(where: { $0.lowercased() == channel.lowercased() }) {
                    autoJoinChannels.append(channel)
                    UserDefaults.standard.set(autoJoinChannels, forKey: "freeq.channels")
                }
                // Load any pinned messages for the channel's pinned bar.
                fetchPins(channel: channel)
                if let historyCommand = ChannelHydration.historyCommand(for: channel) {
                    sendRaw(historyCommand)
                }
            } else {
                if let ch = channels.first(where: { $0.name.lowercased() == channel.lowercased() }) {
                    if !ch.members.contains(where: { $0.nick.lowercased() == joinNick.lowercased() }) {
                        ch.members.append(MemberInfo(nick: joinNick, isOp: false, isHalfop: false, isVoiced: false, awayMsg: nil, did: nil))
                    }
                    // System message
                    ch.appendIfNew(ChatMessage(
                        id: UUID().uuidString, from: "",
                        text: "\(joinNick) joined",
                        isAction: false, timestamp: Date(), replyTo: nil
                    ))
                }
            }

        case .parted(let channel, let partNick):
            if partNick.lowercased() == nick.lowercased() {
                channels.removeAll { $0.name.lowercased() == channel.lowercased() }
                autoJoinChannels.removeAll { $0.lowercased() == channel.lowercased() }
                UserDefaults.standard.set(autoJoinChannels, forKey: "freeq.channels")
                if activeChannel?.lowercased() == channel.lowercased() {
                    activeChannel = channels.first?.name
                }
            } else {
                if let ch = channels.first(where: { $0.name.lowercased() == channel.lowercased() }) {
                    ch.members.removeAll { $0.nick.lowercased() == partNick.lowercased() }
                    ch.appendIfNew(ChatMessage(
                        id: UUID().uuidString, from: "",
                        text: "\(partNick) left",
                        isAction: false, timestamp: Date(), replyTo: nil
                    ))
                }
            }

        case .message(let msg):
            let isSelf = msg.fromNick.lowercased() == nick.lowercased()

            // Pipe the server's account-tag DID into the profile cache.
            // Every PRIVMSG from an authenticated user carries a
            // `+freeq.at/account=did:plc:...` tag; reading it here means
            // we don't need to manually WHOIS every speaker just to
            // learn the DID for the avatar pipeline. This is the path
            // iOS already takes — macOS was just ignoring `msg.account`
            // and so no Bluesky avatars ever resolved.
            if let did = msg.account, did.hasPrefix("did:") {
                profileCache.setDid(did, for: msg.fromNick)
            }

            // Channel E2EE: map ENC1 ciphertext to its display form (decrypted
            // plaintext, our own echo-cached plaintext, or a placeholder when
            // we lack the key). DM (ENC3) decryption is E2eeManager's job.
            var displayText = msg.text
            var wasEncrypted = false
            if msg.target.hasPrefix("#") {
                (displayText, wasEncrypted) = channelE2ee.incoming(text: msg.text, channel: msg.target)
            }

            let message = ChatMessage(
                id: msg.msgid ?? UUID().uuidString,
                from: msg.fromNick,
                text: displayText,
                isAction: msg.isAction,
                timestamp: Date(timeIntervalSince1970: Double(msg.timestampMs) / 1000.0),
                replyTo: msg.replyTo,
                isEdited: msg.editOf != nil,
                isSigned: msg.isSigned,
                isEncrypted: wasEncrypted,
                origin: msg.origin
            )

            // Handle edits
            if let editOf = msg.editOf {
                if let batchId = msg.batchId, var batch = batches[batchId] {
                    batch.learnTarget(from: msg.target)
                    if let idx = batch.messages.firstIndex(where: { $0.id == editOf }) {
                        batch.messages[idx].text = displayText
                        batch.messages[idx].isEdited = true
                        if let newId = msg.msgid { batch.messages[idx].id = newId }
                    } else {
                        batch.messages.append(message)
                    }
                    batches[batchId] = batch
                    return
                }

                let target = msg.target
                if target.hasPrefix("#") {
                    let ch = getOrCreateChannel(target)
                    ch.applyEdit(originalId: editOf, newId: msg.msgid, newText: displayText)
                    Task { await MessageStore.shared.markEdited(msgId: editOf, newText: displayText) }
                } else {
                    let bufName = isSelf ? target : msg.fromNick
                    let dm = getOrCreateDM(bufName)
                    dm.applyEdit(originalId: editOf, newId: msg.msgid, newText: displayText)
                    Task { await MessageStore.shared.markEdited(msgId: editOf, newText: displayText) }
                }
                return
            }

            // Handle batch (CHATHISTORY)
            if let batchId = msg.batchId, var batch = batches[batchId] {
                batch.append(message, messageTarget: msg.target)
                batches[batchId] = batch
                return
            }

            // Route to channel or DM
            let target = msg.target
            // Persist to local DB
            Task { await MessageStore.shared.store(message, channel: target) }

            // Blocked senders: the message still lands in the buffer (the
            // list filters it out on display, so unblocking restores it) but
            // must not ring bells or bump unread badges.
            let senderBlocked = !isSelf && isBlocked(nick: msg.fromNick, did: msg.account)

            if target.hasPrefix("#") {
                let ch = getOrCreateChannel(target)
                ch.appendIfNew(message)
                ch.typingUsers.removeValue(forKey: msg.fromNick)
                if !senderBlocked { incrementUnread(target) }

                let level = notifyLevel(target)
                let mentioned = msg.text.localizedCaseInsensitiveContains(nick)
                if !isSelf && !senderBlocked && level != .muted {
                    if mentioned {
                        mentionCounts[target.lowercased(), default: 0] += 1
                        // Mentions are time-sensitive so a permitted Focus
                        // can let them through.
                        NotificationManager.shared.notifyMessage(
                            target: target,
                            title: "\(msg.fromNick) in \(target)",
                            body: msg.text,
                            timeSensitive: true
                        )
                        NotificationManager.shared.requestAttentionIfBackground()
                        playSound(.mention)
                    } else if level == .all
                        && UserDefaults.standard.bool(forKey: "freeq.notifyAllMessages") {
                        // Opt-in: notify for ALL channel traffic, not just
                        // mentions. Still gated by NotificationManager to the
                        // inactive/not-viewing case, off by default so a busy
                        // backgrounded channel doesn't flood, and skipped for
                        // channels the user set to mentions-only.
                        NotificationManager.shared.notifyMessage(
                            target: target,
                            title: "\(msg.fromNick) in \(target)",
                            body: msg.text
                        )
                    }
                }
            } else {
                let bufName = isSelf ? target : msg.fromNick
                closedDMs.remove(bufName.lowercased())
                let dm = getOrCreateDM(bufName)
                dm.appendIfNew(message)
                if !senderBlocked { incrementUnread(bufName) }

                // DM notification (time-sensitive: a DM is a direct ping).
                if !isSelf && !senderBlocked {
                    NotificationManager.shared.notifyMessage(
                        target: bufName,
                        title: msg.fromNick,
                        body: msg.text,
                        timeSensitive: true
                    )
                    NotificationManager.shared.requestAttentionIfBackground()
                    playSound(.dm)
                }
            }

        case .tagMsg(let tagMsg):
            let tags = Dictionary(uniqueKeysWithValues: tagMsg.tags.map { ($0.key, $0.value) })
            let target = tagMsg.target
            let from = tagMsg.from
            let isSelf = from.lowercased() == nick.lowercased()
            let dmBuffer = isSelf ? target : from
            let bufferName = target.hasPrefix("#") ? target : dmBuffer

            // Typing indicators
            if let typing = tags["+typing"] {
                if !isSelf {
                    let ch = bufferName.hasPrefix("#") ? getOrCreateChannel(bufferName) : getOrCreateDM(bufferName)
                    if typing == "active" {
                        ch.typingUsers[from] = Date()
                    } else if typing == "done" {
                        ch.typingUsers.removeValue(forKey: from)
                    }
                }
            }

            // Message deletion
            if let deleteId = tags["+draft/delete"] {
                let ch = bufferName.hasPrefix("#") ? getOrCreateChannel(bufferName) : getOrCreateDM(bufferName)
                ch.applyDelete(msgId: deleteId)
                Task { await MessageStore.shared.markDeleted(msgId: deleteId) }
            }

            // Reactions — idempotent add (a self-echo or duplicate is a no-op).
            if let emoji = tags["+react"], let replyId = tags["+reply"] {
                let ch = bufferName.hasPrefix("#") ? getOrCreateChannel(bufferName) : getOrCreateDM(bufferName)
                ch.addReaction(msgId: replyId, emoji: emoji, from: from)
            }

            // Reaction removal (toggle off)
            if let emoji = tags["+freeq.at/unreact"], let replyId = tags["+reply"] {
                let ch = bufferName.hasPrefix("#") ? getOrCreateChannel(bufferName) : getOrCreateDM(bufferName)
                ch.removeReaction(msgId: replyId, emoji: emoji, from: from)
            }

            // AV session lifecycle (`+freeq.at/av-state`)
            if let avState = tags["+freeq.at/av-state"],
               let avId = tags["+freeq.at/av-id"],
               target.hasPrefix("#") {
                handleAvState(avState, sessionId: avId,
                              actor: tags["+freeq.at/av-actor"] ?? from,
                              channel: target)
            }

        case .names(let channel, let memberList):
            let key = channel.lowercased()
            var existing = pendingNames[key] ?? []
            existing.append(contentsOf: memberList.map { m in
                MemberInfo(nick: m.nick, isOp: m.isOp, isHalfop: m.isHalfop, isVoiced: m.isVoiced, awayMsg: m.awayMsg, did: nil)
            })
            pendingNames[key] = existing

        case .topicChanged(let channel, let topic):
            if let ch = channels.first(where: { $0.name.lowercased() == channel.lowercased() }) {
                ch.topic = topic.text
                ch.topicSetBy = topic.setBy
                ch.lastActivity = Date()
            }

        case .modeChanged(let channel, let mode, let arg, _):
            guard let targetNick = arg else { break }
            if let ch = channels.first(where: { $0.name.lowercased() == channel.lowercased() }),
               let idx = ch.members.firstIndex(where: { $0.nick.lowercased() == targetNick.lowercased() }) {
                let m = ch.members[idx]
                switch mode {
                case "+o": ch.members[idx] = MemberInfo(nick: m.nick, isOp: true, isHalfop: m.isHalfop, isVoiced: m.isVoiced, awayMsg: m.awayMsg, did: m.did)
                case "-o": ch.members[idx] = MemberInfo(nick: m.nick, isOp: false, isHalfop: m.isHalfop, isVoiced: m.isVoiced, awayMsg: m.awayMsg, did: m.did)
                case "+h": ch.members[idx] = MemberInfo(nick: m.nick, isOp: m.isOp, isHalfop: true, isVoiced: m.isVoiced, awayMsg: m.awayMsg, did: m.did)
                case "-h": ch.members[idx] = MemberInfo(nick: m.nick, isOp: m.isOp, isHalfop: false, isVoiced: m.isVoiced, awayMsg: m.awayMsg, did: m.did)
                case "+v": ch.members[idx] = MemberInfo(nick: m.nick, isOp: m.isOp, isHalfop: m.isHalfop, isVoiced: true, awayMsg: m.awayMsg, did: m.did)
                case "-v": ch.members[idx] = MemberInfo(nick: m.nick, isOp: m.isOp, isHalfop: m.isHalfop, isVoiced: false, awayMsg: m.awayMsg, did: m.did)
                default: break
                }
            }

        case .kicked(let channel, let kickedNick, let by, let reason):
            if kickedNick.lowercased() == nick.lowercased() {
                channels.removeAll { $0.name.lowercased() == channel.lowercased() }
                autoJoinChannels.removeAll { $0.lowercased() == channel.lowercased() }
                UserDefaults.standard.set(autoJoinChannels, forKey: "freeq.channels")
                if activeChannel?.lowercased() == channel.lowercased() {
                    activeChannel = channels.first?.name
                }
                errorMessage = "Kicked from \(channel) by \(by): \(reason)"
                // Being removed from a channel is worth a notification even
                // in the foreground — no target (the channel is gone).
                NotificationManager.shared.notifyEvent(
                    title: "Removed from \(channel)",
                    body: reason.isEmpty ? "Kicked by \(by)" : "Kicked by \(by): \(reason)"
                )
            } else {
                if let ch = channels.first(where: { $0.name.lowercased() == channel.lowercased() }) {
                    ch.members.removeAll { $0.nick.lowercased() == kickedNick.lowercased() }
                    ch.appendIfNew(ChatMessage(
                        id: UUID().uuidString, from: "",
                        text: "\(kickedNick) was kicked by \(by)\(reason.isEmpty ? "" : " (\(reason))")",
                        isAction: false, timestamp: Date(), replyTo: nil
                    ))
                }
            }

        case .nickChanged(let oldNick, let newNick):
            if oldNick.lowercased() == nick.lowercased() {
                nick = newNick
                UserDefaults.standard.set(newNick, forKey: "freeq.nick")
            }
            profileCache.renameUser(from: oldNick, to: newNick)
            for ch in allBuffers {
                if let idx = ch.members.firstIndex(where: { $0.nick.lowercased() == oldNick.lowercased() }) {
                    let old = ch.members[idx]
                    ch.members[idx] = MemberInfo(nick: newNick, isOp: old.isOp, isHalfop: old.isHalfop, isVoiced: old.isVoiced, awayMsg: old.awayMsg, did: old.did)
                }
            }

        case .awayChanged(let awayNick, let awayMsg):
            if awayNick.lowercased() == nick.lowercased() {
                selfAwayReason = awayMsg
            }
            for ch in allBuffers {
                if let idx = ch.members.firstIndex(where: { $0.nick.lowercased() == awayNick.lowercased() }) {
                    let old = ch.members[idx]
                    ch.members[idx] = MemberInfo(nick: old.nick, isOp: old.isOp, isHalfop: old.isHalfop, isVoiced: old.isVoiced, awayMsg: awayMsg, did: old.did)
                }
            }

        case .userQuit(let quitNick, let reason):
            for ch in channels {
                if ch.members.contains(where: { $0.nick.lowercased() == quitNick.lowercased() }) {
                    ch.members.removeAll { $0.nick.lowercased() == quitNick.lowercased() }
                    ch.typingUsers.removeValue(forKey: quitNick)
                    ch.appendIfNew(ChatMessage(
                        id: UUID().uuidString, from: "",
                        text: "\(quitNick) quit\(reason.isEmpty ? "" : " (\(reason))")",
                        isAction: false, timestamp: Date(), replyTo: nil
                    ))
                }
            }

        case .batchStart(let id, let batchType, let target):
            guard HistoryBatchRouting.shouldBuffer(batchType: batchType, target: target) else { return }
            batches[id] = HistoryBatchBuffer(target: target)

        case .batchEnd(let id):
            guard let batch = batches.removeValue(forKey: id) else { return }
            HistoryBatchRouting.apply(buffer: batch, channels: &channels, dmBuffers: &dmBuffers)

        case .chatHistoryTarget(let targetNick, let timestamp):
            if closedDMs.contains(targetNick.lowercased()) { return }
            let dm = getOrCreateDM(targetNick)
            profileCache.fetchProfileIfPossible(nick: targetNick)
            if let ts = timestamp,
               let parsed = ISO8601DateFormatter.freeqTargets.date(from: ts) {
                if dm.messages.isEmpty || parsed > dm.lastActivity {
                    dm.lastActivity = parsed
                }
            }

        case .whoisReply(let whoisNick, let info):
            // Parse WHOIS for DID: "nick is authenticated as did:plc:xxx"
            // Or "nick is logged in as did:plc:xxx"
            if info.contains("authenticated as ") || info.contains("logged in as ") {
                let parts = info.split(separator: " ")
                if let did = parts.last, did.hasPrefix("did:") {
                    let didStr = String(did)
                    profileCache.setDid(didStr, for: whoisNick)
                    // Update member DID in all channels
                    for ch in channels {
                        if let idx = ch.members.firstIndex(where: { $0.nick.lowercased() == whoisNick.lowercased() }) {
                            let m = ch.members[idx]
                            if m.did == nil {
                                ch.members[idx] = MemberInfo(nick: m.nick, isOp: m.isOp, isHalfop: m.isHalfop, isVoiced: m.isVoiced, awayMsg: m.awayMsg, did: didStr)
                            }
                        }
                    }
                }
            }
            // Background WHOIS is for identity hydration only. Only explicit
            // user-triggered WHOIS replies should appear in chat; otherwise
            // protected channels can look like they have messages when they
            // merely received diagnostics for some other channel's members.
            if WhoisDisplayPolicy.shouldDisplay(explicitlyRequested: explicitWhoisRequests.contains(whoisNick.lowercased())),
               let ch = activeChannelState {
                ch.appendIfNew(ChatMessage(
                    id: UUID().uuidString, from: "server", text: info,
                    isAction: false, timestamp: Date(), replyTo: nil
                ))
            }

        case .notice(let text):
            switch ServerNoticeRouter.route(text) {
            case .ignore:
                return
            case .motdStart:
                motd = ""
                return
            case .motdLine(let line):
                motd += line + "\n"
                return
            case .motdEnd:
                if !motd.isEmpty { showMotd = true }
                return
            case .namesEnd(let channel):
                let key = channel.lowercased()
                // Ensure channel exists before flushing
                let ch = getOrCreateChannel(channel)
                if let members = pendingNames.removeValue(forKey: key) {
                    ch.members = members
                    // WHOIS each member to discover DIDs (background, rate-limited)
                    whoisMembers(members.map(\.nick))
                }
                requestHistory(channel: channel)
                return
            case .apiBearer(let sessionId):
                apiBearerSessionId = sessionId
                return
            case .channelAccessDenied(let channel, let reason):
                let ch = getOrCreateChannel(channel)
                ch.accessDeniedReason = reason
                ch.appendIfNew(ServerNoticeRouter.channelAccessMessage(channel: channel, reason: reason))
                if activeChannel == nil
                    || activeChannel?.lowercased() == channel.lowercased()
                    || activeChannelState == nil {
                    activeChannel = ch.name
                }
                return
            case .whoisDiagnostic(let whoisNick, let displayText):
                if WhoisDisplayPolicy.shouldDisplay(explicitlyRequested: explicitWhoisRequests.contains(whoisNick.lowercased())),
                   let ch = activeChannelState {
                    ch.appendIfNew(ChatMessage(
                        id: UUID().uuidString,
                        from: "server",
                        text: displayText,
                        isAction: false,
                        timestamp: Date(),
                        replyTo: nil
                    ))
                }
                return
            case .display(let displayText):
                if let ch = activeChannelState {
                    ch.appendIfNew(ChatMessage(
                        id: UUID().uuidString,
                        from: "server",
                        text: displayText,
                        isAction: false,
                        timestamp: Date(),
                        replyTo: nil
                    ))
                }
            }

        case .disconnected(let reason):
            connectionState = .disconnected
            // If we were in a call when the IRC connection dropped, tear it
            // down locally — peers only learn we left via the av-leave TAGMSG,
            // which we can't send on a dead wire.
            if isInCall {
                tearDownCallLocallyOnDisconnect()
            }
            if !reason.contains("intentional") && hasSavedSession {
                scheduleReconnect()
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
