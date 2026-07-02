import XCTest
import CryptoKit
@testable import FreeqMacosCore

/// Coverage for the core-model behavior the original ValidationTests suite
/// didn't reach: ChannelState ordering/edit/delete/reaction paths,
/// MemberInfo display logic, ServerConfig fallbacks, and the remaining
/// ChannelCrypto error branches.
final class CoreModelTests: XCTestCase {

    private func msg(_ id: String, _ text: String = "hi",
                     at t: TimeInterval = 0, from: String = "alice") -> ChatMessage {
        ChatMessage(id: id, from: from, text: text, isAction: false,
                    timestamp: Date(timeIntervalSince1970: t), replyTo: nil)
    }

    // MARK: - ChannelState message list

    func testAppendIfNewDedupesById() {
        let ch = ChannelState(name: "#t")
        ch.appendIfNew(msg("a"))
        ch.appendIfNew(msg("a", "duplicate"))
        XCTAssertEqual(ch.messages.count, 1)
        XCTAssertEqual(ch.messages[0].text, "hi")
    }

    func testAppendOutOfOrderInsertsByTimestamp() {
        let ch = ChannelState(name: "#t")
        ch.appendIfNew(msg("m1", at: 100))
        ch.appendIfNew(msg("m3", at: 300))
        ch.appendIfNew(msg("m2", at: 200))  // history backfill arrives late
        XCTAssertEqual(ch.messages.map(\.id), ["m1", "m2", "m3"])
    }

    func testAppendUpdatesLastActivityOnlyForward() {
        let ch = ChannelState(name: "#t")
        ch.appendIfNew(msg("new", at: Date().timeIntervalSince1970 + 100))
        let activity = ch.lastActivity
        ch.appendIfNew(msg("old", at: 0))  // backfill must not rewind activity
        XCTAssertEqual(ch.lastActivity, activity)
    }

    func testApplyEditRewritesTextAndTracksNewId() {
        let ch = ChannelState(name: "#t")
        ch.appendIfNew(msg("orig"))
        ch.applyEdit(originalId: "orig", newId: "edit-1", newText: "fixed")
        XCTAssertEqual(ch.messages[0].text, "fixed")
        XCTAssertTrue(ch.messages[0].isEdited)
        XCTAssertEqual(ch.messages[0].id, "edit-1")
        // The replacement id is now known — its echo must not re-append.
        ch.appendIfNew(msg("edit-1", "echo"))
        XCTAssertEqual(ch.messages.count, 1)
    }

    func testApplyEditOnUnknownIdIsNoop() {
        let ch = ChannelState(name: "#t")
        ch.appendIfNew(msg("a"))
        ch.applyEdit(originalId: "ghost", newId: nil, newText: "x")
        XCTAssertEqual(ch.messages[0].text, "hi")
    }

    func testApplyDeleteSoftDeletesAndClearsText() {
        let ch = ChannelState(name: "#t")
        ch.appendIfNew(msg("a", "secret"))
        ch.applyDelete(msgId: "a")
        XCTAssertTrue(ch.messages[0].isDeleted)
        XCTAssertEqual(ch.messages[0].text, "")
        XCTAssertFalse(ch.hasVisibleMessages)
    }

    // MARK: - ChannelState reactions

    func testApplyReactionTogglesOnAndOff() {
        let ch = ChannelState(name: "#t")
        ch.appendIfNew(msg("a"))
        ch.applyReaction(msgId: "a", emoji: "👍", from: "bob")
        XCTAssertTrue(ch.hasReaction(msgId: "a", emoji: "👍", from: "bob"))
        ch.applyReaction(msgId: "a", emoji: "👍", from: "bob")
        XCTAssertFalse(ch.hasReaction(msgId: "a", emoji: "👍", from: "bob"))
        XCTAssertNil(ch.messages[0].reactions["👍"], "empty reaction sets must be pruned")
    }

    func testRemoveReactionKeepsOtherReactors() {
        let ch = ChannelState(name: "#t")
        ch.appendIfNew(msg("a"))
        ch.addReaction(msgId: "a", emoji: "🔥", from: "bob")
        ch.addReaction(msgId: "a", emoji: "🔥", from: "carol")
        ch.removeReaction(msgId: "a", emoji: "🔥", from: "bob")
        XCTAssertTrue(ch.hasReaction(msgId: "a", emoji: "🔥", from: "carol"))
        XCTAssertFalse(ch.hasReaction(msgId: "a", emoji: "🔥", from: "bob"))
    }

    func testReactionOnUnknownMessageIsSafe() {
        let ch = ChannelState(name: "#t")
        ch.applyReaction(msgId: "ghost", emoji: "👍", from: "bob")
        ch.removeReaction(msgId: "ghost", emoji: "👍", from: "bob")
        XCTAssertFalse(ch.hasReaction(msgId: "ghost", emoji: "👍", from: "bob"))
    }

