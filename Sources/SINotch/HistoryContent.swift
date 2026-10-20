import Foundation
import SINotchCore

/// Selection happens at the source, before tool arguments/results are dropped.
/// Never archive generic argument dictionaries or command output.
enum HistoryContent {
    static func message(id: String, role: AgentHistoryItem.Role, content: Any?) -> AgentHistoryItem? {
        SessionSnippet.message(content, limit: HistoryStore.maximumTextCharacters)
            .map { AgentHistoryItem(id: id, role: role, text: $0) }
    }
    static func command(id: String, name: String, arguments: Any?) -> AgentHistoryItem? {
        let name = name.split(separator: ".").last.map(String.init) ?? name
        var arguments = arguments
        if let text = arguments as? String, let data = text.data(using: .utf8), data.count <= AgentEvent.maximumPayloadBytes {
            arguments = (try? JSONSerialization.jsonObject(with: data)) ?? text
        }
        let object = arguments as? [String: Any]
        let command: String?
        switch name {
        case "exec_command", "shell_command": command = object?["cmd"] as? String ?? object?["command"] as? String
        case "shell", "bash", "terminal":
            command = object?["command"] as? String ?? (object?["command"] as? [String])?.joined(separator: " ")
        // These are executable script tools, rather than arbitrary MCP inputs.
        case "exec", "js": command = arguments as? String ?? object?["code"] as? String
        default: command = nil
        }
        return SessionSnippet.text(command, limit: HistoryStore.maximumTextCharacters)
            .map { .init(id: id, role: .command, text: $0) }
    }
    static func bounded(_ items: [AgentHistoryItem]) -> [AgentHistoryItem] {
        var bytes = 0
        return items.suffix(64).reversed().filter {
            bytes += $0.text.utf8.count
            return bytes <= 96 * 1024
        }.reversed()
    }
}
