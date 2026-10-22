import XCTest
@testable import SINotch

final class CodexQuotaControllerTests: XCTestCase {
    @MainActor
    func testStartRefreshesWithoutOpeningViewAndCacheSurvivesErrors() async throws {
        let suite = "si-notch.quota." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("/usr/bin/true", forKey: CodexBinaryLocator.preferenceKey)
        let snapshot = try CodexUsageService.parseRateLimits(Data(#"{"rateLimits":{"limitId":"codex","primary":{"usedPercent":20,"windowDurationMins":300}}}"#.utf8))
        var calls = 0
        let controller = CodexQuotaController(defaults: defaults) { _ in calls += 1; return .limits(snapshot) }
        controller.start()
        for _ in 0..<100 where controller.loading { await Task.yield() }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(controller.status, .limits(snapshot))
        controller.refreshIfNeeded(); XCTAssertEqual(calls, 1)
        controller.stop()
        let reopened = CodexQuotaController(defaults: defaults) { _ in throw CodexUsageError.timedOut }
        XCTAssertEqual(reopened.status, .limits(snapshot))
        reopened.refresh()
        for _ in 0..<100 where reopened.loading { await Task.yield() }
        XCTAssertNotNil(reopened.error)
        XCTAssertEqual(reopened.status, .limits(snapshot), "A network failure must retain the dated last reading")
        reopened.stop()
    }
    @MainActor
    func testSignedOutClearsPersistedQuota() async throws {
        let suite = "si-notch.quota." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("/usr/bin/true", forKey: CodexBinaryLocator.preferenceKey)
        let controller = CodexQuotaController(defaults: defaults) { _ in .signedOut }
        controller.refresh()
        for _ in 0..<100 where controller.loading { await Task.yield() }
        XCTAssertEqual(controller.status, .signedOut)
        XCTAssertNil(defaults.data(forKey: "codexQuotaSnapshot"))
    }
}
