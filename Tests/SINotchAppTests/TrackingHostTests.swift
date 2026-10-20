import AppKit
import SwiftUI
import XCTest
@testable import SINotch

final class TrackingHostTests: XCTestCase {
    @MainActor
    func testMotionAfterPausingBelowTheIslandKeepsItsOriginAndIgnoresDuplicateDelivery() throws {
        _ = NSApplication.shared
        let frame = CGRect(x: 100, y: 100, width: 200, height: 33)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        let host = TrackingHost(rootView: Color.clear)
        var point = CGPoint(x: 200, y: 70)
        host.pointerLocation = { point }
        host.interactionFrame = frame
        var entries: [Bool] = []
        var movements: [(CGPoint, CGPoint)] = []
        host.onHover = { entries.append($0) }
        host.onPointerMove = { movements.append(($0, $1)) }
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        let start = ProcessInfo.processInfo.systemUptime + 1
        func event(at time: TimeInterval) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: time,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 0, pressure: 0))
        }
        host.mouseMoved(with: try event(at: start))
        point = CGPoint(x: 200, y: 89)
        let approach = try event(at: start + 10)
        host.mouseMoved(with: approach)
        host.mouseMoved(with: approach) // Local monitor and tracking-area delivery share one event.
        host.updateTrackingAreas() // Layout without motion must not manufacture another approach.
        XCTAssertEqual(entries, [true])
        XCTAssertEqual(movements.count, 1)
        XCTAssertEqual(movements.first?.0, CGPoint(x: 200, y: 70))
        XCTAssertEqual(movements.first?.1, point)
    }
}
