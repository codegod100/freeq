import XCTest
@testable import FreeqIosCore

/// Tests for the channel-E2EE policy layer: which messages get encrypted on
/// send, how incoming ciphertext is displayed, and how the self-echo cache
/// restores plaintext. Mirrors the web client's behavior in
/// `freeq-sdk-js/src/client.ts` (hasChannelKey → encryptChannel on send;
/// ENC1 + channel → decryptChannel or "[encrypted message]" on receive).
final class ChannelE2eeStateTests: XCTestCase {

    // MARK: - Key management

    func testSetAndRemoveKey() {
        var state = ChannelE2eeState()
        XCTAssertFalse(state.hasKey(channel: "#sec"))
        state.setKey(channel: "#sec", passphrase: "hunter2")
        XCTAssertTrue(state.hasKey(channel: "#sec"))
        state.removeKey(channel: "#sec")
        XCTAssertFalse(state.hasKey(channel: "#sec"))
    }

    func testKeyLookupIsCaseInsensitive() {
        var state = ChannelE2eeState()
        state.setKey(channel: "#Secret", passphrase: "pw")
        XCTAssertTrue(state.hasKey(channel: "#secret"))
        XCTAssertTrue(state.hasKey(channel: "#SECRET"))
        state.removeKey(channel: "#sEcReT")
        XCTAssertFalse(state.hasKey(channel: "#Secret"))
    }

    func testExportedKeyRestoresState() {
        var state = ChannelE2eeState()
        state.setKey(channel: "#sec", passphrase: "hunter2")
        let exported = state.exportKey(channel: "#sec")!

        var restored = ChannelE2eeState()
        restored.importKey(channel: "#sec", base64: exported)
        XCTAssertTrue(restored.hasKey(channel: "#sec"))

        // Round-trips ciphertext across export/import.
        let wire = state.outgoing(text: "hello", channel: "#sec")!
        XCTAssertEqual(restored.incoming(text: wire, channel: "#sec").display, "hello")
    }

    func testImportRejectsGarbage() {
        var state = ChannelE2eeState()
        state.importKey(channel: "#sec", base64: "not-base64!!!")
        XCTAssertFalse(state.hasKey(channel: "#sec"))
        state.importKey(channel: "#sec", base64: Data([1, 2, 3]).base64EncodedString())  // wrong length
        XCTAssertFalse(state.hasKey(channel: "#sec"))
    }

    // MARK: - Outgoing

    func testOutgoingWithoutKeyIsNil() {
        var state = ChannelE2eeState()
        XCTAssertNil(state.outgoing(text: "hello", channel: "#plain"))
    }

    func testOutgoingWithKeyEncryptsAndCachesEcho() {
        var state = ChannelE2eeState()
        state.setKey(channel: "#sec", passphrase: "hunter2")
        let wire = state.outgoing(text: "attack at dawn", channel: "#sec")
        XCTAssertNotNil(wire)
        XCTAssertTrue(wire!.hasPrefix("ENC1:"))

        // The server echoes our ciphertext back; the cache restores plaintext.
        let echoed = state.incoming(text: wire!, channel: "#sec")
        XCTAssertEqual(echoed.display, "attack at dawn")
        XCTAssertTrue(echoed.isEncrypted)
    }

    func testEchoCacheIsSingleUse() {
        var state = ChannelE2eeState()
        state.setKey(channel: "#sec", passphrase: "hunter2")
        let wire = state.outgoing(text: "msg", channel: "#sec")!
        _ = state.incoming(text: wire, channel: "#sec")
        // Second delivery decrypts normally (we still hold the key) rather
        // than hitting the consumed cache entry.
        let second = state.incoming(text: wire, channel: "#sec")
        XCTAssertEqual(second.display, "msg")
    }

    func testEchoCacheIsBounded() {
        var state = ChannelE2eeState()
        state.setKey(channel: "#sec", passphrase: "hunter2")
        var first: String?
        for i in 0..<(ChannelE2eeState.echoCacheLimit + 10) {
            let wire = state.outgoing(text: "m\(i)", channel: "#sec")
            if i == 0 { first = wire }
        }
        XCTAssertLessThanOrEqual(state.echoCacheCount, ChannelE2eeState.echoCacheLimit)
        // Oldest entry was evicted, but decryption still works via the key.
        XCTAssertEqual(state.incoming(text: first!, channel: "#sec").display, "m0")
    }

    // MARK: - Incoming

    func testIncomingPlaintextPassesThrough() {
        var state = ChannelE2eeState()
        let r = state.incoming(text: "just words", channel: "#any")
        XCTAssertEqual(r.display, "just words")
        XCTAssertFalse(r.isEncrypted)
    }

    func testIncomingCiphertextWithKeyDecrypts() throws {
        var sender = ChannelE2eeState()
        sender.setKey(channel: "#sec", passphrase: "hunter2")
        let wire = sender.outgoing(text: "secret", channel: "#sec")!

        var receiver = ChannelE2eeState()
        receiver.setKey(channel: "#sec", passphrase: "hunter2")
        let r = receiver.incoming(text: wire, channel: "#sec")
        XCTAssertEqual(r.display, "secret")
        XCTAssertTrue(r.isEncrypted)
    }

    func testIncomingCiphertextWithoutKeyShowsPlaceholder() {
        var sender = ChannelE2eeState()
        sender.setKey(channel: "#sec", passphrase: "hunter2")
        let wire = sender.outgoing(text: "secret", channel: "#sec")!

        var receiver = ChannelE2eeState()
        let r = receiver.incoming(text: wire, channel: "#sec")
        XCTAssertEqual(r.display, "[encrypted message]")
        XCTAssertTrue(r.isEncrypted)
    }

    func testIncomingCiphertextWithWrongKeyShowsPlaceholder() {
        var sender = ChannelE2eeState()
        sender.setKey(channel: "#sec", passphrase: "hunter2")
        let wire = sender.outgoing(text: "secret", channel: "#sec")!

        var receiver = ChannelE2eeState()
        receiver.setKey(channel: "#sec", passphrase: "wrong")
        let r = receiver.incoming(text: wire, channel: "#sec")
        XCTAssertEqual(r.display, "[encrypted message]")
        XCTAssertTrue(r.isEncrypted)
    }

    // MARK: - ChatMessage lock badge

    func testChatMessageEqualityIncludesEncryptedFlag() {
        let base = ChatMessage(
            id: "m1", from: "alice", text: "hi",
            isAction: false, timestamp: Date(timeIntervalSince1970: 0), replyTo: nil)
        var locked = base
        locked.isEncrypted = true
        XCTAssertNotEqual(base, locked, "isEncrypted must trigger SwiftUI redraw")
    }

    func testKeysAreScopedPerChannel() {
        var state = ChannelE2eeState()
        state.setKey(channel: "#a", passphrase: "pw")
        XCTAssertNil(state.outgoing(text: "x", channel: "#b"))
        let wire = state.outgoing(text: "x", channel: "#a")!
        // Same wire arriving on another channel can't decrypt (different salt).
        let r = state.incoming(text: wire, channel: "#b")
        XCTAssertEqual(r.display, "[encrypted message]")
    }
}
