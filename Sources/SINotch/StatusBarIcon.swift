import AppKit
import SINotchCore

enum StatusBarIcon {
    static func make(style: CompanionStyle) -> NSImage {
        // Reuse the companion's small sprite. Facial ink becomes transparent so
        // the system can tint it; the robot's dark display exposes its lit eyes.
        let sprite = PixelCompanion.frame(style: style, status: .idle, time: 0,
                                          reduceMotion: true, detailed: false)
        let rows: Range<Int>
        switch style {
        case .cat: rows = 3..<13
        case .robot: rows = 2..<12
        case .sprout: rows = 2..<17
        case .ghost: rows = 4..<17
        }
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { _ in
            NSGraphicsContext.current?.shouldAntialias = false
            NSColor.black.setFill()
            for y in rows {
                for x in 3..<17 where ![Character("."), "E", "P"].contains(sprite[x, y]) {
                    NSRect(x: x, y: (18 - rows.count) / 2 + rows.upperBound - 1 - y, width: 1, height: 1).fill()
                }
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "si-notch"
        return image
    }
}
