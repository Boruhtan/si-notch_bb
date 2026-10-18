import Foundation
import XCTest
@testable import SINotchCore

final class PresentationTests: XCTestCase {
    private func parse(_ object: [String: Any]) throws -> AgentEvent {
        try AgentEvent.parse(data: JSONSerialization.data(withJSONObject: object))
    }

    func testPresentationMetadataParsesEncodesAndValidates() throws {
        let event = try parse(["type": "agent-turn-complete", "thread-id": "thread-1", "turn-id": "turn-1",
                               "model_name": "gpt-6.1-sol", "reasoning_effort": "high",
                               "first_prompt": "Fix the sidebar layout"])
        XCTAssertEqual(event.modelName, "gpt-6.1-sol")
        XCTAssertEqual(event.reasoningEffort, "high")
        XCTAssertEqual(event.firstPrompt, "Fix the sidebar layout")

        let encoded = try JSONEncoder().encode(event)
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(raw["model"] as? String, "gpt-6.1-sol")
        XCTAssertEqual(raw["reasoning_effort"] as? String, "high")
        XCTAssertEqual(raw["first_prompt"] as? String, "Fix the sidebar layout")
        let roundTrip = try AgentEvent.parse(data: encoded)
        XCTAssertEqual(roundTrip.modelName, event.modelName)
        XCTAssertEqual(roundTrip.reasoningEffort, event.reasoningEffort)
        XCTAssertEqual(roundTrip.firstPrompt, event.firstPrompt)

        for (field, value) in [("model", String(repeating: "m", count: 257)),
                               ("reasoning_effort", String(repeating: "r", count: 129)),
                               ("first_prompt", String(repeating: "p", count: 16_385)),
                               ("first_prompt", "bad\0prompt")] {
            XCTAssertThrowsError(try parse(["event": "agent.working", "session_id": "s", field: value])) {
                XCTAssertEqual($0 as? AgentEventError, .invalidField(field))
            }
        }
        XCTAssertThrowsError(try parse(["event": "agent.working", "session_id": "s", "model": 7]))
    }

    func testSessionPreservesFirstPromptAndMergesLaterModelMetadata() {
        var store = SessionStore()
        let first = AgentEvent(sessionID: "s", provider: "codex", kind: .working,
                               timestamp: Date(timeIntervalSince1970: 100), modelName: "model-a",
                               firstPrompt: "Original task")
        XCTAssertEqual(store.apply(first), .applied)
        let update = AgentEvent(sessionID: "s", provider: "codex", kind: .usageUpdated,
                                timestamp: Date(timeIntervalSince1970: 101), modelName: "model-b",
                                reasoningEffort: "high", firstPrompt: "Later message")
        XCTAssertEqual(store.apply(update), .applied)
        XCTAssertEqual(store.sessions["s"]?.firstPrompt, "Original task")
        XCTAssertEqual(store.sessions["s"]?.modelName, "model-b")
        XCTAssertEqual(store.sessions["s"]?.reasoningEffort, "high")
        XCTAssertEqual(store.apply(AgentEvent(sessionID: "s", provider: "codex", kind: .completed,
                                          timestamp: Date(timeIntervalSince1970: 102))), .applied)
        XCTAssertEqual(store.sessions["s"]?.firstPrompt, "Original task")
        XCTAssertEqual(store.sessions["s"]?.modelName, "model-b")

        var latePrompt = SessionStore()
        _ = latePrompt.apply(AgentEvent(sessionID: "late", kind: .working))
        _ = latePrompt.apply(AgentEvent(sessionID: "late", kind: .working, firstPrompt: "First supplied prompt"))
        XCTAssertEqual(latePrompt.sessions["late"]?.firstPrompt, "First supplied prompt")
    }

    func testSessionFilterUsesLiteralCaseInsensitiveLinesAndMissingMetadataIsVisible() {
        let filter = SessionFilter(directories: "  /Work/Secret  \n  project.*  \n\n",
                                   promptPrefixes: "  Fix [Bug]  \n ^urgent \n")
        XCTAssertEqual(filter.directories, ["/Work/Secret", "project.*"])
        XCTAssertEqual(filter.promptPrefixes, ["Fix [Bug]", "^urgent"])
        XCTAssertTrue(filter.hides(path: "/Users/me/work/SECRET/module", firstPrompt: nil))
        XCTAssertTrue(filter.hides(path: "/tmp/project.*-literal", firstPrompt: nil))
        XCTAssertFalse(filter.hides(path: "/tmp/project-anything", firstPrompt: nil))
        XCTAssertTrue(filter.hides(path: nil, firstPrompt: "FIX [BUG] in toolbar"))
        XCTAssertTrue(filter.hides(path: nil, firstPrompt: "^Urgent issue"))
        XCTAssertFalse(filter.hides(path: nil, firstPrompt: "Please fix [bug] in toolbar"))
        XCTAssertFalse(filter.hides(path: nil, firstPrompt: nil))
    }

    func testReminderFiresOnlyAtDeadlineAndOnceForUnchangedState() {
        var reminders = FollowUpReminders()
        reminders.update(id: "waiting", status: .waiting, now: 100, delay: 30, includeCompleted: false)
        XCTAssertEqual(reminders.due(now: 129.9, states: ["waiting": .waiting]), [])
        XCTAssertEqual(reminders.due(now: 130, states: ["waiting": .waiting]), ["waiting"])
        XCTAssertEqual(reminders.due(now: 300, states: ["waiting": .waiting]), [])
    }

    func testReminderCancelsForChangedStateForegroundAndExplicitDismissal() {
        var reminders = FollowUpReminders()
        reminders.update(id: "changed", status: .approval, now: 10, delay: 20, includeCompleted: false)
        XCTAssertEqual(reminders.due(now: 15, states: ["changed": .working]), [])
        XCTAssertEqual(reminders.due(now: 100, states: ["changed": .approval]), [])

        reminders.update(id: "front", status: .waiting, now: 10, delay: 20, includeCompleted: false)
        XCTAssertEqual(reminders.due(now: 30, states: ["front": .waiting], foregroundIDs: ["front"]), [])
        XCTAssertEqual(reminders.due(now: 100, states: ["front": .waiting]), [])

        reminders.update(id: "dismissed", status: .waiting, now: 10, delay: 20, includeCompleted: false)
        reminders.cancel("dismissed")
        XCTAssertEqual(reminders.due(now: 100, states: ["dismissed": .waiting]), [])
    }

    func testCompletedReminderIsOptInAndInvalidDelaysDoNotSchedule() {
        var reminders = FollowUpReminders()
        reminders.update(id: "done", status: .completed, now: 10, delay: 20, includeCompleted: false)
        XCTAssertEqual(reminders.due(now: 30, states: ["done": .completed]), [])
        reminders.update(id: "done", status: .completed, now: 10, delay: 20, includeCompleted: true)
        XCTAssertEqual(reminders.due(now: 30, states: ["done": .completed]), ["done"])
        reminders.update(id: "zero", status: .waiting, now: 10, delay: 0, includeCompleted: true)
        reminders.update(id: "nan", status: .waiting, now: 10, delay: .nan, includeCompleted: true)
        XCTAssertEqual(reminders.due(now: 100, states: ["zero": .waiting, "nan": .waiting]), [])
    }
}
