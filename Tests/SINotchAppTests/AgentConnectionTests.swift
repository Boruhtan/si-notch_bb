import Foundation
import XCTest
import SINotchCore
@testable import SINotch

final class AgentConnectionTests: XCTestCase {
    private let hermesApp = HarnessDetection(kind: .hermes, locations: [HarnessLocation(kind: .application,
        url: URL(fileURLWithPath: "/fixture/Hermes.app"), resolvedURL: URL(fileURLWithPath: "/fixture/Hermes.app"))])

    private func presence(_ id: String, at date: Date) -> AgentConnection.Observation {
        .init(provider: "hermes", connectionID: id, name: id, lastSeen: date, eventAt: date, eventID: id)
    }

    func testConfirmedLocalProfileReplacesInstalledAndRunningAppOnlyRow() {
        let now = Date(), local = presence("local", at: Date())
        for status: AgentStatus in [.idle, .completed, .ended] {
            let historical = AgentSession(id: "old", provider: "hermes", status: status,
                createdAt: now.addingTimeInterval(-300))
            let rows = AgentConnection.project(detected: [hermesApp], sessions: [historical], receipts: [:],
                running: ["hermes"], now: now, connections: [local.id: local],
                localIdentities: [.init(provider: "hermes", connectionID: "local")])
            XCTAssertEqual(rows.map(\.id), [local.id], "Historical \(status) must not recreate a duplicate")
            XCTAssertEqual(rows.filter { $0.state == .online }.count, 1)
        }
    }

    func testRemoteProfileCannotHideTheLocalApplication() {
        let now = Date(), remote = presence("remote", at: Date()), connector = UUID()
        let saved = AgentConnection.Configuration(connectionID: "remote", name: "Don David", connectorID: connector,
            visible: true, transportState: .connected)
        // Even an identity collision must not override saved SSH ownership.
        let rows = AgentConnection.project(detected: [hermesApp], sessions: [], receipts: [:], running: ["hermes"],
            now: now, connections: [remote.id: remote], configurations: [saved],
            localIdentities: [.init(provider: "hermes", connectionID: "remote")])
        XCTAssertEqual(Set(rows.map(\.id)), ["hermes", remote.id])
        XCTAssertNil(rows.first { $0.id == "hermes" }?.connectorID)
        XCTAssertEqual(rows.first { $0.id == remote.id }?.connectorID, connector)
    }

    func testUnverifiedNamedAnnouncementDoesNotClaimTheLocalApplication() {
        let now = Date(), unverified = presence("unknown-origin", at: Date())
        let rows = AgentConnection.project(detected: [hermesApp], sessions: [], receipts: [:], running: ["hermes"],
            now: now, connections: [unverified.id: unverified])
        XCTAssertEqual(Set(rows.map(\.id)), ["hermes", unverified.id])
    }

    func testIndependentProviderReceiptSurvivesAnUnrelatedRemoteProfile() {
        let now = Date(), remote = presence("ssh", at: Date())
        let rows = AgentConnection.project(detected: [], sessions: [], receipts: ["hermes": now], running: [],
            now: now, connections: [remote.id: remote])
        XCTAssertEqual(Set(rows.map(\.id)), ["hermes", remote.id])
        XCTAssertEqual(rows.first { $0.id == "hermes" }?.lastSeen, now)
    }

