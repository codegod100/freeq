import XCTest
@testable import FreeqMacosCore

final class MessageTimelineTests: XCTestCase {
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 12) -> Date {
        cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h))!
    }

    // MARK: - Separator placement

    func testFirstMessageGetsSeparator() {
        XCTAssertTrue(MessageTimeline.showsDateSeparator(
            before: date(2026, 7, 2), previous: nil, calendar: cal))
    }

    func testSameDayNoSeparator() {
        XCTAssertFalse(MessageTimeline.showsDateSeparator(
            before: date(2026, 7, 2, 18), previous: date(2026, 7, 2, 9), calendar: cal))
    }

    func testDayBoundaryGetsSeparator() {
        XCTAssertTrue(MessageTimeline.showsDateSeparator(
            before: date(2026, 7, 2, 0), previous: date(2026, 7, 1, 23), calendar: cal))
    }

    func testYearBoundaryGetsSeparator() {
        XCTAssertTrue(MessageTimeline.showsDateSeparator(
            before: date(2026, 1, 1), previous: date(2025, 12, 31), calendar: cal))
    }

    // MARK: - Labels

    func testTodayLabel() {
        let now = date(2026, 7, 2, 15)
        XCTAssertEqual(
            MessageTimeline.dayLabel(for: date(2026, 7, 2, 1), now: now, calendar: cal),
            "Today")
    }

    func testYesterdayLabel() {
        let now = date(2026, 7, 2)
        XCTAssertEqual(
            MessageTimeline.dayLabel(for: date(2026, 7, 1, 23), now: now, calendar: cal),
            "Yesterday")
    }

    func testSameYearLabelOmitsYear() {
        let now = date(2026, 7, 2)
        let label = MessageTimeline.dayLabel(
            for: date(2026, 6, 20), now: now, calendar: cal,
            locale: Locale(identifier: "en_US"))
        XCTAssertEqual(label, "Saturday, June 20")
    }

    func testOtherYearLabelIncludesYear() {
        let now = date(2026, 7, 2)
        let label = MessageTimeline.dayLabel(
            for: date(2025, 12, 25), now: now, calendar: cal,
            locale: Locale(identifier: "en_US"))
        XCTAssertTrue(label.contains("2025"), "expected year in \(label)")
        XCTAssertTrue(label.contains("December 25"), "expected date in \(label)")
    }
}
