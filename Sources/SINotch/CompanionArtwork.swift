import AppKit
import SwiftUI
import SINotchCore

/// Animation ticks update a small backing layer without invalidating SwiftUI's
/// window hierarchy. The existing schedule owns blink and pose timing.
struct CompanionArtwork: NSViewRepresentable {
    var configuration: Configuration

    struct Configuration: Equatable {
        var status: AgentStatus
        var style: CompanionStyle
        var motion: CompanionPoseTransition
        var greetingStartedAt: Date?
        var reduceMotion: Bool
        var previewTime: TimeInterval?
        var displayScale: Double

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.status == rhs.status && lhs.style == rhs.style &&
            lhs.motion.source == rhs.motion.source && lhs.motion.target == rhs.motion.target &&
            lhs.motion.startedAt == rhs.motion.startedAt && lhs.greetingStartedAt == rhs.greetingStartedAt &&
            lhs.reduceMotion == rhs.reduceMotion && lhs.previewTime == rhs.previewTime &&
            lhs.displayScale == rhs.displayScale
        }
    }

    func makeNSView(context: Context) -> SpriteView { SpriteView() }
    func updateNSView(_ view: SpriteView, context: Context) { view.configure(configuration) }
    static func dismantleNSView(_ view: SpriteView, coordinator: ()) { view.stop() }

    final class SpriteView: NSView {
        private let spriteLayer = CALayer()
        private var configuration: Configuration?
        private var timer: Timer?
        private var visibilityObserver: NSObjectProtocol?
        var isAnimating: Bool { timer?.isValid == true }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = true
            spriteLayer.magnificationFilter = .nearest
            spriteLayer.minificationFilter = .nearest
            layer?.addSublayer(spriteLayer)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        deinit {
            timer?.invalidate()
            if let visibilityObserver { NotificationCenter.default.removeObserver(visibilityObserver) }
        }
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func configure(_ value: Configuration) {
            guard configuration != value else { return }
            configuration = value
            refresh()
        }

        override func layout() {
            super.layout()
            refresh()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            if let window {
                visibilityObserver = NotificationCenter.default.addObserver(
                    forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in self?.refresh() }
                }
            }
            refresh()
        }

        override func viewDidHide() { super.viewDidHide(); timer?.invalidate(); timer = nil }
        override func viewDidUnhide() { super.viewDidUnhide(); refresh() }

        func stop() {
            timer?.invalidate(); timer = nil
            if let visibilityObserver { NotificationCenter.default.removeObserver(visibilityObserver) }
            visibilityObserver = nil
        }

        private func refresh() {
            timer?.invalidate(); timer = nil
            guard let config = configuration, bounds.width > 0, bounds.height > 0 else { return }
            let date = Date()
            let time = config.previewTime ?? date.timeIntervalSinceReferenceDate
            let pose = config.previewTime == nil
                ? config.motion.value(at: time, reduceMotion: config.reduceMotion) : CompanionPose.target(config.status)
            let sprite = PixelCompanion.frame(style: config.style, status: config.status, time: time,
                stateAge: config.previewTime ?? max(0, time - config.motion.startedAt),
                greetingAge: config.greetingStartedAt.map { max(0, date.timeIntervalSince($0)) },
                reduceMotion: config.reduceMotion,
                detailed: min(bounds.width, bounds.height) * config.displayScale >= 40)
            let grid = PixelCompanionLayout(width: bounds.width, height: bounds.height,
                displayScale: config.displayScale, side: sprite.dimension)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            spriteLayer.frame = CGRect(x: grid.originX, y: grid.originY,
                width: Double(sprite.dimension) * grid.cell, height: Double(sprite.dimension) * grid.cell)
            spriteLayer.contentsScale = config.displayScale
            spriteLayer.contents = CompanionRaster.image(sprite: sprite, pose: pose,
                pixelsPerCell: Int((grid.cell * config.displayScale).rounded()))
            spriteLayer.opacity = Float(pose.opacity)
            CATransaction.commit()

            guard window?.occlusionState.contains(.visible) == true, !isHiddenOrHasHiddenAncestor else { return }
            let schedule = CompanionTimelineSchedule(status: config.status, motion: config.motion,
                greetingStartedAt: config.greetingStartedAt, paused: config.reduceMotion || config.previewTime != nil)
            guard let next = schedule.nextUpdate(after: date) else { return }
            let timer = Timer(timeInterval: max(0.001, next.timeIntervalSinceNow), repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }
}
