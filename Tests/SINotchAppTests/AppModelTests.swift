import Combine
import XCTest
@testable import SINotch

final class AppModelTests: XCTestCase {
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
