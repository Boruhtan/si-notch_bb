import Foundation
import CoreGraphics
import XCTest
@testable import SINotchCore

final class NotchGeometryTests: XCTestCase {
    func testCompactStatusWingDoesNotGrowWithTitleOrCrossMenuClearance() {
        let geometry = NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                     topInset: 32, auxiliaryLeftWidth: 663.5, auxiliaryRightWidth: 663.5,
                                     backingScaleFactor: 2)
        for left in [29.0, 135.0] {
            let frame = geometry.coveringTopEdge(geometry.compactFrame(leftWingWidth: left, rightWingWidth: 21))
            XCTAssertEqual(frame.maxX, 870)
            XCTAssertEqual(frame.maxY, 983)
            XCTAssertEqual(frame.minX + left + 0.5, geometry.auxiliaryTopLeftArea!.maxX)
            XCTAssertEqual(geometry.coveringTopEdge(geometry.compactFrame(wingWidth: 29)).maxX - frame.maxX, 8,
                           "Return 8 pt to the menu bar; a long title does not widen the status wing")
        }
    }

    func testAttachedSurfaceUsesIntegralBoundsAndCoversTheTopEdge() {
        for scale in [1.0, 2.0] {
            let geometry = NotchGeometry(screenFrame: CGRect(x: -1512, y: -982, width: 1512, height: 982), backingScaleFactor: scale)
            for frame in [geometry.compactFrame(), geometry.expandedFrame()] {
                let attached = geometry.coveringTopEdge(frame)
                XCTAssertEqual(attached.maxY, geometry.screenFrame.maxY + 1)
                XCTAssertEqual(attached.minY, frame.minY)
                XCTAssertEqual(attached.minX, frame.minX)
                XCTAssertEqual(attached.width, frame.width)
            }
            let detached = geometry.expandedFrame(topOffset: 40)
            XCTAssertEqual(geometry.coveringTopEdge(detached), detached)
            let halfPoint = geometry.frame(width: 243, height: 33)
            let attached = geometry.coveringTopEdge(halfPoint)
            XCTAssertEqual(attached.origin.x.rounded(), attached.origin.x)
            XCTAssertEqual(attached.size.width.rounded(), attached.size.width)
            XCTAssertTrue(attached.contains(halfPoint))
        }
    }

    func testMeasuredMacBookCutoutUsesPointAreasAndNativeTopAnchor() {
        let geometry = NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                     topInset: 32,
                                     auxiliaryTopLeftArea: CGRect(x: 0, y: 950, width: 663.5, height: 32),
                                     auxiliaryTopRightArea: CGRect(x: 848.5, y: 950, width: 663.5, height: 32),
                                     backingScaleFactor: 2)
        XCTAssertTrue(geometry.hasNotch)
        XCTAssertEqual(geometry.notchWidth, 185)
        XCTAssertEqual(geometry.centerX, 756)
        XCTAssertEqual(geometry.compactFrame(wingWidth: 36), CGRect(x: 627.5, y: 950, width: 257, height: 32))
        XCTAssertEqual(geometry.compactFrame(wingWidth: 36, topOffset: 40).maxY, 942)
    }

    func testNotchedDisplayCentersOnPhysicalCutout() {
        let geometry = NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                     topInset: 32, auxiliaryLeftWidth: 650, auxiliaryRightWidth: 670)
        XCTAssertTrue(geometry.hasNotch)
        XCTAssertEqual(geometry.notchWidth, 192)
        XCTAssertEqual(geometry.centerX, 746)
        XCTAssertEqual(geometry.compactFrame(width: 150, height: 20), CGRect(x: 650, y: 950, width: 192, height: 32))
    }

    func testExternalDisplayWithoutNotchUsesScreenCenter() {
        let geometry = NotchGeometry(screenFrame: CGRect(x: 1512, y: 100, width: 1920, height: 1080))
        XCTAssertFalse(geometry.hasNotch)
        XCTAssertEqual(geometry.compactFrame(), CGRect(x: 2352, y: 1142, width: 240, height: 38))
        XCTAssertEqual(geometry.compactFrame(wingWidth: 36), CGRect(x: 2436, y: 1148, width: 72, height: 32))
    }

    func testAsymmetricAuxiliaryAreasCenterOnGapAcrossNegativeScreenOrigin() {
        let geometry = NotchGeometry(screenFrame: CGRect(x: -1600, y: 100, width: 1500, height: 900),
                                     topInset: 32,
                                     auxiliaryTopLeftArea: CGRect(x: -1600, y: 968, width: 600, height: 32),
                                     auxiliaryTopRightArea: CGRect(x: -810, y: 968, width: 710, height: 32),
                                     backingScaleFactor: 2)
        XCTAssertTrue(geometry.hasNotch)
        XCTAssertEqual(geometry.notchWidth, 190)
        XCTAssertEqual(geometry.centerX, -905)
        XCTAssertEqual(geometry.compactFrame(wingWidth: 36), CGRect(x: -1036, y: 968, width: 262, height: 32))
    }

    func testIncompleteOrMisplacedAuxiliaryAreasDoNotInventNotch() {
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
        let left = CGRect(x: 0, y: 668, width: 400, height: 32)
        XCTAssertFalse(NotchGeometry(screenFrame: frame, topInset: 32,
                                     auxiliaryTopLeftArea: left, auxiliaryTopRightArea: nil).hasNotch)
        XCTAssertFalse(NotchGeometry(screenFrame: frame, topInset: 32,
                                     auxiliaryTopLeftArea: left,
                                     auxiliaryTopRightArea: CGRect(x: 600, y: 620, width: 400, height: 32)).hasNotch)
    }

    func testBackingScaleSnapsCompactEdgesToPixels() {
        let geometry = NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                     topInset: 32,
                                     auxiliaryTopLeftArea: CGRect(x: 0, y: 950, width: 663.5, height: 32),
                                     auxiliaryTopRightArea: CGRect(x: 848.5, y: 950, width: 663.5, height: 32),
                                     backingScaleFactor: 2)
        let frame = geometry.compactFrame(wingWidth: 35.25)
        XCTAssertEqual(frame.width * 2, (frame.width * 2).rounded())
        XCTAssertEqual(frame.minX * 2, (frame.minX * 2).rounded())
        XCTAssertEqual(frame.maxY, geometry.screenFrame.maxY)
    }

    func testNegativeOriginsAndVerticalMonitorArrangement() {
        let geometry = NotchGeometry(screenFrame: CGRect(x: -1920, y: -1080, width: 1920, height: 1080))
        XCTAssertEqual(geometry.expandedFrame(), CGRect(x: -1190, y: -320, width: 460, height: 320))
        XCTAssertEqual(geometry.expandedFrame(width: 3000, height: 3000), geometry.screenFrame)
        XCTAssertEqual(geometry.frame(width: 200, height: 100, topOffset: 2000).minY, -1080)
    }

    func testInvalidGeometryProducesFiniteClampedFrames() {
        let geometry = NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1000, height: 700),
                                     topInset: .infinity, auxiliaryLeftWidth: -5, auxiliaryRightWidth: 1200)
        XCTAssertFalse(geometry.hasNotch)
        XCTAssertEqual(geometry.frame(width: -.infinity, height: -20), CGRect(x: 500, y: 700, width: 0, height: 0))
        XCTAssertEqual(NotchGeometry(screenFrame: .null).expandedFrame(), .zero)
    }
}
