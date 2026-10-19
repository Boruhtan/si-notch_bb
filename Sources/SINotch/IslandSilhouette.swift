import SwiftUI

/// The small inward shoulders meet the display's top edge. Unlike a floating
/// rounded rectangle this reads as a continuation of the physical camera cutout.
struct IslandSilhouette: Shape {
    var shoulder: CGFloat
    var bottomRadius: CGFloat
    var droplet: CGFloat = 0

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
        get { AnimatablePair(AnimatablePair(shoulder, bottomRadius), droplet) }
        set { shoulder = newValue.first.first; bottomRadius = newValue.first.second; droplet = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let s = max(0, min(shoulder, min(rect.width / 4, rect.height / 3)))
        let r = max(0, min(bottomRadius, min((rect.width - 2 * s) / 2, rect.height - s)))
        let lift = min(8, rect.height * 0.04) * max(0, min(1, droplet))
        let left = rect.minX + s, right = rect.maxX - s
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: right, y: rect.minY + s), control: CGPoint(x: right, y: rect.minY))
        p.addLine(to: CGPoint(x: right, y: rect.maxY - r - lift))
        p.addQuadCurve(to: CGPoint(x: right - r, y: rect.maxY - lift), control: CGPoint(x: right, y: rect.maxY - lift))
        // A shallow curved belly contracts into the final straight bottom edge.
        // It follows the live window geometry instead of running a second clock.
        p.addCurve(to: CGPoint(x: left + r, y: rect.maxY - lift),
                   control1: CGPoint(x: right - r - (right - left - 2 * r) / 3, y: rect.maxY + lift / 3),
                   control2: CGPoint(x: left + r + (right - left - 2 * r) / 3, y: rect.maxY + lift / 3))
        p.addQuadCurve(to: CGPoint(x: left, y: rect.maxY - r - lift), control: CGPoint(x: left, y: rect.maxY - lift))
        p.addLine(to: CGPoint(x: left, y: rect.minY + s))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY), control: CGPoint(x: left, y: rect.minY))
        p.closeSubpath()
        return p
    }
}
