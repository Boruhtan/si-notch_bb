import Foundation
import SINotchCore

/// Keeps metadata-only updates from restoring an identified background request.
struct CodexServiceSessionFilter {
    private var ignored: Set<String> = []
    private var nativeInternal: Set<String> = []
    private var order: [String] = []
    private let capacity = 256

    mutating func hides(_ event: AgentEvent) -> Bool {
        guard event.provider.lowercased() == "codex" else { return false }
        if event.isInternalSession == true || Self.isSuggestionRequest(event.firstPrompt ?? event.title) {
            if event.isInternalSession == true { nativeInternal.insert(event.sessionID) }
            if ignored.insert(event.sessionID).inserted {
                order.append(event.sessionID)
                if order.count > capacity {
                    let oldest = order.removeFirst()
                    ignored.remove(oldest)
                    nativeInternal.remove(oldest)
                }
            }
            return true
        }
        // An explicit user turn can reuse a thread previously used by the app.
        if event.isInternalSession == false { nativeInternal.remove(event.sessionID) }
        if !nativeInternal.contains(event.sessionID), let prompt = event.firstPrompt,
           !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ignored.remove(event.sessionID)
            order.removeAll { $0 == event.sessionID }
        }
        return ignored.contains(event.sessionID)
    }

    /// SessionSource from the installed Codex protocol. Structured custom sources
    /// are user integrations; internal and subagent sources are implementation work.
    /// Unknown/future sources remain unclassified rather than hiding real tasks.
    static func nativeClassification(source: Any?, threadSource: Any? = nil) -> Bool? {
        if let threadSource = threadSource as? String,
           ["subagent", "guardian_review"].contains(threadSource) { return true }
        if let source = source as? [String: Any] {
            if source["internal"] != nil || source["subagent"] != nil { return true }
            if source["custom"] != nil { return false }
        }
        if let source = source as? String, ["cli", "vscode", "exec", "mcp"].contains(source) { return false }
        if let threadSource = threadSource as? String {
            if ["user", "realtime_voice", "voice_chat", "agent_created_thread", "avatar_quick_chat", "chatgpt_handoff"].contains(threadSource) { return false }
        }
        return nil
    }

    static func isSuggestionRequest(_ value: String?) -> Bool {
        normalizedPrefix(value).hasPrefix("this is an app-generated request for a suggested next user message. the user did not write this")
    }

    /// Observed memory-job signatures. Folder names and model names do not
    /// establish provenance; quoted instructions in a user task do not match.
    static func isMemoryRequest(_ value: String?) -> Bool {
        let prefix = normalizedPrefix(value)
        return prefix.hasPrefix("## memory writing agent: phase 2 (consolidation)") ||
            prefix.hasPrefix("consolidate the supplied rollout summaries into `memory_summary.md`")
    }

    private static func normalizedPrefix(_ value: String?) -> String {
        (value ?? "").prefix(512).split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .replacingOccurrences(of: "‑", with: "-").lowercased()
    }
}
