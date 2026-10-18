import Foundation
import XCTest
@testable import SINotch

final class CodexHookAuthorizationTests: XCTestCase {
    private let command = "/usr/bin/python3 '/app/codex-hook.py' --cli '/app/si-notchctl'"
    private let source = "/tmp/codex-home/hooks.json"
    private let cwd = "/tmp/workspace"

    private var client: CodexHookAuthorization {
        CodexHookAuthorization(command: command, sourcePath: source, cwd: cwd)
    }

    private func listing(status: String = "untrusted", hash: String = "sha256:original",
                         warnings: [String] = [], extra: [[String: Any]] = []) -> [String: Any] {
        let hooks: [[String: Any]] = CodexHookSetup.events.enumerated().map { index, name in
            ["eventName": name.prefix(1).lowercased() + name.dropFirst(),
             "key": "file:\(source):event:\(index):0", "currentHash": hash,
             "trustStatus": status, "enabled": true, "isManaged": false,
             "source": "user", "sourcePath": source, "command": command]
        }
        return ["data": [["cwd": cwd, "hooks": hooks + extra,
                          "warnings": warnings, "errors": [] as [String]]]]
    }

    func testExactEightHookPlanAndNativeBatchWriteShape() throws {
        let plan = try client.plan(from: listing())
        XCTAssertEqual(plan.hooks.count, 8)
        XCTAssertEqual(plan.pendingCount, 8)
        XCTAssertEqual(plan.command, command)
        let params = CodexHookAuthorization.writeParams(for: plan)
        XCTAssertEqual(params["reloadUserConfig"] as? Bool, true)
        XCTAssertNil(params["filePath"])
        let edits = try XCTUnwrap(params["edits"] as? [[String: Any]])
        XCTAssertEqual(edits.count, 1)
        XCTAssertEqual(edits[0]["keyPath"] as? String, "hooks.state")
        XCTAssertEqual(edits[0]["mergeStrategy"] as? String, "upsert")
        let value = try XCTUnwrap(edits[0]["value"] as? [String: [String: String]])
        XCTAssertEqual(value.count, 8)
        XCTAssertTrue(value.values.allSatisfy { $0 == ["trusted_hash": "sha256:original"] })
    }

    func testAuthorizeRechecksExactHashAndVerifiesTrustedAfterWrite() throws {
        let plan = try client.plan(from: listing())
        var calls: [String] = []
        try client.authorize(reviewed: plan) { method, params in
            calls.append(method)
            switch calls.count {
            case 1: return self.listing()
            case 2:
                XCTAssertEqual(method, "config/batchWrite")
                let edits = try XCTUnwrap(params["edits"] as? [[String: Any]])
                XCTAssertEqual((edits[0]["value"] as? [String: Any])?.count, 8)
                return ["status": "ok", "filePath": "/tmp/codex-home/config.toml", "version": "v2"]
            case 3: return self.listing(status: "trusted")
            default: XCTFail("Unexpected request"); return [:]
            }
        }
        XCTAssertEqual(calls, ["hooks/list", "config/batchWrite", "hooks/list"])
    }

    func testChangedHashStopsBeforeAnyWrite() throws {
        let plan = try client.plan(from: listing())
        var calls: [String] = []
        XCTAssertThrowsError(try client.authorize(reviewed: plan) { method, _ in
            calls.append(method)
            return self.listing(hash: "sha256:changed")
        })
        XCTAssertEqual(calls, ["hooks/list"])
    }

    func testWarningsMissingDuplicateAndWrongSourceFailClosed() throws {
        XCTAssertThrowsError(try client.plan(from: listing(warnings: ["hook load warning"])))
        var missing = listing()
        var data = try XCTUnwrap(missing["data"] as? [[String: Any]])
        var hooks = try XCTUnwrap(data[0]["hooks"] as? [[String: Any]])
        hooks.removeLast()
        data[0]["hooks"] = hooks
        missing["data"] = data
        XCTAssertThrowsError(try client.plan(from: missing))
        let duplicate = try XCTUnwrap((listing()["data"] as? [[String: Any]])?[0]["hooks"] as? [[String: Any]])[0]
        XCTAssertThrowsError(try client.plan(from: listing(extra: [duplicate])))
        var wrongSource = duplicate
        wrongSource["sourcePath"] = "/tmp/another/hooks.json"
        XCTAssertThrowsError(try client.plan(from: listing(extra: [wrongSource])))
        var repeatedKey = listing()
        var repeatedData = try XCTUnwrap(repeatedKey["data"] as? [[String: Any]])
        var repeatedHooks = try XCTUnwrap(repeatedData[0]["hooks"] as? [[String: Any]])
        repeatedHooks[1]["key"] = repeatedHooks[0]["key"]
        repeatedData[0]["hooks"] = repeatedHooks
        repeatedKey["data"] = repeatedData
        XCTAssertThrowsError(try client.plan(from: repeatedKey))
    }

    func testReportsFailureWhenWriteDoesNotProduceTrustedStatus() throws {
        let plan = try client.plan(from: listing())
        var n = 0
        XCTAssertThrowsError(try client.authorize(reviewed: plan) { _, _ in
            n += 1
            return n == 2 ? ["status": "ok"] : self.listing()
        })
        XCTAssertEqual(n, 3)
    }
}
