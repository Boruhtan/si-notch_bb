import Foundation
import XCTest
@testable import SINotch

final class CodexUsageTests: XCTestCase {
    private let officialFixture = #"""
    {
      "rateLimits": {
        "limitId": "codex", "limitName": null,
        "primary": {"usedPercent": 25, "windowDurationMins": 300, "resetsAt": 1792340000},
        "secondary": {"usedPercent": 60, "windowDurationMins": 10080, "resetsAt": 1792700000}
      },
      "rateLimitsByLimitId": {
        "codex": {
          "limitId": "codex", "limitName": null,
          "primary": {"usedPercent": 25, "windowDurationMins": 300, "resetsAt": 1792340000},
          "secondary": {"usedPercent": 60, "windowDurationMins": 10080, "resetsAt": 1792700000}
        },
        "codex_other": {
          "limitId": "codex_other", "limitName": "Other Codex usage",
          "primary": {"usedPercent": 42, "windowDurationMins": 60, "resetsAt": 1792300000},
          "secondary": null
        }
      }
    }
    """#

    func testMultiBucketResponsePreservesPrimarySecondaryAndResetTimes() throws {
        let snapshot = try CodexUsageService.parseRateLimits(Data(officialFixture.utf8), planType: "pro")
        XCTAssertEqual(snapshot.planType, "pro")
        XCTAssertEqual(snapshot.buckets.map(\.id), ["codex", "codex_other"])
        XCTAssertEqual(snapshot.buckets[0].primary?.remainingPercent, 75)
        XCTAssertEqual(snapshot.buckets[0].secondary?.remainingPercent, 40)
        XCTAssertEqual(snapshot.buckets[0].primary?.windowDurationMins, 300)
        XCTAssertEqual(snapshot.buckets[0].secondary?.resetDate?.timeIntervalSince1970, 1792700000)
        XCTAssertNil(snapshot.buckets[1].secondary)
    }

    func testLegacySingleBucketAndNullFieldsStayUnknown() throws {
        let data = Data(#"{"rateLimits":{"limitId":"codex","limitName":null,"primary":{"usedPercent":null,"windowDurationMins":null,"resetsAt":null},"secondary":null}}"#.utf8)
        let snapshot = try CodexUsageService.parseRateLimits(data)
        XCTAssertEqual(snapshot.buckets.count, 1)
        XCTAssertNil(snapshot.buckets[0].primary?.remainingPercent)
        XCTAssertNil(snapshot.buckets[0].primary?.resetDate)
    }

    func testMissingBucketsAreNotPresentedAsZeroUsage() {
        XCTAssertThrowsError(try CodexUsageService.parseRateLimits(Data(#"{"rateLimits":null,"rateLimitsByLimitId":{}}"#.utf8)))
    }

    func testInvalidSavedBinaryDoesNotSilentlySelectAnotherCLI() {
        let suite = "si-notch-codex-usage-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("/tmp/missing-codex-\(UUID().uuidString)", forKey: CodexBinaryLocator.preferenceKey)
        XCTAssertNil(CodexBinaryLocator.detected(defaults: defaults, environment: ["PATH": "/usr/local/bin"]))
    }

    func testOfflineAppServerHandshakeAndReadOnlyMethods() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("si-notch-usage-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("fake-codex")
        let source = #"""
        #!/usr/bin/python3
        import json, sys
        initialized = False
        for line in sys.stdin:
            request = json.loads(line)
            method = request.get("method")
            if method == "initialize":
                print(json.dumps({"id": request["id"], "result": {"userAgent": "test"}}), flush=True)
            elif method == "initialized":
                initialized = True
            elif method == "account/read" and initialized and request.get("params", {}).get("refreshToken") is False:
                print(json.dumps({"id": request["id"], "result": {"account": {"type": "chatgpt", "planType": "pro", "email": "secret@example.test"}, "requiresOpenaiAuth": True}}), flush=True)
            elif method == "account/rateLimits/read" and initialized:
                print(json.dumps({"id": request["id"], "result": {"rateLimits": {"limitId": "codex", "primary": {"usedPercent": 20, "windowDurationMins": 300, "resetsAt": 1792340000}, "secondary": None}}}), flush=True)
            else:
                print(json.dumps({"id": request.get("id"), "error": {"code": -32600}}), flush=True)
        """#
        try Data(source.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let status = try await CodexUsageService().refresh(binary: script)
        guard case .limits(let snapshot) = status else { return XCTFail("Expected rate limits") }
        XCTAssertEqual(snapshot.planType, "pro")
        XCTAssertEqual(snapshot.buckets.first?.primary?.remainingPercent, 80)
        XCTAssertFalse(String(describing: snapshot).contains("secret@example.test"))
    }
}
