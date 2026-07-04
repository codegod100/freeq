import XCTest
@testable import FreeqMacosCore

/// Failing-first tests for the "things like delete that might be wrong" sweep:
/// author-action target resolution, delete authorization, and deleted-message
/// exclusion. Each is a pure decision AppState should delegate to, so the
/// wiring is covered instead of duplicated inline.
final class MessageActionsTests: XCTestCase {

    private func msg(_ id: String, from: String, _ text: String = "x",
                     deleted: Bool = false, action: Bool = false,
                     at t: TimeInterval) -> ChatMessage {
        ChatMessage(id: id, from: from, text: text, isAction: action,
                    timestamp: Date(timeIntervalSince1970: t), replyTo: nil,
                    isDeleted: deleted)
    }

    // MARK: - lastEditable (powers ↑-edit and /delete with no id)

    func testLastEditablePicksMyMostRecentMessage() {
        let msgs = [
            msg("a", from: "me", at: 1),
            msg("b", from: "other", at: 2),
            msg("c", from: "me", at: 3),
        ]
        XCTAssertEqual(MessageActions.lastEditable(messages: msgs, nick: "me")?.id, "c")
    }

    func testLastEditableSkipsMyDeletedMessage() {
        // The reported-adjacent bug: after deleting your last message, editing
        // "the last one" must not re-target the tombstone.
        let msgs = [
            msg("a", from: "me", at: 1),
            msg("b", from: "me", deleted: true, at: 2),
        ]
        XCTAssertEqual(MessageActions.lastEditable(messages: msgs, nick: "me")?.id, "a")
    }

    func testLastEditableSkipsActionLines() {
        // /me actions and server "pinned a message" lines carry no editable id.
        let msgs = [
            msg("a", from: "me", at: 1),
            msg("b", from: "me", action: true, at: 2),
        ]
        XCTAssertEqual(MessageActions.lastEditable(messages: msgs, nick: "me")?.id, "a")
    }

    func testLastEditableIsCaseInsensitiveOnNick() {
        let msgs = [msg("a", from: "Me", at: 1)]
        XCTAssertEqual(MessageActions.lastEditable(messages: msgs, nick: "me")?.id, "a")
    }

    func testLastEditableNilWhenNoneOfMine() {
        let msgs = [msg("a", from: "other", at: 1)]
        XCTAssertNil(MessageActions.lastEditable(messages: msgs, nick: "me"))
    }

    // MARK: - canDelete (authorization)

    func testAuthorCanDeleteOwnMessage() {
        let m = msg("a", from: "me", at: 1)
        XCTAssertTrue(MessageActions.canDelete(m, by: "me", isOp: false))
    }

    func testNonAuthorNonOpCannotDelete() {
        let m = msg("a", from: "other", at: 1)
        XCTAssertFalse(MessageActions.canDelete(m, by: "me", isOp: false))
    }

    func testOpCanDeleteAnyone() {
        let m = msg("a", from: "other", at: 1)
        XCTAssertTrue(MessageActions.canDelete(m, by: "me", isOp: true))
    }

    func testCannotDeleteAnAlreadyDeletedMessage() {
        let m = msg("a", from: "me", deleted: true, at: 1)
        XCTAssertFalse(MessageActions.canDelete(m, by: "me", isOp: true))
    }

    // MARK: - searchMatches (excludes deleted)

    func testSearchExcludesDeleted() {
        let msgs = [
            msg("a", from: "me", "hello world", at: 1),
            msg("b", from: "me", "hello there", deleted: true, at: 2),
        ]
        let hits = MessageActions.searchMatches(msgs, query: "hello")
        XCTAssertEqual(hits.map(\.id), ["a"])
    }

    func testSearchMatchesTextOrSender() {
        let msgs = [
            msg("a", from: "alice", "nothing here", at: 1),
            msg("b", from: "me", "find me", at: 2),
        ]
        XCTAssertEqual(MessageActions.searchMatches(msgs, query: "alice").map(\.id), ["a"])
        XCTAssertEqual(MessageActions.searchMatches(msgs, query: "find").map(\.id), ["b"])
    }

    func testSearchIsCaseInsensitiveAndEmptyQueryMatchesNothing() {
        let msgs = [msg("a", from: "me", "Hello", at: 1)]
        XCTAssertEqual(MessageActions.searchMatches(msgs, query: "HELLO").map(\.id), ["a"])
        XCTAssertTrue(MessageActions.searchMatches(msgs, query: "").isEmpty)
    }
}
