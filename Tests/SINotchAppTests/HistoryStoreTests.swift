import XCTest
import SINotchCore
@testable import SINotch

final class HistoryStoreTests: XCTestCase {
    func testTurnCompletionDoesNotInheritTheNextTurnsWorkingStatus() throws {
        let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
        let store = try HistoryStore(directory: path, policy: .init())
        _ = try store.accept(event("old", kind: .working), session: session(.working))
        _ = try store.accept(event("old", kind: .completed), session: session(.working))
        _ = try store.accept(event("new", kind: .working), session: session(.working))
        try store.flush()
        let reopened = try HistoryStore(directory: path, policy: .init())
        XCTAssertEqual(reopened.ordered.first { $0.turnID == "old" }?.status, .completed)
        XCTAssertEqual(reopened.ordered.first { $0.turnID == "new" }?.status, .working)
    }

    func testLateTextAndToolEventsCannotReopenCompletedHistory() throws {
        let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
        let store = try HistoryStore(directory: path, policy: .init())
        _ = try store.accept(event(), session: session())
        for kind: AgentEventKind in [.usageUpdated, .toolStarted, .toolFinished, .working] {
            var late = event(kind: kind, items: [.init(id: kind.rawValue, role: .command, text: "swift test")])
            late.timestamp = Date().addingTimeInterval(1)
            _ = try store.accept(late, session: session(.working))
            XCTAssertEqual(store.ordered.first?.status, .completed, "\(kind) is not a new turn")
        }
    }

    func testPassiveTextKeepsTheArchivedTurnsStatusInsteadOfTheLiveSessionStatus() throws {
        let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
        let store = try HistoryStore(directory: path, policy: .init())
        _ = try store.accept(event(kind: .waiting), session: session(.waiting))
        _ = try store.accept(event(kind: .usageUpdated), session: session(.working))
        XCTAssertEqual(store.ordered.first?.status, .waiting)
    }

