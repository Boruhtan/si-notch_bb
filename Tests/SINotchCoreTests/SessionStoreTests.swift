import Foundation
import XCTest
@testable import SINotchCore

final class SessionStoreTests: XCTestCase {
    private func event(_ kind: AgentEventKind, session: String = "s", at time: TimeInterval = 100,
                       id: String? = nil, sequence: Int? = nil, tool: String? = nil) -> AgentEvent {
        AgentEvent(sessionID: session, provider: "claude", kind: kind, timestamp: Date(timeIntervalSince1970: time),
                   id: id, sequence: sequence, projectPath: "/tmp/project", toolName: tool)
    }

    func testLifecycleTransitionsAndTerminalToolCompletion() throws {
        var store = SessionStore()
        for (kind, expected) in [(AgentEventKind.sessionStarted, AgentStatus.idle), (.working, .working),
                                 (.approvalRequested, .approval), (.toolStarted, .working), (.waiting, .waiting),
                                 (.completed, .completed), (.toolFinished, .completed)] {
            XCTAssertEqual(store.apply(event(kind), receivedAt: Date(timeIntervalSince1970: 100)), .applied)
            XCTAssertEqual(store.sessions["s"]?.status, expected)
        }
        XCTAssertEqual(store.sessions["s"]?.title, "project")
        XCTAssertEqual(store.sessions["s"]?.id, "s")
    }

    func testDedupeIsScopedBySessionAndBounded() {
        var store = SessionStore(maximumRememberedEventIDs: 2)
        let first = event(.working, id: "one")
        XCTAssertEqual(store.apply(first), .applied)
        XCTAssertEqual(store.apply(first), .duplicate)
        XCTAssertEqual(store.apply(event(.working, session: "other", id: "one")), .applied)
        XCTAssertEqual(store.apply(event(.waiting, id: "two")), .applied)
        XCTAssertEqual(store.apply(first), .applied)
    }

    func testTimestampAndSequenceOrderingPreventRegression() {
        var store = SessionStore()
        XCTAssertEqual(store.apply(event(.completed, at: 200)), .applied)
        XCTAssertEqual(store.apply(event(.working, at: 100)), .outOfOrder)
        XCTAssertEqual(store.sessions["s"]?.status, .completed)
        store.clear()
        XCTAssertEqual(store.apply(event(.working, at: 200, sequence: 2)), .applied)
        XCTAssertEqual(store.apply(event(.completed, at: 300, sequence: 1)), .outOfOrder)
        XCTAssertEqual(store.apply(event(.completed, at: 190, sequence: 3)), .applied)
        XCTAssertEqual(store.sessions["s"]?.status, .completed)
        XCTAssertEqual(store.sessions["s"]?.lastEventAt, Date(timeIntervalSince1970: 200))
    }

    func testUnknownAndInvalidEventsCannotCreateSessions() {
        var store = SessionStore()
        XCTAssertEqual(store.apply(event(.unknown)), .ignoredUnknown)
        XCTAssertEqual(store.apply(event(.working, session: "../bad")), .invalid)
        XCTAssertTrue(store.sessions.isEmpty)
        _ = store.apply(event(.working))
        XCTAssertEqual(store.apply(AgentEvent(sessionID: "s", provider: "codex", kind: .completed)), .invalid)
        XCTAssertEqual(store.sessions["s"]?.provider, "claude")
    }

    func testExplicitEndCannotBeResurrectedExceptBySessionStart() {
        var store = SessionStore()
        _ = store.apply(event(.sessionEnded))
        _ = store.apply(event(.working, at: 101))
        XCTAssertEqual(store.sessions["s"]?.status, .ended)
        _ = store.apply(event(.sessionStarted, at: 102))
        _ = store.apply(event(.working, at: 103))
        XCTAssertEqual(store.sessions["s"]?.status, .working)
    }

