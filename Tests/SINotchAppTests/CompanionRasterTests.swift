import XCTest
import SINotchCore
@testable import SINotch

final class CompanionRasterTests: XCTestCase {
    @MainActor
    func testRasterPreservesPixelCoordinatesTransparencyAndPalette() throws {
        var sprite = PixelCompanion(dimension: 3)
        sprite.stamp("#E.\n.T.\n..K", x: 0, y: 0)
        let image = try XCTUnwrap(CompanionRaster.image(sprite: sprite, pose: .target(.working)))
        XCTAssertEqual(image.width, 3); XCTAssertEqual(image.height, 3)
        let data = try XCTUnwrap(image.dataProvider?.data) as Data
        func pixel(_ x: Int, _ y: Int) -> [UInt8] {
            Array(data[((y * 3 + x) * 4)..<((y * 3 + x + 1) * 4)])
        }
        XCTAssertEqual(pixel(0, 0), [133, 233, 165, 255])
        XCTAssertEqual(pixel(1, 0), [9, 15, 14, 255])
        XCTAssertEqual(pixel(2, 0), [0, 0, 0, 0])
        XCTAssertEqual(pixel(1, 1), [250, 250, 240, 255])
        XCTAssertEqual(pixel(2, 2), [41, 48, 56, 255])
    }

    @MainActor
    func testRepeatedFramesReuseImageAndColorChangesRemainDistinct() throws {
        let sprite = PixelCompanion.frame(style: .cat, status: .working, time: 1)
        let image = try XCTUnwrap(CompanionRaster.image(sprite: sprite, pose: .target(.working)))
        XCTAssertTrue(image === CompanionRaster.image(sprite: sprite, pose: .target(.working)))
        let changed = try XCTUnwrap(CompanionRaster.image(sprite: sprite, pose: .target(.waiting)))
        XCTAssertNotEqual(image.dataProvider?.data, changed.dataProvider?.data)
        let next = PixelCompanion.frame(style: .cat, status: .working, time: 1.2)
        XCTAssertNotEqual(CompanionRaster.image(sprite: next, pose: .target(.working))?.dataProvider?.data,
                          image.dataProvider?.data)
    }

    @MainActor
    func testEnlargedFramesUseExactPixelBlocksWithoutInterpolation() throws {
        var sprite = PixelCompanion(dimension: 2)
        sprite.stamp("#E\n.T", x: 0, y: 0)
        let base = try XCTUnwrap(CompanionRaster.image(sprite: sprite, pose: .target(.idle)))
        let source = try XCTUnwrap(base.dataProvider?.data) as Data
        for scale in [2, 3, 4] {
            let image = try XCTUnwrap(CompanionRaster.image(sprite: sprite, pose: .target(.idle), pixelsPerCell: scale))
            let data = try XCTUnwrap(image.dataProvider?.data) as Data
            XCTAssertEqual(image.width, 2 * scale)
            for y in 0..<image.height {
                for x in 0..<image.width {
                    let from = (y / scale * 2 + x / scale) * 4
                    let to = (y * image.width + x) * 4
                    XCTAssertEqual(data[to..<to + 4], source[from..<from + 4])
                }
            }
        }
    }
}
