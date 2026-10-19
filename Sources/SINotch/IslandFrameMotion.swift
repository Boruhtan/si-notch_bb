import SwiftUI

/// SwiftUI's native spring model drives the AppKit frame as well as the content.
/// Both axes share one response so the outline grows as one surface. Every
/// component carries its velocity into an interrupted or reversed transition.
struct IslandFrameMotion {
    struct Velocity {
        var center: Double = 0
        var width: Double = 0
        var height: Double = 0
    }

    let origin: CGRect
    let destination: CGRect
    let initialVelocity: Velocity
    private let widthSpring: Spring
    private let heightSpring: Spring
    private let centerSpring: Spring

    init(origin: CGRect, destination: CGRect, expanding: Bool, initialVelocity: Velocity = .init()) {
        self.origin = origin
        self.destination = destination
        self.initialVelocity = initialVelocity
        let response = Spring(duration: expanding ? 0.40 : 0.28, bounce: 0)
        widthSpring = response
        heightSpring = response
        centerSpring = response
    }

    func frame(at time: TimeInterval) -> CGRect {
        let width = max(1, origin.width + widthSpring.value(target: destination.width - origin.width,
                                                         initialVelocity: initialVelocity.width, time: max(0, time)))
        let height = max(1, origin.height + heightSpring.value(target: destination.height - origin.height,
                                                             initialVelocity: initialVelocity.height, time: max(0, time)))
        let center = origin.midX + centerSpring.value(target: destination.midX - origin.midX,
                                                     initialVelocity: initialVelocity.center, time: max(0, time))
        // The top stays attached to the camera even during the downward bounce.
        return CGRect(x: center - width / 2, y: destination.maxY - height, width: width, height: height)
    }

    func velocity(at time: TimeInterval) -> Velocity {
        Velocity(center: centerSpring.velocity(target: destination.midX - origin.midX,
                                               initialVelocity: initialVelocity.center, time: max(0, time)),
                 width: widthSpring.velocity(target: destination.width - origin.width,
                                             initialVelocity: initialVelocity.width, time: max(0, time)),
                 height: heightSpring.velocity(target: destination.height - origin.height,
                                               initialVelocity: initialVelocity.height, time: max(0, time)))
    }

    func isSettled(at time: TimeInterval) -> Bool {
        let frame = frame(at: time)
        let velocity = velocity(at: time)
        return abs(frame.width - destination.width) < 0.15 && abs(frame.height - destination.height) < 0.15 &&
            abs(frame.midX - destination.midX) < 0.15 &&
            abs(velocity.width) < 2 && abs(velocity.height) < 2 && abs(velocity.center) < 2
    }
}
