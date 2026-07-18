import CallKit
import AVFoundation

/// Makes a freeq voice call feel like a real call: reports it to the system via
/// CallKit so it shows in Recents, gets the green status-bar pill and
/// lock-screen call controls, and integrates the hardware/AirPods mute + End
/// button — all while freeq keeps managing its own audio session and the Rust
/// AV engine (we deliberately do NOT let CallKit take over audio, so the
/// existing, working call path is untouched).
///
/// Incoming ring-on-locked-device needs PushKit + APNs (server + paid account),
/// a separate step; this covers the on-device call surface available today.
///
/// Master-flagged: if CallKit ever fights the audio path, set `enabled = false`
/// and the whole integration no-ops.
final class CallKitManager: NSObject {
    static let shared = CallKitManager()

    /// Master switch. Flip to false to fully disable CallKit reporting.
    static let enabled = true

    private let provider: CXProvider
    private let controller = CXCallController()
    private var currentCallID: UUID?

    /// Wired by AppState so the system End / Mute buttons drive the real call.
    var onEnd: (() -> Void)?
    var onSetMuted: ((Bool) -> Void)?

    override init() {
        let config = CXProviderConfiguration()
        config.supportsVideo = true
        config.maximumCallsPerCallGroup = 1
        config.supportedHandleTypes = [.generic]
        config.includesCallsInRecents = true
        provider = CXProvider(configuration: config)
        super.init()
        provider.setDelegate(self, queue: nil) // main queue
    }

    /// Report that we've joined a freeq voice call — surfaces it as an active
    /// system call. `channel` is the human label shown in the system UI.
    func reportStarted(channel: String) {
        guard Self.enabled, currentCallID == nil else { return }
        let id = UUID()
        currentCallID = id
        let handle = CXHandle(type: .generic, value: channel)
        let start = CXStartCallAction(call: id, handle: handle)
        start.isVideo = false
        controller.request(CXTransaction(action: start)) { [weak self] error in
            guard let self else { return }
            if let error {
                // Couldn't register the call with the system — drop our handle
                // so freeq's own call continues unaffected.
                print("[callkit] start failed: \(error.localizedDescription)")
                self.currentCallID = nil
                return
            }
            let update = CXCallUpdate()
            update.remoteHandle = handle
            update.localizedCallerName = channel
            update.hasVideo = false
            update.supportsHolding = false
            update.supportsGrouping = false
            update.supportsUngrouping = false
            self.provider.reportCall(with: id, updated: update)
            // Already in the call — mark connected immediately (no ringing).
            self.provider.reportOutgoingCall(with: id, connectedAt: nil)
        }
    }

    /// The freeq call ended (user left, or transport tore down) — clear the
    /// system call.
    func reportEnded() {
        guard let id = currentCallID else { return }
        currentCallID = nil
        provider.reportCall(with: id, endedAt: nil, reason: .remoteEnded)
    }

    /// Reflect a mute change freeq made itself (in-app mic button) onto the
    /// system call UI, so the two stay in sync.
    func reflectMuted(_ muted: Bool) {
        guard Self.enabled, let id = currentCallID else { return }
        let action = CXSetMutedCallAction(call: id, muted: muted)
        controller.request(CXTransaction(action: action)) { _ in }
    }
}

extension CallKitManager: CXProviderDelegate {
    func providerDidReset(_ provider: CXProvider) {
        currentCallID = nil
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        // freeq already engaged the audio + AV engine before reporting; nothing
        // more to do here.
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        // System End / lock-screen hang-up → tear down the real call.
        currentCallID = nil
        onEnd?()
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        onSetMuted?(action.isMuted)
        action.fulfill()
    }

    // freeq owns its audio session; CallKit's activate/deactivate are no-ops.
    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {}
    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {}
}