    // MARK: - ChannelState typing + member lookup

    func testActiveTypersExpireAfterFiveSeconds() {
        let ch = ChannelState(name: "#t")
        ch.typingUsers["fresh"] = Date()
        ch.typingUsers["stale"] = Date().addingTimeInterval(-10)
        XCTAssertEqual(ch.activeTypers, ["fresh"])
    }

    func testMemberInfoLookupIsCaseInsensitive() {
        let ch = ChannelState(name: "#t")
        ch.members = [MemberInfo(nick: "Alice", isOp: true, isHalfop: false,
                                 isVoiced: false, awayMsg: nil, did: "did:plc:x")]
        XCTAssertNotNil(ch.memberInfo(for: "alice"))
        XCTAssertNil(ch.memberInfo(for: "bob"))
    }

    func testChannelKindFlags() {
        XCTAssertTrue(ChannelState(name: "#chan").isChannel)
        XCTAssertFalse(ChannelState(name: "#chan").isDM)
        XCTAssertTrue(ChannelState(name: "alice").isDM)
    }

    // MARK: - MemberInfo display logic

    func testMemberPrefixPrecedence() {
        func member(op: Bool = false, halfop: Bool = false, voiced: Bool = false) -> MemberInfo {
            MemberInfo(nick: "x", isOp: op, isHalfop: halfop, isVoiced: voiced,
                       awayMsg: nil, did: nil)
        }
        XCTAssertEqual(member(op: true, halfop: true, voiced: true).prefix, "@")
        XCTAssertEqual(member(halfop: true, voiced: true).prefix, "%")
        XCTAssertEqual(member(voiced: true).prefix, "+")
        XCTAssertEqual(member().prefix, "")
    }

    func testMemberAwayAndVerifiedFlags() {
        let away = MemberInfo(nick: "x", isOp: false, isHalfop: false,
                              isVoiced: false, awayMsg: "lunch", did: nil)
        XCTAssertTrue(away.isAway)
        XCTAssertFalse(away.isVerified)
        let verified = MemberInfo(nick: "x", isOp: false, isHalfop: false,
                                  isVoiced: false, awayMsg: nil, did: "did:plc:abc")
        XCTAssertFalse(verified.isAway)
        XCTAssertTrue(verified.isVerified)
    }

    // MARK: - ServerConfig

    func testServerConfigDefaultsAndDerivedValues() {
        // The test process doesn't set IRC_SERVER/AUTH_BROKER_BASE, so the
        // freeq.at fallbacks apply and every derived value must be coherent.
        XCTAssertEqual(ServerConfig.ircServer, "irc.freeq.at:6697")
        XCTAssertEqual(ServerConfig.host, "irc.freeq.at")
        XCTAssertEqual(ServerConfig.apiBaseUrl, "https://irc.freeq.at")
        XCTAssertEqual(ServerConfig.authBrokerBase, "https://auth.freeq.at")
        XCTAssertEqual(ServerConfig.deploymentID, "irc.freeq.at:6697|https://auth.freeq.at")
    }

    // MARK: - ChannelCrypto remaining error branches

    func testDecryptNonUTF8PlaintextFails() throws {
        // A conforming peer could encrypt arbitrary bytes; our String API
        // must reject them cleanly rather than crash or mojibake.
        let key = ChannelCrypto.deriveKey(passphrase: "pw", channel: "#t")
        let sealed = try AES.GCM.seal(Data([0xFF, 0xFE, 0xFD]), using: key)
        let wire = "ENC1:\(Data(sealed.nonce).base64EncodedString()):"
            + (sealed.ciphertext + sealed.tag).base64EncodedString()
        XCTAssertThrowsError(try ChannelCrypto.decrypt(key: key, wire: wire)) {
            XCTAssertEqual($0 as? ChannelCrypto.CryptoError, .invalidUTF8)
        }
    }

    func testEncryptRejectsInvalidInjectedNonce() {
        let key = ChannelCrypto.deriveKey(passphrase: "pw", channel: "#t")
        XCTAssertThrowsError(
            try ChannelCrypto.encrypt(key: key, plaintext: "x", nonce: Data([1, 2, 3]))
        )
    }

    func testCiphertextShorterThanTagIsMalformed() {
        let key = ChannelCrypto.deriveKey(passphrase: "pw", channel: "#t")
        let nonce = Data(count: 12).base64EncodedString()
        let tooShort = Data([1, 2, 3]).base64EncodedString()  // < 16-byte tag
        XCTAssertThrowsError(try ChannelCrypto.decrypt(key: key, wire: "ENC1:\(nonce):\(tooShort)")) {
            XCTAssertEqual($0 as? ChannelCrypto.CryptoError, .malformed)
        }
    }
}
