import XCTest
@testable import FreeqMacosCore

final class MenuBarModelTests: XCTestCase {

    func testEmptyWhenNoUnread() {
        XCTAssertTrue(MenuBarModel.entries(unread: [:], mentions: [:], order: ["#a"]).isEmpty)
    }

    func testOnlyPositiveCountsIncluded() {
        let e = MenuBarModel.entries(
            unread: ["#a": 0, "#b": 3], mentions: [:], order: ["#a", "#b"])
        XCTAssertEqual(e.map(\.name), ["#b"])
    }

    func testMentionsSortFirst() {
        let e = MenuBarModel.entries(
            unread: ["#a": 10, "#b": 2],
            mentions: ["#b": 1],
            order: ["#a", "#b"])
        // #b has a mention → first despite lower count.
        XCTAssertEqual(e.map(\.name), ["#b", "#a"])
        XCTAssertTrue(e[0].mention)
        XCTAssertFalse(e[1].mention)
    }

    func testTiesKeepDiscoveryOrder() {
        let e = MenuBarModel.entries(
            unread: ["#a": 5, "#b": 5, "#c": 5],
            mentions: [:],
            order: ["#c", "#a", "#b"])
        XCTAssertEqual(e.map(\.name), ["#c", "#a", "#b"])
    }

    func testCountDescendingWithinMentionGroup() {
        let e = MenuBarModel.entries(
            unread: ["#a": 2, "#b": 9],
            mentions: ["#a": 1, "#b": 1],
            order: ["#a", "#b"])
        XCTAssertEqual(e.map(\.name), ["#b", "#a"])
    }

    func testKeysAreLowercasedButNamesPreserveCase() {
        let e = MenuBarModel.entries(
            unread: ["#mixedcase": 4], mentions: [:], order: ["#MixedCase"])
        XCTAssertEqual(e.map(\.name), ["#MixedCase"])
        XCTAssertEqual(e.first?.count, 4)
    }

    func testIconReflectsMostSalientState() {
        XCTAssertEqual(MenuBarModel.iconName(inCall: true, muted: false, unread: true, mention: true), "waveform")
        XCTAssertEqual(MenuBarModel.iconName(inCall: true, muted: true, unread: false, mention: false), "mic.slash.fill")
        XCTAssertEqual(MenuBarModel.iconName(inCall: false, muted: false, unread: true, mention: true), "message.badge.filled.fill")
        XCTAssertEqual(MenuBarModel.iconName(inCall: false, muted: false, unread: true, mention: false), "message.badge")
        XCTAssertEqual(MenuBarModel.iconName(inCall: false, muted: false, unread: false, mention: false), "message")
    }
}
