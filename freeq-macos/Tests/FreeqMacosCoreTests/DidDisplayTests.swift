import XCTest
@testable import FreeqMacosCore

/// DID-keyed DM identity helpers — the macOS port of the Android reference
/// implementation (DidDisplayTest) plus the TUI merge semantics. DM buffers
/// key by the SDK's dm_key (peer DID when known, else nick); these helpers
/// keep a raw `did:…` from ever rendering and fold a nick-keyed thread into
/// its DID-keyed one when the binding is learned.
final class DidDisplayTests: XCTestCase {

    private let plc = "did:plc:k2n3e2vsihf3farequ44t5j7"
    private let key = "did:key:z6MkhaXgBZDvotDkL5257faiztiGiC2QtKLGpbnnEGta2doK"

    private func msg(_ id: String, _ text: String = "hi",
                     at t: TimeInterval = 0, from: String = "alice") -> ChatMessage {
        ChatMessage(id: id, from: from, text: text, isAction: false,
                    timestamp: Date(timeIntervalSince1970: t), replyTo: nil)
    }

    // MARK: - isDid

    func testIsDidAcceptsPlcAndKeySyntax() {
        XCTAssertTrue(DidDisplay.isDid(plc))
        XCTAssertTrue(DidDisplay.isDid(key))
        XCTAssertTrue(DidDisplay.isDid("did:web:example.com"))
    }

    func testIsDidRejectsNonDids() {
        XCTAssertFalse(DidDisplay.isDid("alice"))
        XCTAssertFalse(DidDisplay.isDid("#didtest"))
        XCTAssertFalse(DidDisplay.isDid("did:"))
        XCTAssertFalse(DidDisplay.isDid("did:plc:"))
        XCTAssertFalse(DidDisplay.isDid(""))
        XCTAssertFalse(DidDisplay.isDid("DIDthing"))
    }

    // MARK: - shorten

    func testShortenCompactsLongIds() {
        XCTAssertEqual(DidDisplay.shorten(plc), "plc:k2n3…t5j7")
        XCTAssertEqual(DidDisplay.shorten(key), "key:z6Mk…2doK")
    }

    func testShortenKeepsShortIdsAndPassesThroughNonDids() {
        XCTAssertEqual(DidDisplay.shorten("did:web:example.com"), "web:example.com")
        XCTAssertEqual(DidDisplay.shorten("alice"), "alice")
        XCTAssertEqual(DidDisplay.shorten("#chan"), "#chan")
    }

    // MARK: - displayName

    func testDisplayNamePassesThroughPlainNicks() {
        XCTAssertEqual(
            DidDisplay.displayName(key: "alice", bindings: [:], reverseNick: { _ in nil }),
            "alice")
    }

    func testDisplayNamePrefersBinding() {
        XCTAssertEqual(
            DidDisplay.displayName(key: plc, bindings: [plc: "alice"], reverseNick: { _ in nil }),
            "alice")
    }

    func testDisplayNameFallsBackToReverseResolverThenShorten() {
        XCTAssertEqual(
            DidDisplay.displayName(key: plc, bindings: [:], reverseNick: { d in d == self.plc ? "bob" : nil }),
            "bob")
        XCTAssertEqual(
            DidDisplay.displayName(key: plc, bindings: [:], reverseNick: { _ in nil }),
            "plc:k2n3…t5j7")
    }

    // MARK: - mergeDmBuffers: re-key a lone nick thread

    func testMergeRekeysLoneNickBuffer() {
        let nickBuf = ChannelState(name: "Alice")
        nickBuf.appendIfNew(msg("01A", "cold start", at: 10))
        nickBuf.members = [MemberInfo(nick: "Alice", isOp: false, isHalfop: false,
                                      isVoiced: false, awayMsg: nil, did: nil)]
        var dms = [nickBuf]
        var unread = ["alice": 2]
        var mentions: [String: Int] = [:]
        // lastActivity floors at init-time `Date()`; capture the pre-merge
        // value — the re-key must carry it, whatever it is.
        let expectedActivity = nickBuf.lastActivity

        let merged = DidDisplay.mergeDmBuffers(
            dmBuffers: &dms, unreadCounts: &unread, mentionCounts: &mentions,
            nick: "alice", did: plc)

        XCTAssertTrue(merged)
        XCTAssertEqual(dms.count, 1)
        XCTAssertEqual(dms[0].name, plc)
        XCTAssertEqual(dms[0].messages.map(\.id), ["01A"])
        XCTAssertEqual(dms[0].members.count, 1)
        XCTAssertEqual(dms[0].lastActivity, expectedActivity)
        // Unread carries to the DID key.
        XCTAssertNil(unread["alice"])
        XCTAssertEqual(unread[plc.lowercased()], 2)
    }

