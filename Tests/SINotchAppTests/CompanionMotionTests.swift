import Foundation
import XCTest
import SINotchCore
@testable import SINotch

final class CompanionMotionTests: XCTestCase {
    func testDistinctStateColors() {
        XCTAssertLessThan(CompanionPose.target(.ended).opacity, 1)
        let working = CompanionPose.target(.working)
        XCTAssertGreaterThan(working.green, working.red)
        XCTAssertGreaterThan(working.green, working.blue)
        XCTAssertNotEqual(working.red, CompanionPose.target(.waiting).red)
    }

    func testFastRetargetingPreservesDisplayedPose() {
        var motion = CompanionPoseTransition(status: .idle, at: 0)
        motion.retarget(to: .working, at: 1)
        let displayed = motion.value(at: 1.06)
        motion.retarget(to: .approval, at: 1.06)
        XCTAssertEqual(motion.value(at: 1.06), displayed)
        XCTAssertNotEqual(displayed, CompanionPose.target(.idle))
        XCTAssertNotEqual(displayed, CompanionPose.target(.working))
        let settled = motion.value(at: 3)
        XCTAssertEqual(settled.red, CompanionPose.target(.approval).red, accuracy: 1e-10)
    }

    func testReduceMotionUsesStaticTargetImmediately() {
        var motion = CompanionPoseTransition(status: .working, at: 0)
        motion.retarget(to: .completed, at: 1, reduceMotion: true)
        XCTAssertEqual(motion.value(at: 1, reduceMotion: true), CompanionPose.target(.completed))
        XCTAssertEqual(motion.value(at: 1), CompanionPose.target(.completed))
    }

    func testInvalidTimesAndInterpolationCannotProduceInvalidPose() {
        var motion = CompanionPoseTransition(at: .nan)
        motion.retarget(to: .failed, at: .infinity)
        let pose = motion.value(at: .nan)
        XCTAssertTrue(pose.red.isFinite)
        XCTAssertTrue(pose.opacity.isFinite)
        XCTAssertEqual(CompanionPose.target(.idle).interpolated(to: .target(.working), progress: .nan), .target(.working))
    }
}
