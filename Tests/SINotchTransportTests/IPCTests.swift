import XCTest
import Foundation
import Darwin
@testable import SINotchTransport

final class IPCTests: XCTestCase {
    private var directory: String!
    private var socketPath: String { directory + "/events.sock" }
    private var servers = [IPCServer]()

    override func setUpWithError() throws {
        directory = "/private/tmp/sinotch-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
    }

    override func tearDownWithError() throws {
        servers.forEach { $0.stop() }
        servers.removeAll()
        try? FileManager.default.removeItem(atPath: directory)
    }

    private func server(clientTimeout: TimeInterval = 0.2, replyTimeout: TimeInterval = 0.5,
                        handler: @escaping IPCServer.MessageHandler) throws -> IPCServer {
        let server = IPCServer(socketPath: socketPath, clientTimeout: clientTimeout, replyTimeout: replyTimeout, onMessage: handler)
        try server.start()
        servers.append(server)
        return server
    }

    func testRoundTripCompactsJSONAndKeepsReply() throws {
        let received = expectation(description: "one event")
        _ = try server { data, reply in
            XCTAssertEqual(try? JSONSerialization.jsonObject(with: data) as? [String: String], ["event": "working"])
            reply(Data("{\"decision\":\"allow\",\"request_id\":\"a\"}".utf8))
            reply(Data("{\"decision\":\"deny\"}".utf8)) // First response wins.
            received.fulfill()
        }
        let response = try XCTUnwrap(IPCClient(socketPath: socketPath).send(Data("{\n  \"event\": \"working\"\n}".utf8), awaitReply: true))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [String: String])
        XCTAssertEqual(object["decision"], "allow")
        wait(for: [received], timeout: 1)
    }

    func testPeerExecutableComesFromTheLocalSocketRatherThanEventMetadata() throws {
        let received = expectation(description: "kernel peer identity")
        let endpoint = IPCServer(socketPath: socketPath, onPeerMessage: { _, executable, reply in
            XCTAssertNotNil(executable)
            XCTAssertEqual(executable.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() },
                           Bundle.main.executableURL?.resolvingSymlinksInPath())
            reply(Data("{\"ok\":true}".utf8))
            received.fulfill()
        })
        try endpoint.start()
        servers.append(endpoint)
        _ = try IPCClient(socketPath: socketPath).send(Data("{\"peer_executable\":\"/usr/bin/ssh\"}".utf8), awaitReply: true)
        wait(for: [received], timeout: 1)
    }

    func testOneHundredConcurrentObservationsReceiveTheirOwnAcknowledgements() throws {
        let lock = NSLock()
        var ids: Set<Int> = []
        let endpoint = IPCServer(socketPath: socketPath, maxConnections: 128) { data, reply in
            let id = (try? JSONSerialization.jsonObject(with: data) as? [String: Int])?["id"]
            if let id { lock.lock(); ids.insert(id); lock.unlock() }
            reply(data)
        }
        try endpoint.start()
        servers.append(endpoint)
        let path = socketPath
        DispatchQueue.concurrentPerform(iterations: 100) { index in
            do {
                let data = Data("{\"id\":\(index)}".utf8)
                let response = try IPCClient(socketPath: path).send(data, awaitReply: true, timeout: 5)
                XCTAssertEqual(response, data)
            } catch { XCTFail("Observation \(index) failed: \(error)") }
        }
        XCTAssertEqual(ids, Set(0..<100))
    }

    func testServerCreatesPrivateDirectoriesAndSocketAndStopRemovesSocket() throws {
        let nested = directory + "/one/two/events.sock"
        let server = IPCServer(socketPath: nested) { _, reply in reply(nil) }
        try server.start()
        servers.append(server)
        for path in [directory + "/one", directory + "/one/two"] {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: nested)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: nested))
        server.stop() // Idempotent.
    }

    func testCannotReplaceActiveServer() throws {
        let first = try server { _, reply in reply(Data("{\"ok\":true}".utf8)) }
        let second = IPCServer(socketPath: socketPath) { _, reply in reply(nil) }
        XCTAssertThrowsError(try second.start()) { error in
            guard case IPCError.alreadyRunning = error else { return XCTFail("Unexpected \(error)") }
        }
        second.stop()
        XCTAssertNotNil(try IPCClient(socketPath: socketPath).send(Data("{}".utf8), awaitReply: true))
        first.stop()
    }

    func testAbsentAppFailsPromptly() throws {
        let began = Date()
        XCTAssertThrowsError(try IPCClient(socketPath: socketPath).send(Data("{}".utf8), awaitReply: true, timeout: 0.1))
        XCTAssertLessThan(Date().timeIntervalSince(began), 0.5)
    }

    func testClientTimeoutWhileApprovalIsPending() throws {
        let received = expectation(description: "approval received")
        _ = try server { _, _ in received.fulfill() }
        let began = Date()
        XCTAssertThrowsError(try IPCClient(socketPath: socketPath).send(Data("{}".utf8), awaitReply: true, timeout: 0.1)) { error in
            guard case IPCError.timeout = error else { return XCTFail("Unexpected \(error)") }
        }
        XCTAssertLessThan(Date().timeIntervalSince(began), 0.5)
        wait(for: [received], timeout: 1)
    }

    func testClientRefusesPublicParentDirectory() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory)
        let candidate = IPCServer(socketPath: socketPath) { _, reply in reply(nil) }
        XCTAssertThrowsError(try candidate.start()) { error in
            guard case IPCError.unsafePath = error else { return XCTFail("Unexpected \(error)") }
        }
    }

    func testRefusesSymlinkParentAndSocketWithoutDeletingTargets() throws {
        let target = directory + "/target"
        try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let link = directory + "/link"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        let candidate = IPCServer(socketPath: link + "/events.sock") { _, reply in reply(nil) }
        XCTAssertThrowsError(try candidate.start())
        let file = directory + "/preserve.txt"
        try Data("preserve".utf8).write(to: URL(fileURLWithPath: file))
        try FileManager.default.createSymbolicLink(atPath: socketPath, withDestinationPath: file)
        let endpoint = IPCServer(socketPath: socketPath) { _, reply in reply(nil) }
        XCTAssertThrowsError(try endpoint.start())
        XCTAssertThrowsError(try IPCClient(socketPath: socketPath).send(Data("{}".utf8)))
        XCTAssertEqual(try String(contentsOfFile: file, encoding: .utf8), "preserve")
    }

    func testClientRefusesSocketWithLoosePermissions() throws {
        _ = try server { _, reply in reply(nil) }
        XCTAssertEqual(chmod(socketPath, 0o666), 0)
        XCTAssertThrowsError(try IPCClient(socketPath: socketPath).send(Data("{}".utf8))) { error in
            guard case IPCError.unsafePath = error else { return XCTFail("Unexpected \(error)") }
        }
    }

    func testClientRejectsOversizedOrInvalidJSONBeforeConnecting() throws {
        let client = IPCClient(socketPath: socketPath)
        XCTAssertThrowsError(try client.send(Data(repeating: 0x61, count: IPCPaths.maximumMessageBytes + 1))) { error in
            guard case IPCError.messageTooLarge = error else { return XCTFail("Unexpected \(error)") }
        }
        for value in ["[1,2]", "null", "{}\n{}", "not-json"] {
            XCTAssertThrowsError(try client.send(Data(value.utf8))) { error in
                guard case IPCError.invalidMessage = error else { return XCTFail("Unexpected \(error)") }
            }
        }
    }

    func testMalformedFramesNeverReachHandler() throws {
        let unexpected = expectation(description: "malformed frame forwarded")
        unexpected.isInverted = true
        _ = try server { _, reply in unexpected.fulfill(); reply(nil) }
        for frame in [Data("not-json\n".utf8), Data("{}\n{}\n".utf8), Data("[1]\n".utf8),
                      Data(repeating: 0x61, count: IPCPaths.maximumMessageBytes + 1)] {
            let descriptor = try connectRaw()
            _ = frame.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress, $0.count, 0) }
            shutdown(descriptor, SHUT_WR)
            Darwin.close(descriptor)
        }
        wait(for: [unexpected], timeout: 0.4)
    }

    func testIncompleteFrameTimesOutAndNextClientStillWorks() throws {
        let received = expectation(description: "valid event")
        _ = try server(clientTimeout: 0.1) { _, reply in received.fulfill(); reply(Data("{\"ok\":true}".utf8)) }
        let descriptor = try connectRaw()
        let unfinished = Data("{\"event\":".utf8)
        _ = unfinished.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress, $0.count, 0) }
        usleep(180_000)
        var buffer = [UInt8](repeating: 0, count: 16)
        XCTAssertEqual(Darwin.recv(descriptor, &buffer, buffer.count, 0), 0)
        Darwin.close(descriptor)
        XCTAssertNotNil(try IPCClient(socketPath: socketPath).send(Data("{}".utf8), awaitReply: true))
        wait(for: [received], timeout: 1)
    }

    func testStopDoesNotDeleteReplacedPath() throws {
        let running = try server { _, reply in reply(nil) }
        XCTAssertEqual(unlink(socketPath), 0)
        try Data("user-file".utf8).write(to: URL(fileURLWithPath: socketPath))
        running.stop()
        XCTAssertEqual(try String(contentsOfFile: socketPath, encoding: .utf8), "user-file")
    }

    func testConnectionLimitRejectsAdditionalPendingClient() throws {
        let firstReceived = expectation(description: "first pending client")
        firstReceived.assertForOverFulfill = true
        let limited = IPCServer(socketPath: socketPath, maxConnections: 1, clientTimeout: 0.2, replyTimeout: 1) { _, _ in
            firstReceived.fulfill()
        }
        try limited.start()
        servers.append(limited)
        let pending = try connectRaw()
        defer { Darwin.close(pending) }
        let frame = Data("{}\n".utf8)
        XCTAssertEqual(frame.withUnsafeBytes { Darwin.send(pending, $0.baseAddress, $0.count, 0) }, frame.count)
        wait(for: [firstReceived], timeout: 1)
        XCTAssertThrowsError(try IPCClient(socketPath: socketPath).send(Data("{}".utf8), awaitReply: true, timeout: 0.2))
    }

    func testFireAndForgetFrameIsDeliveredAfterClientCloses() throws {
        let received = (0..<16).map { expectation(description: "closed client's frame \($0)") }
        received.forEach { $0.assertForOverFulfill = true }
        _ = try server { data, _ in
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["event"] as? String == "closed", let index = object["index"] as? Int,
                  received.indices.contains(index) else { return XCTFail("Unexpected frame: \(data)") }
            received[index].fulfill()
        }
        for index in received.indices {
            try IPCClient(socketPath: socketPath).send(Data("{\"event\":\"closed\",\"index\":\(index)}".utf8))
            wait(for: [received[index]], timeout: 1)
        }
    }

    func testRestartReleasesPreviousGenerationApprovalWait() throws {
        let firstReceived = expectation(description: "first pending client")
        let stateLock = NSLock()
        var count = 0
        let restartable = IPCServer(socketPath: socketPath, maxConnections: 1, clientTimeout: 0.2, replyTimeout: 3) { _, reply in
            stateLock.lock(); count += 1; let current = count; stateLock.unlock()
            if current == 1 { firstReceived.fulfill() }
            else { reply(Data("{\"ok\":true}".utf8)) }
        }
        try restartable.start()
        servers.append(restartable)
        let pending = try connectRaw()
        defer { Darwin.close(pending) }
        let frame = Data("{}\n".utf8)
        XCTAssertEqual(frame.withUnsafeBytes { Darwin.send(pending, $0.baseAddress, $0.count, 0) }, frame.count)
        wait(for: [firstReceived], timeout: 1)
        restartable.stop()
        try restartable.start()
        XCTAssertNotNil(try IPCClient(socketPath: socketPath).send(Data("{}".utf8), awaitReply: true, timeout: 0.5))
    }

    private func connectRaw() throws -> Int32 {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw IPCError.systemCall("socket", errno) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(socketPath.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { Darwin.close(descriptor); throw IPCError.systemCall("connect", errno) }
        var enabled: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled)))
        return descriptor
    }
}
