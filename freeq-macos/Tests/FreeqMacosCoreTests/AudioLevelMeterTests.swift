import XCTest
@testable import FreeqMacosCore

/// Tests for the mic level meter + speaking detector: pure math over PCM
/// buffers (RMS → dBFS → normalized level) with attack/release hysteresis so
/// the speaking indicator doesn't flicker at the threshold.
final class AudioLevelMeterTests: XCTestCase {

    private func frames(_ amplitude: Float, count: Int = 480) -> [Float] {
        [Float](repeating: amplitude, count: count)
    }

    // MARK: - Level math

    func testSilenceIsFloorDb() {
        var meter = AudioLevelMeter()
        let u = meter.process(samples: frames(0), at: 0)
        XCTAssertEqual(u.db, AudioLevelMeter.floorDb)
        XCTAssertEqual(u.level, 0, accuracy: 0.001)
        XCTAssertFalse(u.isSpeaking)
    }

    func testFullScaleIsZeroDb() {
        var meter = AudioLevelMeter()
        let u = meter.process(samples: frames(1.0), at: 0)
        XCTAssertEqual(u.db, 0, accuracy: 0.01)
        XCTAssertEqual(u.level, 1, accuracy: 0.001)
    }

    func testHalfScaleIsMinusSixDb() {
        var meter = AudioLevelMeter()
        let u = meter.process(samples: frames(0.5), at: 0)
        XCTAssertEqual(u.db, -6.02, accuracy: 0.1)
    }

    func testSineRmsIsAmplitudeOverSqrt2() {
        var meter = AudioLevelMeter()
        let sine = (0..<4800).map { Float(sin(Double($0) / 4800 * 2 * .pi * 10)) }
        let u = meter.process(samples: sine, at: 0)
        XCTAssertEqual(u.db, -3.01, accuracy: 0.1)  // RMS of unit sine = 1/√2
    }

    func testEmptyBufferKeepsFloor() {
        var meter = AudioLevelMeter()
        let u = meter.process(samples: [], at: 0)
        XCTAssertEqual(u.db, AudioLevelMeter.floorDb)
        XCTAssertFalse(u.isSpeaking)
    }

    func testLevelIsClampedToUnitRange() {
        var meter = AudioLevelMeter()
        // Digital over: amplitude > 1.0 must not exceed level 1.
        let u = meter.process(samples: frames(2.0), at: 0)
        XCTAssertLessThanOrEqual(u.level, 1)
        // And deep quiet must not go below 0.
        let q = meter.process(samples: frames(0.000001), at: 0.01)
        XCTAssertGreaterThanOrEqual(q.level, 0)
    }

    // MARK: - Speaking detection (attack)

    func testSingleLoudBufferDoesNotTriggerSpeaking() {
        var meter = AudioLevelMeter()
        // One loud buffer could be a keyboard click — attack needs 2.
        let u = meter.process(samples: frames(0.5), at: 0)
        XCTAssertFalse(u.isSpeaking)
    }

    func testConsecutiveLoudBuffersTriggerSpeaking() {
        var meter = AudioLevelMeter()
        _ = meter.process(samples: frames(0.5), at: 0.00)
        let u = meter.process(samples: frames(0.5), at: 0.01)
        XCTAssertTrue(u.isSpeaking)
    }

    func testQuietBufferResetsAttack() {
        var meter = AudioLevelMeter()
        _ = meter.process(samples: frames(0.5), at: 0.00)
        _ = meter.process(samples: frames(0.0), at: 0.01)
        let u = meter.process(samples: frames(0.5), at: 0.02)
        XCTAssertFalse(u.isSpeaking, "attack counter must reset on quiet")
    }

    // MARK: - Speaking detection (release / hang time)

    func testSpeakingHoldsThroughShortPauses() {
        var meter = AudioLevelMeter()
        _ = meter.process(samples: frames(0.5), at: 0.00)
        _ = meter.process(samples: frames(0.5), at: 0.01)
        // Inter-word gap shorter than the release window.
        let u = meter.process(samples: frames(0.0), at: 0.3)
        XCTAssertTrue(u.isSpeaking, "must hang through inter-word silence")
    }

    func testSpeakingReleasesAfterHangTime() {
        var meter = AudioLevelMeter()
        _ = meter.process(samples: frames(0.5), at: 0.00)
        _ = meter.process(samples: frames(0.5), at: 0.01)
        let u = meter.process(samples: frames(0.0), at: 0.01 + AudioLevelMeter.releaseSeconds + 0.1)
        XCTAssertFalse(u.isSpeaking)
    }

    func testSpeechResumingDuringHangExtendsIt() {
        var meter = AudioLevelMeter()
        _ = meter.process(samples: frames(0.5), at: 0.00)
        _ = meter.process(samples: frames(0.5), at: 0.01)
        _ = meter.process(samples: frames(0.0), at: 0.4)   // pause
        _ = meter.process(samples: frames(0.5), at: 0.5)   // resume (already speaking: 1 buffer keeps it)
        let u = meter.process(samples: frames(0.0), at: 0.5 + AudioLevelMeter.releaseSeconds - 0.1)
        XCTAssertTrue(u.isSpeaking, "resumed speech must restart the release clock")
    }

    func testSubThresholdMurmurNeverTriggers() {
        var meter = AudioLevelMeter()
        // Just below the -45 dB threshold (0.003 ≈ -50 dB).
        for i in 0..<50 {
            let u = meter.process(samples: frames(0.003), at: Double(i) * 0.01)
            XCTAssertFalse(u.isSpeaking)
        }
    }
}
