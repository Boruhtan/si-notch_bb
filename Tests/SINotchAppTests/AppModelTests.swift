import Combine
import XCTest
import SINotchCore
@testable import SINotch

final class AppModelTests: XCTestCase {
    @MainActor
    func testObservedNewCodexTurnReopensEndedCLIWithAndWithoutBootstrap() throws {
        for bootstrap in [false, true] {
            let model = makeModel()
            defer { model.shutdown() }
            model.defaults.set(true, forKey: "codexAutoDetect")
            let endedAt = Date().addingTimeInterval(-5), turn = UUID().uuidString
            let ended = AgentEvent(sessionID: "resumed-cli", provider: "codex", kind: .sessionEnded, timestamp: endedAt)
            model.receive(try JSONEncoder().encode(ended)) { _ in }
            XCTAssertTrue(model.sessions.isEmpty)
            let working = AgentEvent(sessionID: "resumed-cli", provider: "codex", kind: .working,
                timestamp: endedAt.addingTimeInterval(1), id: "rollout:\(turn):\(bootstrap ? "bootstrap" : "start")",
                firstPrompt: "Resume the local test", turnID: turn)
            model.receiveCodexObservation(working, bootstrap: bootstrap)
            XCTAssertEqual(model.sessions.first?.status, .working)
            let complete = AgentEvent(sessionID: "resumed-cli", provider: "codex", kind: .completed,
                timestamp: endedAt.addingTimeInterval(2), id: "rollout:\(turn):complete", turnID: turn)
            model.receiveCodexObservation(complete, bootstrap: false)
            XCTAssertEqual(model.sessions.first?.status, .completed)
        }
    }

    @MainActor
    func testStaleOrUnidentifiedObservationCannotReopenEndedCodex() throws {
        let model = makeModel()
        defer { model.shutdown() }
        model.defaults.set(true, forKey: "codexAutoDetect")
        let endedAt = Date(), turn = UUID().uuidString
        model.receive(try JSONEncoder().encode(AgentEvent(sessionID: "ended-cli", provider: "codex",
            kind: .sessionEnded, timestamp: endedAt))) { _ in }
        for event in [
            AgentEvent(sessionID: "ended-cli", provider: "codex", kind: .working,
                timestamp: endedAt.addingTimeInterval(-1), id: "rollout:\(turn):bootstrap", turnID: turn),
            AgentEvent(sessionID: "ended-cli", provider: "codex", kind: .working,
                timestamp: endedAt.addingTimeInterval(1), id: "desktop:late-log", turnID: turn),
            AgentEvent(sessionID: "ended-cli", provider: "codex", kind: .working,
                timestamp: endedAt.addingTimeInterval(1), id: "desktop-stream:missing-turn")
        ] {
            model.receiveCodexObservation(event, bootstrap: true)
            XCTAssertTrue(model.sessions.isEmpty)
            XCTAssertEqual(model.store.sessions["ended-cli"]?.status, .ended)
        }
    }

    @MainActor
    func testFreshRolloutBootstrapRestoresNewTurnOfCompletedSession() throws {
        let model = makeModel()
        defer { model.shutdown() }
        model.defaults.set(true, forKey: "codexAutoDetect")
        let completedAt = Date().addingTimeInterval(-10), turn = UUID().uuidString
        model.receive(try JSONEncoder().encode(AgentEvent(sessionID: "completed-cli", provider: "codex",
            kind: .completed, timestamp: completedAt))) { _ in }
        model.receiveCodexObservation(AgentEvent(sessionID: "completed-cli", provider: "codex", kind: .working,
            timestamp: completedAt.addingTimeInterval(1), id: "rollout:\(turn):bootstrap", turnID: turn), bootstrap: true)
        XCTAssertEqual(model.sessions.first?.status, .working)
    }
    @MainActor
    func testUnchangedMaintenanceTickDoesNotInvalidateTheInterface() {
        let model = makeModel()
        var changes = 0
        let subscription = model.objectWillChange.sink { changes += 1 }
        model.tick()
        model.tick()
        XCTAssertEqual(changes, 0)
        withExtendedLifetime(subscription) {}
    }

