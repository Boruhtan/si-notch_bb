import AppKit
import XCTest
import SINotchCore
@testable import SINotch

final class FullScreenTests: XCTestCase {
    func testDisplayCoverageAllowsCameraInsetButRejectsMaximizedAndOtherDisplayWindows() {
        let display = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        XCTAssertTrue(FullScreenDetector.coversDisplay(display, display: display, topInset: 37))
        XCTAssertTrue(FullScreenDetector.coversDisplay(CGRect(x: 0, y: 37, width: 1728, height: 1080), display: display, topInset: 37))
        XCTAssertFalse(FullScreenDetector.coversDisplay(CGRect(x: 0, y: 38, width: 1728, height: 1000), display: display, topInset: 37))
        XCTAssertFalse(FullScreenDetector.coversDisplay(CGRect(x: 1728, y: 0, width: 1728, height: 1117), display: display, topInset: 37))
        let external = CGRect(x: -1920, y: -200, width: 1920, height: 1080)
        XCTAssertTrue(FullScreenDetector.coversDisplay(external, display: external, topInset: 0))
    }

    @MainActor
    func testEnteringFullscreenDismissesExistingExpansionAndHoverRevealsThenHides() async throws {
        _ = NSApplication.shared
        let model = AppModel(defaults: UserDefaults(suiteName: "si-notch.fullscreen-tests." + UUID().uuidString)!)
        var fullScreen = false
        var visible = false
        let adapter = PresentationPolicy(defaults: model.defaults, state: { model.presentationState }, panel: { nil },
            onVisibilityChange: { visible = $0 }, onAutoDismiss: {}, fullScreen: { fullScreen },
            onFullScreenChange: { _ in model.hover(false); model.setExpanded(false, origin: .automatic) })
        model.presentationPolicy = adapter
        model.onLayout = { adapter.refresh() }
        defer { adapter.stop(); model.presentationPolicy = nil; model.shutdown() }
        adapter.start()
        model.setExpanded(true)
        XCTAssertTrue(visible)
        fullScreen = true
        adapter.refresh()
        XCTAssertFalse(model.expanded)
        XCTAssertFalse(visible)
        XCTAssertFalse(adapter.canAutomaticallyReveal(for: nil))
        model.hoverLocation = { .zero }
        model.hover(true)
        try await Task.sleep(for: .milliseconds(260))
        XCTAssertTrue(model.expanded)
        XCTAssertTrue(visible)
        model.defaults.set(true, forKey: "keepOpen")
        model.defaults.set(false, forKey: "collapseOnMouseLeave")
        model.hover(false)
        try await Task.sleep(for: .milliseconds(370))
        XCTAssertFalse(model.expanded)
        XCTAssertFalse(visible)
        fullScreen = false
        adapter.refresh()
        XCTAssertTrue(visible)
        XCTAssertFalse(model.expanded)
    }

    @MainActor
    func testChangingHiddenReasonReconcilesTheHiddenHoverTarget() {
        _ = NSApplication.shared
        let defaults = UserDefaults(suiteName: "si-notch.fullscreen-tests." + UUID().uuidString)!
        defaults.set(true, forKey: "showOnlyWithSessions")
        var fullscreen = false
        var reconciliations = 0
        let adapter = PresentationPolicy(defaults: defaults, state: { .init() }, panel: { nil },
            onVisibilityChange: { _ in reconciliations += 1 }, onAutoDismiss: {}, fullScreen: { fullscreen })
        adapter.start()
        defer { adapter.stop() }
        XCTAssertEqual(adapter.currentDecision?.hiddenReason, .noSessions)
        fullscreen = true
        adapter.refresh()
        XCTAssertEqual(adapter.currentDecision?.hiddenReason, .fullScreen)
        XCTAssertEqual(reconciliations, 2, "A hidden-to-hidden transition must enable fullscreen hover tracking")
        adapter.refresh()
        XCTAssertEqual(reconciliations, 2, "Routine polling must not interrupt an animation")
        fullscreen = false
        adapter.refresh()
        XCTAssertEqual(reconciliations, 3)
    }
}
