import XCTest
import SINotchCore
@testable import SINotch

final class TokenUsageTests: XCTestCase {
    private let stamp = "2026-10-22T08:00:00Z"
    private func row(_ type: String, _ payload: [String: Any], at: String? = nil) -> [String: Any] {
        ["type": type, "timestamp": at ?? stamp, "payload": payload]
    }
    private func counts(_ input: Int, _ output: Int) -> [String: Any] {
        ["input_tokens": input, "output_tokens": output, "cached_input_tokens": input / 2, "reasoning_output_tokens": output / 2, "cache_write_input_tokens": 0]
    }
    private func start(_ parser: inout UsageLogParser, parent: String? = nil) {
        var meta: [String: Any] = ["id": "session", "cwd": "/project"]
        if let parent { meta["parent_thread_id"] = parent }
        parser.consume(row("session_meta", meta), provider: "codex")
        parser.consume(row("event_msg", ["type": "task_started", "turn_id": "turn"]), provider: "codex")
    }
    private func owned(_ parser: inout UsageLogParser, id: String, input: Int, output: Int, cumulative: [String: Any]? = nil) {
        var payload: [String: Any] = ["thread_id": "session", "session_id": "root", "turn_id": "turn", "response_id": id, "usage": counts(input, output)]
        if let cumulative { payload["turn_token_usage"] = cumulative }
        parser.consume(row("token_usage_record", payload), provider: "codex")
    }
    private func legacy(_ parser: inout UsageLogParser, input: Int, output: Int) {
        parser.consume(row("event_msg", ["type": "token_count", "info": ["total_token_usage": counts(input, output)]]), provider: "codex")
    }
    func testOwnedResponsesMirrorsAndResumedCountersCountOnce() throws {
        var parser = UsageLogParser(); start(&parser)
        owned(&parser, id: "a", input: 100, output: 10, cumulative: counts(100, 10))
        legacy(&parser, input: 100, output: 10)
        owned(&parser, id: "a", input: 100, output: 10, cumulative: counts(100, 10))
        // The resumed counter reset does not erase or duplicate the first request.
        owned(&parser, id: "b", input: 40, output: 5, cumulative: counts(40, 5))
        legacy(&parser, input: 40, output: 5)
        XCTAssertEqual(parser.session?.counts?.total, 155)
        XCTAssertEqual(parser.session?.counts?.input, 140)
        XCTAssertEqual(parser.session?.counts?.cached, 70)
        XCTAssertFalse(try XCTUnwrap(parser.session).partial)
    }
    func testLegacyBeforeOwnedIsReplacedAndDuplicateTotalsIgnored() {
        var parser = UsageLogParser(); start(&parser)
        legacy(&parser, input: 100, output: 10); legacy(&parser, input: 100, output: 10)
        owned(&parser, id: "a", input: 100, output: 10, cumulative: counts(100, 10))
        XCTAssertEqual(parser.session?.counts?.total, 110)
    }
    func testLegacyResetDoesNotInventNewSpend() {
        var parser = UsageLogParser(); start(&parser)
        legacy(&parser, input: 100, output: 10)
        legacy(&parser, input: 50, output: 5)
        legacy(&parser, input: 100, output: 10)
        XCTAssertEqual(parser.session?.counts?.total, 110)
        XCTAssertEqual(parser.session?.partial, true)
    }
    func testChildOwnsThreadNotExecutionSessionAndExcludesCopiedParentHistory() {
        var parser = UsageLogParser()
        parser.consume(row("session_meta", ["id": "session", "parent_thread_id": "parent"]), provider: "codex")
        legacy(&parser, input: 900, output: 90)
        parser.consume(row("token_usage_record", ["thread_id": "parent", "turn_id": "old", "response_id": "old", "usage": counts(900, 90)]), provider: "codex")
        parser.consume(row("event_msg", ["type": "task_started", "turn_id": "turn"]), provider: "codex")
        owned(&parser, id: "child", input: 20, output: 2, cumulative: counts(20, 2))
        legacy(&parser, input: 20, output: 2)
        XCTAssertEqual(parser.session?.counts?.total, 22)
        XCTAssertEqual(parser.session?.parentID, UsageSession.key(provider: "codex", session: "parent"))
    }
    func testPiCacheInputAndDuplicateMessages() {
        var parser = UsageLogParser()
        parser.consume(["type": "session", "id": "pi", "timestamp": stamp], provider: "pi")
        let message: [String: Any] = ["type": "message", "id": "reply", "timestamp": stamp, "message": ["role": "assistant", "usage": ["input": 20, "output": 5, "cacheRead": 100, "cacheWrite": 10, "reasoning": 3]]]
        parser.consume(message, provider: "pi"); parser.consume(message, provider: "pi")
        XCTAssertEqual(parser.session?.counts?.input, 130)
        XCTAssertEqual(parser.session?.counts?.total, 135)
        XCTAssertEqual(parser.session?.counts?.reasoning, 3)
        XCTAssertNil(TokenCounts.pi(["input": true, "output": 1]))
        XCTAssertNil(TokenCounts.pi(["input": -1, "output": 1]))
        XCTAssertNil(TokenCounts.pi(["input": 1.5, "output": 1]))
    }
    func testMissingUsageStaysUnknownAndDoesNotPersistConversationText() throws {
        var parser = UsageLogParser(); start(&parser)
        parser.consume(row("response_item", ["type": "message", "role": "user", "content": "PRIVATE PROMPT"]), provider: "codex")
        XCTAssertNil(parser.session?.counts)
        let encoded = String(decoding: try JSONEncoder().encode(parser), as: UTF8.self)
        XCTAssertFalse(encoded.contains("PRIVATE PROMPT"))
    }
    func testIncrementalStoreReopenPartialTailAndDeletedSource() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("sessions"), journal = root.appendingPathComponent("journal")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let file = source.appendingPathComponent("session.jsonl")
        func data(_ object: [String: Any]) throws -> Data { var d = try JSONSerialization.data(withJSONObject: object); d.append(10); return d }
        var bytes = try data(row("session_meta", ["id": "session"]))
        bytes.append(try data(row("event_msg", ["type": "task_started", "turn_id": "turn"])))
        bytes.append(try data(row("event_msg", ["type": "token_count", "info": ["total_token_usage": counts(100, 10)]])))
        let next = try data(row("event_msg", ["type": "token_count", "info": ["total_token_usage": counts(150, 20)]]))
        bytes.append(next.prefix(20)); try bytes.write(to: file)
        var store = try UsageStore(directory: journal, roots: [("codex", source)])
        for _ in 0..<5 { store.scan(timeBudget: 2) }; try store.flush()
        XCTAssertEqual(store.sessions.first?.counts?.total, 110)
        store = try UsageStore(directory: journal, roots: [("codex", source)])
        let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd(); try handle.write(contentsOf: next.dropFirst(20)); try handle.close()
        for _ in 0..<5 { store.scan(timeBudget: 2) }; try store.flush()
        XCTAssertEqual(store.sessions.first?.counts?.total, 170)
        // Log rotation must not erase already recorded turns.
        try data(row("session_meta", ["id": "session"])).write(to: file, options: .atomic)
        for _ in 0..<3 { store.scan(timeBudget: 2) }; try store.flush()
        XCTAssertEqual(store.sessions.first?.counts?.total, 170)
        try FileManager.default.removeItem(at: file)
        store = try UsageStore(directory: journal, roots: [("codex", source)])
        store.scan(timeBudget: 2)
        XCTAssertEqual(store.sessions.first?.counts?.total, 170)
        let mode = try FileManager.default.attributesOfItem(atPath: journal.appendingPathComponent("tokens.json").path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }
    func testHermesRequestsPersistDeduplicationAndChildIdentity() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        var store = try UsageStore(directory: dir, roots: [])
        let event = AgentEvent(sessionID: "parent", provider: "hermes", kind: .usageUpdated,
            usage: AgentUsage(inputTokens: 100, outputTokens: 10, requestID: "req"), turnID: "turn", connectionID: "host")
        store.accept(event); store.accept(event)
        store.accept(AgentEvent(sessionID: "parent", provider: "hermes", kind: .subagentStarted,
            subagent: AgentSubagent(id: "child-card", name: "research", sessionID: "child"), connectionID: "host"))
        try store.flush()
        store = try UsageStore(directory: dir, roots: []); store.accept(event)
        XCTAssertEqual(store.sessions.compactMap(\.counts).reduce(0) { $0 + $1.total }, 110)
        XCTAssertEqual(store.sessions.first { $0.sessionID == "child" }?.parentID,
                       UsageSession.key(provider: "hermes", connection: "host", session: "parent"))
        XCTAssertNotEqual(UsageSession.key(provider: "hermes", connection: "other", session: "parent"), store.sessions.first { $0.sessionID == "parent" }?.id)
    }
    func testLiveReadOnlyUsageScanWhenRequested() throws {
        guard ProcessInfo.processInfo.environment["SI_NOTCH_USAGE_LIVE_CHECK"] == "1" else { throw XCTSkip("Opt-in local metadata check") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("si-notch-usage-live-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let store = try UsageStore(directory: dir, roots: [("codex", home.appendingPathComponent(".codex/sessions")), ("pi", home.appendingPathComponent(".pi/agent/sessions"))])
        let start = Date()
        var passes = 0
        repeat { store.scan(timeBudget: 0.4); passes += 1 } while store.incomplete && passes < 2000
        try store.flush()
        XCTAssertFalse(store.incomplete)
        XCTAssertFalse(store.sessions.isEmpty)
        XCTAssertTrue(store.sessions.contains { $0.provider == "pi" && $0.counts != nil })
        XCTAssertTrue(store.sessions.contains { $0.provider == "codex" && $0.parentID != nil && $0.counts != nil })
        print("USAGE_LIVE sessions=\(store.sessions.count) children=\(store.sessions.filter { $0.parentID != nil }.count) passes=\(passes) seconds=\(Date().timeIntervalSince(start))")
    }
}
