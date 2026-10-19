import Darwin
import Foundation
import Network
import SINotchCore

/// Read-only follower of the user's local Desktop IPC socket. It never starts
/// a router, resumes a thread, sends a prompt, or answers an approval request.
final class CodexDesktopStream {
    private let queue: DispatchQueue
    private let socketURL: URL
    private let onEvent: (AgentEvent, Bool) -> Void
    private var connection: NWConnection?
    private var clientID: String?
    private var pending = Data()
    private var tracked: [String: Date] = [:]
    private var taskSessions: Set<String> = []
    private var feed = CodexDesktopFeed()
    private var subscribed: Set<String> = []
    private var resnapshotAt: [String: Date] = [:]
    private var retryAfter = Date.distantPast
    private var connectingAt: Date?
    private let maximumFrame = 32 * 1024 * 1024

    init(queue: DispatchQueue, socketURL: URL = FileManager.default.homeDirectoryForCurrentUser
         .appendingPathComponent(".codex/ipc/ipc.sock"), onEvent: @escaping (AgentEvent, Bool) -> Void) {
        self.queue = queue
        self.socketURL = socketURL
        self.onEvent = onEvent
    }

    func observe(_ ids: [String], now: Date = Date()) {
        track(ids, activity: true, now: now)
        for (id, seen) in tracked where now.timeIntervalSince(seen) > 3600 {
            follow(id, following: false); tracked[id] = nil; taskSessions.remove(id)
            feed.remove(id); subscribed.remove(id); resnapshotAt[id] = nil
        }
        if let connectingAt, now.timeIntervalSince(connectingAt) > 10, clientID == nil { disconnect() }
        // Connect before the first log/rollout signal so native local discovery
        // can subscribe before a short turn (or a turn without reasoning) ends.
        if connection == nil, now >= retryAfter { connect() }
        subscribe(now: now)
    }

    private func track(_ ids: [String], activity: Bool, now: Date) {
        for id in ids where UUID(uuidString: id) != nil {
            tracked[id] = now
            if activity { taskSessions.insert(id) }
        }
    }

    private func subscribe(now: Date = Date()) {
        guard clientID != nil else { return }
        for id in tracked.keys where !subscribed.contains(id) ||
            (!feed.hasSnapshot(id) && now.timeIntervalSince(resnapshotAt[id] ?? .distantPast) >= 5) {
            follow(id, following: true)
            subscribed.insert(id)
            resnapshotAt[id] = now
        }
    }

    func contains(_ id: String) -> Bool { connection != nil && feed.isFresh(id) }

    func stop() {
        for id in subscribed { follow(id, following: false) }
        disconnect()
        tracked.removeAll(); taskSessions.removeAll()
    }

    private func connect() {
        // Never follow symlinks or connect outside the current user's private IPC directory.
        var directory = stat(), socketInfo = stat()
        guard lstat(socketURL.deletingLastPathComponent().path, &directory) == 0,
              directory.st_mode & S_IFMT == S_IFDIR, directory.st_uid == getuid(), directory.st_mode & 0o077 == 0,
              lstat(socketURL.path, &socketInfo) == 0, socketInfo.st_mode & S_IFMT == S_IFSOCK,
              socketInfo.st_uid == getuid(), socketInfo.st_mode & 0o077 == 0 else {
            retryAfter = Date().addingTimeInterval(15); return
        }
        let socket = NWConnection(to: .unix(path: socketURL.path), using: .tcp)
        connection = socket
        connectingAt = Date()
        socket.stateUpdateHandler = { [weak self, weak socket] state in
            guard let self, let socket, self.connection === socket else { return }
            switch state {
            case .ready:
                self.send(["type": "request", "requestId": UUID().uuidString, "sourceClientId": "si-notch",
                           "version": 0, "method": "initialize", "params": ["clientType": "si-notch"], "timeoutMs": 3000])
                self.read(socket)
            case .failed, .cancelled: self.disconnect()
            default: break
            }
        }
        socket.start(queue: queue)
    }

