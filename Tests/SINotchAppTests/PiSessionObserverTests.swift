import Foundation
import XCTest
@testable import SINotch

final class PiSessionObserverTests: XCTestCase {
    private let sessionID = "11111111-1111-4111-8111-111111111111"

    private func fixture() throws -> (root: URL, file: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("si-notch-pi-observer-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("--Users-example-work--", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (root, folder.appendingPathComponent("2026-test_\(sessionID).jsonl"))
    }

    private func line(_ type: String, _ fields: [String: Any], at date: Date = Date()) throws -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var object = fields
        object["type"] = type
        object["timestamp"] = formatter.string(from: date)
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(10)
        return data
    }

    private func header(at date: Date = Date()) throws -> Data {
        try line("session", ["version": 3, "id": sessionID, "cwd": "/tmp/example-project"], at: date)
    }

    private func message(_ role: String, id: String, stopReason: String? = nil,
                         secret: String = "PRIVATE_PROMPT", at date: Date = Date()) throws -> Data {
        var payload: [String: Any] = ["role": role, "content": secret]
        if let stopReason { payload["stopReason"] = stopReason }
        if role == "assistant" { payload["model"] = "fixture-model"; payload["thinkingLevel"] = "high" }
        return try line("message", ["id": id, "parentId": NSNull(), "message": payload], at: date)
    }

    private func append(_ data: Data, to file: URL) throws {
        if !FileManager.default.fileExists(atPath: file.path) { try data.write(to: file); return }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    func testRichLocalSessionUsesTaskAndAssistantText() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let now = Date()
        try append(header(at: now), to: f.file)
        try append(message("user", id: "user1", secret: "Fix the notch layout token=private-key", at: now), to: f.file)
        try append(message("assistant", id: "answer1", stopReason: "stop", secret: "Layout fixed; checks passed", at: now), to: f.file)
        var scanner = PiSessionScanner(sessionsRoot: f.root, includeContent: true)
        let events = scanner.poll(now: now)
        XCTAssertEqual(events.first?.event.title, "Fix the notch layout token=[redacted]")
        XCTAssertEqual(events.first?.event.message, "Layout fixed; checks passed")
        XCTAssertEqual(events.first?.event.firstPrompt, events.first?.event.title)
    }

    func testFreshIncompleteBootstrapIsIdleThenIncrementalLifecycleIsAccurate() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let now = Date()
        try append(header(at: now), to: f.file)
        try append(message("user", id: "user1", at: now), to: f.file)
        var scanner = PiSessionScanner(sessionsRoot: f.root)
        let bootstrap = scanner.poll(now: now)
        XCTAssertEqual(bootstrap.map(\.event.kind), [.sessionStarted])
        XCTAssertEqual(bootstrap.first?.isBootstrap, true)
        XCTAssertEqual(bootstrap.first?.event.sessionID, sessionID)
        XCTAssertEqual(bootstrap.first?.event.projectPath, "/tmp/example-project")
        XCTAssertNil(bootstrap.first?.event.message)
        XCTAssertNil(bootstrap.first?.event.firstPrompt)
        XCTAssertTrue(scanner.poll(now: now).isEmpty)

