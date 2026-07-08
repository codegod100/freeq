import XCTest
@testable import FreeqMacosCore

/// Auto-rejoin decision on reconnect — the client half of the server's AV
/// teardown grace. If we drop mid-call and reconnect within the grace window,
/// rejoining the same channel must re-enter the same session; a stale or
/// mismatched pending must not.
final class AvRejoinTests: XCTestCase {
    private func pending(_ channel: String, at: Date) -> PendingCallRejoin {
        PendingCallRejoin(channel: channel, sessionId: "S1", instance: "devA", disconnectedAt: at)
    }

    func testRejoinsSameChannelWithinWindow() {
        let now = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(shouldRejoinCall(
            pending: pending("#freeq", at: now.addingTimeInterval(-5)),
            joinedChannel: "#freeq", now: now))
    }

    func testNoPendingDoesNotRejoin() {
        XCTAssertFalse(shouldRejoinCall(
            pending: nil, joinedChannel: "#freeq", now: Date()))
    }

    func testDifferentChannelDoesNotRejoin() {
        let now = Date(timeIntervalSince1970: 1000)
        XCTAssertFalse(shouldRejoinCall(
            pending: pending("#other", at: now.addingTimeInterval(-5)),
            joinedChannel: "#freeq", now: now))
    }

    func testExpiredPendingDoesNotRejoin() {
        // Drop was 45s ago — past the 30s grace, the server slot is gone.
        let now = Date(timeIntervalSince1970: 1000)
        XCTAssertFalse(shouldRejoinCall(
            pending: pending("#freeq", at: now.addingTimeInterval(-45)),
            joinedChannel: "#freeq", now: now))
    }

    func testChannelMatchIsCaseInsensitive() {
        let now = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(shouldRejoinCall(
            pending: pending("#Freeq", at: now.addingTimeInterval(-1)),
            joinedChannel: "#freeq", now: now))
    }
}
