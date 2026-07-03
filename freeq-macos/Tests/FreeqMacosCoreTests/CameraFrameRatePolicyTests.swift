import CoreMedia
import XCTest
@testable import FreeqMacosCore

final class CameraFrameRatePolicyTests: XCTestCase {
    private func duration(_ value: Int64, _ timescale: Int32) -> CMTime {
        CMTime(value: CMTimeValue(value), timescale: timescale)
    }

    func testDesiredRateInsideRangeIsUsed() {
        // 1–60fps range: durations from 1/60 (min) to 1/1 (max).
        let target = CameraFrameRatePolicy.targetMinFrameDuration(
            desiredFps: 30,
            ranges: [(min: duration(1, 60), max: duration(1, 1))])
        XCTAssertEqual(target, duration(1, 30))
    }

    func testFractionalNtscFixedRateClampsToRangeEdge() {
        // The crash case: fixed 29.97fps — the only valid duration is
        // 1001/30000. Desired 1/30 is outside; must clamp, never throw.
        let ntsc = duration(1001, 30000)
        let target = CameraFrameRatePolicy.targetMinFrameDuration(
            desiredFps: 30,
            ranges: [(min: ntsc, max: ntsc)])
        XCTAssertEqual(target, ntsc)
    }

    func testSlowCameraClampsToItsFastestRate() {
        // Camera maxes at 24fps: fastest allowed duration is 1/24.
        let target = CameraFrameRatePolicy.targetMinFrameDuration(
            desiredFps: 30,
            ranges: [(min: duration(1, 24), max: duration(1, 1))])
        XCTAssertEqual(target, duration(1, 24))
    }

    func testFixedFastCameraClampsToItsSlowestRate() {
        // Fixed 60fps camera: desired 1/30 is slower than allowed; the
        // slowest valid duration is 1/60.
        let fixed60 = duration(1, 60)
        let target = CameraFrameRatePolicy.targetMinFrameDuration(
            desiredFps: 30,
            ranges: [(min: fixed60, max: fixed60)])
        XCTAssertEqual(target, fixed60)
    }

    func testSecondRangeCanSatisfyDesiredRate() {
        let target = CameraFrameRatePolicy.targetMinFrameDuration(
            desiredFps: 30,
            ranges: [
                (min: duration(1, 60), max: duration(1, 60)),  // fixed 60
                (min: duration(1, 30), max: duration(1, 15)),  // 15–30fps
            ])
        XCTAssertEqual(target, duration(1, 30))
    }

    func testNoRangesReturnsNil() {
        XCTAssertNil(CameraFrameRatePolicy.targetMinFrameDuration(desiredFps: 30, ranges: []))
    }

    func testNonPositiveFpsReturnsNil() {
        XCTAssertNil(CameraFrameRatePolicy.targetMinFrameDuration(
            desiredFps: 0,
            ranges: [(min: duration(1, 60), max: duration(1, 1))]))
    }
}
