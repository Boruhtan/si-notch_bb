import Foundation
import XCTest
@testable import SINotch
import SINotchCore

final class CodexServiceSessionTests: XCTestCase {
    private let servicePrompt = "This is an app-generated request for a suggested next user message. The user did not write this message."

    @MainActor
    private func model() -> AppModel {
        let suite = "si-notch.service-tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(false, forKey: "sound")
        defaults.set(true, forKey: "autoExpand")
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return AppModel(defaults: defaults)
    }

    @MainActor
    @discardableResult
    private func send(_ event: AgentEvent, to model: AppModel) throws -> [String: Any] {
        var response = Data()
        model.receive(try JSONEncoder().encode(event)) { response = $0 }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [String: Any])
    }

    @MainActor
    func testSuggestionAndLateLifecycleEventsNeverCreateATask() throws {
        let model = model()
        defer { model.shutdown() }
        for event in [
            AgentEvent(sessionID: "service", provider: "codex", kind: .working, title: servicePrompt, firstPrompt: servicePrompt),
            AgentEvent(sessionID: "service", provider: "codex", kind: .completed, message: "{\"suggestion\":null}"),
            AgentEvent(sessionID: "service", provider: "codex", kind: .working, title: "Codex Desktop")
        ] {
            XCTAssertEqual(try send(event, to: model)["disposition"] as? String, "filtered")
            XCTAssertTrue(model.sessions.isEmpty)
            XCTAssertTrue(model.store.sessions.isEmpty)
            XCTAssertFalse(model.expanded)
            XCTAssertNil(model.providerReceipts["codex"])
        }
        XCTAssertTrue(model.activity.isEmpty)
    }

    @MainActor
    func testLatePromptRemovesPlaceholderAndPreservesThePingTask() throws {
        let model = model()
        defer { model.shutdown() }
        try send(AgentEvent(sessionID: "ping", provider: "codex", kind: .completed,
                            title: "Ping", message: "Pong", firstPrompt: "Ping"), to: model)
        try send(AgentEvent(sessionID: "service", provider: "codex", kind: .working, title: "Codex Desktop"), to: model)
        model.selectedID = "service"
        model.measuredSessionHeights["service"] = 150
        try send(AgentEvent(sessionID: "service", provider: "codex", kind: .usageUpdated,
                            title: servicePrompt, firstPrompt: servicePrompt), to: model)
        try send(AgentEvent(sessionID: "service", provider: "codex", kind: .completed), to: model)
        XCTAssertEqual(model.sessions.map(\.id), ["ping"])
        XCTAssertEqual(model.sessions.first?.lastMessage, "Pong")
        XCTAssertNil(model.selectedID)
        XCTAssertNil(model.activity["service"])
        XCTAssertNil(model.measuredSessionHeights["service"])
        model.activeFilter = "Готово"
        XCTAssertEqual(model.filtered.map(\.id), ["ping"])
        var reply = Data()
        model.receive(Data("{\"command\":\"status\",\"protocol_version\":1}".utf8)) { reply = $0 }
        let status = try XCTUnwrap(JSONSerialization.jsonObject(with: reply) as? [String: Any])
        XCTAssertEqual(status["session_count"] as? Int, 1)
    }

    @MainActor
    func testDesktopSnapshotProjectionPreservesServiceDetection() throws {
        let model = model()
        defer { model.shutdown() }
        let id = "11111111-1111-4111-8111-111111111111"
        var state = CodexDesktopState()
        XCTAssertTrue(state.apply(["type": "snapshot", "revision": 1, "conversationState": [
            "id": id, "title": String(servicePrompt.prefix(100)),
            "turns": [["turnStartedAtMs": 1, "status": "completed", "items": [
                ["type": "userMessage", "content": [["type": "text", "text": servicePrompt]]],
                ["type": "agentMessage", "phase": "final_answer", "text": "{\"suggestion\":null}"]
            ]]]
        ]]))
        let event = try XCTUnwrap(state.event(sessionID: id))
        XCTAssertEqual(try send(event, to: model)["disposition"] as? String, "filtered")
        XCTAssertTrue(model.sessions.isEmpty)
    }

    @MainActor
    func testBackgroundTurnCannotOverwriteAUserTaskAndUserCanResume() throws {
        let model = model()
        defer { model.shutdown() }
        try send(AgentEvent(sessionID: "shared", provider: "codex", kind: .completed,
                            title: "Fix parser", message: "Fixed", firstPrompt: "Fix parser"), to: model)
        try send(AgentEvent(sessionID: "shared", provider: "codex", kind: .working,
                            title: servicePrompt, firstPrompt: servicePrompt), to: model)
        try send(AgentEvent(sessionID: "shared", provider: "codex", kind: .completed, message: "{\"suggestion\":null}"), to: model)
        XCTAssertEqual(model.sessions.first?.lastMessage, "Fixed")
        XCTAssertEqual(model.sessions.first?.title, "Fix parser")
        XCTAssertEqual(model.sessions.first?.status, .completed)
        try send(AgentEvent(sessionID: "shared", provider: "codex", kind: .working,
                            title: "Add tests", firstPrompt: "Add tests"), to: model)
        XCTAssertEqual(model.sessions.first?.title, "Add tests")
        XCTAssertEqual(model.sessions.first?.status, .working)
    }

    func testOnlyExplicitCodexServicePrefixIsFiltered() {
        var filter = CodexServiceSessionFilter()
        XCTAssertFalse(filter.hides(AgentEvent(sessionID: "custom", provider: "custom", kind: .working, firstPrompt: servicePrompt)))
        for prompt in ["Ping", "Explain this: " + servicePrompt, "\"" + servicePrompt + "\"",
                       "This is an app-generated request for a report.", "{\"suggestion\":null}"] {
            XCTAssertFalse(filter.hides(AgentEvent(sessionID: UUID().uuidString, provider: "codex", kind: .working,
                                                  title: servicePrompt, firstPrompt: prompt)))
        }
        XCTAssertTrue(filter.hides(AgentEvent(sessionID: "title", provider: "codex", kind: .completed, title: servicePrompt)))
        XCTAssertTrue(CodexServiceSessionFilter.isSuggestionRequest(" \n" + servicePrompt.replacingOccurrences(of: " ", with: "\n")))
    }

    @MainActor
    func testNativeInternalSourcesAreFilteredRegardlessOfPromptOrDirectory() throws {
        let model = model()
        defer { model.shutdown() }
        let sources: [[String: Any]] = [
            ["internal": "memory_consolidation"], ["internal": "guardian"],
            ["internal": "future_internal_task"], ["subagent": "memory_consolidation"],
            ["subagent": ["thread_spawn": ["parent_thread_id": "PRIVATE ANCESTRY"]]]
        ]
        for source in sources {
            let id = UUID().uuidString
            var state = CodexDesktopState()
            XCTAssertTrue(state.apply(["type": "snapshot", "revision": 1, "conversationState": [
                "id": id, "source": source, "title": "Arbitrary renamed task", "cwd": "/tmp/anywhere",
                "threadRuntimeStatus": ["type": "active"],
                "turns": [["status": "inProgress", "items": [["type": "userMessage", "content": "Arbitrary instructions"]]]]
            ]]))
            let event = try XCTUnwrap(state.event(sessionID: id))
            XCTAssertEqual(event.isInternalSession, true)
            XCTAssertEqual(try send(event, to: model)["disposition"] as? String, "filtered")
            XCTAssertEqual(try send(AgentEvent(sessionID: id, provider: "codex", kind: .working,
                firstPrompt: "Late instructions without provenance"), to: model)["disposition"] as? String, "filtered")
            XCTAssertFalse(String(data: try JSONSerialization.data(withJSONObject: state.root), encoding: .utf8)!.contains("PRIVATE"))
        }
        XCTAssertTrue(model.store.sessions.isEmpty)
        XCTAssertTrue(model.sessions.isEmpty)
        XCTAssertTrue(model.activity.isEmpty)
        XCTAssertFalse(model.expanded)
        XCTAssertNil(model.providerReceipts["codex"])
    }

    func testCustomUnknownAndEphemeralUserSourcesStayVisible() {
        XCTAssertEqual(CodexServiceSessionFilter.nativeClassification(source: ["custom": "integration"]), false)
        XCTAssertEqual(CodexServiceSessionFilter.nativeClassification(source: "exec"), false)
        XCTAssertEqual(CodexServiceSessionFilter.nativeClassification(source: nil, threadSource: "guardian_review"), true)
        XCTAssertNil(CodexServiceSessionFilter.nativeClassification(source: ["future_source": true]))
        var state = CodexDesktopState()
        let id = UUID().uuidString
        XCTAssertTrue(state.apply(["type": "snapshot", "revision": 1, "conversationState": [
            "id": id, "source": "exec", "ephemeral": true, "title": "User CLI task"
        ]]))
        XCTAssertEqual(state.event(sessionID: id)?.isInternalSession, false)
    }

    @MainActor
    func testLateNativeMetadataRemovesPlaceholderAndExplicitUserCanResume() throws {
        let model = model()
        defer { model.shutdown() }
        try send(AgentEvent(sessionID: "native", provider: "codex", kind: .working,
            title: "Task discovered before metadata", firstPrompt: "Arbitrary internal instructions"), to: model)
        XCTAssertEqual(try send(AgentEvent(sessionID: "native", provider: "codex", kind: .working,
            title: "Internal task", firstPrompt: "Internal instructions", isInternalSession: true), to: model)["disposition"] as? String, "filtered")
        XCTAssertTrue(model.store.sessions.isEmpty)
        try send(AgentEvent(sessionID: "native", provider: "codex", kind: .working,
            firstPrompt: "A real user task", isInternalSession: false), to: model)
        XCTAssertEqual(model.sessions.first?.firstPrompt, "A real user task")
    }
}
