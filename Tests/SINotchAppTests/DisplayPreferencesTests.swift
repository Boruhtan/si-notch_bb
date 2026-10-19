import Foundation
import XCTest
import SINotchCore
@testable import SINotch

final class DisplayPreferencesTests: XCTestCase {
    @MainActor
    func testSessionOnlyVisibilityIsOptInForNewAndResetPreferences() {
        let suite = "si-notch.display-tests." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: preferences)
        defer { model.shutdown() }
        XCTAssertFalse(preferences.bool(forKey: "showOnlyWithSessions"))
        preferences.set(true, forKey: "showOnlyWithSessions")
        DisplayPreferences.reset(in: preferences)
        XCTAssertFalse(preferences.bool(forKey: "showOnlyWithSessions"))
    }

    @MainActor
    func testResetRestoresDisplayWithoutChangingOtherPreferencesOrSessions() {
        let suite = "si-notch.display-tests." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: preferences)
        defer { model.shutdown() }
        for (key, value) in DisplayPreferences.defaults {
            if let flag = value as? Bool { preferences.set(!flag, forKey: key) }
            else if value is String { preferences.set("custom", forKey: key) }
            else { preferences.set(999.0, forKey: key) }
        }
        preferences.set(true, forKey: "compactDetail")
        preferences.set(true, forKey: "quiet")
        preferences.set("ru", forKey: "appLanguage")
        preferences.set("/private/project", forKey: "blockedDirectories")
        preferences.set(false, forKey: "codexAutoDetect")
        preferences.set("beta", forKey: "updateChannel")
        model.store.apply(AgentEvent(sessionID: "task", provider: "custom", kind: .working))

        DisplayPreferences.reset(in: preferences)

        for (key, expected) in DisplayPreferences.defaults {
            XCTAssertEqual(preferences.object(forKey: key) as? NSObject, expected as? NSObject, key)
        }
        XCTAssertNil(preferences.object(forKey: "compactDetail"))
        XCTAssertTrue(preferences.bool(forKey: "quiet"))
        XCTAssertEqual(preferences.string(forKey: "appLanguage"), "ru")
        XCTAssertEqual(preferences.string(forKey: "blockedDirectories"), "/private/project")
        XCTAssertFalse(preferences.bool(forKey: "codexAutoDetect"))
        XCTAssertEqual(preferences.string(forKey: "updateChannel"), "beta")
        XCTAssertEqual(model.sessions.map(\.id), ["task"])
    }

    @MainActor
    func testLegacyCompactTitlePreferenceCannotStretchTheIsland() {
        let suite = "si-notch.display-tests." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: preferences)
        defer { model.shutdown() }
        let width = model.compactWingWidth
        preferences.set(true, forKey: "compactDetail")
        model.store.apply(AgentEvent(sessionID: "task", provider: "custom", kind: .working,
            title: String(repeating: "Long title ", count: 100)))
        XCTAssertEqual(model.compactWingWidth, width)
        XCTAssertEqual(width, 26)
    }

    @MainActor
    func testVisibilityUsesTasksRatherThanConnectionsSearchOrStatusFilters() {
        let suite = "si-notch.display-tests." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: preferences)
        defer { model.shutdown() }
        model.providerReceipts["custom"] = Date()
        model.store.apply(AgentEvent(sessionID: "idle", provider: "custom", kind: .sessionStarted))
        XCTAssertFalse(model.presentationState.hasSessions)
        model.store.apply(AgentEvent(sessionID: "task", provider: "custom", kind: .working, title: "Build"))
        model.activeFilter = "Готово"
        model.search = "No match"
        XCTAssertTrue(model.filtered.isEmpty)
        XCTAssertTrue(model.presentationState.hasSessions)
        XCTAssertTrue(model.presentationState.hasWorkingSessions)
        model.store.apply(AgentEvent(sessionID: "task", provider: "custom", kind: .waiting))
        XCTAssertTrue(model.presentationState.hasSessions)
        XCTAssertFalse(model.presentationState.hasWorkingSessions)
        model.store.apply(AgentEvent(sessionID: "task", provider: "custom", kind: .completed))
        XCTAssertTrue(model.presentationState.hasSessions)
        model.clearFinished()
        XCTAssertFalse(model.presentationState.hasSessions)
        model.store.apply(AgentEvent(sessionID: "task", provider: "custom", kind: .working, projectPath: "/hidden"))
        preferences.set("/hidden", forKey: "blockedDirectories")
        XCTAssertFalse(model.presentationState.hasSessions)
        preferences.set("", forKey: "blockedDirectories")
        model.store.apply(AgentEvent(sessionID: "task", provider: "custom", kind: .sessionEnded))
        XCTAssertFalse(model.presentationState.hasSessions)
    }
}
