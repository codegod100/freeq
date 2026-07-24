import XCTest
@testable import FreeqIosCore

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
}
