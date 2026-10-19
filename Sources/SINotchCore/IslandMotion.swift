import Foundation

public enum IslandTiming {
    public static let hoverEnter: TimeInterval = 0.06
    public static let hoverExit: TimeInterval = 0.25
    public static let expandResponse: TimeInterval = 0.26
    public static let collapseResponse: TimeInterval = 0.22
}

public struct IslandMotionSample: Equatable, Sendable {
    /// Normalized displacement from the starting position toward the target.
    public let progress: Double
    /// Normalized progress per second.
    public let velocity: Double

    public init(progress: Double, velocity: Double) {
        self.progress = progress
        self.velocity = velocity
    }
}

/// An analytic, critically damped spring starting at zero with zero velocity.
/// `response` determines its natural angular frequency, ω = 2π / response.
public struct IslandSpring: Equatable, Sendable {
    public let response: TimeInterval
    private let angularFrequency: Double

    public init(response: TimeInterval = 0.36) {
        let frequency = 2 * Double.pi / response
        if response.isFinite, response > 0, frequency.isFinite, frequency > 0 {
            self.response = response
            angularFrequency = frequency
        } else {
            self.response = 0.36
            angularFrequency = 2 * Double.pi / 0.36
        }
    }

    public func value(at time: TimeInterval) -> IslandMotionSample {
        if time == .infinity { return IslandMotionSample(progress: 1, velocity: 0) }
        guard time.isFinite, time > 0 else { return IslandMotionSample(progress: 0, velocity: 0) }
        let x = angularFrequency * time
        guard x.isFinite else { return IslandMotionSample(progress: 1, velocity: 0) }
        // expm1 avoids cancellation when progress is close to zero.
        let progress = min(1, max(0, -expm1(log1p(x) - x)))
        let velocity = angularFrequency * (x * exp(-x))
        return IslandMotionSample(progress: progress, velocity: velocity)
    }

    /// The earliest time at which every interpolated dimension is within the
    /// requested point threshold, given a bound on the largest displacement.
    /// Invalid distances settle immediately; invalid thresholds use 0.25 points.
    public func settlingDuration(maximumDistance: Double, pixelThreshold: Double = 0.25) -> TimeInterval {
        guard maximumDistance.isFinite else { return 0 }
        let distance = abs(maximumDistance)
        let threshold = pixelThreshold.isFinite && pixelThreshold > 0 ? pixelThreshold : 0.25
        guard distance > threshold else { return 0 }
        // Solve (1+x)e^-x <= threshold/distance in log space to avoid underflow.
        let logEpsilon = log(threshold) - log(distance)
        var lower = 0.0
        var upper = 1.0
        while log1p(upper) - upper > logEpsilon { upper *= 2 }
        for _ in 0..<80 {
            let midpoint = (lower + upper) / 2
            if log1p(midpoint) - midpoint > logEpsilon { lower = midpoint }
            else { upper = midpoint }
        }
        // Round toward a settled result; extreme valid responses saturate safely.
        let duration = upper / angularFrequency * (1 + 8 * Double.ulpOfOne)
        return duration.isFinite ? duration : Double.greatestFiniteMagnitude
    }
}
