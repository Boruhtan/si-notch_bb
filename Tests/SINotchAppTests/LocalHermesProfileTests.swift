import Foundation
import XCTest
import SINotchCore
@testable import SINotch

final class LocalHermesProfileTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func settings(_ root: URL, profile: String?, instance: String, name: String, socket: String? = nil) throws -> URL {
        let home = profile.map { root.appendingPathComponent("profiles/" + $0) } ?? root
        let file = home.appendingPathComponent("plugins/si-notch/si-notch.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var object = ["instanceId": instance, "displayName": name]
        if let socket { object["socketPath"] = socket }
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        return file
    }

    func testInventoryRetainsQuietProfilesWithoutInventingPresence() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try settings(root, profile: nil, instance: "default", name: "Main")
        _ = try settings(root, profile: "legal", instance: "legal", name: "Legal")
        let registry = LocalHermesProfileRegistry(root: root)
        let profiles = registry.scan()
        XCTAssertEqual(Set(profiles.map(\.name)), ["Main", "Legal"])
        let rows = AgentConnection.project(detected: [], sessions: [], receipts: [:], running: ["hermes"],
            now: Date(), localProfiles: profiles)
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy { $0.state == .installed && $0.activeTaskCount == 0 && $0.connectorID == nil })
        XCTAssertFalse(rows.contains { $0.id == "hermes" })
    }

    func testNamesDoNotChangeIdentityAndInvalidOrClonedSettingsFailClosed() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try settings(root, profile: nil, instance: "stable", name: "First")
        let registry = LocalHermesProfileRegistry(root: root)
        let original = try XCTUnwrap(registry.scan().first)
        _ = try settings(root, profile: nil, instance: "stable", name: "Changed")
        XCTAssertEqual(registry.scan().first?.id, original.id)
        let clone = try settings(root, profile: "clone", instance: "stable", name: "Clone")
        XCTAssertTrue(registry.scan().isEmpty)
        try FileManager.default.removeItem(at: clone)
        _ = try settings(root, profile: "bad-name", instance: "bad", name: "bad\nname")
        _ = try settings(root, profile: "other-socket", instance: "other", name: "Other", socket: "/other/events.sock")
        XCTAssertEqual(registry.scan().map(\.name), ["Changed"])
    }

    func testRegisteredProfilesKeepTasksFreshnessAndSSHOwnershipSeparate() {
        let now = Date(), old = now.addingTimeInterval(-121), connector = UUID()
        let local = [LocalHermesProfile(connectionID: "a", name: "A"), .init(connectionID: "b", name: "B")]
        let observations = ["hermes/a": AgentConnection.Observation(provider: "hermes", connectionID: "a", name: "Untrusted label",
            lastSeen: now, eventAt: now, eventID: "one", origin: .local),
            "hermes/b": .init(provider: "hermes", connectionID: "b", name: "B", lastSeen: old, eventAt: old, eventID: "old", origin: .local)]
        var task = AgentSession(id: "a-task", provider: "hermes", status: .working); task.connectionID = "a"
        let config = AgentConnection.Configuration(connectionID: "remote", name: "Remote", connectorID: connector,
            visible: true, transportState: .connected)
        let rows = AgentConnection.project(detected: [], sessions: [task], receipts: [:], running: ["hermes"], now: now,
            connections: observations, configurations: [config], localProfiles: local)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.first { $0.id == "hermes/a" }?.name, "A")
        XCTAssertEqual(rows.first { $0.id == "hermes/a" }?.activeTaskCount, 1)
        XCTAssertEqual(rows.first { $0.id == "hermes/b" }?.state, .lastSeen)
        XCTAssertEqual(rows.first { $0.id == "hermes/remote" }?.connectorID, connector)
        let collision = AgentConnection.project(detected: [], sessions: [], receipts: [:], running: [], now: now,
            configurations: [config], localProfiles: [.init(connectionID: "remote", name: "Local clone")])
        XCTAssertEqual(collision.map(\.name), ["Remote"])
    }

    func testUnknownOriginCannotClaimRegisteredLocalProfileAndLegacyWorkSurvives() {
        let now = Date(), profile = LocalHermesProfile(connectionID: "a", name: "A")
        let unknown = AgentConnection.Observation(provider: "hermes", connectionID: "a", name: "Impersonator",
            lastSeen: now, eventAt: now, eventID: "one", origin: .unknown)
        let task = AgentSession(id: "separate", provider: "hermes", status: .working)
        let rows = AgentConnection.project(detected: [], sessions: [task], receipts: ["hermes": now], running: [],
            now: now, connections: [unknown.id: unknown], localProfiles: [profile])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first { $0.id == profile.id }?.state, .installed)
        XCTAssertEqual(rows.first { $0.id == "hermes" }?.activeTaskCount, 1)
    }

    @MainActor func testModelRefreshFindsNewProfilesAndRejectsRemoteTakeover() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let suite = "si-notch.local-profile-tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let model = AppModel(defaults: defaults, localProfileRegistry: .init(root: root))
        defer { model.shutdown(); defaults.removePersistentDomain(forName: suite) }
        model.refreshLocalProfiles(); XCTAssertTrue(model.localHermesProfiles.isEmpty)
        _ = try settings(root, profile: "coder", instance: "coder", name: "Coder")
        model.refreshLocalProfiles(); let profile = try XCTUnwrap(model.localHermesProfiles.first)
        let event = AgentEvent(sessionID: "task", provider: "hermes", kind: .working, connectionID: profile.connectionID)
        model.receive(try JSONEncoder().encode(event), origin: .unknown) { _ in }
        XCTAssertNil(model.store.sessions["task"])
        model.receive(try JSONEncoder().encode(event), origin: .local) { _ in }
        XCTAssertEqual(model.agents.first { $0.id == profile.id }?.activeTaskCount, 1)
    }

    @MainActor func testForkBundleBlocksFeedDownloadAndInstaller() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("Fork.bundle")
        try FileManager.default.createDirectory(at: bundleURL.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "test.fork", "SIUpdatesDisabled": true],
            format: .xml, options: 0).write(to: bundleURL.appendingPathComponent("Contents/Info.plist"))
        let bundle = try XCTUnwrap(Bundle(url: bundleURL))
        XCTAssertTrue(ForkUpdatePolicy.disabled(in: bundle))
        XCTAssertNil(UpdateConfiguration(bundle: bundle))
        let service = UpdateService(updatesDisabled: true)
        let result = try await service.check(currentVersion: "0.4.37-bb.2", channel: .stable)
        XCTAssertEqual(result, .unconfigured)
        let release = UpdateRelease(version: "99.0.0", bundleVersion: "99.0.0", bundleBuild: "99", channel: .stable,
            notes: "", url: URL(string: "https://invalid.example/archive.zip")!, sha256: "", size: 1)
        do { _ = try await service.downloadVerified(release); XCTFail("Fork must not download updates") }
        catch UpdateError.unavailable { }
        do { try UpdateInstaller.start(archive: root.appendingPathComponent("missing.zip"), release: release, bundle: bundle); XCTFail("Fork must not launch updater") }
        catch UpdateError.unavailable { }
    }
}
