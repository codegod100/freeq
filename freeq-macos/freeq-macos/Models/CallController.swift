import AVFoundation
import Foundation
import ScreenCaptureKit
import Security

// MARK: - AV server endpoints

extension AppState {
    /// MoQ SFU base URL — the dedicated QUIC/WebTransport listener on :8080,
    /// the same endpoint the web client and iOS use. NOT the :443 reverse
    /// proxy, which serves an older, audio-starved WebSocket MoQ.
    var sfuBaseUrl: String {
        "https://\(avHost):8080"
    }

    /// REST API base for session discovery.
    var avApiBaseUrl: String {
        "https://\(avHost)"
    }

    /// Host portion of `serverAddress`, stripped of any `:port` suffix.
    private var avHost: String {
        serverAddress.split(separator: ":").first.map(String.init) ?? "irc.freeq.at"
    }
}

// MARK: - Call lifecycle

extension AppState {
    /// Outcome of a REST probe for an active session on a channel.
    enum ActiveSessionProbe {
        case found(sessionId: String)
        case none
    }

    /// 8-char lowercase hex per-device instance id.
    static func generateAvInstanceId() -> String {
        var bytes = [UInt8](repeating: 0, count: 4)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Start or join a voice session on a channel. Always resolves the
    /// channel's *live* session from the server before joining — the
    /// in-memory `activeAvSessions` cache can point at a dead session.
    func startOrJoinVoice(channel: String) {
        guard !isInCall else { return }
        Task { await discoverAndJoinOrStart(channel: channel) }
    }

    /// `/av leave` / `/av end` entrypoint used by the UI and slash command.
    func toggleCameraEnabled() { toggleCamera() }
    func toggleScreenShareEnabled() { toggleScreenShare() }

    private func discoverAndJoinOrStart(channel: String) async {
        let key = channel.lowercased()
        let encoded = channel.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? channel
        let url = URL(string: "\(avApiBaseUrl)/api/v1/channels/\(encoded)/sessions")

        if let url {
            var req = URLRequest(url: url)
            req.timeoutInterval = 4
            if let (data, _) = try? await URLSession.shared.data(for: req),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let active = json["active"] as? [String: Any],
                   let sessionState = active["state"] as? String,
                   sessionState == "Active",
                   let sessionId = active["id"] as? String {
                    await MainActor.run {
                        self.activeAvSessions[key] = sessionId
                        self.startCall(channel: channel, sessionId: sessionId)
                    }
                } else {
                    await MainActor.run {
                        self.activeAvSessions.removeValue(forKey: key)
                        self.startFreshAvSession(channel: channel)
                    }
                }
                return
            }
        }

        await MainActor.run {
            if let cached = self.activeAvSessions[key] {
                self.startCall(channel: channel, sessionId: cached)
            } else {
                self.startFreshAvSession(channel: channel)
            }
        }
    }

    /// Mint a per-device instance id, mark the channel pending, and put
    /// `av-start` on the wire. We join once the server echoes `started`.
    func startFreshAvSession(channel: String) {
        let instance = Self.generateAvInstanceId()
        currentAvInstance = instance
        pendingAvStart.insert(channel.lowercased())
        sendRaw("@+freeq.at/av-start;+freeq.at/av-instance=\(instance) TAGMSG \(channel)")
    }

    /// Construct the MoQ session, start mic capture, and announce the join.
    func startCall(channel: String, sessionId: String) {
        let instance = currentAvInstance ?? Self.generateAvInstanceId()
        currentAvInstance = instance
        do {
            let handler = AvCallbackHandler(appState: self)
            avSession = try FreeqAv(
                serverUrl: sfuBaseUrl,
                sessionId: sessionId,
                nick: nick,
                instanceId: instance,
                handler: handler
            )
            startLocalMic()
            if let out = preferredOutputDeviceId {
                try? avSession?.setOutputDevice(deviceId: out)
            }
            sendRaw("@+freeq.at/av-join;+freeq.at/av-id=\(sessionId);+freeq.at/av-instance=\(instance) TAGMSG \(channel)")
            // Fresh call — don't inherit mute/camera/expand from a prior one.
            isMuted = false
            isCameraOn = false
            isScreenSharing = false
            isCallExpanded = false
            participantsWithVideo = []
            callParticipants = []
            isInCall = true
            currentCallChannel = channel
            currentCallSessionId = sessionId
        } catch {
            print("[av] Failed to start call: \(error)")
            currentAvInstance = nil
        }
    }