        try append(message("assistant", id: "toolcall1", stopReason: "toolUse",
                           secret: "PRIVATE_TOOL_ARGS", at: now.addingTimeInterval(1)), to: f.file)
        let working = scanner.poll(now: now.addingTimeInterval(1))
        XCTAssertEqual(working.map(\.event.kind), [.working])
        XCTAssertEqual(working.first?.event.modelName, "fixture-model")
        XCTAssertEqual(working.first?.event.reasoningEffort, "high")
        XCTAssertNil(working.first?.event.toolName)
        try append(message("toolResult", id: "result1", secret: "PRIVATE_TOOL_OUTPUT",
                           at: now.addingTimeInterval(2)), to: f.file)
        XCTAssertEqual(scanner.poll(now: now.addingTimeInterval(2)).map(\.event.kind), [.working])
        try append(message("assistant", id: "final1", stopReason: "stop",
                           secret: "PRIVATE_LAST_RESULT", at: now.addingTimeInterval(3)), to: f.file)
        let completed = scanner.poll(now: now.addingTimeInterval(3))
        XCTAssertEqual(completed.map(\.event.kind), [.completed])
        for observation in bootstrap + working + completed {
            XCTAssertNil(observation.event.message)
            XCTAssertNil(observation.event.firstPrompt)
            XCTAssertNoThrow(try observation.event.validate())
            let encoded = String(data: try JSONEncoder().encode(observation.event), encoding: .utf8)!
            XCTAssertFalse(encoded.contains("PRIVATE_"))
            XCTAssertTrue(observation.event.id?.hasPrefix("pi-file:") == true)
        }
    }

    func testRecentCompletedBootstrapDoesNotPretendWorkingAndOldHistoryIgnored() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let now = Date()
        try append(header(at: now), to: f.file)
        try append(message("user", id: "user1", at: now), to: f.file)
        try append(message("assistant", id: "final1", stopReason: "stop", at: now), to: f.file)
        var scanner = PiSessionScanner(sessionsRoot: f.root)
        XCTAssertEqual(scanner.poll(now: now).map(\.event.kind), [.completed])
        XCTAssertTrue(scanner.poll(now: now).isEmpty)

        let old = now.addingTimeInterval(-3600)
        let other = f.root.appendingPathComponent("--old-project--/old.jsonl")
        try FileManager.default.createDirectory(at: other.deletingLastPathComponent(), withIntermediateDirectories: true)
        try append(header(at: old), to: other)
        try append(message("user", id: "old-user", at: old), to: other)
        var freshScanner = PiSessionScanner(sessionsRoot: f.root)
        XCTAssertEqual(freshScanner.poll(now: now).count, 1)
    }

    func testHookSuppressionAndSilenceIdle() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let now = Date()
        try append(header(at: now), to: f.file)
        var scanner = PiSessionScanner(sessionsRoot: f.root)
        XCTAssertEqual(scanner.poll(now: now).map(\.event.kind), [.sessionStarted])
        try append(message("user", id: "user1", at: now.addingTimeInterval(1)), to: f.file)
        XCTAssertEqual(scanner.poll(now: now.addingTimeInterval(1)).map(\.event.kind), [.working])
        XCTAssertEqual(scanner.poll(now: now.addingTimeInterval(3 * 60 + 2)).map(\.event.kind), [.sessionStarted])
        XCTAssertTrue(scanner.poll(now: now.addingTimeInterval(3 * 60 + 2)).isEmpty)
        try append(message("assistant", id: "toolcall1", stopReason: "toolUse",
                           at: now.addingTimeInterval(3 * 60 + 3)), to: f.file)
        XCTAssertTrue(scanner.poll(now: now.addingTimeInterval(3 * 60 + 3),
                                   suppressedSessionIDs: [sessionID]).isEmpty)
    }

    func testPartialLinesAndSymlinkAreIgnored() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let now = Date()
        try append(header(at: now), to: f.file)
        var scanner = PiSessionScanner(sessionsRoot: f.root)
        XCTAssertEqual(scanner.poll(now: now).map(\.event.kind), [.sessionStarted])
        let record = try message("user", id: "user1", at: now)
        try append(Data(record.prefix(record.count / 2)), to: f.file)
        XCTAssertTrue(scanner.poll(now: now).isEmpty)
        try append(Data(record.dropFirst(record.count / 2)), to: f.file)
        XCTAssertEqual(scanner.poll(now: now).map(\.event.kind), [.working])
        let link = f.file.deletingLastPathComponent().appendingPathComponent("linked.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.file)
        var otherScanner = PiSessionScanner(sessionsRoot: f.root)
        XCTAssertEqual(otherScanner.poll(now: now).count, 1)
    }
}
