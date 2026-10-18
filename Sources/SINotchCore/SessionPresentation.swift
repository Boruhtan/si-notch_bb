import Foundation

/// User-supplied filters use literal, case-insensitive text, never regular expressions.
public struct SessionFilter: Sendable {
    public let directories: [String]
    public let promptPrefixes: [String]
    public init(directories: String = "", promptPrefixes: String = "") {
        func lines(_ value: String) -> [String] {
            value.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.prefix(128).map { String($0.prefix(4096)) }
        }
        self.directories = lines(directories)
        self.promptPrefixes = lines(promptPrefixes)
    }
    public func hides(path: String?, firstPrompt: String?) -> Bool {
        if let path, directories.contains(where: { path.localizedCaseInsensitiveContains($0) }) { return true }
        if let firstPrompt, promptPrefixes.contains(where: { firstPrompt.lowercased().hasPrefix($0.lowercased()) }) { return true }
        return false
    }
}

/// One reminder for an unchanged unread state, using a monotonic deadline.
public struct FollowUpReminders: Sendable {
    private struct Entry: Sendable { let status: AgentStatus; let due: TimeInterval }
    private var entries: [String: Entry] = [:]
    public init() {}
    public mutating func update(id: String, status: AgentStatus, now: TimeInterval, delay: TimeInterval, includeCompleted: Bool) {
        entries.removeValue(forKey: id)
        guard delay.isFinite, delay > 0, [.approval, .waiting].contains(status) || (includeCompleted && status == .completed) else { return }
        entries[id] = Entry(status: status, due: now + delay)
    }
    public mutating func cancel(_ id: String) { entries.removeValue(forKey: id) }
    public mutating func due(now: TimeInterval, states: [String: AgentStatus], foregroundIDs: Set<String> = []) -> [String] {
        var result: [String] = []
        for (id, entry) in entries {
            guard states[id] == entry.status else { entries.removeValue(forKey: id); continue }
            if foregroundIDs.contains(id) { entries.removeValue(forKey: id); continue }
            if now >= entry.due { entries.removeValue(forKey: id); result.append(id) }
        }
        return result.sorted()
    }
}
