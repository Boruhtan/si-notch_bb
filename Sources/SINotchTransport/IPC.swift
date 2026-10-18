import Foundation
import Darwin

public enum IPCPaths {
    public static var defaultSocketPath: String {
        if let path = ProcessInfo.processInfo.environment["SI_NOTCH_SOCKET"], !path.isEmpty { return path }
        return NSHomeDirectory() + "/.si-notch/run/events.sock"
    }
    public static let maximumMessageBytes = 128 * 1024
}

public enum IPCError: Error, LocalizedError {
    case invalidPath(String)
    case unsafePath(String)
    case systemCall(String, Int32)
    case alreadyRunning
    case messageTooLarge
    case invalidMessage
    case timeout
    case disconnected

    public var errorDescription: String? {
        switch self {
        case .invalidPath(let path): return "Invalid Unix socket path: \(path)"
        case .unsafePath(let reason): return "Unsafe Unix socket location: \(reason)"
        case .systemCall(let operation, let code): return "\(operation): \(String(cString: strerror(code)))"
        case .alreadyRunning: return "si-notch is already listening on this socket."
        case .messageTooLarge: return "IPC message exceeds 128 KiB."
        case .invalidMessage: return "Expected one JSON object, terminated by one newline."
        case .timeout: return "Timed out waiting for si-notch."
        case .disconnected: return "si-notch closed the connection."
        }
    }
}

/// One JSON object per connection. There are no network listeners or shell commands.
public final class IPCServer {
    public typealias MessageHandler = (Data, @escaping (Data?) -> Void) -> Void
    public let socketPath: String
    private let handler: MessageHandler
    private let maximumConnections: Int
    private let clientTimeout: TimeInterval
    private let replyTimeout: TimeInterval
    private let lock = NSLock()
    private let acceptQueue = DispatchQueue(label: "si-notch.ipc.accept")
    private let clients = DispatchQueue(label: "si-notch.ipc.clients", attributes: .concurrent)
    private var descriptor: Int32 = -1
    private var socketIdentity: (dev_t, ino_t)?
    private var generation: UInt64 = 0
    private var activeClients = [Int32: UInt64]()

