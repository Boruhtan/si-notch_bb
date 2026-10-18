import Foundation
import XCTest
@testable import SINotch

final class PiSetupTests: XCTestCase {
    private func fixture() throws -> (directory: URL, adapter: URL, helper: URL, settings: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("si-notch-pi-setup-\(UUID().uuidString)", isDirectory: true)
        let contents = directory.appendingPathComponent("si-notch.app/Contents")
        let adapterDir = contents.appendingPathComponent("Resources/adapters")
        let helperDir = contents.appendingPathComponent("Helpers")
        let configDir = directory.appendingPathComponent("pi-agent")
        try FileManager.default.createDirectory(at: adapterDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: helperDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let adapter = adapterDir.appendingPathComponent("pi-si-notch.js")
        let helper = helperDir.appendingPathComponent("si-notchctl")
        try Data("export default () => {};\n".utf8).write(to: adapter)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        return (directory, adapter, helper, configDir.appendingPathComponent("settings.json"))
    }

    func testPreviewAndApplyPreserveAllExistingSettingsAndExtensionsWithBackup() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let original = #"{"theme":"custom","nested":{"keep":[1,true]},"extensions":["/other/a.js","-builtin:mcp"]}"#
        try Data(original.utf8).write(to: f.settings)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: f.settings.path)
        let setup = PiSetup(adapterPath: f.adapter.path, helperPath: f.helper.path, settingsURL: f.settings)
        let preview = try setup.preview()
        XCTAssertTrue(preview.canApply)
        XCTAssertEqual(preview.existingExtensionCount, 2)
        XCTAssertEqual(preview.extensionPath, f.adapter.path)
        XCTAssertEqual(try String(contentsOf: f.settings, encoding: .utf8), original)
        let backup = try XCTUnwrap(setup.apply(preview))
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), original)
        let after = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: f.settings)) as? [String: Any])
        XCTAssertEqual(after["theme"] as? String, "custom")
        let nested = try XCTUnwrap(after["nested"] as? [String: Any])
        XCTAssertEqual(nested["keep"] as? [AnyHashable], [1, true])
        XCTAssertEqual(after["extensions"] as? [String], ["/other/a.js", "-builtin:mcp", f.adapter.path])
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: f.settings.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertFalse(try setup.preview().canApply)
    }

    func testNewSettingsFileAndIdempotentPreview() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let setup = PiSetup(adapterPath: f.adapter.path, helperPath: f.helper.path, settingsURL: f.settings)
        XCTAssertNil(try setup.apply(setup.preview()))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: f.settings)) as? [String: Any])
        XCTAssertEqual(root["extensions"] as? [String], [f.adapter.path])
        XCTAssertFalse(try setup.preview().canApply)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: f.settings.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testChangedFileSymlinkAndBusyLockAreRejected() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let setup = PiSetup(adapterPath: f.adapter.path, helperPath: f.helper.path, settingsURL: f.settings)
        let stale = try setup.preview()
        try Data(#"{"theme":"changed"}"#.utf8).write(to: f.settings)
        XCTAssertThrowsError(try setup.apply(stale)) { XCTAssertEqual($0 as? PiSetup.SetupError, .changedSincePreview) }
        try FileManager.default.removeItem(at: f.settings)
        try FileManager.default.createSymbolicLink(at: f.settings, withDestinationURL: f.adapter)
        XCTAssertThrowsError(try setup.preview()) { XCTAssertEqual($0 as? PiSetup.SetupError, .unsupportedFile) }
        try FileManager.default.removeItem(at: f.settings)
        let lock = URL(fileURLWithPath: f.settings.path + ".lock")
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: lock) }
        XCTAssertThrowsError(try setup.apply(try setup.preview())) { XCTAssertEqual($0 as? PiSetup.SetupError, .busy) }
    }

    func testInvalidAndAmbiguousConfigurationsStopWithoutWriting() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let setup = PiSetup(adapterPath: f.adapter.path, helperPath: f.helper.path, settingsURL: f.settings)
        for content in [#"{"extensions":"bad"}"#, #"{"extensions":[42]}"#, "not-json"] {
            try Data(content.utf8).write(to: f.settings)
            XCTAssertThrowsError(try setup.preview()) { XCTAssertEqual($0 as? PiSetup.SetupError, .unsupportedFile) }
            XCTAssertEqual(try String(contentsOf: f.settings, encoding: .utf8), content)
        }
        for content in [#"{"extensions":["/old/pi-si-notch.js"]}"#,
                        "{\"extensions\":[\"-\(f.adapter.path)\"]}"] {
            try Data(content.utf8).write(to: f.settings)
            XCTAssertThrowsError(try setup.preview()) { XCTAssertEqual($0 as? PiSetup.SetupError, .ambiguousInstallation) }
            XCTAssertEqual(try String(contentsOf: f.settings, encoding: .utf8), content)
        }
    }

    func testAdapterAndHelperMustMatchBundleLayout() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let wrong = PiSetup(adapterPath: f.adapter.path, helperPath: "/usr/bin/true", settingsURL: f.settings)
        XCTAssertThrowsError(try wrong.preview()) { XCTAssertEqual($0 as? PiSetup.SetupError, .invalidHelper) }
        try FileManager.default.removeItem(at: f.adapter)
        let setup = PiSetup(adapterPath: f.adapter.path, helperPath: f.helper.path, settingsURL: f.settings)
        XCTAssertThrowsError(try setup.preview()) { XCTAssertEqual($0 as? PiSetup.SetupError, .invalidAdapter) }
    }
}
