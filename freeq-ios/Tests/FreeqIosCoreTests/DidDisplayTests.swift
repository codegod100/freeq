import XCTest
@testable import FreeqIosCore

/// DID-keyed DM identity helpers — iOS port of the shared suite (Android
/// DidDisplayTest, macOS DidDisplayTests). DM buffers key by the SDK's
/// dm_key (peer DID when known, else nick); these helpers keep a raw
/// `did:…` from ever rendering and fold a nick-keyed thread into its
/// DID-keyed one when the binding is learned — including via the
/// conversation list's partner-did, which covers OFFLINE peers.
final class DidDisplayTests: XCTestCase {

    private let plc = "did:plc:k2n3e2vsihf3farequ44t5j7"
    private let key = "did:key:z6MkhaXgBZDvotDkL5257faiztiGiC2QtKLGpbnnEGta2doK"

    private func msg(_ id: String, _ text: String = "hi",
                     at t: TimeInterval = 0, from: String = "alice") -> ChatMessage {
        ChatMessage(id: id, from: from, text: text, isAction: false,
                    timestamp: Date(timeIntervalSince1970: t), replyTo: nil)
    }

    // MARK: - isDid / shorten

    func testIsDidSyntax() {
        XCTAssertTrue(DidDisplay.isDid(plc))
        XCTAssertTrue(DidDisplay.isDid(key))
        XCTAssertTrue(DidDisplay.isDid("did:web:example.com"))
        XCTAssertFalse(DidDisplay.isDid("alice"))
        XCTAssertFalse(DidDisplay.isDid("#didtest"))
        XCTAssertFalse(DidDisplay.isDid("did:"))
        XCTAssertFalse(DidDisplay.isDid("did:plc:"))
        XCTAssertFalse(DidDisplay.isDid(""))
    }

    func testShorten() {
        XCTAssertEqual(DidDisplay.shorten(plc), "plc:k2n3…t5j7")
        XCTAssertEqual(DidDisplay.shorten(key), "key:z6Mk…2doK")
        XCTAssertEqual(DidDisplay.shorten("did:web:example.com"), "web:example.com")
        XCTAssertEqual(DidDisplay.shorten("alice"), "alice")
    }

    // MARK: - displayName

    func testDisplayNameChain() {
        XCTAssertEqual(
            DidDisplay.displayName(key: "alice", bindings: [:], reverseNick: { _ in nil }),
            "alice")
        XCTAssertEqual(
            DidDisplay.displayName(key: plc, bindings: [plc: "alice"], reverseNick: { _ in nil }),
            "alice")
        XCTAssertEqual(
            DidDisplay.displayName(key: plc, bindings: [:], reverseNick: { d in d == self.plc ? "bob" : nil }),
            "bob")
        XCTAssertEqual(
            DidDisplay.displayName(key: plc, bindings: [:], reverseNick: { _ in nil }),
            "plc:k2n3…t5j7")
    }

    // MARK: - merge: re-key a lone nick thread

    func testMergeRekeysLoneNickBuffer() {
        let nickBuf = ChannelState(name: "Alice")
        nickBuf.appendIfNew(msg("01A", "cold start", at: 10))
        nickBuf.members = [MemberInfo(nick: "Alice", isOp: false, isHalfop: false,
                                      isVoiced: false, awayMsg: nil, did: nil)]
        var dms = [nickBuf]
        var unread = ["Alice": 2]
        let expectedActivity = nickBuf.lastActivity

        let merged = DidDisplay.mergeDmBuffers(
            dmBuffers: &dms, unreadCounts: &unread, nick: "alice", did: plc)

        XCTAssertTrue(merged)
        XCTAssertEqual(dms.count, 1)
        XCTAssertEqual(dms[0].name, plc)
        XCTAssertEqual(dms[0].messages.map(\.id), ["01A"])
        XCTAssertEqual(dms[0].members.count, 1)
        XCTAssertEqual(dms[0].lastActivity, expectedActivity)
        // Unread carries by exact buffer name to the DID key.
        XCTAssertNil(unread["Alice"])
        XCTAssertEqual(unread[plc], 2)
        // The rebuilt transcript keeps its dedup set: re-appending is a no-op.
        dms[0].appendIfNew(msg("01A", "dupe"))
        XCTAssertEqual(dms[0].messages.count, 1)
    }

    // MARK: - merge: fold into an existing DID thread

    func testMergeFoldsWithDedupeAndOrder() {
        let nickBuf = ChannelState(name: "alice")
        nickBuf.appendIfNew(msg("01A", "only in nick thread", at: 5))
        nickBuf.appendIfNew(msg("01B", "dupe", at: 6))
        let didBuf = ChannelState(name: plc)
        didBuf.appendIfNew(msg("01B", "dupe", at: 6))
        didBuf.appendIfNew(msg("01C", "later", at: 20))
        var dms = [nickBuf, didBuf]
        var unread = ["alice": 2, plc: 1]
        let expectedActivity = max(nickBuf.lastActivity, didBuf.lastActivity)

        let merged = DidDisplay.mergeDmBuffers(
            dmBuffers: &dms, unreadCounts: &unread, nick: "alice", did: plc)

        XCTAssertTrue(merged)
        XCTAssertEqual(dms.count, 1)
        XCTAssertEqual(dms[0].name, plc)
        XCTAssertEqual(dms[0].messages.map(\.id), ["01A", "01B", "01C"])
        XCTAssertEqual(dms[0].lastActivity, expectedActivity)
        XCTAssertEqual(unread[plc], 3)
        XCTAssertNil(unread["alice"])
    }

    // MARK: - merge guards

    func testMergeGuards() {
        var unread: [String: Int] = [:]

        // Channel names never merge.
        let chan = ChannelState(name: "#general")
        var dms = [chan]
        XCTAssertFalse(DidDisplay.mergeDmBuffers(
            dmBuffers: &dms, unreadCounts: &unread, nick: "#general", did: plc))
        XCTAssertEqual(dms[0].name, "#general")

        // Non-DID target is a no-op.
        dms = [ChannelState(name: "bob")]
        XCTAssertFalse(DidDisplay.mergeDmBuffers(
            dmBuffers: &dms, unreadCounts: &unread, nick: "bob", did: "not-a-did"))

        // nick == did is a no-op.
        dms = [ChannelState(name: plc)]
        XCTAssertFalse(DidDisplay.mergeDmBuffers(
            dmBuffers: &dms, unreadCounts: &unread, nick: plc, did: plc))
        XCTAssertEqual(dms.count, 1)

        // Absent nick buffer is a no-op.
        dms = []
        XCTAssertFalse(DidDisplay.mergeDmBuffers(
            dmBuffers: &dms, unreadCounts: &unread, nick: "ghost", did: plc))
    }
}
