import Foundation
import CoreGraphics

/// Coordinates are macOS global screen points; backing scale aligns edges to pixels.
public struct NotchGeometry: Equatable, Sendable {
    public let screenFrame: CGRect
    public let topInset: CGFloat
    public let auxiliaryTopLeftArea: CGRect?
    public let auxiliaryTopRightArea: CGRect?
    public let backingScaleFactor: CGFloat

    public init(screenFrame: CGRect, topInset: CGFloat,
                auxiliaryTopLeftArea: CGRect?, auxiliaryTopRightArea: CGRect?,
                backingScaleFactor: CGFloat = 1) {
        if [screenFrame.minX, screenFrame.minY, screenFrame.width, screenFrame.height].allSatisfy(\.isFinite),
           screenFrame.width > 0, screenFrame.height > 0 {
            self.screenFrame = screenFrame
        } else { self.screenFrame = .zero }
        self.topInset = topInset.isFinite ? max(0, min(topInset, self.screenFrame.height)) : 0
        self.auxiliaryTopLeftArea = auxiliaryTopLeftArea
        self.auxiliaryTopRightArea = auxiliaryTopRightArea
        self.backingScaleFactor = backingScaleFactor.isFinite && backingScaleFactor > 0 ? backingScaleFactor : 1
    }

    /// Width-only initializer retained for callers that have measured the top areas.
    public init(screenFrame: CGRect, topInset: CGFloat = 0,
                auxiliaryLeftWidth: CGFloat? = nil, auxiliaryRightWidth: CGFloat? = nil,
                backingScaleFactor: CGFloat = 1) {
        let topY = screenFrame.maxY - topInset
        self.init(screenFrame: screenFrame, topInset: topInset,
                  auxiliaryTopLeftArea: auxiliaryLeftWidth.map { CGRect(x: screenFrame.minX, y: topY, width: $0, height: topInset) },
                  auxiliaryTopRightArea: auxiliaryRightWidth.map { CGRect(x: screenFrame.maxX - $0, y: topY, width: $0, height: topInset) },
                  backingScaleFactor: backingScaleFactor)
    }

    public var auxiliaryLeftWidth: CGFloat? { auxiliaryTopLeftArea?.width }
    public var auxiliaryRightWidth: CGFloat? { auxiliaryTopRightArea?.width }

    public var hasNotch: Bool {
        guard topInset > 0, let left = auxiliaryTopLeftArea, let right = auxiliaryTopRightArea,
              validTopArea(left), validTopArea(right), left.maxX < right.minX else { return false }
        return left.maxX > screenFrame.minX && right.minX < screenFrame.maxX
    }

    public var notchWidth: CGFloat {
        guard hasNotch else { return 0 }
        return auxiliaryTopRightArea!.minX - auxiliaryTopLeftArea!.maxX
    }

    public var centerX: CGFloat {
        guard hasNotch else { return screenFrame.midX }
        return (auxiliaryTopLeftArea!.maxX + auxiliaryTopRightArea!.minX) / 2
    }

    /// Hidden fullscreen reveal stays within the physical cutout, or the top
    /// three points on a display without one. Never extend over player content.
    public var fullScreenRevealFrame: CGRect {
        let width = min(screenFrame.width, hasNotch ? notchWidth : 80)
        let height = max(3, topInset)
        return CGRect(x: centerX - width / 2, y: screenFrame.maxY - height, width: width, height: height)
    }

    /// Collapsed bounds cover the physical cutout and only the requested control wings.
    public func compactFrame(wingWidth: CGFloat, minimumHeight: CGFloat = 32,
                             topOffset: CGFloat = 0) -> CGRect {
        compactFrame(leftWingWidth: wingWidth, rightWingWidth: wingWidth,
                     minimumHeight: minimumHeight, topOffset: topOffset)
    }

    /// Each wing starts at the physical cutout, independent of the other wing.
    /// The status counter must not reserve the title's wider space in the menu bar.
    public func compactFrame(leftWingWidth: CGFloat, rightWingWidth: CGFloat,
                             minimumHeight: CGFloat = 32, topOffset: CGFloat = 0) -> CGRect {
        let left = finiteSize(leftWingWidth), right = finiteSize(rightWingWidth)
        var result = frame(width: notchWidth + left + right,
                           height: max(topInset, finiteSize(minimumHeight)), topOffset: topOffset)
        result.origin.x = max(screenFrame.minX, min(snap(centerX - notchWidth / 2 - left), screenFrame.maxX - result.width))
        return result
    }

    public func compactFrame(width: CGFloat = 240, height: CGFloat = 38) -> CGRect {
        frame(width: max(finiteSize(width), notchWidth), height: max(finiteSize(height), topInset))
    }

    public func expandedFrame(width: CGFloat = 460, height: CGFloat = 320, topOffset: CGFloat = 0) -> CGRect {
        frame(width: width, height: height, topOffset: topOffset)
    }

    /// AppKit rounds this borderless window to whole screen points. Integral bounds
    /// and one point of bleed keep its top edge fixed even on Retina displays.
    /// Detached panels below the menu bar keep their exact bounds.
    public func coveringTopEdge(_ frame: CGRect) -> CGRect {
        guard abs(frame.maxY - screenFrame.maxY) < 0.0001 else { return frame }
        var result = frame.integral
        result.size.height += 1
        return result
    }

    public func frame(width: CGFloat, height: CGFloat, topOffset: CGFloat = 0) -> CGRect {
        let width = min(screenFrame.width, snap(finiteSize(width)))
        let height = min(screenFrame.height, snap(finiteSize(height)))
        let offset = min(max(0, screenFrame.height - height), snap(finiteSize(topOffset)))
        let x = max(screenFrame.minX, min(snap(centerX - width / 2), screenFrame.maxX - width))
        let y = max(screenFrame.minY, min(snap(screenFrame.maxY - offset - height), screenFrame.maxY - height))
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func validTopArea(_ area: CGRect) -> Bool {
        let values = [area.minX, area.minY, area.maxX, area.maxY, area.width, area.height]
        let tolerance = 1 / backingScaleFactor
        return values.allSatisfy(\.isFinite) && area.width > 0 && area.height > 0 &&
            area.minX >= screenFrame.minX - tolerance && area.maxX <= screenFrame.maxX + tolerance &&
            abs(area.maxY - screenFrame.maxY) <= tolerance &&
            area.minY <= screenFrame.maxY - topInset + tolerance
    }

    private func finiteSize(_ size: CGFloat) -> CGFloat { size.isFinite ? max(0, size) : 0 }
    private func snap(_ value: CGFloat) -> CGFloat {
        let pixels = value * backingScaleFactor
        return pixels.isFinite ? pixels.rounded() / backingScaleFactor : value
    }
}
