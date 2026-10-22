import Foundation
import Darwin
import SINotchCore

/// Utility-queue confined, incremental, private journal. File offsets and numeric
/// aggregates commit together; reopening cannot replay an already counted tail.
final class UsageStore {
    struct Cursor: Codable {
        var inode: UInt64
        var offset: UInt64 = 0
        var parser = UsageLogParser()
        var discarding = false
    }
    struct State: Codable {
        var version = 2
        var files: [String: Cursor] = [:]
        var events: [String: UsageSession] = [:]
        var requestIDs: [String: Set<String>] = [:]
        var groups: [String: [String]]?
        var legacyFiles: [String: Cursor]?
    }
    private(set) var state = State()
    private let directory: URL
    private var directories = SessionDirectoryCache()
    private var pending: [URL] = []
    private var discoveredProviders: [String: String] = [:]
    private var dirty = false
    private var titles: [String: String] = [:]
    private var titleMetadata: [URL: SessionFileMetadata] = [:]
    private(set) var incomplete = false
    private(set) var sourceUnavailable = false
    private var lastDiscovery = Date.distantPast
    let roots: [(String, URL)]
    private let maxLine = 2 * 1024 * 1024
    private let maxState: Int
    private var savedState = State()

    init(directory: URL, roots: [(String, URL)], maximumBytes: Int = 64 * 1024 * 1024) throws {
        self.maxState = maximumBytes
        self.directory = directory
        self.roots = roots.map { ($0.0, $0.1.standardizedFileURL.resolvingSymlinksInPath()) }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let meta = SessionFileMetadata(directory), meta.isDirectory, meta.owner == geteuid() else { throw CocoaError(.fileReadNoPermission) }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let url = directory.appendingPathComponent("tokens.json")
        if fm.fileExists(atPath: url.path) {
            guard let meta = SessionFileMetadata(url), meta.isRegularFile, meta.owner == geteuid(), meta.size <= maxState else { throw CocoaError(.fileReadNoPermission) }
            state = try JSONDecoder().decode(State.self, from: Data(contentsOf: url))
            guard (1...2).contains(state.version) else { throw CocoaError(.fileReadCorruptFile) }
            if state.version == 1 {
                let backup = directory.appendingPathComponent("tokens-v1-" + UUID().uuidString + ".backup")
                try fm.copyItem(at: url, to: backup)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
                // Retain the old aggregates until their primary sources have been rebuilt.
                state.legacyFiles = state.files
                state.files = [:]; state.version = 2; dirty = true
                try flush()
            }
            savedState = state
        }
    }
    var sessions: [UsageSession] {
        var values = state.events
        for cursor in (state.legacyFiles ?? [:]).values {
            guard var row = cursor.parser.session else { continue }
            row.partial = true
            values[row.id] = Self.merge(values[row.id], row)
        }
        for cursor in state.files.values {
            guard let row = cursor.parser.session else { continue }
            values[row.id] = Self.merge(values[row.id], row)
        }
        for (key, title) in titles where values[key] != nil { values[key]?.title = title }
        return values.values.sorted { $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt }
    }
    static func merge(_ existing: UsageSession?, _ row: UsageSession) -> UsageSession {
        var result = existing ?? row
        for (id, turn) in row.turns where result.turns[id] == nil || turn.counts.total > result.turns[id]!.counts.total { result.turns[id] = turn }
        for (id, request) in row.requests ?? [:] {
            result.requests = result.requests ?? [:]
            if let prior = result.requests?[id] {
                if !prior.matchesMeasurement(request) { result.partial = true }
            } else { result.requests?[id] = request }
        }
        for (id, info) in row.turnInfo ?? [:] {
            result.turnInfo = result.turnInfo ?? [:]
            if result.turnInfo?[id] == nil || info.status != .working { result.turnInfo?[id] = info }
        }
        result.updatedAt = max(result.updatedAt, row.updatedAt); result.partial = result.partial || row.partial
        if result.title == String(result.sessionID.prefix(12)) { result.title = row.title }
        result.parentID = result.parentID ?? row.parentID; result.project = result.project ?? row.project
        result.model = row.model ?? result.model; result.connectionName = row.connectionName ?? result.connectionName
        // Rotated/duplicated files may contain disjoint requests in the same turn.
        // The union of request identities is the minimum known total, component by component.
        let sums = Dictionary(grouping: (result.requests ?? [:]).values, by: \.aggregateID)
        for (id, requests) in sums {
            let sum = requests.reduce(TokenCounts.zero) { $0.adding($1.counts) }
            let previous = result.turns[id]
            let prior = previous?.counts ?? .zero
            let input = max(prior.input, sum.input), output = max(prior.output, sum.output)
            let counts = input == sum.input && output == sum.output ? sum : TokenCounts(input: input, output: output,
                cached: prior.cached, cacheWrite: prior.cacheWrite, reasoning: prior.reasoning)
            result.turns[id] = UsageTurn(counts: counts, date: max(previous?.date ?? .distantPast, requests.map(\.date).max()!),
                                        model: previous?.model ?? requests.last?.model, authoritative: previous?.authoritative ?? true)
        }
        return result
    }
    func group(_ ids: [String], id: String = "group:" + UUID().uuidString) throws {
        let valid = Set(TaskUsageIndex(sessions: sessions).tasks.filter { !$0.unassigned }.map(\.id))
        let selected = Set(ids)
        guard selected.count > 1, selected.isSubset(of: valid),
              !(state.groups ?? [:]).values.contains(where: { !Set($0).isDisjoint(with: selected) }) else { throw CocoaError(.validationMissingMandatoryProperty) }
        state.groups = state.groups ?? [:]; state.groups?[id] = selected.sorted(); dirty = true
        try flush()
    }
    func ungroup(_ id: String) throws { state.groups?.removeValue(forKey: id); dirty = true; try flush() }
    func restoreLastSaved() { state = savedState; dirty = false; pending = []; lastDiscovery = .distantPast }
    /// Keeps lifecycle metadata and request identity even after the live card ends.
    func accept(_ event: AgentEvent) {
        guard event.kind != .agentPresence else { return }
        let key = UsageSession.key(provider: event.provider, connection: event.connectionID, session: event.sessionID)
        var row = state.events[key] ?? UsageSession(sessionID: event.sessionID, provider: event.provider,
            connectionID: event.connectionID, title: event.title, date: event.timestamp)
        let old = row
        if let title = event.title { row.title = String(title.prefix(160)) }
        row.project = event.projectPath ?? row.project
        row.model = event.modelName ?? row.model
        row.connectionName = event.connectionName ?? row.connectionName
        row.partial = row.partial || event.usage?.incomplete == true
        if let turn = event.turnID {
            row.turnInfo = row.turnInfo ?? [:]
            if row.turnInfo?[turn] == nil { row.turnInfo?[turn] = UsageTurnInfo(startedAt: event.timestamp) }
            if let status = event.kind.historyTerminalStatus { row.turnInfo?[turn]?.status = status }
        }
        // Native Codex/Pi logs are authoritative. Hook snapshots never add to them.
        if let usage = event.usage, let counts = TokenCounts(usage), !["codex", "pi"].contains(event.provider.lowercased()) {
            if let request = usage.requestID {
                if state.requestIDs[key]?.contains(request) != true {
                    state.requestIDs[key, default: []].insert(request)
                    let turn = event.turnID ?? request
                    row.requests = row.requests ?? [:]
                    row.requests?[request] = UsageRequest(id: request, aggregateID: turn, turnID: event.turnID,
                        counts: counts, date: usage.endedAt.map { Date(timeIntervalSince1970: $0) } ?? event.timestamp,
                        startedAt: usage.startedAt.map { Date(timeIntervalSince1970: $0) }, model: row.model, kind: usage.callKind)
                    if let ownTurn = event.turnID, let parent = usage.parentSessionID, let parentTurn = usage.parentTurnID {
                        row.parentID = UsageSession.key(provider: event.provider, connection: event.connectionID, session: parent)
                        row.turnInfo?[ownTurn]?.parentSessionKey = row.parentID
                        row.turnInfo?[ownTurn]?.parentTurnID = parentTurn
                    }
                    row.partial = row.partial || usage.incomplete == true
                    row.turns[turn] = UsageTurn(counts: (row.turns[turn]?.counts ?? .zero).adding(counts), date: event.timestamp, model: row.model)
                } else if let prior = row.requests?[request], prior.counts != counts || prior.turnID != event.turnID { row.partial = true }
            } else {
                // Cumulative snapshots replace rather than add across refreshes.
                row.turns["snapshot"] = UsageTurn(counts: counts, date: event.timestamp, model: row.model)
            }
        }
        if let child = event.subagent, let sid = child.sessionID {
            let childKey = UsageSession.key(provider: event.provider, connection: event.connectionID, session: sid)
            if let parentTurn = child.parentTurnID ?? event.turnID {
                row.turnInfo = row.turnInfo ?? [:]
                if row.turnInfo?[parentTurn] == nil { row.turnInfo?[parentTurn] = UsageTurnInfo(startedAt: event.timestamp) }
                let children = (row.turnInfo?[parentTurn]?.childSessionKeys ?? []).union([childKey])
                row.turnInfo?[parentTurn]?.childSessionKeys = children
            }
            var childRow = state.events[childKey] ?? UsageSession(sessionID: sid, provider: event.provider,
                connectionID: event.connectionID, title: child.name, date: event.timestamp)
            childRow.parentID = key; childRow.title = child.name; childRow.connectionName = event.connectionName
            if childRow != state.events[childKey] { state.events[childKey] = childRow; dirty = true }
        }
        if row != old || state.events[key] == nil { row.updatedAt = max(row.updatedAt, event.timestamp); state.events[key] = row; dirty = true }
    }
    @discardableResult
    func scan(now: Date = Date(), byteBudget: Int = 8 * 1024 * 1024, timeBudget: TimeInterval = 0.4) -> Bool {
        let started = Date()
        refreshTitles()
        if pending.isEmpty || now.timeIntervalSince(lastDiscovery) >= 60 {
            var found: [URL] = []
            sourceUnavailable = false
            for (provider, root) in roots {
                guard let metadata = SessionFileMetadata(root) else { continue } // optional agent not installed
                guard metadata.isDirectory, metadata.owner == geteuid() else { sourceUnavailable = true; continue }
                var folders = [root]
                for _ in 0..<(provider == "codex" ? 3 : 2) {
                    var next: [URL] = []
                    for folder in folders {
                        for child in directories.contents(of: folder) {
                            guard let meta = SessionFileMetadata(child), meta.owner == geteuid() else { continue }
                            if meta.isDirectory { next.append(child) }
                            else if meta.isRegularFile, child.pathExtension == "jsonl" { found.append(child); discoveredProviders[child.path] = provider }
                        }
                    }
                    folders = next
                }
                for folder in folders {
                    for child in directories.contents(of: folder) where child.pathExtension == "jsonl" && SessionFileMetadata(child)?.isRegularFile == true {
                        found.append(child); discoveredProviders[child.path] = provider
                    }
                }
            }
            let known = Set(pending)
            let added = Set(found).subtracting(known).sorted {
                (SessionFileMetadata($0)?.modified ?? .distantPast) > (SessionFileMetadata($1)?.modified ?? .distantPast)
            }
            pending += added
            lastDiscovery = now
        }
        var budget = max(1, byteBudget)
        var deferred: [URL] = []
        var changed = false
        while !pending.isEmpty, budget > 0, Date().timeIntervalSince(started) < timeBudget {
            let url = pending.removeFirst()
            guard let meta = SessionFileMetadata(url), meta.isRegularFile, meta.owner == geteuid(),
                  let provider = discoveredProviders[url.path] else { sourceUnavailable = true; continue }
            var cursor = state.files[url.path] ?? Cursor(inode: meta.inode)
            if cursor.inode != meta.inode || meta.size < cursor.offset {
                if let previous = cursor.parser.session {
                    state.events[previous.id] = Self.merge(state.events[previous.id], previous); dirty = true
                }
                cursor = Cursor(inode: meta.inode)
            }
            guard cursor.offset < meta.size else { continue }
            do {
                let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
                try handle.seek(toOffset: cursor.offset)
                // Leave incomplete trailing lines on disk, including across app restarts.
                let data = try handle.read(upToCount: min(budget, maxLine)) ?? Data()
                budget -= data.count
                var consumed = 0
                for index in data.indices where data[index] == 10 {
                    let line = data.subdata(in: consumed..<index)
                    if !cursor.discarding, !line.isEmpty,
                       let row = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                        cursor.parser.consume(row, provider: provider)
                    }
                    cursor.discarding = false
                    consumed = index + 1
                }
                if consumed == 0, data.count == maxLine {
                    cursor.discarding = true; consumed = data.count
                    cursor.parser.session?.partial = true
                }
                cursor.offset += UInt64(consumed)
                if let legacy = state.legacyFiles?[url.path], cursor.inode == legacy.inode, cursor.offset >= legacy.offset {
                    // Rebuilt the exact old prefix. Prefer the source over the migration fallback,
                    // including when rebuilding corrects an older parser's overcount.
                    state.legacyFiles?.removeValue(forKey: url.path); dirty = true
                }
                if consumed > 0 { state.files[url.path] = cursor; changed = true; dirty = true }
                if consumed > 0, cursor.offset < meta.size { deferred.append(url) }
            } catch { sourceUnavailable = true; deferred.append(url) }
        }
        pending += deferred
        incomplete = !pending.isEmpty || sourceUnavailable
        return changed
    }
    private func refreshTitles() {
        for (provider, root) in roots where provider == "codex" && root.lastPathComponent == "sessions" {
            let index = root.deletingLastPathComponent().appendingPathComponent("session_index.jsonl")
            guard let meta = SessionFileMetadata(index), meta.isRegularFile, meta.owner == geteuid(),
                  meta.size <= 8 * 1024 * 1024, titleMetadata[index] != meta,
                  let data = try? Data(contentsOf: index) else { continue }
            for line in data.split(separator: 10) {
                guard let row = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      let sid = UsageLogParser.identifier(row["id"]),
                      let title = UsageLogParser.text(row["thread_name"], max: 160) else { continue }
                let key = UsageSession.key(provider: "codex", session: sid)
                titles[key] = title
                // Retain known names when the native index later disappears.
                for path in state.files.keys where state.files[path]?.parser.session?.id == key {
                    if state.files[path]?.parser.session?.title != title { state.files[path]?.parser.session?.title = title; dirty = true }
                }
            }
            titleMetadata[index] = meta
        }
    }
    func flush() throws {
        guard dirty else { return }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
        guard data.count <= maxState else { throw CocoaError(.fileWriteOutOfSpace) }
        let temporary = directory.appendingPathComponent(".tokens-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        let handle = try FileHandle(forWritingTo: temporary)
        defer { try? handle.close() }
        try handle.synchronize()
        guard rename(temporary.path, directory.appendingPathComponent("tokens.json").path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        let fd = open(directory.path, O_RDONLY)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw CocoaError(.fileWriteUnknown) }
        dirty = false; savedState = state
    }
}
