import XCTest
@testable import FreeqMacosCore

/// The verified-proof sheet's data layer: parsing `/api/v1/verify/{msgid}` and
/// `/api/v1/signing-keys/{did}` responses, and the honest verdict strings.
final class SignatureProofTests: XCTestCase {

    // MARK: - VerifyResult parsing

    func testParsesClientSessionKeyVerification() {
        let r = VerifyResult.from(json: [
            "verification": ["valid": true, "verified_by": "client-session-key"]
        ])
        XCTAssertTrue(r.valid)
        XCTAssertEqual(r.verifiedBy, "client-session-key")
    }

    func testParsesNullVerificationAsUnverified() {
        // The server returns `verification: null` for an unsigned message.
        let r = VerifyResult.from(json: ["verification": NSNull()])
        XCTAssertFalse(r.valid)
        XCTAssertEqual(r.verifiedBy, "none")
    }

    func testParsesMissingVerificationAsUnverified() {
        let r = VerifyResult.from(json: [:])
        XCTAssertFalse(r.valid)
        XCTAssertEqual(r.verifiedBy, "none")
    }

    // MARK: - Verdict strings (CHECKED result, never an assertion)

    func testClientKeyVerdictSaysSignedOnDevice() {
        let r = VerifyResult(valid: true, verifiedBy: "client-session-key")
        XCTAssertTrue(r.summary.contains("signed on the sender's own device"))
    }

    func testServerKeyVerdictSaysSignedByServer() {
        let r = VerifyResult(valid: true, verifiedBy: "server-key")
        XCTAssertTrue(r.summary.contains("signed by the server"))
    }

    func testUnknownButValidVerdictStaysGeneric() {
        let r = VerifyResult(valid: true, verifiedBy: "future-mechanism")
        XCTAssertTrue(r.summary.hasPrefix("Verified"))
        XCTAssertFalse(r.summary.contains("device"))
        XCTAssertFalse(r.summary.contains("server"))
    }

    func testInvalidVerdictSaysCouldNotBeVerified() {
        let r = VerifyResult(valid: false, verifiedBy: "none")
        XCTAssertTrue(r.summary.contains("could not be verified"))
        // An invalid signature must never read as verified.
        XCTAssertFalse(r.summary.hasPrefix("Verified"))
    }

    // MARK: - SigningKeyInfo

    func testParsesSigningKeyWithDefaults() {
        let k = SigningKeyInfo.from(json: ["public_key": "z6Mk..."])
        XCTAssertEqual(k?.publicKey, "z6Mk...")
        XCTAssertEqual(k?.algorithm, "ed25519")
        XCTAssertEqual(k?.sourceLabel, "server-attested")
    }

    func testMissingPublicKeyYieldsNil() {
        XCTAssertNil(SigningKeyInfo.from(json: ["algorithm": "ed25519"]))
    }

    func testClientSessionSourceLabel() {
        let k = SigningKeyInfo(publicKey: "pk", algorithm: "ed25519", source: "client-session")
        XCTAssertEqual(k.sourceLabel, "signed on their device")
    }
}
