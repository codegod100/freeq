import Foundation

/// The user's camera background effect. Persisted as a single string
/// (`freeq.av.bgEffect`) so it round-trips through UserDefaults.
enum VideoBackgroundEffect: Equatable {
    case none
    case blur
    case image(URL)

    /// Anything that requires running the segmentation pipeline.
    var isActive: Bool { self != .none }

    var encoded: String {
        switch self {
        case .none: return "none"
        case .blur: return "blur"
        case .image(let url): return "image:" + url.path
        }
    }

    init(encoded: String) {
        switch encoded {
        case "blur":
            self = .blur
        case let s where s.hasPrefix("image:"):
            let path = String(s.dropFirst("image:".count))
            self = path.isEmpty ? .none : .image(URL(fileURLWithPath: path))
        default:
            self = .none
        }
    }
}

/// Aspect-fill geometry for compositing a custom background image behind the
/// segmented person: scale to cover the frame, centered, cropping overflow.
enum BackgroundImageFit {
    static func fillRect(imageSize: CGSize, frameSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              frameSize.width > 0, frameSize.height > 0 else {
            return CGRect(origin: .zero, size: frameSize)
        }
        let scale = max(frameSize.width / imageSize.width,
                        frameSize.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (frameSize.width - size.width) / 2,
            y: (frameSize.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }
}
