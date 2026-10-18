import Foundation
import XCTest
@testable import SINotch

final class HarnessDiscoveryTests: XCTestCase {
    private var folder: URL!
    private var bin: URL!
    private var applications: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("si-notch-discovery-\(UUID().uuidString)")
        bin = folder.appendingPathComponent("bin")
        applications = folder.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folder)
    }

    private func service(directories: [URL]? = nil) -> HarnessDiscoveryService {
        HarnessDiscoveryService(homeDirectory: folder, environment: [:], executableDirectories: directories ?? [bin], applicationDirectories: [applications])
    }

    @discardableResult
    private func executable(_ name: String, in directory: URL? = nil, contents: String = "#!/bin/sh\nexit 0\n") throws -> URL {
        let url = (directory ?? bin).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    private func app(_ name: String, packageType: String = "APPL") throws {
        let contents = applications.appendingPathComponent(name).appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundlePackageType": packageType, "CFBundleIdentifier": "example.test.\(name)"], format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
    }

    func testFindsEightKnownCLIsAndKeepsCodexPiFirst() throws {
        for name in ["codex", "pi", "claude", "opencode", "hermes", "gemini", "copilot", "cursor-agent"] { try executable(name) }
        let report = service().scan(at: Date(timeIntervalSince1970: 123))
        XCTAssertEqual(report.detected.count, 8)
        XCTAssertEqual(report.results.prefix(2).map(\.kind), [.codex, .pi])
        XCTAssertEqual(report.results.count, 9)
        XCTAssertEqual(report.scannedAt, Date(timeIntervalSince1970: 123))
        XCTAssertTrue(report.detected.allSatisfy(\.hasCLI))
        XCTAssertTrue(try XCTUnwrap(report.results.first { $0.kind == .codex }).primaryExecutablePath!.hasSuffix("/bin/codex"))
    }

    func testScanNeverExecutesDiscoveredProgramsOrChangesConfiguration() throws {
        let marker = folder.appendingPathComponent("executed")
        let config = folder.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = "notify = [\"existing-hook\"]\n"
        try Data(original.utf8).write(to: config)
        try executable("codex", contents: "#!/bin/sh\ntouch '\(marker.path)'\nexit 0\n")
        XCTAssertTrue(service().scan().results.first { $0.kind == .codex }!.isDetected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(try String(contentsOf: config), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: config.deletingLastPathComponent().path), ["config.toml"])
    }

    func testExecutableDirectoriesNonexecutableFilesAndBrokenLinksAreIgnored() throws {
        try FileManager.default.createDirectory(at: bin.appendingPathComponent("codex"), withIntermediateDirectories: true)
        let pi = try executable("pi")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pi.path)
        try FileManager.default.createSymbolicLink(at: bin.appendingPathComponent("claude"), withDestinationURL: folder.appendingPathComponent("missing"))
        XCTAssertTrue(service().scan().detected.isEmpty)
    }

    func testSymlinksToSameExecutableAreDeduplicated() throws {
        let target = try executable("codex", in: folder.appendingPathComponent("real"))
        let second = folder.appendingPathComponent("other-bin")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        for directory in [bin!, second] {
            try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("codex"), withDestinationURL: target)
        }
        let codex = try XCTUnwrap(service(directories: [bin, second, bin]).scan().results.first { $0.kind == .codex })
        XCTAssertEqual(codex.locations.count, 1)
        XCTAssertEqual(codex.locations[0].url, bin.appendingPathComponent("codex"))
        XCTAssertEqual(codex.locations[0].resolvedURL, target.resolvingSymlinksInPath())
    }

    func testAppOnlyDetectionDoesNotClaimCLIOrClaudeCode() throws {
        try app("Codex.app")
        try app("Claude.app")
        try app("Hermes.app", packageType: "BNDL")
        let report = service().scan()
        let codex = try XCTUnwrap(report.results.first { $0.kind == .codex })
        XCTAssertTrue(codex.isDetected)
        XCTAssertTrue(codex.hasApplication)
        XCTAssertFalse(codex.hasCLI)
        XCTAssertNil(codex.primaryExecutablePath)
        XCTAssertFalse(report.results.first { $0.kind == .claude }!.isDetected)
        XCTAssertFalse(report.results.first { $0.kind == .hermes }!.isDetected)
    }

    func testPATHIgnoresEmptyRelativeAndDuplicateEntriesWithoutRecursion() throws {
        let custom = folder.appendingPathComponent("custom-bin")
        try executable("pi", in: custom)
        try executable("codex", in: folder.appendingPathComponent("unscanned/deep/bin"))
        let scanner = HarnessDiscoveryService(homeDirectory: folder,
            environment: ["PATH": ":relative/bin:\(custom.path):\(custom.path)::", "TOKEN": "not-inspected"], applicationDirectories: [])
        XCTAssertEqual(scanner.executableDirectories.filter { $0.path == custom.path }.count, 1)
        XCTAssertFalse(scanner.executableDirectories.contains { $0.path.hasSuffix("/relative/bin") })
        let report = scanner.scan()
        XCTAssertTrue(report.results.first { $0.kind == .pi }!.locations.contains { $0.url.path.hasPrefix(custom.path) })
        XCTAssertFalse(report.results.first { $0.kind == .codex }!.locations.contains { $0.url.path.hasPrefix(folder.path + "/unscanned/") })
    }

    func testSearchDirectoriesAreBounded() {
        let directories = (0..<200).map { folder.appendingPathComponent("directory-\($0)") }
        XCTAssertEqual(service(directories: directories).executableDirectories.count, 128)
    }

    func testRescanFindsNewVersionManagerInstallWithoutShellEnvironment() throws {
        let scanner = HarnessDiscoveryService(homeDirectory: folder, environment: [:], applicationDirectories: [])
        let paths = [(".nvm/versions/node/v22.0.0/bin", "claude"),
                     ("Library/Application Support/fnm/node-versions/v24.0.0/installation/bin", "opencode"),
                     (".asdf/installs/nodejs/22.0.0/bin", "pi"),
                     (".local/share/mise/installs/node/24.0.0/bin", "gemini")]
        _ = scanner.scan()
        for (directory, command) in paths { try executable(command, in: folder.appendingPathComponent(directory)) }
        let report = scanner.scan()
        for (directory, command) in paths {
            XCTAssertTrue(report.detected.flatMap(\.locations).contains { $0.url.path == folder.appendingPathComponent(directory + "/" + command).path })
        }
        XCTAssertLessThanOrEqual(report.executableDirectories.count, 128)
    }

    func testGenericAgentIsNotCursorUnlessConventionalTargetIdentifiesIt() throws {
        let generic = try executable("agent")
        XCTAssertFalse(service().scan().results.first { $0.kind == .cursor }!.isDetected)
        try FileManager.default.removeItem(at: generic)
        let target = try executable("agent", in: folder.appendingPathComponent("cursor-agent/versions/test"))
        try FileManager.default.createSymbolicLink(at: generic, withDestinationURL: target)
        XCTAssertTrue(service().scan().results.first { $0.kind == .cursor }!.hasCLI)
    }

    func testCustomConnectionAlwaysRemainsManual() throws {
        try executable("custom")
        let custom = try XCTUnwrap(service().scan().results.first { $0.kind == .custom })
        XCTAssertFalse(custom.isDetected)
        XCTAssertTrue(custom.locations.isEmpty)
        XCTAssertEqual(custom.kind.supportLocalizationKey, "discovery.support.custom")
    }
}
