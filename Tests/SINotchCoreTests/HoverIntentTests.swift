import XCTest
@testable import SINotchCore

final class HoverIntentTests: XCTestCase {
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