    private func read(_ socket: NWConnection) {
        socket.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self, weak socket] data, _, ended, error in
            guard let self, let socket, self.connection === socket else { return }
            if let data {
                self.pending.append(data)
                guard self.consumeFrames() else { self.disconnect(); return }
            }
            if ended || error != nil { self.disconnect() } else { self.read(socket) }
        }
    }

    private func consumeFrames() -> Bool {
        while pending.count >= 4 {
            let size = pending.prefix(4).enumerated().reduce(0) { $0 | Int($1.element) << ($1.offset * 8) }
            guard size > 0, size <= maximumFrame else { return false }
            guard pending.count >= size + 4 else { return true }
            let bytes = Data(pending.dropFirst(4).prefix(size))
            pending.removeFirst(size + 4)
            guard let frame = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return false }
            handle(frame)
        }
        return true
    }

    private func handle(_ frame: [String: Any]) {
        if frame["type"] as? String == "response", frame["method"] as? String == "initialize",
           frame["resultType"] as? String == "success",
           let id = (frame["result"] as? [String: Any])?["clientId"] as? String, UUID(uuidString: id) != nil {
            clientID = id; connectingAt = nil
            subscribe()
            return
        }
        if frame["type"] as? String == "client-discovery-request", let requestID = frame["requestId"] as? String {
            send(["type": "client-discovery-response", "requestId": requestID, "response": ["canHandle": false]])
            return
        }
        guard frame["type"] as? String == "broadcast" else { return }
        if let targets = frame["targetClientIds"] as? [String], let clientID, !targets.contains(clientID) { return }
        if frame["method"] as? String == "thread-read-state-changed", frame["version"] as? Int == 3,
           let params = frame["params"] as? [String: Any], params["hostId"] as? String == "local",
           let id = params["conversationId"] as? String, UUID(uuidString: id) != nil {
            // Read-state events identify a local thread but do not establish
            // that it is running. Ignore all context and request its snapshot.
            track([id], activity: false, now: Date())
            subscribe()
            return
        }
        guard frame["method"] as? String == "thread-stream-state-changed",
              frame["version"] as? Int == 11, let params = frame["params"] as? [String: Any],
              let id = params["conversationId"] as? String, subscribed.contains(id),
              let host = params["hostId"] as? String, ["local", "durable"].contains(host),
              let change = params["change"] as? [String: Any] else { return }
        let update = feed.consume(id: id, host: host, change: change)
        if update.needsSnapshot {
            if Date().timeIntervalSince(resnapshotAt[id] ?? .distantPast) >= 5 {
                resnapshotAt[id] = Date()
                follow(id, following: true) // Request a fresh snapshot after a lost revision.
            }
            return
        }
        if let event = update.event {
            if event.kind == .working || event.kind == .waiting {
                tracked[id] = Date()
                taskSessions.insert(id)
            }
            // Opening old history is discovery, not a newly completed task.
            guard taskSessions.contains(id) else { return }
            onEvent(event, update.bootstrap)
        }
    }

    private func follow(_ id: String, following: Bool) {
        guard let clientID else { return }
        for host in ["local", "durable"] {
            send(["type": "broadcast", "sourceClientId": clientID, "version": 1,
                  "method": "thread-stream-following-changed",
                  "params": ["conversationId": id, "hostId": host, "following": following]])
        }
    }

    private func send(_ object: [String: Any]) {
        guard let connection, let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        var size = UInt32(data.count).littleEndian
        var frame = withUnsafeBytes(of: &size) { Data($0) }
        frame.append(data)
        connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    private func disconnect() {
        let old = connection
        connection = nil; clientID = nil; connectingAt = nil
        old?.cancel()
        pending.removeAll(); subscribed.removeAll(); feed = CodexDesktopFeed(); resnapshotAt.removeAll()
        retryAfter = Date().addingTimeInterval(5)
    }
}

/// Stream freshness is independent of socket connectivity. A connected but stale
/// stream must not suppress current lifecycle events from the Desktop log.
struct CodexDesktopFeed {
    private struct Entry {
        var state: CodexDesktopState
        var host: String
        var updatedAt: Date
        var emittedAt: Date
        var fingerprint: AgentEvent
    }
    private var entries: [String: Entry] = [:]

    func hasSnapshot(_ id: String) -> Bool { entries[id] != nil }

    func isFresh(_ id: String, now: Date = Date()) -> Bool {
        guard let entry = entries[id] else { return false }
        return (0...15).contains(now.timeIntervalSince(entry.updatedAt))
    }

    mutating func remove(_ id: String) { entries[id] = nil }

    mutating func consume(id: String, host: String, change: [String: Any], now: Date = Date())
        -> (event: AgentEvent?, bootstrap: Bool, needsSnapshot: Bool) {
        let previous = entries[id]
        // Local and cloud hosts have separate revision histories. Never apply
        // one host's delta to the other host's snapshot.
        if let previous, previous.host != host, isFresh(id, now: now) { return (nil, false, false) }
        var state = previous?.host == host ? previous!.state : CodexDesktopState()
        guard state.apply(change), var event = state.event(sessionID: id, now: now) else {
            if previous?.host == host { entries[id] = nil }
            return (nil, false, true)
        }
        var fingerprint = event
        fingerprint.id = nil; fingerprint.timestamp = .distantPast
        let heartbeat = previous.map { now.timeIntervalSince($0.emittedAt) >= 30 } ?? true
        let emit = previous?.fingerprint != fingerprint || heartbeat
        if heartbeat { event.id = "desktop-stream:\(id):heartbeat:\(Int(now.timeIntervalSince1970))" }
        entries[id] = Entry(state: state, host: host, updatedAt: now,
                            emittedAt: emit ? now : previous!.emittedAt, fingerprint: fingerprint)
        return (emit ? event : nil, previous == nil, false)
    }
}
