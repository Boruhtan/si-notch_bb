import CoreFoundation
import Darwin
import Foundation
import SINotchCore

/// Evidence for one existing goal archive, independent of any resumed turn.
struct CodexGoalHistoryCompletion: Equatable {
    let sessionKey: String
    let originalTurnID: String
    let createdAt: Date
    let completedAt: Date
    let objective: String
}

/// Reads only rollouts belonging to existing /goal archives. Each call has a
/// shared byte budget; cursors retain no transcript or generic tool output.
struct CodexGoalHistoryScanner {
    private struct Goal: Equatable {
        let created: TimeInterval
        let objective: String
        let turnID: String
    }
    private struct Cursor {
        let inode: UInt64
        let sessionID: String
        let sessionKey: String
        var offset: UInt64 = 0
        var partial = Data()
        var discarding = false
        var validated = false
        var rejected = false
        var turnID: String?
        var turnStartedAt: Date?
        var goals: [Goal] = []
        var pendingCalls: Set<String> = []
        var completed: Set<TimeInterval> = []
    }
    private struct Candidate {
        let url: URL
        let metadata: SessionFileMetadata
        let sessionID: String
        let sessionKey: String
    }
    let sessionsRoot: URL
    private(set) var hasPendingBytes = false
    private var cursors: [String: Cursor] = [:]
    private var targetTurns: [String: Set<String>] = [:]
    private var directories = SessionDirectoryCache()
    private var discovered: [Candidate] = []
    private var discoveryKeys: Set<String> = []
    private var discoveredAt = Date.distantPast
    private let maximumLineBytes = 256 * 1024

    init(sessionsRoot: URL) {
        self.sessionsRoot = sessionsRoot.standardizedFileURL.resolvingSymlinksInPath()
    }

    static func isGoalTitle(_ title: String) -> Bool {
        title.hasPrefix("/goal") && title.dropFirst(5).first?.isWhitespace == true
    }

