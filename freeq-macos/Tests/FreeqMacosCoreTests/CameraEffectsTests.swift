import XCTest
@testable import FreeqMacosCore

/// Tests for the pure parts of camera background effects: the persisted
/// effect setting's encoding, and the aspect-fill geometry used to composite
/// a custom background image behind the segmented person.
final class CameraEffectsTests: XCTestCase {

    // MARK: - VideoBackgroundEffect encoding (UserDefaults round-trip)

    func testEncodeDecodeNone() {
        XCTAssertEqual(VideoBackgroundEffect.none.encoded, "none")
        XCTAssertEqual(VideoBackgroundEffect(encoded: "none"), .none)
    }

    func testEncodeDecodeBlur() {
        XCTAssertEqual(VideoBackgroundEffect.blur.encoded, "blur")
        XCTAssertEqual(VideoBackgroundEffect(encoded: "blur"), .blur)
    }

    func testEncodeDecodeImage() {
        let url = URL(fileURLWithPath: "/tmp/bg.jpg")
        let effect = VideoBackgroundEffect.image(url)
        XCTAssertEqual(effect.encoded, "image:/tmp/bg.jpg")
        XCTAssertEqual(VideoBackgroundEffect(encoded: "image:/tmp/bg.jpg"), effect)
    }

    func testImagePathWithColonSurvivesRoundTrip() {
        let url = URL(fileURLWithPath: "/tmp/we:ird/bg.jpg")
        let effect = VideoBackgroundEffect.image(url)
        XCTAssertEqual(VideoBackgroundEffect(encoded: effect.encoded), effect)
    }

    func testGarbageDecodesToNone() {
        XCTAssertEqual(VideoBackgroundEffect(encoded: "sparkles"), .none)
        XCTAssertEqual(VideoBackgroundEffect(encoded: ""), .none)
        XCTAssertEqual(VideoBackgroundEffect(encoded: "image:"), .none)
    }

    func testIsActiveFlag() {
        XCTAssertFalse(VideoBackgroundEffect.none.isActive)
        XCTAssertTrue(VideoBackgroundEffect.blur.isActive)
        XCTAssertTrue(VideoBackgroundEffect.image(URL(fileURLWithPath: "/x")).isActive)
    }

    // MARK: - Aspect-fill geometry

    func testExactMatchIsIdentity() {
        let r = BackgroundImageFit.fillRect(
            imageSize: CGSize(width: 1280, height: 720),
            frameSize: CGSize(width: 1280, height: 720))
        XCTAssertEqual(r, CGRect(x: 0, y: 0, width: 1280, height: 720))
    }

    func testWideImageIntoTallerFrameCropsSides() {
        // 4000×1000 into 1280×720: height-bound → scale 0.72, width 2880,
        // centered → x = (1280 − 2880)/2 = −800.
        let r = BackgroundImageFit.fillRect(
            imageSize: CGSize(width: 4000, height: 1000),
            frameSize: CGSize(width: 1280, height: 720))
        XCTAssertEqual(r.height, 720, accuracy: 0.01)
        XCTAssertEqual(r.width, 2880, accuracy: 0.01)
        XCTAssertEqual(r.origin.x, -800, accuracy: 0.01)
        XCTAssertEqual(r.origin.y, 0, accuracy: 0.01)
    }

    func testPortraitImageIntoLandscapeFrameCropsTopBottom() {
        // 1000×2000 into 1280×720: width-bound → scale 1.28, height 2560,
        // centered → y = (720 − 2560)/2 = −920.
        let r = BackgroundImageFit.fillRect(
            imageSize: CGSize(width: 1000, height: 2000),
            frameSize: CGSize(width: 1280, height: 720))
        XCTAssertEqual(r.width, 1280, accuracy: 0.01)
        XCTAssertEqual(r.height, 2560, accuracy: 0.01)
        XCTAssertEqual(r.origin.y, -920, accuracy: 0.01)
        XCTAssertEqual(r.origin.x, 0, accuracy: 0.01)
    }

    func testFillAlwaysCoversFrame() {
        let sizes = [CGSize(width: 333, height: 777), CGSize(width: 5000, height: 100),
                     CGSize(width: 720, height: 720)]
        let frame = CGSize(width: 1280, height: 720)
        for s in sizes {
            let r = BackgroundImageFit.fillRect(imageSize: s, frameSize: frame)
            XCTAssertLessThanOrEqual(r.minX, 0.01)
            XCTAssertLessThanOrEqual(r.minY, 0.01)
            XCTAssertGreaterThanOrEqual(r.maxX, frame.width - 0.01)
            XCTAssertGreaterThanOrEqual(r.maxY, frame.height - 0.01)
        }
    }

    func testDegenerateImageSizeReturnsFrameRect() {
        let r = BackgroundImageFit.fillRect(
            imageSize: .zero, frameSize: CGSize(width: 1280, height: 720))
        XCTAssertEqual(r, CGRect(x: 0, y: 0, width: 1280, height: 720))
    }
}
