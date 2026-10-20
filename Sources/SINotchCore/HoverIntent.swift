import Foundation

/// A cancellable pause within a small radius. The caller revalidates the logical
/// hit region on each sample; travelling through it must not count as intent.
public struct HoverIntent: Sendable {
    public static let sampleInterval: TimeInterval = 0.025
    private var anchor: CGPoint
    private var settledSince: TimeInterval

    public init(location: CGPoint, at time: TimeInterval) {
        anchor = location
        settledSince = time
    }

    public mutating func sample(location: CGPoint, at time: TimeInterval, delay: TimeInterval) -> Bool {
        guard time.isFinite, settledSince.isFinite, time >= settledSince,
              anchor.x.isFinite, anchor.y.isFinite,
              location.x.isFinite, location.y.isFinite else { return false }
        // Anchor the tolerance to the start of the pause, so slow movement cannot
        // accumulate dwell through many individually small samples.
        if hypot(location.x - anchor.x, location.y - anchor.y) > 4 {
            anchor = location
            settledSince = time
        }
        return time - settledSince >= Self.dwell(for: delay)
    }

    /// Older saved delays may be shorter than a deliberate pause.
    public static func dwell(for delay: TimeInterval) -> TimeInterval {
        delay.isFinite ? max(IslandTiming.hoverEnter, delay) : IslandTiming.hoverEnter
    }
}
