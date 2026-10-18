import AppKit
import SINotchCore

/// AppKit owns the outer window; SwiftUI only animates the content inside it.
/// Sampling monotonic time avoids stretching an animation when a frame is late.
@MainActor
final class IslandWindowAnimator {
    private weak var window: NSWindow?
    private let origin: NSRect
    private let destination: NSRect
    private let spring: IslandSpring
    private let framesPerSecond: Double
    private var timer: Timer?
    private var began: TimeInterval = 0
    private let duration: TimeInterval
    var isRunning: Bool { timer != nil }

    init(window: NSWindow, destination: NSRect, response: TimeInterval, framesPerSecond: Int) {
        self.window = window
        origin = window.frame
        self.destination = destination
        spring = IslandSpring(response: response)
        self.framesPerSecond = Double(max(30, min(120, framesPerSecond)))
        let distance = [abs(origin.minX - destination.minX), abs(origin.minY - destination.minY),
                        abs(origin.width - destination.width), abs(origin.height - destination.height)].max() ?? 0
        duration = spring.settlingDuration(maximumDistance: Double(distance), pixelThreshold: 0.15)
    }

    func start() {
        stop()
        began = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1 / framesPerSecond, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        step()
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func step() {
        guard let window else { stop(); return }
        let elapsed = ProcessInfo.processInfo.systemUptime - began
        if elapsed >= duration {
            window.setFrame(destination, display: true, animate: false)
            stop()
            return
        }
        let progress = CGFloat(spring.value(at: elapsed).progress)
        func lerp(_ start: CGFloat, _ end: CGFloat) -> CGFloat { start + (end - start) * progress }
        // NSWindow rounds fractional point sizes independently of the origin.
        // Round once here, then derive y from the fixed top and rounded height.
        func snap(_ value: CGFloat) -> CGFloat { value.rounded() }
        let width = snap(lerp(origin.width, destination.width))
        let height = snap(lerp(origin.height, destination.height))
        let center = lerp(origin.midX, destination.midX)
        let top = snap(lerp(origin.maxY, destination.maxY))
        window.setFrame(NSRect(x: snap(center - width / 2), y: top - height, width: width, height: height),
                        display: true, animate: false)
    }
}
