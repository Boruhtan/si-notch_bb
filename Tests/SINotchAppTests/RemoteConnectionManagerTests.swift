import Foundation
import XCTest
@testable import SINotch

final class RemoteConnectionManagerTests: XCTestCase {
    @MainActor
    func testLegacyMigrationDoesNotConnectAndNamesPersistIndependently() throws {
        let suite = "si-notch.remote-manager." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("user@host", forKey: "remoteSSHHost")
        defaults.set("/home/user/run/e.sock", forKey: "remoteSSHSocketPath")
        let manager = RemoteConnectionManager(defaults: defaults)
        let first = try XCTUnwrap(manager.connections.first)
        XCTAssertEqual(manager.state(first.id), .disconnected)
        XCTAssertEqual(first.host, "user@host")
        var renamed = first; renamed.name = "lain"; manager.update(renamed)
        let secondID = try XCTUnwrap(manager.add())
        XCTAssertNotEqual(first.id, secondID)
        let restored = RemoteConnectionManager(defaults: defaults)
        XCTAssertEqual(restored.connections.count, 2)
        XCTAssertEqual(restored.connections.first?.name, "lain")
        XCTAssertEqual(restored.state(first.id), .disconnected)
        manager.remove(secondID)
        XCTAssertEqual(manager.connections.count, 1)
    }

    @MainActor
    func testCorruptStorageIsPreserved() {
        let suite = "si-notch.remote-manager." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = Data("corrupt fixture".utf8)
        defaults.set(original, forKey: RemoteConnectionManager.storageKey)
        let manager = RemoteConnectionManager(defaults: defaults)
        XCTAssertNotNil(manager.error)
        XCTAssertNil(manager.add())
        manager.remove(UUID())
        XCTAssertEqual(defaults.data(forKey: RemoteConnectionManager.storageKey), original)
    }

    @MainActor
    func testConnectionIntentSurvivesShutdownAndExplicitDisconnectStaysOff() async throws {
        let suite = "si-notch.remote-manager." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ssh = try fakeSSH(in: directory)
        var createdControllers = 0
        let factory = {
            createdControllers += 1
            return RemoteConnectionController(defaults: nil, sshExecutable: ssh, retryDelays: [], socketAvailable: { _ in true })
        }
        let manager = RemoteConnectionManager(defaults: defaults, makeController: factory)
        defer { manager.disconnectAll() }
        let id = try XCTUnwrap(manager.add()), idle = try XCTUnwrap(manager.add())
        var connection = manager.connections[0]
        connection.host = "fixture"; connection.remoteSocketPath = "/home/a/events.sock"
        manager.update(connection)
        manager.restoreConnections(localSocketPath: "/Users/test/e.sock")
        XCTAssertEqual(createdControllers, 0)
        manager.connect(id, localSocketPath: "/Users/test/e.sock")
        try await waitForConnection(manager, id)
        XCTAssertTrue(manager.reconnectAtLaunch(id))
        XCTAssertFalse(manager.reconnectAtLaunch(idle))
        manager.disconnectAll()

        let restarted = RemoteConnectionManager(defaults: defaults, makeController: factory)
        defer { restarted.disconnectAll() }
        XCTAssertEqual(restarted.state(id), .disconnected)
        restarted.restoreConnections(localSocketPath: "/Users/test/e.sock")
        restarted.restoreConnections(localSocketPath: "/Users/test/e.sock")
        try await waitForConnection(restarted, id)
        XCTAssertEqual(createdControllers, 2)
        XCTAssertEqual(restarted.state(idle), .disconnected)
        restarted.disconnect(id)

        let optedOut = RemoteConnectionManager(defaults: defaults, makeController: factory)
        optedOut.restoreConnections(localSocketPath: "/Users/test/e.sock")
        XCTAssertEqual(optedOut.state(id), .disconnected)
        XCTAssertFalse(optedOut.reconnectAtLaunch(id))
        XCTAssertEqual(createdControllers, 2)
        optedOut.setReconnectAtLaunch(id, enabled: true)
        optedOut.remove(id)
        XCTAssertFalse(optedOut.reconnectAtLaunch(id))
    }