    @MainActor
    private func makeModel() -> AppModel {
        let suite = "si-notch.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        return AppModel(defaults: defaults)
    }
    private func payload(_ id: String, request: String, event: String = "approval.request", wait: Bool = true) -> Data {
        try! JSONSerialization.data(withJSONObject: ["session_id": id, "provider": "custom", "event": event, "request_id": request, "approval_id": request, "await_response": wait, "response_timeout": 60])
    }
    @MainActor
    func testStaleButtonCannotApproveReplacementEvenWhenWireIDReused() async {
        let model = makeModel()
        var oldReplies: [Data] = []
        var newReplies: [Data] = []
        model.receive(payload("test", request: "req")) { oldReplies.append($0) }
        let oldToken = model.pending["test"]!.token
        model.receive(payload("test", request: "req")) { newReplies.append($0) }
        XCTAssertEqual(oldReplies.count, 1)
        XCTAssertNotEqual(model.pending["test"]!.token, oldToken)
        model.respond("test", expectedToken: oldToken, decision: "allow")
        XCTAssertEqual(newReplies.count, 0)
        XCTAssertNotNil(model.pending["test"])
        model.respond("test", expectedToken: model.pending["test"]!.token, decision: "deny")
        XCTAssertEqual(newReplies.count, 1)
        XCTAssertNil(model.pending["test"])
    }
    @MainActor
    func testObserverApprovalCancelsPreviousInteractiveRequest() async {
        let model = makeModel()
        var replies: [Data] = []
        model.receive(payload("test", request: "interactive")) { replies.append($0) }
        model.receive(payload("test", request: "observer", wait: false)) { _ in }
        XCTAssertNil(model.pending["test"])
        XCTAssertEqual(replies.count, 1)
        let result = try! JSONSerialization.jsonObject(with: replies[0]) as! [String: Any]
        XCTAssertEqual(result["decision"] as? String, "cancelled")
    }
    @MainActor
    func testDesktopObservationCannotCancelLiveCodexPermissionButCompletionDoes() throws {
        let model = makeModel()
        defer { model.shutdown() }
        var replies: [Data] = []
        let request: [String: Any] = ["session_id": "codex-permission", "provider": "codex", "event": "approval.request",
            "request_id": "exact-request", "approval_id": "exact-request", "await_response": true, "response_timeout": 60]
        model.receive(try JSONSerialization.data(withJSONObject: request)) { replies.append($0) }
        let token = try XCTUnwrap(model.pending["codex-permission"]?.token)
        for event in ["agent.working", "agent.waiting", "approval.request"] {
            model.receive(try JSONSerialization.data(withJSONObject: ["session_id": "codex-permission", "provider": "codex",
                "event": event, "id": "desktop-stream:\(UUID().uuidString)"])) { _ in }
            XCTAssertEqual(model.pending["codex-permission"]?.token, token)
            XCTAssertEqual(model.store.sessions["codex-permission"]?.status, .approval)
            XCTAssertTrue(replies.isEmpty)
        }
        model.receive(try JSONSerialization.data(withJSONObject: ["session_id": "codex-permission", "provider": "codex",
            "event": "agent.completed", "id": "desktop-stream:completed"])) { _ in }
        XCTAssertNil(model.pending["codex-permission"])
        XCTAssertEqual(replies.count, 1)
        model.respond("codex-permission", expectedToken: token, decision: "allow")
        XCTAssertEqual(replies.count, 1, "A stale button must not answer after completion")
    }
    @MainActor
    func testDeadlineUsesClientTimeoutAndReleasesCallback() async {
        let model = makeModel()
        var replies: [Data] = []
        model.receive(payload("test", request: "timed")) { replies.append($0) }
        let deadline = model.pending["test"]!.expiresAt
        model.tick(at: deadline + 1)
        XCTAssertNil(model.pending["test"])
        XCTAssertEqual(replies.count, 1)
        let result = try! JSONSerialization.jsonObject(with: replies[0]) as! [String: Any]
        XCTAssertEqual(result["decision"] as? String, "timeout")
    }
    @MainActor
    func testPendingDecisionQuotaReservesCapacityForObservations() async {
        let model = makeModel()
        for i in 0..<8 { model.receive(payload("s\(i)", request: "r\(i)")) { _ in } }
        XCTAssertEqual(model.pending.count, 8)
        var response = Data()
        model.receive(payload("overflow", request: "r9")) { response = $0 }
        let result = try! JSONSerialization.jsonObject(with: response) as! [String: Any]
        XCTAssertEqual(result["decision"] as? String, "busy")
        XCTAssertEqual(model.pending.count, 8)
        model.receive(payload("normal", request: "unused", event: "agent.completed", wait: false)) { _ in }
        XCTAssertEqual(model.store.sessions["normal"]?.status.rawValue, "completed")
    }
    @MainActor
    func testAwaitedUsageCannotReplacePendingDecisionOrMutateSession() async {
        let model = makeModel()
        var originalReplies = 0
        model.receive(payload("test", request: "original")) { _ in originalReplies += 1 }
        let token = model.pending["test"]!.token
        var invalidResponse = Data()
        model.receive(payload("test", request: "invalid", event: "usage.update")) { invalidResponse = $0 }
        XCTAssertEqual(model.pending["test"]?.token, token)
        XCTAssertEqual(originalReplies, 0)
        let result = try! JSONSerialization.jsonObject(with: invalidResponse) as! [String: Any]
        XCTAssertEqual(result["decision"] as? String, "invalid_request")
        model.respond("test", expectedToken: token, decision: "deny")
        XCTAssertEqual(originalReplies, 1)
    }

}
