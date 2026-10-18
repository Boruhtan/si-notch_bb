import Foundation
import SINotchCore

/// Colors ease between states while the sprite itself stays on the pixel grid.
struct CompanionPose: Equatable {
    var opacity = 1.0
    var red = 0.64
    var green = 0.69
    var blue = 0.73

    static func target(_ status: AgentStatus) -> CompanionPose {
        switch status {
        case .idle: return CompanionPose()
        case .working: return CompanionPose(red: 0.40, green: 0.89, blue: 0.56)
        case .waiting, .approval: return CompanionPose(red: 1, green: 0.74, blue: 0.36)
        case .completed: return CompanionPose(red: 0.48, green: 0.79, blue: 1)
        case .failed: return CompanionPose(red: 1, green: 0.47, blue: 0.43)
        case .ended: return CompanionPose(opacity: 0.62)
        }
    }

    func interpolated(to target: CompanionPose, progress: Double) -> CompanionPose {
        let p = progress.isFinite ? min(1, max(0, progress)) : 1
        func blend(_ from: Double, _ to: Double) -> Double { from + (to - from) * p }
        return CompanionPose(opacity: blend(opacity, target.opacity), red: blend(red, target.red),
                             green: blend(green, target.green), blue: blend(blue, target.blue))
    }
}

/// Retargeting starts from the displayed pose so rapid event changes never pop.
struct CompanionPoseTransition {
    private(set) var source: CompanionPose
    private(set) var target: CompanionPose
    private(set) var startedAt: TimeInterval
    private let spring = IslandSpring(response: 0.28)

    init(status: AgentStatus = .idle, at time: TimeInterval = 0) {
        source = .target(status)
        target = source
        startedAt = time.isFinite ? time : 0
    }

    func value(at time: TimeInterval, reduceMotion: Bool = false) -> CompanionPose {
        if reduceMotion { return target }
        let elapsed = time.isFinite ? max(0, time - startedAt) : 0
        return source.interpolated(to: target, progress: spring.value(at: elapsed).progress)
    }

    mutating func retarget(to status: AgentStatus, at time: TimeInterval, reduceMotion: Bool = false) {
        let timestamp = time.isFinite ? time : startedAt
        source = value(at: timestamp, reduceMotion: reduceMotion)
        target = .target(status)
        startedAt = timestamp
        if reduceMotion { source = target }
    }
}
