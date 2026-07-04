import XCTest
@testable import FreeqIosCore

/// Tests for restoring the last-open conversation on launch. The app should
/// reopen where you left off, falling back sensibly when that target is gone.
/// Ported from freeq-macos — the iOS app was missing this feature entirely.
final class LastChannelTests: XCTestCase {

    func testRestoresSavedChannelWhenStillPresent() {
        XCTAssertEqual(
            LastChannel.restore(saved: "#dev", channels: ["#freeq", "#dev"], dms: []),
            "#dev")
    }

    func testRestoreIsCaseInsensitiveButKeepsCurrentCasing() {
        // Saved lowercased, current list has display casing → return the list's.
        XCTAssertEqual(
            LastChannel.restore(saved: "#mixedcase", channels: ["#MixedCase"], dms: []),
            "#MixedCase")
    }

    func testRestoresSavedDM() {
        XCTAssertEqual(
            LastChannel.restore(saved: "alice", channels: ["#freeq"], dms: ["alice", "bob"]),
            "alice")
    }

    func testFallsBackToFirstChannelWhenSavedGone() {
        // Left #old since last launch → open the first available channel.
        XCTAssertEqual(
            LastChannel.restore(saved: "#old", channels: ["#freeq", "#dev"], dms: []),
            "#freeq")
    }

    func testFallsBackToFirstDMWhenNoChannels() {
        XCTAssertEqual(
            LastChannel.restore(saved: "#gone", channels: [], dms: ["alice"]),
            "alice")
    }

    func testNilWhenNothingAvailable() {
        XCTAssertNil(LastChannel.restore(saved: "#x", channels: [], dms: []))
    }

    func testNoSavedFallsBackToFirstChannel() {
        XCTAssertEqual(
            LastChannel.restore(saved: nil, channels: ["#freeq"], dms: []),
            "#freeq")
    }
}
