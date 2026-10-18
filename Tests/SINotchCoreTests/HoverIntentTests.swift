import XCTest
@testable import SINotchCore

final class HoverIntentTests: XCTestCase {
    func testStationaryPointerOpensAfterShortPause() {
        var intent = HoverIntent(location: .zero, at: 10)
        XCTAssertFalse(intent.sample(location: .zero, at: 10.03, delay: 0.05))
        XCTAssertTrue(intent.sample(location: .zero, at: 10.06, delay: 0.05))
    }

    func testMovementWithinTheRegionUsesTheSameDwell() {
        for vertical in [false, true] {
            var intent = HoverIntent(location: .zero, at: 0)
            for step in 1...4 {
                let distance = CGFloat(step) * 8
                let point = CGPoint(x: vertical ? 0 : distance, y: vertical ? -distance : 0)
                XCTAssertEqual(intent.sample(location: point, at: Double(step) * 0.025, delay: 0.08), step == 4)
            }
        }
    }

    func testMovementDoesNotRestartConfiguredDelay() {
        var intent = HoverIntent(location: .zero, at: 0)
        let stop = CGPoint(x: 100, y: 30)
        XCTAssertFalse(intent.sample(location: stop, at: 0.07, delay: 0.08))
        XCTAssertTrue(intent.sample(location: stop, at: 0.09, delay: 0.08))
    }

    func testUpwardApproachDoesNotRequireStoppingBehindTheNotch() {
        var intent = HoverIntent(location: CGPoint(x: 100, y: 500), at: 0)
        XCTAssertFalse(intent.sample(location: CGPoint(x: 101, y: 508), at: 0.025, delay: 0.05))
        XCTAssertTrue(intent.sample(location: CGPoint(x: 102, y: 516), at: 0.05, delay: 0.05))
    }

    func testApproachRegionExtendsOnlyBelowTheVisibleWindow() {
        let frame = CGRect(x: 500, y: 800, width: 240, height: 33)
        let region = HoverIntent.region(for: frame)
        XCTAssertTrue(region.contains(CGPoint(x: 620, y: 795)))
        XCTAssertFalse(region.contains(CGPoint(x: 620, y: 789)))
        XCTAssertFalse(region.contains(CGPoint(x: 499, y: 810)))
        XCTAssertEqual(region.maxY, frame.maxY)
    }

    func testSmallPointerJitterDoesNotDelayIntent() {
        var intent = HoverIntent(location: .zero, at: 0)
        XCTAssertFalse(intent.sample(location: CGPoint(x: 1, y: -1), at: 0.05, delay: 0.08))
        XCTAssertTrue(intent.sample(location: CGPoint(x: -1, y: 1), at: 0.11, delay: 0.08))
    }

    func testConfiguredDelayAndInvalidSamples() {
        var intent = HoverIntent(location: .zero, at: 10)
        XCTAssertFalse(intent.sample(location: .zero, at: 10.2, delay: 0.5))
        XCTAssertFalse(intent.sample(location: .zero, at: 9, delay: 0.08))
        XCTAssertFalse(intent.sample(location: .zero, at: .infinity, delay: 0.08))
        XCTAssertFalse(intent.sample(location: CGPoint(x: CGFloat.nan, y: 0), at: 10.6, delay: 0.08))
        XCTAssertTrue(intent.sample(location: .zero, at: 10.51, delay: 0.5))
    }
}
