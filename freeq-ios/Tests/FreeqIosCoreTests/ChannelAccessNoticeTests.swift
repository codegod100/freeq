import XCTest
@testable import FreeqIosCore

/// Classifying gated-join NOTICEs so iOS explains *why* a join failed
/// instead of silently doing nothing (parity with macOS).
final class ChannelAccessNoticeTests: XCTestCase {

    func testRecognizesDenialPhrases() {
        for (text, chan) in [
            ("#secret This channel requires authentication — sign in to join", "#secret"),
            ("#club Cannot join (+i): invite only", "#club"),
            ("#vip You are banned from this channel", "#vip"),
            ("#locked Bad channel key (+k)", "#locked"),
            ("#full Channel is full (+l)", "#full"),
            ("#mod Not authorized to join", "#mod"),
        ] {
            let parsed = ChannelAccessNotice.parse(text)
            XCTAssertNotNil(parsed, "should recognize: \(text)")
            XCTAssertEqual(parsed?.channel, chan)
            XCTAssertFalse(parsed?.reason.isEmpty ?? true)
        }
    }

    func testIgnoresNonDenialNotices() {
        XCTAssertNil(ChannelAccessNotice.parse("MOTD:Welcome"))
        XCTAssertNil(ChannelAccessNotice.parse("#general topic changed to hello"))
        XCTAssertNil(ChannelAccessNotice.parse("just some server chatter"))
        XCTAssertNil(ChannelAccessNotice.parse(""))
        XCTAssertNil(ChannelAccessNotice.parse("#general"))  // no reason
    }

    func testRequiresChannelPrefix() {
        // A non-channel first token with a denial phrase must not match.
        XCTAssertNil(ChannelAccessNotice.parse("alice you are banned"))
    }
}
