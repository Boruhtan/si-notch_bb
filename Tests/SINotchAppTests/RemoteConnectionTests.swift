import Foundation
import XCTest
@testable import SINotch

final class RemoteConnectionTests: XCTestCase {
    func testSSHArgumentsUsePrivateReverseUnixSocketAndKnownHost() throws {
        let command = try RemoteSSHCommand(host: "alice@build-box",
                                           remoteSocketPath: "/home/alice/.si-notch/run/events.sock",
                                           localSocketPath: "/Users/alice/.si-notch/run/events.sock")
        let args = command.arguments
        XCTAssertEqual(args.suffix(3), ["--", "alice@build-box", "exec /bin/cat >/dev/null"])
        XCTAssertFalse(args.contains("-N"))
        XCTAssertTrue(args.contains("/home/alice/.si-notch/run/events.sock:/Users/alice/.si-notch/run/events.sock"))
        for requirement in ["BatchMode=yes", "StrictHostKeyChecking=yes", "ExitOnForwardFailure=yes",
                            "ForwardAgent=no", "StreamLocalBindMask=0177", "StreamLocalBindUnlink=no",
                            "ControlPath=none", "ControlMaster=no", "ControlPersist=no"] {
            XCTAssertTrue(args.contains(requirement), "Missing \(requirement)")
        }
        XCTAssertEqual(args.filter { $0 == "-R" }.count, 1)
        XCTAssertFalse(args.contains(where: { $0 == "-L" || $0 == "-D" }))
    }

    func testHostAndSocketValidationRejectsOptionAndPathInjection() {
        for host in ["-oProxyCommand=bad", "alice@-host", "a;touch /tmp/x", "a b", "a\nhost", "a@@host"] {
            XCTAssertThrowsError(try RemoteSSHCommand(host: host, remoteSocketPath: "/home/a/run/e.sock",
                                                      localSocketPath: "/Users/a/run/e.sock"))
        }
        for path in ["relative.sock", "/tmp/../etc/sock", "/tmp/a:b.sock", "/tmp/x\n-Rbad", "/tmp/"] {
            XCTAssertThrowsError(try RemoteSSHCommand(host: "build-box", remoteSocketPath: path,
                                                      localSocketPath: "/Users/a/run/e.sock"))
        }
    }

    func testOnlyMatchingOpenSSHForwardConfirmationCounts() {
        let path = "/home/alice/.si-notch/run/events.sock"
        let local = "/Users/alice/.si-notch/run/events.sock"
        XCTAssertTrue(RemoteSSHForwardConfirmation.matches(
            "debug1: remote forward success for: listen \(path):-2, connect \(local):-2",
            remoteSocketPath: path, localSocketPath: local))
        XCTAssertFalse(RemoteSSHForwardConfirmation.matches("debug1: remote forward failure for: listen \(path):-2, connect \(local):-2",
                                                         remoteSocketPath: path, localSocketPath: local))
        XCTAssertFalse(RemoteSSHForwardConfirmation.matches("debug1: remote forward success for: listen /other:-2, connect \(local):-2",
                                                         remoteSocketPath: path, localSocketPath: local))
        XCTAssertFalse(RemoteSSHForwardConfirmation.matches("debug1: remote forward success for: listen \(path):-2, connect /other:-2",
                                                         remoteSocketPath: path, localSocketPath: local))
        XCTAssertFalse(RemoteSSHForwardConfirmation.matches("Banner: remote forward success for: listen \(path):-2, connect \(local):-2",
                                                         remoteSocketPath: path, localSocketPath: local))
    }

