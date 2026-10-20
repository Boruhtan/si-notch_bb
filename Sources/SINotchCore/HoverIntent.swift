import Foundation

/// A cancellable pause within a small radius. The caller revalidates the logical
/// hit region on each sample; travelling through it must not count as intent.
public struct HoverIntent: Sendable {
    public static let sampleInterval: TimeInterval = 0.025
    public static let approachMargin: CGFloat = 20
    private var anchor: CGPoint
    private var settledSince: TimeInterval
    private var approachOrigin: CGPoint?

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

    /// A short upward movement into the lower approach strip is an intentional
    /// approach, without requiring the pointer to stop or enter the camera area.
    /// Side entry, sideways travel and reversal do not take this fast path.
    public mutating func approach(from previous: CGPoint, to location: CGPoint, region: CGRect) -> Bool {
        guard [previous.x, previous.y, location.x, location.y,
               region.minX, region.minY, region.width, region.height].allSatisfy(\.isFinite),
              region.width > 0, region.height > 0, region.contains(location) else {
            approachOrigin = nil
            return false
        }
        if approachOrigin == nil, previous.y < region.minY, location.y > previous.y {
            let progress = (region.minY - previous.y) / (location.y - previous.y)
            let x = previous.x + (location.x - previous.x) * progress
            if x >= region.minX && x < region.maxX {
                approachOrigin = CGPoint(x: x, y: region.minY)
            }
        }
        guard let origin = approachOrigin else { return false }
        let upward = location.y - origin.y
        let sideways = abs(location.x - origin.x)
        if location.y < previous.y - 1 || sideways > max(6, upward) {
            approachOrigin = nil
            return false
        }
        return upward >= 8 && upward >= sideways
    }

    /// A narrow strip below the visible island lets the pointer stay visible on
    /// notched displays. It does not enlarge the window or intercept other clicks.
    public static func region(for frame: CGRect) -> CGRect {
        CGRect(x: frame.minX, y: frame.minY - approachMargin,
               width: frame.width, height: frame.height + approachMargin)
    }
}