    static func title(_ title: String, matches objective: String) -> Bool {
        guard isGoalTitle(title), let safe = SessionSnippet.text(objective, limit: HistoryStore.maximumTextCharacters) else { return false }
        let excerpt = String(title.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
        if excerpt.hasSuffix("…") {
            let prefix = String(excerpt.dropLast())
            return !prefix.isEmpty && safe.hasPrefix(prefix)
        }
        return excerpt == safe
    }

    mutating func poll(targets: [HistorySummary], maximumBytes: Int = 1024 * 1024) -> [CodexGoalHistoryCompletion] {
        let targets = targets.filter {
            $0.provider.lowercased() == "codex" && $0.status != .completed &&
                $0.turnID.flatMap(UUID.init(uuidString:)) != nil && Self.isGoalTitle($0.title)
        }
        hasPendingBytes = false
        guard !targets.isEmpty else { cursors.removeAll(); targetTurns.removeAll(); return [] }
        let turns = Dictionary(grouping: targets, by: \.sessionKey).mapValues { Set($0.compactMap(\.turnID)) }
        let addedKeys = Set(turns.compactMap { key, value in
            value.isSubset(of: targetTurns[key] ?? []) ? nil : key
        })
        // A new archive may appear after its creation event was already read.
        // Reconstruct only the affected session, preserving all other cursors.
        cursors = cursors.filter { !addedKeys.contains($0.value.sessionKey) }
        targetTurns = turns
        let keys = Set(targets.map(\.sessionKey))
        let candidates = candidates(keys: keys)
        cursors = cursors.filter { key, _ in candidates.contains { $0.url.path == key } }
        var remaining = min(4 * 1024 * 1024, max(0, maximumBytes))
        var result: [CodexGoalHistoryCompletion] = []
        for candidate in candidates {
            let path = candidate.url.path
            var cursor = cursors[path] ?? Cursor(inode: candidate.metadata.inode,
                sessionID: candidate.sessionID, sessionKey: candidate.sessionKey)
            if cursor.inode != candidate.metadata.inode || candidate.metadata.size < cursor.offset {
                cursor = Cursor(inode: candidate.metadata.inode, sessionID: candidate.sessionID,
                    sessionKey: candidate.sessionKey)
            }
            guard !cursor.rejected else { cursors[path] = cursor; continue }
            var readFailed = false
            if remaining > 0, candidate.metadata.size > cursor.offset {
                let count = min(remaining, Int(min(UInt64(remaining), candidate.metadata.size - cursor.offset)))
                if let bytes = read(candidate, offset: cursor.offset, count: count), !bytes.isEmpty {
                    cursor.offset += UInt64(bytes.count)
                    remaining -= bytes.count
                    consume(bytes, cursor: &cursor, targets: targets, into: &result)
                } else { readFailed = true }
            }
            if !cursor.rejected, !readFailed, cursor.offset < candidate.metadata.size { hasPendingBytes = true }
            cursors[path] = cursor
        }
        return result
    }

    private mutating func candidates(keys: Set<String>) -> [Candidate] {
        // Existing files need only lstat. New rollout discovery is infrequent;
        // directory memberships themselves are also cached by metadata.
        if keys == discoveryKeys, Date().timeIntervalSince(discoveredAt) < 30 {
            return discovered.compactMap { old in
                guard safeParents(old.url), let metadata = SessionFileMetadata(old.url),
                      metadata.isRegularFile, metadata.owner == getuid() else { return nil }
                return Candidate(url: old.url, metadata: metadata, sessionID: old.sessionID, sessionKey: old.sessionKey)
            }
        }
        var folders = [sessionsRoot]
        for width in [4, 2, 2] {
            folders = folders.flatMap { folder in
                directories.contents(of: folder).filter {
                    $0.lastPathComponent.count == width &&
                        $0.lastPathComponent.utf8.allSatisfy { (48...57).contains($0) } &&
                        SessionFileMetadata($0)?.isDirectory == true
                }
            }
        }
        var found: [Candidate] = []
        for folder in folders {
            for url in directories.contents(of: folder) where url.lastPathComponent.hasPrefix("rollout-") && url.pathExtension == "jsonl" {
                let id = String(url.deletingPathExtension().lastPathComponent.suffix(36)).lowercased()
                guard UUID(uuidString: id) != nil,
                      let key = try? HistoryStore.sessionKey(AgentEvent(sessionID: id, provider: "codex", kind: .completed)),
                      keys.contains(key), safeParents(url), let metadata = SessionFileMetadata(url),
                      metadata.isRegularFile, metadata.owner == getuid() else { continue }
                found.append(Candidate(url: url, metadata: metadata, sessionID: id, sessionKey: key))
            }
        }
        discovered = found.sorted { $0.url.path < $1.url.path }
        discoveryKeys = keys; discoveredAt = Date()
        return discovered
    }

    private func safeParents(_ url: URL) -> Bool {
        var parent = url.deletingLastPathComponent()
        for _ in 0..<3 {
            guard SessionFileMetadata(parent)?.isDirectory == true else { return false }
            parent.deleteLastPathComponent()
        }
        return parent.standardizedFileURL.path == sessionsRoot.path && SessionFileMetadata(parent)?.isDirectory == true
    }

    private func read(_ candidate: Candidate, offset: UInt64, count: Int) -> Data? {
        let descriptor = open(candidate.url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), UInt64(info.st_ino) == candidate.metadata.inode else { return nil }
        do { try handle.seek(toOffset: offset); return try handle.read(upToCount: count) }
        catch { return nil }
    }

    private func consume(_ bytes: Data, cursor: inout Cursor, targets: [HistorySummary],
                         into result: inout [CodexGoalHistoryCompletion]) {
        let buffer = cursor.partial + bytes
        cursor.partial.removeAll(keepingCapacity: true)
        var start = buffer.startIndex
        while let end = buffer[start...].firstIndex(of: 10) {
            if !cursor.discarding, end - start <= maximumLineBytes,
               let record = try? JSONSerialization.jsonObject(with: Data(buffer[start..<end])) as? [String: Any] {
                consume(record, cursor: &cursor, targets: targets, into: &result)
            } else if !cursor.validated { cursor.rejected = true }
            cursor.discarding = false
            start = buffer.index(after: end)
        }
        if buffer.endIndex - start > maximumLineBytes { cursor.discarding = true }
        else if !cursor.discarding { cursor.partial = Data(buffer[start...]) }
    }

    private func consume(_ record: [String: Any], cursor: inout Cursor, targets: [HistorySummary],
                         into result: inout [CodexGoalHistoryCompletion]) {
        guard !cursor.rejected, let type = record["type"] as? String,
              let payload = record["payload"] as? [String: Any] else { return }
        if !cursor.validated {
            guard type == "session_meta", (payload["id"] as? String)?.lowercased() == cursor.sessionID,
                  payload["parent_thread_id"] == nil || payload["parent_thread_id"] is NSNull,
                  CodexServiceSessionFilter.nativeClassification(source: payload["source"]) != true else {
                cursor.rejected = true; return
            }
            cursor.validated = true
            return
        }
        guard let stamp = Self.date(record["timestamp"]) else { return }
        if type == "event_msg" {
            switch payload["type"] as? String {
            case "task_started":
                cursor.turnID = (payload["turn_id"] as? String).flatMap { UUID(uuidString: $0)?.uuidString.lowercased() }
                cursor.turnStartedAt = stamp
            case "task_complete", "turn_aborted", "turn_cancelled":
                if payload["turn_id"] == nil || (payload["turn_id"] as? String)?.lowercased() == cursor.turnID {
                    cursor.turnID = nil; cursor.turnStartedAt = nil
                }
            case "thread_goal_updated":
                guard (payload["threadId"] as? String)?.lowercased() == cursor.sessionID,
                      let value = payload["goal"] as? [String: Any] else { return }
                goal(value, stamp: stamp, canCreate: true, cursor: &cursor, targets: targets, into: &result)
            default: break
            }
        } else if type == "response_item", let kind = payload["type"] as? String,
                  let call = payload["call_id"] as? String, !call.isEmpty, call.utf8.count <= 256 {
            if ["custom_tool_call", "function_call"].contains(kind), Self.isCompletionCall(payload) {
                if cursor.pendingCalls.count < 32 { cursor.pendingCalls.insert(call) }
            } else if ["custom_tool_call_output", "function_call_output"].contains(kind),
                      cursor.pendingCalls.remove(call) != nil {
                for value in Self.outputGoals(payload["output"]) {
                    goal(value, stamp: stamp, canCreate: false, cursor: &cursor, targets: targets, into: &result)
                }
            }
        }
    }

    private func goal(_ value: [String: Any], stamp: Date, canCreate: Bool, cursor: inout Cursor,
                      targets: [HistorySummary], into result: inout [CodexGoalHistoryCompletion]) {
        guard (value["threadId"] as? String)?.lowercased() == cursor.sessionID,
              let objective = value["objective"] as? String, !objective.isEmpty, objective.utf8.count <= 64 * 1024,
              let created = Self.seconds(value["createdAt"]), let updated = Self.seconds(value["updatedAt"]),
              updated >= created, updated <= stamp.timeIntervalSince1970 + 1,
              let status = value["status"] as? String else { return }
        if canCreate, status == "active", created == updated,
           abs(stamp.timeIntervalSince1970 - created) < 2,
           let turn = cursor.turnID, let started = cursor.turnStartedAt,
           created >= floor(started.timeIntervalSince1970), created - started.timeIntervalSince1970 <= 300,
           targets.contains(where: { $0.sessionKey == cursor.sessionKey && $0.turnID?.lowercased() == turn && Self.title($0.title, matches: objective) }),
           !cursor.goals.contains(where: { $0.created == created }) {
            cursor.goals.append(Goal(created: created, objective: objective, turnID: turn))
        }
        guard status == "complete", !cursor.completed.contains(created),
              let goal = cursor.goals.first(where: { $0.created == created && $0.objective == objective }),
              targets.contains(where: { $0.sessionKey == cursor.sessionKey && $0.turnID?.lowercased() == goal.turnID && Self.title($0.title, matches: objective) }) else { return }
        cursor.completed.insert(created)
        result.append(CodexGoalHistoryCompletion(sessionKey: cursor.sessionKey, originalTurnID: goal.turnID,
            createdAt: Date(timeIntervalSince1970: created), completedAt: Date(timeIntervalSince1970: updated), objective: objective))
    }

    private static func seconds(_ value: Any?) -> TimeInterval? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        return value.isFinite && value > 0 && value.rounded(.down) == value ? value : nil
    }
    private static func date(_ value: Any?) -> Date? {
        guard let value = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
    private static let completionScript = try! NSRegularExpression(pattern:
        #"^\s*(?:text\(\s*await\s+tools\.update_goal\(\s*\{\s*["']?status["']?\s*:\s*["']complete["']\s*\}\s*\)\s*\)|await\s+tools\.update_goal\(\s*\{\s*["']?status["']?\s*:\s*["']complete["']\s*\}\s*\))\s*;?\s*$"#)
    private static func isCompletionCall(_ payload: [String: Any]) -> Bool {
        if payload["type"] as? String == "custom_tool_call", ["exec", "functions.exec"].contains(payload["name"] as? String ?? ""),
           let input = payload["input"] as? String, input.utf8.count <= 1024 {
            return completionScript.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)) != nil
        }
        guard payload["type"] as? String == "function_call", ["update_goal", "functions.update_goal"].contains(payload["name"] as? String ?? ""),
              let arguments = payload["arguments"] as? String, arguments.utf8.count <= 1024,
              let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return Set(object.keys) == ["status"] && object["status"] as? String == "complete"
    }
    private static func outputGoals(_ output: Any?) -> [[String: Any]] {
        let texts: [String]
        if let output = output as? String { texts = [output] }
        else if let blocks = output as? [[String: Any]], blocks.count <= 16 {
            texts = blocks.compactMap { $0["type"] as? String == "input_text" ? $0["text"] as? String : nil }
        } else { return [] }
        return texts.compactMap { text in
            guard text.utf8.count <= 128 * 1024, let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(object.keys) == ["goal", "remainingTokens", "completionBudgetReport"],
                  let goal = object["goal"] as? [String: Any] else { return nil }
            return goal
        }
    }
}