    func testTerminalReconciliationOnlyUpdatesAnExistingMatchingTurnAndPreservesContent() throws {
        let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
        let store = try HistoryStore(directory: path, policy: .init())
        _ = try store.accept(event(kind: .working), session: session(.working))
        try store.flush()
        let before = try XCTUnwrap(store.entry(store.ordered[0].id))
        var completion = event(kind: .completed, items: [])
        completion.firstPrompt = nil
        completion.sessionID = "other-session"
        XCTAssertFalse(try store.finish(completion))
        completion.sessionID = "session"
        completion.turnID = "other-turn"
        XCTAssertFalse(try store.finish(completion))
        completion.turnID = "turn-1"
        XCTAssertTrue(try store.finish(completion))
        XCTAssertFalse(try store.finish(completion))
        try store.flush()
        let reopened = try HistoryStore(directory: path, policy: .init())
        let after = try XCTUnwrap(reopened.entry(before.id))
        XCTAssertEqual(after.summary.status, .completed)
        XCTAssertEqual(after.items, before.items)
        XCTAssertEqual(after.summary.updatedAt, before.summary.updatedAt)
        XCTAssertEqual(reopened.ordered.count, 1)
    }

    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("si-notch-history-test-" + UUID().uuidString) }
    private func event(_ turn: String? = "turn-1", kind: AgentEventKind = .completed, items: [AgentHistoryItem]? = nil) -> AgentEvent {
        AgentEvent(sessionID: "session", provider: "codex", kind: kind, firstPrompt: "Fix the panel", turnID: turn,
            historyItems: items ?? [.init(id: "request", role: .user, text: "Fix the panel"),
                                   .init(id: "command", role: .command, text: "swift test"),
                                   .init(id: "reply", role: .assistant, text: "The panel is fixed.")])
    }
    private func session(_ status: AgentStatus = .completed) -> AgentSession {
        AgentSession(id: "session", provider: "codex", title: "Fix the panel", projectPath: "/work/project", status: status)
    }
    func testRoundTripRetainsRolesAndSeparatesTurnsWithoutLoadingAllContent() throws {
        let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
        let store = try HistoryStore(directory: path, policy: .init())
        XCTAssertTrue(try store.accept(event(), session: session()))
        XCTAssertTrue(try store.accept(event("turn-2"), session: session()))
        try store.flush()
        let reopened = try HistoryStore(directory: path, policy: .init())
        XCTAssertEqual(reopened.ordered.count, 2)
        let entry = try XCTUnwrap(reopened.entry(reopened.ordered[0].id))
        XCTAssertEqual(entry.items.map(\.role), [.user, .command, .assistant])
        XCTAssertEqual(entry.items.map(\.text), ["Fix the panel", "swift test", "The panel is fixed."])
        let index = try String(contentsOf: path.appendingPathComponent("index.json"), encoding: .utf8)
        XCTAssertFalse(index.contains("swift test"))
        XCTAssertFalse(index.contains("The panel is fixed."))
    }
    func testStreamingUpdatesReplaceItemAndDuplicateSourcesDoNotAppendCopies() throws {
        let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
        let store = try HistoryStore(directory: path, policy: .init())
        var update = event(kind: .working, items: [.init(id: "a", role: .assistant, text: "Checking")])
        update.firstPrompt = nil
        _ = try store.accept(update, session: session(.working))
        update.historyItems?[0].text = "Checking the window"
        _ = try store.accept(update, session: session(.working))
        update.historyItems?[0].id = "rollout-a"
        XCTAssertFalse(try store.accept(update, session: session(.working)))
        try store.flush()
        let entry = try XCTUnwrap(store.entry(store.ordered[0].id))
        XCTAssertEqual(entry.items.count, 1)
        XCTAssertEqual(entry.items[0].text, "Checking the window")
    }
    func testCountLimitPrunesOldestAndDisabledRecordingPreservesExisting() throws {
        let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
        let store = try HistoryStore(directory: path, policy: .init(count: 2))
        for n in 0..<3 {
            var e = event("turn-\(n)"); e.timestamp = Date(timeIntervalSince1970: Double(n + 1))
            _ = try store.accept(e, session: session())
        }
        try store.flush()
        XCTAssertEqual(store.ordered.compactMap(\.turnID), ["turn-2", "turn-1"])
        XCTAssertFalse(try store.accept(event("turn-0"), session: session()))
        try store.setPolicy(.init(enabled: false, count: 2))
        XCTAssertFalse(try store.accept(event("turn-4"), session: session()))
        XCTAssertEqual(store.ordered.count, 2)
        try store.setPolicy(.init(count: 1))
        XCTAssertEqual(store.ordered.map(\.turnID), ["turn-2"])
    }
    func testActualFileBytesIncludingIndexStayWithinLimitAndLongTurnsAreBounded() throws {
        let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
        let store = try HistoryStore(directory: path, policy: .init(count: 100, megabytes: 1))
        for n in 0..<12 {
            var e = event("turn-\(n)")
            e.historyItems = (0..<20).map { .init(id: "part-\($0)", role: .assistant, text: "\($0) " + String(repeating: "я👋\"", count: 5000)) }
            _ = try store.accept(e, session: session())
            try store.flush()
        }
        let children = try FileManager.default.contentsOfDirectory(at: path, includingPropertiesForKeys: [.fileSizeKey])
        let bytes = try children.reduce(0) { try $0 + ($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        XCTAssertLessThanOrEqual(bytes, 1024 * 1024)
        XCTAssertEqual(bytes, store.bytes)
        XCTAssertLessThan(store.ordered.count, 12)
        let entry = try XCTUnwrap(store.entry(store.ordered[0].id))
        XCTAssertTrue(entry.truncated)
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(entry).count, HistoryStore.maximumEntryBytes)
    }
    func testClearInvalidatesBufferedContentAndLateSnapshotAcrossRestart() throws {
        let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
        let store = try HistoryStore(directory: path, policy: .init())
        _ = try store.accept(event(), session: session())
        try store.clear(); try store.flush()
        XCTAssertTrue(store.ordered.isEmpty)
        let reopened = try HistoryStore(directory: path, policy: .init())
        XCTAssertFalse(try reopened.accept(event(), session: session()))
        XCTAssertTrue(try reopened.accept(event("new-turn"), session: session()))
        try reopened.flush()
        XCTAssertEqual(reopened.ordered.map(\.turnID), ["new-turn"])
    }
    func testClearLegacySessionAllowsDifferentNewPrompt() throws {
        let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
        let store = try HistoryStore(directory: path, policy: .init())
        _ = try store.accept(event(nil), session: session())
        try store.clear()
        XCTAssertFalse(try store.accept(event(nil), session: session()))
        var next = event(nil, kind: .working)
        next.firstPrompt = "Another request"
        next.historyItems = [.init(id: "new", role: .user, text: "Another request")]
        XCTAssertTrue(try store.accept(next, session: session(.working)))
    }
    func testPermissionAndToolResultMessagesAreExcludedAndKnownSecretsAreRedacted() throws {
        let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
        let store = try HistoryStore(directory: path, policy: .init())
        for kind: AgentEventKind in [.approvalRequested, .toolStarted, .toolFinished, .toolFailed, .waiting] {
            var e = event(kind: kind, items: [])
            e.firstPrompt = nil; e.message = "PRIVATE_TOOL_OUTPUT"
            XCTAssertFalse(try store.accept(e, session: session(.working)))
        }
        _ = try store.accept(event(items: [.init(id: "cmd", role: .command, text: "curl -H 'Authorization: Bearer abc.def' token=secret-value")]), session: session())
        try store.flush()
        let entry = try XCTUnwrap(store.entry(store.ordered[0].id))
        let command = try XCTUnwrap(entry.items.last(where: { $0.role == .command }))
        XCTAssertFalse(command.text.contains("secret-value"))
        XCTAssertFalse(command.text.contains("abc.def"))
    }
    func testOrphanRecordRecoveryAndPrivatePermissions() throws {
        let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
        let store = try HistoryStore(directory: path, policy: .init())
        _ = try store.accept(event(), session: session()); try store.flush()
        try FileManager.default.removeItem(at: path.appendingPathComponent("index.json"))
        let recovered = try HistoryStore(directory: path, policy: .init())
        XCTAssertEqual(recovered.ordered.count, 1)
        let directoryMode = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? Int
        let fileMode = try FileManager.default.attributesOfItem(atPath: path.appendingPathComponent(recovered.ordered[0].id.uuidString + ".json").path)[.posixPermissions] as? Int
        XCTAssertEqual(directoryMode, 0o700); XCTAssertEqual(fileMode, 0o600)
    }
    func testSymlinkRootIsRejectedAndEntryLinkDoesNotReadOrDeleteTarget() throws {
        let path = directory(), target = directory(), link = directory()
        defer { for url in [path, link, target] { try? FileManager.default.removeItem(at: url) } }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try HistoryStore(directory: link, policy: .init()))
        let store = try HistoryStore(directory: path, policy: .init())
        _ = try store.accept(event(), session: session()); try store.flush()
        let id = store.ordered[0].id
        let file = path.appendingPathComponent(id.uuidString + ".json")
        try FileManager.default.removeItem(at: file)
        let sentinel = target.appendingPathComponent("sentinel"); try Data("PRIVATE".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: sentinel)
        let reopened = try HistoryStore(directory: path, policy: .init())
        XCTAssertTrue(reopened.ordered.isEmpty)
        try reopened.clear()
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "PRIVATE")
    }
}
