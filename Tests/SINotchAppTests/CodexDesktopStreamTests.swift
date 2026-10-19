import Darwin
import Foundation
import SINotchCore
import XCTest
@testable import SINotch

final class CodexDesktopStreamTests: XCTestCase {
    private final class DesktopSocket {
        let directory: URL
        let url: URL
        private let listener: Int32
        private let finished = DispatchSemaphore(value: 0)

        init() throws {
            directory = URL(fileURLWithPath: "/private/tmp/si-notch-desktop-\(UUID().uuidString)")
            url = directory.appendingPathComponent("ipc.sock")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                     attributes: [.posixPermissions: 0o700])
            listener = socket(AF_UNIX, SOCK_STREAM, 0)
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            let path = Array(url.path.utf8CString)
            withUnsafeMutableBytes(of: &address.sun_path) { bytes in
                for index in path.indices { bytes[index] = UInt8(bitPattern: path[index]) }
            }
            let length = socklen_t(address.sun_len)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, length) }
            }
            guard result == 0, listen(listener, 1) == 0, chmod(url.path, 0o600) == 0 else {
                close(listener)
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        }

        func serve(_ handler: @escaping (Int32) throws -> Void) {
            DispatchQueue.global(qos: .utility).async { [self] in
                let client = accept(listener, nil, nil)
                guard client >= 0 else { return }
                defer { close(client) }
                var timeout = timeval(tv_sec: 4, tv_usec: 0)
                setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
                var noSignal: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
                do {
                    try handler(client)
                    // A real Desktop keeps the stream open. Closing with
                    // unread follower frames can reset a Unix socket's tail.
                    _ = finished.wait(timeout: .now() + 6)
                } catch { XCTFail("Desktop socket: \(error)") }
            }
        }

        func finish() {
            finished.signal()
            shutdown(listener, SHUT_RDWR)
        }

        static func read(_ fd: Int32) throws -> [String: Any] {
            func bytes(_ count: Int) throws -> Data {
                var data = Data(count: count), offset = 0
                while offset < count {
                    let received = data.withUnsafeMutableBytes { recv(fd, $0.baseAddress!.advanced(by: offset), count - offset, 0) }
                    guard received > 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                    offset += received
                }
                return data
            }
            let header = try bytes(4)
            let size = header.enumerated().reduce(0) { $0 | Int($1.element) << ($1.offset * 8) }
            guard (1...65536).contains(size) else { throw NSError(domain: "Invalid frame", code: size) }
            return try XCTUnwrap(JSONSerialization.jsonObject(with: bytes(size)) as? [String: Any])
        }

        static func send(_ fd: Int32, _ object: [String: Any]) throws {
            let data = try JSONSerialization.data(withJSONObject: object)
            var size = UInt32(data.count).littleEndian
            var frame = withUnsafeBytes(of: &size) { Data($0) }
            frame.append(data)
            var offset = 0
            while offset < frame.count {
                let sent = frame.withUnsafeBytes { Darwin.send(fd, $0.baseAddress!.advanced(by: offset), frame.count - offset, 0) }
                guard sent > 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                offset += sent
            }
        }

        static func initialize(_ fd: Int32) throws {
            XCTAssertEqual(try read(fd)["method"] as? String, "initialize")
            try send(fd, ["type": "response", "method": "initialize", "resultType": "success",
                          "result": ["clientId": UUID().uuidString]])
        }

        static func snapshot(_ fd: Int32, id: String, status: String, revision: Int = 1) throws {
            try send(fd, ["type": "broadcast", "method": "thread-stream-state-changed", "version": 11,
                "params": ["conversationId": id, "hostId": "local", "change": ["type": "snapshot",
                    "revision": revision, "conversationState": ["id": id, "title": "Local integration test",
                        "threadRuntimeStatus": ["type": status == "inProgress" ? "active" : "idle"],
                        "turns": [["turnStartedAtMs": revision, "status": status, "items": []]]]]]])
        }

        deinit {
            shutdown(listener, SHUT_RDWR)
            close(listener)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func testAllParallelSessionsSubscribeBeyondEight() throws {
        let server = try DesktopSocket()
        defer { server.finish() }
        let ids = Set((0..<12).map { _ in UUID().uuidString })
        let received = expectation(description: "all Desktop sessions")
        received.expectedFulfillmentCount = ids.count
        server.serve { fd in
            try DesktopSocket.initialize(fd)
            var followed = Set<String>()
            while followed.count < ids.count {
                let frame = try DesktopSocket.read(fd)
                guard let params = frame["params"] as? [String: Any], params["hostId"] as? String == "local",
                      let id = params["conversationId"] as? String else { continue }
                XCTAssertTrue(ids.contains(id))
                if followed.insert(id).inserted { try DesktopSocket.snapshot(fd, id: id, status: "inProgress") }
            }
        }
        let queue = DispatchQueue(label: "si-notch.desktop-test")
        let stream = CodexDesktopStream(queue: queue, socketURL: server.url) { event, _ in
            XCTAssertTrue(ids.contains(event.sessionID)); XCTAssertEqual(event.kind, .working)
            received.fulfill()
        }
        queue.sync { stream.observe(Array(ids)) }
        wait(for: [received], timeout: 5)
        queue.sync { stream.stop() }
    }

    func testLocalDiscoveryWithoutLogDoesNotReplayCompletedHistory() throws {
        let server = try DesktopSocket(), id = UUID().uuidString
        defer { server.finish() }
        let received = expectation(description: "new local turn after discovery")
        server.serve { fd in
            try DesktopSocket.initialize(fd)
            for (host, version, value) in [("durable", 3, UUID().uuidString), ("local", 2, UUID().uuidString),
                                           ("local", 3, "invalid"), ("local", 3, id)] {
                try DesktopSocket.send(fd, ["type": "broadcast", "method": "thread-read-state-changed", "version": version,
                                           "params": ["conversationId": value, "hostId": host, "context": "PRIVATE"]])
            }
            let frame = try DesktopSocket.read(fd)
            XCTAssertEqual((frame["params"] as? [String: Any])?["conversationId"] as? String, id)
            try DesktopSocket.snapshot(fd, id: id, status: "completed")
            try DesktopSocket.snapshot(fd, id: id, status: "inProgress", revision: 2)
        }
        let queue = DispatchQueue(label: "si-notch.desktop-discovery-test")
        let stream = CodexDesktopStream(queue: queue, socketURL: server.url) { event, bootstrap in
            XCTAssertEqual(event.sessionID, id); XCTAssertEqual(event.kind, .working)
            XCTAssertFalse(bootstrap)
            received.fulfill()
        }
        queue.sync { stream.observe([]) }
        wait(for: [received], timeout: 5)
        queue.sync { stream.stop() }
    }
}
