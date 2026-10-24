import Foundation
import SINotchCore

/// Provider availability is independent of the tasks shown in the island.
struct AgentConnection: Identifiable, Equatable {
    struct LocalIdentity: Hashable {
        let provider: String
        let connectionID: String
    }
    struct Observation: Equatable {
        let provider: String
        let connectionID: String
        let name: String
        let lastSeen: Date
        let eventAt: Date
        let eventID: String?
        var id: String { provider + "/" + connectionID }
    }
    struct Configuration {
        let connectionID: String
        let name: String
        let connectorID: UUID
        let visible: Bool
        var transportState: RemoteConnectionState? = nil
    }
    enum State: String {
        case online, lastSeen, installed, offline
        var label: String {
            switch self {
            case .online: L10n.tr("agents.state.online")
            case .lastSeen: L10n.tr("agents.state.lastSeen")
            case .installed: L10n.tr("agents.state.installed")
            case .offline: L10n.tr("agents.state.offline")
            }
        }
    }
    enum Activity: String {
        case unknown, idle, working, attention
        var label: String {
            switch self {
            case .unknown: L10n.tr("agents.activity.unknown")
            case .idle: L10n.tr("agents.activity.idle")
            case .working: L10n.tr("agents.activity.working")
            case .attention: L10n.tr("agents.activity.attention")
            }
        }
    }
    let id: String
    let provider: String
    let displayName: String?
    let state: State
    let lastSeen: Date?
    var connectorID: UUID? = nil
    var activity: Activity = .unknown
    var activeTaskCount = 0
    var name: String { displayName ?? HarnessKind(rawValue: provider)?.displayName ?? provider }

    static func runningProviders(detected: [HarnessDetection], applicationPaths: Set<String>,
                                 bundleIdentifiers: Set<String>) -> Set<String> {
        var providers = Set(detected.filter { detection in
            detection.locations.contains { $0.kind == .application && applicationPaths.contains($0.resolvedURL.path) }
        }.map(\.id))
        // Distribution names can change; the app's identity does not depend on
        // whether its bundle is named Codex.app or ChatGPT.app.
        if bundleIdentifiers.contains("com.openai.codex") { providers.insert("codex") }
        return providers
    }

    static func isTask(_ session: AgentSession) -> Bool {
        guard session.status != .idle && session.status != .ended else { return false }
        // Lifecycle-only Desktop fallback has no task context. Keep its provider
        // in Agents until the public-content stream or rollout supplies a task.
        if session.provider == "codex", session.lastEventID?.hasPrefix("desktop:") == true,
           session.title == "Codex Desktop", session.firstPrompt == nil,
           session.lastMessage == nil, session.tasks.isEmpty { return false }
        return true
    }

    static func project(detected: [HarnessDetection], sessions: [AgentSession],
                        receipts: [String: Date], running: Set<String>, now: Date,
                        connections: [String: Observation] = [:],
                        configurations: [Configuration] = [],
                        localDisplayNames: [String: String] = [:],
                        localIdentities: Set<LocalIdentity> = []) -> [Self] {
        let installed = Set(detected.filter(\.isDetected).map(\.id))
        let legacySessions = sessions.filter { $0.connectionID == nil }
        let configured = Dictionary(configurations.map { ($0.connectionID, $0) }, uniquingKeysWith: { first, _ in first })
        func isFresh(_ date: Date) -> Bool {
            let age = now.timeIntervalSince(date)
            return age >= -5 && age <= 120
        }
        // An unconfigured announcement is not proof of locality: it can arrive
        // through SSH too. Only identities read from this Mac's plugin settings
        // can represent its installed/running app. Saved SSH ownership wins.
        let representedLocally = Set(connections.values.filter {
            localIdentities.contains(LocalIdentity(provider: $0.provider, connectionID: $0.connectionID)) &&
                configured[$0.connectionID] == nil && isFresh($0.lastSeen)
        }.map(\.provider))
        let providers = installed.union(legacySessions.map(\.provider))
            .union(receipts.keys).union(running)
        let legacy = providers.filter { provider in
            // Completed/idle historical sessions must not resurrect an app-only
            // duplicate. Independent unscoped work keeps its own row and tasks.
            !representedLocally.contains(provider) || legacySessions.contains {
                $0.provider == provider && isTask($0) &&
                    [.working, .waiting, .approval, .failed].contains($0.status)
            }
        }.map { provider in
            let observations = legacySessions.filter { $0.provider == provider }
            let latest = observations.max { $0.lastEventAt < $1.lastEventAt }
            let seen = receipts[provider] ?? latest?.lastEventAt
            // A quiet hook cannot prove that its process is still running. Only
            // fresh events or an observed native app establish online presence.
            let fresh = receipts[provider].map(isFresh) ?? false
            let ended = !observations.isEmpty && observations.allSatisfy { $0.status == .ended }
            let appOnlyPresence = running.contains(provider) && !representedLocally.contains(provider)
            let state: State = appOnlyPresence || (fresh && !ended) ? .online :
                ended ? .offline : seen != nil ? .lastSeen : .installed
            // Local labels affect only the legacy provider row, never named/SSH profiles.
            let displayName = localDisplayNames[provider].flatMap { value -> String? in
                let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, name.count <= 128,
                      !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
                return name
            }
            return Self(id: provider, provider: provider, displayName: displayName, state: state, lastSeen: seen)
        }
        // Local configuration owns grouping and display names. Incoming events cannot
        // impersonate another saved SSH connector by supplying a group name.
        let observedIDs = Set(connections.values.map(\.connectionID))
        let named = connections.values.compactMap { observation -> Self? in
            let config = configured[observation.connectionID]
            if config?.visible == false { return nil }
            let age = now.timeIntervalSince(observation.lastSeen)
            let connected = config?.transportState.map { $0 == .connected } ?? true
            return Self(id: observation.id, provider: observation.provider, displayName: config?.name ?? observation.name,
                        state: connected && age >= -5 && age <= 120 ? .online : .lastSeen, lastSeen: observation.lastSeen,
                        connectorID: config?.connectorID)
        }
        let quiet = configured.values.filter { $0.visible && !observedIDs.contains($0.connectionID) }.map {
            Self(id: "hermes/" + $0.connectionID, provider: "hermes", displayName: $0.name,
                 state: .installed, lastSeen: nil, connectorID: $0.connectorID)
        }
        return (legacy + named + quiet).map { agent in
            var agent = agent
            guard agent.state == .online else { return agent }
            let active = sessions.filter { session in
                let identity = session.connectionID.map { session.provider + "/" + $0 } ?? session.provider
                return identity == agent.id && Self.isTask(session) &&
                    [.working, .waiting, .approval, .failed].contains(session.status)
            }
            agent.activeTaskCount = active.count
            agent.activity = active.contains { [.waiting, .approval, .failed].contains($0.status) } ? .attention :
                active.isEmpty ? .idle : .working
            return agent
        }.sorted {
            if ($0.state == .online) != ($1.state == .online) { return $0.state == .online }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}
