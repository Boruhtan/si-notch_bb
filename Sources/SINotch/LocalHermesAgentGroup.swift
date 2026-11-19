import Foundation

/// Presentation only. Grouping never changes agent identity, presence or task ownership.
struct LocalHermesAgentGroup: Equatable {
    static let id = "local-hermes"
    let name: String
    let profiles: [AgentConnection]
    var onlineCount: Int { profiles.filter { $0.state == .online }.count }

    static func project(agents: [AgentConnection], inventory: [LocalHermesProfile],
                        observations: [String: AgentConnection.Observation], hostName: String) -> Self? {
        let registered = Set(inventory.map(\.id))
        let confirmed = Set(observations.values.filter { $0.provider == "hermes" && $0.origin == .local }.map(\.id))
        let profiles = agents.filter {
            $0.provider == "hermes" && $0.connectorID == nil &&
                (registered.contains($0.id) || confirmed.contains($0.id))
        }
        guard !profiles.isEmpty else { return nil }
        let ids = Set(profiles.map(\.id))
        let primary = inventory.first { $0.isDefault && ids.contains($0.id) }?.name ?? "Hermes"
        return Self(name: hostName + " · " + primary, profiles: profiles)
    }
}
