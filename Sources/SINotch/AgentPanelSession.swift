import SINotchCore

struct AgentPanelSession: Identifiable {
    let session: AgentSession
    var profileName: String? = nil
    var id: String { session.id }

    static func rows(in session: AgentSession) -> Int { 1 + session.tasks.count + session.subagents.count }

    static func byProfile(_ sessions: [AgentSession], excludingHostSessions claims: [String: AgentHostApplication]) -> [String: [AgentSession]] {
        Dictionary(grouping: sessions.filter { AgentConnection.isActiveTask($0) && claims[$0.id] == nil },
                   by: AgentConnection.identity).mapValues(roots)
    }

    /// An explicit link suppresses a duplicate session only within the same agent identity.
    static func roots(_ sessions: [AgentSession]) -> [AgentSession] {
        let identities = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, AgentConnection.identity(for: $0)) })
        let nested = Set(sessions.flatMap { parent in
            parent.subagents.compactMap { child -> String? in
                guard let id = child.sessionID, id != parent.id, identities[id] == identities[parent.id] else { return nil }
                return id
            }
        })
        return sessions.filter { !nested.contains($0.id) }
    }
}
