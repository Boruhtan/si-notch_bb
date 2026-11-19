import Foundation
import XCTest
import SINotchCore
@testable import SINotch

final class AttentionQueueTests: XCTestCase {
    @MainActor
    func testQueueKeepsActionableRequestsSeparateFromErrorsAndPassiveWaiting() {
        let model = makeModel()
        defer { model.shutdown() }

        send(model, "agent.working", session: "error-id")
        send(model, "agent.failed", session: "error-id")
        send(model, "agent.waiting", session: "question-id", request: "question-one")
        send(model, "approval.request", session: "approval-id", request: "approval-one")
        send(model, "agent.waiting", session: "passive-wait")
        send(model, "approval.request", session: "passive-permission")
        send(model, "agent.working", session: "active-work")

        let queue = model.attentionQueue
        XCTAssertEqual(Set(queue.requests.map(\.id)), ["question-id", "approval-id"])
        XCTAssertEqual(queue.errors.map(\.id), ["error-id"])
        XCTAssertTrue(queue.ssh.isEmpty)
        XCTAssertTrue(queue.requests.allSatisfy { $0.waitingSince != nil })
        XCTAssertTrue(queue.requests.allSatisfy { $0.deadline == nil })
    }

    @MainActor
    func testObservedRequestKeepsOriginalWaitAcrossRepeatsAndClearsWhenResolved() async throws {
        let model = makeModel()
        defer { model.shutdown() }

        send(model, "agent.waiting", session: "question", request: "question-one")
        let start = try XCTUnwrap(model.attentionQueue.requests.first?.waitingSince)
        try await Task.sleep(for: .milliseconds(20))
        send(model, "agent.waiting", session: "question", request: "question-one")
        XCTAssertEqual(model.attentionQueue.requests.first?.waitingSince, start)
        model.tick(at: ProcessInfo.processInfo.systemUptime + 46)
        XCTAssertEqual(model.attentionQueue.requests.first?.waitingSince, start,
                       "An observed prompt remains unresolved after its automatic reveal lease expires")

        send(model, "agent.waiting", session: "question", request: "question-two")
        XCTAssertGreaterThan(try XCTUnwrap(model.attentionQueue.requests.first?.waitingSince), start)

        send(model, "agent.working", session: "question")
        XCTAssertTrue(model.attentionQueue.requests.isEmpty)
    }

    @MainActor
    func testExpiringConfirmationTakesPriorityAndDisappearsAfterReply() throws {
        let model = makeModel()
        defer { model.shutdown() }

        send(model, "agent.waiting", session: "first-question", request: "first")
        model.inject(["event": "approval.request", "session_id": "later-approval", "provider": "custom",
                      "await_response": true, "request_id": "later", "response_timeout": 90])
        model.inject(["event": "approval.request", "session_id": "expiring-approval", "provider": "custom",
                      "await_response": true, "request_id": "soon", "response_timeout": 15])

        let items = model.attentionQueue.requests
        XCTAssertEqual(items.map(\.id), ["expiring-approval", "first-question", "later-approval"])
        let expiring = try XCTUnwrap(items.first)
        XCTAssertNotNil(expiring.deadline)
        XCTAssertEqual(expiring.waitingSince, model.pending[expiring.id]?.receivedAt)

        let approval = try XCTUnwrap(model.pending[expiring.id])
        model.respond(expiring.id, expectedToken: approval.token, decision: "deny")
        XCTAssertEqual(model.attentionQueue.requests.map(\.id), ["first-question", "later-approval"])
    }

    @MainActor
    func testCollapsedPanelOpensAttentionForRequestAndAllowsManualTabChanges() {
        let model = makeModel()
        defer { model.shutdown() }
        model.defaults.set(true, forKey: "autoExpand")

        send(model, "agent.failed", session: "failure")
        XCTAssertFalse(model.expanded)
        send(model, "agent.waiting", session: "question", request: "pending-question")
        XCTAssertTrue(model.expanded)
        XCTAssertTrue(model.showingAttention)

        model.selectAgents(true)
        XCTAssertTrue(model.showAgents)
        XCTAssertFalse(model.showingAttention)
        send(model, "approval.request", session: "approval", request: "pending-approval")
        XCTAssertTrue(model.showAgents)
        XCTAssertFalse(model.showingAttention)

        model.setExpanded(false)
        model.setExpanded(true)
        XCTAssertTrue(model.showingAttention)
        model.selectAgents(false)
        XCTAssertFalse(model.showingAttention)
    }

