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
    func testCollapsedGroupCountersAndAttentionUseTheSameMembership() throws {
        let model = makeModel()
        defer { model.shutdown() }
        model.localHermesProfiles = [LocalHermesProfile(connectionID: "local-profile", name: "Don Digidon", isDefault: true)]
        let connector = try XCTUnwrap(model.remoteConnections.add())
        var connection = try XCTUnwrap(model.remoteConnections.connections.first)
        connection.name = "Pupsik"
        connection.profiles = [RemoteHermesProfile(id: "default", home: "/home/fixture", displayName: "Don David",
            enabled: true, showSessionText: false, pluginInstalled: true, connectionId: "remote-profile")]
        model.remoteConnections.update(connection)
        model.setLocalHermesGroupExpanded(false)
        model.setConnectorExpanded(connector, false)
        model.setApplicationGroupExpanded(.rex, false)
        model.setApplicationGroupExpanded(.zed, false)

        func event(_ kind: String, _ id: String, profile: String? = nil, host: AgentHostApplication? = nil,
                   origin: AgentConnection.Origin = .local, request: Bool = false) {
            var value = ["event": kind, "provider": profile == nil ? "codex" : "hermes", "session_id": id]
            if let profile { value["connection_id"] = profile }
            if let host { value["terminal_bundle_id"] = host.bundleID }
            if request { value["attention_request_id"] = id + "-request" }
            model.receive(model.json(value), origin: origin) { _ in }
        }
        event("agent.waiting", "karabas-question", profile: "local-profile", request: true)
        event("agent.working", "karabas-working", profile: "local-profile")
        event("agent.working", "karabas-done", profile: "local-profile")
        event("agent.completed", "karabas-done", profile: "local-profile")
        event("agent.waiting", "karabas-passive", profile: "local-profile")
        event("agent.working", "karabas-error", profile: "local-profile")
        event("agent.failed", "karabas-error", profile: "local-profile")
        event("approval.request", "pupsik-question", profile: "remote-profile", host: .rex, origin: .remote(connector), request: true)
        event("agent.waiting", "rex-question", profile: "local-profile", host: .rex, request: true)
        event("agent.waiting", "zed-question", host: .zed, request: true)
        event("agent.waiting", "ungrouped", request: true)

        let groups: [AgentGroupID: String] = [.localHermes: "karabas-question", .remote(connector): "pupsik-question",
            .application(.rex): "rex-question", .application(.zed): "zed-question"]
        XCTAssertEqual(model.agentGroupCounts[.localHermes], AgentGroupCounts(waiting: 1, working: 1, completed: 1))
        model.selectAgents(true)
        for (group, request) in groups {
            XCTAssertEqual(model.agentGroupCounts[group]?.waiting, 1)
            model.selectAttention(group: group)
            XCTAssertTrue(model.showingAttention)
            XCTAssertEqual(model.attentionGroup, group)
            XCTAssertEqual(model.visibleAttentionQueue.requests.map(\.id), [request])
            XCTAssertEqual(model.visibleAttentionQueue.errors.map(\.id), group == .localHermes ? ["karabas-error"] : [])
            XCTAssertTrue(model.handlePanelKey(18, characters: "1"))
            XCTAssertEqual(model.selectedID, request)
        }
        model.selectAttention()
        XCTAssertNil(model.attentionGroup)
        XCTAssertNil(model.selectedID)
        XCTAssertEqual(Set(model.visibleAttentionQueue.requests.map(\.id)), Set(Array(groups.values) + ["ungrouped"]))
        XCTAssertFalse(model.localHermesGroupExpanded)
        XCTAssertFalse(model.connectorExpanded(connector))
        XCTAssertFalse(model.applicationGroupExpanded(.rex))
        XCTAssertFalse(model.applicationGroupExpanded(.zed))

        event("agent.working", "pupsik-question", profile: "remote-profile", origin: .remote(connector))
        model.selectAttention(group: .remote(connector))
        XCTAssertTrue(model.visibleAttentionQueue.requests.isEmpty)
        XCTAssertEqual(model.agentGroupCounts[.remote(connector)], AgentGroupCounts(working: 1))
    }

    func testScopedQueueIncludesOnlyItsOwnSSHError() {
        let failed = AttentionSSHItem(id: UUID(), name: "Pupsik", state: .failed(.authenticationFailed))
        let other = AttentionSSHItem(id: UUID(), name: "Other", state: .retrying)
        let queue = AttentionQueue(requests: [], errors: [], ssh: [failed, other])
        XCTAssertEqual(queue.filtered(to: .remote(failed.id)).ssh.map(\.id), [failed.id])
        XCTAssertTrue(queue.filtered(to: .localHermes).ssh.isEmpty)
        XCTAssertTrue(queue.filtered(to: .application(.rex)).ssh.isEmpty)
    }

    @MainActor
    func testRexReportsAppearInAttentionAndClearWithTheTerminalSnapshot() throws {
        let model = makeModel()
        defer { model.shutdown() }
        let block = try XCTUnwrap(RexTerminal.Block(session: "session:11111111-1111-1111-1111-111111111111",
                                                    block: "block:22222222-2222-2222-2222-222222222222"))
        let items = RexAttentionItem.items(from: ["records": [
            ["state": "working", "app": "codex"],
            ["state": "blocked", "effective_app": "codex", "msg": "private"],
            ["state": "blocked", "app": "codex"],
            ["state": "error", "app": "codex"],
            ["state": "done"],
        ]], block: block)
        model.updateRexAttention(items)
        XCTAssertEqual(model.attentionQueue.rexWaiting.count, 1)
        XCTAssertEqual(model.attentionQueue.rexErrors.count, 1)
        XCTAssertEqual(model.attentionQueue.rexErrors.first?.provider, "codex")
        XCTAssertEqual(model.agentGroupCounts[.application(.rex)], AgentGroupCounts(waiting: 1, errors: 1))
        XCTAssertTrue(model.sessions.isEmpty)
        model.selectAttention(group: .application(.zed))
        XCTAssertTrue(model.visibleAttentionQueue.rex.isEmpty)
        model.selectAttention(group: .application(.rex))
        XCTAssertEqual(model.visibleAttentionQueue.count, 2)

        let event = AgentEvent(sessionID: "cli-session", provider: "codex", kind: .approvalRequested,
            terminalBundleID: "com.superlogical.rex", attentionRequestID: "actual-request",
            rexSessionID: block.session, rexBlockID: block.block)
        model.receive(try JSONEncoder().encode(event), origin: .local) { _ in }
        XCTAssertEqual(model.visibleAttentionQueue.requests.map(\.id), ["cli-session"])
        XCTAssertTrue(model.visibleAttentionQueue.rexWaiting.isEmpty)
        XCTAssertEqual(model.visibleAttentionQueue.rexErrors.count, 1)
        model.updateRexAttention([])
        XCTAssertEqual(model.visibleAttentionQueue.count, 1)
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
