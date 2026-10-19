import XCTest
@testable import SINotch

final class IslandFrameMotionTests: XCTestCase {
    let compact = CGRect(x: 600, y: 967, width: 230, height: 33)
    let expanded = CGRect(x: 375, y: 650, width: 680, height: 350)

    func testDropOpensAsOneSurfaceWithoutReboundAndWithFixedTop() {
        let motion = IslandFrameMotion(origin: compact, destination: expanded, expanding: true)
        XCTAssertEqual(motion.frame(at: 0), compact)
        XCTAssertGreaterThan(motion.frame(at: 0.18).height, expanded.height * 0.65)
        XCTAssertLessThan(motion.frame(at: 0.10).height, expanded.height * 0.65)
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
