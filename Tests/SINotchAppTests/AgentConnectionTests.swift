import Foundation
import XCTest
import SINotchCore
@testable import SINotch

final class AgentConnectionTests: XCTestCase {
    func testSSHConnectionDoesNotInventProfilePresenceOrTaskActivity() {
        let now = Date(), connector = UUID()
        let config = AgentConnection.Configuration(connectionID: "p", name: "Lane", connectorID: connector,
            visible: true, transportState: .connected)
        let quiet = AgentConnection.project(detected: [], sessions: [], receipts: [:], running: [], now: now,
            configurations: [config])
        XCTAssertEqual(quiet.first?.state, .installed)
        XCTAssertEqual(quiet.first?.activity, .unknown)
        let presence = AgentConnection.Observation(provider: "hermes", connectionID: "p", name: "Lane",
            lastSeen: now, eventAt: now, eventID: "heartbeat")
        let online = AgentConnection.project(detected: [], sessions: [], receipts: [:], running: [], now: now,
            connections: [presence.id: presence], configurations: [config])
        XCTAssertEqual(online.first?.state, .online)
        XCTAssertEqual(online.first?.activity, .idle)
        XCTAssertEqual(online.first?.activeTaskCount, 0)
    }

    func testProfilePresenceTaskCompletionAndTransportLossAreIndependent() {
        let now = Date(), connector = UUID()
        var config = AgentConnection.Configuration(connectionID: "p", name: "Lane", connectorID: connector,
            visible: true, transportState: .connected)
        let presence = AgentConnection.Observation(provider: "hermes", connectionID: "p", name: "Lane",
            lastSeen: now, eventAt: now, eventID: "heartbeat")
        var task = AgentSession(id: "task", provider: "hermes", status: .working)
        task.connectionID = "p"
        var unrelated = AgentSession(id: "other", provider: "hermes", status: .waiting)
        unrelated.connectionID = "other-profile"
        func project(at time: Date = now) -> AgentConnection? {
            AgentConnection.project(detected: [], sessions: [task, unrelated], receipts: [:], running: [], now: time,
                connections: [presence.id: presence], configurations: [config]).first { $0.name == "Lane" }
        }
        XCTAssertEqual(project()?.activity, .working)
        XCTAssertEqual(project()?.activeTaskCount, 1)
        task.status = .waiting
        XCTAssertEqual(project()?.activity, .attention)
        task.status = .completed
        XCTAssertEqual(project()?.state, .online)
        XCTAssertEqual(project()?.activity, .idle)
        XCTAssertEqual(project()?.activeTaskCount, 0)
        config.transportState = .disconnected
        XCTAssertEqual(project()?.state, .lastSeen)
        XCTAssertEqual(project()?.activity, .unknown)
        config.transportState = .connected
        XCTAssertEqual(project(at: now.addingTimeInterval(121))?.state, .lastSeen)
        XCTAssertEqual(project(at: now.addingTimeInterval(121))?.activity, .unknown)
    }

    @MainActor func testRepeatedHeartbeatRefreshesPresenceWithoutCreatingOrChangingTask() throws {
        let model = AppModel(defaults: UserDefaults(suiteName: "si-notch.heartbeat-tests." + UUID().uuidString)!)
        defer { model.shutdown() }
        func receive(_ kind: AgentEventKind, id: String) throws {
            model.receive(try JSONEncoder().encode(AgentEvent(sessionID: id, provider: "hermes", kind: kind,
                id: UUID().uuidString, connectionID: "p", connectionName: "Lane"))) { _ in }
        }
        try receive(.agentPresence, id: "presence-p")
        XCTAssertTrue(model.store.sessions.isEmpty)
        XCTAssertEqual(model.agents.first?.activity, .idle)
        try receive(.working, id: "task")
        try receive(.agentPresence, id: "presence-p")
        XCTAssertEqual(model.store.sessions.count, 1)
        XCTAssertEqual(model.agents.first?.activity, .working)
        try receive(.completed, id: "task")
        try receive(.agentPresence, id: "presence-p")
        XCTAssertEqual(model.store.sessions["task"]?.status, .completed)
        XCTAssertEqual(model.agents.first?.state, .online)
        XCTAssertEqual(model.agents.first?.activity, .idle)
        XCTAssertTrue(model.pending.isEmpty)
    }

