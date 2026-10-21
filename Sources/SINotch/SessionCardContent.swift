import Foundation
import SINotchCore

/// Display-only projections of supplied session metadata. Missing data stays missing.
struct SessionCardContent: Equatable {
    let primaryTitle: String
    let providerName: String
    let shortID: String
    let projectName: String?
    let projectIsTitle: Bool
    let tool: String?
    let toolSymbol: String
    let summary: String?
    let message: String?
    let taskPrompt: String?
    let modelName: String?
    let reasoningEffort: String?
    let isMemoryService: Bool

    init(session: AgentSession, displayTitle: String? = nil, displayMessage: String? = nil, statusLabel: String? = nil) {
        providerName = session.provider.lowercased() == "codex" && session.isWorkSession == true ? "Work" : Self.providerName(session.provider)
        modelName = Self.singleLine(session.modelName, limit: 256)
        reasoningEffort = Self.singleLine(session.reasoningEffort, limit: 128)
        isMemoryService = session.provider.lowercased() == "codex" &&
            CodexServiceSessionFilter.isMemoryRequest(session.firstPrompt ?? session.title)
        shortID = String(session.id.suffix(8))
        projectName = session.projectPath.flatMap { path in
            guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return Self.singleLine(URL(fileURLWithPath: path).lastPathComponent, limit: 160)
        }
        let suppliedTitle = Self.singleLine(displayTitle ?? session.title, limit: 512)
        let prompt = Self.clean(session.firstPrompt)
        let task = session.tasks.first(where: { !$0.completed }) ?? session.tasks.last
        let candidates = [suppliedTitle, Self.singleLine(prompt, limit: 160), Self.singleLine(task?.title, limit: 160)]
        let meaningful = candidates.compactMap { $0 }.first { !Self.isGeneric($0, provider: session.provider) }
        let resolvedTitle = String((meaningful ?? projectName ?? providerName).prefix(160))
        primaryTitle = resolvedTitle
        projectIsTitle = projectName.map { Self.canonical($0) == Self.canonical(resolvedTitle) } ?? false
        tool = Self.singleLine(session.currentTool, limit: 120)
        toolSymbol = Self.symbol(for: tool)

        let rawMessage = Self.clean(displayMessage ?? session.lastMessage)
        let duplicates = [suppliedTitle, prompt, statusLabel, providerName, primaryTitle].compactMap { $0 }.map(Self.canonical)
        if let rawMessage, !duplicates.contains(Self.canonical(rawMessage)) {
            message = rawMessage
            summary = Self.singleLine(rawMessage, limit: 240)
        } else {
            message = nil
            summary = nil
        }
        if let prompt, Self.canonical(prompt) != Self.canonical(primaryTitle),
           Self.canonical(prompt) != Self.canonical(message ?? "") {
            taskPrompt = prompt
        } else { taskPrompt = nil }
    }

    /// Conservative budget for a two-line title and optional two-line update.
    /// The real list remains scrollable; expanded task/usage/request sections vary.
    func estimatedCollapsedHeight(fontSize: Double = 11, showActivity: Bool = true,
                                  showModel: Bool = true, showReasoning: Bool = true) -> Double {
        let messageLine = max(10, min(16, fontSize)) * 1.4
        let metadata = (showModel && modelName != nil) || (showReasoning && reasoningEffort != nil)
        return 108 + (metadata ? messageLine + 7 : 0) + (showActivity && summary != nil ? messageLine * 2 + 7 : 0)
    }

    static func providerName(_ rawValue: String) -> String {
        switch rawValue.lowercased() {
        case "codex": "Codex"
        case "pi": "Pi"
        case "claude": "Claude Code"
        case "opencode": "OpenCode"
        case "hermes": "Hermes"
        case "gemini": "Gemini CLI"
        case "copilot": "Copilot CLI"
        case "cursor": "Cursor Agent"
        default: rawValue
        }
    }

    private static func isGeneric(_ title: String, provider: String) -> Bool {
        let value = canonical(title)
        let agent = canonical(provider)
        let brand = canonical(providerName(provider))
        return ["agent", "agentsession", "session", "newsession", "untitled", "task",
                agent, brand, agent + "session", agent + "agent", agent + "cli", brand + "session", brand + "agent"].contains(value)
    }

    private static func canonical(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let bounded = String(value.prefix(4096)).replacingOccurrences(of: "\u{001B}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
        let scalars = bounded.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t" }
        let cleaned = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func singleLine(_ value: String?, limit: Int) -> String? {
        guard let value = clean(value) else { return nil }
        return String(value.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(limit))
    }

    private static func symbol(for tool: String?) -> String {
        let name = tool?.lowercased() ?? ""
        if ["bash", "shell", "terminal", "exec", "command"].contains(where: name.contains) { return "terminal" }
        if ["grep", "glob", "search", "find"].contains(where: name.contains) { return "magnifyingglass" }
        if ["write", "edit", "patch"].contains(where: name.contains) { return "square.and.pencil" }
        if ["read", "file"].contains(where: name.contains) { return "doc.text" }
        if ["web", "fetch", "browser"].contains(where: name.contains) { return "globe" }
        if ["subagent", "spawn", "delegate"].contains(where: name.contains) { return "person.2" }
        if ["plan", "todo", "task"].contains(where: name.contains) { return "checklist" }
        return "wrench.and.screwdriver"
    }
}