    func testStaleExpiryUsesReceiveTimeAndFreshEventResumes() {
        var store = SessionStore()
        _ = store.apply(event(.working), receivedAt: Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(store.expireStaleSessions(now: Date(timeIntervalSince1970: 1059), timeout: 60), [])
        XCTAssertEqual(store.expireStaleSessions(now: Date(timeIntervalSince1970: 1060), timeout: 60), ["s"])
        XCTAssertEqual(store.sessions["s"]?.status, .ended)
        XCTAssertEqual(store.expireStaleSessions(now: Date(timeIntervalSince1970: 1100), timeout: 60), [])
        _ = store.apply(event(.working, at: 1100), receivedAt: Date(timeIntervalSince1970: 1100))
        XCTAssertEqual(store.sessions["s"]?.status, .working)
        XCTAssertEqual(store.expireStaleSessions(timeout: -1), [])
    }

    func testTaskSubagentAndUsageUpdatesMergeWithoutResettingStatus() throws {
        var store = SessionStore()
        _ = store.apply(event(.working))
        var update = event(.taskUpdated)
        update.task = AgentTask(id: "t1", title: "Tests")
        update.subagent = AgentSubagent(id: "a1", name: "Research")
        update.usage = AgentUsage(inputTokens: 100, outputTokens: 20)
        _ = store.apply(update)
        update.task?.status = .completed
        update.kind = .usageUpdated
        update.usage = AgentUsage(outputTokens: 30, primaryUsedPercent: 25)
        _ = store.apply(update)
        let session = try XCTUnwrap(store.sessions["s"])
        XCTAssertEqual(session.status, .working)
        XCTAssertEqual(session.tasks.count, 1)
        XCTAssertTrue(session.tasks[0].completed)
        XCTAssertEqual(session.subagents.count, 1)
        XCTAssertEqual(session.usage?.inputTokens, 100)
        XCTAssertEqual(session.usage?.outputTokens, 30)
        XCTAssertEqual(session.usage?.usedPercent, 25)
    }

    func testApprovalAndToolStateClearOnCompletion() {
        var store = SessionStore()
        var approval = event(.approvalRequested, tool: "Bash")
        approval.approvalID = "request-1"
        approval.targetURL = "codex://threads/s"
        approval.terminalBundleID = "com.apple.Terminal"
        _ = store.apply(approval)
        XCTAssertEqual(store.sessions["s"]?.approvalID, "request-1")
        XCTAssertEqual(store.sessions["s"]?.currentTool, "Bash")
        _ = store.apply(event(.completed))
        XCTAssertNil(store.sessions["s"]?.approvalID)
        XCTAssertNil(store.sessions["s"]?.currentTool)
        XCTAssertEqual(store.sessions["s"]?.terminalBundleID, "com.apple.Terminal")
    }

    func testCapacityRetainsLiveWorkAndOrderIsDeterministic() {
        var store = SessionStore(maximumSessions: 2)
        let now = Date(timeIntervalSince1970: 100)
        _ = store.apply(event(.working, session: "a"), receivedAt: now)
        _ = store.apply(event(.completed, session: "b"), receivedAt: now)
        _ = store.apply(event(.working, session: "c"), receivedAt: now)
        XCTAssertEqual(store.orderedSessions.map(\.id), ["a", "c"])
        XCTAssertNil(store.sessions["b"])
    }

    func testChildrenAreBoundedAndRecentUpdatesAreRetained() throws {
        var store = SessionStore(maximumTasksPerSession: 2, maximumSubagentsPerSession: 2)
        for index in 1...4 {
            var update = event(.taskUpdated, at: Double(index))
            update.task = AgentTask(id: "t\(index)", title: "Task \(index)")
            update.subagent = AgentSubagent(id: "a\(index)", name: "Agent \(index)")
            XCTAssertEqual(store.apply(update), .applied)
        }
        XCTAssertEqual(store.sessions["s"]?.tasks.map(\.id), ["t3", "t4"])
        XCTAssertEqual(store.sessions["s"]?.subagents.map(\.id), ["a3", "a4"])
        var update = event(.taskUpdated, at: 5)
        update.task = AgentTask(id: "t3", title: "Task 3 finished", status: .completed)
        update.subagent = AgentSubagent(id: "a3", name: "Agent 3", status: .completed)
        _ = store.apply(update)
        update.timestamp = Date(timeIntervalSince1970: 6)
        update.task = AgentTask(id: "t5", title: "Task 5")
        update.subagent = AgentSubagent(id: "a5", name: "Agent 5")
        _ = store.apply(update)
        let session = try XCTUnwrap(store.sessions["s"])
        XCTAssertEqual(session.tasks.map(\.id), ["t3", "t5"])
        XCTAssertTrue(session.tasks[0].completed)
        XCTAssertEqual(session.subagents.map(\.id), ["a3", "a5"])
        XCTAssertEqual(session.subagents[0].status, .completed)
    }

    func testPruneAndClear() {
        var store = SessionStore()
        let now = Date(timeIntervalSince1970: 100)
        _ = store.apply(event(.completed, session: "done"), receivedAt: now)
        _ = store.apply(event(.working, session: "live"), receivedAt: now)
        XCTAssertEqual(store.pruneSessions(now: Date(timeIntervalSince1970: 200), retention: 50), ["done"])
        XCTAssertNotNil(store.sessions["live"])
        store.removeSession(id: "live")
        XCTAssertTrue(store.sessions.isEmpty)
        store.clear()
        XCTAssertEqual(store.apply(event(.working, id: "again")), .applied)
    }
}
