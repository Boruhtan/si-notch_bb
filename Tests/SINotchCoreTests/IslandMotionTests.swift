import Foundation
import XCTest
@testable import SINotchCore

final class IslandMotionTests: XCTestCase {
    func testInteractiveProfileReachesMostOfItsTravelPromptly() {
        let open = IslandSpring(response: IslandTiming.expandResponse)
        let close = IslandSpring(response: IslandTiming.collapseResponse)
        XCTAssertGreaterThan(open.value(at: 0.17).progress, 0.9)
        XCTAssertGreaterThan(close.value(at: 0.15).progress, 0.9)
        XCTAssertLessThan(open.settlingDuration(maximumDistance: 700), 0.45)
        XCTAssertLessThan(close.settlingDuration(maximumDistance: 700), 0.38)
    }

    func testZeroVelocityStartAndSettledEndpoint() {
        let spring = IslandSpring(response: 0.36)
        XCTAssertEqual(spring.value(at: 0), IslandMotionSample(progress: 0, velocity: 0))
        XCTAssertEqual(spring.value(at: -1), IslandMotionSample(progress: 0, velocity: 0))
        XCTAssertEqual(spring.value(at: .infinity), IslandMotionSample(progress: 1, velocity: 0))
        XCTAssertEqual(spring.value(at: 100).progress, 1)
        XCTAssertEqual(spring.value(at: 100).velocity, 0)
    }

    func testCriticalResponseMatchesAnalyticValueAndDerivative() {
        let spring = IslandSpring(response: 0.36)
        let omega = 2 * Double.pi / spring.response
        let sample = spring.value(at: 1 / omega)
        XCTAssertEqual(sample.progress, 1 - 2 / exp(1), accuracy: 1e-12)
        XCTAssertEqual(sample.velocity, omega / exp(1), accuracy: 1e-12)
        let time = 0.17
        let delta = 1e-6
        let numericalDerivative = (spring.value(at: time + delta).progress - spring.value(at: time - delta).progress) / (2 * delta)
        XCTAssertEqual(spring.value(at: time).velocity, numericalDerivative, accuracy: 1e-8)
    }

    func testMotionIsMonotonicAndNeverOvershoots() {
        for response in [0.32, 0.36, 0.5] {
            let spring = IslandSpring(response: response)
            var previous = 0.0
            for step in 0...500 {
                let sample = spring.value(at: Double(step) * response / 100)
                XCTAssertGreaterThanOrEqual(sample.progress, previous)
                XCTAssertTrue((0...1).contains(sample.progress))
                XCTAssertGreaterThanOrEqual(sample.velocity, 0)
                XCTAssertTrue(sample.velocity.isFinite)
                previous = sample.progress
            }
        }
    }

    func testResponseScalesTimeAndRetractionIsFaster() {
        let expand = IslandSpring(response: 0.36)
        let retract = IslandSpring(response: 0.32)
        XCTAssertGreaterThan(retract.value(at: 0.12).progress, expand.value(at: 0.12).progress)
        XCTAssertEqual(expand.value(at: 0.36 * 0.4).progress, retract.value(at: 0.32 * 0.4).progress, accuracy: 1e-12)
        XCTAssertEqual(expand.settlingDuration(maximumDistance: 700) / retract.settlingDuration(maximumDistance: 700), 0.36 / 0.32, accuracy: 1e-12)
    }

    func testSettlingDurationBoundsLargestPixelDisplacement() {
        let spring = IslandSpring(response: 0.36)
        for distance in [1.0, 100, 1600, 10000] {
            let duration = spring.settlingDuration(maximumDistance: distance)
            XCTAssertGreaterThan(duration, 0)
            XCTAssertLessThanOrEqual((1 - spring.value(at: duration).progress) * distance, 0.25 + 1e-10)
            XCTAssertGreaterThan((1 - spring.value(at: duration * 0.99).progress) * distance, 0.25)
        }
        XCTAssertEqual(spring.settlingDuration(maximumDistance: 0), 0)
        XCTAssertEqual(spring.settlingDuration(maximumDistance: 0.25), 0)
        XCTAssertEqual(spring.settlingDuration(maximumDistance: -100), spring.settlingDuration(maximumDistance: 100))
    }

    func testInvalidInputsNeverProduceNaN() {
        for response in [0.0, -1, .nan, .infinity, -.infinity, .leastNonzeroMagnitude] {
            let spring = IslandSpring(response: response)
            XCTAssertEqual(spring.response, 0.36)
            for time in [-1.0, .nan, .infinity, -.infinity, .greatestFiniteMagnitude] {
                let sample = spring.value(at: time)
                XCTAssertTrue(sample.progress.isFinite)
                XCTAssertTrue(sample.velocity.isFinite)
            }
        }
        let spring = IslandSpring()
        for threshold in [0.0, -1, .nan, .infinity] {
            XCTAssertEqual(spring.settlingDuration(maximumDistance: 700, pixelThreshold: threshold), spring.settlingDuration(maximumDistance: 700))
        }
        XCTAssertEqual(spring.settlingDuration(maximumDistance: .nan), 0)
        XCTAssertEqual(spring.settlingDuration(maximumDistance: .infinity), 0)
        XCTAssertTrue(IslandSpring(response: .greatestFiniteMagnitude).settlingDuration(maximumDistance: 700).isFinite)
        XCTAssertTrue(spring.settlingDuration(maximumDistance: .greatestFiniteMagnitude, pixelThreshold: .leastNonzeroMagnitude).isFinite)
    }
}