    public init(socketPath: String = IPCPaths.defaultSocketPath, maxConnections: Int = 16,
                clientTimeout: TimeInterval = 2, replyTimeout: TimeInterval = 125,
                onMessage: @escaping MessageHandler) {
        self.socketPath = socketPath
        self.maximumConnections = max(1, maxConnections)
        self.clientTimeout = max(0.05, clientTimeout)
        self.replyTimeout = max(0.05, replyTimeout)
        self.handler = onMessage
    }

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard descriptor < 0 else { throw IPCError.alreadyRunning }
        try SocketSecurity.prepareParent(for: socketPath)
        var address = try SocketIO.address(for: socketPath)
        try SocketSecurity.removeStaleSocket(at: socketPath)
        let listener = try SocketIO.makeSocket()
        var bound = false
        do {
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0 else { throw IPCError.systemCall("bind", errno) }
            bound = true
            guard chmod(socketPath, 0o600) == 0 else { throw IPCError.systemCall("chmod socket", errno) }
            guard Darwin.listen(listener, Int32(maximumConnections)) == 0 else {
                throw IPCError.systemCall("listen", errno)
            }
            var info = stat()
            guard lstat(socketPath, &info) == 0 else { throw IPCError.systemCall("stat socket", errno) }
            descriptor = listener
            socketIdentity = (info.st_dev, info.st_ino)
            generation &+= 1
            let token = generation
            acceptQueue.async { [weak self] in self?.acceptLoop(listener, generation: token) }
        } catch {
            Darwin.close(listener)
            if bound { unlink(socketPath) }
            throw error
        }
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        let listener = descriptor
        descriptor = -1
        generation &+= 1
        let connected = Array(activeClients.keys)
        let identity = socketIdentity
        socketIdentity = nil
        if listener >= 0 { shutdown(listener, SHUT_RDWR); Darwin.close(listener) }
        // The worker owns close(); shutdown safely interrupts reads without descriptor reuse.
        // Hold the lock until shutdown completes so a worker cannot close/reuse an fd here.
        for client in connected { shutdown(client, SHUT_RDWR) }
        if let identity {
            var info = stat()
            if lstat(socketPath, &info) == 0, info.st_dev == identity.0, info.st_ino == identity.1 {
                unlink(socketPath)
            }
        }
    }

    deinit { stop() }

    private func acceptLoop(_ listener: Int32, generation token: UInt64) {
        while isRunning(token) {
            var item = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            let result = Darwin.poll(&item, 1, 100)
            if result < 0 { if errno == EINTR { continue }; break }
            guard result > 0, item.revents & Int16(POLLIN) != 0 else { continue }
            // The listener is nonblocking. Keep stop()/start() from closing and
            // reusing its descriptor between the generation check and accept().
            lock.lock()
            guard descriptor == listener, generation == token else { lock.unlock(); continue }
            let client = Darwin.accept(listener, nil, nil)
            lock.unlock()
            guard client >= 0 else { continue }
            do { try SocketIO.configure(client); try SocketSecurity.checkPeer(client) }
            catch { Darwin.close(client); continue }
            lock.lock()
            let currentClients = activeClients.values.reduce(0) { $0 + ($1 == token ? 1 : 0) }
            let allowed = descriptor == listener && generation == token && currentClients < maximumConnections
            if allowed { activeClients[client] = token }
            lock.unlock()
            guard allowed else { Darwin.close(client); continue }
            clients.async { [weak self] in
                guard let self else { Darwin.close(client); return }
                defer {
                    self.lock.lock()
                    self.activeClients.removeValue(forKey: client)
                    // Keep descriptor removal and close atomic with respect to stop().
                    Darwin.close(client)
                    self.lock.unlock()
                }
                self.serve(client, generation: token)
            }
        }
    }

    private func isRunning(_ token: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return descriptor >= 0 && generation == token
    }

    private func serve(_ client: Int32, generation token: UInt64) {
        do {
            let message = try SocketIO.readFrame(client, timeout: clientTimeout)
            let reply = PendingReply()
            handler(message) { reply.finish($0) }
            // Polling permits stop() to cancel approval waits promptly.
            let deadline = ProcessInfo.processInfo.systemUptime + replyTimeout
            while reply.ready.wait(timeout: .now() + 0.1) == .timedOut {
                guard isRunning(token), ProcessInfo.processInfo.systemUptime < deadline else { return }
            }
            if let response = reply.value {
                try SocketIO.writeFrame(client, data: response, timeout: clientTimeout)
            }
        } catch {
            // Invalid/oversized/unfinished frames are dropped before reaching the app.
        }
    }
}

public struct IPCClient {
    public let socketPath: String
    public init(socketPath: String = IPCPaths.defaultSocketPath) { self.socketPath = socketPath }

    @discardableResult
    public func send(_ data: Data, awaitReply: Bool = false, timeout: TimeInterval = 2) throws -> Data? {
        let compact = try SocketIO.compact(data)
        try SocketSecurity.validateParent(for: socketPath)
        try SocketSecurity.validateSocket(at: socketPath)
        let connection = try SocketIO.makeSocket()
        defer { Darwin.close(connection) }
        try SocketIO.connect(connection, path: socketPath, timeout: timeout)
        try SocketSecurity.checkPeer(connection)
        try SocketIO.writeFrame(connection, data: compact, timeout: timeout)
        shutdown(connection, SHUT_WR)
        return awaitReply ? try SocketIO.readFrame(connection, timeout: timeout) : nil
    }
}

private final class PendingReply {
    let ready = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var finished = false
    private var data: Data?
    var value: Data? { lock.lock(); defer { lock.unlock() }; return data }
    func finish(_ value: Data?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        data = value
        lock.unlock()
        ready.signal()
    }
}

