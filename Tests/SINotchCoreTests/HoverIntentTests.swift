import XCTest
@testable import SINotchCore

final class HoverIntentTests: XCTestCase {
    private let region = CGRect(x: 100, y: 100, width: 200, height: 53)

    func testUpwardApproachOpensBeforeThePointerReachesTheVisibleEdge() {
        var intent = HoverIntent(location: CGPoint(x: 200, y: 101), at: 0)
        XCTAssertFalse(intent.approach(from: CGPoint(x: 200, y: 98), to: CGPoint(x: 200, y: 101), region: region))
        XCTAssertTrue(intent.approach(from: CGPoint(x: 200, y: 101), to: CGPoint(x: 202, y: 109), region: region))
        XCTAssertLessThan(109, region.minY + HoverIntent.approachMargin, "The pointer is still below the physical/visible edge")
    }

    func testFastApproachCanOpenOnTheFirstMotionEvent() {
        var intent = HoverIntent(location: CGPoint(x: 200, y: 110), at: 0)
        XCTAssertTrue(intent.approach(from: CGPoint(x: 195, y: 80), to: CGPoint(x: 200, y: 110), region: region))
    }

    func testSideEntryAndDownwardTravelNeverTakeTheFastPath() {
        var intent = HoverIntent(location: CGPoint(x: 101, y: 110), at: 0)
        XCTAssertFalse(intent.approach(from: CGPoint(x: 90, y: 110), to: CGPoint(x: 101, y: 110), region: region))
        XCTAssertFalse(intent.approach(from: CGPoint(x: 101, y: 110), to: CGPoint(x: 150, y: 110), region: region))
        XCTAssertFalse(intent.approach(from: CGPoint(x: 150, y: 154), to: CGPoint(x: 150, y: 140), region: region))
    }

    func testReversingOrTurningSidewaysCancelsTheApproach() {
        for sideways in [false, true] {
            var intent = HoverIntent(location: CGPoint(x: 200, y: 105), at: 0)
            XCTAssertFalse(intent.approach(from: CGPoint(x: 200, y: 98), to: CGPoint(x: 200, y: 105), region: region))
            let turn = sideways ? CGPoint(x: 215, y: 107) : CGPoint(x: 200, y: 103)
            XCTAssertFalse(intent.approach(from: CGPoint(x: 200, y: 105), to: turn, region: region))
            XCTAssertFalse(intent.approach(from: turn, to: CGPoint(x: 215, y: 115), region: region))
        }
    }

    func testBriefAccidentalHoverDoesNotOpenEvenWithLegacyDelay() {
        var intent = HoverIntent(location: .zero, at: 10)
        XCTAssertFalse(intent.sample(location: .zero, at: 10.08, delay: 0.06))
        XCTAssertFalse(intent.sample(location: .zero, at: 10.15, delay: 0.06))
        XCTAssertTrue(intent.sample(location: .zero, at: 10.19, delay: 0.06))
    }

    func testCrossingTheIslandInEitherDirectionDoesNotOpen() {
        for vertical in [false, true] {
            var intent = HoverIntent(location: .zero, at: 0)
            for step in 1...16 {
                let distance = CGFloat(step) * 8
                let point = CGPoint(x: vertical ? 0 : distance, y: vertical ? -distance : 0)
                XCTAssertFalse(intent.sample(location: point, at: Double(step) * 0.025, delay: 0.06))
            }
        }
    }

    func testMovingThenStoppingRequiresAFreshPause() {
        var intent = HoverIntent(location: .zero, at: 0)
        let stop = CGPoint(x: 100, y: 30)
        XCTAssertFalse(intent.sample(location: stop, at: 0.3, delay: 0.06))
        XCTAssertFalse(intent.sample(location: stop, at: 0.4, delay: 0.06))
        XCTAssertTrue(intent.sample(location: stop, at: 0.49, delay: 0.06))
    }

    func testSlowContinuousDriftCannotAccumulateDwell() {
        var intent = HoverIntent(location: .zero, at: 0)
        for step in 1...30 {
            XCTAssertFalse(intent.sample(location: CGPoint(x: step, y: 0), at: Double(step) * 0.025, delay: 0.06))
        }
    }

    func testApproachRegionExtendsOnlyBelowTheVisibleWindow() {
        let frame = CGRect(x: 500, y: 800, width: 240, height: 33)
        let region = HoverIntent.region(for: frame)
        XCTAssertTrue(region.contains(CGPoint(x: 620, y: 782)), "The cursor can remain fully below the physical cutout")
        XCTAssertFalse(region.contains(CGPoint(x: 620, y: 779)))
        XCTAssertFalse(region.contains(CGPoint(x: 499, y: 810)))
        XCTAssertEqual(region.maxY, frame.maxY)
    }

    func testSmallPointerJitterDoesNotDelayIntent() {
        var intent = HoverIntent(location: .zero, at: 0)
        XCTAssertFalse(intent.sample(location: CGPoint(x: 1, y: -1), at: 0.1, delay: 0.18))
        XCTAssertTrue(intent.sample(location: CGPoint(x: -1, y: 1), at: 0.19, delay: 0.18))
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
