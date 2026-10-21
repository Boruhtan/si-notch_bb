import XCTest
@testable import SINotch

final class IslandFrameMotionTests: XCTestCase {
    let compact = CGRect(x: 600, y: 967, width: 230, height: 33)
    let expanded = CGRect(x: 375, y: 650, width: 680, height: 350)

    func testExternalCapsuleKeepsRightAnchorDuringExpansionAndReversal() {
        let compact = CGRect(x: 1844, y: 1018, width: 64, height: 30)
        let expanded = CGRect(x: 1228, y: 488, width: 680, height: 560)
        let open = IslandFrameMotion(origin: compact, destination: expanded, transition: .expand)
        let reverse = IslandFrameMotion(origin: open.frame(at: 0.09), destination: compact,
            transition: .collapse, initialVelocity: open.velocity(at: 0.09))
        for motion in [open, reverse] {
            for step in 0...90 {
                let frame = motion.frame(at: Double(step) / 120)
                XCTAssertEqual(frame.maxX, compact.maxX, accuracy: 0.001)
                XCTAssertEqual(frame.maxY, compact.maxY, accuracy: 0.001)
            }
        }
    }

    func testFloatingHoverContourExcludesTransparentCorners() {
        let shape = IslandSilhouette(shoulder: 10, bottomRadius: 15, floating: true)
        let frame = CGRect(x: 100, y: 100, width: 64, height: 30)
        XCTAssertFalse(shape.contains(CGPoint(x: 101, y: 129), inScreenFrame: frame))
        XCTAssertFalse(shape.contains(CGPoint(x: 101, y: 101), inScreenFrame: frame))
        XCTAssertTrue(shape.contains(CGPoint(x: 132, y: 129), inScreenFrame: frame))
        XCTAssertTrue(shape.contains(CGPoint(x: 101, y: 115), inScreenFrame: frame))
    }

    @MainActor
    func testOpenOutlineAndContentDoNotReenterWhenAgentGroupChangesHeight() {
        // The remote group changes only height (221 ↔ 477 pt). Its shoulders,
        // droplet deformation and content opacity must remain fully expanded.
        for height in [221.0, 270, 350, 477, 350, 221] {
            XCTAssertEqual(IslandView.revealProgress(viewport: CGSize(width: 680, height: height),
                compactWidth: 236, expandedWidth: 680), 1)
        }
        let before = IslandView.revealProgress(viewport: CGSize(width: 458, height: 130),
            compactWidth: 236, expandedWidth: 680)
        let retargeted = IslandView.revealProgress(viewport: CGSize(width: 458, height: 300),
            compactWidth: 236, expandedWidth: 680)
        XCTAssertEqual(before, 0.5)
        XCTAssertEqual(retargeted, before, "A measured card height must not jump the outline halfway through opening")
    }

    func testDropOpensAsOneSurfaceWithoutReboundAndWithFixedTop() {
        let motion = IslandFrameMotion(origin: compact, destination: expanded, transition: .expand)
        XCTAssertEqual(motion.frame(at: 0), compact)
        XCTAssertGreaterThan(motion.frame(at: 0.14).height, expanded.height * 0.75)
        XCTAssertLessThan(motion.frame(at: 0.05).height, expanded.height * 0.65)
        var previous = compact.height
        for step in 0...120 {
            let frame = motion.frame(at: Double(step) / 120)
            XCTAssertEqual(frame.maxY, expanded.maxY, accuracy: 0.001)
            XCTAssertGreaterThanOrEqual(frame.height, previous)
            XCTAssertLessThanOrEqual(frame.height, expanded.height)
            let widthProgress = (frame.width - compact.width) / (expanded.width - compact.width)
            let heightProgress = (frame.height - compact.height) / (expanded.height - compact.height)
            XCTAssertEqual(widthProgress, heightProgress, accuracy: 0.0001)
            previous = frame.height
        }
        XCTAssertTrue(motion.isSettled(at: 0.7))
    }

    func testReversalPreservesPositionAndVelocityAndSettles() {
        let open = IslandFrameMotion(origin: compact, destination: expanded, transition: .expand)
        let time = 0.09
        let frame = open.frame(at: time)
        let velocity = open.velocity(at: time)
        let close = IslandFrameMotion(origin: frame, destination: compact, transition: .collapse, initialVelocity: velocity)
        XCTAssertEqual(close.frame(at: 0), frame)
        XCTAssertEqual(close.velocity(at: 0).height, velocity.height, accuracy: 0.001)
        XCTAssertEqual(close.velocity(at: 0).width, velocity.width, accuracy: 0.001)
        // Momentum continues briefly before the spring retracts; no hard stop.
        XCTAssertGreaterThan(close.frame(at: 0.001).height, frame.height)
        XCTAssertTrue(close.isSettled(at: 0.7))
        XCTAssertEqual(close.frame(at: 0.7).height, compact.height, accuracy: 0.15)
    }

    func testCollapseDoesNotExposeThePhysicalCutout() {
        let close = IslandFrameMotion(origin: expanded, destination: compact, transition: .collapse)
        var last = expanded.height
        for step in 0...120 {
            let frame = close.frame(at: Double(step) / 120)
            XCTAssertGreaterThanOrEqual(frame.height, compact.height - 0.001)
            XCTAssertLessThanOrEqual(frame.height, last + 0.001)
            last = frame.height
        }
        XCTAssertTrue(close.isSettled(at: 0.6))
    }

    func testResizingContentPreservesWidthAndTopAndCanReverseWithoutStopping() {
        let smaller = CGRect(x: expanded.minX, y: 790, width: expanded.width, height: 210)
        let shrink = IslandFrameMotion(origin: expanded, destination: smaller, transition: .resize)
        let time = 0.08
        let frame = shrink.frame(at: time)
        let velocity = shrink.velocity(at: time)
        let grow = IslandFrameMotion(origin: frame, destination: expanded, transition: .resize,
                                     initialVelocity: velocity)
        XCTAssertEqual(grow.frame(at: 0), frame)
        XCTAssertEqual(grow.velocity(at: 0).height, velocity.height, accuracy: 0.001)
        for step in 0...84 {
            let frame = grow.frame(at: Double(step) / 120)
            XCTAssertEqual(frame.width, expanded.width, accuracy: 0.001)
            XCTAssertEqual(frame.maxY, expanded.maxY, accuracy: 0.001)
            XCTAssertGreaterThanOrEqual(frame.height, smaller.height)
        }
        XCTAssertTrue(grow.isSettled(at: 0.7))
    }
}
