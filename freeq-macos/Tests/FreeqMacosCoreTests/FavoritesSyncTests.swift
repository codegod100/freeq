import XCTest
@testable import FreeqMacosCore

final class FavoritesSyncTests: XCTestCase {
    func testServerOrderWinsLocalAppended() {
        XCTAssertEqual(FavoritesSync.merge(server: ["#a", "#b"], local: ["#b", "#c"]),
                       ["#a", "#b", "#c"])
    }
    func testDedupCaseInsensitiveLowercased() {
        XCTAssertEqual(FavoritesSync.merge(server: ["#A"], local: ["#a", "#B"]), ["#a", "#b"])
    }
    func testUnionLosesNothing() {
        let m = FavoritesSync.merge(server: ["#a"], local: ["#z"])
        XCTAssertTrue(m.contains("#a") && m.contains("#z"))
    }
    func testEmpties() {
        XCTAssertEqual(FavoritesSync.merge(server: ["#x"], local: []), ["#x"])
        XCTAssertEqual(FavoritesSync.merge(server: [], local: ["#y"]), ["#y"])
        XCTAssertEqual(FavoritesSync.merge(server: [], local: []), [])
    }

    // MARK: - unjoined (roamed-in favorites we aren't in on this device)

    func testUnjoinedFindsFavoriteNotInChannelList() {
        // The reported bug: #freeq is favorited (roamed from another device)
        // but not joined here, so it rendered in neither sidebar group.
        XCTAssertEqual(
            FavoritesSync.unjoined(favorites: ["#freeq", "#general"], joined: ["#general"]),
            ["#freeq"])
    }

    func testUnjoinedIsCaseInsensitive() {
        // Channel names are case-insensitive; a case difference must not
        // produce a phantom "join me" row for a channel we're already in.
        XCTAssertTrue(FavoritesSync.unjoined(favorites: ["#freeq"], joined: ["#FreeQ"]).isEmpty)
    }

    func testUnjoinedExcludesDMsAndIsSorted() {
        // Only #channels are joinable; DM favorites must never appear.
        XCTAssertEqual(
            FavoritesSync.unjoined(favorites: ["#b", "#a", "alice"], joined: []),
            ["#a", "#b"])
    }

    func testUnjoinedEmptyWhenAllJoined() {
        XCTAssertTrue(FavoritesSync.unjoined(favorites: ["#a", "#b"], joined: ["#a", "#b"]).isEmpty)
        XCTAssertTrue(FavoritesSync.unjoined(favorites: [], joined: ["#a"]).isEmpty)
    }
}
