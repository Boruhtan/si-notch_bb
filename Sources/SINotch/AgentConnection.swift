import Foundation
import SINotchCore

/// Provider availability is independent of the tasks shown in the island.
struct AgentConnection: Identifiable, Equatable {
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
    let state: State
    let lastSeen: Date?
    var name: String { HarnessKind(rawValue: id)?.displayName ?? id }

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
                        receipts: [String: Date], running: Set<String>, now: Date) -> [Self] {
        let installed = Set(detected.filter(\.isDetected).map(\.id))
        let providers = installed.union(sessions.map(\.provider)).union(receipts.keys).union(running)
        return providers.map { provider in
            let observations = sessions.filter { $0.provider == provider }
            let latest = observations.max { $0.lastEventAt < $1.lastEventAt }
            let seen = receipts[provider] ?? latest?.lastEventAt
            // A quiet hook cannot prove that its process is still running. Only
            // fresh events or an observed native app establish online presence.
            let fresh = receipts[provider].map { now.timeIntervalSince($0) >= -5 && now.timeIntervalSince($0) <= 120 } ?? false
            let ended = !observations.isEmpty && observations.allSatisfy { $0.status == .ended }
            let state: State = running.contains(provider) || (fresh && !ended) ? .online :
                ended ? .offline : seen != nil ? .lastSeen : .installed
            return Self(id: provider, state: state, lastSeen: seen)
        }.sorted {
            if ($0.state == .online) != ($1.state == .online) { return $0.state == .online }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}