    @MainActor
    func testLongOutageKeepsRetryingAndDisconnectCancelsPendingRetry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("si-notch-ssh-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fakeSSH = directory.appendingPathComponent("ssh")
        let launches = directory.appendingPathComponent("launches")
        try "#!/bin/sh\necho attempt >> '\(launches.path)'\nexit 255\n".write(to: fakeSSH, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeSSH.path)
        let defaults = UserDefaults(suiteName: "si-notch.remote-tests." + UUID().uuidString)!
        let controller = RemoteConnectionController(defaults: defaults, sshExecutable: fakeSSH,
                                                    retryDelays: [0.01, 0.02], socketAvailable: { _ in true })
        controller.host = "fixture"
        controller.remoteSocketPath = "/home/fixture/.si-notch/run/events.sock"
        controller.connect(localSocketPath: "/Users/fixture/.si-notch/run/events.sock")
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while ProcessInfo.processInfo.systemUptime < deadline {
            if (try? String(contentsOf: launches, encoding: .utf8).split(separator: "\n").count) ?? 0 >= 6 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(controller.state, .retrying)
        let count = (try? String(contentsOf: launches, encoding: .utf8).split(separator: "\n").count) ?? 0
        XCTAssertGreaterThanOrEqual(count, 6, "Transient outages must outlive the initial retry schedule")
        controller.disconnect()
        XCTAssertEqual(controller.state, .disconnected)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual((try? String(contentsOf: launches, encoding: .utf8).split(separator: "\n").count) ?? 0, count)
    }

    @MainActor
    func testSuccessfulForwardResetsBackoffAcrossRepeatedOutages() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("si-notch-ssh-flap-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ssh = directory.appendingPathComponent("ssh"), count = directory.appendingPathComponent("count")
        try """
        #!/bin/sh
        n=0
        if [ -f '\(count.path)' ]; then read n < '\(count.path)'; fi
        n=$((n + 1))
        echo "$n" > '\(count.path)'
        if [ "$n" = 1 ]; then exit 255; fi
        printf '%s\\n' 'debug1: remote forward success for: listen /home/test/e.sock:-2, connect /Users/test/e.sock:-2' >&2
        if [ "$n" -lt 5 ]; then sleep 0.1; exit 255; fi
        exec /bin/cat >/dev/null
        """.write(to: ssh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ssh.path)
        let controller = RemoteConnectionController(defaults: nil, sshExecutable: ssh,
            retryDelays: [0.01, 2], socketAvailable: { _ in true })
        defer { controller.disconnect() }
        controller.host = "fixture"
        controller.remoteSocketPath = "/home/test/e.sock"
        controller.connect(localSocketPath: "/Users/test/e.sock")
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while ProcessInfo.processInfo.systemUptime < deadline {
            if controller.state == .connected,
               (try? String(contentsOf: count, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) == "5" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(controller.state, .connected)
        XCTAssertEqual(try String(contentsOf: count, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "5")
    }

    @MainActor
    func testControllerBecomesConnectedOnlyAfterForwardConfirmation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("si-notch-ssh-confirm-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fakeSSH = directory.appendingPathComponent("ssh")
        let remote = "/home/fixture/.si-notch/run/events.sock"
        let script = "#!/bin/sh\nprintf '%5000s\\n' x >&2\nprintf '%s\\n' 'debug1: remote forward success for: listen \(remote):-2, connect /Users/fixture/.si-notch/run/events.sock:-2' >&2\nexec sleep 30\n"
        try script.write(to: fakeSSH, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeSSH.path)
        let defaults = UserDefaults(suiteName: "si-notch.remote-tests." + UUID().uuidString)!
        let controller = RemoteConnectionController(defaults: defaults, sshExecutable: fakeSSH,
                                                    retryDelays: [], socketAvailable: { _ in true })
        controller.host = "fixture"
        controller.remoteSocketPath = remote
        controller.connect(localSocketPath: "/Users/fixture/.si-notch/run/events.sock")
        XCTAssertEqual(controller.state, .connecting)
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while ProcessInfo.processInfo.systemUptime < deadline {
            if controller.state == .connected { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(controller.state, .connected)
        controller.disconnect()
        XCTAssertEqual(controller.state, .disconnected)
    }

    @MainActor
    func testNoConnectionStartsWithoutLocalSocket() {
        let defaults = UserDefaults(suiteName: "si-notch.remote-tests." + UUID().uuidString)!
        let controller = RemoteConnectionController(defaults: defaults, socketAvailable: { _ in false })
        controller.host = "fixture"
        controller.remoteSocketPath = "/home/fixture/.si-notch/run/events.sock"
        controller.connect(localSocketPath: "/Users/fixture/.si-notch/run/events.sock")
        XCTAssertEqual(controller.state, .failed(.localSocketUnavailable))
    }

    @MainActor
    func testAuthenticationAndHostKeyFailuresStopAutomaticRetries() async throws {
        for (diagnostic, failure) in [
            ("fixture: Permission denied (publickey).", RemoteConnectionFailure.authenticationFailed),
            ("Host key verification failed.", .hostKeyVerificationFailed),
            ("WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!", .hostKeyVerificationFailed)
        ] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: directory) }
            let ssh = directory.appendingPathComponent("ssh"), launches = directory.appendingPathComponent("launches")
            try "#!/bin/sh\necho attempt >> '\(launches.path)'\nprintf '%s\\n' '\(diagnostic)' >&2\nexit 255\n"
                .write(to: ssh, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ssh.path)
            let controller = RemoteConnectionController(defaults: nil, sshExecutable: ssh,
                retryDelays: [0.01], socketAvailable: { _ in true })
            defer { controller.disconnect() }
            controller.host = "fixture"
            controller.remoteSocketPath = "/home/test/e.sock"
            controller.connect(localSocketPath: "/Users/test/e.sock")
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            while ProcessInfo.processInfo.systemUptime < deadline, controller.state != .failed(failure) {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(controller.state, .failed(failure))
            try await Task.sleep(for: .milliseconds(80))
            XCTAssertEqual(try String(contentsOf: launches, encoding: .utf8).split(separator: "\n").count, 1)
        }
    }

    @MainActor
    func testRejectedForwardRecoversOnceAndReconnects() async throws {
        try await assertForwardRecovery(recoveryFails: false)
    }

    @MainActor
    func testSocketRecoveryRetriesAfterTransientSSHFailures() async throws {
        for failure in [RemoteSetupError.timedOut, .remote("ssh: connect to host fixture: Operation timed out")] {
            try await assertForwardRecovery(recoveryFails: false, transientRecoveryFailure: failure)
        }
    }

    @MainActor
    func testTunnelInputStaysOpenUntilDisconnect() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ssh = directory.appendingPathComponent("ssh"), closed = directory.appendingPathComponent("eof")
        try """
        #!/bin/sh
        trap '' TERM
        printf '%s\\n' 'debug1: remote forward success for: listen /home/test/e.sock:-2, connect /Users/test/e.sock:-2' >&2
        /bin/cat >/dev/null
        touch '\(closed.path)'
        """.write(to: ssh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ssh.path)
        let controller = RemoteConnectionController(defaults: nil, sshExecutable: ssh,
            retryDelays: [], socketAvailable: { _ in true })
        defer { controller.disconnect() }
        controller.host = "fixture"
        controller.remoteSocketPath = "/home/test/e.sock"
        controller.connect(localSocketPath: "/Users/test/e.sock")
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while ProcessInfo.processInfo.systemUptime < deadline, controller.state != .connected {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(controller.state, .connected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: closed.path))
        controller.disconnect()
        let closeDeadline = ProcessInfo.processInfo.systemUptime + 3
        while ProcessInfo.processInfo.systemUptime < closeDeadline, !FileManager.default.fileExists(atPath: closed.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: closed.path))
    }

    @MainActor
    func testUnsafeSocketStopsRecoveryWithoutFurtherRetries() async throws {
        try await assertForwardRecovery(recoveryFails: true)
    }

    @MainActor
    private func assertForwardRecovery(recoveryFails: Bool, transientRecoveryFailure: RemoteSetupError? = nil) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("recovered")
        let ssh = directory.appendingPathComponent("ssh")
        let remote = "/home/fixture/run/events.sock", local = "/Users/fixture/run/events.sock"
        try """
        #!/bin/sh
        if [ ! -f '\(marker.path)' ]; then
          printf '%s\\n' 'debug1: remote forward failure for: listen \(remote):-2, connect \(local):-2' >&2
          exit 255
        fi
        printf '%s\\n' 'debug1: remote forward success for: listen \(remote):-2, connect \(local):-2' >&2
        exec sleep 20
        """.write(to: ssh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ssh.path)
        var recoveries = 0
        let controller = RemoteConnectionController(defaults: nil, sshExecutable: ssh,
            retryDelays: [0.01], socketAvailable: { _ in true }, recoverSocket: { command, python in
                XCTAssertEqual(command.remoteSocketPath, remote)
                XCTAssertEqual(python, "/custom/python")
                recoveries += 1
                if recoveryFails { throw RemoteSetupError.invalidResponse }
                if recoveries == 1, let transientRecoveryFailure { throw transientRecoveryFailure }
                try Data().write(to: marker)
            })
        defer { controller.disconnect() }
        controller.host = "fixture"
        controller.remoteSocketPath = remote
        controller.pythonPath = "/custom/python"
        controller.connect(localSocketPath: local)
        let expected: RemoteConnectionState = recoveryFails ? .failed(.socketRecoveryFailed) : .connected
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while ProcessInfo.processInfo.systemUptime < deadline, controller.state != expected {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(controller.state, expected)
        let expectedRecoveries = transientRecoveryFailure == nil ? 1 : 2
        XCTAssertEqual(recoveries, expectedRecoveries)
        if !recoveryFails {
            controller.disconnect()
            try FileManager.default.removeItem(at: marker)
            controller.connect(localSocketPath: local)
            let secondDeadline = ProcessInfo.processInfo.systemUptime + 3
            while ProcessInfo.processInfo.systemUptime < secondDeadline, controller.state != .connected {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(controller.state, .connected)
            XCTAssertEqual(recoveries, expectedRecoveries + 1)
        }
    }

    func testPortableRemoteRelayDeliversObservationAndCorrelatedDecision() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let relay = repository.appendingPathComponent("scripts/remote-relay.py").path
        let fixture = #"""
import json, os, pathlib, socket, subprocess, sys, tempfile, threading
relay = sys.argv[1]
with tempfile.TemporaryDirectory(prefix="si-notch-remote-", dir="/private/tmp") as directory:
    os.chmod(directory, 0o700)
    endpoint = str(pathlib.Path(directory) / "events.sock")
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(endpoint)
    os.chmod(endpoint, 0o600)
    server.listen(3)
    received = []
    def serve():
        for index in range(3):
            connection, _ = server.accept()
            with connection:
                frame = bytearray()
                while b"\n" not in frame:
                    frame.extend(connection.recv(8192))
                event = json.loads(frame.split(b"\n", 1)[0])
                received.append(event)
                reply = {"ok": True, "disposition": "applied"}
                if event.get("await_response"):
                    reply = {"ok": True, "decision": "allow", "request_id": event["request_id"]}
                    if index == 2:
                        reply["request_id"] = "wrong-request"
                connection.sendall(json.dumps(reply).encode() + b"\n")
    worker = threading.Thread(target=serve, daemon=True)
    worker.start()
    env = dict(os.environ)
    env["SI_NOTCH_SOCKET"] = endpoint
    observer = subprocess.run([sys.executable, relay, "emit", json.dumps({"event":"agent.working", "session_id":"remote-test", "provider":"custom"})], env=env, capture_output=True, text=True, timeout=3)
    assert observer.returncode == 0 and not observer.stdout, observer
    decision = subprocess.run([sys.executable, relay, "request", json.dumps({"session_id":"remote-test", "provider":"custom", "request_id":"req-1"}), "--timeout", "1"], env=env, capture_output=True, text=True, timeout=3)
    assert decision.returncode == 0 and json.loads(decision.stdout)["request_id"] == "req-1", decision
    mismatch = subprocess.run([sys.executable, relay, "request", json.dumps({"session_id":"remote-test", "provider":"custom", "request_id":"req-2"}), "--timeout", "1"], env=env, capture_output=True, text=True, timeout=3)
    assert mismatch.returncode == 2 and not mismatch.stdout, mismatch
    worker.join(timeout=3)
    assert not worker.is_alive() and len(received) == 3, received
    assert received[0]["event"] == "agent.working"
    assert received[1]["event"] == "approval.request" and received[1]["await_response"] is True
    server.close()
"""#
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", fixture, relay]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let diagnostic = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, diagnostic)
    }
}
