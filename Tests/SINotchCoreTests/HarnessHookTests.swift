import Foundation
import XCTest
@testable import SINotchCore

final class HarnessHookTests: XCTestCase {
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