    func testNamedLocalAndSSHProfilesKeepSeparateTasksAndAgentCounts() throws {
        let now = Date(), connector = UUID()
        let observations = [presence("a", at: now), presence("b", at: now), presence("ssh", at: now)]
        var a = AgentSession(id: "a-task", provider: "hermes", status: .working); a.connectionID = "a"
        var b = AgentSession(id: "b-task", provider: "hermes", status: .completed); b.connectionID = "b"
        var ssh = AgentSession(id: "remote-task", provider: "hermes", status: .waiting); ssh.connectionID = "ssh"
        let rows = AgentConnection.project(detected: [hermesApp], sessions: [a, b, ssh], receipts: [:],
            running: ["hermes"], now: now, connections: Dictionary(uniqueKeysWithValues: observations.map { ($0.id, $0) }),
            configurations: [.init(connectionID: "ssh", name: "Don David", connectorID: connector,
                visible: true, transportState: .connected)],
            localIdentities: [.init(provider: "hermes", connectionID: "a"), .init(provider: "hermes", connectionID: "b")])
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(Set(rows.map(\.id)).count, 3)
        XCTAssertEqual(rows.filter { $0.state == .online }.count, 3)
        XCTAssertEqual(rows.first { $0.id == "hermes/a" }?.activeTaskCount, 1)
        XCTAssertEqual(rows.first { $0.id == "hermes/b" }?.activeTaskCount, 0)
        XCTAssertEqual(rows.first { $0.id == "hermes/ssh" }?.activeTaskCount, 1)
        XCTAssertEqual(rows.first { $0.id == "hermes/ssh" }?.activity, .attention)
        XCTAssertEqual(rows.first { $0.id == "hermes/ssh" }?.connectorID, connector)
    }

    func testIndependentActiveUnscopedSessionIsNotMergedIntoLocalProfile() {
        let now = Date(), local = presence("local", at: Date())
        for status: AgentStatus in [.working, .waiting, .approval, .failed] {
            let separate = AgentSession(id: "unscoped", provider: "hermes", status: status)
            let rows = AgentConnection.project(detected: [hermesApp], sessions: [separate], receipts: ["hermes": now],
                running: ["hermes"], now: now, connections: [local.id: local],
                localIdentities: [.init(provider: "hermes", connectionID: "local")])
            XCTAssertEqual(rows.count, 2)
            XCTAssertEqual(rows.first { $0.id == "hermes" }?.activeTaskCount, 1)
            XCTAssertEqual(rows.first { $0.id == local.id }?.activeTaskCount, 0)
        }
    }

    func testLocalProfilePresenceCannotRefreshAnIndependentUnscopedAgent() {
        let now = Date(), old = now.addingTimeInterval(-121), local = presence("local", at: Date())
        let separate = AgentSession(id: "unscoped", provider: "hermes", status: .working, createdAt: old)
        let rows = AgentConnection.project(detected: [hermesApp], sessions: [separate], receipts: ["hermes": old],
            running: ["hermes"], now: now, connections: [local.id: local],
            localIdentities: [.init(provider: "hermes", connectionID: "local")])
        XCTAssertEqual(rows.first { $0.id == "hermes" }?.state, .lastSeen)
        XCTAssertEqual(rows.first { $0.id == "hermes" }?.lastSeen, old)
        XCTAssertEqual(rows.first { $0.id == local.id }?.state, .online)
    }

    func testStaleFutureHiddenAndDisconnectedProfilesDoNotSuppressLocalApp() {
        let now = Date()
        for date in [now.addingTimeInterval(-121), now.addingTimeInterval(6)] {
            let local = presence("local", at: date)
            let rows = AgentConnection.project(detected: [hermesApp], sessions: [], receipts: [:], running: ["hermes"],
                now: now, connections: [local.id: local], localIdentities: [.init(provider: "hermes", connectionID: "local")])
            XCTAssertEqual(rows.first { $0.id == "hermes" }?.state, .online)
            XCTAssertEqual(rows.first { $0.id == local.id }?.state, .lastSeen)
        }
        let local = presence("local", at: now)
        for visible in [false, true] {
            let saved = AgentConnection.Configuration(connectionID: "local", name: "disabled", connectorID: UUID(),
                visible: visible, transportState: .disconnected)
            let rows = AgentConnection.project(detected: [hermesApp], sessions: [], receipts: [:], running: ["hermes"],
                now: now, connections: [local.id: local], configurations: [saved],
                localIdentities: [.init(provider: "hermes", connectionID: "local")])
            XCTAssertEqual(rows.first { $0.id == "hermes" }?.state, .online)
            XCTAssertEqual(rows.contains { $0.id == local.id }, visible)
        }
    }

    func testIdentityFileAloneDoesNotSuppressTheLocalApp() {
        let rows = AgentConnection.project(detected: [hermesApp], sessions: [], receipts: [:], running: ["hermes"],
            now: Date(), localIdentities: [.init(provider: "hermes", connectionID: "not-observed")])
        XCTAssertEqual(rows.map(\.id), ["hermes"])
    }

