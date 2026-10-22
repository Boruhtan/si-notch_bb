import XCTest
import SINotchCore
@testable import SINotch

final class TaskUsageTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_792_641_600)
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("task-usage-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func event(_ session: String, _ turn: String?, _ request: String, _ input: Int, _ output: Int,
                       parent: String? = nil, parentTurn: String? = nil, model: String = "model-a") -> AgentEvent {
        AgentEvent(sessionID: session, provider: "hermes", kind: .usageUpdated, timestamp: date,
                   usage: AgentUsage(inputTokens: input, outputTokens: output,
                   cachedInputTokens: input / 2, reasoningOutputTokens: output / 2, requestID: request,
                   parentSessionID: parent, parentTurnID: parentTurn), modelName: model, turnID: turn, connectionID: "host")
    }
    private func key(_ session: String) -> String { UsageSession.key(provider: "hermes", connection: "host", session: session) }
    private func assertConservation(_ store: UsageStore, file: StaticString = #filePath, line: UInt = #line) {
        let sessions = store.sessions.compactMap(\.counts).reduce(TokenCounts.zero) { $0.adding($1) }
        let tasks = TaskUsageIndex(sessions: store.sessions, groups: store.state.groups ?? [:]).tasks
        let total = tasks.compactMap(\.counts).reduce(TokenCounts.zero) { $0.adding($1) }
        XCTAssertEqual(total.input, sessions.input, file: file, line: line)
        XCTAssertEqual(total.output, sessions.output, file: file, line: line)
        XCTAssertEqual(Set(tasks.flatMap(\.items).map(\.id)).count, tasks.flatMap(\.items).count, file: file, line: line)
    }
    func testLateAndReusedChildBelongsToItsOriginalParentTurn() throws {
        let store = try UsageStore(directory: temporary(), roots: [])
        store.accept(event("root", "first", "r1", 100, 10))
        store.accept(event("root", "second", "r2", 200, 20))
        store.accept(event("child", "child-first", "c1", 30, 3, parent: "root", parentTurn: "first"))
        store.accept(event("child", "child-second", "c2", 40, 4, parent: "root", parentTurn: "second"))
        store.accept(event("grandchild", "deep", "g1", 5, 1, parent: "child", parentTurn: "child-first"))
        let index = TaskUsageIndex(sessions: store.sessions)
        XCTAssertEqual(index.task(session: key("root"), turn: "first")?.counts?.total, 149)
        XCTAssertEqual(index.task(session: key("root"), turn: "second")?.counts?.total, 264)
        XCTAssertEqual(index.task(session: key("child"), turn: "child-first")?.counts?.total, 149)
        XCTAssertEqual(index.tasks.count, 2)
        assertConservation(store)
    }
    func testUnknownParentAndTurnStayUnassignedAndZeroIsKnown() throws {
        let store = try UsageStore(directory: temporary(), roots: [])
        store.accept(event("root", "zero", "zero", 0, 0))
        store.accept(event("unknown", nil, "orphan", 20, 2))
        store.accept(AgentEvent(sessionID: "empty", provider: "hermes", kind: .working, timestamp: date, turnID: "pending", connectionID: "host"))
        let index = TaskUsageIndex(sessions: store.sessions)
        XCTAssertEqual(index.task(session: key("root"), turn: "zero")?.counts?.total, 0)
        XCTAssertNil(index.task(session: key("empty"), turn: "pending")?.counts)
        XCTAssertEqual(index.tasks.first(where: \.unassigned)?.counts?.total, 22)
        assertConservation(store)
    }
    func testDuplicateConflictRestartAndModelsKeepOneNumericFact() throws {
        let dir = try temporary()
        var store = try UsageStore(directory: dir, roots: [])
        let a = event("root", "t", "a", 100, 10)
        store.accept(a); store.accept(a); try store.flush()
        store = try UsageStore(directory: dir, roots: [])
        store.accept(a); store.accept(event("root", "t", "a", 999, 99))
        store.accept(event("root", "t", "b", 20, 2, model: "model-b"))
        let task = try XCTUnwrap(TaskUsageIndex(sessions: store.sessions).tasks.first)
        XCTAssertEqual(task.counts?.total, 132); XCTAssertTrue(task.partial)
        XCTAssertEqual(task.requestCount, 2)
        XCTAssertEqual(Set(task.items.compactMap(\.model)), ["model-a", "model-b"])
        assertConservation(store)
    }
    func testConflictingTurnIdentityCannotMoveAnExistingRequest() throws {
        let store = try UsageStore(directory: temporary(), roots: [])
        store.accept(event("s", "first", "r", 10, 2))
        store.accept(event("s", "second", "r", 10, 2))
        let index = TaskUsageIndex(sessions: store.sessions)
        XCTAssertEqual(index.task(session: key("s"), turn: "first")?.counts?.total, 12)
        XCTAssertTrue(index.task(session: key("s"), turn: "first")?.partial == true)
        XCTAssertNil(index.task(session: key("s"), turn: "second")?.counts)
        assertConservation(store)
    }
    func testMergeUndoAndRestartNeverChangeTotals() throws {
        let dir = try temporary()
        var store = try UsageStore(directory: dir, roots: [])
        store.accept(event("root", "first", "a", 100, 10)); store.accept(event("root", "second", "b", 20, 2))
        let ids = TaskUsageIndex(sessions: store.sessions).tasks.map(\.id)
        try store.group(ids, id: "group:test")
        store = try UsageStore(directory: dir, roots: [])
        let grouped = TaskUsageIndex(sessions: store.sessions, groups: store.state.groups ?? [:])
        XCTAssertEqual(grouped.tasks.count, 1); XCTAssertEqual(grouped.tasks[0].counts?.total, 132)
        XCTAssertEqual(grouped.task(session: key("root"), turn: "first")?.id, "group:test")
        XCTAssertThrowsError(try store.group(ids))
        assertConservation(store)
        try store.ungroup("group:test")
        XCTAssertEqual(TaskUsageIndex(sessions: store.sessions, groups: store.state.groups ?? [:]).tasks.count, 2)
        assertConservation(store)
    }
    func testUnknownChildIsExplicitlyIncompleteUntilItsUsageArrives() throws {
        let store = try UsageStore(directory: temporary(), roots: [])
        store.accept(event("root", "t", "r", 100, 10))
        store.accept(AgentEvent(sessionID: "root", provider: "hermes", kind: .subagentStarted, timestamp: date,
                   subagent: AgentSubagent(id: "child-card", name: "research", sessionID: "child", parentTurnID: "t"), connectionID: "host"))
        XCTAssertTrue(try XCTUnwrap(TaskUsageIndex(sessions: store.sessions).task(session: key("root"), turn: "t")).partial)
        store.accept(event("child", "c", "request", 0, 0, parent: "root", parentTurn: "t"))
        XCTAssertFalse(try XCTUnwrap(TaskUsageIndex(sessions: store.sessions).task(session: key("root"), turn: "t")).partial)
        assertConservation(store)
    }
    func testSplitSourcesUnionRequestsAndPreserveHistoricalRemainder() {
        var a = UsageSession(sessionID: "s", provider: "codex", date: date)
        a.turns["t"] = UsageTurn(counts: TokenCounts(input: 100, output: 10), date: date)
        a.requests = ["a": UsageRequest(id: "a", aggregateID: "t", turnID: "t", counts: TokenCounts(input: 100, output: 10), date: date)]
        var b = a
        b.requests = ["b": UsageRequest(id: "b", aggregateID: "t", turnID: "t", counts: TokenCounts(input: 20, output: 2), date: date)]
        b.turns["t"] = UsageTurn(counts: TokenCounts(input: 20, output: 2), date: date)
        let union = UsageStore.merge(a, b)
        XCTAssertEqual(union.counts?.total, 132)
        XCTAssertEqual(TaskUsageIndex(sessions: [union]).tasks.first?.counts?.total, 132)
        b.turns["t"]?.counts = TokenCounts(input: 200, output: 20)
        let historical = UsageStore.merge(a, b)
        let task = TaskUsageIndex(sessions: [historical]).tasks.first!
        XCTAssertEqual(task.counts?.total, 220); XCTAssertTrue(task.partial)
        XCTAssertEqual(task.requestCount, 2)
    }
    func testPiBranchesFollowParentsAcrossMetadataAndDoNotUseLatestUser() throws {
        var p = UsageLogParser()
        func row(_ type: String, _ id: String, _ parent: String? = nil, _ message: [String: Any]? = nil) -> [String: Any] {
            var r: [String: Any] = ["type": type, "id": id, "timestamp": "2026-10-22T08:00:00Z"]
            r["parentId"] = parent; r["message"] = message; return r
        }
        p.consume(row("session", "s"), provider: "pi")
        p.consume(row("message", "u1", nil, ["role": "user"]), provider: "pi")
        p.consume(row("message", "u2", "u1", ["role": "user"]), provider: "pi")
        p.consume(row("model_change", "m", "u1"), provider: "pi")
        let reply = row("message", "a", "m", ["role": "assistant", "stopReason": "stop", "usage": ["input": 5, "output": 2, "cacheRead": 10, "cacheWrite": 3]])
        p.consume(reply, provider: "pi"); p.consume(reply, provider: "pi")
        let index = TaskUsageIndex(sessions: [try XCTUnwrap(p.session)])
        let sid = UsageSession.key(provider: "pi", session: "s")
        XCTAssertEqual(index.task(session: sid, turn: "u1")?.counts?.total, 20)
        XCTAssertNil(index.task(session: sid, turn: "u2")?.counts)
        XCTAssertEqual(index.task(session: sid, turn: "u1")?.status, .completed)
    }
    func testCodexExplicitRootTurnOverridesLateParentActivityAndLegacyMirror() throws {
        var p = UsageLogParser()
        func consume(_ type: String, _ payload: [String: Any]) { p.consume(["type": type, "timestamp": "2026-10-22T08:00:00Z", "payload": payload], provider: "codex") }
        consume("session_meta", ["id": "child", "parent_thread_id": "root"])
        consume("event_msg", ["type": "task_started", "turn_id": "child-turn"])
        let counts: [String: Any] = ["input_tokens": 100, "output_tokens": 10, "cached_input_tokens": 50, "reasoning_output_tokens": 5]
        let record: [String: Any] = ["thread_id": "child", "session_id": "root", "turn_id": "child-turn", "root_turn_id": "original", "response_id": "r", "usage": counts, "turn_token_usage": counts]
        consume("token_usage_record", record); consume("token_usage_record", record)
        consume("event_msg", ["type": "token_count", "info": ["total_token_usage": counts]])
        let index = TaskUsageIndex(sessions: [try XCTUnwrap(p.session)])
        XCTAssertEqual(index.tasks.count, 1); XCTAssertEqual(index.tasks[0].turnID, "original")
        XCTAssertEqual(index.tasks[0].counts?.total, 110); XCTAssertEqual(index.tasks[0].requestCount, 1)
    }
    func testMigrationBacksUpAndRebuildsSourceWhileKeepingMissingHistory() throws {
        let dir = try temporary(), source = dir.appendingPathComponent("source"), journal = dir.appendingPathComponent("journal")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let file = source.appendingPathComponent("session.jsonl")
        let records: [[String: Any]] = [
            ["type": "session_meta", "timestamp": "2026-10-22T08:00:00Z", "payload": ["id": "s"]],
            ["type": "token_usage_record", "timestamp": "2026-10-22T08:00:01Z", "payload": ["thread_id": "s", "turn_id": "t", "response_id": "r", "usage": ["input_tokens": 10, "output_tokens": 2]]]]
        var data = Data()
        for record in records { data.append(try JSONSerialization.data(withJSONObject: record)); data.append(10) }
        try data.write(to: file)
        let first = try UsageStore(directory: journal, roots: [("codex", source)])
        for _ in 0..<4 { first.scan(timeBudget: 2) }; try first.flush()
        var old = first.state; old.version = 1
        old.files[file.path]?.parser.session?.requests = nil
        old.files[file.path]?.parser.session?.turns["t"]?.counts = TokenCounts(input: 999, output: 99)
        var orphan = UsageSession(sessionID: "gone", provider: "codex", date: date)
        orphan.turns["old"] = UsageTurn(counts: TokenCounts(input: 20, output: 2), date: date)
        var cursor = UsageStore.Cursor(inode: 0); cursor.parser.session = orphan
        old.files[source.appendingPathComponent("deleted.jsonl").path] = cursor
        let oldData = try JSONEncoder().encode(old)
        try oldData.write(to: journal.appendingPathComponent("tokens.json"))
        let migrated = try UsageStore(directory: journal, roots: [("codex", source)])
        for _ in 0..<5 { migrated.scan(timeBudget: 2) }; try migrated.flush()
        XCTAssertEqual(migrated.sessions.first(where: { $0.sessionID == "s" })?.counts?.total, 12)
        XCTAssertEqual(migrated.sessions.first(where: { $0.sessionID == "gone" })?.counts?.total, 22)
        let backup = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: journal, includingPropertiesForKeys: nil).first { $0.pathExtension == "backup" })
        XCTAssertEqual(try Data(contentsOf: backup), oldData)
        assertConservation(migrated)
    }
    @MainActor
    func testCommitAcknowledgementComesAfterDurableJournalWrite() async throws {
        let dir = try temporary()
        let controller = UsageController()
        controller.start(directory: dir, roots: [])
        let accepted = await withCheckedContinuation { continuation in
            controller.commit(event("root", "t", "r", 100, 10)) { continuation.resume(returning: $0) }
        }
        XCTAssertTrue(accepted)
        let saved = try JSONDecoder().decode(UsageStore.State.self, from: Data(contentsOf: dir.appendingPathComponent("tokens.json")))
        XCTAssertEqual(saved.events[key("root")]?.counts?.total, 110)
        XCTAssertTrue(saved.requestIDs[key("root")]?.contains("r") == true)
        controller.shutdown()
    }
    func testStorageLimitFailureCannotAcknowledgeUnsavedCounts() throws {
        let dir = try temporary()
        let store = try UsageStore(directory: dir, roots: [], maximumBytes: 32)
        store.accept(event("s", "t", "r", 10, 2))
        XCTAssertThrowsError(try store.flush())
        store.restoreLastSaved()
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("tokens.json").path))
    }
    func testInvalidSubsetsAreUnknownAndNeverAddedToTotal() {
        let counts = TokenCounts(input: 10, output: 2, cached: 20, cacheWrite: -1, reasoning: 3)
        XCTAssertEqual(counts.total, 12); XCTAssertNil(counts.cached); XCTAssertNil(counts.cacheWrite); XCTAssertNil(counts.reasoning)
        XCTAssertEqual(TokenCounts(input: 100, output: 20, cached: 80, reasoning: 10).total, 120)
    }
    func testRealHermesParentChildAndAuxiliaryUsageSurviveReplayAndRestart() throws {
        // Numeric trace from a real parent, one native child, and title generation.
        let dir = try temporary()
        var store = try UsageStore(directory: dir, roots: [])
        let trace: [(String, String, Int, Int, Int, Int, String?)] = [
            ("root", "title", 493, 73, 0, 0, "auxiliary"),
            ("root", "api-1", 24637, 176, 3968, 0, nil),
            ("root", "api-2", 25121, 50, 24448, 30, nil),
            ("child", "api-1", 19484, 88, 3712, 55, nil),
            ("child", "api-2", 19684, 10, 19328, 0, nil)]
        let events = trace.map { session, request, input, output, cached, reasoning, kind in
            AgentEvent(sessionID: session, provider: "hermes", kind: .usageUpdated, timestamp: date,
                usage: AgentUsage(inputTokens: input, outputTokens: output, cachedInputTokens: cached,
                    cacheWriteInputTokens: 0, reasoningOutputTokens: reasoning, requestID: request,
                    parentSessionID: session == "child" ? "root" : nil,
                    parentTurnID: session == "child" ? "root-turn" : nil, callKind: kind),
                turnID: session + "-turn", connectionID: "host")
        }
        for _ in 0..<4 { for event in events { store.accept(event) }; try store.flush() }
        store = try UsageStore(directory: dir, roots: [])
        for event in events { store.accept(event) }; try store.flush()
        let tasks = TaskUsageIndex(sessions: store.sessions).tasks
        let task = try XCTUnwrap(tasks.first)
        XCTAssertEqual(tasks.count, 1); XCTAssertEqual(task.requestCount, 5); XCTAssertFalse(task.partial)
        XCTAssertEqual(task.counts, TokenCounts(input: 89419, output: 397, cached: 51456, cacheWrite: 0, reasoning: 85))
        XCTAssertEqual(store.sessions.first { $0.sessionID == "root" }?.counts?.total, 50550)
        XCTAssertEqual(store.sessions.first { $0.sessionID == "child" }?.counts?.total, 39266)
        assertConservation(store)
    }
    func testAuditLiveJournalCopyWhenRequested() throws {
        guard let output = ProcessInfo.processInfo.environment["SI_NOTCH_TASK_AUDIT_DIR"] else { throw XCTSkip("Opt-in private journal audit") }
        let directory = URL(fileURLWithPath: output)
        let home = FileManager.default.homeDirectoryForCurrentUser
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = home.appendingPathComponent("Library/Application Support/si-notch/Usage/tokens.json")
        try FileManager.default.copyItem(at: original, to: directory.appendingPathComponent("tokens.json"))
        let store = try UsageStore(directory: directory, roots: [("codex", home.appendingPathComponent(".codex/sessions")), ("codex", home.appendingPathComponent(".codex/archived_sessions")), ("pi", home.appendingPathComponent(".pi/agent/sessions"))])
        var passes = 0
        let started = Date()
        repeat { store.scan(timeBudget: 0.4); passes += 1 } while store.incomplete && passes < 3000
        try store.flush(); XCTAssertFalse(store.incomplete); assertConservation(store)
        let tasks = TaskUsageIndex(sessions: store.sessions).tasks
        print("TASK_AUDIT sessions=\(store.sessions.count) tasks=\(tasks.count) requests=\(tasks.reduce(0) { $0 + $1.requestCount }) unassigned=\(tasks.filter(\.unassigned).count) seconds=\(Date().timeIntervalSince(started))")
    }
}