    func leaveCall() {
        if let channel = currentCallChannel, let sessionId = currentCallSessionId {
            let instanceTag = currentAvInstance.map { ";+freeq.at/av-instance=\($0)" } ?? ""
            sendRaw("@+freeq.at/av-leave;+freeq.at/av-id=\(sessionId)\(instanceTag) TAGMSG \(channel)")
        }
        teardownLocal()
    }

    /// Tear down the call without sending `av-leave` (the wire is gone).
    func tearDownCallLocallyOnDisconnect() {
        teardownLocal()
    }

    private func teardownLocal() {
        cameraCapture?.stop()
        cameraCapture = nil
        screenCapture?.stop()
        screenCapture = nil
        micCapture?.stop()
        micCapture = nil
        localMicLevel = 0
        isLocalSpeaking = false
        avSession?.leave()
        avSession = nil
        currentAvInstance = nil
        isInCall = false
        isMuted = false
        isCameraOn = false
        isScreenSharing = false
        isCallExpanded = false
        callParticipants = []
        participantsWithVideo = []
        participantsWithScreen = []
        remoteAudioLevels = [:]
        callTransportStatus = nil
        currentCallChannel = nil
        currentCallSessionId = nil
    }

    func toggleMute() {
        isMuted.toggle()
        avSession?.setMuted(muted: isMuted)
        // Belt-and-suspenders: stop pushing frames across the FFI too. The
        // meter keeps running so the UI can hint "talking while muted".
        micCapture?.muted = isMuted
    }

    /// Switch the call microphone (nil = system default). Sticky across calls.
    func setMicDevice(uid: String?) {
        preferredMicUID = uid
        micCapture?.setPreferredDevice(uid: uid)
    }

    /// Switch the call camera (nil = default). Sticky across calls; applies
    /// live when the camera is on.
    func setCameraDevice(uid: String?) {
        preferredCameraUID = uid
        cameraCapture?.setPreferredDevice(uniqueID: uid)
    }

    /// Route remote audio to an output device (nil = system default).
    /// Playback lives in the Rust backend, so this goes over the FFI.
    func setOutputDevice(id: String?) {
        preferredOutputDeviceId = id
        do {
            try avSession?.setOutputDevice(deviceId: id)
        } catch {
            errorMessage = "Couldn't switch the speaker: \(error.localizedDescription)"
        }
    }

    /// Output devices for the speaker picker (empty when not in a call).
    func availableOutputDevices() -> [MediaDevice] {
        guard let av = avSession else { return [] }
        return MediaDeviceSelection.displayList(
            av.listOutputDevices().map { MediaDevice(id: $0.id, name: $0.name) }
        )
    }

    func toggleCamera() {
        let next = !isCameraOn
        if next { startLocalCamera() } else { stopLocalCamera() }
        isCameraOn = next
    }

