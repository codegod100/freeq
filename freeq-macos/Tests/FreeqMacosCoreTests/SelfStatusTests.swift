import XCTest
@testable import FreeqMacosCore

/// The status editor's emoji+text composition: one "emoji text" string on the
/// wire (IRC AWAY), two fields in the editor.
final class SelfStatusTests: XCTestCase {

    // MARK: - combined

    func testCombinedJoinsEmojiAndText() {
        XCTAssertEqual(SelfStatus.combined(emoji: "🛠️", text: "Building"), "🛠️ Building")
    }

    func testCombinedDropsEmptyParts() {
        XCTAssertEqual(SelfStatus.combined(emoji: "", text: "Focusing"), "Focusing")
        XCTAssertEqual(SelfStatus.combined(emoji: "🌙", text: ""), "🌙")
        XCTAssertEqual(SelfStatus.combined(emoji: "", text: ""), "")
    }

    func testCombinedTrimsWhitespace() {
        XCTAssertEqual(SelfStatus.combined(emoji: " 🌙 ", text: "  Away  "), "🌙 Away")
        XCTAssertEqual(SelfStatus.combined(emoji: "  ", text: " "), "")
    }

    // MARK: - split

    func testSplitRoundTripsAnEmojiStatus() {
        let (emoji, text) = SelfStatus.split("🛠️ Building")
        XCTAssertEqual(emoji, "🛠️")
        XCTAssertEqual(text, "Building")
    }

    func testSplitHandlesVariationSelectorEmoji() {
        let (emoji, text) = SelfStatus.split("☕️ Coffee")
        XCTAssertEqual(emoji, "☕️")
        XCTAssertEqual(text, "Coffee")
    }

    func testSplitPlainTextHasNoEmoji() {
        let (emoji, text) = SelfStatus.split("In a meeting")
        XCTAssertEqual(emoji, "")
        XCTAssertEqual(text, "In a meeting")
    }

    func testSplitDoesNotTreatDigitsAsEmoji() {
        // '1' carries Unicode isEmoji (keycap base) but must stay in the text.
        let (emoji, text) = SelfStatus.split("1:1 with Sam")
        XCTAssertEqual(emoji, "")
        XCTAssertEqual(text, "1:1 with Sam")
    }

    func testSplitEmptyString() {
        let (emoji, text) = SelfStatus.split("")
        XCTAssertEqual(emoji, "")
        XCTAssertEqual(text, "")
    }
}
