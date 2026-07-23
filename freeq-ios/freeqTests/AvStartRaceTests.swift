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

    // ── join → token → dial (audit F7) ──

    func testTokenForOurSessionDialsAndOthersDont() {
        let pending = PendingMediaDial(channel: "#x", sessionId: "S1", instance: "abc12345")
        XCTAssertTrue(shouldDialOnToken(pending: pending, tokenSessionId: "S1"))
        XCTAssertFalse(shouldDialOnToken(pending: pending, tokenSessionId: "S2"))
        XCTAssertFalse(shouldDialOnToken(pending: nil, tokenSessionId: "S1"))
    }

    func testFallbackOnlyFiresForTheSameHeldDial() {
        let pending = PendingMediaDial(channel: "#x", sessionId: "S1", instance: "abc12345")
        XCTAssertTrue(shouldDialOnFallback(pending: pending, expected: pending))
        XCTAssertFalse(shouldDialOnFallback(pending: nil, expected: pending))
        let newer = PendingMediaDial(channel: "#x", sessionId: "S2", instance: "def67890")
        XCTAssertFalse(shouldDialOnFallback(pending: newer, expected: pending))
    }

    func testDialUrlCarriesInstanceAndToken() {
        XCTAssertEqual(mediaDialUrl(base: "https://h:8080", instance: "i", token: nil),
                       "https://h:8080?inst=i")
        XCTAssertEqual(mediaDialUrl(base: "https://h:8080", instance: "i", token: "a+b/c="),
                       "https://h:8080?inst=i&jwt=a%2Bb%2Fc%3D")
        XCTAssertEqual(mediaDialUrl(base: "https://h:8080", instance: "i", token: ""),
                       "https://h:8080?inst=i")
    }

    // ── roster reconciliation (audit F9) ──

    func testReconcileExcludesSelfByInstanceAndKeepsOtherDevice() {
        let roster = [
            AvRosterEntry(nick: "chad", instance: "me111111"),
            AvRosterEntry(nick: "chad", instance: "ipad2222"),
            AvRosterEntry(nick: "eve", instance: "eve33333"),
        ]
        XCTAssertEqual(
            reconcileCallParticipants(roster: roster, myNick: "chad", myInstance: "me111111"),
            ["chad", "eve"])
    }

    func testReconcileLegacyRowsFallBackToNickAndDedupe() {
        let roster = [
            AvRosterEntry(nick: "Chad", instance: nil),
            AvRosterEntry(nick: "Eve", instance: nil),
            AvRosterEntry(nick: "eve", instance: "e1"),
        ]
        XCTAssertEqual(
            reconcileCallParticipants(roster: roster, myNick: "chad", myInstance: "me111111"),
            ["Eve"])
    }
}
