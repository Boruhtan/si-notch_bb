import Foundation

/// Explicit text content for the local archive. Tool results and reasoning have
/// no representation here; adapters must select only these three public roles.
public struct AgentHistoryItem: Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable { case user, assistant, command }
    public var id: String
    public var role: Role
    public var text: String
    public init(id: String, role: Role, text: String) {
        self.id = id; self.role = role; self.text = text
    }
}