    // MARK: - mergeDmBuffers: fold into an existing DID thread

    func testMergeFoldsIntoExistingDidBufferWithDedupeAndCarry() {
        let nickBuf = ChannelState(name: "alice")
        nickBuf.appendIfNew(msg("01A", "only in nick thread", at: 5))
        nickBuf.appendIfNew(msg("01B", "dupe", at: 6))
        let didBuf = ChannelState(name: plc)
        didBuf.appendIfNew(msg("01B", "dupe", at: 6))
        didBuf.appendIfNew(msg("01C", "later", at: 20))
        var dms = [nickBuf, didBuf]
        var unread = ["alice": 2, plc.lowercased(): 1]
        var mentions = ["alice": 1]
        let expectedActivity = max(nickBuf.lastActivity, didBuf.lastActivity)

        let merged = DidDisplay.mergeDmBuffers(
            dmBuffers: &dms, unreadCounts: &unread, mentionCounts: &mentions,
            nick: "alice", did: plc)

        XCTAssertTrue(merged)
        XCTAssertEqual(dms.count, 1)
        XCTAssertEqual(dms[0].name, plc)
        // 01B deduped; 01A inserted in time order before 01C.
        XCTAssertEqual(dms[0].messages.map(\.id), ["01A", "01B", "01C"])
        XCTAssertEqual(dms[0].lastActivity, expectedActivity)
        XCTAssertEqual(unread[plc.lowercased()], 3)
        XCTAssertEqual(mentions[plc.lowercased()], 1)
        XCTAssertNil(unread["alice"])
        XCTAssertNil(mentions["alice"])
    }

    // MARK: - mergeDmBuffers: guards

    func testMergeGuards() {
        let chan = ChannelState(name: "#general")
        chan.appendIfNew(msg("01A"))
        var dms = [chan]
        var unread: [String: Int] = [:]
        var mentions: [String: Int] = [:]

        // A channel name must never merge into a DID thread.
        XCTAssertFalse(DidDisplay.mergeDmBuffers(
            dmBuffers: &dms, unreadCounts: &unread, mentionCounts: &mentions,
            nick: "#general", did: plc))
        XCTAssertEqual(dms[0].name, "#general")

        // Non-DID "did" is a no-op.
        let nickBuf = ChannelState(name: "bob")
        dms = [nickBuf]
        XCTAssertFalse(DidDisplay.mergeDmBuffers(
            dmBuffers: &dms, unreadCounts: &unread, mentionCounts: &mentions,
            nick: "bob", did: "not-a-did"))

        // nick == did (case-insensitive) is a no-op.
        let didNamed = ChannelState(name: plc)
        dms = [didNamed]
        XCTAssertFalse(DidDisplay.mergeDmBuffers(
            dmBuffers: &dms, unreadCounts: &unread, mentionCounts: &mentions,
            nick: plc, did: plc))
        XCTAssertEqual(dms.count, 1)

        // No nick-keyed buffer present is a no-op.
        dms = []
        XCTAssertFalse(DidDisplay.mergeDmBuffers(
            dmBuffers: &dms, unreadCounts: &unread, mentionCounts: &mentions,
            nick: "ghost", did: plc))
    }
}

/// Speculative-history failure suppression (the TUI 67365d80 lesson): the
/// client fetches DM history on its own when a conversation opens; a guest,
/// or a DM with a guest peer, gets a CHATHISTORY failure back that the user
/// never asked for. Per-target failures are swallowed; a TARGETS (`*`)
/// failure — the reply to an explicit conversation-list request — surfaces.
final class ChatHistoryNoticeRoutingTests: XCTestCase {

    func testPerTargetChatHistoryFailureIsIgnored() {
        XCTAssertEqual(
            ServerNoticeRouter.route(
                "CHATHISTORY ACCOUNT_REQUIRED did:plc:k2n3e2vsihf3farequ44t5j7 You must be authenticated to access DM history"),
            .ignore)
        XCTAssertEqual(
            ServerNoticeRouter.route("CHATHISTORY INVALID_TARGET gnap Unknown target"),
            .ignore)
    }

    func testTargetsChatHistoryFailureStillDisplays() {
        let text = "CHATHISTORY ACCOUNT_REQUIRED * You must be authenticated to list DM targets"
        XCTAssertEqual(ServerNoticeRouter.route(text), .display(text))
    }

    func testNonChatHistoryNoticesUnaffected() {
        let text = "some ordinary server notice"
        XCTAssertEqual(ServerNoticeRouter.route(text), .display(text))
    }
}
