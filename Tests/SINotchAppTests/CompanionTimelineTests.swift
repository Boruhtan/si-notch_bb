import XCTest
import SINotchCore
@testable import SINotch

final class CompanionTimelineTests: XCTestCase {
    func testRestingCompanionWakesOnlyAtBlinkEdges() throws {
        let schedule = CompanionTimelineSchedule(status: .idle, motion: .init(at: 0))
        let close = try XCTUnwrap(schedule.nextUpdate(after: Date(timeIntervalSinceReferenceDate: 1)))
        XCTAssertEqual(close.timeIntervalSinceReferenceDate, 5.431, accuracy: 0.00001)
        let open = try XCTUnwrap(schedule.nextUpdate(after: close))
        XCTAssertEqual(open.timeIntervalSinceReferenceDate, 5.601, accuracy: 0.00001)
        let nextClose = try XCTUnwrap(schedule.nextUpdate(after: open))
        XCTAssertEqual(nextClose.timeIntervalSinceReferenceDate, 11.031, accuracy: 0.00001)
    }

    func testStaticAndReducedMotionSchedulesStop() {
        for status: AgentStatus in [.completed, .ended] {
            let schedule = CompanionTimelineSchedule(status: status, motion: .init(status: status, at: 0))
            XCTAssertNil(schedule.nextUpdate(after: Date(timeIntervalSinceReferenceDate: 1)))
        }
        let paused = CompanionTimelineSchedule(status: .working, motion: .init(at: 0), paused: true)
        XCTAssertEqual(Array(paused.entries(from: Date(), mode: .normal)).count, 1)
    }

    func testColorTransitionKeepsSmoothCadenceThenReturnsToPixelCadence() throws {
        var motion = CompanionPoseTransition(status: .idle, at: 0)
        motion.retarget(to: .working, at: 1)
        let schedule = CompanionTimelineSchedule(status: .working, motion: motion)
        let next = try XCTUnwrap(schedule.nextUpdate(after: Date(timeIntervalSinceReferenceDate: 1.1)))
        XCTAssertLessThanOrEqual(next.timeIntervalSinceReferenceDate - 1.1, 1.0 / 30 + 0.00001)
        let settled = try XCTUnwrap(schedule.nextUpdate(after: Date(timeIntervalSinceReferenceDate: 2.01)))
        XCTAssertGreaterThan(settled.timeIntervalSinceReferenceDate - 2.01, 0.1)
    }

    func testScheduledFramesPreserveTypingBlinkGreetingAndCelebration() {
        for status: AgentStatus in [.idle, .working, .completed, .ended] {
            for greeting in [false, true] {
                let greetingDate = greeting ? Date(timeIntervalSinceReferenceDate: 0.14) : nil
                let schedule = CompanionTimelineSchedule(status: status, motion: .init(status: status, at: 0),
                    greetingStartedAt: greetingDate)
                var rendered = Date(timeIntervalSinceReferenceDate: 0)
                var next = schedule.nextUpdate(after: rendered)
                for tick in 0..<144 {
                    let time = 0.002 + Double(tick) / 12
                    while let update = next, update.timeIntervalSinceReferenceDate <= time {
                        rendered = update
                        next = schedule.nextUpdate(after: update)
                    }
                    for style in CompanionStyle.allCases {
                        func sprite(at time: TimeInterval) -> PixelCompanion {
                            PixelCompanion.frame(style: style, status: status, time: time, stateAge: time,
                                greetingAge: greetingDate.map { time - $0.timeIntervalSinceReferenceDate })
                        }
                        XCTAssertTrue(sprite(at: time) == sprite(at: rendered.timeIntervalSinceReferenceDate),
                                       "\(style) \(status) greeting=\(greeting) at \(time)")
                    }
                }
            }
        }
    }
}
