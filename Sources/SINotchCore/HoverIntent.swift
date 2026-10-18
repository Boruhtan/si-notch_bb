import Foundation

/// A cancellable dwell. The caller revalidates the logical hit region on each
/// sample; pointer speed and direction do not change the configured delay.
public struct HoverIntent: Sendable {
    public static let sampleInterval: TimeInterval = 0.025
    public static let approachMargin: CGFloat = 10
    private let enteredAt: TimeInterval

    public init(location: CGPoint, at time: TimeInterval) {
        enteredAt = time
    }

    public mutating func sample(location: CGPoint, at time: TimeInterval, delay: TimeInterval) -> Bool {
        guard time.isFinite, enteredAt.isFinite, time >= enteredAt,
              location.x.isFinite, location.y.isFinite else { return false }
        let dwell = delay.isFinite ? max(0.02, delay) : IslandTiming.hoverEnter
        return time - enteredAt >= dwell
    }

    /// A narrow strip below the visible island lets the pointer stay visible on
    /// notched displays. It does not enlarge the window or intercept other clicks.
    public static func region(for frame: CGRect) -> CGRect {
        CGRect(x: frame.minX, y: frame.minY - approachMargin,
               width: frame.width, height: frame.height + approachMargin)
    }
}