private enum SocketSecurity {
    static func prepareParent(for path: String) throws {
        let parent = try parentPath(path)
        var current = ""
        for component in parent.split(separator: "/") {
            current += "/" + component
            var info = stat()
            if lstat(current, &info) != 0 {
                guard errno == ENOENT else { throw IPCError.systemCall("stat directory", errno) }
                guard mkdir(current, 0o700) == 0 else { throw IPCError.systemCall("mkdir", errno) }
                guard lstat(current, &info) == 0 else { throw IPCError.systemCall("stat directory", errno) }
            }
            try checkDirectory(info, path: current, isParent: current == parent)
        }
    }

    static func validateParent(for path: String) throws {
        let parent = try parentPath(path)
        var current = ""
        for component in parent.split(separator: "/") {
            current += "/" + component
            var info = stat()
            guard lstat(current, &info) == 0 else { throw IPCError.systemCall("stat directory", errno) }
            try checkDirectory(info, path: current, isParent: current == parent)
        }
    }

    private static func parentPath(_ path: String) throws -> String {
        guard path.hasPrefix("/"), !path.contains("\0"), !path.hasSuffix("/"),
              !path.split(separator: "/").contains(".."), !path.split(separator: "/").contains(".") else {
            throw IPCError.invalidPath(path)
        }
        _ = try SocketIO.address(for: path)
        let parent = (path as NSString).deletingLastPathComponent
        guard parent != "/" else { throw IPCError.unsafePath("socket requires a private parent directory") }
        return parent
    }

    private static func checkDirectory(_ info: stat, path: String, isParent: Bool) throws {
        guard info.st_mode & S_IFMT == S_IFDIR else {
            throw IPCError.unsafePath("\(path) is not a directory (symlinks are refused)")
        }
        // Root-owned ancestors such as /Users are trusted; the endpoint directory must be private.
        guard info.st_uid == geteuid() || (!isParent && info.st_uid == 0) else {
            throw IPCError.unsafePath("\(path) has a different owner")
        }
        if isParent && info.st_mode & 0o077 != 0 {
            throw IPCError.unsafePath("\(path) must have mode 0700")
        }
        if !isParent && info.st_mode & 0o022 != 0 && info.st_mode & S_ISVTX == 0 {
            throw IPCError.unsafePath("\(path) is writable by other users")
        }
    }

    static func validateSocket(at path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else { throw IPCError.systemCall("stat socket", errno) }
        guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else {
            throw IPCError.unsafePath("socket must be owned by this user with mode 0600; symlinks are refused")
        }
    }

    static func removeStaleSocket(at path: String) throws {
        var info = stat()
        if lstat(path, &info) != 0 {
            guard errno == ENOENT else { throw IPCError.systemCall("stat socket", errno) }
            return
        }
        try validateSocket(at: path)
        let probe = try SocketIO.makeSocket()
        defer { Darwin.close(probe) }
        do {
            try SocketIO.connect(probe, path: path, timeout: 0.2)
            throw IPCError.alreadyRunning
        } catch IPCError.systemCall(_, let code) where code == ECONNREFUSED || code == ENOENT {
            guard unlink(path) == 0 || errno == ENOENT else { throw IPCError.systemCall("unlink stale socket", errno) }
        }
    }

    static func checkPeer(_ descriptor: Int32) throws {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(descriptor, &uid, &gid) == 0 else { throw IPCError.systemCall("getpeereid", errno) }
        guard uid == geteuid() else { throw IPCError.unsafePath("peer belongs to another user") }
    }
}

private enum SocketIO {
    static func address(for path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        guard !bytes.contains(0), bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw IPCError.invalidPath(path)
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { target in
            target.initializeMemory(as: UInt8.self, repeating: 0)
            target.copyBytes(from: bytes)
        }
        return address
    }

