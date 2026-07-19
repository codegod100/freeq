import AppIntents
import Foundation

/// App Intents expose freeq's core actions to Shortcuts, Spotlight, and — the
/// reason this matters more here than in a typical app — to *agents* and
/// automation, which is directly on-brand for freeq's agent-native pitch.
/// Each intent drives the one live `AppState` (`AppState.current`), the same
/// path the UI and command palette use.

enum FreeqIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notRunning
    case notConnected
    case noTarget
    case notInCall

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notRunning: "freeq isn't running."
        case .notConnected: "freeq isn't connected — open it and sign in first."
        case .noTarget: "No channel specified and no channel is currently open."
        case .notInCall: "You're not in a call."
        }
    }
}

@MainActor
private func requireConnectedApp() throws -> AppState {
    guard let app = AppState.current else { throw FreeqIntentError.notRunning }
    guard app.connectionState == .registered || app.connectionState == .connected else {
        throw FreeqIntentError.notConnected
    }
    return app
}

struct SendFreeqMessageIntent: AppIntent {
    static var title: LocalizedStringResource = "Send a Message"
    static var description = IntentDescription("Send a message to a freeq channel or DM.")
    static var openAppWhenRun = false

    @Parameter(title: "Message") var message: String
    @Parameter(title: "Channel or person", description: "Defaults to the currently open conversation.")
    var channel: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Send \(\.$message) to \(\.$channel)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let app = try requireConnectedApp()
        guard let target = channel ?? app.activeChannel, !target.isEmpty else {
            throw FreeqIntentError.noTarget
        }
        app.submitInput(message, target: target)
        return .result(dialog: "Sent to \(target).")
    }
}

struct OpenFreeqConversationIntent: AppIntent {
    static var title: LocalizedStringResource = "Open a Conversation"
    static var description = IntentDescription("Bring freeq forward and open a channel or DM.")
    static var openAppWhenRun = true

    @Parameter(title: "Channel or person") var channel: String

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$channel) in freeq")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let app = AppState.current else { throw FreeqIntentError.notRunning }
        if channel.hasPrefix("#") {
            app.activeChannel = channel
        } else {
            // A person: route through openDM so a spoken/typed nick lands on
            // the canonical (DID-keyed) thread instead of a nonexistent
            // nick-keyed buffer.
            app.openDM(with: channel)
        }
        return .result()
    }
}

struct ToggleFreeqMuteIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle Mute"
    static var description = IntentDescription("Mute or unmute yourself in the current freeq call.")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let app = try requireConnectedApp()
        guard app.isInCall else { throw FreeqIntentError.notInCall }
        app.toggleMute()
        return .result(dialog: app.isMuted ? "Muted." : "Unmuted.")
    }
}

struct JoinFreeqCallIntent: AppIntent {
    static var title: LocalizedStringResource = "Join or Start a Call"
    static var description = IntentDescription("Join the call in a channel, starting one if needed.")
    static var openAppWhenRun = true

    @Parameter(title: "Channel") var channel: String

    static var parameterSummary: some ParameterSummary {
        Summary("Join the call in \(\.$channel)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let app = try requireConnectedApp()
        app.activeChannel = channel
        app.startOrJoinVoice(channel: channel)
        return .result()
    }
}

struct LeaveFreeqCallIntent: AppIntent {
    static var title: LocalizedStringResource = "Leave the Call"
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let app = try requireConnectedApp()
        guard app.isInCall else { throw FreeqIntentError.notInCall }
        app.leaveCall()
        return .result(dialog: "Left the call.")
    }
}

struct SetFreeqStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Away Status"
    static var description = IntentDescription("Set or clear your freeq away status.")
    static var openAppWhenRun = false

    @Parameter(title: "Away", description: "Turn away on or off.") var away: Bool
    @Parameter(title: "Reason") var reason: String?

    static var parameterSummary: some ParameterSummary {
        When(\.$away, .equalTo, true) {
            Summary("Set away with reason \(\.$reason)")
        } otherwise: {
            Summary("Clear away status")
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let app = try requireConnectedApp()
        if away {
            app.setAway(reason?.isEmpty == false ? reason : "AFK")
            return .result(dialog: "You're now away.")
        } else {
            app.setAway(nil)
            return .result(dialog: "You're back.")
        }
    }
}

struct FreeqShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SendFreeqMessageIntent(),
            phrases: ["Send a message with \(.applicationName)",
                      "Post to \(.applicationName)"],
            shortTitle: "Send Message",
            systemImageName: "paperplane")
        AppShortcut(
            intent: OpenFreeqConversationIntent(),
            phrases: ["Open a conversation in \(.applicationName)",
                      "Open \(.applicationName)"],
            shortTitle: "Open Conversation",
            systemImageName: "bubble.left.and.bubble.right")
        AppShortcut(
            intent: JoinFreeqCallIntent(),
            phrases: ["Join a call in \(.applicationName)",
                      "Start a call in \(.applicationName)"],
            shortTitle: "Join Call",
            systemImageName: "phone")
        AppShortcut(
            intent: ToggleFreeqMuteIntent(),
            phrases: ["Toggle mute in \(.applicationName)",
                      "Mute \(.applicationName)"],
            shortTitle: "Toggle Mute",
            systemImageName: "mic.slash")
        AppShortcut(
            intent: SetFreeqStatusIntent(),
            phrases: ["Set my \(.applicationName) status",
                      "Set away in \(.applicationName)"],
            shortTitle: "Set Away",
            systemImageName: "moon")
    }
}