    @MainActor func testProfileAnnouncementsStayOutOfTasksAndRemainSeparate() throws {
        let model = AppModel(defaults: UserDefaults(suiteName: "si-notch.profile-tests." + UUID().uuidString)!)
        for name in ["architect", "researcher"] {
            let event = AgentEvent(sessionID: "presence-" + name, provider: "hermes", kind: .agentPresence,
                id: "event-" + name, connectionID: name, connectionName: name.capitalized)
            model.receive(try JSONEncoder().encode(event)) { response in
                XCTAssertEqual((try? JSONSerialization.jsonObject(with: response) as? [String: Any])?["ok"] as? Bool, true)
            }
        }
        XCTAssertTrue(model.store.sessions.isEmpty)
        XCTAssertTrue(model.activity.isEmpty)
        XCTAssertEqual(Set(model.agents.map(\.name)), ["Architect", "Researcher"])
        XCTAssertTrue(model.agents.allSatisfy { $0.provider == "hermes" && $0.state == .online })
        for id in ["a", "b"] {
            model.receive(try JSONEncoder().encode(AgentEvent(sessionID: id, provider: "hermes", kind: .working,
                connectionID: "architect", connectionName: "Architect"))) { _ in }
        }
        XCTAssertEqual(model.agents.count, 2)
        XCTAssertEqual(model.sessions.count, 2)
        XCTAssertTrue(model.pending.isEmpty)
    }

