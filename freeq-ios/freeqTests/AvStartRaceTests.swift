import XCTest
@testable import freeq

/// Concurrent av-start race + av-error handling — iOS parity with macOS.
/// The regression these guard: "multiple people join a call and some can
/// hear each other and some can't, in random directions."
final class AvStartRaceTests: XCTestCase {
    // ── av-state=started convergence ──

    func testLoserOfConcurrentStartJoinsWinnersSession() {
        // We were trying to start (pending), but a PEER's start landed first.
        // Old iOS behavior: only joined when actor == self → the loser stayed
        // wedged outside the call. Must converge on the winner.
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

    // ── +freeq.at/av-error ──

    func testJoinFailedForOurCallTearsDownAndRediscovers() {
        XCTAssertEqual(
            resolveAvError(code: "join-failed", errorSessionId: "S1",
                           currentCallSessionId: "S1", pendingStart: false),
            .teardownAndRediscover)
    }

    func testJoinFailedWithoutIdStillTearsDownOurCall() {
        XCTAssertEqual(
            resolveAvError(code: "join-failed", errorSessionId: "",
                           currentCallSessionId: "S1", pendingStart: false),
            .teardownAndRediscover)
    }

    func testJoinFailedForAnotherSessionIsIgnored() {
        XCTAssertEqual(
            resolveAvError(code: "join-failed", errorSessionId: "S2",
                           currentCallSessionId: "S1", pendingStart: false),
            .ignore)
        XCTAssertEqual(
            resolveAvError(code: "join-failed", errorSessionId: "S1",
                           currentCallSessionId: nil, pendingStart: false),
            .ignore)
    }

    func testStartCollisionWhilePendingJoinsWinner() {
        XCTAssertEqual(
            resolveAvError(code: "start-collision", errorSessionId: "WINNER",
                           currentCallSessionId: nil, pendingStart: true),
            .joinSession("WINNER"))
    }

    func testStartCollisionWithoutPendingOrIdIsIgnored() {
        XCTAssertEqual(
            resolveAvError(code: "start-collision", errorSessionId: "WINNER",
                           currentCallSessionId: nil, pendingStart: false),
            .ignore)
        XCTAssertEqual(
            resolveAvError(code: "start-collision", errorSessionId: "",
                           currentCallSessionId: nil, pendingStart: true),
            .ignore)
    }
}
