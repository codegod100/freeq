import XCTest
@testable import FreeqIosCore

/// FreeqIdentity.parse gates safety-relevant UI: `isOnFreeq` decides whether a
/// person gets a Message button and presence, so its edge cases (missing nick,
/// empty nick, agent class) must hold.
final class FreeqIdentityTests: XCTestCase {

    func testParseFullIdentity() {
        let id = FreeqIdentity.parse("did:plc:abc", [
            "online": true,
            "nick": "chad",
            "handle": "chadfowler.com",
            "channels": ["#freeq", "#dev"],
            "actor_class": "human",
        ])
        XCTAssertTrue(id.isOnFreeq)
        XCTAssertTrue(id.online)
        XCTAssertEqual(id.nick, "chad")
        XCTAssertEqual(id.channels, ["#freeq", "#dev"])
        XCTAssertFalse(id.isAgent)
    }

    func testUnknownDIDIsNotOnFreeq() {
        // A reachable-but-unknown DID: server returns online=false, no nick.
        let id = FreeqIdentity.parse("did:plc:stranger", ["online": false])
        XCTAssertFalse(id.isOnFreeq)
        XCTAssertNil(id.nick)
        XCTAssertTrue(id.channels.isEmpty)
    }

    func testEmptyNickDoesNotCountAsOnFreeq() {
        // An empty-string nick must not produce a Message button targeting "".
        let id = FreeqIdentity.parse("did:plc:x", ["nick": ""])
        XCTAssertFalse(id.isOnFreeq)
        XCTAssertNil(id.nick)
    }

    func testAgentClass() {
        let id = FreeqIdentity.parse("did:key:z6Mk", [
            "nick": "lobot", "actor_class": "agent",
        ])
        XCTAssertTrue(id.isAgent)
        XCTAssertTrue(id.isOnFreeq)
    }

    func testMissingFieldsDefaultSafely() {
        let id = FreeqIdentity.parse("did:plc:y", [:])
        XCTAssertFalse(id.online)
        XCTAssertFalse(id.isOnFreeq)
        XCTAssertFalse(id.isAgent)
        XCTAssertEqual(id.actorClass, "human")
    }
}
