import AppKit

enum StatusBarIcon {
    static func make() -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            let display = NSBezierPath(roundedRect: NSRect(x: 1, y: 3, width: 18, height: 12), xRadius: 3, yRadius: 3)
            display.lineWidth = 1.5
            display.stroke()
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: 6, y: 11, width: 8, height: 4), xRadius: 1.5, yRadius: 1.5).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "si-notch"
        return image
    }
}
