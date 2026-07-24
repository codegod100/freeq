import Foundation
import CoreGraphics

/// Screen-share output sizing: fit the source (in real pixels) into the
/// encoder ceiling (1920×1080 — the SDK encodes a 720p H.264 track, so
/// anything above the ceiling is wasted capture bandwidth), preserving
/// aspect, never upscaling, and rounding to even (H.264 chroma subsampling).
enum ScreenShareConfig {
    static let maxWidth = 1920
    static let maxHeight = 1080
    static let framesPerSecond = 30

    static func outputSize(sourceWidth: Int, sourceHeight: Int) -> (width: Int, height: Int) {
        let w = max(1, sourceWidth)
        let h = max(1, sourceHeight)
        let scale = min(1.0, min(Double(maxWidth) / Double(w), Double(maxHeight) / Double(h)))
        let outW = max(2, Int((Double(w) * scale).rounded() / 2) * 2)
        let outH = max(2, Int((Double(h) * scale).rounded() / 2) * 2)
        return (outW, outH)
    }
}

/// Expanded-call grid math: the column count that maximizes 16:9 tile area
/// for `count` tiles in `container`.
enum CallGridLayout {
    static let tileAspect: CGFloat = 16.0 / 9.0

    static func columns(for count: Int, in container: CGSize) -> Int {
        guard count > 1 else { return 1 }
        let width = max(container.width, 1)
        let height = max(container.height, 1)

        var bestCols = 1
        var bestArea: CGFloat = 0
        for cols in 1...count {
            let rows = Int(ceil(Double(count) / Double(cols)))
            // Tile size bounded by both the column width and the row height.
            let tileW = min(width / CGFloat(cols), (height / CGFloat(rows)) * tileAspect)
            let tileH = tileW / tileAspect
            let area = tileW * tileH
            // >= : on equal tile area prefer more columns — video grids read
            // better wide than tall (2 tiles side-by-side, not stacked).
            if area >= bestArea {
                bestArea = area
                bestCols = cols
            }
        }
        return bestCols
    }

    /// The exact 16:9 tile size that fits `count` tiles into `container` at the
    /// optimal column count, bounded by BOTH the column width AND the row
    /// height (minus inter-tile `spacing`). This is the piece that makes the
    /// gallery behave like Meet/Zoom: every tile is fully visible with no
    /// scrolling or clipping, because the tile is never taller than the rows
    /// allow. Returns `.zero` for an empty/degenerate container.
    static func tileSize(for count: Int, in container: CGSize, spacing: CGFloat = 8) -> CGSize {
        guard count > 0, container.width > 0, container.height > 0 else { return .zero }
        let cols = max(1, columns(for: count, in: container))
        let rows = Int(ceil(Double(count) / Double(cols)))
        // Space left for tiles after the gaps between them.
        let availW = max(1, container.width - spacing * CGFloat(max(0, cols - 1)))
        let availH = max(1, container.height - spacing * CGFloat(max(0, rows - 1)))
        // Width is capped by the columns; height is capped by the rows
        // (converted to an equivalent width via the aspect ratio). The min
        // guarantees the tile fits both axes.
        let tileW = min(availW / CGFloat(cols), (availH / CGFloat(rows)) * tileAspect)
        let w = max(1, tileW)
        return CGSize(width: w, height: w / tileAspect)
    }
}
