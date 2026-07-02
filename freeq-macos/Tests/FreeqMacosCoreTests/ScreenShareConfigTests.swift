import XCTest
@testable import FreeqMacosCore

/// Tests for screen-share output sizing: fit the source (display or window,
/// in real pixels) into the encoder ceiling, preserve aspect, never upscale,
/// and keep dimensions even (H.264 requires it).
final class ScreenShareConfigTests: XCTestCase {

    func testSmallSourcePassesThroughUnscaled() {
        let d = ScreenShareConfig.outputSize(sourceWidth: 1280, sourceHeight: 720)
        XCTAssertEqual(d.width, 1280)
        XCTAssertEqual(d.height, 720)
    }

    func testRetina5KScalesToCeilingPreservingAspect() {
        // 5120×2880 is 16:9 → exactly the 1920×1080 ceiling.
        let d = ScreenShareConfig.outputSize(sourceWidth: 5120, sourceHeight: 2880)
        XCTAssertEqual(d.width, 1920)
        XCTAssertEqual(d.height, 1080)
    }

    func testUltrawidePreservesAspect() {
        // 3440×1440 (21.5:9) → width-bound: 1920×803.7 → even-rounded 1920×804.
        let d = ScreenShareConfig.outputSize(sourceWidth: 3440, sourceHeight: 1440)
        XCTAssertEqual(d.width, 1920)
        XCTAssertEqual(d.height, 804)
        XCTAssertEqual(d.height % 2, 0)
    }

    func testPortraitSourceIsHeightBound() {
        // A rotated 1440×2560 display → height-bound: 1080 tall, 607.5→608 wide.
        let d = ScreenShareConfig.outputSize(sourceWidth: 1440, sourceHeight: 2560)
        XCTAssertEqual(d.height, 1080)
        XCTAssertEqual(d.width, 608)
    }

    func testOddSourceDimensionsRoundToEven() {
        let d = ScreenShareConfig.outputSize(sourceWidth: 1279, sourceHeight: 719)
        XCTAssertEqual(d.width % 2, 0)
        XCTAssertEqual(d.height % 2, 0)
        XCTAssertLessThanOrEqual(d.width, 1280)
        XCTAssertLessThanOrEqual(d.height, 720)
    }

    func testTinyWindowNeverCollapsesBelowMinimum() {
        let d = ScreenShareConfig.outputSize(sourceWidth: 1, sourceHeight: 1)
        XCTAssertGreaterThanOrEqual(d.width, 2)
        XCTAssertGreaterThanOrEqual(d.height, 2)
    }

    func testNeverUpscales() {
        let d = ScreenShareConfig.outputSize(sourceWidth: 640, sourceHeight: 480)
        XCTAssertEqual(d.width, 640)
        XCTAssertEqual(d.height, 480)
    }

    func testFrameRateIs30() {
        XCTAssertEqual(ScreenShareConfig.framesPerSecond, 30)
    }
}
