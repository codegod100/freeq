import XCTest
@testable import FreeqMacosCore

final class ComposeFormattingTests: XCTestCase {
    // MARK: - Selection wrapping

    func testWrapsSelectionInBold() {
        let r = ComposeFormatting.wrap(
            text: "hello world", selectionLocation: 6, selectionLength: 5,
            prefix: "**", suffix: "**")
        XCTAssertEqual(r.text, "hello **world**")
        // Selection stays on the inner text so formats compose.
        XCTAssertEqual(r.selectionLocation, 8)
        XCTAssertEqual(r.selectionLength, 5)
    }

    func testWrapsMidStringSelection() {
        let r = ComposeFormatting.wrap(
            text: "abc def ghi", selectionLocation: 4, selectionLength: 3,
            prefix: "_", suffix: "_")
        XCTAssertEqual(r.text, "abc _def_ ghi")
        XCTAssertEqual(r.selectionLocation, 5)
        XCTAssertEqual(r.selectionLength, 3)
    }

    func testNoSelectionInsertsMarkersAndPlacesCaretBetween() {
        let r = ComposeFormatting.wrap(
            text: "hello ", selectionLocation: 6, selectionLength: 0,
            prefix: "`", suffix: "`")
        XCTAssertEqual(r.text, "hello ``")
        XCTAssertEqual(r.selectionLocation, 7)
        XCTAssertEqual(r.selectionLength, 0)
    }

    func testEmptyTextNoSelection() {
        let r = ComposeFormatting.wrap(
            text: "", selectionLocation: 0, selectionLength: 0,
            prefix: "**", suffix: "**")
        XCTAssertEqual(r.text, "****")
        XCTAssertEqual(r.selectionLocation, 2)
    }

    // MARK: - Link placeholder

    func testLinkWithSelectionSelectsUrlPlaceholder() {
        let r = ComposeFormatting.wrap(
            text: "see docs here", selectionLocation: 4, selectionLength: 4,
            prefix: "[", suffix: "](url)", placeholder: "url")
        XCTAssertEqual(r.text, "see [docs](url) here")
        // "url" is selected so the user can type over it.
        let ns = r.text as NSString
        XCTAssertEqual(
            ns.substring(with: NSRange(location: r.selectionLocation, length: r.selectionLength)),
            "url")
    }

    func testLinkWithoutSelectionPlacesCaretInBrackets() {
        let r = ComposeFormatting.wrap(
            text: "", selectionLocation: 0, selectionLength: 0,
            prefix: "[", suffix: "](url)", placeholder: "url")
        XCTAssertEqual(r.text, "[](url)")
        XCTAssertEqual(r.selectionLocation, 1)
        XCTAssertEqual(r.selectionLength, 0)
    }

    // MARK: - Robustness

    func testOutOfBoundsSelectionClamps() {
        let r = ComposeFormatting.wrap(
            text: "abc", selectionLocation: 10, selectionLength: 5,
            prefix: "*", suffix: "*")
        XCTAssertEqual(r.text, "abc**")
        XCTAssertEqual(r.selectionLocation, 4)
    }

    func testNegativeSelectionClamps() {
        let r = ComposeFormatting.wrap(
            text: "abc", selectionLocation: -2, selectionLength: -3,
            prefix: "*", suffix: "*")
        XCTAssertEqual(r.text, "**abc")
        XCTAssertEqual(r.selectionLocation, 1)
        XCTAssertEqual(r.selectionLength, 0)
    }

    func testEmojiSelectionUsesUtf16Offsets() {
        // "🎉" is 2 UTF-16 units; selecting it must not split the pair.
        let text = "a🎉b"
        let r = ComposeFormatting.wrap(
            text: text, selectionLocation: 1, selectionLength: 2,
            prefix: "**", suffix: "**")
        XCTAssertEqual(r.text, "a**🎉**b")
        XCTAssertEqual(r.selectionLocation, 3)
        XCTAssertEqual(r.selectionLength, 2)
    }

    func testWholeStringSelection() {
        let r = ComposeFormatting.wrap(
            text: "ship it", selectionLocation: 0, selectionLength: 7,
            prefix: "~~", suffix: "~~")
        XCTAssertEqual(r.text, "~~ship it~~")
        XCTAssertEqual(r.selectionLocation, 2)
        XCTAssertEqual(r.selectionLength, 7)
    }
}
