import XCTest
@testable import FreeqIosCore

/// Coordination-card presentation policy — the native analogue of the web
/// CoordinationCards dispatcher. Pure mapping, so it's fully unit-tested.
final class CoordinationCardTests: XCTestCase {

    private func info(_ event: String, phase: String? = nil,
                      evidence: String? = nil, payload: String? = nil) -> CoordinationInfo {
        CoordinationInfo(eventType: event, taskId: "T1", phase: phase,
                         evidenceType: evidence, reference: nil, payload: payload)
    }

    func testKnownEventStyles() {
        XCTAssertEqual(CoordinationCard.style(for: info("task_request")).label, "New Task")
        XCTAssertEqual(CoordinationCard.style(for: info("task_request")).accent, .agent)
        XCTAssertEqual(CoordinationCard.style(for: info("task_complete")).accent, .success)
        XCTAssertEqual(CoordinationCard.style(for: info("task_failed")).accent, .error)
        XCTAssertEqual(CoordinationCard.style(for: info("task_accept")).icon, "👍")
    }

    func testTaskUpdateUsesPhaseIconAndLabel() {
        let s = CoordinationCard.style(for: info("task_update", phase: "testing"))
        XCTAssertEqual(s.icon, "🧪")
        XCTAssertEqual(s.label, "Testing")
    }

    func testTaskUpdateWithoutPhaseFallsBack() {
        let s = CoordinationCard.style(for: info("task_update"))
        XCTAssertEqual(s.icon, "📌")
        XCTAssertEqual(s.label, "Update")
    }

    func testEvidenceCardIsExpandableWithTypedIconAndHumanLabel() {
        let s = CoordinationCard.style(for: info("evidence_attach", evidence: "test_result"))
        XCTAssertTrue(s.expandablePayload)
        XCTAssertEqual(s.icon, "🧪")
        XCTAssertEqual(s.label, "test result")
    }

    func testUnknownEventGetsGenericCardLabeledWithRawName() {
        let s = CoordinationCard.style(for: info("weird_new_event"))
        XCTAssertEqual(s.icon, "📌")
        XCTAssertEqual(s.label, "weird_new_event")
        XCTAssertFalse(s.expandablePayload)
    }

    func testPrettyPayloadFormatsJSON() {
        let out = CoordinationCard.prettyPayload("{\"of\":5,\"step\":3}")
        XCTAssertEqual(out, "{\n  \"of\" : 5,\n  \"step\" : 3\n}")
    }

    func testPrettyPayloadPassesThroughNonJSON() {
        XCTAssertEqual(CoordinationCard.prettyPayload("not json"), "not json")
        XCTAssertNil(CoordinationCard.prettyPayload(nil))
        XCTAssertNil(CoordinationCard.prettyPayload(""))
    }
}
