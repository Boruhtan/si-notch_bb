import Foundation
import CryptoKit
import Darwin
import SINotchCore

extension AgentEventKind {
    var historyTerminalStatus: AgentStatus? {
        switch self {
        case .completed: return .completed
        case .failed: return .failed
        case .sessionEnded: return .ended
        default: return nil
        }
    }
}

struct HistoryPolicy: Equatable {
    var enabled = true
    var maximumCount = 1000
    var maximumBytes = 200 * 1024 * 1024
    init(enabled: Bool = true, count: Int = 1000, megabytes: Int = 200) {
        self.enabled = enabled
        maximumCount = min(10000, max(1, count))
        maximumBytes = min(2048, max(1, megabytes)) * 1024 * 1024
    }
    init(defaults: UserDefaults) {
        self.init(enabled: defaults.object(forKey: "historyEnabled") as? Bool ?? true,
                  count: defaults.object(forKey: "historyMaximumCount") as? Int ?? 1000,
                  megabytes: defaults.object(forKey: "historyMaximumMB") as? Int ?? 200)
    }
}

struct HistorySummary: Codable, Identifiable, Equatable {
    var id: UUID
    var sessionKey: String
    var turnID: String?
    var title: String
    var provider: String
    var project: String?
    var startedAt: Date
    var updatedAt: Date
    var status: AgentStatus
    var memoryService: Bool
    var bytes: Int
}

struct HistoryEntry: Codable, Equatable, Identifiable {
    var summary: HistorySummary
    var items: [AgentHistoryItem] = []
    var truncated = false
    var id: UUID { summary.id }
}

