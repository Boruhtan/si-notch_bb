import AppKit
import SwiftUI
import XCTest
@testable import SINotch

final class TrackingHostTests: XCTestCase {
    @MainActor
    func testPointerBelowVisibleEdgeDoesNotEnter() throws {
        _ = NSApplication.shared
        let frame = CGRect(x: 100, y: 100, width: 200, height: 33)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        let host = TrackingHost(rootView: Color.clear)
        var point = CGPoint(x: 200, y: 70)
        host.pointerLocation = { point }
        host.interactionFrame = frame
        var entries: [Bool] = []
        host.onHover = { entries.append($0) }
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        for (step, y) in [80.0, 89, 99, 99.5].enumerated() {
            point.y = y
            host.mouseMoved(with: try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: .zero,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime + Double(step),
                windowNumber: window.windowNumber, context: nil, eventNumber: step, clickCount: 0, pressure: 0)))
            XCTAssertTrue(entries.isEmpty, "No hover \(100 - y) pt below the visible edge")
        }
    }

    @MainActor
    func testEntryRequiresVisibleSurfaceAndIgnoresDuplicateDelivery() throws {
        _ = NSApplication.shared
        let frame = CGRect(x: 100, y: 100, width: 200, height: 33)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        let host = TrackingHost(rootView: Color.clear)
        var point = CGPoint(x: 200, y: 70)
        host.pointerLocation = { point }
        host.interactionFrame = frame
        var entries: [Bool] = []
        var movements: [CGPoint] = []
        host.onHover = { entries.append($0) }
        host.onPointerMove = { movements.append($0) }
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        let start = ProcessInfo.processInfo.systemUptime + 1
        func event(at time: TimeInterval) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: time,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 0, pressure: 0))
        }
        host.mouseMoved(with: try event(at: start))
        point = CGPoint(x: 200, y: 100.5)
        let approach = try event(at: start + 10)
        host.mouseMoved(with: approach)
        host.mouseMoved(with: approach) // Local monitor and tracking-area delivery share one event.
        host.updateTrackingAreas() // Layout without motion must not manufacture another approach.
        XCTAssertEqual(entries, [true])
        XCTAssertEqual(movements.count, 1)
        XCTAssertEqual(movements.first, point)
    }

    @MainActor
    func testLayoutCannotEnterButShrinkingTargetExitsImmediately() throws {
        _ = NSApplication.shared
        let frame = CGRect(x: 100, y: 100, width: 200, height: 33)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        let host = TrackingHost(rootView: Color.clear)
        host.pointerLocation = { CGPoint(x: 200, y: 110) }
        host.interactionFrame = frame
        var entries: [Bool] = []
        host.onHover = { entries.append($0) }
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        host.updateTrackingAreas()
        XCTAssertTrue(entries.isEmpty, "Showing the island under a parked pointer is not deliberate entry")
        host.mouseMoved(with: try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: .zero,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime + 1,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 0, pressure: 0)))
        XCTAssertEqual(entries, [true])
        host.interactionFrame = CGRect(x: 100, y: 120, width: 200, height: 13)
        XCTAssertEqual(entries, [true, false], "The old, still animating window must not retain hover")
        host.interactionFrame = frame
        XCTAssertEqual(entries, [true, false], "Restoring geometry alone cannot reopen")
    }

    @MainActor
    func testTransparentContourAndDraggingAreExcluded() {
        _ = NSApplication.shared
        let frame = CGRect(x: -500, y: -100, width: 200, height: 33)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        let host = TrackingHost(rootView: Color.clear)
        host.interactionFrame = frame
        host.interactionShape = IslandSilhouette(shoulder: 3, bottomRadius: 13)
        var buttons = 0
        host.pointerButtons = { buttons }
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        XCTAssertFalse(host.containsHoverPoint(CGPoint(x: -499, y: -84)), "Transparent shoulder")
        XCTAssertFalse(host.containsHoverPoint(CGPoint(x: -495, y: -99.5)), "Rounded bottom corner")
        XCTAssertFalse(host.containsHoverPoint(CGPoint(x: -400, y: -100.5)), "Half a point below the bottom")
        let contact = CGPoint(x: -400, y: -99.5)
        XCTAssertTrue(host.containsHoverPoint(contact), "Contact requires no deep penetration")
        buttons = 1
        XCTAssertFalse(host.containsHoverPoint(contact), "Dragging another window must not open the island")
        host.allowsHoverDuringDrag = true
        XCTAssertTrue(host.containsHoverPoint(contact), "Dragging within an already open panel stays usable")
    }

    @MainActor
    func testHiddenFullscreenTargetRequiresExitThenPhysicalReentry() throws {
        _ = NSApplication.shared
        let host = TrackingHost(rootView: Color.clear)
        host.hiddenInteractionFrame = CGRect(x: 100, y: 100, width: 200, height: 33)
        host.tracksHiddenHover = true
        var point = CGPoint(x: 200, y: 110)
        host.pointerLocation = { point }
        var entries: [Bool] = []
        host.onHover = { entries.append($0) }
        host.resetHover(requiringExit: true)
        var time = ProcessInfo.processInfo.systemUptime
        func move() throws {
            time += 1
            host.mouseMoved(with: try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: .zero,
                modifierFlags: [], timestamp: time, windowNumber: 0, context: nil,
                eventNumber: 1, clickCount: 0, pressure: 0)))
        }
        try move()
        XCTAssertEqual(entries, [false])
        point.y = 99.5
        try move()
        XCTAssertEqual(entries, [false], "The area below the hidden notch is not an entry")
        point.y = 100.5
        try move()
        XCTAssertEqual(entries, [false, true])
    }
}
