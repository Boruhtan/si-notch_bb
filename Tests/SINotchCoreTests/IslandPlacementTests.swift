import XCTest
@testable import SINotchCore

final class IslandPlacementTests: XCTestCase {
    func testExternalCapsuleReservesMenuAndKeepsRightAnchorWhenExpanded() {
        for origin in [CGPoint(x: 1512, y: -98), CGPoint(x: -1920, y: 982)] {
            let screen = CGRect(origin: origin, size: CGSize(width: 1920, height: 1080))
            let placement = IslandPlacement(geometry: NotchGeometry(screenFrame: screen),
                                            belowMenu: false, menuBarHeight: 24)
            let compact = placement.compactFrame(leftWidth: 26, rightWidth: 18)
            let expanded = placement.expandedFrame(width: 680, height: 560)
            XCTAssertTrue(placement.isFloating)
            XCTAssertTrue(placement.isTrailing)
            XCTAssertEqual(placement.cameraWidth, 0)
            XCTAssertEqual(compact.size, CGSize(width: 64, height: 30))
            XCTAssertEqual(compact.maxX, screen.maxX - 12)
            XCTAssertEqual(compact.maxY, screen.maxY - 32)
            XCTAssertEqual(expanded.maxX, compact.maxX)
            XCTAssertEqual(expanded.maxY, compact.maxY)
            XCTAssertTrue(screen.contains(expanded))
            let reveal = placement.fullScreenRevealFrame(leftWidth: 26, rightWidth: 18)
            XCTAssertEqual(reveal.minX, compact.minX)
            XCTAssertEqual(reveal.maxY, screen.maxY)
            XCTAssertEqual(reveal.height, 3)
        }
    }

    func testPhysicalNotchKeepsExactExistingGeometry() {
        let geometry = NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                     topInset: 32, auxiliaryLeftWidth: 663.5, auxiliaryRightWidth: 663.5,
                                     backingScaleFactor: 2)
        let placement = IslandPlacement(geometry: geometry, belowMenu: false, menuBarHeight: 32)
        XCTAssertFalse(placement.isFloating)
        XCTAssertFalse(placement.isTrailing)
        XCTAssertEqual(placement.cameraWidth, 185)
        XCTAssertEqual(placement.compactFrame(leftWidth: 26, rightWidth: 18),
                       geometry.coveringTopEdge(geometry.compactFrame(leftWingWidth: 29, rightWingWidth: 21, minimumHeight: 33)))
        XCTAssertEqual(placement.expandedFrame(width: 680, height: 560),
                       geometry.coveringTopEdge(geometry.expandedFrame(width: 680, height: 560)))
        let below = IslandPlacement(geometry: geometry, belowMenu: true, menuBarHeight: 32)
        XCTAssertTrue(below.isFloating)
        XCTAssertEqual(below.cameraWidth, 0, "A detached surface must not reserve an empty camera gap")
        XCTAssertEqual(below.compactFrame(leftWidth: 26, rightWidth: 18).midX, 756)
        XCTAssertEqual(below.compactFrame(leftWidth: 26, rightWidth: 18).maxY, 942)
    }
}