    static func makeSocket() throws -> Int32 {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw IPCError.systemCall("socket", errno) }
        do { try configure(descriptor) } catch { Darwin.close(descriptor); throw error }
        return descriptor
    }

    static func configure(_ descriptor: Int32) throws {
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0,
              fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else { throw IPCError.systemCall("fcntl", errno) }
    }

    static func connect(_ descriptor: Int32, path: String, timeout: TimeInterval) throws {
        var address = try address(for: path)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result == 0 { return }
        guard errno == EINPROGRESS || errno == EAGAIN else { throw IPCError.systemCall("connect", errno) }
        try wait(descriptor, events: Int16(POLLOUT), deadline: ProcessInfo.processInfo.systemUptime + max(0.01, timeout))
        var code: Int32 = 0
        var size = socklen_t(MemoryLayout.size(ofValue: code))
        guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &code, &size) == 0 else { throw IPCError.systemCall("getsockopt", errno) }
        guard code == 0 else { throw IPCError.systemCall("connect", code) }
    }

    static func compact(_ data: Data) throws -> Data {
        guard data.count <= IPCPaths.maximumMessageBytes else { throw IPCError.messageTooLarge }
        guard let object = try? JSONSerialization.jsonObject(with: data), object is [String: Any],
              let compact = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            throw IPCError.invalidMessage
        }
        guard compact.count <= IPCPaths.maximumMessageBytes else { throw IPCError.messageTooLarge }
        return compact
    }

    static func writeFrame(_ descriptor: Int32, data: Data, timeout: TimeInterval) throws {
        var frame = try compact(data)
        frame.append(0x0a)
        let deadline = ProcessInfo.processInfo.systemUptime + max(0.01, timeout)
        try frame.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                try wait(descriptor, events: Int16(POLLOUT), deadline: deadline)
                // An accepted socket can already have a closed peer. Suppress
                // SIGPIPE on each send instead of configuring SO_NOSIGPIPE there;
                // that setsockopt can fail with EINVAL after an immediate close.
                let count = Darwin.send(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, MSG_NOSIGNAL)
                if count < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    throw IPCError.systemCall("send", errno)
                }
                guard count > 0 else { throw IPCError.disconnected }
                offset += count
            }
        }
    }

    static func readFrame(_ descriptor: Int32, timeout: TimeInterval) throws -> Data {
        let deadline = ProcessInfo.processInfo.systemUptime + max(0.01, timeout)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            try wait(descriptor, events: Int16(POLLIN), deadline: deadline)
            let count = Darwin.recv(descriptor, &buffer, buffer.count, 0)
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw IPCError.systemCall("recv", errno)
            }
            guard count > 0 else { throw IPCError.disconnected }
            data.append(contentsOf: buffer.prefix(count))
            if let end = data.firstIndex(of: 0x0a) {
                guard end <= IPCPaths.maximumMessageBytes else { throw IPCError.messageTooLarge }
                guard end == data.index(before: data.endIndex) else { throw IPCError.invalidMessage }
                return try compact(Data(data[..<end]))
            }
            guard data.count <= IPCPaths.maximumMessageBytes else { throw IPCError.messageTooLarge }
        }
    }

    private static func wait(_ descriptor: Int32, events: Int16, deadline: TimeInterval) throws {
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw IPCError.timeout }
            var item = pollfd(fd: descriptor, events: events, revents: 0)
            let result = Darwin.poll(&item, 1, Int32(min(remaining * 1000 + 1, Double(Int32.max))))
            if result < 0 { if errno == EINTR { continue }; throw IPCError.systemCall("poll", errno) }
            guard result > 0 else { throw IPCError.timeout }
            if item.revents & events != 0 { return }
            // A client can write a complete frame and close before this poll.
            // A hangup still permits recv() to drain bytes already in the socket.
            if events == Int16(POLLIN), item.revents & Int16(POLLHUP) != 0 { return }
            if item.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { throw IPCError.disconnected }
        }
    }
}
