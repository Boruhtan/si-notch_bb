import AppKit
import SINotchCore

/// The OS adapter for IslandPresentationPolicy. It observes app/Space changes
/// and mouse buttons only; it does not request Accessibility, Input Monitoring,
/// or Screen Recording access and never reads another application's settings.
@MainActor
final class PresentationPolicy {
    static let registeredDefaults: [String: Any] = [
        "hideWhenIdle": false,
        "hideInFullScreen": true,
        "suppressWhenTargetAppFrontmost": true,
        "dismissAutoRevealOnOutsideClick": false,
        "disableClickJump": false,
        "collapseOnMouseLeave": true
    ]

    private let defaults: UserDefaults
    private let readState: () -> IslandPresentationState
    private let panel: () -> NSWindow?
    private let onVisibilityChange: (Bool) -> Void
    private let onAutoDismiss: () -> Void
    private let now: () -> TimeInterval
    private var policy: IslandPresentationPolicy
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var timer: Timer?
    private var started = false
    private(set) var currentDecision: IslandPresentationDecision?

    init(defaults: UserDefaults = .standard,
         state: @escaping () -> IslandPresentationState,
         panel: @escaping () -> NSWindow?,
         onVisibilityChange: @escaping (Bool) -> Void,
         onAutoDismiss: @escaping () -> Void,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.defaults = defaults
        readState = state
        self.panel = panel
        self.onVisibilityChange = onVisibilityChange
        self.onAutoDismiss = onAutoDismiss
        self.now = now
        policy = IslandPresentationPolicy(now: now())
        defaults.register(defaults: Self.registeredDefaults)
    }

    var options: IslandPresentationOptions {
        var value = IslandPresentationOptions()
        value.hideWhenIdle = defaults.bool(forKey: "hideWhenIdle")
        value.hideInFullScreen = defaults.bool(forKey: "hideInFullScreen")
        value.suppressWhenTargetAppFrontmost = defaults.bool(forKey: "suppressWhenTargetAppFrontmost")
        value.dismissAutoRevealOnOutsideClick = defaults.bool(forKey: "dismissAutoRevealOnOutsideClick")
        value.disableClickJump = defaults.bool(forKey: "disableClickJump")
        value.collapseOnMouseLeave = defaults.bool(forKey: "collapseOnMouseLeave")
        return value
    }

    var canJump: Bool { policy.canJump(options: options) }
    var canCollapseOnMouseLeave: Bool {
        policy.canCollapseOnMouseLeave(options: options, state: snapshot())
    }
    var expansionOrigin: IslandExpansionOrigin? { policy.expansionOrigin }

    func start() {
        guard !started else { return }
        started = true
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didActivateApplicationNotification)
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.activeSpaceDidChangeNotification)
        observe(NotificationCenter.default, UserDefaults.didChangeNotification)
        // A foreground app can enter native fullscreen without activating again.
        // Poll the public system presentation flags; no window enumeration needed.
        let tick = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        tick.tolerance = 0.1
        RunLoop.main.add(tick, forMode: .common)
        timer = tick
        let buttons: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: buttons) { [weak self] event in
            let point = NSEvent.mouseLocation
            let windowNumber = event.windowNumber
            Task { @MainActor in self?.mouseDown(at: point, localWindowNumber: windowNumber) }
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: buttons) { [weak self] _ in
            let point = NSEvent.mouseLocation
            Task { @MainActor in self?.mouseDown(at: point, localWindowNumber: nil) }
        }
        refresh(forceVisibilityUpdate: true)
    }

    func stop() {
        started = false
        timer?.invalidate()
        timer = nil
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        localMouseMonitor = nil
        globalMouseMonitor = nil
    }

    /// Refresh after changing pending/working state or Settings visibility. Layout
    /// alone does not reset the idle clock. The forced variant reconciles window
    /// ordering after another owner has explicitly ordered the panel out.
    func refresh(forceVisibilityUpdate: Bool = false) {
        guard started else { return }
        let next = policy.decision(options: options, state: snapshot(), at: now())
        let changed = next.isVisible != currentDecision?.isVisible
        currentDecision = next
        if changed || forceVisibilityUpdate { onVisibilityChange(next.isVisible) }
    }

    func noteActivity() {
        policy.noteActivity(at: now())
        refresh()
    }

    /// Call even when the Bool was already true: a manual action can take over
    /// an automatic expansion without causing a second frame animation.
    func expansionChanged(_ expanded: Bool, origin: IslandExpansionOrigin) {
        policy.expansionChanged(expanded, origin: origin, at: now())
        refresh()
    }

    func canAutomaticallyReveal(for session: AgentSession?) -> Bool {
        policy.canAutomaticallyReveal(options: options, state: snapshot(),
            targetBundleID: targetBundleID(for: session),
            frontmostBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }

    private func snapshot() -> IslandPresentationState {
        var state = readState()
        // Unlike NSApp.presentationOptions, this is the foreground application's
        // effective system state (documented in NSApplication.h).
        state.isNativeFullScreen = NSApp.currentSystemPresentationOptions.contains(.fullScreen)
        return state
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name) {
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        observers.append((center, observer))
    }

    private func mouseDown(at point: NSPoint, localWindowNumber: Int?) {
        guard started, let window = panel(), window.isVisible else { return }
        let inside = localWindowNumber.map { $0 == window.windowNumber } ?? window.frame.contains(point)
        if inside { noteActivity(); return }
        guard policy.shouldDismissForOutsideClick(options: options, state: snapshot()) else { return }
        onAutoDismiss()
    }

    /// App-level approximation only: it cannot identify a terminal tab. Use the
    /// same explicit URL target priority as AppModel.jump; never infer a provider.
    private func targetBundleID(for session: AgentSession?) -> String? {
        guard let session else { return nil }
        if let raw = session.targetURL, let url = URL(string: raw),
           let scheme = url.scheme?.lowercased(), ["codex", "vscode", "cursor", "zed", "ghostty"].contains(scheme),
           let appURL = NSWorkspace.shared.urlForApplication(toOpen: url),
           let identifier = Bundle(url: appURL)?.bundleIdentifier { return identifier }
        return session.terminalBundleID
    }
}
