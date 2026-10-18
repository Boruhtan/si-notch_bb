import AppKit
import XCTest
@testable import SINotch

final class CompanionArtworkTests: XCTestCase {
    @MainActor
    func testNativeLayerUsesBackingPixelGridAndDoesNotAnimateOffscreen() throws {
        let view = CompanionArtwork.SpriteView(frame: CGRect(x: 0, y: 0, width: 22, height: 22))
        view.configure(.init(status: .working, style: .cat, motion: .init(status: .working, at: 0),
            reduceMotion: false, previewTime: 1, displayScale: 2))
        let layer = try XCTUnwrap(view.layer?.sublayers?.first)
        let first = try XCTUnwrap(layer.contents) as! CGImage
        XCTAssertEqual(layer.frame, CGRect(x: 1, y: 1, width: 20, height: 20))
        XCTAssertEqual(layer.contentsScale, 2)
        XCTAssertEqual(first.width, 40)
        XCTAssertFalse(view.isAnimating)
        XCTAssertNil(view.hitTest(.zero), "The SwiftUI companion must keep receiving greetings")
        view.configure(.init(status: .working, style: .cat, motion: .init(status: .working, at: 0),
            reduceMotion: false, previewTime: 1.2, displayScale: 2))
        let next = try XCTUnwrap(layer.contents) as! CGImage
        XCTAssertNotEqual(first.dataProvider?.data, next.dataProvider?.data)
        view.configure(.init(status: .working, style: .cat, motion: .init(status: .working, at: 0),
            reduceMotion: false, displayScale: 2))
        XCTAssertFalse(view.isAnimating, "Detached views must not schedule animation frames")
    }
}
