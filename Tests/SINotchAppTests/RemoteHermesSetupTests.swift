import Foundation
import XCTest
@testable import SINotch

final class RemoteHermesSetupTests: XCTestCase {
    func testSSHCheckNeedsNoHermesInstallationAndReportsFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ssh = directory.appendingPathComponent("ssh")
        try "#!/bin/sh\nfor arg in \"$@\"; do last=\"$arg\"; done\nexec /bin/sh -c \"$last\"\n".write(to: ssh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ssh.path)
        var connection = RemoteSSHConnection(name: "fixture"); connection.host = "fixture"
        let client = RemoteHermesSetupClient(resources: nil, sshExecutable: ssh, timeout: 2)
        try await client.checkConnection(connection)
        try "#!/bin/sh\necho 'SSH fixture refused' >&2\nexit 255\n".write(to: ssh, atomically: true, encoding: .utf8)
        do { try await client.checkConnection(connection); XCTFail("Expected SSH failure") }
        catch { XCTAssertTrue(error.localizedDescription.contains("SSH fixture refused")) }
    }

    func testSSHSetupQuotesCodeAndPathsAndKeepsStrictAuthentication() throws {
        let source = "print('quoted'); # $HOME `touch /tmp/fixture`"
        let args = try RemoteHermesSetupClient.arguments(host: "user@host", pythonPath: "~/Hermes env/python", source: source)
        XCTAssertTrue(args.contains("BatchMode=yes"))
        XCTAssertTrue(args.contains("StrictHostKeyChecking=yes"))
        XCTAssertTrue(args.contains("ForwardAgent=no"))
        XCTAssertEqual(args[args.count - 2], "user@host")
        XCTAssertTrue(args.last!.hasPrefix("exec \"$HOME\"/'Hermes env/python' -c '"))
        XCTAssertTrue(args.last!.contains("'\\''"))
        for host in ["-bad", "host;other", "user@-host"] {
            XCTAssertThrowsError(try RemoteHermesSetupClient.arguments(host: host, pythonPath: "/python", source: source))
        }
        for path in ["python", "~/../python", "/python\nother"] {
            XCTAssertThrowsError(try RemoteHermesSetupClient.arguments(host: "fixture", pythonPath: path, source: source))
        }
    }

    func testInspectionParsesSnakeCaseIdentityWithoutSourcesOrConfiguration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "# setup fixture".write(to: directory.appendingPathComponent("remote-hermes-setup.py"), atomically: true, encoding: .utf8)
        let ssh = directory.appendingPathComponent("ssh")
        let script = """
        #!/usr/bin/python3
        import json,sys
        request=json.load(sys.stdin)
        assert request['op']=='inspect' and 'sources' not in request and 'profiles' not in request
        print(json.dumps({'ok':True,'data':{'snapshot':'abc','home':'/home/test','relay_path':'/relay','socket_path':'/sock','socket_ready':False,'profiles':[{'id':'default','home':'/home/test','display_name':'lain','enabled':True,'show_session_text':False,'plugin_installed':True,'connection_id':'hermes-instance-abc'}]}}))
        """
        try script.write(to: ssh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ssh.path)
        var connection = RemoteSSHConnection(name: "lain"); connection.host = "fixture"
        let client = RemoteHermesSetupClient(resources: directory, sshExecutable: ssh, timeout: 5)
        let snapshot = try await client.inspect(connection)
        XCTAssertEqual(snapshot.profiles.first?.connectionId, "hermes-instance-abc")
        XCTAssertEqual(snapshot.profiles.first?.displayName, "lain")
        XCTAssertFalse(snapshot.socketReady)
    }
}
