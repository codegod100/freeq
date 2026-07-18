import XCTest
@testable import FreeqMacosCore

/// Pure block-list decisions (Models/Safety.swift): who's blocked, and which
/// message rows survive filtering. AppState only persists + wires these.
final class SafetyTests: XCTestCase {

    private func msg(_ id: String, from: String) -> ChatMessage {
        ChatMessage(id: id, from: from, text: "x", isAction: false,
                    timestamp: Date(timeIntervalSince1970: 1), replyTo: nil)
    }

    // MARK: - isBlocked

    func testBlockByNickIsCaseInsensitive() {
        var list = BlockList()
        list.block(nick: "Spammer", did: nil)
        XCTAssertTrue(list.isBlocked(nick: "spammer"))
        XCTAssertTrue(list.isBlocked(nick: "SPAMMER"))
        XCTAssertFalse(list.isBlocked(nick: "friend"))
    }

    func testBlockByDidSurvivesNickChange() {
        var list = BlockList()
        list.block(nick: "spammer", did: "did:plc:abc")
        // Same DID, new nick — still blocked.
        XCTAssertTrue(list.isBlocked(nick: "innocent-new-name", did: "did:plc:abc"))
        // Different person with a different DID is not.
        XCTAssertFalse(list.isBlocked(nick: "innocent-new-name", did: "did:plc:xyz"))
    }

    func testEmptyDidDoesNotBlockEveryone() {
        var list = BlockList()
        list.block(nick: "spammer", did: "")
        XCTAssertTrue(list.dids.isEmpty)  // empty DID never stored
        XCTAssertFalse(list.isBlocked(nick: "friend", did: ""))
    }

    // MARK: - unblock

    func testUnblockRemovesBothKeys() {
        var list = BlockList()
        list.block(nick: "Spammer", did: "did:plc:abc")
        list.unblock(nick: "spammer", did: "did:plc:abc")
        XCTAssertTrue(list.isEmpty)
        XCTAssertFalse(list.isBlocked(nick: "spammer", did: "did:plc:abc"))
    }

    func testNickInitializerLowercases() {
        let list = BlockList(nicks: ["Mixed", "CASE"])
        XCTAssertTrue(list.isBlocked(nick: "mixed"))
        XCTAssertTrue(list.isBlocked(nick: "case"))
    }

    // MARK: - visible (message-list filtering)

    func testVisibleHidesBlockedAuthorsMessages() {
        var list = BlockList()
        list.block(nick: "spammer", did: nil)
        let msgs = [msg("a", from: "friend"), msg("b", from: "Spammer"), msg("c", from: "friend")]
        XCTAssertEqual(list.visible(msgs, didFor: { _ in nil }).map(\.id), ["a", "c"])
    }

    func testVisibleHidesByResolvedDidEvenUnderNewNick() {
        var list = BlockList()
        list.block(nick: "oldnick", did: "did:plc:abc")
        let msgs = [msg("a", from: "newnick"), msg("b", from: "friend")]
        let out = list.visible(msgs, didFor: { $0 == "newnick" ? "did:plc:abc" : nil })
        XCTAssertEqual(out.map(\.id), ["b"])
    }

    func testVisibleAlwaysPassesSystemLines() {
        var list = BlockList()
        list.block(nick: "spammer", did: nil)
        let msgs = [msg("sys", from: ""), msg("b", from: "spammer")]
        XCTAssertEqual(list.visible(msgs, didFor: { _ in nil }).map(\.id), ["sys"])
    }

    func testVisibleIsPassthroughWhenNothingBlocked() {
        let list = BlockList()
        let msgs = [msg("a", from: "x"), msg("b", from: "y")]
        XCTAssertEqual(list.visible(msgs, didFor: { _ in
            XCTFail("must not resolve DIDs when the block list is empty")
            return nil
        }).map(\.id), ["a", "b"])
    }

    // MARK: - report targets & reasons

    func testReportReasonsAreNonEmptyAndEndWithCatchAll() {
        XCTAssertFalse(reportReasons.isEmpty)
        XCTAssertEqual(reportReasons.last, "Something else")
    }

    func testReportTargetIdentityDistinguishesMessageAndUserReports() {
        let user = ReportTarget(nick: "bob", did: "did:plc:abc")
        let message = ReportTarget(nick: "bob", did: "did:plc:abc", text: "offensive")
        XCTAssertNotEqual(user.id, message.id)
    }
}
