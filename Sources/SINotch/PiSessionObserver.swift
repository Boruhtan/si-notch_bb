import Darwin
import Foundation
import SINotchCore

/// The source is explicit so file-derived snapshots can never be mistaken for
/// the authoritative Pi extension hook.
struct PiSessionObservation {
    enum Source { case sessionFile }
    let event: AgentEvent
    let isBootstrap: Bool
    let source: Source = .sessionFile
}

/// Bounded, read-only scan of Pi's JSONL sessions. Optional message snippets
/// exclude reasoning, tool arguments and command output.
struct PiSessionScanner {
    private enum Activity: Equatable { case idle, working, completed }

    private struct Candidate {
        let url: URL
        let inode: UInt64
        let size: UInt64
        let modified: Date
    }

    private struct FileState {
        let inode: UInt64
        let sessionID: String
        let cwd: String?
        var offset: UInt64
        var partial = Data()
        var discardingLongLine = false
        var ordinal = 0
        var activity = Activity.idle
        var activityAt: Date
        var lastEventAt: Date
        var lastRecordID: String?
        var prompt: String?
        var message: String?
        var tool: String?
        var model: String?
        var effort: String?
        var visible = false
        var idleAfterSilence = false
    }

    let sessionsRoot: URL
    let includeContent: Bool
    var silenceInterval: TimeInterval = 3 * 60
    private var files: [String: FileState] = [:]

    private let maximumDirectories = 512
    private let maximumCandidates = 16
    private let maximumHeaderBytes = 16 * 1024
    private let maximumLineBytes = 256 * 1024
    private let maximumTailBytes = 1024 * 1024
    private let maximumIncrementBytes = 512 * 1024
    private let recentFileAge: TimeInterval = 10 * 60
    private let freshRecordAge: TimeInterval = 30

