import Foundation
import XCTest
@testable import SINotch

final class CodexSessionObserverTests: XCTestCase {
    private let sessionID = "11111111-1111-4111-8111-111111111111"
    private let turnID = "22222222-2222-4222-8222-222222222222"

    private func fixture() throws -> (root: URL, file: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("si-notch-codex-observer-\(UUID().uuidString)", isDirectory: true)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.year, .month, .day], from: Date())
        let directory = root.appendingPathComponent(String(format: "%04d/%02d/%02d",
            parts.year!, parts.month!, parts.day!), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (root, directory.appendingPathComponent("rollout-test.jsonl"))
    }

    private func record(_ type: String, _ payload: [String: Any], at date: Date = Date()) throws -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var data = try JSONSerialization.data(withJSONObject: [
            "timestamp": formatter.string(from: date), "type": type, "payload": payload
        ], options: [.sortedKeys])
        data.append(10)
        return data
    }

    private func append(_ data: Data, to file: URL) throws {
        if !FileManager.default.fileExists(atPath: file.path) {
            try data.write(to: file)
        } else {
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        }
    }

    private func metadata(_ source: Any = "cli") throws -> Data {
        try record("session_meta", ["id": sessionID, "cwd": "/tmp/example-project", "source": source])
    }

    func testRichRolloutIncludesTaskAndPublicAssistantMessage() throws {
        let (root, file) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        try append(metadata("vscode"), to: file)
        try append(record("event_msg", ["type": "task_started", "turn_id": turnID], at: now), to: file)
        try append(record("response_item", ["type": "message", "role": "user", "content": [["type": "input_text", "text": "Fix clipping"]]], at: now), to: file)
        try append(record("response_item", ["type": "message", "role": "assistant", "phase": "commentary", "content": [["type": "output_text", "text": "Checking window geometry"]]], at: now), to: file)
        var scanner = CodexRolloutScanner(sessionsRoot: root, includeContent: true)
        let event = scanner.poll(now: now).first?.event
        XCTAssertEqual(event?.title, "Fix clipping")
        XCTAssertEqual(event?.message, "Checking window geometry")
    }

    func testActiveBootstrapAndCompletionContainNoConversationText() throws {
        let (root, file) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        try append(metadata(), to: file)
        try append(record("event_msg", ["type": "task_started", "turn_id": turnID], at: now), to: file)
        try append(record("event_msg", ["type": "token_count", "secret": "PRIVATE_PROMPT"], at: now), to: file)
        var scanner = CodexRolloutScanner(sessionsRoot: root)

        let initial = scanner.poll(now: now)
        XCTAssertEqual(initial.count, 1)
        XCTAssertEqual(initial.first?.event.kind, .working)
        XCTAssertEqual(initial.first?.event.provider, "codex")
        XCTAssertEqual(initial.first?.event.sessionID, sessionID)
        XCTAssertEqual(initial.first?.event.projectPath, "/tmp/example-project")
        XCTAssertEqual(initial.first?.isBootstrap, true)
        XCTAssertNil(initial.first?.event.message)
        XCTAssertNil(initial.first?.event.firstPrompt)
        XCTAssertNil(initial.first?.event.targetURL)
        XCTAssertNoThrow(try initial.first?.event.validate())
        XCTAssertTrue(scanner.poll(now: now).isEmpty)

        try append(record("event_msg", ["type": "task_complete", "turn_id": turnID,
            "last_agent_message": "PRIVATE_RESPONSE"], at: now), to: file)
        let completed = scanner.poll(now: now)
        XCTAssertEqual(completed.map(\.event.kind), [.completed])
        XCTAssertEqual(completed.first?.isBootstrap, false)
        XCTAssertNil(completed.first?.event.message)
        XCTAssertFalse(String(data: try JSONEncoder().encode(completed[0].event), encoding: .utf8)!
            .contains("PRIVATE_RESPONSE"))
        XCTAssertTrue(scanner.poll(now: now).isEmpty)
    }

    func testCompletedHistoryIsNotReplayed() throws {
        let (root, file) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try append(metadata(), to: file)
        try append(record("event_msg", ["type": "task_started", "turn_id": turnID]), to: file)
        try append(record("event_msg", ["type": "task_complete", "turn_id": turnID]), to: file)
        var scanner = CodexRolloutScanner(sessionsRoot: root)
        XCTAssertTrue(scanner.poll().isEmpty)
    }

    func testIncrementalToolsAndPartialCompletion() throws {
        let (root, file) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try append(metadata(), to: file)
        var scanner = CodexRolloutScanner(sessionsRoot: root)
        XCTAssertTrue(scanner.poll().isEmpty)

        try append(record("event_msg", ["type": "task_started", "turn_id": turnID]), to: file)
        XCTAssertEqual(scanner.poll().map(\.event.kind), [.working])
        try append(record("response_item", ["type": "function_call", "name": "exec_command",
            "call_id": "call_1", "arguments": "PRIVATE_COMMAND" ]), to: file)
        let start = scanner.poll()
        XCTAssertEqual(start.map(\.event.kind), [.toolStarted])
        XCTAssertEqual(start.first?.event.toolName, "exec_command")
        XCTAssertNil(start.first?.event.message)
        try append(record("response_item", ["type": "function_call_output", "call_id": "call_1",
            "output": "PRIVATE_OUTPUT"]), to: file)
        XCTAssertEqual(scanner.poll().map(\.event.kind), [.toolFinished])

        let completion = try record("event_msg", ["type": "task_complete", "turn_id": turnID])
        try append(Data(completion.prefix(completion.count / 2)), to: file)
        XCTAssertTrue(scanner.poll().isEmpty)
        try append(Data(completion.dropFirst(completion.count / 2)), to: file)
        XCTAssertEqual(scanner.poll().map(\.event.kind), [.completed])
    }

    func testSubagentAndUnsafeCallIdentifierAreIgnored() throws {
        let (root, file) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try append(metadata(["subagent": ["parent_thread_id": sessionID]]), to: file)
        try append(record("event_msg", ["type": "task_started", "turn_id": turnID]), to: file)
        var scanner = CodexRolloutScanner(sessionsRoot: root)
        XCTAssertTrue(scanner.poll().isEmpty)

        try FileManager.default.removeItem(at: file)
        try append(metadata(), to: file)
        XCTAssertTrue(scanner.poll().isEmpty)
        try append(record("event_msg", ["type": "task_started", "turn_id": turnID]), to: file)
        XCTAssertEqual(scanner.poll().map(\.event.kind), [.working])
        try append(record("response_item", ["type": "function_call", "name": "exec_command",
            "call_id": "bad id", "arguments": "ignored"]), to: file)
        XCTAssertTrue(scanner.poll().isEmpty)
    }

    func testNativeInternalRolloutsAreIgnoredButCustomIntegrationsAreObserved() throws {
        for source in [["internal": "memory_consolidation"], ["internal": "guardian"], ["custom": "integration"]] {
            let (root, file) = try fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            try append(metadata(source), to: file)
            try append(record("event_msg", ["type": "task_started", "turn_id": turnID]), to: file)
            var scanner = CodexRolloutScanner(sessionsRoot: root)
            let events = scanner.poll().map(\.event)
            if source["custom"] != nil {
                XCTAssertEqual(events.count, 1)
                XCTAssertEqual(events.first?.isInternalSession, false)
            } else { XCTAssertTrue(events.isEmpty) }
        }
    }

    func testSilenceMovesWorkingSessionIdleUntilFreshActivity() throws {
        let (root, file) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        try append(metadata(), to: file)
        try append(record("event_msg", ["type": "task_started", "turn_id": turnID], at: now), to: file)
        var scanner = CodexRolloutScanner(sessionsRoot: root)
        XCTAssertEqual(scanner.poll(now: now).map(\.event.kind), [.working])
        let later = now.addingTimeInterval(15 * 60 + 1)
        XCTAssertEqual(scanner.poll(now: later).map(\.event.kind), [.sessionStarted])
        XCTAssertTrue(scanner.poll(now: later).isEmpty)
        try append(record("event_msg", ["type": "token_count"], at: later), to: file)
        XCTAssertEqual(scanner.poll(now: later).map(\.event.kind), [.working])
    }

    func testOldActiveTurnBecomesVisibleOnlyOnFreshActivity() throws {
        let (root, file) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        try append(metadata(), to: file)
        try append(record("event_msg", ["type": "task_started", "turn_id": turnID],
            at: now.addingTimeInterval(-10 * 60)), to: file)
        var scanner = CodexRolloutScanner(sessionsRoot: root)
        XCTAssertTrue(scanner.poll(now: now).isEmpty)
        try append(record("event_msg", ["type": "token_count"], at: now), to: file)
        XCTAssertEqual(scanner.poll(now: now).map(\.event.kind), [.working])
    }

    func testAbortAndCancellationClearBusyWithoutCompletion() throws {
        let (root, file) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try append(metadata(), to: file)
        var scanner = CodexRolloutScanner(sessionsRoot: root)
        XCTAssertTrue(scanner.poll().isEmpty)
        for terminal in ["turn_aborted", "turn_cancelled"] {
            try append(record("event_msg", ["type": "task_started", "turn_id": turnID]), to: file)
            XCTAssertEqual(scanner.poll().map(\.event.kind), [.working])
            try append(record("event_msg", ["type": terminal, "turn_id": turnID,
                "reason": "interrupted"]), to: file)
            let result = scanner.poll()
            XCTAssertEqual(result.map(\.event.kind), [.sessionStarted])
            XCTAssertFalse(result.contains { $0.event.kind == .completed })
            XCTAssertTrue(scanner.poll().isEmpty)
        }
    }

    func testFreshToolMakesOldTurnVisibleSoCompletionCanClearIt() throws {
        let (root, file) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        try append(metadata(), to: file)
        try append(record("event_msg", ["type": "task_started", "turn_id": turnID],
            at: now.addingTimeInterval(-10 * 60)), to: file)
        var scanner = CodexRolloutScanner(sessionsRoot: root)
        XCTAssertTrue(scanner.poll(now: now).isEmpty)
        try append(record("response_item", ["type": "function_call", "name": "exec_command",
            "call_id": "call_fresh", "arguments": "PRIVATE_COMMAND"], at: now), to: file)
        XCTAssertEqual(scanner.poll(now: now).map(\.event.kind), [.toolStarted])
        try append(record("event_msg", ["type": "task_complete", "turn_id": turnID], at: now), to: file)
        XCTAssertEqual(scanner.poll(now: now).map(\.event.kind), [.completed])
    }

    func testIDlessAbortRequiresTimestampAtOrAfterCurrentTurnStart() throws {
        let (root, file) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let started = now.addingTimeInterval(-30)
        try append(metadata(), to: file)
        var scanner = CodexRolloutScanner(sessionsRoot: root)
        XCTAssertTrue(scanner.poll(now: now).isEmpty)
        try append(record("event_msg", ["type": "task_started", "turn_id": turnID], at: started), to: file)
        XCTAssertEqual(scanner.poll(now: now).map(\.event.kind), [.working])

        try append(record("event_msg", ["type": "turn_aborted"],
            at: started.addingTimeInterval(-1)), to: file)
        XCTAssertTrue(scanner.poll(now: now).isEmpty)
        try append(record("event_msg", ["type": "turn_aborted", "turn_id": UUID().uuidString],
            at: now), to: file)
        XCTAssertTrue(scanner.poll(now: now).isEmpty)
        try append(record("event_msg", ["type": "turn_aborted", "turn_id": NSNull()],
            at: now), to: file)
        XCTAssertEqual(scanner.poll(now: now).map(\.event.kind), [.sessionStarted])

        let nextTurn = UUID().uuidString
        try append(record("event_msg", ["type": "task_started", "turn_id": nextTurn], at: now), to: file)
        XCTAssertEqual(scanner.poll(now: now).map(\.event.kind), [.working])
        try append(record("event_msg", ["type": "turn_cancelled"], at: now), to: file)
        XCTAssertEqual(scanner.poll(now: now).map(\.event.kind), [.sessionStarted])
    }
}
