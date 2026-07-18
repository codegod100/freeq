import Foundation
import SwiftUI
import WatchConnectivity

/// Watch-side WC bridge. Receives snapshots from the phone, sends reply
/// requests back. Drives the SwiftUI views as an ObservableObject.
final class WatchSession: NSObject, ObservableObject {
    @Published var snapshot: WatchSnapshot? = nil
    @Published var sending: Bool = false
    @Published var error: String? = nil

    private let session: WCSession? = WCSession.isSupported() ? WCSession.default : nil

    func activate() {
        session?.delegate = self
        if session?.activationState != .activated {
            session?.activate()
        }
    }

    /// Send a message via the phone. Returns true if the phone accepted it.
    @discardableResult
    func sendMessage(target: String, text: String) async -> Bool {
        guard let session, session.isReachable else {
            await MainActor.run { self.error = "Phone unreachable" }
            return false
        }
        guard let data = try? JSONEncoder().encode(WatchSendRequest(target: target, text: text)) else {
            return false
        }
        await MainActor.run { self.sending = true }
        return await withCheckedContinuation { cont in
            session.sendMessage([WatchKeys.sendRequest: data]) { reply in
                Task { @MainActor in self.sending = false }
                cont.resume(returning: (reply["ok"] as? Bool) ?? false)
            } errorHandler: { err in
                Task { @MainActor in
                    self.sending = false
                    self.error = err.localizedDescription
                }
                cont.resume(returning: false)
            }
        }
    }

    private func ingest(snapshotData: Data) {
        guard let snap = try? JSONDecoder().decode(WatchSnapshot.self, from: snapshotData) else { return }
        Task { @MainActor in
            self.snapshot = snap
        }
    }
}

extension WatchSession: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        // No-op; we'll receive the first context push imminently.
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String : Any]) {
        if let data = applicationContext[WatchKeys.snapshot] as? Data {
            ingest(snapshotData: data)
        }
    }
}