    init(sessionsRoot: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".pi/agent/sessions", isDirectory: true), includeContent: Bool = false) {
        self.sessionsRoot = sessionsRoot.standardizedFileURL
        self.includeContent = includeContent
    }

    mutating func poll(now: Date = Date(), suppressedSessionIDs: Set<String> = []) -> [PiSessionObservation] {
        var observations: [PiSessionObservation] = []
        let selected = candidates(now: now)
        for candidate in selected {
            let key = candidate.url.path
            if var state = files[key], state.inode == candidate.inode, candidate.size >= state.offset {
                if candidate.size > state.offset {
                    readIncrement(candidate, state: &state, now: now,
                                  suppressed: suppressedSessionIDs, into: &observations)
                    files[key] = state
                }
            } else if let state = bootstrap(candidate, now: now,
                                            suppressed: suppressedSessionIDs, into: &observations) {
                files[key] = state
            }
        }
        for key in files.keys.sorted() {
            guard var state = files[key], state.visible, state.activity == .working,
                  !state.idleAfterSilence,
                  now.timeIntervalSince(state.activityAt) >= silenceInterval else { continue }
            state.activity = .idle
            state.idleAfterSilence = true
            if !suppressedSessionIDs.contains(state.sessionID) {
                observations.append(PiSessionObservation(event: event(.sessionStarted, state: state,
                    stamp: now, id: "pi-file:\(state.sessionID):silence:\(state.offset)"), isBootstrap: false))
            }
            files[key] = state
        }
        if files.count > maximumCandidates * 2 {
            let live = Set(selected.map { $0.url.path })
            files = files.filter { live.contains($0.key) }
        }
        return observations
    }

    private func candidates(now: Date) -> [Candidate] {
        let fm = FileManager.default
        guard let rootValues = try? sessionsRoot.resourceValues(forKeys: [.isSymbolicLinkKey]),
              rootValues.isSymbolicLink != true,
              let directories = try? fm.contentsOfDirectory(at: sessionsRoot,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]) else { return [] }
        var found: [Candidate] = []
        for directory in directories.prefix(maximumDirectories) where directory.lastPathComponent.hasPrefix("--") {
            guard let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true,
                  let contents = try? fm.contentsOfDirectory(at: directory,
                    includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { continue }
            for url in contents where url.pathExtension == "jsonl" {
                guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]),
                      values.isSymbolicLink != true,
                      let attributes = try? fm.attributesOfItem(atPath: url.path),
                      attributes[.type] as? FileAttributeType == .typeRegular,
                      (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                      let size = attributes[.size] as? NSNumber,
                      let inode = attributes[.systemFileNumber] as? NSNumber,
                      let modified = attributes[.modificationDate] as? Date,
                      size.uint64Value >= 2,
                      now.timeIntervalSince(modified) >= -60,
                      now.timeIntervalSince(modified) <= recentFileAge else { continue }
                found.append(Candidate(url: url, inode: inode.uint64Value,
                                       size: size.uint64Value, modified: modified))
            }
        }
        return Array(found.sorted { $0.modified > $1.modified }.prefix(maximumCandidates))
    }

    private func bootstrap(_ candidate: Candidate, now: Date, suppressed: Set<String>,
                           into observations: inout [PiSessionObservation]) -> FileState? {
        guard let handle = try? FileHandle(forReadingFrom: candidate.url) else { return nil }
        defer { try? handle.close() }
        guard let beginning = try? handle.read(upToCount: maximumHeaderBytes),
              let headerEnd = beginning.firstIndex(of: 10),
              let header = json(Data(beginning[..<headerEnd])),
              header["type"] as? String == "session",
              let sessionID = safeID(header["id"]),
              let created = recordDate(header),
              let version = header["version"] as? Int, (1...3).contains(version) else { return nil }
        let cwd = safePath(header["cwd"])
        let bodyStart = UInt64(headerEnd + 1)
        let tailStart = max(bodyStart, candidate.size > UInt64(maximumTailBytes)
                            ? candidate.size - UInt64(maximumTailBytes) : bodyStart)
        guard (try? handle.seek(toOffset: tailStart)) != nil else { return nil }
        // FileHandle reports EOF as nil on some Foundation versions. A new
        // session commonly contains only its header, which is still useful.
        let tail = (try? handle.read(upToCount: maximumTailBytes)) ?? Data()
        var state = FileState(inode: candidate.inode, sessionID: sessionID, cwd: cwd,
                              offset: tailStart + UInt64(tail.count), activityAt: created,
                              lastEventAt: created)
        var body = tail
        if tailStart > bodyStart {
            guard let firstNewline = body.firstIndex(of: 10) else { return state }
            body.removeSubrange(...firstNewline)
        }
        consume(body, state: &state, now: now, bootstrap: true,
                suppressed: suppressed, into: &observations)
        if now.timeIntervalSince(candidate.modified) <= recentFileAge,
           now.timeIntervalSince(state.lastEventAt) >= -60,
           now.timeIntervalSince(state.lastEventAt) <= recentFileAge,
           !suppressed.contains(sessionID) {
            state.visible = true
            let kind: AgentEventKind = state.activity == .completed ? .completed : .sessionStarted
            observations.append(PiSessionObservation(event: event(kind, state: state,
                stamp: state.lastEventAt, id: "pi-file:\(sessionID):bootstrap:\(state.offset)"), isBootstrap: true))
        }
        return state
    }

    private func readIncrement(_ candidate: Candidate, state: inout FileState, now: Date,
                               suppressed: Set<String>, into observations: inout [PiSessionObservation]) {
        if candidate.size - state.offset > UInt64(maximumIncrementBytes) {
            if let replacement = bootstrap(candidate, now: now, suppressed: suppressed, into: &observations) {
                state = replacement
            }
            return
        }
        guard let handle = try? FileHandle(forReadingFrom: candidate.url) else { return }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: state.offset)) != nil,
              let bytes = try? handle.read(upToCount: Int(candidate.size - state.offset)) else { return }
        state.offset += UInt64(bytes.count)
        consume(bytes, state: &state, now: now, bootstrap: false,
                suppressed: suppressed, into: &observations)
    }

    private func consume(_ bytes: Data, state: inout FileState, now: Date, bootstrap: Bool,
                         suppressed: Set<String>, into observations: inout [PiSessionObservation]) {
        var buffer = state.partial + bytes
        state.partial.removeAll(keepingCapacity: true)
        if state.discardingLongLine {
            guard let newline = buffer.firstIndex(of: 10) else { return }
            buffer.removeSubrange(...newline)
            state.discardingLongLine = false
        }
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if let record = json(line) {
                state.ordinal += 1
                consumeRecord(record, state: &state, now: now, bootstrap: bootstrap,
                              suppressed: suppressed, into: &observations)
            }
        }
        if buffer.count > maximumLineBytes { state.discardingLongLine = true }
        else { state.partial = buffer }
    }

    private func consumeRecord(_ record: [String: Any], state: inout FileState, now: Date,
                               bootstrap: Bool, suppressed: Set<String>,
                               into observations: inout [PiSessionObservation]) {
        guard let stamp = recordDate(record),
              stamp >= state.lastEventAt.addingTimeInterval(-60) else { return }
        let type = record["type"] as? String
        if type == "model_change" {
            state.model = safeText(record["modelId"], maximum: 256) ?? state.model
            return
        }
        if type == "thinking_level_change" {
            state.effort = safeText(record["thinkingLevel"], maximum: 128) ?? state.effort
            return
        }
        guard type == "message", let message = record["message"] as? [String: Any],
              let role = message["role"] as? String else { return }
        if includeContent {
            if role == "user" { state.prompt = SessionSnippet.message(message["content"]); state.message = nil }
            if role == "assistant" {
                state.message = SessionSnippet.message(message["content"]) ?? state.message
                if let blocks = message["content"] as? [[String: Any]] {
                    state.tool = blocks.last(where: { $0["type"] as? String == "toolCall" })
                        .flatMap { SessionSnippet.text($0["name"], limit: 80) }
                }
            }
        }
        let activity: Activity
        switch role {
        case "user", "toolResult": activity = .working
        case "assistant":
            state.model = safeText(message["model"], maximum: 256) ?? state.model
            state.effort = safeText(message["thinkingLevel"], maximum: 128) ?? state.effort
            switch message["stopReason"] as? String {
            case "stop": activity = .completed
            case "toolUse": activity = .working
            default: activity = .idle
            }
        default: return
        }
        state.activity = activity
        state.activityAt = stamp
        state.lastEventAt = max(state.lastEventAt, stamp)
        state.lastRecordID = safeID(record["id"])
        state.idleAfterSilence = false
        guard !bootstrap, !suppressed.contains(state.sessionID),
              now.timeIntervalSince(stamp) >= -60,
              now.timeIntervalSince(stamp) <= freshRecordAge else { return }
        state.visible = true
        let kind: AgentEventKind = activity == .completed ? .completed :
            activity == .working ? .working : .sessionStarted
        let token = state.lastRecordID ?? "entry-\(state.ordinal)-\(state.offset)"
        observations.append(PiSessionObservation(event: event(kind, state: state,
            stamp: stamp, id: "pi-file:\(state.sessionID):\(token)"), isBootstrap: false))
    }

    private func event(_ kind: AgentEventKind, state: FileState, stamp: Date, id: String) -> AgentEvent {
        AgentEvent(sessionID: state.sessionID, provider: "pi", kind: kind, timestamp: stamp,
                   id: id, title: state.prompt.map { String($0.prefix(100)) }, projectPath: state.cwd,
                   message: state.message, toolName: state.tool, modelName: state.model, reasoningEffort: state.effort, firstPrompt: state.prompt)
    }

    private func json(_ data: Data) -> [String: Any]? {
        guard !data.isEmpty, data.count <= maximumLineBytes else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func safeID(_ value: Any?) -> String? {
        guard let value = safeText(value, maximum: 160),
              value.range(of: "^[A-Za-z0-9._:-]+$", options: .regularExpression) != nil else { return nil }
        return value
    }

    private func safePath(_ value: Any?) -> String? {
        guard let value = safeText(value, maximum: 4096), value.hasPrefix("/") else { return nil }
        return value
    }

    private func safeText(_ value: Any?, maximum: Int) -> String? {
        guard let text = value as? String, !text.isEmpty, text.utf8.count <= maximum,
              !text.unicodeScalars.contains(where: { $0.value < 32 }) else { return nil }
        return text
    }

    private func recordDate(_ record: [String: Any]) -> Date? {
        guard let text = record["timestamp"] as? String else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return parser.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

/// File polling is off the UI thread. Hook sightings suppress later file
/// observations for the same Pi session before they reach the main queue.
final class PiSessionObserver {
    private let queue = DispatchQueue(label: "si-notch.pi-session-observer", qos: .utility)
    private let lock = NSLock()
    private var started = false
    private var generation: UInt64 = 0
    private var hookSessionIDs = Set<String>()
    private var scanner: PiSessionScanner
    private let interval: TimeInterval
    private let onEvent: (AgentEvent, Bool) -> Void
    private var timer: DispatchSourceTimer?

    init(sessionsRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent/sessions", isDirectory: true),
         pollInterval: TimeInterval = 1,
         onEvent: @escaping (AgentEvent, Bool) -> Void) {
        scanner = PiSessionScanner(sessionsRoot: sessionsRoot, includeContent: true)
        interval = max(0.25, pollInterval)
        self.onEvent = onEvent
    }

    func markHookObserved(sessionID: String) {
        lock.lock()
        hookSessionIDs.insert(sessionID)
        lock.unlock()
    }

    func start() {
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true
        generation &+= 1
        let current = generation
        lock.unlock()
        queue.async { [weak self] in
            guard let self, self.isCurrent(current), self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: self.interval)
            timer.setEventHandler { [weak self] in
                guard let self, self.isCurrent(current) else { return }
                let suppressed = self.currentHookSessionIDs()
                for observation in self.scanner.poll(suppressedSessionIDs: suppressed) {
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.isCurrent(current),
                              !self.isHookObserved(observation.event.sessionID) else { return }
                        self.onEvent(observation.event, observation.isBootstrap)
                    }
                }
            }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        lock.lock()
        started = false
        generation &+= 1
        lock.unlock()
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
        }
    }

    private func currentHookSessionIDs() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return hookSessionIDs
    }

    private func isHookObserved(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return hookSessionIDs.contains(id)
    }

    private func isCurrent(_ value: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return started && generation == value
    }
}
