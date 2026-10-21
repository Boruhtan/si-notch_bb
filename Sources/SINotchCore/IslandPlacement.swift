import Foundation
import CoreGraphics

/// Display capabilities choose the surface; task state and content stay shared.
public struct IslandPlacement {
    public let geometry: NotchGeometry
    public let isFloating: Bool
    public let isTrailing: Bool
    public let topOffset: CGFloat

    public init(geometry: NotchGeometry, belowMenu: Bool, menuBarHeight: CGFloat) {
        self.geometry = geometry
        isFloating = !geometry.hasNotch || belowMenu
        isTrailing = !geometry.hasNotch
        let menuHeight = menuBarHeight.isFinite ? max(0, menuBarHeight) : 0
        topOffset = isFloating ? max(geometry.topInset, menuHeight) + 8 : 0
    }

    public var cameraWidth: CGFloat { isFloating ? 0 : geometry.notchWidth }
    public var headerHeight: CGFloat { isFloating ? 36 : geometry.topInset }
    public var compactHeight: CGFloat { isFloating ? 30 : max(33, geometry.topInset) }
    public var compactSideInset: CGFloat { isFloating ? 10 : 3 }

    public func compactFrame(leftWidth: CGFloat, rightWidth: CGFloat) -> CGRect {
        if isFloating {
            return floatingFrame(width: leftWidth + rightWidth + 2 * compactSideInset, height: compactHeight)
        }
        return geometry.coveringTopEdge(geometry.compactFrame(
            leftWingWidth: leftWidth + compactSideInset,
            rightWingWidth: rightWidth + compactSideInset, minimumHeight: compactHeight))
    }

    public func expandedFrame(width: CGFloat, height: CGFloat) -> CGRect {
        isFloating ? floatingFrame(width: width, height: height) :
            geometry.coveringTopEdge(geometry.expandedFrame(width: width, height: height))
    }

    public func fullScreenRevealFrame(leftWidth: CGFloat, rightWidth: CGFloat) -> CGRect {
        guard isTrailing else { return geometry.fullScreenRevealFrame }
        let compact = compactFrame(leftWidth: leftWidth, rightWidth: rightWidth)
        return CGRect(x: compact.minX, y: geometry.screenFrame.maxY - 3, width: compact.width, height: 3)
    }

    private func floatingFrame(width: CGFloat, height: CGFloat) -> CGRect {
        var frame = geometry.frame(width: width, height: height, topOffset: topOffset)
        if isTrailing {
            let scale = geometry.backingScaleFactor
            frame.origin.x = max(geometry.screenFrame.minX,
                ((geometry.screenFrame.maxX - 12 - frame.width) * scale).rounded() / scale)
        }
        return frame
    }
}
