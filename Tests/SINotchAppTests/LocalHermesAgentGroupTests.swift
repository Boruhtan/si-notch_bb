import XCTest
import SINotchCore
@testable import SINotch

final class LocalHermesAgentGroupTests: XCTestCase {
    func testGroupingPreservesProfilesAndLeavesSSHLegacyAndOtherProvidersSeparate() throws {
        let remote = UUID(), now = Date()
        let inventory = [LocalHermesProfile(connectionID: "main", name: "Don Digidon", isDefault: true),
                         .init(connectionID: "coder", name: "coder")]
        let observations = ["hermes/main": AgentConnection.Observation(provider: "hermes", connectionID: "main",
            name: "Main", lastSeen: now, eventAt: now, eventID: "main", origin: .local)]
        var task = AgentSession(id: "local-task", provider: "hermes", status: .working)
        task.connectionID = "main"
        let legacy = AgentSession(id: "legacy", provider: "hermes", status: .working)
        let rows = AgentConnection.project(detected: [], sessions: [task, legacy], receipts: [:], running: ["pi"], now: now,
            connections: observations, configurations: [.init(connectionID: "remote", name: "Don David", connectorID: remote,
                visible: true, transportState: .connected)], localProfiles: inventory)
        let group = try XCTUnwrap(LocalHermesAgentGroup.project(agents: rows, inventory: inventory,
                                                               observations: observations, hostName: "Karabas"))
        XCTAssertEqual(group.name, "Karabas · Don Digidon")
        XCTAssertEqual(Set(group.profiles.map(\.id)), Set(inventory.map(\.id)))
        XCTAssertEqual(group.profiles.first { $0.id == "hermes/main" }?.activeTaskCount, 1)
        XCTAssertEqual(group.profiles.first { $0.id == "hermes/coder" }?.activeTaskCount, 0)
        XCTAssertEqual(group.onlineCount, 1)
        let grouped = Set(group.profiles.map(\.id))
        let outside = rows.filter { !grouped.contains($0.id) }
        XCTAssertEqual(Set(outside.map(\.id)), Set(["hermes", "hermes/remote", "pi"]))
        XCTAssertEqual(rows.count, group.profiles.count + outside.count, "A group is not an additional agent")
    }

    func testRemoteAndUnverifiedAnnouncementsCannotEnterTheLocalGroup() {
        let now = Date(), remote = UUID()
        let rows = [AgentConnection(id: "hermes/remote", provider: "hermes", displayName: "Remote", state: .online,
                                    lastSeen: now, connectorID: remote),
                    .init(id: "hermes/unknown", provider: "hermes", displayName: "Unknown", state: .online, lastSeen: now)]
        let observations = ["hermes/unknown": AgentConnection.Observation(provider: "hermes", connectionID: "unknown",
            name: "Unverified", lastSeen: now, eventAt: now, eventID: nil, origin: .unknown)]
        XCTAssertNil(LocalHermesAgentGroup.project(agents: rows,
            inventory: [.init(connectionID: "remote", name: "Cloned local default", isDefault: true)],
            observations: observations, hostName: "Karabas"))
    }

    func testOneHundredLocalProfilesKeepIndependentTasksAndFreshness() throws {
        let now = Date(), old = now.addingTimeInterval(-130), remote = UUID()
        let inventory = (0..<100).map { LocalHermesProfile(connectionID: "local-\($0)", name: "Profile \($0)", isDefault: $0 == 0) }
        let observations = Dictionary(uniqueKeysWithValues: inventory.enumerated().map { index, profile in
            (profile.id, AgentConnection.Observation(provider: "hermes", connectionID: profile.connectionID,
                name: profile.name, lastSeen: index == 0 ? now : old, eventAt: index == 0 ? now : old,
                eventID: "event-\(index)", origin: .local))
        })
        var task = AgentSession(id: "local-task", provider: "hermes", status: .working)
        task.connectionID = "local-0"
        let rows = AgentConnection.project(detected: [], sessions: [task], receipts: [:], running: [], now: now,
            connections: observations, configurations: [.init(connectionID: "remote", name: "Remote", connectorID: remote,
                visible: true, transportState: .connected)], localProfiles: inventory)
        let group = try XCTUnwrap(LocalHermesAgentGroup.project(agents: rows, inventory: inventory,
                                                               observations: observations, hostName: "Mac"))
        XCTAssertEqual(group.profiles.count, 100)
        XCTAssertEqual(group.onlineCount, 1)
        XCTAssertEqual(group.profiles.reduce(0) { $0 + $1.activeTaskCount }, 1)
        XCTAssertEqual(rows.count, 101)
        XCTAssertTrue(group.profiles.allSatisfy { $0.connectorID == nil })
    }