    @MainActor
    func testStartupChoiceCanBeDisabledAfterFailureAndEndpointEditsClearIt() throws {
        let suite = "si-notch.remote-manager." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = RemoteConnectionManager(defaults: defaults, makeController: {
            RemoteConnectionController(defaults: nil, socketAvailable: { _ in false })
        })
        let id = try XCTUnwrap(manager.add())
        var connection = manager.connections[0]
        connection.host = "fixture"; connection.remoteSocketPath = "/home/a/events.sock"
        manager.update(connection)
        manager.setReconnectAtLaunch(id, enabled: true)
        manager.restoreConnections(localSocketPath: "/missing.sock")
        XCTAssertEqual(manager.state(id), .failed(.localSocketUnavailable))
        XCTAssertTrue(manager.reconnectAtLaunch(id))
        manager.setReconnectAtLaunch(id, enabled: false)
        XCTAssertFalse(RemoteConnectionManager(defaults: defaults).reconnectAtLaunch(id))
        manager.setReconnectAtLaunch(id, enabled: true)
        connection.name = "Renamed"
        manager.update(connection)
        XCTAssertTrue(manager.reconnectAtLaunch(id))
        connection.host = "other-host"
        manager.update(connection)
        XCTAssertFalse(manager.reconnectAtLaunch(id))
        XCTAssertFalse(RemoteConnectionManager(defaults: defaults).reconnectAtLaunch(id))
    }

    @MainActor
    private func waitForConnection(_ manager: RemoteConnectionManager, _ id: UUID) async throws {
        // Process launch/pipe callbacks can be delayed in the full app suite.
        // Keep the confirmation assertion, below the controller's 10 s deadline.
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while ProcessInfo.processInfo.systemUptime < deadline, manager.state(id) != .connected {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(manager.state(id), .connected)
    }

    private func fakeSSH(in directory: URL) throws -> URL {
        let ssh = directory.appendingPathComponent("ssh")
        try """
        #!/bin/sh
        for arg in "$@"; do
          if [ "$previous" = '-R' ]; then forward="$arg"; fi
          previous="$arg"
        done
        printf 'debug1: remote forward success for: listen %s:-2, connect %s:-2\\n' "${forward%:*}" "${forward#*:}" >&2
        exec /bin/cat >/dev/null
        """.write(to: ssh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ssh.path)
        return ssh
    }

    @MainActor
    func testTunnelsAreIndependentAndDuplicateEndpointIsRejected() async throws {
        let suite = "si-notch.remote-manager." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ssh = directory.appendingPathComponent("ssh")
        try """
        #!/bin/sh
        for arg in "$@"; do
          if [ "$previous" = '-R' ]; then forward="$arg"; fi
          previous="$arg"
        done
        printf 'debug1: remote forward success for: listen %s:-2, connect %s:-2\\n' "${forward%:*}" "${forward#*:}" >&2
        exec sleep 20
        """.write(to: ssh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ssh.path)
        let manager = RemoteConnectionManager(defaults: defaults, makeController: {
            RemoteConnectionController(defaults: nil, sshExecutable: ssh, retryDelays: [], socketAvailable: { _ in true })
        })
        defer { manager.disconnectAll() }
        let a = try XCTUnwrap(manager.add()), b = try XCTUnwrap(manager.add())
        var first = manager.connections[0]; first.host = "fixture"; first.remoteSocketPath = "/home/a/events.sock"; manager.update(first)
        var second = manager.connections[1]; second.host = "fixture"; second.remoteSocketPath = first.remoteSocketPath; manager.update(second)
        manager.connect(a, localSocketPath: "/Users/test/run/e.sock")
        manager.connect(b, localSocketPath: "/Users/test/run/e.sock")
        XCTAssertNotNil(manager.error)
        XCTAssertEqual(manager.state(b), .disconnected)
        second.remoteSocketPath = "/home/b/events.sock"; manager.update(second)
        manager.connect(b, localSocketPath: "/Users/test/run/e.sock")
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while ProcessInfo.processInfo.systemUptime < deadline, manager.state(a) != .connected || manager.state(b) != .connected {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(manager.state(a), .connected)
        XCTAssertEqual(manager.state(b), .connected)
        first.host = "edited"; manager.update(first)
        XCTAssertEqual(manager.connections[0].host, "fixture")
        manager.disconnect(a)
        XCTAssertEqual(manager.state(a), .disconnected)
        XCTAssertEqual(manager.state(b), .connected)
    }
}
