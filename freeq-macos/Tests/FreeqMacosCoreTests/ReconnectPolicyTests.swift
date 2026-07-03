import XCTest
@testable import FreeqMacosCore

/// IRC reconnect pacing. Most disconnects happen with a healthy network
/// (server restart, idle timeout), so the first retry must be near-instant;
/// only sustained failure backs off.
final class ReconnectPolicyTests: XCTestCase {

    func testFirstRetryIsNearInstant() {
        XCTAssertEqual(ReconnectPolicy.delay(afterAttempt: 1), 0.5)
    }

    func testBackoffGrowsThenCaps() {
        XCTAssertEqual(ReconnectPolicy.delay(afterAttempt: 2), 2)
        XCTAssertEqual(ReconnectPolicy.delay(afterAttempt: 3), 4)
        XCTAssertEqual(ReconnectPolicy.delay(afterAttempt: 4), 8)
        XCTAssertEqual(ReconnectPolicy.delay(afterAttempt: 5), 16)
        XCTAssertEqual(ReconnectPolicy.delay(afterAttempt: 6), 30)
        XCTAssertEqual(ReconnectPolicy.delay(afterAttempt: 60), 30)
    }

    func testDegenerateAttemptNumbersAreSafe() {
        XCTAssertEqual(ReconnectPolicy.delay(afterAttempt: 0), 0.5)
        XCTAssertEqual(ReconnectPolicy.delay(afterAttempt: -3), 0.5)
        XCTAssertEqual(ReconnectPolicy.delay(afterAttempt: Int.max), 30)
    }
}
