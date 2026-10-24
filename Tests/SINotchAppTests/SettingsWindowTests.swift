import AppKit
import XCTest
@testable import SINotch

final class SettingsWindowTests: XCTestCase {
    @MainActor
    func testFirstOpenBuildsContentAndReopenRecreatesIt() throws {
        _ = NSApplication.shared
        let suite = "si-notch.settings-window-tests." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        let model = AppModel(defaults: preferences)
        let delegate = AppDelegate(model: model)
        defer {
            delegate.settingsWindow?.close()
            model.shutdown()
            preferences.removePersistentDomain(forName: suite)
        }

        delegate.showSettings()
        let window = try XCTUnwrap(delegate.settingsWindow)
        let firstContent = try XCTUnwrap(window.contentView)
        // AppKit's placeholder NSView has no intrinsic settings layout. Checking
        // the content's fitting size also forces SwiftUI to build the first page.
        XCTAssertGreaterThanOrEqual(firstContent.fittingSize.width, 820)
        XCTAssertGreaterThanOrEqual(firstContent.fittingSize.height, 660)
        XCTAssertTrue(window.isVisible)

        delegate.showSettings()
        XCTAssertTrue(window.contentView === firstContent, "Opening an already visible window preserves its state")

        window.close()
        XCTAssertNil(window.contentView, "Closing releases live settings observers")
        XCTAssertFalse(delegate.settingsPresented)

        delegate.showSettings()
        let reopenedContent = try XCTUnwrap(window.contentView)
        XCTAssertFalse(reopenedContent === firstContent)
        XCTAssertGreaterThanOrEqual(reopenedContent.fittingSize.width, 820)
        XCTAssertGreaterThanOrEqual(reopenedContent.fittingSize.height, 660)
        XCTAssertTrue(delegate.settingsPresented)
        XCTAssertTrue(window.isVisible)
    }
}
