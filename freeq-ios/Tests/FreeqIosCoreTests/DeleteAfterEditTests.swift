import XCTest
@testable import FreeqIosCore

/// Deleting an *edited* message must still work.
///
/// `applyEdit` rewrites the in-memory id to the edit's msgid and records the
/// chain root in `editOf` (so chained edits keep matching). Deletes always name
/// the ORIGINAL msgid — that is the identity clients hold and what the server
/// relays in `+draft/delete`. `applyDelete` went through
/// `findMessage(byId:)`, which matches `id` only, so after any edit the delete
/// found nothing and the message stayed on screen even though the server had
/// removed it.
final class DeleteAfterEditTests: XCTestCase {
    private func msg(_ id: String, _ text: String = "hi") -> ChatMessage {
        ChatMessage(id: id, from: "alice", text: text, isAction: false,
                    timestamp: Date(timeIntervalSince1970: 0), replyTo: nil)
    }

    func testDeleteByOriginalIdAfterEdit() {
        let ch = ChannelState(name: "#t")
        ch.appendIfNew(msg("orig", "secret v1"))
        ch.applyEdit(originalId: "orig", newId: "edit1", newText: "secret v2")
        // Sanity: the edit re-keyed the row.
        XCTAssertEqual(ch.messages.first?.id, "edit1")
        XCTAssertEqual(ch.messages.first?.editOf, "orig")

        ch.applyDelete(msgId: "orig")

        let m = ch.messages.first
        XCTAssertEqual(m?.isDeleted, true, "delete naming the original msgid must apply")
        XCTAssertEqual(m?.text, "")
    }

    func testDeleteByEditIdStillWorks() {
        // The other end of the chain: whichever id the caller holds must work.
        let ch = ChannelState(name: "#t")
        ch.appendIfNew(msg("orig", "v1"))
        ch.applyEdit(originalId: "orig", newId: "edit1", newText: "v2")
        ch.applyDelete(msgId: "edit1")
        XCTAssertEqual(ch.messages.first?.isDeleted, true)
    }

    func testDeleteDoesNotTouchUnrelatedMessages() {
        let ch = ChannelState(name: "#t")
        ch.appendIfNew(msg("orig", "v1"))
        ch.appendIfNew(msg("other", "keep me"))
        ch.applyEdit(originalId: "orig", newId: "edit1", newText: "v2")
        ch.applyDelete(msgId: "orig")
        let other = ch.messages.first(where: { $0.text == "keep me" })
        XCTAssertEqual(other?.isDeleted, false)
    }
}