    @MainActor
    func testFailedConnectorContributesOneRowAndDeliberateDisconnectClearsIt() throws {
        let model = makeModel()
        let directory = URL(fileURLWithPath: "/private/tmp/sn-attn-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer {
            model.shutdown()
            try? FileManager.default.removeItem(at: directory)
        }

        let disconnectedID = try XCTUnwrap(model.remoteConnections.add())
        let connectorID = try XCTUnwrap(model.remoteConnections.add())
        var connection = try XCTUnwrap(model.remoteConnections.connections.first { $0.id == connectorID })
        connection.name = "Pupsik fixture"
        connection.host = "-invalid-fixture"
        connection.remoteSocketPath = "/home/fixture/events.sock"
        connection.profiles = (0..<2).map { index in
            RemoteHermesProfile(id: "profile-\(index)", home: "/home/fixture", displayName: "Profile \(index)",
                enabled: true, showSessionText: false, pluginInstalled: true, connectionId: "remote-\(index)")
        }
        model.remoteConnections.update(connection)
        model.remoteConnections.setReconnectAtLaunch(connectorID, enabled: true)
        XCTAssertTrue(model.attentionQueue.ssh.isEmpty)

        model.remoteConnections.connect(connectorID, localSocketPath: directory.appendingPathComponent("events.sock").path)
        XCTAssertEqual(model.remoteConnections.state(disconnectedID), .disconnected)
        XCTAssertEqual(model.remoteConnections.state(connectorID), .failed(.invalidHost))
        XCTAssertEqual(model.attentionQueue.ssh.map(\.id), [connectorID])
        XCTAssertEqual(model.attentionQueue.ssh.first?.name, "Pupsik fixture")
        XCTAssertEqual(model.attentionQueue.ssh.first?.state, .failed(.invalidHost))
        XCTAssertFalse(model.expanded)

        model.remoteConnections.disconnect(connectorID)
        XCTAssertTrue(model.attentionQueue.ssh.isEmpty)
    }

    @MainActor
    func testRequestDisplaysSavedRemoteProfileAndConnectorNames() throws {
        let model = makeModel()
        defer { model.shutdown() }

        let id = try XCTUnwrap(model.remoteConnections.add())
        var connection = try XCTUnwrap(model.remoteConnections.connections.first)
        connection.name = "Pupsik fixture"
        connection.profiles = [RemoteHermesProfile(id: "research", home: "/home/fixture", displayName: "Research profile",
            enabled: true, showSessionText: false, pluginInstalled: true, connectionId: "remote-fixture")]
        model.remoteConnections.update(connection)
        let event = model.json(["event": "agent.waiting", "session_id": "remote-question", "provider": "hermes",
                               "connection_id": "remote-fixture", "connection_name": "Transient name",
                               "attention_request_id": "question", "cwd": "/home/fixture/projects/review"])

        model.receive(event, origin: .remote(id)) { _ in }

        let item = try XCTUnwrap(model.attentionQueue.requests.first)
        XCTAssertEqual(item.profileName, "Research profile")
        XCTAssertEqual(item.machineName, "Pupsik fixture")
        XCTAssertEqual(item.session.projectPath, "/home/fixture/projects/review")
    }

    @MainActor
    private func makeModel() -> AppModel {
        let suite = "si-notch.attention-tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults)
        model.defaults.set(false, forKey: "autoExpand")
        return model
    }

    @MainActor
    private func send(_ model: AppModel, _ event: String, session: String, request: String? = nil) {
        var payload = ["event": event, "provider": "hermes", "session_id": session,
                       "event_id": UUID().uuidString]
        if let request { payload["attention_request_id"] = request }
        model.inject(payload)
    }
}
