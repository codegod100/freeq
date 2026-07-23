import XCTest
@testable import FreeqMacosCore

/// Single-flight gate for connection attempts. The concurrency policy here is
/// what prevents the reconnect *storm* (multiple triggers → multiple sockets →
/// stranded half-open connections + duplicate server-side sessions).
final class ConnectGateTests: XCTestCase {

    func testFreshGateAllowsOneAttempt() {
        var gate = ConnectGate()
        XCTAssertFalse(gate.isBusy)
        XCTAssertTrue(gate.beginAttempt())
        XCTAssertTrue(gate.isBusy)
    }

    func testSecondConcurrentTriggerIsSuppressed() {
        var gate = ConnectGate()
        XCTAssertTrue(gate.beginAttempt())
        // Wake + foreground + disconnect + timer all racing: only the first wins.
        XCTAssertFalse(gate.beginAttempt())
        XCTAssertFalse(gate.beginAttempt())
        XCTAssertFalse(gate.beginAttempt())
    }

    func testNoNewAttemptWhileLive() {
        var gate = ConnectGate()
        XCTAssertTrue(gate.beginAttempt())
        gate.settle()  // reached IRC `registered`
        XCTAssertFalse(gate.isBusy == false)  // live ⇒ busy
        XCTAssertFalse(gate.beginAttempt(), "must not reconnect while already connected")
    }

    func testDropAfterFailureReopensTheGate() {
        var gate = ConnectGate()
        XCTAssertTrue(gate.beginAttempt())
        gate.drop()  // broker fetch failed / connect threw
        XCTAssertFalse(gate.isBusy)
        XCTAssertTrue(gate.beginAttempt(), "a failed attempt must not latch the gate shut")
    }

    func testDropAfterDisconnectReopensTheGate() {
        var gate = ConnectGate()
        XCTAssertTrue(gate.beginAttempt())
        gate.settle()             // connected
        gate.drop()               // connection later dropped
        XCTAssertFalse(gate.isBusy)
        XCTAssertTrue(gate.beginAttempt(), "post-disconnect reconnect must be allowed")
    }

    func testSettleEndsInFlightWindow() {
        var gate = ConnectGate()
        _ = gate.beginAttempt()
        XCTAssertEqual(gate, ConnectGate.inFlightForTesting)
        gate.settle()
        XCTAssertEqual(gate, ConnectGate.liveForTesting)
    }

    func testFullReconnectCycleNeverStalls() {
        var gate = ConnectGate()
        // Storm scenario: many triggers, one attempt, it fails, retry succeeds,
        // drops again, and a final retry is still permitted.
        XCTAssertTrue(gate.beginAttempt())
        XCTAssertFalse(gate.beginAttempt())
        gate.drop()
        XCTAssertTrue(gate.beginAttempt())
        gate.settle()
        XCTAssertFalse(gate.beginAttempt())
        gate.drop()
        XCTAssertTrue(gate.beginAttempt())
    }
}

private extension ConnectGate {
    static var inFlightForTesting: ConnectGate {
        var g = ConnectGate(); _ = g.beginAttempt(); return g
    }
    static var liveForTesting: ConnectGate {
        var g = ConnectGate(); _ = g.beginAttempt(); g.settle(); return g
    }
}
