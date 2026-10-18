import XCTest
@testable import SINotch

final class CodexConfigSetupTests: XCTestCase {
    private var folder: URL!
    private var helper: URL!
    private var config: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("si-notch-codex-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        helper = folder.appendingPathComponent("si-notchctl")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        config = folder.appendingPathComponent(".codex/config.toml")
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folder)
    }

    private func setup() -> CodexConfigSetup { CodexConfigSetup(helperPath: helper.path, configURL: config) }

    func testEscapedQuotedNotifyCannotCreateDuplicateTOMLKey() throws {
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = #""no\u0074ify" = ["existing-handler"]"# + "\n"
        try Data(original.utf8).write(to: config)
        let preview = try setup().preview()
        XCTAssertFalse(preview.canApply)
        XCTAssertThrowsError(try setup().apply(preview))
        XCTAssertEqual(try String(contentsOf: config), original)
    }

    func testAddsTopLevelNotifyAndBacksUpUnrelatedConfiguration() throws {
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = "# personal settings\n[features]\nstreaming = true\n"
        try Data(original.utf8).write(to: config)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)

        let preview = try setup().preview()
        XCTAssertTrue(preview.canApply)
        let backup = try XCTUnwrap(setup().apply(preview))
        XCTAssertEqual(try String(contentsOf: backup), original)
        let updated = try String(contentsOf: config)
        XCTAssertTrue(updated.hasPrefix("notify = ["))
        XCTAssertTrue(updated.hasSuffix(original))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: config.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testExistingNotifyIsNeverReplaced() throws {
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = "notify = [\"/existing/hook\", \"turn-ended\"]\n[features]\nstreaming = true\n"
        try Data(original.utf8).write(to: config)
        let preview = try setup().preview()
        XCTAssertTrue(preview.existingNotify)
        XCTAssertFalse(preview.canApply)
        XCTAssertThrowsError(try setup().apply(preview))
        XCTAssertEqual(try String(contentsOf: config), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: config.deletingLastPathComponent().path).count, 1)
    }

    func testConcurrentEditInvalidatesPreviewWithoutBackupOrWrite() throws {
        let preview = try setup().preview()
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("model = \"custom\"\n".utf8).write(to: config)
        XCTAssertThrowsError(try setup().apply(preview))
        XCTAssertEqual(try String(contentsOf: config), "model = \"custom\"\n")
    }

    func testQuotedNotifyKeyAlsoBlocksAutomaticEdit() throws {
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("\"notify\" = [\"/existing/hook\"]\n".utf8).write(to: config)
        XCTAssertFalse(try setup().preview().canApply)
    }

    func testSymlinkConfigIsRejected() throws {
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        let target = folder.appendingPathComponent("real-config.toml")
        try Data("model = \"test\"\n".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: config, withDestinationURL: target)
        XCTAssertThrowsError(try setup().preview())
        XCTAssertEqual(try String(contentsOf: target), "model = \"test\"\n")
    }

    func testCreatesMissingConfigOnlyAfterApply() throws {
        let preview = try setup().preview()
        XCTAssertFalse(FileManager.default.fileExists(atPath: config.path))
        XCTAssertNil(try setup().apply(preview))
        XCTAssertTrue(try String(contentsOf: config).contains("si-notchctl"))
    }
}
