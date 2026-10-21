import AppKit

enum StatusBarIcon {
    static func make(style: CompanionStyle) -> NSImage {
        // Draw at menu-bar size, with enough space between facial features for
        // a 1x display. Template tinting also handles selected menu items.
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: true) { _ in
            NSGraphicsContext.current?.shouldAntialias = true
            NSColor.black.setFill()
            NSColor.black.setStroke()
            switch style {
            case .cat: drawCat()
            case .robot: drawRobot()
            case .sprout: drawSprout()
            case .ghost: drawGhost()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "si-notch"
        return image
    }

    private static func outline(_ path: NSBezierPath, width: CGFloat = 1.35) {
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }

    private static func eye(_ x: CGFloat, _ y: CGFloat, height: CGFloat = 2.4) {
        NSBezierPath(ovalIn: NSRect(x: x, y: y, width: 1.8, height: height)).fill()
    }

    private static func smile(at y: CGFloat) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 8.4, y: y))
        path.curve(to: NSPoint(x: 11.6, y: y),
                   controlPoint1: NSPoint(x: 9, y: y + 1.7), controlPoint2: NSPoint(x: 11, y: y + 1.7))
        outline(path, width: 1)
    }

    private static func drawCat() {
        let head = NSBezierPath()
        head.move(to: NSPoint(x: 2.8, y: 8))
        head.line(to: NSPoint(x: 2.4, y: 2.1))
        head.curve(to: NSPoint(x: 3.5, y: 1.6),
                   controlPoint1: NSPoint(x: 2.3, y: 1.2), controlPoint2: NSPoint(x: 2.8, y: 1.1))
        head.line(to: NSPoint(x: 6.7, y: 4.2))
        head.curve(to: NSPoint(x: 13.3, y: 4.2),
                   controlPoint1: NSPoint(x: 8.8, y: 3.3), controlPoint2: NSPoint(x: 11.2, y: 3.3))
        head.line(to: NSPoint(x: 16.5, y: 1.6))
        head.curve(to: NSPoint(x: 17.6, y: 2.1),
                   controlPoint1: NSPoint(x: 17.2, y: 1.1), controlPoint2: NSPoint(x: 17.7, y: 1.2))
        head.line(to: NSPoint(x: 17.2, y: 8))
        head.curve(to: NSPoint(x: 18, y: 11),
                   controlPoint1: NSPoint(x: 17.8, y: 9), controlPoint2: NSPoint(x: 18, y: 9.8))
        head.curve(to: NSPoint(x: 10, y: 16.2),
                   controlPoint1: NSPoint(x: 18, y: 14.4), controlPoint2: NSPoint(x: 14.2, y: 16.2))
        head.curve(to: NSPoint(x: 2, y: 11),
                   controlPoint1: NSPoint(x: 5.8, y: 16.2), controlPoint2: NSPoint(x: 2, y: 14.4))
        head.curve(to: NSPoint(x: 2.8, y: 8),
                   controlPoint1: NSPoint(x: 2, y: 9.8), controlPoint2: NSPoint(x: 2.2, y: 9))
        head.close()
        outline(head)
        eye(5.8, 8.1)
        eye(12.4, 8.1)
        let nose = NSBezierPath()
        nose.move(to: NSPoint(x: 9, y: 10.8))
        nose.line(to: NSPoint(x: 11, y: 10.8))
        nose.line(to: NSPoint(x: 10, y: 11.9))
        nose.close()
        nose.fill()
        let mouth = NSBezierPath()
        mouth.move(to: NSPoint(x: 7.8, y: 12.4))
        mouth.curve(to: NSPoint(x: 10, y: 11.9),
                    controlPoint1: NSPoint(x: 8.3, y: 13.7), controlPoint2: NSPoint(x: 10, y: 13.4))
        mouth.curve(to: NSPoint(x: 12.2, y: 12.4),
                    controlPoint1: NSPoint(x: 10, y: 13.4), controlPoint2: NSPoint(x: 11.7, y: 13.7))
        outline(mouth, width: 0.9)
        let whiskers = NSBezierPath()
        for (outer, inner) in [(CGFloat(0.8), CGFloat(4.5)), (19.2, 15.5)] {
            whiskers.move(to: NSPoint(x: outer, y: 10.9))
            whiskers.line(to: NSPoint(x: inner, y: 11.5))
            whiskers.move(to: NSPoint(x: outer, y: 13.4))
            whiskers.line(to: NSPoint(x: inner, y: 12.8))
        }
        outline(whiskers, width: 0.9)
    }

    private static func drawRobot() {
        let antenna = NSBezierPath()
        antenna.move(to: NSPoint(x: 10, y: 2.5))
        antenna.line(to: NSPoint(x: 10, y: 5))
        outline(antenna)
        NSBezierPath(ovalIn: NSRect(x: 8.6, y: 0.8, width: 2.8, height: 2.8)).fill()
        outline(NSBezierPath(roundedRect: NSRect(x: 2.6, y: 5, width: 14.8, height: 11.2), xRadius: 3.2, yRadius: 3.2))
        for x: CGFloat in [0.5, 18.2] {
            NSBezierPath(roundedRect: NSRect(x: x, y: 8.5, width: 1.3, height: 4), xRadius: 0.65, yRadius: 0.65).fill()
        }
        eye(5.9, 8.2, height: 3)
        eye(12.3, 8.2, height: 3)
        smile(at: 12.5)
    }

    private static func drawSprout() {
        let leaves = NSBezierPath()
        leaves.move(to: NSPoint(x: 10, y: 7.1))
        leaves.curve(to: NSPoint(x: 3.4, y: 1.1),
                     controlPoint1: NSPoint(x: 4.3, y: 7.2), controlPoint2: NSPoint(x: 3, y: 3.7))
        leaves.curve(to: NSPoint(x: 10, y: 7.1),
                     controlPoint1: NSPoint(x: 7.8, y: 0.8), controlPoint2: NSPoint(x: 10, y: 3.5))
        leaves.curve(to: NSPoint(x: 16.6, y: 1.1),
                     controlPoint1: NSPoint(x: 10, y: 3.5), controlPoint2: NSPoint(x: 12.2, y: 0.8))
        leaves.curve(to: NSPoint(x: 10, y: 7.1),
                     controlPoint1: NSPoint(x: 17, y: 3.7), controlPoint2: NSPoint(x: 15.7, y: 7.2))
        leaves.close()
        leaves.fill()
        let pot = NSBezierPath()
        pot.move(to: NSPoint(x: 3.6, y: 8.5))
        pot.line(to: NSPoint(x: 5, y: 14.8))
        pot.curve(to: NSPoint(x: 6.8, y: 16.3),
                  controlPoint1: NSPoint(x: 5.2, y: 15.9), controlPoint2: NSPoint(x: 5.8, y: 16.3))
        pot.line(to: NSPoint(x: 13.2, y: 16.3))
        pot.curve(to: NSPoint(x: 15, y: 14.8),
                  controlPoint1: NSPoint(x: 14.2, y: 16.3), controlPoint2: NSPoint(x: 14.8, y: 15.9))
        pot.line(to: NSPoint(x: 16.4, y: 8.5))
        pot.close()
        outline(pot)
        let rim = NSBezierPath()
        rim.move(to: NSPoint(x: 2.9, y: 8.5))
        rim.line(to: NSPoint(x: 17.1, y: 8.5))
        outline(rim, width: 1.6)
        eye(6.6, 10.3, height: 1.9)
        eye(11.6, 10.3, height: 1.9)
        smile(at: 13.1)
    }

    private static func drawGhost() {
        let body = NSBezierPath()
        body.move(to: NSPoint(x: 3, y: 8.5))
        body.curve(to: NSPoint(x: 10, y: 1.6),
                   controlPoint1: NSPoint(x: 3, y: 4.1), controlPoint2: NSPoint(x: 5.6, y: 1.6))
        body.curve(to: NSPoint(x: 17, y: 8.5),
                   controlPoint1: NSPoint(x: 14.4, y: 1.6), controlPoint2: NSPoint(x: 17, y: 4.1))
        body.line(to: NSPoint(x: 17, y: 15.8))
        body.curve(to: NSPoint(x: 12.3, y: 15.8),
                   controlPoint1: NSPoint(x: 15.8, y: 13.7), controlPoint2: NSPoint(x: 14.2, y: 18))
        body.curve(to: NSPoint(x: 7.7, y: 15.8),
                   controlPoint1: NSPoint(x: 10.7, y: 14), controlPoint2: NSPoint(x: 9.3, y: 14))
        body.curve(to: NSPoint(x: 3, y: 15.8),
                   controlPoint1: NSPoint(x: 5.8, y: 18), controlPoint2: NSPoint(x: 4.2, y: 13.7))
        body.close()
        outline(body)
        eye(6, 7.3, height: 2.9)
        eye(12.2, 7.3, height: 2.9)
        smile(at: 11.6)
    }
}
