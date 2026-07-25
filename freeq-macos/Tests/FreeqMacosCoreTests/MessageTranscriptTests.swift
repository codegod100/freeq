import XCTest
@testable import FreeqMacosCore

/// Clean block-copy transcript: `Name: message`, no Slack-style junk.
final class MessageTranscriptTests: XCTestCase {

    private func msg(_ from: String, _ text: String,
                     action: Bool = false, deleted: Bool = false,
                     at seconds: TimeInterval = 0) -> ChatMessage {
        ChatMessage(id: UUID().uuidString, from: from, text: text,
                    isAction: action, timestamp: Date(timeIntervalSince1970: seconds),
                    replyTo: nil, isDeleted: deleted)
    }

    func testBasicNameColonMessage() {
        let out = MessageTranscript.plainText([
            msg("vrypan", "hello"),
            msg("chadfowler.com", "hi there"),
        ])
        XCTAssertEqual(out, "vrypan: hello\nchadfowler.com: hi there")
    }

    func testDisplayNameResolution() {
        let names = ["chadfowler.com": "Chad Fowler", "nandi.uk": "NaNdi"]
        let out = MessageTranscript.plainText([
            msg("chadfowler.com", "sounds like a hole to fill :)"),
            msg("nandi.uk", "I turned it into a cli lib"),
        ]) { names[$0] ?? $0 }
        XCTAssertEqual(out, "Chad Fowler: sounds like a hole to fill :)\nNaNdi: I turned it into a cli lib")
    }

    func testSystemLinesSkippedByDefault() {
        let out = MessageTranscript.plainText([
            msg("vrypan", "one"),
            msg("", "reedharmeyer joined"),   // presence noise
            msg("chad", "two"),
        ])
        XCTAssertEqual(out, "vrypan: one\nchad: two")
    }

    func testSystemLinesIncludedWhenAsked() {
        var opts = MessageTranscript.Options()
        opts.skipSystem = false
        let out = MessageTranscript.plainText([
            msg("vrypan", "one"),
            msg("", "reedharmeyer joined"),
            msg("chad", "two"),
        ], options: opts)
        XCTAssertEqual(out, "vrypan: one\nreedharmeyer joined\nchad: two")
    }

    func testDeletedSkipped() {
        let out = MessageTranscript.plainText([
            msg("a", "kept"),
            msg("a", "gone", deleted: true),
            msg("b", "also kept"),
        ])
        XCTAssertEqual(out, "a: kept\nb: also kept")
    }

    func testActionRendersAsEmote() {
        let out = MessageTranscript.plainText([msg("chad", "waves", action: true)])
        XCTAssertEqual(out, "* chad waves")
    }

    func testMultilineBodyPreserved() {
        let out = MessageTranscript.plainText([
            msg("dev", "line one\nline two\nline three"),
            msg("other", "ok"),
        ])
        XCTAssertEqual(out, "dev: line one\nline two\nline three\nother: ok")
    }

    func testTimestampsWhenRequested() {
        var opts = MessageTranscript.Options()
        opts.includeTimestamps = true
        opts.timeStyle = .short
        // 1970-01-01 00:00:00 UTC formatted in the *local* zone — assert only
        // that the stamp is bracketed and the shape is `Name [..]: text`.
        let out = MessageTranscript.plainText([msg("x", "hey", at: 0)], options: opts)
        XCTAssertTrue(out.hasPrefix("x ["), out)
        XCTAssertTrue(out.contains("]: hey"), out)
    }

    func testEmptySelectionIsEmptyString() {
        XCTAssertEqual(MessageTranscript.plainText([]), "")
    }

    func testOnlySystemLinesYieldsEmptyByDefault() {
        let out = MessageTranscript.plainText([
            msg("", "a joined"),
            msg("", "b left"),
        ])
        XCTAssertEqual(out, "")
    }
}
