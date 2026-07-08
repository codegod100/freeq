import Foundation
import SwiftUI

/// A channel with its messages and members.
@Observable
class ChannelState: Identifiable {
    let name: String
    var messages: [ChatMessage] = []
    var members: [MemberInfo] = []
    var topic: String = ""
    var topicSetBy: String?
    var pinnedMessages: [ChatMessage] = []
    var typingUsers: [String: Date] = [:]
    var lastActivity: Date = Date()
    var isEncrypted: Bool = false
    var accessDeniedReason: String?

    var id: String { name }
    var isChannel: Bool { name.hasPrefix("#") }
    var isDM: Bool { !name.hasPrefix("#") }

    /// Members collapsed to one row per account (same DID). Multi-session or
    /// nick-collision twins (e.g. chadfowler.com / chadfowlercom, or a bot that
    /// reconnected N times) count once. DID resolves from the roster or the
    /// profile cache; guests (no resolvable DID) are kept. Prefers the fuller
    /// (dotted) handle for display. Single source for member lists + counts.
    var uniqueMembers: [MemberInfo] {
        var indexByDid: [String: Int] = [:]
        var out: [MemberInfo] = []
        for m in members {
            guard let did = m.did ?? ProfileCache.shared.did(for: m.nick) else {
                out.append(m); continue
            }
            if let idx = indexByDid[did] {
                if m.nick.contains("."), !out[idx].nick.contains(".") { out[idx] = m }
            } else {
                indexByDid[did] = out.count
                out.append(m)
            }
        }
        return out
    }

    var uniqueMemberCount: Int { uniqueMembers.count }
    var hasVisibleMessages: Bool { messages.contains { !$0.isDeleted } }

    var activeTypers: [String] {
        let cutoff = Date().addingTimeInterval(-5)
        return typingUsers.filter { $0.value > cutoff }.map(\.key).sorted()
    }

    private var messageIds: Set<String> = []

    init(name: String) {
        self.name = name
    }

    func findMessage(byId id: String) -> Int? {
        messages.firstIndex(where: { $0.id == id })
    }

    func memberInfo(for nick: String) -> MemberInfo? {
        members.first(where: { $0.nick.lowercased() == nick.lowercased() })
    }

    /// Append a message only if its ID hasn't been seen before.
    func appendIfNew(_ msg: ChatMessage) {
        guard !messageIds.contains(msg.id) else { return }
        messageIds.insert(msg.id)

        if let last = messages.last, msg.timestamp < last.timestamp {
            let idx = messages.firstIndex(where: { $0.timestamp > msg.timestamp }) ?? messages.endIndex
            messages.insert(msg, at: idx)
        } else {
            messages.append(msg)
        }
        if msg.timestamp > lastActivity {
            lastActivity = msg.timestamp
        }
    }

    func applyEdit(originalId: String, newId: String?, newText: String) {
        if let idx = findMessage(byId: originalId) {
            messages[idx].text = newText
            messages[idx].isEdited = true
            if let newId {
                messages[idx].id = newId
                messageIds.insert(newId)
            }
        }
    }

    func applyDelete(msgId: String) {
        if let idx = findMessage(byId: msgId) {
            messages[idx].isDeleted = true
            messages[idx].text = ""
        }
    }

    func applyReaction(msgId: String, emoji: String, from: String) {
        if let idx = findMessage(byId: msgId) {
            var reactions = messages[idx].reactions
            var nicks = reactions[emoji] ?? Set()
            if nicks.contains(from) {
                nicks.remove(from)
                if nicks.isEmpty { reactions.removeValue(forKey: emoji) }
                else { reactions[emoji] = nicks }
            } else {
                nicks.insert(from)
                reactions[emoji] = nicks
            }
            messages[idx].reactions = reactions
        }
    }

    func addReaction(msgId: String, emoji: String, from: String) {
        guard !emoji.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let idx = findMessage(byId: msgId) else { return }
        var reactions = messages[idx].reactions
        var nicks = reactions[emoji] ?? Set()
        nicks.insert(from)
        reactions[emoji] = nicks
        messages[idx].reactions = reactions
    }

    func removeReaction(msgId: String, emoji: String, from: String) {
        guard let idx = findMessage(byId: msgId),
              var nicks = messages[idx].reactions[emoji] else { return }
        nicks.remove(from)
        if nicks.isEmpty {
            messages[idx].reactions.removeValue(forKey: emoji)
        } else {
            messages[idx].reactions[emoji] = nicks
        }
    }

    func hasReaction(msgId: String, emoji: String, from: String) -> Bool {
        guard let idx = findMessage(byId: msgId) else { return false }
        return messages[idx].reactions[emoji]?.contains(from) ?? false
    }
}
