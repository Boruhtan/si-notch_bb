import Foundation

/// Metadata-only adapters for the documented local CLI hook protocols.
public enum HarnessHook {
    public static let events: [String: [String: AgentEventKind]] = [
        "gemini": ["SessionStart": .sessionStarted, "BeforeAgent": .working,
                   "AfterAgent": .completed, "Notification": .waiting, "SessionEnd": .sessionEnded],
        "copilot": ["sessionStart": .sessionStarted, "userPromptSubmitted": .working,
                    "agentStop": .completed, "notification": .waiting, "sessionEnd": .sessionEnded],
        "cursor": ["sessionStart": .sessionStarted, "beforeSubmitPrompt": .working,
                   "stop": .completed, "sessionEnd": .sessionEnded]
    ]

    public static func observation(provider: String, hook: String, raw: [String: Any],
                                   timestamp: Date = Date()) throws -> AgentEvent? {
        guard var kind = events[provider]?[hook] else { return nil }
        if let supplied = raw["hook_event_name"] as? String, supplied != hook { return nil }
        let session = provider == "cursor"
            ? (raw["conversation_id"] ?? raw["session_id"]) as? String
            : (raw["sessionId"] ?? raw["session_id"]) as? String
        guard let session else { return nil }
        if provider == "gemini", hook == "Notification", raw["notification_type"] as? String != "ToolPermission" { return nil }
        if provider == "copilot", hook == "notification",
           !["permission_prompt", "elicitation_dialog"].contains(raw["notification_type"] as? String ?? "") { return nil }
        if provider == "cursor", hook == "stop" {
            switch raw["status"] as? String {
            case "completed": kind = .completed
            case "error": kind = .failed
            case "aborted": kind = .waiting
            default: return nil
            }
        }
        var cwd = raw["cwd"] as? String
        if provider == "cursor" {
            let roots = raw["workspace_roots"] as? [String]
            cwd = roots?.count == 1 ? roots?.first : nil
        }
        if let path = cwd, !path.hasPrefix("/") || path.utf8.count > 4096 || path.contains("\0") { cwd = nil }
        let event = AgentEvent(sessionID: session, provider: provider, kind: kind,
                               timestamp: timestamp, projectPath: cwd)
        try event.validate()
        return event
    }
}
