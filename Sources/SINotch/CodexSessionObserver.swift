import Foundation
import SINotchCore

/// A local, read-only rollout observation. Bootstrap events are historical state
/// snapshots and should not trigger notification sounds or automatic reveal.
struct CodexSessionObservation {
    let event: AgentEvent
    let isBootstrap: Bool
}

/// Polls recent local rollouts. Optional public snippets exclude reasoning,
/// tool arguments and command output.
struct CodexRolloutScanner {
    private struct FileState {
        let inode: UInt64
        var offset: UInt64
        var partial = Data()
        var discardingLongLine = false
        let sessionID: String
        let cwd: String?
        let isInternalSession: Bool?
        var activeTurnID: String?
        var activeTurnStartedAt: Date?
        var activityAt: Date?
        var visible = false
        var idleAfterSilence = false
        var prompt: String?
        var message: String?
        var model: String?
        var effort: String?
        var tools: [String: String] = [:]
    }

    private struct Candidate {
        let url: URL
        let inode: UInt64
        let size: UInt64
        let modified: Date
    }

    let sessionsRoot: URL
    let includeContent: Bool
    var silenceInterval: TimeInterval = 15 * 60
    private var files: [String: FileState] = [:]

    private let maximumFiles = 16
    private let maximumLineBytes = 256 * 1_024
    private let maximumBootstrapBytes = 4 * 1_024 * 1_024
    private let maximumIncrementBytes = 512 * 1_024

    init(sessionsRoot: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/sessions", isDirectory: true), includeContent: Bool = false) {
        self.sessionsRoot = sessionsRoot.standardizedFileURL
        self.includeContent = includeContent
    }

    mutating func poll(now: Date = Date()) -> [CodexSessionObservation] {
        var observations: [CodexSessionObservation] = []
        for candidate in candidates(now: now) {
            let key = candidate.url.path
            if var state = files[key], state.inode == candidate.inode, candidate.size >= state.offset {
                if candidate.size > state.offset {
                    readIncrement(candidate, state: &state, now: now, into: &observations)
                    files[key] = state
                }
            } else if let state = bootstrap(candidate, now: now, into: &observations) {
                files[key] = state
            }
        }
        for key in files.keys.sorted() {
            guard var state = files[key], let activity = state.activityAt,
                  state.activeTurnID != nil, state.visible, !state.idleAfterSilence,
                  now.timeIntervalSince(activity) >= silenceInterval else { continue }
            state.idleAfterSilence = true
            observations.append(CodexSessionObservation(event: event(.sessionStarted, state: state, now: now,
                id: "rollout:\(state.activeTurnID ?? "unknown"):silent"), isBootstrap: false))
            files[key] = state
        }
        if files.count > maximumFiles * 2 {
            let live = Set(candidates(now: now).map { $0.url.path })
            files = files.filter { live.contains($0.key) }
        }
        return observations
    }

