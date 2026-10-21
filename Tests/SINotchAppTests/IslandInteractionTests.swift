import AppKit
import SwiftUI
import XCTest
import SINotchCore
@testable import SINotch

final class IslandInteractionTests: XCTestCase {
    @MainActor
    func testClearKeepsPanelOpenAtStationaryFooterAndClosesOnRealLeave() async throws {
        for sessionsOnly in [false, true] {
            let fixture = try Fixture(sessionsOnly: sessionsOnly)
            defer { fixture.close() }
            let oldFrame = fixture.delegate.panel.frame
            try fixture.move(to: CGPoint(x: oldFrame.maxX - 80, y: oldFrame.minY + 18))
            XCTAssertTrue(fixture.model.pointerInside)
            fixture.model.clearFinished()
            XCTAssertTrue(fixture.model.sessions.isEmpty)
            XCTAssertLessThan(fixture.delegate.panel.frame.height, oldFrame.height)
            XCTAssertTrue(fixture.model.pointerInside, "Content moved, the pointer did not leave")
            try await Task.sleep(for: .milliseconds(350))
            XCTAssertTrue(fixture.model.expanded, "Clear must preserve the user's interaction, including session-only mode")
            XCTAssertTrue(fixture.delegate.panel.isVisible)
            // Movement toward the smaller panel must remain usable at any speed.
            try fixture.move(to: CGPoint(x: oldFrame.midX, y: oldFrame.minY + 35))
            try await Task.sleep(for: .milliseconds(350))
            XCTAssertTrue(fixture.model.expanded)
            try fixture.move(to: CGPoint(x: oldFrame.midX, y: oldFrame.minY - 20))
            try await Task.sleep(for: .milliseconds(350))
            XCTAssertFalse(fixture.model.expanded, "Leaving the previous occupied area still closes normally")
            XCTAssertEqual(fixture.delegate.panel.isVisible, !sessionsOnly)
        }
    }

    @MainActor
    func testReturningToResizedPanelReleasesOldHoverArea() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let oldFrame = fixture.delegate.panel.frame
        let footer = CGPoint(x: oldFrame.maxX - 80, y: oldFrame.minY + 18)
        try fixture.move(to: footer)
        fixture.model.clearFinished()
        let smaller = fixture.delegate.panel.frame
        try fixture.move(to: CGPoint(x: smaller.midX, y: smaller.midY))
        XCTAssertTrue(fixture.model.pointerInside)
        try fixture.move(to: footer)
        XCTAssertFalse(fixture.model.pointerInside, "The old area is only a bridge back into the panel")
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertFalse(fixture.model.expanded)
        try fixture.move(to: footer)
        XCTAssertFalse(fixture.model.pointerInside, "A collapsed island never inherits the expanded hover area")
        XCTAssertNil(fixture.model.expansionTimer)
    }

    @MainActor
    func testExplicitCollapseDiscardsResizeBridgeImmediately() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let frame = fixture.delegate.panel.frame
        let footer = CGPoint(x: frame.maxX - 80, y: frame.minY + 18)
        try fixture.move(to: footer)
        fixture.model.clearFinished()
        XCTAssertTrue(fixture.model.pointerInside)
        fixture.model.setExpanded(false)
        XCTAssertFalse(fixture.model.pointerInside)
        XCTAssertFalse(fixture.host.containsHoverPoint(footer))
        try fixture.move(to: footer)
        XCTAssertNil(fixture.model.expansionTimer)
        XCTAssertFalse(fixture.model.expanded)
    }

    @MainActor
    private final class Fixture {
        let model: AppModel
        let delegate: AppDelegate
        let host: TrackingHost<IslandView>
        let suite = "si-notch.clear-tests." + UUID().uuidString
        var point = CGPoint(x: -10000, y: -10000)
        var time = ProcessInfo.processInfo.systemUptime

        init(sessionsOnly: Bool = false) throws {
            _ = NSApplication.shared
            guard NSScreen.main != nil else { throw XCTSkip("Requires a window server") }
            let defaults = UserDefaults(suiteName: suite)!
            defaults.set(sessionsOnly, forKey: "showOnlyWithSessions")
            defaults.set(false, forKey: "sound")
            defaults.set(false, forKey: "keepOpen")
            model = AppModel(defaults: defaults)
            for id in ["one", "two", "three"] {
                model.store.apply(AgentEvent(sessionID: id, provider: "custom", kind: .completed, title: "Completed"))
                model.measuredSessionHeights[id] = 140
            }
            delegate = AppDelegate(model: model)
            delegate.panel = IslandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                         backing: .buffered, defer: false)
            host = TrackingHost(rootView: IslandView(model: model))
            host.sizingOptions = []
            delegate.panel.contentView = host
            host.pointerLocation = { [unowned self] in point }
            host.pointerButtons = { 0 }
            model.hoverLocation = { [unowned self] in point }
            model.hoverHitTest = { [weak host] in host?.containsHoverPoint($0) ?? false }
            host.onHover = { [weak model] in model?.hover($0) }
            model.onLayout = { [weak delegate, weak model] in
                model?.presentationPolicy?.refresh()
                delegate?.layout(allowAnimation: false)
            }
            model.presentationPolicy = PresentationPolicy(defaults: defaults,
                state: { [unowned model] in model.presentationState }, panel: { [weak delegate] in delegate?.panel },
                onVisibilityChange: { [weak delegate] in delegate?.applyIslandVisibility($0) },
                onAutoDismiss: {}, fullScreen: { false })
            model.presentationPolicy?.start()
            model.setExpanded(true, origin: .hover)
            delegate.layout(allowAnimation: false)
            delegate.panel.orderFront(nil)
        }

        func move(to destination: CGPoint) throws {
            point = destination
            time += 1
            host.mouseMoved(with: try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: .zero,
                modifierFlags: [], timestamp: time, windowNumber: delegate.panel.windowNumber,
                context: nil, eventNumber: 1, clickCount: 0, pressure: 0)))
        }

        func close() {
            model.onLayout = nil
            host.onHover = nil
            model.presentationPolicy?.stop()
            model.shutdown()
            delegate.panel.orderOut(nil)
            delegate.panel.contentView = nil
            model.defaults.removePersistentDomain(forName: suite)
        }
    }
}
