import SwiftUI
import SINotchCore

/// Pixel poses change at 6 Hz. A resting companion needs only two blink edges
/// per 5.6 seconds; keep 30 Hz solely for the brief color transition.
struct CompanionTimelineSchedule: TimelineSchedule {
    var status: AgentStatus
    var motion: CompanionPoseTransition
    var greetingStartedAt: Date?
    var paused = false

    func entries(from startDate: Date, mode: Mode) -> AnySequence<Date> {
        AnySequence {
            var next: Date? = startDate
            return AnyIterator<Date> {
                guard let date = next else { return nil }
                next = nextUpdate(after: date)
                return date
            }
        }
    }

    func nextUpdate(after date: Date) -> Date? {
        guard !paused else { return nil }
        let time = date.timeIntervalSinceReferenceDate
        var next = TimeInterval.infinity
        let colorEnd = motion.startedAt + 0.7
        if motion.source != motion.target, time < colorEnd {
            next = min(time + 1.0 / 30, colorEnd)
        }
        let celebrationEnd = motion.startedAt + 0.7
        let greetingStart = greetingStartedAt?.timeIntervalSinceReferenceDate
        let greetingEnd = greetingStartedAt.map { $0.timeIntervalSinceReferenceDate + 0.8 }
        let celebrating = status == .completed && time < celebrationEnd
        let greeting = greetingStart.map { time >= $0 && time < $0 + 0.8 } ?? false
        if let greetingStart, time < greetingStart { next = min(next, greetingStart) }
        if status == .working || celebrating || greeting {
            // Step just beyond a boundary so floating point rounding cannot
            // select the preceding sprite phase or a still-closed eye.
            next = min(next, (floor(time * 6) + 1) / 6 + 0.001)
        }
        if celebrating { next = min(next, celebrationEnd) }
        if greeting, let greetingEnd { next = min(next, greetingEnd) }
        if status != .completed && status != .ended {
            let cycle = floor(time / 5.6) * 5.6
            let close = cycle + 5.431
            next = min(next, time < close ? close : cycle + 5.601)
        }
        return next.isFinite ? Date(timeIntervalSinceReferenceDate: next) : nil
    }
}
