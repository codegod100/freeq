import AppIntents
import Foundation

// MARK: - Channel Entity

/// A channel or DM, exposed to the App Intents framework so Siri / Shortcuts /
/// Spotlight can find one and pass it to an action.
struct ChannelEntity: AppEntity, Identifiable {
    let id: String
    /// Human name — the peer's nick for DID-keyed DM buffers.
    var name: String = ""

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(
            name: LocalizedStringResource("Channel"),
            numericFormat: "\(placeholder: .int) channels"
        )
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name.isEmpty ? id : name)")
    }

    static var defaultQuery = ChannelQuery()
}

/// Queries `AppState.shared` for channels + DM buffers — the same lists the
/// chat list pane shows.
struct ChannelQuery: EntityQuery {
    func entities(for identifiers: [ChannelEntity.ID]) async throws -> [ChannelEntity] {
        let all = await all()
        let set = Set(identifiers)
        return all.filter { set.contains($0.id) }
    }

    func suggestedEntities() async throws -> [ChannelEntity] {
        await all()
    }

    @MainActor
    private func all() async -> [ChannelEntity] {
        guard let state = AppState.shared else { return [] }
        let names = state.channels.map { $0.name } + state.dmBuffers.map { $0.name }
        return names.map { ChannelEntity(id: $0, name: state.displayNameForKey($0)) }
    }
}

// MARK: - Open channel

struct OpenChannelIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Channel"
    static var description = IntentDescription("Open a freeq channel or DM.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Channel", requestValueDialog: "Which channel?")
    var channel: ChannelEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let state = AppState.shared else {
            throw $channel.needsValueError("freeq isn't running yet — open the app first.")
        }
        let name = channel.id
        if name.hasPrefix("#") || name.hasPrefix("&") {
            state.activeChannel = name
        } else {
            state.pendingDMNick = name
        }
        return .result()
    }
}

// MARK: - Send message

struct SendMessageIntent: AppIntent {
    static var title: LocalizedStringResource = "Send Message"
    static var description = IntentDescription("Send a message to a freeq channel or DM.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Channel", requestValueDialog: "Which channel?")
    var channel: ChannelEntity

    @Parameter(title: "Message", requestValueDialog: "What's your message?")
    var text: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let state = AppState.shared else {
            return .result(dialog: "freeq isn't running.")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .result(dialog: "Empty message — nothing sent.")
        }
        let ok = state.sendMessage(target: channel.id, text: trimmed)
        if ok {
            return .result(dialog: "Sent to \(channel.id).")
        } else {
            return .result(dialog: "Couldn't send to \(channel.id) — not connected.")
        }
    }
}

// MARK: - Read latest

struct ReadLatestIntent: AppIntent {
    static var title: LocalizedStringResource = "Read Latest"
    static var description = IntentDescription("Read the most recent messages in a freeq channel or DM.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Channel", requestValueDialog: "Which channel?")
    var channel: ChannelEntity

    @Parameter(title: "How many", default: 5)
    var count: Int

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let state = AppState.shared else {
            return .result(dialog: "freeq isn't running.")
        }
        let buffer = state.channels.first { $0.name == channel.id }
            ?? state.dmBuffers.first { $0.name == channel.id }
        guard let buffer else {
            return .result(dialog: "I don't see \(channel.id) in your channel list.")
        }
        let recent = buffer.messages
            .filter { !$0.from.isEmpty && !$0.isDeleted }
            .suffix(max(1, min(count, 20)))
        if recent.isEmpty {
            return .result(dialog: "\(channel.id) is empty.")
        }
        let summary = recent.map { "\($0.from): \($0.text)" }.joined(separator: ". ")
        return .result(dialog: "From \(channel.id). \(summary)")
    }
}

// MARK: - Start call

struct StartCallIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Call"
    static var description = IntentDescription("Start or join the voice call in a freeq channel.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Channel", requestValueDialog: "Which channel?")
    var channel: ChannelEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let state = AppState.shared else {
            throw $channel.needsValueError("freeq isn't running yet — open the app first.")
        }
        // Calls are channel-only; route to the channel and start/join voice.
        let name = channel.id
        guard name.hasPrefix("#") || name.hasPrefix("&") else {
            return .result()
        }
        state.activeChannel = name
        state.startOrJoinVoice(channel: name)
        return .result()
    }
}

// MARK: - Shortcuts surfacing

struct FreeqShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenChannelIntent(),
            phrases: [
                "Open \(\.$channel) in \(.applicationName)",
                "Show \(\.$channel) in \(.applicationName)"
            ],
            shortTitle: "Open Channel",
            systemImageName: "number"
        )
        AppShortcut(
            intent: SendMessageIntent(),
            phrases: [
                "Send a message in \(.applicationName)",
                "Post to \(\.$channel) in \(.applicationName)"
            ],
            shortTitle: "Send Message",
            systemImageName: "paperplane"
        )
        AppShortcut(
            intent: ReadLatestIntent(),
            phrases: [
                "What's new in \(\.$channel) on \(.applicationName)",
                "Read latest from \(\.$channel) in \(.applicationName)"
            ],
            shortTitle: "Read Latest",
            systemImageName: "speaker.wave.2"
        )
        AppShortcut(
            intent: StartCallIntent(),
            phrases: [
                "Start a call in \(\.$channel) on \(.applicationName)",
                "Join the call in \(\.$channel) on \(.applicationName)"
            ],
            shortTitle: "Start Call",
            systemImageName: "phone.fill"
        )
    }
}
