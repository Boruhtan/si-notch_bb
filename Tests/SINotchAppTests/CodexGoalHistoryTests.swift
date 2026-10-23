import XCTest
import SINotchCore
@testable import SINotch

final class CodexGoalHistoryTests: XCTestCase {
    private let sid = "11111111-2222-4333-8444-555555555555"
    private let turn = "11111111-2222-4333-8444-666666666666"
    private let resumed = "11111111-2222-4333-8444-777777777777"
    private let created = 1792761979.0

    private func goal(_ status: String, updated: Double = 90) -> [String: Any] {
        ["threadId": sid, "objective": "Ship the app", "status": status, "createdAt": created, "updatedAt": created + updated]
    }
    private func row(_ type: String, _ payload: [String: Any], at offset: Double = 0) -> [String: Any] {
        ["timestamp": ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: created + offset)), "type": type, "payload": payload]
    }
    private func initial() -> [[String: Any]] {
        [row("session_meta", ["id": sid, "source": "cli"]),
         row("event_msg", ["type": "task_started", "turn_id": turn]),
         row("event_msg", ["type": "thread_goal_updated", "threadId": sid, "goal": goal("active", updated: 0)]),
         row("event_msg", ["type": "turn_aborted", "turn_id": turn], at: 30),
         row("event_msg", ["type": "task_started", "turn_id": resumed], at: 60)]
    }
    private func target(turnID: String? = nil, title: String = "/goal Ship the app") throws -> HistorySummary {
        HistorySummary(id: UUID(), sessionKey: try HistoryStore.sessionKey(AgentEvent(sessionID: sid, provider: "codex", kind: .working)),
            turnID: turnID ?? turn, title: title, provider: "codex", project: nil,
            startedAt: Date(timeIntervalSince1970: created), updatedAt: Date(timeIntervalSince1970: created + 30),
            status: .ended, memoryService: false, bytes: 0)
    }
    private func fixture(_ rows: [[String: Any]]) throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("si-notch-goal-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("2026/10/23")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("rollout-test-\(sid).jsonl")
        try encoded(rows).write(to: file)
        return (root, file)
    }
    private func encoded(_ rows: [[String: Any]]) throws -> Data {
        var data = Data()
        for row in rows { data.append(try JSONSerialization.data(withJSONObject: row)); data.append(10) }
        return data
    }
    private func call(_ script: String = "text(await tools.update_goal({status:\"complete\"}));") -> [String: Any] {
        row("response_item", ["type": "custom_tool_call", "name": "functions.exec", "call_id": "complete", "input": script], at: 90)
    }
    private func reply(_ value: [String: Any]? = nil, callID: String = "complete") throws -> [String: Any] {
        let envelope: [String: Any] = ["goal": value ?? goal("complete"), "remainingTokens": NSNull(), "completionBudgetReport": NSNull()]
        let text = String(decoding: try JSONSerialization.data(withJSONObject: envelope), as: UTF8.self)
        return row("response_item", ["type": "custom_tool_call_output", "call_id": callID,
            "output": [["type": "input_text", "text": "Script completed"], ["type": "input_text", "text": text]]], at: 90)
    }
    func testResumedGoalCompletionRetainsItsOriginalTurnAcrossSmallChunks() throws {
        let (root, _) = try fixture(initial() + [call(), reply()])
        var scanner = CodexGoalHistoryScanner(sessionsRoot: root)
        var found: [CodexGoalHistoryCompletion] = []
        repeat { found += scanner.poll(targets: [try target()], maximumBytes: 73) } while scanner.hasPendingBytes
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.originalTurnID, turn)
        XCTAssertEqual(found.first?.objective, "Ship the app")
        XCTAssertTrue(scanner.poll(targets: [try target()]).isEmpty)
    }
    func testNativeGoalCompletionAndIncrementalDelivery() throws {
        let (root, file) = try fixture(initial())
        var scanner = CodexGoalHistoryScanner(sessionsRoot: root)
        XCTAssertTrue(scanner.poll(targets: [try target()]).isEmpty)
        let bytes = try encoded([row("event_msg", ["type": "thread_goal_updated", "threadId": sid, "goal": goal("complete")], at: 90)])
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: bytes); try handle.close()
        XCTAssertEqual(scanner.poll(targets: [try target()]).first?.originalTurnID, turn)
    }
    func testOrdinaryCompletionUncorrelatedOutputAndArbitraryScriptsCannotCompleteGoal() throws {
        for ending in [
            [row("event_msg", ["type": "task_complete", "turn_id": resumed], at: 90)],
            [try reply()],
            [call("const example = 'tools.update_goal({status:complete})';"), try reply()],
            [call(), try reply(callID: "other")],
            [call(), try reply(goal("paused"))]
        ] {
            let (root, _) = try fixture(initial() + ending)
            var scanner = CodexGoalHistoryScanner(sessionsRoot: root)
            XCTAssertTrue(scanner.poll(targets: [try target()]).isEmpty)
        }
    }
    func testForeignGoalAndWrongObjectiveAreRejected() throws {
        for field in ["threadId", "objective"] {
            var wrong = goal("complete"); wrong[field] = "other"
            let (root, _) = try fixture(initial() + [call(), reply(wrong)])
            var scanner = CodexGoalHistoryScanner(sessionsRoot: root)
            XCTAssertTrue(scanner.poll(targets: [try target()]).isEmpty)
        }
        let (root, _) = try fixture(initial() + [call(), reply()])
        var scanner = CodexGoalHistoryScanner(sessionsRoot: root)
        XCTAssertTrue(scanner.poll(targets: [try target(title: "Ship the app")]).isEmpty)
    }
    func testNewArchiveTargetRewindsOnlyItsSessionAndSymlinkIsNotRead() throws {
        let (root, file) = try fixture(initial() + [call(), reply()])
        var scanner = CodexGoalHistoryScanner(sessionsRoot: root)
        XCTAssertTrue(scanner.poll(targets: [try target(turnID: resumed)]).isEmpty)
        XCTAssertEqual(scanner.poll(targets: [try target(turnID: resumed), try target()]).count, 1)
        let original = file.appendingPathExtension("original")
        try FileManager.default.moveItem(at: file, to: original)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: original)
        var linked = CodexGoalHistoryScanner(sessionsRoot: root)
        XCTAssertTrue(linked.poll(targets: [try target()]).isEmpty)
        XCTAssertFalse(linked.hasPendingBytes)
    }
    func testLongUnrelatedOutputAndIncompleteTailDoNotHideLaterGoalCompletion() throws {
        let (root, file) = try fixture(initial())
        let ending = try encoded([call(), reply()])
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: Data(repeating: 120, count: 300_000))
        try handle.write(contentsOf: Data([10])); try handle.write(contentsOf: ending.dropLast()); try handle.close()
        var scanner = CodexGoalHistoryScanner(sessionsRoot: root)
        var found: [CodexGoalHistoryCompletion] = []
        repeat { found += scanner.poll(targets: [try target()], maximumBytes: 4096) } while scanner.hasPendingBytes
        XCTAssertTrue(found.isEmpty)
        let tail = try FileHandle(forWritingTo: file); try tail.seekToEnd(); try tail.write(contentsOf: Data([10])); try tail.close()
        XCTAssertEqual(scanner.poll(targets: [try target()]).count, 1)
    }
    func testLiveGoalEvidenceWhenExplicitlyRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["SI_NOTCH_GOAL_LIVE_CHECK_ROLLOUT"] else {
            throw XCTSkip("Opt-in read-only goal history check")
        }
        let file = URL(fileURLWithPath: path)
        let id = String(file.deletingPathExtension().lastPathComponent.suffix(36))
        let key = try HistoryStore.sessionKey(AgentEvent(sessionID: id, provider: "codex", kind: .working))
        struct Index: Decodable { let entries: [HistorySummary] }
        let index = try JSONDecoder().decode(Index.self, from: Data(contentsOf: HistoryController.defaultDirectory.appendingPathComponent("index.json")))
        let targets = index.entries.filter { $0.sessionKey == key && CodexGoalHistoryScanner.isGoalTitle($0.title) }
        XCTAssertFalse(targets.isEmpty)
        var root = file
        for _ in 0..<4 { root.deleteLastPathComponent() }
        var scanner = CodexGoalHistoryScanner(sessionsRoot: root)
        var found: [CodexGoalHistoryCompletion] = [], passes = 0
        repeat { found += scanner.poll(targets: targets); passes += 1 } while scanner.hasPendingBytes && passes < 256
        XCTAssertFalse(scanner.hasPendingBytes)
        XCTAssertEqual(found.count, targets.filter { $0.status != .completed }.count)
        XCTAssertTrue(found.allSatisfy { completion in targets.contains { $0.turnID == completion.originalTurnID } })
        print("GOAL_LIVE matched=\(found.count) passes=\(passes); source and production history unchanged")
    }
}
