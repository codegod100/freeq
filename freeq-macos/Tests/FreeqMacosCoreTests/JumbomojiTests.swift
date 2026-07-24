import XCTest
@testable import FreeqMacosCore

final class JumbomojiTests: XCTestCase {
    func testSizesOneToThreeLargestFirst() {
        XCTAssertEqual(Jumbomoji.size("🎉"), 48)
        XCTAssertEqual(Jumbomoji.size("🎉🚀"), 40)
        XCTAssertEqual(Jumbomoji.size("🎉🚀🔥"), 34)
    }

    func testIgnoresWhitespace() {
        XCTAssertEqual(Jumbomoji.size("🎉 🚀"), 40)
        XCTAssertEqual(Jumbomoji.size("  🔥  "), 48)
    }

    func testZwjAndModifiersCountAsOne() {
        XCTAssertTrue(Jumbomoji.isJumbomoji("👩‍💻"))
        XCTAssertTrue(Jumbomoji.isJumbomoji("👍🏽"))
        XCTAssertEqual(Jumbomoji.size("👩‍💻👨‍👩‍👧"), 40)
    }

    func testRejectsMoreThanThree() {
        XCTAssertNil(Jumbomoji.size("🎉🚀🔥💯"))
        XCTAssertFalse(Jumbomoji.isJumbomoji("😀😀😀😀😀"))
    }

    func testRejectsMixedText() {
        XCTAssertNil(Jumbomoji.size("nice 🎉"))
        XCTAssertNil(Jumbomoji.size("🎉!"))
        XCTAssertNil(Jumbomoji.size("lol"))
        XCTAssertNil(Jumbomoji.size("123"))
        XCTAssertNil(Jumbomoji.size("#"))
    }

    func testRejectsEmpty() {
        XCTAssertNil(Jumbomoji.size(""))
        XCTAssertNil(Jumbomoji.size("   "))
    }
}
