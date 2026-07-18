import XCTest
@testable import FreeqMacosCore

final class ComposeHistoryTests: XCTestCase {
    func testRecallPreviousWalksNewestToOldest() {
        var h = ComposeHistory()
        h.record("first")
        h.record("second")
        h.record("third")
        XCTAssertEqual(h.recallPrevious(draft: ""), "third")
        XCTAssertEqual(h.recallPrevious(draft: ""), "second")
        XCTAssertEqual(h.recallPrevious(draft: ""), "first")
        // At the oldest entry, further steps do nothing.
        XCTAssertNil(h.recallPrevious(draft: ""))
    }

    func testRecallNextRestoresDraftPastNewest() {
        var h = ComposeHistory()
        h.record("sent")
        XCTAssertEqual(h.recallPrevious(draft: "work in progress"), "sent")
        // Walking forward past the newest restores the stashed draft.
        XCTAssertEqual(h.recallNext(), "work in progress")
        XCTAssertFalse(h.isRecalling)
        // Not recalling → next is a no-op.
        XCTAssertNil(h.recallNext())
    }

    func testRoundTripThroughHistory() {
        var h = ComposeHistory()
        h.record("a")
        h.record("b")
        XCTAssertEqual(h.recallPrevious(draft: "draft"), "b")
        XCTAssertEqual(h.recallPrevious(draft: "ignored"), "a")
        XCTAssertEqual(h.recallNext(), "b")
        XCTAssertEqual(h.recallNext(), "draft")
    }

    func testEmptyHistoryRecallsNothing() {
        var h = ComposeHistory()
        XCTAssertNil(h.recallPrevious(draft: "draft"))
        XCTAssertNil(h.recallNext())
    }

    func testRecordResetsRecallState() {
        var h = ComposeHistory()
        h.record("a")
        _ = h.recallPrevious(draft: "draft")
        XCTAssertTrue(h.isRecalling)
        h.record("b")
        XCTAssertFalse(h.isRecalling)
        // Fresh recall starts from the new newest.
        XCTAssertEqual(h.recallPrevious(draft: ""), "b")
    }

    func testConsecutiveDuplicatesCollapse() {
        var h = ComposeHistory()
        h.record("same")
        h.record("same")
        XCTAssertEqual(h.entries, ["same"])
        h.record("other")
        h.record("same")
        XCTAssertEqual(h.entries, ["same", "other", "same"])
    }

    func testBlankEntriesIgnored() {
        var h = ComposeHistory()
        h.record("   ")
        h.record("\n")
        XCTAssertTrue(h.entries.isEmpty)
    }

    func testLimitEvictsOldest() {
        var h = ComposeHistory()
        h.limit = 3
        for i in 1...5 { h.record("msg\(i)") }
        XCTAssertEqual(h.entries, ["msg3", "msg4", "msg5"])
    }

    func testCancelRecallDropsDraftStash() {
        var h = ComposeHistory()
        h.record("a")
        _ = h.recallPrevious(draft: "draft")
        h.cancelRecall()
        XCTAssertFalse(h.isRecalling)
        XCTAssertNil(h.recallNext())
    }
}
