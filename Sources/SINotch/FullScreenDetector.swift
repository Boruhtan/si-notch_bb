import AppKit

/// Public system presentation flags cover native Spaces and immersive video
/// players. Window bounds scope those flags to the island's display. No window
/// titles, pixels, Accessibility access, or Screen Recording access are used.
enum FullScreenDetector {
    static func isFullScreen(on screen: NSScreen?) -> Bool {
        coveringWindowLevel(on: screen) != nil
    }

    static func coveringWindowLevel(on screen: NSScreen?) -> Int? {
        let options = NSApp.currentSystemPresentationOptions
        let native = options.contains(.fullScreen)
        let immersive = !options.intersection([.hideMenuBar, .autoHideMenuBar]).isEmpty &&
            !options.intersection([.hideDock, .autoHideDock]).isEmpty
        guard let screen else { return nil }
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]], let primary = NSScreen.screens.first else { return native ? 0 : nil }
        // Quartz uses a top-left origin on the primary display; AppKit uses bottom-left.
        let frame = CGRect(x: screen.frame.minX, y: primary.frame.maxY - screen.frame.maxY,
                           width: screen.frame.width, height: screen.frame.height)
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var frontmostWindows: [(rect: CGRect, level: Int)] = []
        let direct = windows.compactMap { window -> Int? in
            guard let pid = window[kCGWindowOwnerPID as String] as? Int32,
                  pid != ProcessInfo.processInfo.processIdentifier,
                  let layer = window[kCGWindowLayer as String] as? Int, layer >= 0,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0.9,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { return nil }
            if pid == frontmostPID { frontmostWindows.append((rect, layer)) }
            if (native || immersive) && layer == 0 &&
                coversDisplay(rect, display: frame, topInset: screen.safeAreaInsets.top) { return layer }
            // Some NSView/AVKit players use a borderless covering window and
            // leave presentation flags unchanged. Ordinary maximized windows
            // leave room for the menu bar or Dock and fail this stricter check.
            if pid == frontmostPID && coversDisplay(rect, display: frame, topInset: screen.safeAreaInsets.top) { return layer }
            return nil
        }.max()
        // Browsers can split one fullscreen surface into separate toolbar and
        // content windows. Only combine opaque bands from the same active app.
        if coversDisplay(frontmostWindows.map(\.rect), display: frame, topInset: screen.safeAreaInsets.top) {
            let level = frontmostWindows.filter { coversWidth($0.rect, display: frame) && $0.rect.intersects(frame) }
                .map(\.level).max() ?? 0
            return max(direct ?? 0, level)
        }
        return direct
    }

    private static func coversWidth(_ window: CGRect, display: CGRect) -> Bool {
        window.minX <= display.minX + 2 && window.maxX >= display.maxX - 2
    }

    static func coversDisplay(_ windows: [CGRect], display: CGRect, topInset: CGFloat) -> Bool {
        let bands = windows.filter {
            coversWidth($0, display: display) && $0.minY >= display.minY - 2 && $0.intersects(display)
        }.sorted { $0.minY < $1.minY }
        var coveredEnd = display.minY + max(0, topInset)
        for band in bands {
            guard band.minY <= coveredEnd + 2 else { return false }
            coveredEnd = max(coveredEnd, band.maxY)
            if coveredEnd >= display.maxY - 2 { return true }
        }
        return false
    }

    static func coversDisplay(_ window: CGRect, display: CGRect, topInset: CGFloat) -> Bool {
        // Native fullscreen content can begin just below a physical camera cutout.
        let tolerance: CGFloat = 2
        return window.minX <= display.minX + tolerance && window.maxX >= display.maxX - tolerance &&
            window.minY <= display.minY + max(0, topInset) + tolerance && window.minY >= display.minY - tolerance &&
            window.maxY >= display.maxY - tolerance
    }
}
