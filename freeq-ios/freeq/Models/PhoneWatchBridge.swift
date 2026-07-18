import Foundation
#if canImport(WatchConnectivity)
import WatchConnectivity
#endif

/// Phone-side bridge to the watchOS companion. Listens for "send a message"
/// requests from the watch, and pushes channel/DM snapshots to the watch
/// whenever the phone's state changes meaningfully.
@MainActor
final class PhoneWatchBridge: NSObject {
    static let shared = PhoneWatchBridge()
    weak var appState: AppState?

#if canImport(WatchConnectivity)
    private var session: WCSession? {
        guard WCSession.isSupported() else { return nil }
        return WCSession.default
    }
#endif

    func attach(_ state: AppState) {
        self.appState = state
#if canImport(WatchConnectivity)
        guard let session else { return }
        session.delegate = self
        if session.activationState != .activated {
            session.activate()
        }
        // Initial snapshot so the watch has something to show on first launch.
        push()
#endif
    }

    /// Push the current state to the watch. Cheap to call — gated on payload
    /// changes so we don't spam WatchConnectivity.
    func push() {
#if canImport(WatchConnectivity)
        guard let session, session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else {
            return
        }
        guard let snapshot = currentSnapshot() else { return }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        do {
            try session.updateApplicationContext([WatchKeys.snapshot: data])
        } catch {
            // updateApplicationContext throws if you call it before activation
            // completes; harmless on a phone without a paired watch.
        }
#endif
    }

    private func currentSnapshot() -> WatchSnapshot? {
        guard let state = appState else { return nil }
        let buffers: [WatchBufferSummary] = (state.channels + state.dmBuffers).map { ch in
            let last = ch.messages.last(where: { !$0.from.isEmpty && !$0.isDeleted })
            return WatchBufferSummary(
                name: ch.name,
                unread: state.unreadCounts[ch.name] ?? 0,
                lastFrom: last?.from,
                lastText: last?.text,
                lastAt: last?.timestamp,
                isChannel: ch.name.hasPrefix("#") || ch.name.hasPrefix("&")
            )
        }
        // Keep the last 10 messages per buffer to fit comfortably in the
        // applicationContext payload.
        var recent: [String: [WatchMessage]] = [:]
        for ch in (state.channels + state.dmBuffers) {
            let tail = ch.messages.suffix(10).map { msg in
                WatchMessage(msgid: msg.id, from: msg.from, text: msg.text, at: msg.timestamp)
            }
            recent[ch.name] = Array(tail)
        }
        return WatchSnapshot(
            nick: state.nick,
            connected: state.connectionState == .registered,
            buffers: buffers,
            recent: recent
        )
    }
}

#if canImport(WatchConnectivity)
extension PhoneWatchBridge: WCSessionDelegate {
    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        Task { @MainActor in self.push() }
    }
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // Re-activate so a different watch can pair.
        WCSession.default.activate()
    }

    /// The watch sent us a request — currently only "send this PRIVMSG".
    nonisolated func session(_ session: WCSession,
                             didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        guard let data = message[WatchKeys.sendRequest] as? Data,
              let req = try? JSONDecoder().decode(WatchSendRequest.self, from: data) else {
            replyHandler(["ok": false])
            return
        }
        Task { @MainActor in
            let ok = self.appState?.sendMessage(target: req.target, text: req.text) ?? false
            replyHandler(["ok": ok])
        }
    }
}
#endif
