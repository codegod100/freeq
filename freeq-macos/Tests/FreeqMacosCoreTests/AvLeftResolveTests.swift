import XCTest
@testable import FreeqMacosCore

/// `av-state=left` teardown must key on the stable per-device instance, not the
/// actor nick. Regression for the "ghost tile on disconnect" bug in a 2-person
/// call: a multi-nick account is added under the media-path nick
/// (`chadfowler.com`) but the fast `left` TAGMSG names the dot-stripped actor
/// nick (`chadfowlercom`), so a nick-keyed removal misses.
final class AvLeftResolveTests: XCTestCase {
    func testInstanceMappedResolvesToMediaPathNick() {
        // The ghost case: two nicks, same DID. Instance resolves to the exact
        // nick the participant was added under.
        XCTAssertEqual(
            resolveAvLeftNick(
                instanceToNick: ["dev1": "chadfowler.com"],
                actorNick: "chadfowlercom",
                actorInstance: "dev1"),
            "chadfowler.com")
    }

    func testNilInstanceFallsBackToActorNick() {
        XCTAssertEqual(
            resolveAvLeftNick(
                instanceToNick: ["dev1": "chadfowler.com"],
                actorNick: "chadfowlercom",
                actorInstance: nil),
            "chadfowlercom")
    }

    func testUnknownInstanceFallsBackToActorNick() {
        XCTAssertEqual(
            resolveAvLeftNick(
                instanceToNick: ["dev1": "chadfowler.com"],
                actorNick: "chadfowlercom",
                actorInstance: "dev2"),
            "chadfowlercom")
    }

    func testEmptyInstanceFallsBackToActorNick() {
        XCTAssertEqual(
            resolveAvLeftNick(
                instanceToNick: ["dev1": "chadfowler.com"],
                actorNick: "chadfowlercom",
                actorInstance: ""),
            "chadfowlercom")
    }
}