    private func candidates(now: Date) -> [Candidate] {
        let fm = FileManager.default
        var directories = Set<String>()
        for zone in [TimeZone.current, TimeZone(secondsFromGMT: 0)!] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            for daysBack in 0..<3 {
                guard let date = calendar.date(byAdding: .day, value: -daysBack, to: now) else { continue }
                let dateParts = calendar.dateComponents([.year, .month, .day], from: date)
                guard let year = dateParts.year, let month = dateParts.month, let day = dateParts.day else { continue }
                directories.insert(sessionsRoot.appendingPathComponent(String(format: "%04d/%02d/%02d", year, month, day)).path)
            }
        }
        var found: [Candidate] = []
        for directory in directories {
            guard let contents = try? fm.contentsOfDirectory(at: URL(fileURLWithPath: directory),
                includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { continue }
            for url in contents where url.lastPathComponent.hasPrefix("rollout-") && url.pathExtension == "jsonl" {
                guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]),
                      values.isSymbolicLink != true,
                      let attributes = try? fm.attributesOfItem(atPath: url.path),
                      attributes[.type] as? FileAttributeType == .typeRegular,
                      let size = attributes[.size] as? NSNumber,
                      let inode = attributes[.systemFileNumber] as? NSNumber,
                      let modified = attributes[.modificationDate] as? Date,
                      now.timeIntervalSince(modified) >= -60,
                      now.timeIntervalSince(modified) <= 30 * 60 else { continue }
                found.append(Candidate(url: url, inode: inode.uint64Value,
                                       size: size.uint64Value, modified: modified))
            }
        }
        return Array(found.sorted { $0.modified > $1.modified }.prefix(maximumFiles))
    }

    private func bootstrap(_ candidate: Candidate, now: Date,
                           into observations: inout [CodexSessionObservation]) -> FileState? {
        guard let handle = try? FileHandle(forReadingFrom: candidate.url) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: maximumLineBytes),
              let newline = header.firstIndex(of: 10),
              let meta = json(Data(header[..<newline])),
              meta["type"] as? String == "session_meta",
              let payload = meta["payload"] as? [String: Any],
              payload["parent_thread_id"] == nil,
              CodexServiceSessionFilter.nativeClassification(source: payload["source"]) != true,
              let id = payload["id"] as? String, UUID(uuidString: id) != nil else { return nil }
        let cwd = (payload["cwd"] as? String).flatMap { $0.hasPrefix("/") && $0.utf8.count <= 4096 ? $0 : nil }
        var state = FileState(inode: candidate.inode, offset: 0, sessionID: id, cwd: cwd,
            isInternalSession: CodexServiceSessionFilter.nativeClassification(source: payload["source"]))
        let firstLineEnd = UInt64(newline + 1)
        let start = max(firstLineEnd, candidate.size > UInt64(maximumBootstrapBytes)
                        ? candidate.size - UInt64(maximumBootstrapBytes) : firstLineEnd)
        guard (try? handle.seek(toOffset: start)) != nil,
              let bytes = try? handle.read(upToCount: maximumBootstrapBytes) else { return nil }
        state.offset = start + UInt64(bytes.count)
        var data = bytes
        if start > firstLineEnd {
            guard let boundary = data.firstIndex(of: 10) else { return state }
            data.removeSubrange(...boundary)
        }
        consume(data, state: &state, now: now, bootstrap: true, into: &observations)
        if state.activeTurnID != nil, let activity = state.activityAt,
           now.timeIntervalSince(activity) >= -60, now.timeIntervalSince(activity) <= 3 * 60 {
            state.visible = true
            observations.append(CodexSessionObservation(event: event(.working, state: state, now: now,
                id: "rollout:\(state.activeTurnID ?? "unknown"):bootstrap"), isBootstrap: true))
        }
        return state
    }

    private func readIncrement(_ candidate: Candidate, state: inout FileState, now: Date,
                               into observations: inout [CodexSessionObservation]) {
        // A very large append is bounded: its final tail is treated as a fresh
        // snapshot, never replayed as a sequence of actions.
        if candidate.size - state.offset > UInt64(maximumBootstrapBytes) {
            if let replacement = bootstrap(candidate, now: now, into: &observations) { state = replacement }
            return
        }
        guard let handle = try? FileHandle(forReadingFrom: candidate.url) else { return }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: state.offset)) != nil,
              let bytes = try? handle.read(upToCount: min(maximumIncrementBytes,
                Int(candidate.size - state.offset))) else { return }
        state.offset += UInt64(bytes.count)
        consume(bytes, state: &state, now: now, bootstrap: false, into: &observations)
    }

    private func consume(_ bytes: Data, state: inout FileState, now: Date, bootstrap: Bool,
                         into observations: inout [CodexSessionObservation]) {
        var buffer = state.partial + bytes
        state.partial.removeAll(keepingCapacity: true)
        if state.discardingLongLine {
            guard let boundary = buffer.firstIndex(of: 10) else { return }
            buffer.removeSubrange(...boundary)
            state.discardingLongLine = false
        }
        while let boundary = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<boundary])
            buffer.removeSubrange(...boundary)
            if line.count <= maximumLineBytes, let record = json(line) {
                consumeRecord(record, state: &state, now: now, bootstrap: bootstrap, into: &observations)
            }
        }
        if buffer.count > maximumLineBytes { state.discardingLongLine = true }
        else { state.partial = buffer }
    }

    private func consumeRecord(_ record: [String: Any], state: inout FileState, now: Date,
                               bootstrap: Bool, into observations: inout [CodexSessionObservation]) {
        guard let kind = record["type"] as? String,
              let payload = record["payload"] as? [String: Any] else { return }
        if kind == "turn_context" {
            state.model = Self.safeText(payload["model"], maximum: 256) ?? state.model
            state.effort = Self.safeText(payload["effort"], maximum: 128) ?? state.effort
            if state.visible && !bootstrap {
                observations.append(CodexSessionObservation(event: event(.usageUpdated, state: state,
                    now: now, id: "rollout:\(state.activeTurnID ?? "unknown"):model:\(state.offset)"), isBootstrap: false))
            }
            return
        }
        guard let stamp = Self.recordDate(record) else { return }
        if includeContent, kind == "response_item", payload["type"] as? String == "message" {
            let role = payload["role"] as? String
            if role == "user" { state.prompt = SessionSnippet.message(payload["content"]); state.message = nil }
            if role == "assistant", payload["phase"] as? String != "analysis" {
                state.message = SessionSnippet.message(payload["content"]) ?? state.message
            }
            if state.visible && !bootstrap && (role == "user" || role == "assistant") {
                observations.append(CodexSessionObservation(event: event(.usageUpdated, state: state,
                    now: now, id: "rollout:message:\(state.offset)"), isBootstrap: false))
            }
        }
        if kind == "event_msg" {
            switch payload["type"] as? String {
            case "user_message" where includeContent:
                state.prompt = SessionSnippet.text(payload["message"])
                state.message = nil
            case "task_started":
                guard let turn = payload["turn_id"] as? String, UUID(uuidString: turn) != nil else { return }
                state.activeTurnID = turn
                state.activeTurnStartedAt = stamp
                state.activityAt = stamp
                state.idleAfterSilence = false
                state.tools.removeAll()
                if !bootstrap, now.timeIntervalSince(stamp) >= -60,
                   now.timeIntervalSince(stamp) <= 5 * 60 {
                    state.visible = true
                    observations.append(CodexSessionObservation(event: event(.working, state: state,
                        now: now, id: "rollout:\(turn):start"), isBootstrap: false))
                }
            case "task_complete":
                guard let turn = state.activeTurnID,
                      payload["turn_id"] as? String == turn else { return }
                state.message = includeContent ? SessionSnippet.text(payload["last_agent_message"]) ?? state.message : nil
                state.activeTurnID = nil
                state.activeTurnStartedAt = nil
                state.activityAt = stamp
                state.idleAfterSilence = false
                state.tools.removeAll()
                if state.visible && !bootstrap {
                    observations.append(CodexSessionObservation(event: event(.completed, state: state,
                        now: now, id: "rollout:\(turn):complete", turnID: turn), isBootstrap: false))
                }
                state.visible = false
            case "turn_aborted", "turn_cancelled":
                guard let turn = state.activeTurnID,
                      let startedAt = state.activeTurnStartedAt,
                      stamp >= startedAt else { return }
                if let value = payload["turn_id"], !(value is NSNull) {
                    guard let reportedTurn = value as? String, reportedTurn == turn else { return }
                }
                state.activeTurnID = nil
                state.activeTurnStartedAt = nil
                state.activityAt = stamp
                state.idleAfterSilence = false
                state.tools.removeAll()
                if state.visible && !bootstrap {
                    observations.append(CodexSessionObservation(event: event(.sessionStarted,
                        state: state, now: now, id: "rollout:\(turn):aborted"), isBootstrap: false))
                }
                state.visible = false
            case "item_completed", "token_count", "agent_message":
                if includeContent, payload["type"] as? String == "agent_message" {
                    state.message = SessionSnippet.text(payload["message"]) ?? state.message
                }
                guard state.activeTurnID != nil else { return }
                state.activityAt = stamp
                if (state.idleAfterSilence || !state.visible) && !bootstrap,
                   now.timeIntervalSince(stamp) >= -60,
                   now.timeIntervalSince(stamp) <= 5 * 60 {
                    state.idleAfterSilence = false
                    state.visible = true
                    observations.append(CodexSessionObservation(event: event(.working, state: state,
                        now: now, id: "rollout:\(state.activeTurnID ?? "unknown"):resume:\(state.offset)"), isBootstrap: false))
                }
            default: break
            }
        } else if kind == "response_item", !bootstrap, state.activeTurnID != nil,
                  let itemType = payload["type"] as? String,
                  let callID = Self.safeText(payload["call_id"], maximum: 160),
                  callID.range(of: "^[A-Za-z0-9_.:-]+$", options: .regularExpression) != nil,
                  now.timeIntervalSince(stamp) >= -60,
                  now.timeIntervalSince(stamp) <= 5 * 60 {
            switch itemType {
            case "function_call", "custom_tool_call":
                guard let name = Self.safeText(payload["name"], maximum: 80),
                      name.range(of: "^[A-Za-z0-9_.:-]+$", options: .regularExpression) != nil else { return }
                if state.tools.count < 32 { state.tools[callID] = name }
                state.activityAt = stamp
                state.visible = true
                state.idleAfterSilence = false
                observations.append(CodexSessionObservation(event: event(.toolStarted, state: state,
                    now: now, id: "rollout:\(callID):tool-start", toolName: name), isBootstrap: false))
            case "function_call_output", "custom_tool_call_output":
                guard let name = state.tools.removeValue(forKey: callID) else { return }
                state.activityAt = stamp
                state.visible = true
                state.idleAfterSilence = false
                observations.append(CodexSessionObservation(event: event(.toolFinished, state: state,
                    now: now, id: "rollout:\(callID):tool-finish", toolName: name), isBootstrap: false))
            default: break
            }
        }
    }

    private func event(_ kind: AgentEventKind, state: FileState, now: Date,
                       id: String, toolName: String? = nil, turnID: String? = nil) -> AgentEvent {
        AgentEvent(sessionID: state.sessionID, provider: "codex", kind: kind,
                   timestamp: now, id: id, title: state.prompt.map { String($0.prefix(100)) }, projectPath: state.cwd,
                   message: state.message, toolName: toolName, modelName: state.model, reasoningEffort: state.effort, firstPrompt: state.prompt,
                   turnID: turnID ?? state.activeTurnID, isInternalSession: state.isInternalSession)
    }

    private static func safeText(_ value: Any?, maximum: Int) -> String? {
        guard let string = value as? String, !string.isEmpty, string.utf8.count <= maximum,
              !string.unicodeScalars.contains(where: { $0.value < 32 }) else { return nil }
        return string
    }

    private static func recordDate(_ record: [String: Any]) -> Date? {
        guard let value = record["timestamp"] as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private func json(_ data: Data) -> [String: Any]? {
        guard !data.isEmpty, data.count <= maximumLineBytes else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// Runs file polling away from the UI thread and delivers observations on main.
final class CodexSessionObserver {
    private let queue = DispatchQueue(label: "si-notch.codex-rollout-observer", qos: .utility)
    private let lifecycleLock = NSLock()
    private var started = false
    private var generation: UInt64 = 0
    private let interval: TimeInterval
    private let onEvent: (AgentEvent, Bool) -> Void
    private var scanner: CodexRolloutScanner
    private var desktopScanner = CodexDesktopScanner()
    private var desktopStream: CodexDesktopStream?
    private var timer: DispatchSourceTimer?

    init(sessionsRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true),
         pollInterval: TimeInterval = 1,
         onEvent: @escaping (AgentEvent, Bool) -> Void) {
        scanner = CodexRolloutScanner(sessionsRoot: sessionsRoot, includeContent: true)
        interval = max(0.25, pollInterval)
        self.onEvent = onEvent
    }

    func start() {
        lifecycleLock.lock()
        guard !started else { lifecycleLock.unlock(); return }
        started = true
        generation &+= 1
        let currentGeneration = generation
        lifecycleLock.unlock()
        queue.async { [weak self] in
            guard let self, self.isCurrent(currentGeneration), self.timer == nil else { return }
            self.desktopStream = CodexDesktopStream(queue: self.queue) { [weak self] event, bootstrap in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isCurrent(currentGeneration) else { return }
                    self.onEvent(event, bootstrap)
                }
            }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: self.interval)
            timer.setEventHandler { [weak self] in
                guard let self, self.isCurrent(currentGeneration) else { return }
                let desktop = self.desktopScanner.poll()
                self.desktopStream?.observe(desktop.map { $0.event.sessionID })
                // A fresh Desktop stream owns the lifecycle. File snapshots and
                // log lines must not replay older states over its current turn.
                let observations = (self.scanner.poll() + desktop).filter { self.desktopStream?.contains($0.event.sessionID) != true }
                for observation in observations.sorted(by: { $0.event.timestamp < $1.event.timestamp }) {
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.isCurrent(currentGeneration) else { return }
                        self.onEvent(observation.event, observation.isBootstrap)
                    }
                }
            }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        lifecycleLock.lock()
        started = false
        generation &+= 1
        lifecycleLock.unlock()
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
            self?.desktopStream?.stop()
            self?.desktopStream = nil
        }
    }

    private func isCurrent(_ value: UInt64) -> Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return started && generation == value
    }
}
