import XCTest
@testable import FreeqMacosCore

/// Tests for the expanded-call grid math: pick the column count that
/// maximizes tile area for N participants in a container, assuming 16:9
/// tiles. (The old UI stacked everyone in a VStack — unusable past ~3.)
final class CallGridLayoutTests: XCTestCase {

    private let wide = CGSize(width: 1600, height: 900)

    func testZeroTilesIsOneColumn() {
        XCTAssertEqual(CallGridLayout.columns(for: 0, in: wide), 1)
    }

    func testOneTileFillsContainer() {
        XCTAssertEqual(CallGridLayout.columns(for: 1, in: wide), 1)
    }

    func testTwoTilesSideBySideInLandscape() {
        XCTAssertEqual(CallGridLayout.columns(for: 2, in: wide), 2)
    }

    func testFourTilesTwoByTwo() {
        XCTAssertEqual(CallGridLayout.columns(for: 4, in: wide), 2)
    }

    func testNineTilesThreeByThree() {
        XCTAssertEqual(CallGridLayout.columns(for: 9, in: wide), 3)
    }

    func testTwelveTilesFourColumns() {
        XCTAssertEqual(CallGridLayout.columns(for: 12, in: wide), 4)
    }

    func testTallContainerPrefersFewerColumns() {
        let tall = CGSize(width: 500, height: 1200)
        XCTAssertLessThanOrEqual(
            CallGridLayout.columns(for: 4, in: tall),
            CallGridLayout.columns(for: 4, in: wide)
        )
    }

    func testColumnsNeverExceedTileCount() {
        for n in 1...20 {
            XCTAssertLessThanOrEqual(CallGridLayout.columns(for: n, in: wide), n)
        }
    }

    func testMoreTilesNeverFewerColumnsInSameContainer() {
        var prev = 1
        for n in 1...30 {
            let c = CallGridLayout.columns(for: n, in: wide)
            XCTAssertGreaterThanOrEqual(c, prev, "columns must grow monotonically with tile count")
            prev = c
        }
    }

    func testDegenerateContainerDoesNotCrash() {
        // Exact column choice is unspecified for a zero/negative container —
        // the invariant is: valid range, no crash, no divide-by-zero.
        let zero = CallGridLayout.columns(for: 4, in: .zero)
        XCTAssertTrue((1...4).contains(zero))
        let negative = CallGridLayout.columns(for: 4, in: CGSize(width: -10, height: 5))
        XCTAssertTrue((1...4).contains(negative))
    }

    // MARK: - tileSize: the fit-to-space gallery invariant

    /// The core promise: for any tile count, the whole grid (tiles + gaps)
    /// fits inside the container on BOTH axes. This is what the old
    /// width-only LazyVGrid violated (rows overflowed and got clipped).
    func testTileGridAlwaysFitsContainer() {
        let spacing: CGFloat = 8
        for n in 1...30 {
            let size = CallGridLayout.tileSize(for: n, in: wide, spacing: spacing)
            let cols = CallGridLayout.columns(for: n, in: wide)
            let rows = Int(ceil(Double(n) / Double(cols)))
            let usedW = size.width * CGFloat(cols) + spacing * CGFloat(cols - 1)
            let usedH = size.height * CGFloat(rows) + spacing * CGFloat(rows - 1)
            XCTAssertLessThanOrEqual(usedW, wide.width + 0.5, "row of \(n) overflows width")
            XCTAssertLessThanOrEqual(usedH, wide.height + 0.5, "\(n) tiles overflow height")
        }
    }

    func testTileSizeKeeps16by9() {
        for n in [1, 2, 3, 5, 7, 12, 20] {
            let size = CallGridLayout.tileSize(for: n, in: wide)
            XCTAssertEqual(size.width / size.height, CallGridLayout.tileAspect, accuracy: 0.001)
        }
    }

    func testMoreTilesNeverLargerTiles() {
        var prev = CGFloat.greatestFiniteMagnitude
        for n in 1...30 {
            let w = CallGridLayout.tileSize(for: n, in: wide).width
            XCTAssertLessThanOrEqual(w, prev + 0.5, "tiles must not grow as count grows")
            prev = w
        }
    }

    func testTileSizeDegenerateContainerIsZero() {
        XCTAssertEqual(CallGridLayout.tileSize(for: 4, in: .zero), .zero)
        XCTAssertEqual(CallGridLayout.tileSize(for: 0, in: wide), .zero)
        XCTAssertEqual(CallGridLayout.tileSize(for: 4, in: CGSize(width: -10, height: 5)), .zero)
    }
}