/// Queue-confined Foundation store. Only its small index and up to eight open
/// records live in memory. No directory polling, full-text index, or idle timer.
final class HistoryStore {
    static let maximumEntryBytes = 256 * 1024
    static let maximumTextCharacters = 16384
    private struct Index: Codable {
        var version = 1
        var entries: [HistorySummary]
        var blockedTurns: [String]
    }
    let directory: URL
    private(set) var policy: HistoryPolicy
    private(set) var summaries: [UUID: HistorySummary] = [:]
    private var cache: [UUID: HistoryEntry] = [:]
    private var dirty: Set<UUID> = []
    private var current: [String: UUID] = [:]
    private var blockedTurns: Set<String> = []
    private var blockedOrder: [String] = []
    private var indexDirty = false
    private let files = FileManager.default
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return encoder
    }()
    var ordered: [HistorySummary] {
        summaries.values.sorted { $0.updatedAt == $1.updatedAt ? $0.id.uuidString < $1.id.uuidString : $0.updatedAt > $1.updatedAt }
    }
    var bytes: Int { summaries.values.reduce(0) { $0 + $1.bytes } + ((try? regularSize(indexURL, maximum: 16 * 1024 * 1024)) ?? 0) }
    private var indexURL: URL { directory.appendingPathComponent("index.json") }
    private func url(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }

    init(directory: URL, policy: HistoryPolicy) throws {
        self.directory = directory; self.policy = policy
        try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == geteuid() else { throw CocoaError(.fileReadNoPermission) }
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        if let size = try? regularSize(indexURL, maximum: 16 * 1024 * 1024), size > 0,
           let index = try? JSONDecoder().decode(Index.self, from: Data(contentsOf: indexURL)), index.version == 1 {
            blockedOrder = Array(index.blockedTurns.suffix(256)); blockedTurns = Set(blockedOrder)
            for var summary in index.entries.prefix(10000) {
                if let size = try? regularSize(url(summary.id), maximum: Self.maximumEntryBytes) {
                    summary.bytes = size; summaries[summary.id] = summary
                }
            }
        }
        // Recover a record committed just before an interrupted index write.
        // This runs once on the utility queue, never on the UI thread.
        for child in try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            if child.lastPathComponent.hasPrefix(".write-"),
               UUID(uuidString: String(child.lastPathComponent.dropFirst(7))) != nil,
               (try? regularSize(child, maximum: Self.maximumEntryBytes)) != nil {
                _ = unlink(child.path); continue
            }
            guard child.pathExtension == "json", let id = UUID(uuidString: child.deletingPathExtension().lastPathComponent),
                  summaries[id] == nil else { continue }
            if let entry = try? read(id), entry.id == id {
                var summary = entry.summary
                summary.bytes = (try? regularSize(child, maximum: Self.maximumEntryBytes)) ?? 0
                summaries[id] = summary
            }
        }
        for summary in ordered.reversed() { current[summary.sessionKey] = summary.id }
        indexDirty = true
        try flush()
    }

    func accept(_ event: AgentEvent, session: AgentSession) throws -> Bool {
        guard policy.enabled, event.kind != .agentPresence else { return false }
        let key = try Self.sessionKey(event)
        let turn = event.turnID
        let turnKey = key + ":" + (turn ?? "")
        if turn != nil, blockedTurns.contains(turnKey) { return false }
        var content = (event.historyItems ?? []).compactMap { item -> AgentHistoryItem? in
            guard let text = SessionSnippet.text(item.text, limit: Self.maximumTextCharacters) else { return nil }
            return AgentHistoryItem(id: item.id, role: item.role, text: text)
        }
        if content.isEmpty && event.id?.hasPrefix("rollout:") != true {
            if let prompt = SessionSnippet.text(event.firstPrompt, limit: Self.maximumTextCharacters) {
                content.append(.init(id: "prompt:" + digest(prompt), role: .user, text: prompt))
            }
            // Permission payloads and tool lifecycle messages may contain raw
            // arguments/results. They are never treated as assistant replies.
            if [.working, .completed, .usageUpdated].contains(event.kind),
               let message = SessionSnippet.text(event.message, limit: Self.maximumTextCharacters),
               message != SessionSnippet.text(event.firstPrompt, limit: Self.maximumTextCharacters) {
                content.append(.init(id: "message:" + digest(message), role: .assistant, text: message))
            }
        }
        if !content.isEmpty, !content.contains(where: { $0.role == .user }),
           let prompt = SessionSnippet.text(event.firstPrompt, limit: Self.maximumTextCharacters) {
            content.insert(.init(id: "prompt:" + digest(prompt), role: .user, text: prompt), at: 0)
        }
        if turn == nil {
            if let prompt = content.first(where: { $0.role == .user }) {
                if blockedTurns.contains(key + ":prompt:" + digest(prompt.text)) { return false }
                blockedTurns = blockedTurns.filter { !$0.hasPrefix(key + ":prompt:") }
                blockedOrder = blockedOrder.filter { blockedTurns.contains($0) }
            } else if blockedTurns.contains(where: { $0.hasPrefix(key + ":prompt:") }) { return false }
        }
        var id = current[key]
        if let turn {
            id = summaries.values.first { $0.sessionKey == key && $0.turnID == turn }?.id
            // Attach a newly discovered native turn to the hook's open draft.
            if id == nil, let candidate = current[key], let summary = summaries[candidate],
               summary.turnID == nil, !isTerminal(summary.status) { id = candidate }
        } else if let candidate = id, let summary = summaries[candidate], isTerminal(summary.status),
                  [.working, .sessionStarted].contains(event.kind), content.contains(where: { $0.role == .user }) {
            id = nil
        }
        guard id != nil || !content.isEmpty else { return false }
        var record = try id.flatMap { try entry($0) } ?? HistoryEntry(summary: HistorySummary(
            id: UUID(), sessionKey: key, turnID: turn,
            title: SessionSnippet.text(event.firstPrompt ?? session.title, limit: 160) ?? session.provider,
            provider: session.provider, project: SessionSnippet.text(session.projectPath, limit: 4096),
            startedAt: event.timestamp, updatedAt: event.timestamp, status: session.status,
            memoryService: session.provider.lowercased() == "codex" && CodexServiceSessionFilter.isMemoryRequest(event.firstPrompt ?? session.title), bytes: 0))
        let before = record
        if let prompt = content.first(where: { $0.role == .user }),
           !record.items.contains(where: { $0.role == .user }) {
            record.summary.title = SessionSnippet.text(prompt.text, limit: 160) ?? record.summary.title
            record.summary.memoryService = session.provider.lowercased() == "codex" && CodexServiceSessionFilter.isMemoryRequest(prompt.text)
        }
        if let turn { record.summary.turnID = turn }
        record.summary.status = status(for: event, previous: summaries[record.id]?.status, fallback: session.status)
        for item in content {
            if item.text.count == Self.maximumTextCharacters && item.text.hasSuffix("…") { record.truncated = true }
            if let index = record.items.firstIndex(where: { $0.id == item.id && $0.role == item.role }) {
                record.items[index] = item
            } else if let index = record.items.firstIndex(where: {
                item.role != .command && $0.role == item.role && ($0.text == item.text ||
                    $0.text.hasPrefix(item.text.hasSuffix("…") ? String(item.text.dropLast()) : item.text) ||
                    item.text.hasPrefix($0.text.hasSuffix("…") ? String($0.text.dropLast()) : $0.text))
            }) {
                // Native stream and rollout/hook may describe the same item.
                // Keep the more complete copy, without appending each delta.
                if item.text.count > record.items[index].text.count { record.items[index].text = item.text }
            } else {
                record.items.append(item)
            }
        }
        guard record != before || summaries[record.id] == nil else { return false }
        record.summary.updatedAt = max(record.summary.updatedAt, event.timestamp)
        while record.items.count > 512 { record.items.remove(at: record.items.count > 2 ? 1 : 0); record.truncated = true }
        // An exceptionally long turn keeps its prompt and latest replies.
        while try encoder.encode(record).count > Self.maximumEntryBytes, record.items.count > 1 {
            record.items.remove(at: record.items.count > 2 ? 1 : 0); record.truncated = true
        }
        current[key] = record.id
        cache[record.id] = record; summaries[record.id] = record.summary; dirty.insert(record.id)
        indexDirty = true
        if cache.count > 8 { try flush() }
        return true
    }

    /// Repair only an existing identified turn from an explicit terminal event.
    /// Bootstrap must never import old conversations or alter the live session.
    func finish(_ event: AgentEvent) throws -> Bool {
        guard policy.enabled, let terminal = event.kind.historyTerminalStatus, let turn = event.turnID else { return false }
        let key = try Self.sessionKey(event)
        guard let summary = summaries.values.first(where: { $0.sessionKey == key && $0.turnID == turn }),
              !isTerminal(summary.status), var record = try entry(summary.id) else { return false }
        record.summary.status = terminal
        cache[record.id] = record
        summaries[record.id] = record.summary
        dirty.insert(record.id)
        indexDirty = true
        return true
    }

    static func sessionKey(_ event: AgentEvent) throws -> String {
        let data = try JSONEncoder().encode([event.provider.lowercased(), event.connectionID ?? "", event.sessionID])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func status(for event: AgentEvent, previous: AgentStatus?, fallback: AgentStatus) -> AgentStatus {
        if let previous, isTerminal(previous) { return previous }
        if let terminal = event.kind.historyTerminalStatus { return terminal }
        switch event.kind {
        case .working, .toolStarted: return .working
        case .waiting: return .waiting
        case .approvalRequested: return .approval
        case .sessionStarted: return .idle
        default: return previous ?? fallback
        }
    }

    func entry(_ id: UUID) throws -> HistoryEntry? {
        guard summaries[id] != nil else { return nil }
        return try cache[id] ?? read(id)
    }
    func setPolicy(_ value: HistoryPolicy) throws { policy = value; indexDirty = true; try flush() }
    func clear() throws {
        // Fence all known recent turns so a late full snapshot cannot recreate
        // the records the user just cleared, including after an app restart.
        for summary in ordered.prefix(256).reversed() {
            if let turn = summary.turnID { block(summary.sessionKey + ":" + turn) }
            else if let prompt = try entry(summary.id)?.items.first(where: { $0.role == .user }) {
                block(summary.sessionKey + ":prompt:" + digest(prompt.text))
            }
        }
        for id in summaries.keys { try removeFile(id) }
        cache.removeAll(); dirty.removeAll(); summaries.removeAll(); current.removeAll()
        indexDirty = true; try flush()
    }
    func flush() throws {
        for id in dirty {
            guard var entry = cache[id] else { continue }
            // bytes is an index-only accounting field; keep the record stable.
            entry.summary.bytes = 0; let data = try encoder.encode(entry)
            guard data.count <= Self.maximumEntryBytes else { throw CocoaError(.fileWriteOutOfSpace) }
            try write(data, to: url(id))
            var summary = entry.summary; summary.bytes = data.count
            summaries[id] = summary; cache[id] = entry
        }
        dirty.removeAll()
        while !summaries.isEmpty {
            let index = Index(entries: ordered, blockedTurns: blockedOrder)
            let overhead = try encoder.encode(index).count
            let total = summaries.values.reduce(overhead) { $0 + $1.bytes }
            guard summaries.count > policy.maximumCount || total > policy.maximumBytes || overhead > 4 * 1024 * 1024 else { break }
            guard let oldest = ordered.last else { break }
            if let turn = oldest.turnID { block(oldest.sessionKey + ":" + turn) }
            try removeFile(oldest.id)
            summaries[oldest.id] = nil; cache[oldest.id] = nil
            current = current.filter { $0.value != oldest.id }; indexDirty = true
        }
        if indexDirty {
            try write(encoder.encode(Index(entries: ordered, blockedTurns: blockedOrder)), to: indexURL)
            indexDirty = false
        }
        // Hot content is bounded separately from the much smaller metadata index.
        let keep = Set(ordered.prefix(8).map(\.id)); cache = cache.filter { keep.contains($0.key) }
    }

    private func isTerminal(_ status: AgentStatus) -> Bool { [.completed, .failed, .ended].contains(status) }
    private func block(_ value: String) {
        blockedOrder.removeAll { $0 == value }; blockedOrder.append(value)
        blockedOrder = Array(blockedOrder.suffix(256)); blockedTurns = Set(blockedOrder)
    }
    private func digest(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    private func read(_ id: UUID) throws -> HistoryEntry {
        let file = url(id); _ = try regularSize(file, maximum: Self.maximumEntryBytes)
        let entry = try JSONDecoder().decode(HistoryEntry.self, from: Data(contentsOf: file))
        guard entry.id == id else { throw CocoaError(.fileReadCorruptFile) }
        return entry
    }
    private func regularSize(_ file: URL, maximum: Int) throws -> Int {
        var info = stat()
        guard lstat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_size >= 0, info.st_size <= maximum else {
            throw CocoaError(.fileReadNoPermission)
        }
        return Int(info.st_size)
    }
    private func write(_ data: Data, to file: URL) throws {
        // The containing directory is private. Atomic replacement never follows
        // an existing destination symlink; temp files are also private.
        let temporary = directory.appendingPathComponent(".write-" + UUID().uuidString)
        defer { try? files.removeItem(at: temporary) }
        guard files.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        try data.write(to: temporary)
        guard rename(temporary.path, file.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }
    private func removeFile(_ id: UUID) throws {
        // Unlink the named entry, never recursively delete the archive directory.
        guard unlink(url(id).path) == 0 || errno == ENOENT else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }
}
