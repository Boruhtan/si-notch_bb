import Foundation
import XCTest
@testable import SINotchCore

final class HarnessHookTests: XCTestCase {
    func testCopilotDocumentedWireNamesAndLegacyPayloads() throws {
        let aliases = ["sessionStart": "SessionStart", "userPromptSubmitted": "UserPromptSubmit",
                       "agentStop": "Stop", "notification": "Notification", "sessionEnd": "SessionEnd"]
        for (hook, alias) in aliases {
            for supplied in [nil, hook, alias] as [String?] {
                var raw: [String: Any] = ["session_id": "copilot-s", "notification_type": "permission_prompt"]
                if let supplied { raw["hook_event_name"] = supplied }
                let event = try XCTUnwrap(HarnessHook.observation(provider: "copilot", hook: hook, raw: raw))
                XCTAssertEqual(event.kind, HarnessHook.events["copilot"]?[hook])
            }
        }
        XCTAssertNil(try HarnessHook.observation(provider: "copilot", hook: "notification", raw: [
            "sessionId": "copilot-s", "hook_event_name": "Stop", "notification_type": "permission_prompt"]))
        XCTAssertNil(try HarnessHook.observation(provider: "cursor", hook: "sessionStart", raw: [
            "session_id": "cursor-s", "hook_event_name": "SessionStart"]))
    }

    func testSuppliedModelAndReasoningAreForwardedWithoutOtherRequestFields() throws {
        let event = try XCTUnwrap(HarnessHook.observation(provider: "gemini", hook: "BeforeAgent", raw: [
            "session_id": "s", "model": "model-name", "reasoning_effort": "high",
            "reasoning": "PRIVATE THOUGHTS", "request": ["api_key": "PRIVATE KEY"]]))
        XCTAssertEqual(event.modelName, "model-name")
        XCTAssertEqual(event.reasoningEffort, "high")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(event), as: UTF8.self).contains("PRIVATE"))
        let invalid = try XCTUnwrap(HarnessHook.observation(provider: "gemini", hook: "BeforeAgent", raw: [
            "session_id": "s", "model": "bad\nmodel", "reasoning_effort": "PRIVATE THOUGHTS"]))
        XCTAssertNil(invalid.modelName)
        XCTAssertNil(invalid.reasoningEffort)
    }
    func testDocumentedLifecycleEventsPreserveSessionIdentityAndExcludeContent() throws {
        for (provider, mappings) in HarnessHook.events {
            for (hook, kind) in mappings {
                var raw: [String: Any] = ["session_id": "session-1", "sessionId": "session-1", "conversation_id": "session-1",
                    "cwd": "/tmp/project", "workspace_roots": ["/tmp/project"], "status": "completed",
                    "prompt": "DO-NOT-SEND", "tool_input": ["key": "DO-NOT-SEND"], "message": "DO-NOT-SEND"]
                raw["notification_type"] = provider == "gemini" ? "ToolPermission" : "permission_prompt"
                let event = try XCTUnwrap(HarnessHook.observation(provider: provider, hook: hook, raw: raw))
                XCTAssertEqual(event.kind, kind)
                XCTAssertEqual(event.sessionID, "session-1")
                XCTAssertEqual(event.provider, provider)
                XCTAssertEqual(event.projectPath, "/tmp/project")
                XCTAssertFalse(String(decoding: try JSONEncoder().encode(event), as: UTF8.self).contains("DO-NOT-SEND"))
            }
        }
    }
    func testCursorAbortedAndErrorAreNotReportedAsSuccess() throws {
        for (status, kind): (String, AgentEventKind) in [("aborted", .waiting), ("error", .failed), ("completed", .completed)] {
            XCTAssertEqual(try HarnessHook.observation(provider: "cursor", hook: "stop", raw: ["session_id": "s", "status": status])?.kind, kind)
        }
    }
    func testUnknownOrMismatchedEventsAndMissingIDsAreIgnored() throws {
        XCTAssertNil(try HarnessHook.observation(provider: "other", hook: "stop", raw: ["session_id": "s"]))
        XCTAssertNil(try HarnessHook.observation(provider: "gemini", hook: "BeforeAgent", raw: [:]))
        XCTAssertNil(try HarnessHook.observation(provider: "gemini", hook: "BeforeAgent", raw: ["session_id": "s", "hook_event_name": "AfterAgent"]))
        XCTAssertNil(try HarnessHook.observation(provider: "gemini", hook: "Notification", raw: ["session_id": "s", "notification_type": "other"]))
        XCTAssertThrowsError(try HarnessHook.observation(provider: "gemini", hook: "BeforeAgent", raw: ["session_id": "bad\nID"]))
    }
}
