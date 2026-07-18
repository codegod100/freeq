import XCTest
@testable import FreeqMacosCore

final class ComposeTextExtractionTests: XCTestCase {
    func testPlainTextPassesThrough() {
        XCTAssertEqual(ComposeTextExtraction.sendable("hello world"), "hello world")
    }

    func testEmptyPassesThrough() {
        XCTAssertEqual(ComposeTextExtraction.sendable(""), "")
    }

    func testStripsObjectReplacementPlaceholders() {
        // A Genmoji reads back as U+FFFC in the plain string.
        XCTAssertEqual(ComposeTextExtraction.sendable("hi \u{FFFC} there"), "hi  there")
        XCTAssertEqual(ComposeTextExtraction.sendable("\u{FFFC}\u{FFFC}"), "")
    }

    func testUnicodeAndEmojiUnaffected() {
        XCTAssertEqual(ComposeTextExtraction.sendable("café 🎉 日本語"), "café 🎉 日本語")
    }
}
