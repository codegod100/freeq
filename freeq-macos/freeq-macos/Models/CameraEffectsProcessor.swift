import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Foundation
import Vision

/// Person-segmentation background effects for the outbound camera feed —
/// blur or a custom image behind you, like every incumbent conferencing app.
///
/// Pipeline (runs on the camera capture queue, per frame):
///   BGRA CVPixelBuffer → VNGeneratePersonSegmentationRequest (.balanced)
///   → CIBlendWithMask(person, styled background, mask) → pooled BGRA buffer.
///
/// `.balanced` quality tracks 720p30 comfortably on Apple Silicon; the
/// geometry policy (`BackgroundImageFit`) and the setting encoding
/// (`VideoBackgroundEffect`) are pure and unit-tested.
final class CameraEffectsProcessor {
    var effect: VideoBackgroundEffect = .none {
        didSet {
            if case .image(let url) = effect {
                backgroundImage = CIImage(contentsOf: url)
                if backgroundImage == nil {
                    print("[effects] could not load background image at \(url.path)")
                }
            } else {
                backgroundImage = nil
            }
        }
    }

    private let context = CIContext(options: [.cacheIntermediates: false])
    private let request: VNGeneratePersonSegmentationRequest = {
        let r = VNGeneratePersonSegmentationRequest()
        r.qualityLevel = .balanced
        r.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return r
    }()
    private var backgroundImage: CIImage?
    private var pool: CVPixelBufferPool?
    private var poolSize: (Int, Int) = (0, 0)

    /// Process one camera frame. Returns the composited buffer, or nil when
    /// the effect is off / segmentation found no person mask (caller sends
    /// the original frame).
    func process(_ frame: CVPixelBuffer) -> CVPixelBuffer? {
        guard effect.isActive else { return nil }

        let handler = VNImageRequestHandler(cvPixelBuffer: frame, options: [:])
        guard (try? handler.perform([request])) != nil,
              let maskBuffer = request.results?.first?.pixelBuffer else {
            return nil
        }

        let person = CIImage(cvPixelBuffer: frame)
        let extent = person.extent

        // Scale the (low-res) mask up to frame size.
        var mask = CIImage(cvPixelBuffer: maskBuffer)
        mask = mask.transformed(by: CGAffineTransform(
            scaleX: extent.width / mask.extent.width,
            y: extent.height / mask.extent.height))

        let background: CIImage
        switch effect {
        case .blur:
            // Clamp → blur → crop keeps edges from fading to transparent.
            background = person
                .clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 18])
                .cropped(to: extent)
        case .image:
            guard let bg = backgroundImage else { return nil }
            let rect = BackgroundImageFit.fillRect(
                imageSize: bg.extent.size, frameSize: extent.size)
            let scale = rect.width / bg.extent.width
            background = bg
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale)
                    .concatenating(CGAffineTransform(translationX: rect.origin.x, y: rect.origin.y)))
                .cropped(to: extent)
        case .none:
            return nil
        }

        let blend = CIFilter.blendWithMask()
        blend.inputImage = person
        blend.backgroundImage = background
        blend.maskImage = mask
        guard let output = blend.outputImage else { return nil }

        guard let outBuffer = makeBuffer(width: Int(extent.width), height: Int(extent.height)) else {
            return nil
        }
        context.render(output, to: outBuffer)
        return outBuffer
    }

    private func makeBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        if pool == nil || poolSize != (width, height) {
            let attrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:],
            ]
            var newPool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(
                kCFAllocatorDefault,
                [kCVPixelBufferPoolMinimumBufferCountKey: 3] as CFDictionary,
                attrs as CFDictionary, &newPool)
            pool = newPool
            poolSize = (width, height)
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        return buffer
    }
}
