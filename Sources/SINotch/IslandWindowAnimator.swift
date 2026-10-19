import AppKit
import QuartzCore

/// AppKit owns the outer window; SwiftUI only animates the content inside it.
/// Display-linked sampling follows the window's actual refresh rate.
@MainActor
final class IslandWindowAnimator: NSObject {
    struct FrameTiming: Codable {
        let callbackTime: TimeInterval
        let targetTime: TimeInterval
        let workSeconds: TimeInterval
    }
    private weak var window: NSWindow?
    private let destination: NSRect
    private let motion: IslandFrameMotion
    private let framesPerSecond: Double
    private var displayLink: CADisplayLink?
    private var began: TimeInterval = 0
    private let onFrame: ((FrameTiming) -> Void)?
    var isRunning: Bool { displayLink != nil }

    var velocity: IslandFrameMotion.Velocity {
        motion.velocity(at: ProcessInfo.processInfo.systemUptime - began)
    }

    init(window: NSWindow, destination: NSRect, expanding: Bool, framesPerSecond: Int,
         initialVelocity: IslandFrameMotion.Velocity = .init(), onFrame: ((FrameTiming) -> Void)? = nil) {
        self.window = window
        self.destination = destination
        motion = IslandFrameMotion(origin: window.frame, destination: destination,
                                   expanding: expanding, initialVelocity: initialVelocity)
        self.framesPerSecond = Double(max(30, min(120, framesPerSecond)))
        self.onFrame = onFrame
        super.init()
    }

    func start() {
        stop()
        guard let window else { return }
        began = ProcessInfo.processInfo.systemUptime
        let link = window.displayLink(target: self, selector: #selector(displayFrame(_:)))
        // Request the current display's rate only for this short transition.
        // Allowing a 30 Hz floor can leave ProMotion motion visibly undersampled.
        let rate = Float(framesPerSecond)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
        displayLink = link
        link.add(to: .main, forMode: .common)
        step()
    }

    func stop() { displayLink?.invalidate(); displayLink = nil }

    @objc private func displayFrame(_ link: CADisplayLink) {
        guard let onFrame else { step(); return }
        let start = ProcessInfo.processInfo.systemUptime
        step()
        onFrame(FrameTiming(callbackTime: start, targetTime: link.targetTimestamp,
                            workSeconds: ProcessInfo.processInfo.systemUptime - start))
    }

    private func step() {
        guard let window else { stop(); return }
        let elapsed = ProcessInfo.processInfo.systemUptime - began
        if motion.isSettled(at: elapsed) || elapsed >= 1.5 {
            window.setFrame(destination, display: true, animate: false)
            stop()
            return
        }
        let frame = motion.frame(at: elapsed)
        // NSWindow rounds fractional point sizes independently of the origin.
        // Round once here, then derive y from the fixed top and rounded height.
        func snap(_ value: CGFloat) -> CGFloat { value.rounded() }
        let width = snap(frame.width)
        let height = snap(frame.height)
        window.setFrame(NSRect(x: snap(frame.midX - width / 2), y: snap(frame.maxY) - height, width: width, height: height),
                        display: false, animate: false)
        // Complete the dirty SwiftUI layout and drawing in this display-link
        // turn. Deferring it lets AppKit pace content separately from the frame.
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }
}