    /// Share button / `/av screen`: when idle, present the system content
    /// picker (explicit source choice, no Screen Recording pre-grant needed);
    /// when sharing, stop.
    func toggleScreenShare() {
        guard isInCall else { return }
        if isScreenSharing {
            stopLocalScreenShare()
        } else if #available(macOS 14.0, *) {
            ScreenSharePickerController.shared.present(
                onPicked: { [weak self] filter in
                    self?.startLocalScreenShare(pickedFilter: filter)
                },
                onFailed: { [weak self] message in
                    self?.errorMessage = "Screen sharing failed: \(message)"
                }
            )
        } else {
            startLocalScreenShare()
        }
    }

    /// Share a specific display or window (from the quick-pick menu).
    /// Restarts the capture when already sharing so switching is one click.
    func startScreenShare(target: ScreenShareTarget?) {
        guard isInCall else { return }
        if isScreenSharing {
            stopLocalScreenShare(disableVideo: false)
        }
        startLocalScreenShare(target: target)
    }

    private func startLocalMic() {
        guard avSession != nil else { return }
        let cap = CallMicCapture()
        cap.onSamples = { [weak self] samples in
            self?.avSession?.pushAudioFrame(samples: samples)
        }
        cap.onLevel = { [weak self] update in
            guard let self else { return }
            self.localMicLevel = update.level
            self.isLocalSpeaking = update.isSpeaking
        }
        cap.onPermissionDenied = { [weak self] in
            self?.errorMessage = "Microphone access is denied. Enable it in "
                + "System Settings → Privacy & Security → Microphone, then rejoin the call."
        }
        cap.onError = { [weak self] message in
            self?.errorMessage = message
        }
        cap.setPreferredDevice(uid: preferredMicUID)
        cap.muted = isMuted
        micCapture = cap
        cap.start()
    }

    private func startLocalCamera() {
        guard let av = avSession else { return }
        if cameraCapture == nil {
            let cap = CallCameraCapture()
            cap.onFrame = { [weak self] ptr, length, width, height, ts in
                guard let av = self?.avSession else { return }
                let bytes = Array(UnsafeBufferPointer(start: ptr, count: length))
                av.pushVideoFrame(bgra: bytes, width: UInt32(width), height: UInt32(height), timestampUs: ts)
            }
            cap.onPermissionDenied = { [weak self] in
                guard let self else { return }
                self.isCameraOn = false
                self.errorMessage = "Camera access is denied. Enable it in "
                    + "System Settings → Privacy & Security → Camera, then try again."
            }
            cap.setPreferredDevice(uniqueID: preferredCameraUID)
            cap.effects.effect = cameraBackgroundEffect
            cameraCapture = cap
        }
        do {
            try av.setCameraEnabled(enabled: true)
        } catch {
            print("[av] setCameraEnabled(true) failed: \(error)")
            return
        }
        cameraCapture?.start()
    }

    private func stopLocalCamera() {
        cameraCapture?.stop()
        cameraCapture = nil
        do {
            try avSession?.setCameraEnabled(enabled: false)
        } catch {
            print("[av] setCameraEnabled(false): \(error)")
        }
    }

    /// Screen share publishes a second, video-only MoQ broadcast at
    /// `{our-path}/screen` (the web client's convention), so it runs
    /// alongside the camera instead of hijacking its track.
    private func startLocalScreenShare(target: ScreenShareTarget? = nil,
                                       pickedFilter: SCContentFilter? = nil) {
        guard let av = avSession else { return }
        let cap = CallScreenCapture()
        cap.target = target
        cap.pickedFilter = pickedFilter
        cap.onError = { [weak self] message in
            self?.errorMessage = message
        }
        cap.onFrame = { [weak self] ptr, length, width, height, ts in
            guard let av = self?.avSession else { return }
            let bytes = Array(UnsafeBufferPointer(start: ptr, count: length))
            av.pushScreenFrame(bgra: bytes, width: UInt32(width), height: UInt32(height), timestampUs: ts)
        }
        cap.onStopped = { [weak self] in
            guard let self else { return }
            self.screenCapture = nil
            if self.isScreenSharing {
                self.stopLocalScreenShare()
            }
        }
        screenCapture = cap
        do {
            try av.setScreenEnabled(enabled: true)
        } catch {
            print("[av] setScreenEnabled(true) failed: \(error)")
            errorMessage = "Screen sharing failed to start."
            screenCapture = nil
            return
        }
        isScreenSharing = true
        cap.start()
    }

    private func stopLocalScreenShare(disableVideo: Bool = true) {
        let cap = screenCapture
        screenCapture = nil
        cap?.onStopped = nil
        cap?.stop()
        isScreenSharing = false
        do {
            try avSession?.setScreenEnabled(enabled: false)
        } catch {
            print("[av] setScreenEnabled(false): \(error)")
        }
    }

    /// Called by `RemoteVideoTile`. Weakly retains the display layer.
    func bindVideoSink(nick: String, to layer: AVSampleBufferDisplayLayer) {
        remoteVideoLayers.setObject(layer, forKey: nick.lowercased() as NSString)
    }

    func videoLayer(for nick: String) -> AVSampleBufferDisplayLayer? {
        remoteVideoLayers.object(forKey: nick.lowercased() as NSString)
    }

    /// Called by `RemoteScreenTile`. Weakly retains the display layer.
    func bindScreenSink(nick: String, to layer: AVSampleBufferDisplayLayer) {
        remoteScreenLayers.setObject(layer, forKey: nick.lowercased() as NSString)
    }

    func screenLayer(for nick: String) -> AVSampleBufferDisplayLayer? {
        remoteScreenLayers.object(forKey: nick.lowercased() as NSString)
    }

    /// Handle an inbound `+freeq.at/av-state` TAGMSG.
    func handleAvState(_ avState: String, sessionId: String, actor: String, channel: String) {
        let chanKey = channel.lowercased()
        let inThisCall = isInCall && currentCallChannel?.lowercased() == chanKey
        switch avState {
        case "started":
            activeAvSessions[chanKey] = sessionId
            if pendingAvStart.contains(chanKey) && actor.lowercased() == nick.lowercased() {
                pendingAvStart.remove(chanKey)
                startCall(channel: channel, sessionId: sessionId)
            }
        case "ended":
            activeAvSessions.removeValue(forKey: chanKey)
            pendingAvStart.remove(chanKey)
            if inThisCall { tearDownCallLocallyOnDisconnect() }
        case "joined":
            if inThisCall,
               actor.lowercased() != nick.lowercased(),
               !callParticipants.contains(where: { $0.lowercased() == actor.lowercased() }) {
                callParticipants.append(actor)
            }
        case "left":
            if inThisCall {
                callParticipants.removeAll { $0.lowercased() == actor.lowercased() }
                participantsWithVideo = participantsWithVideo.filter { $0.lowercased() != actor.lowercased() }
                participantsWithScreen = participantsWithScreen.filter { $0.lowercased() != actor.lowercased() }
            }
        default:
            break
        }
    }
}

