import Foundation
import XCTest
@testable import SINotch

final class CodexHookSetupTests: XCTestCase {
    func testMigrationExtendsOnlyTheOwnedPermissionHookAndPreservesOtherHandlers() throws {
        let (directory, adapter, helper, hooks) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let setup = CodexHookSetup(adapterPath: adapter.path, helperPath: helper.path, hooksURL: hooks)
        _ = try setup.apply(setup.preview())
        var original = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: hooks)) as? [String: Any])
        var groups = try XCTUnwrap(original["hooks"] as? [String: [[String: Any]]])
        let other: [String: Any] = ["matcher": "Bash", "hooks": [["type": "command", "command": "/other/permission", "timeout": 17]]]
        groups["PermissionRequest"] = [["hooks": [["type": "command", "command": setup.command, "timeout": 3]]], other]
        original["hooks"] = groups
        let before = try JSONSerialization.data(withJSONObject: original)
        try before.write(to: hooks)
        let preview = try setup.preview()
        XCTAssertEqual(preview.addedEvents, ["PermissionRequest"])
        let backup = try XCTUnwrap(setup.apply(preview))
        XCTAssertEqual(try Data(contentsOf: backup), before)
        let updated = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: hooks)) as? [String: Any])
        let updatedGroups = try XCTUnwrap(updated["hooks"] as? [String: [[String: Any]]])
        XCTAssertEqual((updatedGroups["PermissionRequest"]?[0]["hooks"] as? [[String: Any]])?[0]["timeout"] as? Int, 80)
        XCTAssertEqual(updatedGroups["PermissionRequest"]?[1] as NSDictionary?, other as NSDictionary)
        XCTAssertEqual(updatedGroups["Stop"] as NSArray?, groups["Stop"] as NSArray?)
        XCTAssertFalse(try setup.preview().canApply)
    }
    private func fixture() throws -> (URL, URL, URL, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("si-notch-codex-hook-setup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let adapter = directory.appendingPathComponent("my hook's adapter.py")
        let helper = directory.appendingPathComponent("si-notchctl")
        try Data("# test\n".utf8).write(to: adapter)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        return (directory, adapter, helper, directory.appendingPathComponent("hooks.json"))
    }

    func testMergePreservesExistingGroupsAndCreatesBackupWithoutTouchingNotify() throws {
        let (directory, adapter, helper, hooks) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = #"{"description":"keep","hooks":{"SessionStart":[{"matcher":"startup","hooks":[{"type":"command","command":"/existing/start"}]}],"Stop":[{"hooks":[{"type":"command","command":"/existing/stop"}]}]}}"#
        try Data(original.utf8).write(to: hooks)
        let setup = CodexHookSetup(adapterPath: adapter.path, helperPath: helper.path, hooksURL: hooks)
        let preview = try setup.preview()
        XCTAssertTrue(preview.canApply)
        XCTAssertEqual(preview.addedEvents, CodexHookSetup.events)
        XCTAssertEqual(try String(contentsOf: hooks, encoding: .utf8), original)
        let proposed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(preview.proposedJSON.utf8)) as? [String: Any])
        let proposedHooks = try XCTUnwrap(proposed["hooks"] as? [String: [[String: Any]]])
        let addedGroup = try XCTUnwrap(proposedHooks["Stop"]?.last)
        let addedHandler = try XCTUnwrap((addedGroup["hooks"] as? [[String: Any]])?.first)
        XCTAssertTrue((addedHandler["command"] as? String)?.contains("my hook'\\''s adapter.py") == true)

        let backup = try XCTUnwrap(setup.apply(preview))
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), original)
        let merged = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: hooks)) as? [String: Any])
        XCTAssertEqual(merged["description"] as? String, "keep")
        let groups = try XCTUnwrap(merged["hooks"] as? [String: [[String: Any]]])
        XCTAssertEqual(groups["SessionStart"]?.count, 2)
        XCTAssertEqual(groups["Stop"]?.count, 2)
        XCTAssertEqual(groups["PermissionRequest"]?.count, 1)
        XCTAssertFalse(try setup.preview().canApply)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("config.toml").path))
    }

    func testChangedFileAndSymlinkAreRejected() throws {
        let (directory, adapter, helper, hooks) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let setup = CodexHookSetup(adapterPath: adapter.path, helperPath: helper.path, hooksURL: hooks)
        let preview = try setup.preview()
        try Data(#"{"hooks":{}}"#.utf8).write(to: hooks)
        XCTAssertThrowsError(try setup.apply(preview))
        try FileManager.default.removeItem(at: hooks)
        try FileManager.default.createSymbolicLink(at: hooks, withDestinationURL: adapter)
        XCTAssertThrowsError(try setup.preview())
    }

    func testExistingDifferentAdapterAndMalformedHooksRequireManualReview() throws {
        let (directory, adapter, helper, hooks) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let setup = CodexHookSetup(adapterPath: adapter.path, helperPath: helper.path, hooksURL: hooks)
        try Data(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"python3 /old/codex-hook.py"}]}]}}"#.utf8).write(to: hooks)
        XCTAssertThrowsError(try setup.preview())
        try Data(#"{"hooks":{"Stop":"bad"}}"#.utf8).write(to: hooks)
        XCTAssertThrowsError(try setup.preview())
    }

    func testMatchingCommandWithMatcherCannotMasqueradeAsGlobalHook() throws {
        let (directory, adapter, helper, hooks) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let setup = CodexHookSetup(adapterPath: adapter.path, helperPath: helper.path, hooksURL: hooks)
        let existing: [String: Any] = ["hooks": ["Stop": [
            ["matcher": "some-condition", "hooks": [["type": "command", "command": setup.command, "timeout": 3]]]
        ]]]
        try JSONSerialization.data(withJSONObject: existing).write(to: hooks)
        XCTAssertThrowsError(try setup.preview())
    }

    func testTrustStatusRequiresEveryDiscoveredHookToBeTrusted() throws {
        let command = "/usr/bin/python3 '/example/codex-hook.py' --cli '/example/si-notchctl'"
        func result(_ trust: String) -> [String: Any] {
            ["data": [["hooks": CodexHookSetup.events.map { event in
                ["command": command, "eventName": event.prefix(1).lowercased() + event.dropFirst(),
                 "trustStatus": trust, "enabled": true] as [String: Any]
            }]]]
        }
        XCTAssertEqual(try CodexHookTrustChecker.status(from: result("trusted"), command: command), .trusted)
        XCTAssertEqual(try CodexHookTrustChecker.status(from: result("untrusted"), command: command),
                       .needsReview(trusted: 0, total: 8))
        XCTAssertEqual(try CodexHookTrustChecker.status(from: ["data": [["hooks": []]]], command: command), .notInstalled)
    }
}
