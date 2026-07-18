import XCTest
@testable import FreeqMacosCore

/// The freeq server relays a client's own actions to OTHER members but does
/// not always echo them back to the author:
///   - PRIVMSG (plain messages, edits, replies): echoed to the author IF they
///     hold the `echo-message` cap (the macOS client does), so the author's
///     view updates on echo.
///   - TAGMSG (reactions, deletes): NEVER echoed to the author
///     (freeq-server messaging.rs skips the sender), so the author's client
///     MUST apply the effect locally or their own view never updates.
///
/// This policy is the single source of truth for "do I need to update my own
/// view immediately?" — the delete bug was a missing optimistic apply that
/// reactions already had.
final class SelfActionEchoTests: XCTestCase {

    func testTagmsgActionsNeedOptimisticApply() {
        XCTAssertTrue(SelfActionEcho.needsOptimisticLocalApply(.delete))
        XCTAssertTrue(SelfActionEcho.needsOptimisticLocalApply(.react))
        XCTAssertTrue(SelfActionEcho.needsOptimisticLocalApply(.unreact))
    }

    func testEchoedActionsDoNotNeedOptimisticApply() {
        // These come back via echo-message, so applying locally too would
        // double-apply.
        XCTAssertFalse(SelfActionEcho.needsOptimisticLocalApply(.plainMessage))
        XCTAssertFalse(SelfActionEcho.needsOptimisticLocalApply(.edit))
    }
}