// MARK: - AV Event Handler

final class AvCallbackHandler: @unchecked Sendable, AvEventHandler {
    private weak var appState: AppState?

    init(appState: AppState) {
        self.appState = appState
    }

    func onAvEvent(event: AvEvent) {
        if Thread.isMainThread {
            handle(event: event)
        } else {
            DispatchQueue.main.async { [weak self] in self?.handle(event: event) }
        }
    }

    private func handle(event: AvEvent) {
        guard let state = appState else { return }
        switch event {
        case .connected:
            state.isInCall = true
        case .disconnected:
            state.tearDownCallLocallyOnDisconnect()
        case .participantJoined(let nick):
            if !state.callParticipants.contains(where: { $0.lowercased() == nick.lowercased() }) {
                state.callParticipants.append(nick)
            }
        case .participantLeft(let nick):
            state.callParticipants.removeAll { $0.lowercased() == nick.lowercased() }
            state.participantsWithVideo = state.participantsWithVideo.filter { $0.lowercased() != nick.lowercased() }
            state.participantsWithScreen = state.participantsWithScreen.filter { $0.lowercased() != nick.lowercased() }
        case .audioTrackStarted, .audioTrackStopped, .videoTrackStarted:
            break
        case .videoTrackStopped(let nick):
            state.participantsWithVideo = state.participantsWithVideo.filter { $0.lowercased() != nick.lowercased() }
        case .videoFrame(let nick, let bgra, let width, let height):
            // A frame from a nick we haven't seen means the join events raced
            // the media path — the SDK is delivering their video, so they're
            // in the call. Add them instead of dropping their frames.
            if !state.callParticipants.contains(where: { $0.lowercased() == nick.lowercased() }) {
                state.callParticipants.append(nick)
            }
            if let layer = state.videoLayer(for: nick) {
                // Pixel work happens on the render queue, not the main thread.
                VideoSampleBuffer.renderAsync(bgra: bgra, width: Int(width), height: Int(height), on: layer)
            }
            _ = state.participantsWithVideo.insert(nick)
        case .screenTrackStarted(let nick):
            _ = state.participantsWithScreen.insert(nick)
        case .screenTrackStopped(let nick):
            state.participantsWithScreen = state.participantsWithScreen.filter {
                $0.lowercased() != nick.lowercased()
            }
        case .screenFrame(let nick, let bgra, let width, let height):
            _ = state.participantsWithScreen.insert(nick)
            if let layer = state.screenLayer(for: nick) {
                VideoSampleBuffer.renderAsync(bgra: bgra, width: Int(width), height: Int(height), on: layer)
            }
        case .audioLevel(let nick, let level):
            // R1: remote playout level → active-speaker highlighting.
            state.remoteAudioLevels[nick.lowercased()] = level
        case .reconnecting(let attempt):
            // Inline call-bar status, NOT errorMessage (which is a modal
            // alert) — automatic recovery shouldn't look like a failure.
            state.callTransportStatus = attempt <= 1
                ? "Reconnecting…" : "Reconnecting… (attempt \(attempt))"
        case .reconnected:
            state.callTransportStatus = nil
        case .error(let message):
            print("[av] Error: \(message)")
        }
    }
}
