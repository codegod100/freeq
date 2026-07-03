import XCTest
@testable import FreeqMacosCore

final class CommandRegistryTests: XCTestCase {
    // MARK: - Registry invariants

    func testCommandIdsAreUnique() {
        let ids = CommandRegistry.all.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "duplicate command ids")
    }

    func testShortcutLabelsAreUnique() {
        let labels = CommandRegistry.all.compactMap(\.shortcutLabel)
        XCTAssertEqual(labels.count, Set(labels).count, "two commands claim one shortcut")
    }

    func testEveryCommandHasCategory() {
        XCTAssertFalse(CommandRegistry.all.contains { $0.category.isEmpty })
    }

    func testLookupById() {
        XCTAssertEqual(CommandRegistry.command("call.leave")?.title, "Leave Call")
        XCTAssertNil(CommandRegistry.command("nope"))
    }

    // MARK: - Matcher ranking

    func testTitlePrefixOutranksWordBoundary() {
        let ranked = CommandMatcher.rank(query: "to", in: CommandRegistry.all)
        // "Toggle …" (title prefix) must come before anything matching
        // "to" only at a later word boundary.
        XCTAssertTrue(ranked.first?.title.lowercased().hasPrefix("to") ?? false)
    }

    func testWordBoundaryMatch() {
        let ranked = CommandMatcher.rank(query: "mute", in: CommandRegistry.all)
        XCTAssertTrue(ranked.contains { $0.id == "call.toggleMute" },
                      "\"mute\" should match Toggle Mute at a word boundary")
    }

    func testKeywordMatch() {
        let ranked = CommandMatcher.rank(query: "afk", in: CommandRegistry.all)
        XCTAssertEqual(ranked.first?.id, "presence.toggleAway")
    }

    func testSubsequenceMatch() {
        XCTAssertTrue(CommandMatcher.isSubsequence("lvc", of: "leave call"))
        XCTAssertFalse(CommandMatcher.isSubsequence("xyz", of: "leave call"))
        let ranked = CommandMatcher.rank(query: "lvcall", in: CommandRegistry.all)
        XCTAssertTrue(ranked.contains { $0.id == "call.leave" })
    }

    func testEmptyQueryReturnsNothing() {
        XCTAssertTrue(CommandMatcher.rank(query: "  ", in: CommandRegistry.all).isEmpty)
    }

    func testCaseInsensitive() {
        let ranked = CommandMatcher.rank(query: "BOOKMARKS", in: CommandRegistry.all)
        XCTAssertEqual(ranked.first?.id, "nav.bookmarks")
    }

    func testNoMatchReturnsEmpty() {
        XCTAssertTrue(CommandMatcher.rank(query: "zzzzqqq", in: CommandRegistry.all).isEmpty)
    }
}