    func testSavedProfilesStayVisibleWithoutTasksAndCanBeHiddenOrRenamed() {
        let now = Date(timeIntervalSince1970: 1000), connector = UUID()
        let observed = AgentConnection.Observation(provider: "hermes", connectionID: "p", name: "remote supplied name",
            lastSeen: now, eventAt: now, eventID: "one")
        let saved = AgentConnection.Configuration(connectionID: "p", name: "lain", connectorID: connector, visible: true)
        let quiet = AgentConnection.Configuration(connectionID: "quiet", name: "Editor", connectorID: connector, visible: true)
        let rows = AgentConnection.project(detected: [], sessions: [], receipts: [:], running: [], now: now,
            connections: [observed.id: observed], configurations: [saved, quiet])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first?.name, "lain")
        XCTAssertEqual(rows.first?.connectorID, connector)
        XCTAssertEqual(rows.first?.state, .online)
        XCTAssertEqual(rows.last?.state, .installed)
        let hidden = AgentConnection.Configuration(connectionID: "p", name: "lain", connectorID: connector, visible: false)
        XCTAssertTrue(AgentConnection.project(detected: [], sessions: [], receipts: [:], running: [], now: now,
            connections: [observed.id: observed], configurations: [hidden]).isEmpty)
    }

    func testAnotherProfilesActivityDoesNotRefreshAQuietProfile() {
        let now = Date()
        let old = now.addingTimeInterval(-121)
        let connections = [
            "hermes/a": AgentConnection.Observation(provider: "hermes", connectionID: "a", name: "A", lastSeen: now, eventAt: now, eventID: "a"),
            "hermes/b": AgentConnection.Observation(provider: "hermes", connectionID: "b", name: "B", lastSeen: old, eventAt: old, eventID: "b")]
        let agents = AgentConnection.project(detected: [], sessions: [], receipts: ["hermes": now], running: [], now: now, connections: connections)
        XCTAssertEqual(agents.first { $0.name == "A" }?.state, .online)
        XCTAssertEqual(agents.first { $0.name == "B" }?.state, .lastSeen)
    }
    func testCodexIdentitySurvivesRenamedBundleWithoutMatchingOrdinaryChatGPT() {
        XCTAssertEqual(AgentConnection.runningProviders(detected: [],
            applicationPaths: ["/Applications/ChatGPT.app"], bundleIdentifiers: ["com.openai.codex"]), ["codex"])
        XCTAssertTrue(AgentConnection.runningProviders(detected: [],
            applicationPaths: ["/Applications/ChatGPT.app"], bundleIdentifiers: ["com.openai.chat"]).isEmpty)
    }

    func testCodexLifecyclePlaceholderWaitsForTaskContext() {
        var session = AgentSession(id: "thread", provider: "codex", title: "Codex Desktop", status: .working)
        session.lastEventID = "desktop:thread:1:working"
        XCTAssertFalse(AgentConnection.isTask(session))
        session.firstPrompt = "Fix the parser"
        XCTAssertTrue(AgentConnection.isTask(session))
        session.firstPrompt = nil
        session.title = "Fix the parser"
        XCTAssertTrue(AgentConnection.isTask(session))
        session.status = .completed
        XCTAssertTrue(AgentConnection.isTask(session))
    }
    @MainActor func testIdleHarnessDoesNotCountAsTaskAndPromotesOnWork() throws {
        let model = AppModel(defaults: UserDefaults(suiteName: "si-notch.agent-tests." + UUID().uuidString)!)
        func receive(_ kind: AgentEventKind) throws {
            model.receive(try JSONEncoder().encode(AgentEvent(sessionID: "pi-1", provider: "pi", kind: kind))) { _ in }
        }
        try receive(.sessionStarted)
        XCTAssertTrue(model.sessions.isEmpty)
        XCTAssertEqual(model.agents.map(\.id), ["pi"])
        XCTAssertEqual(model.agents.first?.state, .online)
        try receive(.working)
        XCTAssertEqual(model.sessions.count, 1)
        XCTAssertEqual(model.workingCount, 1)
        try receive(.completed)
        model.activeFilter = "Готово"
        XCTAssertEqual(model.filtered.count, 1)
        try receive(.sessionEnded)
        XCTAssertTrue(model.sessions.isEmpty)
        XCTAssertEqual(model.agents.first?.state, .offline)
    }

    func testFreshnessDoesNotInventOnlineFromInstalledOrHistoricalData() {
        let now = Date(timeIntervalSince1970: 1000)
        let detection = HarnessDetection(kind: .pi, locations: [HarnessLocation(kind: .executable,
            url: URL(fileURLWithPath: "/fixture/pi"), resolvedURL: URL(fileURLWithPath: "/fixture/pi"))])
        let idle = AgentSession(id: "p", provider: "pi", createdAt: now)
        func state(_ sessions: [AgentSession] = [], _ receipts: [String: Date] = [:], _ running: Set<String> = []) -> AgentConnection.State? {
            AgentConnection.project(detected: [detection], sessions: sessions, receipts: receipts,
                running: running, now: now).first?.state
        }
        XCTAssertEqual(state(), .installed)
        XCTAssertEqual(state([idle]), .lastSeen)
        XCTAssertEqual(state([idle], ["pi": now]), .online)
        XCTAssertEqual(state([idle], ["pi": now.addingTimeInterval(-121)]), .lastSeen)
        XCTAssertEqual(state([], [:], ["pi"]), .online)
    }

    func testMultipleSessionsProduceOneAgentAndEndingOneKeepsOtherOnline() {
        let now = Date()
        let sessions = [AgentSession(id: "a", provider: "codex", status: .ended),
                        AgentSession(id: "b", provider: "codex", status: .working)]
        let agents = AgentConnection.project(detected: [], sessions: sessions,
            receipts: ["codex": now], running: [], now: now)
        XCTAssertEqual(agents.count, 1)
        XCTAssertEqual(agents.first?.state, .online)
    }
}
