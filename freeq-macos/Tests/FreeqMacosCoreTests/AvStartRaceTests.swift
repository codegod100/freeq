import XCTest
@testable import FreeqMacosCore

/// Concurrent av-start race — the loser must converge on the winner's session
/// instead of getting wedged. Regression for "2-person call where we could
/// never see/hear each other; rejoin sometimes fixed it."
final class AvStartRaceTests: XCTestCase {
    func testLoserOfConcurrentStartJoinsWinnersSession() {
        // We were trying to start (pending), but a PEER's start landed first.
        // Old behavior: notify only → stuck out of the call. Must join.
        XCTAssertEqual(
            resolveAvStarted(pendingStart: true, actorIsSelf: false, sessionId: "S1"),
            .joinSession("S1"))
    }

    func testWinnerJoinsOwnSession() {
        XCTAssertEqual(
            resolveAvStarted(pendingStart: true, actorIsSelf: true, sessionId: "S1"),
            .joinSession("S1"))
    }

    func testPeerStartedWhileNotPendingNudgesJoin() {
        XCTAssertEqual(
            resolveAvStarted(pendingStart: false, actorIsSelf: false, sessionId: "S1"),
            .notifyPeerStarted)
    }

    func testOwnEchoWithNothingPendingIsIgnored() {
        XCTAssertEqual(
            resolveAvStarted(pendingStart: false, actorIsSelf: true, sessionId: "S1"),
            .ignore)
    }
}
