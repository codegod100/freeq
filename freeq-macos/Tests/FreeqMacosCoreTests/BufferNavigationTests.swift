import XCTest
@testable import FreeqMacosCore

final class BufferNavigationTests: XCTestCase {
    // MARK: - Sidebar order

    func testSidebarOrderFavoritesFirstThenChannelsThenDms() {
        let order = BufferNavigation.sidebarOrder(
            channels: ["#a", "#fav", "#b"],
            favorites: ["#fav"],
            dms: ["alice", "bob"])
        XCTAssertEqual(order, ["#fav", "#a", "#b", "alice", "bob"])
    }

    func testFavoriteMatchIsCaseInsensitive() {
        let order = BufferNavigation.sidebarOrder(
            channels: ["#General"], favorites: ["#general"], dms: [])
        XCTAssertEqual(order, ["#General"])
    }

    // MARK: - Next / previous

    func testNextMovesForward() {
        let order = ["#a", "#b", "#c"]
        XCTAssertEqual(BufferNavigation.target(from: "#a", order: order, direction: .next), "#b")
    }

    func testPreviousMovesBackward() {
        let order = ["#a", "#b", "#c"]
        XCTAssertEqual(BufferNavigation.target(from: "#b", order: order, direction: .previous), "#a")
    }

    func testNextWrapsAtEnd() {
        let order = ["#a", "#b", "#c"]
        XCTAssertEqual(BufferNavigation.target(from: "#c", order: order, direction: .next), "#a")
    }

    func testPreviousWrapsAtStart() {
        let order = ["#a", "#b", "#c"]
        XCTAssertEqual(BufferNavigation.target(from: "#a", order: order, direction: .previous), "#c")
    }

    func testCurrentMatchIsCaseInsensitive() {
        let order = ["#A", "#b"]
        XCTAssertEqual(BufferNavigation.target(from: "#a", order: order, direction: .next), "#b")
    }

    func testNoCurrentEntersFromMatchingEnd() {
        let order = ["#a", "#b", "#c"]
        XCTAssertEqual(BufferNavigation.target(from: nil, order: order, direction: .next), "#a")
        XCTAssertEqual(BufferNavigation.target(from: nil, order: order, direction: .previous), "#c")
    }

    func testSingleBufferGoesNowhere() {
        XCTAssertNil(BufferNavigation.target(from: "#a", order: ["#a"], direction: .next))
    }

    func testEmptyOrderReturnsNil() {
        XCTAssertNil(BufferNavigation.target(from: "#a", order: [], direction: .next))
    }

    // MARK: - Unread-only navigation

    func testUnreadSkipsReadBuffers() {
        let order = ["#a", "#b", "#c", "#d"]
        let unread: Set<String> = ["#d"]
        XCTAssertEqual(
            BufferNavigation.target(
                from: "#a", order: order, direction: .next,
                isUnread: { unread.contains($0) }),
            "#d")
    }

    func testUnreadWrapsAround() {
        let order = ["#a", "#b", "#c"]
        let unread: Set<String> = ["#a"]
        XCTAssertEqual(
            BufferNavigation.target(
                from: "#c", order: order, direction: .next,
                isUnread: { unread.contains($0) }),
            "#a")
    }

    func testUnreadNeverReturnsCurrent() {
        let order = ["#a", "#b"]
        let unread: Set<String> = ["#a"]
        XCTAssertNil(
            BufferNavigation.target(
                from: "#a", order: order, direction: .next,
                isUnread: { unread.contains($0) }))
    }

    func testNoUnreadReturnsNil() {
        let order = ["#a", "#b", "#c"]
        XCTAssertNil(
            BufferNavigation.target(
                from: "#a", order: order, direction: .next,
                isUnread: { _ in false }))
    }
}
