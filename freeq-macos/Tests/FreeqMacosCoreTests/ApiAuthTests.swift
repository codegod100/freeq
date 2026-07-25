import XCTest
@testable import FreeqMacosCore

/// Channel-scoped REST endpoints enforce the same access rule as history, so a
/// private channel refuses a request with no bearer. These pin the header
/// construction that keeps pins/audit/sessions working for private channels.
final class ApiAuthTests: XCTestCase {
    func testNoBearerMeansNoHeader() {
        // Guests legitimately have no bearer; that must not become "Bearer nil".
        XCTAssertNil(ApiAuth.headerValue(bearer: nil))
        let req = ApiAuth.request(URL(string: "https://irc.freeq.at/api/v1/channels/x/pins")!,
                                 bearer: nil)
        XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"))
    }

    func testBlankBearerIsTreatedAsAbsent() {
        // A cleared session can leave an empty string behind; sending "Bearer "
        // is worse than sending nothing.
        XCTAssertNil(ApiAuth.headerValue(bearer: ""))
        XCTAssertNil(ApiAuth.headerValue(bearer: "   "))
        XCTAssertNil(ApiAuth.headerValue(bearer: "\n"))
    }

    func testBearerIsSentWhenPresent() {
        XCTAssertEqual(ApiAuth.headerValue(bearer: "sess-abc"), "Bearer sess-abc")
        let req = ApiAuth.request(URL(string: "https://irc.freeq.at/api/v1/channels/x/pins")!,
                                 bearer: "sess-abc")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer sess-abc")
    }

    func testRequestPreservesTheUrl() {
        let url = URL(string: "https://irc.freeq.at/api/v1/channels/%23secret/sessions")!
        XCTAssertEqual(ApiAuth.request(url, bearer: "s").url, url)
    }
}