    func testLocalIdentityDiscoveryUsesStableInstanceAndMatchingSocketNotDisplayName() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let settings = home.appendingPathComponent(".hermes/plugins/si-notch/si-notch.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        func write(_ object: [String: Any]) throws { try JSONSerialization.data(withJSONObject: object).write(to: settings) }
        let discovery = LocalHermesIdentityDiscovery(home: home, environment: [:])
        let socket = home.appendingPathComponent(".si-notch/run/events.sock").path
        try write(["instanceId": "test", "displayName": "Don Digidon"])
        let expected: Set<AgentConnection.LocalIdentity> = [.init(provider: "hermes",
            connectionID: "hermes-instance-9f86d081884c7d659a2feaa0c55ad015")]
        XCTAssertEqual(discovery.scan(socketPath: socket), expected)
        try write(["instanceId": "test", "displayName": "Changed label"])
        XCTAssertEqual(discovery.scan(socketPath: socket), expected)
        try write(["instanceId": "test", "socketPath": "/different/events.sock"])
        XCTAssertTrue(discovery.scan(socketPath: socket).isEmpty)
        try write(["displayName": "Don Digidon"])
        XCTAssertTrue(discovery.scan(socketPath: socket).isEmpty)
        try write(["instanceId": ""])
        XCTAssertTrue(discovery.scan(socketPath: socket).isEmpty)
    }

    @MainActor func testProfileEventsCannotRefreshProviderReceiptOrAnotherProfile() throws {
        let suite = "si-notch.identity-tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = AppModel(defaults: defaults, localIdentityDiscovery: .init(home: home, environment: [:]))
        defer { model.shutdown(); defaults.removePersistentDomain(forName: suite) }
        let old = Date().addingTimeInterval(-121)
        model.providerReceipts["hermes"] = old
        let other = presence("other", at: old)
        model.connectionReceipts[other.id] = other
        for kind: AgentEventKind in [.agentPresence, .working, .completed] {
            let event = AgentEvent(sessionID: "one", provider: "hermes", kind: kind,
                connectionID: "one", connectionName: "One")
            model.receive(try JSONEncoder().encode(event)) { _ in }
            XCTAssertEqual(model.providerReceipts["hermes"], old)
            XCTAssertEqual(model.connectionReceipts[other.id]?.lastSeen, old)
            XCTAssertEqual(model.agents.first { $0.id == other.id }?.state, .lastSeen)
        }
        let unscoped = AgentEvent(sessionID: "independent", provider: "hermes", kind: .working)
        model.receive(try JSONEncoder().encode(unscoped)) { _ in }
        XCTAssertGreaterThan(try XCTUnwrap(model.providerReceipts["hermes"]), old)
    }

    @MainActor func testAppModelLoadsConfirmedLocalIdentityAndDeduplicatesProjectionAndTick() throws {
        let suite = "si-notch.local-identity-tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let settings = home.appendingPathComponent(".hermes/plugins/si-notch/si-notch.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        let model = AppModel(defaults: defaults, localIdentityDiscovery: .init(home: home, environment: [:]))
        try JSONSerialization.data(withJSONObject: ["instanceId": "test", "socketPath": model.socketPath]).write(to: settings)
        defer { model.shutdown(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: home) }
        model.detectedHarnesses = [hermesApp]; model.runningAgentProviders = ["hermes"]
        let event = AgentEvent(sessionID: "presence", provider: "hermes", kind: .agentPresence,
            connectionID: "hermes-instance-9f86d081884c7d659a2feaa0c55ad015", connectionName: "Don Digidon")
        model.receive(try JSONEncoder().encode(event)) { _ in }
        XCTAssertNil(model.providerReceipts["hermes"])
        XCTAssertEqual(model.agents.map(\.name), ["Don Digidon"])
        XCTAssertEqual(model.agents.filter { $0.state == .online }.count, 1)
        model.tick()
        XCTAssertEqual(model.agents.map(\.name), ["Don Digidon"])
        XCTAssertTrue(model.sessions.isEmpty)
    }

