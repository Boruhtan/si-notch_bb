import Foundation
import XCTest
@testable import SINotch

final class UpdateInstallerTests: XCTestCase {
    private func fixture(_ operation: (URL, URL, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("si-notch-install-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("si-notch.app")
        let new = root.appendingPathComponent("candidate.app")
        for (url, content) in [(old, "old"), (new, "new")] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try content.write(to: url.appendingPathComponent("version.txt"), atomically: true, encoding: .utf8)
        }
        try operation(root, old, new)
    }

    func testReplacementLaunchesNewBundleAndRemovesStaging() throws {
        try fixture { root, old, new in
            try UpdateInstaller.replace(candidate: new, destination: old) { url in
                XCTAssertEqual(try? String(contentsOf: url.appendingPathComponent("version.txt")), "new")
                return true
            }
            XCTAssertEqual(try String(contentsOf: old.appendingPathComponent("version.txt")), "new")
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".si-notch-install-") })
        }
    }

    func testFailedLaunchRestoresOldBundleAndRelaunchesIt() throws {
        try fixture { root, old, new in
            var launches: [String] = []
            XCTAssertThrowsError(try UpdateInstaller.replace(candidate: new, destination: old) { url in
                launches.append((try? String(contentsOf: url.appendingPathComponent("version.txt"))) ?? "missing")
                return launches.count > 1
            })
            XCTAssertEqual(launches, ["new", "old"])
            XCTAssertEqual(try String(contentsOf: old.appendingPathComponent("version.txt")), "old")
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".si-notch-install-") })
        }
    }

    func testCopyFailureLeavesInstalledBundleIntact() throws {
        try fixture { _, old, new in
            try FileManager.default.removeItem(at: new)
            XCTAssertThrowsError(try UpdateInstaller.replace(candidate: new, destination: old) { _ in XCTFail("Must not launch"); return true })
            XCTAssertEqual(try String(contentsOf: old.appendingPathComponent("version.txt")), "old")
        }
    }

    func testDestinationMustBeOurInstalledApp() throws {
        try fixture { _, old, _ in
            XCTAssertThrowsError(try UpdateInstaller.validateDestination(old))
        }
    }
}
