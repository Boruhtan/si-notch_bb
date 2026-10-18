import Foundation
import SINotchCore

/// Provider availability is independent of the tasks shown in the island.
struct AgentConnection: Identifiable, Equatable {
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
    let id: String
    let provider: String
    let displayName: String?
    let state: State
    let lastSeen: Date?
    var connectorID: UUID? = nil
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
                        configurations: [Configuration] = []) -> [Self] {
        let installed = Set(detected.filter(\.isDetected).map(\.id))
        let namedProviders = Set(connections.values.map(\.provider))
        let legacySessions = sessions.filter { $0.connectionID == nil }
        let providers = installed.union(legacySessions.map(\.provider))
            .union(receipts.keys.filter { !namedProviders.contains($0) }).union(running)
        let legacy = providers.map { provider in
            let observations = legacySessions.filter { $0.provider == provider }
            let latest = observations.max { $0.lastEventAt < $1.lastEventAt }
            let seen = receipts[provider] ?? latest?.lastEventAt
            // A quiet hook cannot prove that its process is still running. Only
            // fresh events or an observed native app establish online presence.
            let fresh = receipts[provider].map { now.timeIntervalSince($0) >= -5 && now.timeIntervalSince($0) <= 120 } ?? false
            let ended = !observations.isEmpty && observations.allSatisfy { $0.status == .ended }
            let state: State = running.contains(provider) || (fresh && !ended) ? .online :
                ended ? .offline : seen != nil ? .lastSeen : .installed
            return Self(id: provider, provider: provider, displayName: nil, state: state, lastSeen: seen)
        }
        // Local configuration owns grouping and display names. Incoming events cannot
        // impersonate another saved SSH connector by supplying a group name.
        let configured = Dictionary(configurations.map { ($0.connectionID, $0) }, uniquingKeysWith: { first, _ in first })
        let observedIDs = Set(connections.values.map(\.connectionID))
        let named = connections.values.compactMap { observation -> Self? in
            let config = configured[observation.connectionID]
            if config?.visible == false { return nil }
            let age = now.timeIntervalSince(observation.lastSeen)
            return Self(id: observation.id, provider: observation.provider, displayName: config?.name ?? observation.name,
                        state: age >= -5 && age <= 120 ? .online : .lastSeen, lastSeen: observation.lastSeen,
                        connectorID: config?.connectorID)
        }
        let quiet = configured.values.filter { $0.visible && !observedIDs.contains($0.connectionID) }.map {
            Self(id: "hermes/" + $0.connectionID, provider: "hermes", displayName: $0.name,
                 state: .installed, lastSeen: nil, connectorID: $0.connectorID)
        }
        return (legacy + named + quiet).sorted {
            if ($0.state == .online) != ($1.state == .online) { return $0.state == .online }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}
