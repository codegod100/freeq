import XCTest
@testable import FreeqMacosCore

/// Tests for classifying the server's /api/v1/upload response into an
/// actionable outcome — so a guest sees "sign in to upload" and a
/// Bluesky-share needing PDS scope triggers step-up, instead of a raw
/// status string (the old 403/401 dead-end).
final class UploadResponseTests: XCTestCase {

    private func data(_ s: String) -> Data { Data(s.utf8) }

    func testSuccessExtractsURL() {
        let out = UploadResponse.classify(
            status: 200, body: data(#"{"url":"https://cdn/x.png"}"#))
        XCTAssertEqual(out, .success(url: "https://cdn/x.png"))
    }

    func testSuccessMissingURLIsServerError() {
        let out = UploadResponse.classify(status: 200, body: data(#"{"ok":true}"#))
        if case .failure(.malformed) = out {} else { XCTFail("expected malformed, got \(out)") }
    }

    func testUnauthorizedMeansSignInNeeded() {
        let out = UploadResponse.classify(
            status: 401, body: data("Upload requires an active connection for this DID"))
        XCTAssertEqual(out, .failure(.notAuthenticated))
    }

    func testStepUpRequiredParsesPurposeAndURL() {
        let body = data(#"{"error":"step_up_required","purpose":"blob_upload","step_up_url":"/auth/step-up?purpose=blob_upload"}"#)
        let out = UploadResponse.classify(status: 403, body: body)
        XCTAssertEqual(out, .failure(.stepUpRequired(
            purpose: "blob_upload", url: "/auth/step-up?purpose=blob_upload")))
    }

    func testForbiddenWithoutStepUpIsServerError() {
        let out = UploadResponse.classify(status: 403, body: data("nope"))
        XCTAssertEqual(out, .failure(.server(message: "nope")))
    }

    func testPayloadTooLarge() {
        let out = UploadResponse.classify(status: 413, body: data("File too large (max 10MB)"))
        XCTAssertEqual(out, .failure(.tooLarge))
    }

    func testRateLimited() {
        let out = UploadResponse.classify(status: 429, body: data("Rate limit exceeded"))
        XCTAssertEqual(out, .failure(.rateLimited))
    }

    func testGenericServerError() {
        let out = UploadResponse.classify(status: 500, body: data("boom"))
        XCTAssertEqual(out, .failure(.server(message: "boom")))
    }

    func testEmptyBodyServerErrorHasFallbackMessage() {
        let out = UploadResponse.classify(status: 502, body: Data())
        guard case .failure(let failure) = out else {
            return XCTFail("expected server error")
        }
        // Raw text may be empty; the user-facing message must not be.
        XCTAssertFalse(failure.userMessage.isEmpty)
    }

    // User-facing messages must be actionable, not raw protocol text.
    func testUserMessages() {
        XCTAssertTrue(UploadResponse.Failure.notAuthenticated.userMessage
            .localizedCaseInsensitiveContains("sign in"))
        XCTAssertTrue(UploadResponse.Failure.tooLarge.userMessage
            .localizedCaseInsensitiveContains("10"))
        XCTAssertTrue(UploadResponse.Failure
            .stepUpRequired(purpose: "blob_upload", url: "/x").userMessage
            .localizedCaseInsensitiveContains("permission"))
    }
}
