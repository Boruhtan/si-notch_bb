import Darwin
import XCTest
@testable import SINotch

final class SessionFileMetadataTests: XCTestCase {
    func testAppendAndAtomicReplacementRefreshSizeAndInode() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("session.jsonl")
        try Data("one\n".utf8).write(to: file)
        let initial = try XCTUnwrap(SessionFileMetadata(file))
        XCTAssertTrue(initial.isRegularFile)
        XCTAssertEqual(initial.owner, getuid())
        XCTAssertEqual(initial.size, 4)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("two\n".utf8))
        try handle.close()
        let appended = try XCTUnwrap(SessionFileMetadata(file))
        XCTAssertEqual(appended.inode, initial.inode)
        XCTAssertEqual(appended.size, 8)
        XCTAssertGreaterThanOrEqual(appended.modified, initial.modified)
        try Data("new\n".utf8).write(to: file, options: .atomic)
        let replaced = try XCTUnwrap(SessionFileMetadata(file))
        XCTAssertNotEqual(replaced.inode, initial.inode)
        XCTAssertEqual(replaced.size, 4)
    }

    func testSymlinksAreNeitherRegularFilesNorDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("session.jsonl")
        try Data("{}".utf8).write(to: file)
        for (name, target) in [("file-link", file), ("directory-link", root)] {
            let link = root.appendingPathComponent(name)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            let metadata = try XCTUnwrap(SessionFileMetadata(link))
            XCTAssertFalse(metadata.isRegularFile)
            XCTAssertFalse(metadata.isDirectory)
        }
        XCTAssertNil(SessionFileMetadata(root.appendingPathComponent("missing")))
    }
}