    func testQuietProfilesDoNotBecomeOnlineAndDefaultNameDoesNotDependOnSorting() throws {
        let inventory = [LocalHermesProfile(connectionID: "aaa", name: "Account"),
                         .init(connectionID: "default", name: "Renamed default", isDefault: true)]
        let rows = AgentConnection.project(detected: [], sessions: [], receipts: [:], running: [], now: Date(), localProfiles: inventory)
        let group = try XCTUnwrap(LocalHermesAgentGroup.project(agents: rows, inventory: inventory, observations: [:], hostName: "Mac"))
        XCTAssertEqual(group.name, "Mac · Renamed default")
        XCTAssertEqual(group.onlineCount, 0)
        XCTAssertTrue(group.profiles.allSatisfy { $0.state == .installed && $0.activity == .unknown })
    }

    func testConfirmedLocalProfileWithoutInventoryUsesProviderGroupTitle() throws {
        let now = Date()
        let observation = AgentConnection.Observation(provider: "hermes", connectionID: "standalone", name: "Standalone",
            lastSeen: now, eventAt: now, eventID: nil, origin: .local)
        let rows = AgentConnection.project(detected: [], sessions: [], receipts: [:], running: [], now: now,
                                           connections: [observation.id: observation])
        let group = try XCTUnwrap(LocalHermesAgentGroup.project(agents: rows, inventory: [],
            observations: [observation.id: observation], hostName: "Mac"))
        XCTAssertEqual(group.name, "Mac · Hermes")
        XCTAssertEqual(group.profiles.map(\.id), [observation.id])
    }

    @MainActor
    func testCollapsedGroupResizesWithoutChangingAgentCountAndPersistsAcrossRestart() {
        let suite = "si-notch.local-group." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("Karabas", forKey: "localHermesHostName.v1")
        let model = AppModel(defaults: defaults)
        defer { model.shutdown() }
        model.showAgents = true
        model.localHermesProfiles = [.init(connectionID: "main", name: "Don Digidon", isDefault: true),
                                    .init(connectionID: "coder", name: "coder")]
        let expandedHeight = model.desiredPanelHeight
        XCTAssertTrue(model.localHermesGroupExpanded)
        XCTAssertEqual(model.ungroupedLocalAgents.count, 0)
        model.setLocalHermesGroupExpanded(false)
        XCTAssertEqual(expandedHeight - model.desiredPanelHeight, 64)
        XCTAssertEqual(model.agents.count, 2)
        let restarted = AppModel(defaults: defaults)
        defer { restarted.shutdown() }
        XCTAssertFalse(restarted.localHermesGroupExpanded)
        model.setLocalHermesGroupExpanded(true)
        XCTAssertEqual(model.desiredPanelHeight, expandedHeight)
    }

    func testRegistryIdentifiesDefaultHomeIndependentlyOfItsDisplayName() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("local-group-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for (home, instance, name) in [(root, "main", "Unusual default"),
                                      (root.appendingPathComponent("profiles/coder"), "coder", "AAA") ] {
            let folder = home.appendingPathComponent("plugins/si-notch")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["instanceId": instance, "displayName": name])
                .write(to: folder.appendingPathComponent("si-notch.json"))
        }
        let profiles = LocalHermesProfileRegistry(root: root).scan()
        XCTAssertEqual(profiles.filter(\.isDefault).map(\.name), ["Unusual default"])
        XCTAssertEqual(profiles.count, 2)
    }
}
