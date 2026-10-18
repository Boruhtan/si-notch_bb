import Foundation
import XCTest
import SINotchCore
@testable import SINotch

final class IslandPreviewTests: XCTestCase {
    @MainActor func testOpeningDisplayNeverChangesLiveDefaultsOrCodexDetection() {
        let live = AppModel()
        let keys = ["codexAutoDetect", "sound", "autoExpand", "attentionReveal", "completionReveal", "blockedDirectories", "blockedPromptPrefixes"]
        let before = keys.map { UserDefaults.standard.object(forKey: $0) }
        let registration = UserDefaults.standard.volatileDomain(forName: UserDefaults.registrationDomain) as NSDictionary
        for _ in 0..<3 {
            let preview = IslandPreviewModel()
            preview.setStatus(.completed)
            XCTAssertFalse(preview.model.defaults.bool(forKey: "codexAutoDetect"))
            XCTAssertEqual(UserDefaults.standard.volatileDomain(forName: UserDefaults.registrationDomain) as NSDictionary, registration)
            for (key, value) in zip(keys, before) {
                XCTAssertEqual(String(describing: live.defaults.object(forKey: key)), String(describing: value), key)
            }
        }
    }

    @MainActor func testPreviewNeverStartsServicesOrCreatesPendingRequests() {
        let preview = IslandPreviewModel()
        for status: AgentStatus in [.working, .waiting, .completed] {
            preview.setStatus(status)
            XCTAssertNil(preview.model.server)
            XCTAssertNil(preview.model.timer)
            XCTAssertNil(preview.model.codexObserver)
            XCTAssertNil(preview.model.expansionTimer)
            XCTAssertNil(preview.model.revealTimer)
            XCTAssertTrue(preview.model.pending.isEmpty)
            XCTAssertEqual(preview.model.sessions.map(\.id), ["preview-design"])
            XCTAssertEqual(preview.model.sessions.first?.status, status)
            XCTAssertFalse(preview.model.defaults.bool(forKey: "sound"))
            XCTAssertFalse(preview.model.defaults.bool(forKey: "codexAutoDetect"))
        }
    }

    @MainActor func testLayoutAndWidthUseActualIslandGeometry() {
        let preview = IslandPreviewModel()
        preview.setAvailableWidth(532)
        XCTAssertEqual(preview.visibleWidth, 420)
        XCTAssertEqual(preview.model.expandedPanelWidth, 420)
        XCTAssertTrue(preview.model.expanded)
        preview.setLayout(.compact)
        XCTAssertFalse(preview.model.expanded)
        XCTAssertEqual(preview.visibleHeight, preview.model.headerHeight)
        XCTAssertEqual(preview.visibleWidth, preview.model.cameraWidth + preview.model.compactWingWidth + preview.model.compactStatusWidth + preview.model.compactShoulderWidth * 2)
        preview.setAvailableWidth(.nan)
        XCTAssertTrue(preview.visibleWidth.isFinite)
        preview.setLayout(.expanded)
        XCTAssertEqual(preview.visibleHeight, preview.model.expandedPanelHeight)
    }

    @MainActor func testOnlySupportedSampleStatesAreAccepted() {
        let preview = IslandPreviewModel()
        preview.setStatus(.approval)
        XCTAssertEqual(preview.status, .working)
        XCTAssertTrue(preview.model.pending.isEmpty)
        XCTAssertNil(preview.model.sessions.first?.projectPath)
        XCTAssertNil(preview.model.sessions.first?.targetURL)
    }

    func testAppearanceDefaultAndTransparencyFallback() {
        XCTAssertEqual(IslandAppearance.resolve("old-value"), .opaque)
        XCTAssertEqual(IslandAppearance.resolve("glass"), .opaque)
        XCTAssertEqual(IslandAppearance.resolve("frosted"), .opaque)
        for appearance in IslandAppearance.allCases {
            XCTAssertEqual(appearance.effective(reduceTransparency: true), .opaque)
            XCTAssertEqual(appearance.effective(reduceTransparency: false), appearance)
        }
    }
}
