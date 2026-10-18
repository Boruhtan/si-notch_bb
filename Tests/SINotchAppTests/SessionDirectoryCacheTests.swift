import XCTest
@testable import SINotch

final class SessionDirectoryCacheTests: XCTestCase {
    func testMembershipTracksCreationDeletionReplacementAndLateDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("si-notch-directory-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var cache = SessionDirectoryCache()
        XCTAssertTrue(cache.contents(of: root).isEmpty)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let a = root.appendingPathComponent("a.jsonl"), b = root.appendingPathComponent("b.jsonl")
        try Data("first".utf8).write(to: a)
        XCTAssertEqual(cache.contents(of: root).map(\.lastPathComponent), ["a.jsonl"])
        XCTAssertEqual(cache.contents(of: root).map(\.lastPathComponent), ["a.jsonl"])
        try Data("second".utf8).write(to: b)
        XCTAssertEqual(Set(cache.contents(of: root).map(\.lastPathComponent)), ["a.jsonl", "b.jsonl"])
        try FileManager.default.removeItem(at: a)
        XCTAssertEqual(cache.contents(of: root).map(\.lastPathComponent), ["b.jsonl"])
        try FileManager.default.removeItem(at: root)
        XCTAssertTrue(cache.contents(of: root).isEmpty)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("replacement".utf8).write(to: a)
        XCTAssertEqual(cache.contents(of: root).map(\.lastPathComponent), ["a.jsonl"])
    }

    func testCachedNamesKeepAppendsVisibleAndRejectSymlinkReplacement() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("si-notch-directory-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("sessions"), other = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("session.jsonl")
        try Data("a".utf8).write(to: file)
        var cache = SessionDirectoryCache()
        let first = try XCTUnwrap(cache.contents(of: directory).first)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("bc".utf8)); try handle.close()
        XCTAssertEqual(cache.contents(of: directory), [first])
        XCTAssertEqual(SessionFileMetadata(first)?.size, 3)
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: other)
        XCTAssertTrue(cache.contents(of: directory).isEmpty)
    }
}
