import Foundation

/// A single chat message.
///
/// Pure Foundation model — no UIKit/SwiftUI/ActivityKit — so it (and the
/// `MessageActions` decisions that operate on it) compile under the SwiftPM
/// test harness. Kept field-for-field in sync with the macOS `ChatMessage`.
struct ChatMessage: Identifiable, Equatable {
    var id: String  // msgid or UUID
    let from: String
    var text: String
    let isAction: Bool
    let timestamp: Date
    let replyTo: String?
    var isEdited: Bool = false
    var isDeleted: Bool = false
    var isSigned: Bool = false
    // Origin server name when relayed from a federated peer (+freeq.at/origin).
    // nil = locally-originated. Drives "via {origin}" + suppresses the local
    // verified/signed badges, which would overstate trust for a peer-vouched msg.
    var origin: String? = nil
    var reactions: [String: Set<String>] = [:]  // emoji -> set of nicks

    static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool {
        lhs.id == rhs.id
    }
}
