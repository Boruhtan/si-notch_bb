import XCTest
@testable import SINotch

final class IslandFrameMotionTests: XCTestCase {
    let compact = CGRect(x: 600, y: 967, width: 230, height: 33)
    let expanded = CGRect(x: 375, y: 650, width: 680, height: 350)

    func testDropOpensPromptlyWithSmallBoundedBounceAndFixedTop() {
        let motion = IslandFrameMotion(origin: compact, destination: expanded, expanding: true)
        XCTAssertEqual(motion.frame(at: 0), compact)
        XCTAssertGreaterThan(motion.frame(at: 0.18).height, expanded.height * 0.9)
        var peak: CGFloat = 0
        for step in 0...120 {
            let frame = motion.frame(at: Double(step) / 120)
            XCTAssertEqual(frame.maxY, expanded.maxY, accuracy: 0.001)
            peak = max(peak, frame.height)
            XCTAssertLessThan(frame.width, expanded.width * 1.04)
        }
        XCTAssertGreaterThan(peak, expanded.height + 1)
        XCTAssertLessThan(peak, expanded.height * 1.06)
        XCTAssertTrue(motion.isSettled(at: 0.7))
    }

    func testReversalPreservesPositionAndVelocityAndSettles() {
        let open = IslandFrameMotion(origin: compact, destination: expanded, expanding: true)
        let time = 0.09
        let frame = open.frame(at: time)
        let velocity = open.velocity(at: time)
        let close = IslandFrameMotion(origin: frame, destination: compact, expanding: false, initialVelocity: velocity)
        XCTAssertEqual(close.frame(at: 0), frame)
        XCTAssertEqual(close.velocity(at: 0).height, velocity.height, accuracy: 0.001)
        XCTAssertEqual(close.velocity(at: 0).width, velocity.width, accuracy: 0.001)
        // Momentum continues briefly before the spring retracts; no hard stop.
        XCTAssertGreaterThan(close.frame(at: 0.001).height, frame.height)
        XCTAssertTrue(close.isSettled(at: 0.7))
        XCTAssertEqual(close.frame(at: 0.7).height, compact.height, accuracy: 0.15)
    }

    func testCollapseDoesNotExposeThePhysicalCutout() {
        let close = IslandFrameMotion(origin: expanded, destination: compact, expanding: false)
        var last = expanded.height
        for step in 0...120 {
            let frame = close.frame(at: Double(step) / 120)
            XCTAssertGreaterThanOrEqual(frame.height, compact.height - 0.001)
            XCTAssertLessThanOrEqual(frame.height, last + 0.001)
            last = frame.height
        }
        XCTAssertTrue(close.isSettled(at: 0.6))
    }
}
