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

/// `+freeq.at/av-error` — the server's machine-readable AV failure. The
/// ghost-caller regression this guards: media is dialed and in-call UI is
/// flipped BEFORE av-join round-trips, so a rejected join (session ended /
/// full) must tear that ghost down; it used to arrive only as an unparsed
/// human NOTICE, leaving the client publishing into a session it was never
/// admitted to — in the call per its own UI, silent/invisible to everyone.
final class AvErrorResolutionTests: XCTestCase {
    func testJoinFailedForOurCallTearsDownAndRediscovers() {
        XCTAssertEqual(
            resolveAvError(code: "join-failed", errorSessionId: "S1",
                           currentCallSessionId: "S1", pendingStart: false),
            .teardownAndRediscover)
    }

    func testJoinFailedWithoutIdStillTearsDownOurCall() {
        // Older/degenerate server signal with no av-id: if we have a call up
        // from an optimistic join, it's the one that failed.
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
        // No call up at all — nothing to tear down.
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

    func testUnknownCodeIsIgnored() {
        XCTAssertEqual(
            resolveAvError(code: "some-future-code", errorSessionId: "S1",
                           currentCallSessionId: "S1", pendingStart: true),
            .ignore)
    }
}

/// Join → token → dial ordering (audit F7): the media dial is held until the
/// server's av-token arrives, with a tokenless fallback. Guards the exact
/// coupling that would break every native call when token enforcement flips.
final class MediaDialTests: XCTestCase {
    private let pending = PendingMediaDial(channel: "#x", sessionId: "S1", instance: "abc12345")

    func testTokenForOurSessionDials() {
        XCTAssertTrue(shouldDialOnToken(pending: pending, tokenSessionId: "S1"))
    }

    func testTokenForOtherOrNoPendingDoesNotDial() {
        XCTAssertFalse(shouldDialOnToken(pending: pending, tokenSessionId: "S2"),
                       "a stale token for another session must not dial into the wrong call")
        XCTAssertFalse(shouldDialOnToken(pending: nil, tokenSessionId: "S1"))
    }

    func testFallbackOnlyFiresForTheSameHeldDial() {
        XCTAssertTrue(shouldDialOnFallback(pending: pending, expected: pending))
        // Already dialed (pending cleared) or replaced by a newer call.
        XCTAssertFalse(shouldDialOnFallback(pending: nil, expected: pending))
        let newer = PendingMediaDial(channel: "#x", sessionId: "S2", instance: "def67890")
        XCTAssertFalse(shouldDialOnFallback(pending: newer, expected: pending))
    }

    func testDialUrlCarriesInstanceAndToken() {
        XCTAssertEqual(mediaDialUrl(base: "https://h:8080", instance: "abc12345", token: nil),
                       "https://h:8080?inst=abc12345")
        XCTAssertEqual(mediaDialUrl(base: "https://h:8080", instance: "abc12345", token: "e.y.J"),
                       "https://h:8080?inst=abc12345&jwt=e.y.J")
        // Token chars outside the unreserved set are percent-encoded.
        XCTAssertEqual(mediaDialUrl(base: "https://h:8080", instance: "i", token: "a+b/c="),
                       "https://h:8080?inst=i&jwt=a%2Bb%2Fc%3D")
        // Empty token = tokenless.
        XCTAssertEqual(mediaDialUrl(base: "https://h:8080", instance: "i", token: ""),
                       "https://h:8080?inst=i")
    }
}

/// Roster reconciliation for the native participant strip (audit F9).
final class RosterReconcileTests: XCTestCase {
    func testExcludesSelfByInstanceAndKeepsOurOtherDevice() {
        // Same nick as me on a DIFFERENT instance = my other device — shown.
        let roster = [
            AvRosterEntry(nick: "chad", instance: "me111111"),
            AvRosterEntry(nick: "chad", instance: "ipad2222"),
            AvRosterEntry(nick: "eve", instance: "eve33333"),
        ]
        XCTAssertEqual(
            reconcileCallParticipants(roster: roster, myNick: "chad", myInstance: "me111111"),
            ["chad", "eve"],
            "self excluded by instance; the other device with our nick stays")
    }

    func testLegacyRowsFallBackToNickAndDedupe() {
        let roster = [
            AvRosterEntry(nick: "Chad", instance: nil),   // legacy me — excluded by nick
            AvRosterEntry(nick: "Eve", instance: nil),
            AvRosterEntry(nick: "eve", instance: "e1"),   // dedupe (case-insensitive)
        ]
        XCTAssertEqual(
            reconcileCallParticipants(roster: roster, myNick: "chad", myInstance: "me111111"),
            ["Eve"])
    }

    func testStaleStripIsFullyReplaced() {
        // The reconciler returns the roster's truth — a participant whose
        // `left` TAGMSG we missed simply isn't in it.
        XCTAssertEqual(
            reconcileCallParticipants(
                roster: [AvRosterEntry(nick: "eve", instance: "e1")],
                myNick: "chad", myInstance: "me111111"),
            ["eve"])
        XCTAssertEqual(
            reconcileCallParticipants(roster: [], myNick: "chad", myInstance: "me111111"),
            [])
    }
}
