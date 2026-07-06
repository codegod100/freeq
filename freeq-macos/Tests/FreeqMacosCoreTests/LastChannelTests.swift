import XCTest
@testable import FreeqMacosCore

/// Tests for restoring the last-open conversation on launch. The app should
/// reopen where you left off, falling back sensibly when that target is gone.
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

    // MARK: - Fallback priority (saved gone → favorite → #freeq → first)

    func testFallsBackToFirstFavoriteWhenSavedGone() {
        // Left #old; #dev is a favorite → prefer the favorite over the
        // alphabetically-first channel and over the #freeq lobby.
        XCTAssertEqual(
            LastChannel.restore(saved: "#old", channels: ["#alpha", "#dev", "#freeq"],
                                dms: [], favorites: ["#dev"]),
            "#dev")
    }

    func testFirstFavoriteFollowsSidebarOrder() {
        // Two favorites → the first one in the passed (sidebar) order wins.
        XCTAssertEqual(
            LastChannel.restore(saved: nil, channels: ["#alpha", "#beta", "#zeta"],
                                dms: [], favorites: ["#zeta", "#beta"]),
            "#beta")
    }

    func testFavoriteMatchIsCaseInsensitive() {
        XCTAssertEqual(
            LastChannel.restore(saved: nil, channels: ["#Dev"], dms: [], favorites: ["#dev"]),
            "#Dev")
    }

    func testFallsBackToFreeqLobbyWhenNoFavorite() {
        // No saved, no favorites → the #freeq lobby beats the alphabetically
        // first channel.
        XCTAssertEqual(
            LastChannel.restore(saved: nil, channels: ["#alpha", "#freeq", "#zeta"],
                                dms: [], favorites: []),
            "#freeq")
    }

    func testFallsBackToFirstChannelWhenNoFavoriteOrFreeq() {
        XCTAssertEqual(
            LastChannel.restore(saved: "#gone", channels: ["#alpha", "#zeta"],
                                dms: [], favorites: []),
            "#alpha")
    }

    func testSavedStillWinsOverFavoriteAndFreeq() {
        XCTAssertEqual(
            LastChannel.restore(saved: "#dev", channels: ["#dev", "#freeq"],
                                dms: [], favorites: ["#freeq"]),
            "#dev")
    }
}