    func testLocalAliasPreservesProviderIdentityAndTaskActivity() throws {
        let now = Date()
        let task = AgentSession(id: "local-task", provider: "hermes", status: .working)
        let rows = AgentConnection.project(detected: [], sessions: [task], receipts: ["hermes": now],
            running: ["hermes", "codex"], now: now, localDisplayNames: ["hermes": "  Don Digidon  "])
        let local = try XCTUnwrap(rows.first { $0.id == "hermes" })
        XCTAssertEqual(local.name, "Don Digidon")
        XCTAssertEqual(local.provider, "hermes")
        XCTAssertEqual(local.state, .online)
        XCTAssertEqual(local.activity, .working)
        XCTAssertEqual(local.activeTaskCount, 1)
        XCTAssertEqual(rows.first { $0.id == "codex" }?.name, "Codex")
    }

    func testLocalAliasNeverRenamesRemoteOrQuietProfiles() {
        let now = Date(), connector = UUID()
        let observed = AgentConnection.Observation(provider: "hermes", connectionID: "remote",
            name: "remote supplied name", lastSeen: now, eventAt: now, eventID: "heartbeat")
        let saved = AgentConnection.Configuration(connectionID: "remote", name: "Don David",
            connectorID: connector, visible: true, transportState: .connected)
        let quiet = AgentConnection.Configuration(connectionID: "customs", name: "customs",
            connectorID: connector, visible: true, transportState: .connected)
        let rows = AgentConnection.project(detected: [], sessions: [], receipts: [:], running: ["hermes"],
            now: now, connections: [observed.id: observed], configurations: [saved, quiet],
            localDisplayNames: ["hermes": "Don Digidon"])
        XCTAssertEqual(rows.first { $0.id == "hermes" }?.name, "Don Digidon")
        XCTAssertEqual(rows.first { $0.id == observed.id }?.name, "Don David")
        XCTAssertEqual(rows.first { $0.id == observed.id }?.connectorID, connector)
        XCTAssertEqual(rows.first { $0.id == "hermes/customs" }?.name, "customs")
        XCTAssertEqual(rows.count, 3)
    }

    func testInvalidLocalAliasesFallBackToProductName() {
        for alias in ["", " \n\t ", "Don\nDigidon", "Don\u{0000}Digidon", String(repeating: "x", count: 129)] {
            let rows = AgentConnection.project(detected: [], sessions: [], receipts: [:], running: ["hermes"],
                now: Date(), localDisplayNames: ["hermes": alias])
            XCTAssertEqual(rows.first?.name, "Hermes", "Invalid alias: \(alias.debugDescription)")
        }
        let boundary = String(repeating: "x", count: 128)
        XCTAssertEqual(AgentConnection.project(detected: [], sessions: [], receipts: [:], running: ["hermes"],
            now: Date(), localDisplayNames: ["hermes": boundary]).first?.name, boundary)
    }

    @MainActor func testAppModelReadsLocalAliasWithoutChangingRemoteProfileNames() throws {
        let suite = "si-notch.local-alias-tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(["hermes": "Don Digidon"], forKey: "localAgentDisplayNames.v1")
        let model = AppModel(defaults: defaults)
        defer { model.shutdown(); defaults.removePersistentDomain(forName: suite) }
        for event in [AgentEvent(sessionID: "local", provider: "hermes", kind: .sessionStarted),
                      AgentEvent(sessionID: "presence-remote", provider: "hermes", kind: .agentPresence,
                          connectionID: "remote", connectionName: "Don David")] {
            model.receive(try JSONEncoder().encode(event)) { _ in }
        }
        XCTAssertEqual(model.agents.first { $0.id == "hermes" }?.name, "Don Digidon")
        XCTAssertEqual(model.agents.first { $0.id == "hermes/remote" }?.name, "Don David")
        XCTAssertFalse(model.agents.contains { $0.name == "Hermes" })
        defaults.set(["hermes": "Local alias changed"], forKey: "localAgentDisplayNames.v1")
        model.tick()
        XCTAssertEqual(model.agents.first { $0.id == "hermes" }?.name, "Local alias changed")
        XCTAssertEqual(model.agents.first { $0.id == "hermes/remote" }?.name, "Don David")
    }

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
