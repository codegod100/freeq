import XCTest
@testable import FreeqMacosCore

final class ShareURLTests: XCTestCase {

    private func parse(_ s: String) -> ShareURL.Payload? {
        ShareURL.parse(URL(string: s)!)
    }

    func testRejectsWrongScheme() {
        XCTAssertNil(parse("https://share?text=hi"))
        XCTAssertNil(parse("freeq://other?text=hi"))
    }

    func testTextOnly() {
        XCTAssertEqual(parse("freeq://share?text=hello%20world"),
                       .init(body: "hello world", target: nil))
    }

    func testLinkOnly() {
        XCTAssertEqual(parse("freeq://share?url=https%3A%2F%2Fexample.com"),
                       .init(body: "https://example.com", target: nil))
    }

    func testTextAndLinkCombine() {
        let p = parse("freeq://share?text=look&url=https%3A%2F%2Fx.com")
        XCTAssertEqual(p, .init(body: "look https://x.com", target: nil))
    }

    func testChannelTarget() {
        XCTAssertEqual(parse("freeq://share?text=hi&channel=%23dev"),
                       .init(body: "hi", target: "#dev"))
    }

    func testEmptyBodyIsNil() {
        XCTAssertNil(parse("freeq://share?channel=%23dev"))
        XCTAssertNil(parse("freeq://share?text=&url="))
    }

    func testRoundTripThroughMake() {
        let url = ShareURL.make(text: "a & b", link: "https://x.com/?q=1", channel: "#c")!
        XCTAssertEqual(ShareURL.parse(url), .init(body: "a & b https://x.com/?q=1", target: "#c"))
    }

    func testMakeNilWhenEmpty() {
        XCTAssertNil(ShareURL.make(text: nil, link: nil, channel: "#c"))
        XCTAssertNil(ShareURL.make(text: "", link: "", channel: nil))
    }
}
