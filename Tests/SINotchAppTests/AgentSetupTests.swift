import Foundation
import XCTest
@testable import SINotch

final class AgentSetupTests: XCTestCase {
    func testLocalHermesDiscoveryListsOneHundredProfilesWithoutReadingTheirConfiguration() throws {
        let home = root.appendingPathComponent(".hermes")
        for index in 0..<100 {
            try write(Data("not parsed by discovery".utf8), to: home.appendingPathComponent("profiles/profile-\(index)/config.yaml"))
        }
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("profiles/alias"),
            withDestinationURL: home.appendingPathComponent("profiles/profile-0"))
        let installer = setup(.hermes)
        let profiles = installer.localHermesProfiles()
        XCTAssertEqual(profiles.count, 101)
        XCTAssertEqual(profiles.first?.name, "default")
        XCTAssertEqual(Set(profiles.map(\.id)).count, 101)
        XCTAssertFalse(profiles.contains { $0.name == "alias" })
        XCTAssertTrue(installer.hermesEnableCommand.contains("HERMES_HOME="))
        let named = setup(.hermes, environment: ["HERMES_HOME": home.appendingPathComponent("profiles/profile-7").path])
        XCTAssertTrue(named.hermesEnableCommand.contains("profiles/profile-7' hermes plugins enable si-notch"))
    }
    func testHermesSetupCreatesStableDistinctProfileIdentitiesAndPreservesExistingSettings() throws {
        try write(Data("\"\"\"Hermes Agent observer plugin for si-notch\"\"\"".utf8), to: adapters.appendingPathComponent("hermes-si-notch/__init__.py"))
        try write(Data("name: si-notch\n".utf8), to: adapters.appendingPathComponent("hermes-si-notch/plugin.yaml"))
        var ids: Set<String> = []
        for profile in ["a", "b"] {
            let home = root.appendingPathComponent("hermes-" + profile)
            let installer = setup(.hermes, environment: ["HERMES_HOME": home.path])
            let preview = try installer.preview()
            XCTAssertEqual(try installer.preview().files, preview.files)
            _ = try installer.apply(preview)
            XCTAssertFalse(try installer.preview().canApply)
            let config = home.appendingPathComponent("plugins/si-notch/si-notch.json")
            ids.insert(try XCTUnwrap(try object(config)["instanceId"] as? String))
            try write(Data("{\"instanceId\":\"keep-me\",\"displayName\":\"My profile\",\"showSessionText\":true,\"custom\":7}".utf8), to: config)
            _ = try installer.apply(installer.preview())
            let saved = try object(config)
            XCTAssertEqual(saved["instanceId"] as? String, "keep-me")
            XCTAssertEqual(saved["displayName"] as? String, "My profile")
            XCTAssertEqual(saved["showSessionText"] as? Bool, true)
            XCTAssertEqual(saved["custom"] as? Int, 7)
        }
        XCTAssertEqual(ids.count, 2)
    }
    private var root: URL!
    private var helper: URL!
    private var adapters: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("si-notch-setup-" + UUID().uuidString)
        let contents = root.appendingPathComponent("Apps with spaces/si-notch.app/Contents")
        helper = contents.appendingPathComponent("Helpers/si-notchctl")
        adapters = contents.appendingPathComponent("Resources/adapters")
        try write(Data("#!/bin/sh\nexit 99\n".utf8), to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func setup(_ provider: HarnessKind, environment: [String: String] = [:]) -> AgentSetup {
        AgentSetup(provider: provider, helperPath: helper.path, home: root, environment: environment)
    }
    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
    private func object(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
    func testConnectAllJSONProvidersWithoutExecutingAnythingAndReconnectIsIdempotent() throws {
        for provider: HarnessKind in [.claude, .gemini, .copilot, .cursor] {
            let installer = setup(provider)
            let preview = try installer.preview()
            XCTAssertTrue(preview.canApply)
            XCTAssertFalse(FileManager.default.fileExists(atPath: preview.files[0].url.path))
            XCTAssertTrue(try installer.apply(preview).isEmpty)
            XCTAssertFalse(try installer.preview().canApply)
            let hooks = try XCTUnwrap(try object(preview.files[0].url)["hooks"] as? [String: Any])
            XCTAssertEqual(hooks.count, provider == .claude ? 14 : provider == .cursor ? 4 : 5)
            let text = try String(contentsOf: preview.files[0].url)
            XCTAssertFalse(text.contains("python"))
            XCTAssertTrue(text.contains(helper.path))
        }
    }
    func testPreservesUserSettingsOtherHooksAndPermissionBridge() throws {
        let installer = setup(.claude)
        let url = try installer.settingsURL()
        let existing: [String: Any] = ["model": "user-choice", "permissions": ["deny": ["Bash(rm *)"]],
            "hooks": ["UserPromptSubmit": [["hooks": [["type": "command", "command": "existing-hook"]]]],
                      "PermissionRequest": [["hooks": [["type": "command", "command": "python3 claude-permission.py --helper si-notchctl"]]]]]]
        let original = try JSONSerialization.data(withJSONObject: existing)
        try write(original, to: url)
        let backups = try installer.apply(installer.preview())
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: backups[0]), original)
        let saved = try object(url)
        XCTAssertEqual(saved["model"] as? String, "user-choice")
        XCTAssertTrue(NSDictionary(dictionary: saved["permissions"] as! [String: Any]).isEqual(to: existing["permissions"] as! [String: Any]))
        let hooks = saved["hooks"] as! [String: [[String: Any]]]
        XCTAssertEqual(hooks["UserPromptSubmit"]?.count, 2)
        XCTAssertEqual(hooks["PermissionRequest"]?.count, 2)
        XCTAssertFalse(try installer.preview().canApply)
    }
    func testMalformedDisabledAndSymlinkConfigurationsAreNeverOverwritten() throws {
        let installer = setup(.claude)
        let url = try installer.settingsURL()
        for text in ["{broken", "[]", "{\"hooks\":[]}", "{\"disableAllHooks\":true}", "{\"allowManagedHooksOnly\":true}"] {
            try write(Data(text.utf8), to: url)
            XCTAssertThrowsError(try installer.preview())
            XCTAssertEqual(try String(contentsOf: url), text)
        }
        try FileManager.default.removeItem(at: url)
        let target = root.appendingPathComponent("user-settings.json")
        try write(Data("{}".utf8), to: target)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        XCTAssertThrowsError(try installer.preview())
        XCTAssertEqual(try String(contentsOf: target), "{}")
    }
    func testChangesAfterPreviewAndConcurrentSetupAreRejected() throws {
        let installer = setup(.gemini)
        let preview = try installer.preview()
        let url = preview.files[0].url
        try write(Data("{\"model\":\"new\"}".utf8), to: url)
        XCTAssertThrowsError(try installer.apply(preview))
        let current = try installer.preview()
        let lock = url.deletingLastPathComponent().appendingPathComponent(".si-notch-setup.lock")
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
        XCTAssertThrowsError(try installer.apply(current))
        XCTAssertEqual(try String(contentsOf: url), "{\"model\":\"new\"}")
    }
    func testPluginCopiesOnlyBundledFilesAndRecordsExactHelperPath() throws {
        try write(Data("export const SINotchPlugin = async () => ({});".utf8), to: adapters.appendingPathComponent("opencode-si-notch.js"))
        try write(Data("\"\"\"Hermes Agent observer plugin for si-notch\"\"\"".utf8), to: adapters.appendingPathComponent("hermes-si-notch/__init__.py"))
        try write(Data("name: si-notch\n".utf8), to: adapters.appendingPathComponent("hermes-si-notch/plugin.yaml"))
        for provider: HarnessKind in [.opencode, .hermes] {
            let installer = setup(provider)
            let preview = try installer.preview()
            XCTAssertEqual(preview.files.count, provider == .opencode ? 2 : 3)
            XCTAssertTrue(try installer.apply(preview).isEmpty)
            XCTAssertFalse(try installer.preview().canApply)
            let config = try XCTUnwrap(preview.files.first { $0.url.lastPathComponent == "si-notch.json" })
            XCTAssertEqual(try object(config.url)["helperPath"] as? String, helper.path)
            for file in preview.files { XCTAssertEqual(try Data(contentsOf: file.url), file.proposed) }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".hermes/config.yaml").path))
    }
    func testNeverReplacesAnUnrelatedPlugin() throws {
        try write(Data("export const SINotchPlugin = async () => ({});".utf8), to: adapters.appendingPathComponent("opencode-si-notch.js"))
        let url = root.appendingPathComponent(".config/opencode/plugins/si-notch.js")
        try write(Data("user-plugin".utf8), to: url)
        XCTAssertThrowsError(try setup(.opencode).preview())
        XCTAssertEqual(try String(contentsOf: url), "user-plugin")
    }
    func testCustomConfigDirectoriesAndInvalidRelativeOverrides() throws {
        let custom = root.appendingPathComponent("custom")
        XCTAssertEqual(try setup(.claude, environment: ["CLAUDE_CONFIG_DIR": custom.path]).settingsURL(), custom.appendingPathComponent("settings.json"))
        XCTAssertEqual(try setup(.copilot, environment: ["COPILOT_HOME": custom.path]).settingsURL(), custom.appendingPathComponent("hooks/si-notch.json"))
        XCTAssertEqual(try setup(.claude, environment: ["CLAUDE_CONFIG_DIR": "relative"]).settingsURL(), root.appendingPathComponent(".claude/settings.json"))
    }
}
