import XCTest
@testable import SINotchCore

final class SessionMetadataTests: XCTestCase {
    func testModelSwitchCannotRetainThePreviousModelsReasoningMode() {
        var store = SessionStore()
        store.apply(AgentEvent(sessionID: "s", kind: .working, modelName: "first", reasoningEffort: "high"))
        store.apply(AgentEvent(sessionID: "s", kind: .toolStarted))
        XCTAssertEqual(store.sessions["s"]?.reasoningEffort, "high")
        store.apply(AgentEvent(sessionID: "s", kind: .usageUpdated, modelName: "second"))
        XCTAssertEqual(store.sessions["s"]?.modelName, "second")
        XCTAssertNil(store.sessions["s"]?.reasoningEffort)
        store.apply(AgentEvent(sessionID: "s", kind: .usageUpdated, modelName: "second", reasoningEffort: "low"))
        store.apply(AgentEvent(sessionID: "s", kind: .usageUpdated, modelName: "second", reasoningEffort: ""))
        XCTAssertEqual(store.sessions["s"]?.reasoningEffort, "")
    }

    func testNativeTaskRemovalAndFailedSubagentArePreserved() {
        var store = SessionStore()
        store.apply(AgentEvent(sessionID: "s", kind: .working))
        store.apply(AgentEvent(sessionID: "s", kind: .taskUpdated, task: AgentTask(id: "task", title: "Check settings")))
        store.apply(AgentEvent(sessionID: "s", kind: .taskUpdated, task: AgentTask(id: "task", title: "Check settings", status: .ended)))
        XCTAssertTrue(store.sessions["s"]!.tasks.isEmpty)
        store.apply(AgentEvent(sessionID: "s", kind: .subagentStarted, subagent: AgentSubagent(id: "child", name: "reviewer")))
        store.apply(AgentEvent(sessionID: "s", kind: .subagentEnded, subagent: AgentSubagent(id: "child", name: "reviewer", status: .failed)))
        XCTAssertEqual(store.sessions["s"]?.subagents.first?.status, .failed)
        XCTAssertEqual(store.sessions["s"]?.status, .working)
    }
}
