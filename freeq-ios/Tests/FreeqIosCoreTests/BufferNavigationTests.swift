import XCTest
@testable import FreeqIosCore

/// Keyboard buffer-navigation ordering + stepping (⌥↑/↓, ⌥⇧↑/↓, ⌘1–9).
final class BufferNavigationTests: XCTestCase {
    let channels = ["#alpha", "#beta", "#freeq"]
    let dms = ["yolo", "nandi"]

    func testSidebarOrderFavoritesFirst() {
        let order = BufferNavigation.sidebarOrder(
            channels: channels, favoriteOrder: ["#freeq", "yolo"], dms: dms)
        // favorites (in favorite order), then remaining channels, then remaining DMs.
        XCTAssertEqual(order, ["#freeq", "yolo", "#alpha", "#beta", "nandi"])
    }

    func testSidebarOrderDropsStaleFavorites() {
        // A favorite that no longer exists is skipped.
        let order = BufferNavigation.sidebarOrder(
            channels: channels, favoriteOrder: ["#gone", "#beta"], dms: dms)
        XCTAssertEqual(order, ["#beta", "#alpha", "#freeq", "yolo", "nandi"])
    }

    func testStepNextAndWrap() {
        let order = ["#a", "#b", "#c"]
        XCTAssertEqual(BufferNavigation.step(order: order, current: "#a", delta: 1), "#b")
        XCTAssertEqual(BufferNavigation.step(order: order, current: "#c", delta: 1), "#a") // wrap
        XCTAssertEqual(BufferNavigation.step(order: order, current: "#a", delta: -1), "#c") // wrap back
    }

    func testStepNoCurrentPicksEnds() {
        let order = ["#a", "#b", "#c"]
        XCTAssertEqual(BufferNavigation.step(order: order, current: nil, delta: 1), "#a")
        XCTAssertEqual(BufferNavigation.step(order: order, current: nil, delta: -1), "#c")
    }

    func testStepUnreadOnlySkipsRead() {
        let order = ["#a", "#b", "#c", "#d"]
        // from #a, next unread skips #b (read) to #c.
        XCTAssertEqual(
            BufferNavigation.step(order: order, current: "#a", delta: 1,
                                  unreadOnly: true, unread: ["#c"]),
            "#c")
        // no unread → nil.
        XCTAssertNil(
            BufferNavigation.step(order: order, current: "#a", delta: 1,
                                  unreadOnly: true, unread: []))
    }

    func testStepUnreadOnlyWrapsToOnlyUnread() {
        let order = ["#a", "#b", "#c"]
        // only #a is unread; from #b, next-unread wraps to #a.
        XCTAssertEqual(
            BufferNavigation.step(order: order, current: "#b", delta: 1,
                                  unreadOnly: true, unread: ["#a"]),
            "#a")
    }

    func testAtIndexBounds() {
        let order = ["#a", "#b"]
        XCTAssertEqual(BufferNavigation.atIndex(0, order: order), "#a")
        XCTAssertEqual(BufferNavigation.atIndex(1, order: order), "#b")
        XCTAssertNil(BufferNavigation.atIndex(2, order: order))
        XCTAssertNil(BufferNavigation.atIndex(-1, order: order))
    }
}
