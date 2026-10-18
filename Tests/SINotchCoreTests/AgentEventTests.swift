import Foundation
import XCTest
@testable import SINotchCore

final class AgentEventTests: XCTestCase {
    func testProfilePresenceRoundTripsAndRequiresAnIdentity() throws {
        let event = AgentEvent(sessionID: "presence-1", provider: "hermes", kind: .agentPresence, timestamp: Date(timeIntervalSince1970: 1000),
                               connectionID: "host:architect", connectionName: "Architect")
        XCTAssertEqual(try AgentEvent.parse(data: JSONEncoder().encode(event)), event)
        XCTAssertThrowsError(try AgentEvent.parse(data: Data(#"{"event":"agent.presence","session_id":"p","provider":"hermes"}"#.utf8)))
        XCTAssertThrowsError(try AgentEvent.parse(data: Data(#"{"event":"agent.presence","session_id":"p","provider":"hermes","connection_id":"bad id"}"#.utf8)))
    }
    func testTurnIdentityAliasesAndRoundTrip() throws {
        for key in ["turn_id", "turn-id", "turnID", "turnId"] {
            let data = try JSONSerialization.data(withJSONObject: ["session_id": "session", "provider": "custom", "event": "agent.working", key: "turn-7"])
            let event = try AgentEvent.parse(data: data)
            XCTAssertEqual(event.turnID, "turn-7")
            XCTAssertEqual(try AgentEvent.parse(data: JSONEncoder().encode(event)).turnID, "turn-7")
        }
        XCTAssertThrowsError(try AgentEvent.parse(data: Data(#"{"session_id":"s","event":"agent.working","turn_id":"invalid turn"}"#.utf8)))
    }

    private let now = Date(timeIntervalSince1970: 1000)

    private func parse(_ json: String) throws -> AgentEvent {
        try AgentEvent.parse(data: Data(json.utf8), receivedAt: now)
    }

    func testOwnEventRoundTripsIncludingStructuredPayloads() throws {
        let original = AgentEvent(sessionID: "session-1", provider: "codex", kind: .approvalRequested,
                                  timestamp: now, id: "event-1", sequence: 2, title: "Build", projectPath: "/tmp/project",
                                  message: "Approve command", toolName: "shell",
                                  task: AgentTask(id: "task-1", title: "Compile"),
                                  subagent: AgentSubagent(id: "worker-1", name: "Reviewer"),
                                  usage: AgentUsage(contextTokens: 500, contextWindow: 1000, primaryUsedPercent: 12.5),
                                  terminalBundleID: "com.apple.Terminal", targetURL: "codex://threads/session-1", approvalID: "request-1")
        XCTAssertEqual(try AgentEvent.parse(data: JSONEncoder().encode(original), receivedAt: now), original)
    }

    func testClaudePromptAndToolLifecycle() throws {
        let prompt = try parse(#"{"hook_event_name":"UserPromptSubmit","session_id":"claude-1","cwd":"/tmp/app","prompt":"Run tests"}"#)
        XCTAssertEqual(prompt.provider, "claude")
        XCTAssertEqual(prompt.kind, .working)
        XCTAssertEqual(prompt.message, "Run tests")
        XCTAssertEqual(prompt.timestamp, now)
        let tool = try parse(#"{"hook_event_name":"PreToolUse","session_id":"claude-1","tool_name":"Bash","tool_use_id":"toolu_1","tool_input":{"command":"swift test"}}"#)
        XCTAssertEqual(tool.kind, .toolStarted)
        XCTAssertEqual(tool.toolName, "Bash")
        XCTAssertEqual(tool.id, "tool.start:toolu_1")
        let done = try parse(#"{"hook_event_name":"PostToolUse","session_id":"claude-1","tool_name":"Bash","tool_use_id":"toolu_1"}"#)
        XCTAssertNotEqual(tool.id, done.id)
    }

    func testClaudeNotificationApprovalAndIdle() throws {
        XCTAssertEqual(try parse(#"{"hook_event_name":"Notification","session_id":"s","notification_type":"permission_prompt"}"#).kind, .approvalRequested)
        XCTAssertEqual(try parse(#"{"hook_event_name":"Notification","session_id":"s","notification_type":"idle_prompt"}"#).kind, .waiting)
        XCTAssertEqual(try parse(#"{"hook_event_name":"PermissionRequest","session_id":"s","tool_use_id":"t1"}"#).approvalID, "t1")
    }

    func testPostCompactResumesWorkingState() throws {
        let event = try parse(#"{"hook_event_name":"PostCompact","session_id":"s","cwd":"/tmp/app"}"#)
        XCTAssertEqual(event.provider, "claude")
        XCTAssertEqual(event.kind, .working)
        var store = SessionStore()
        _ = store.apply(AgentEvent(sessionID: "s", provider: "claude", kind: .waiting, timestamp: now))
        XCTAssertEqual(store.apply(event), .applied)
        XCTAssertEqual(store.sessions["s"]?.status, .working)
    }

    func testStopFailureMarksSessionFailed() throws {
        let event = try parse(#"{"hook_event_name":"StopFailure","session_id":"s","error":"API request failed"}"#)
        XCTAssertEqual(event.kind, .failed)
        XCTAssertEqual(event.message, "API request failed")
        var store = SessionStore()
        _ = store.apply(AgentEvent(sessionID: "s", provider: "claude", kind: .working, timestamp: now))
        XCTAssertEqual(store.apply(event), .applied)
        XCTAssertEqual(store.sessions["s"]?.status, .failed)
        XCTAssertEqual(store.sessions["s"]?.lastMessage, "API request failed")
    }

    func testCodexNotifyMapsTurnAndAssistantMessage() throws {
        let event = try parse(#"{"type":"agent-turn-complete","thread-id":"thread-1","turn-id":"turn-2","cwd":"/tmp/app","input-messages":["Fix tests"],"last-assistant-message":"Tests pass"}"#)
        XCTAssertEqual(event.provider, "codex")
        XCTAssertEqual(event.kind, .completed)
        XCTAssertEqual(event.sessionID, "thread-1")
        XCTAssertEqual(event.message, "Tests pass")
        XCTAssertEqual(event.id, "codex:thread-1:turn-2:agent.completed")
    }

    func testSubagentAndTaskHooks() throws {
        let started = try parse(#"{"hook_event_name":"SubagentStart","session_id":"s","agent_id":"a1","agent_type":"Explore"}"#)
        XCTAssertEqual(started.subagent, AgentSubagent(id: "a1", name: "Explore"))
        let ended = try parse(#"{"hook_event_name":"SubagentStop","session_id":"s","agent_id":"a1","agent_type":"Explore"}"#)
        XCTAssertEqual(ended.subagent?.status, .completed)
        let task = try parse(#"{"hook_event_name":"TaskCompleted","session_id":"s","task_id":"t1","task_subject":"Tests"}"#)
        XCTAssertEqual(task.task?.title, "Tests")
        XCTAssertEqual(task.task?.completed, true)
    }

    func testMalformedIDsAreRejected() throws {
        for id in ["", "../escape", "white space", "line\nbreak", "emoji🦀", String(repeating: "a", count: 257)] {
            let data = try JSONSerialization.data(withJSONObject: ["event": "agent.working", "session_id": id])
            XCTAssertThrowsError(try AgentEvent.parse(data: data), id)
        }
        XCTAssertThrowsError(try parse(#"{"event":"agent.working"}"#)) { XCTAssertEqual($0 as? AgentEventError, .missingSessionID) }
        XCTAssertThrowsError(try parse(#"{"event":"agent.working","session_id":"s","id":"../../event"}"#))
    }

    func testNativeSessionClassificationSurvivesTransport() throws {
        for flag in [true, false] {
            let event = AgentEvent(sessionID: "native", provider: "codex", kind: .working, isInternalSession: flag)
            XCTAssertEqual(try AgentEvent.parse(data: JSONEncoder().encode(event)).isInternalSession, flag)
        }
        XCTAssertNil(try parse(#"{"event":"agent.working","session_id":"legacy"}"#).isInternalSession)
        XCTAssertThrowsError(try parse(#"{"event":"agent.working","session_id":"s","is_internal_session":"true"}"#))
    }

    func testInvalidFieldTypesAndUsageAreRejected() throws {
        for json in [
            #"{"event":"agent.working","session_id":7}"#,
            #"{"event":"agent.working","session_id":"s","sequence":1.5}"#,
            #"{"event":"agent.working","session_id":"s","sequence":-1}"#,
            #"{"event":"agent.working","session_id":"s","timestamp":"today"}"#,
            #"{"event":"usage.update","session_id":"s","usage":{"input_tokens":-1}}"#,
            #"{"event":"usage.update","session_id":"s","usage":{"primary_used_percent":101}}"#,
            #"{"event":"agent.working","session_id":"s","task":{"id":"../t","title":"Task"}}"#
        ] { XCTAssertThrowsError(try parse(json), json) }
    }

    func testISO8601DatesAndUnknownEvents() throws {
        let event = try parse(#"{"event":"future.event","session_id":"s","timestamp":"2026-10-17T12:00:00.125Z"}"#)
        XCTAssertEqual(event.kind, .unknown)
        XCTAssertEqual(event.timestamp.timeIntervalSince1970, 1_792_238_400.125, accuracy: 0.001)
        XCTAssertNoThrow(try parse(#"{"event":"agent.working","session_id":"s","timestamp":"2026-10-17T12:00:00Z"}"#))
    }

    func testPayloadLimitAndMalformedJSON() throws {
        XCTAssertThrowsError(try AgentEvent.parse(data: Data(repeating: 32, count: AgentEvent.maximumPayloadBytes + 1))) {
            XCTAssertEqual($0 as? AgentEventError, .payloadTooLarge)
        }
        for json in ["", "[]", "null", "{broken"] { XCTAssertThrowsError(try parse(json)) }
    }

    func testUsagePercentageAndTaskCompletedAlias() throws {
        let event = try parse(#"{"event":"task.update","session_id":"s","task":{"id":"t1","title":"Done","completed":true},"usage":{"context_tokens":25,"context_window":100}}"#)
        XCTAssertTrue(try XCTUnwrap(event.task).completed)
        XCTAssertEqual(event.usage?.usedPercent, 25)
        XCTAssertNil(AgentUsage(contextTokens: 100, contextWindow: 0).usedPercent)
        XCTAssertEqual(AgentUsage(contextTokens: 200, contextWindow: 100).usedPercent, 100)
    }
}
