import Foundation
import SINotchCore

enum AgentHostApplication: String, CaseIterable, Hashable {
    case rex, zed
    var name: String { self == .rex ? "Rex" : "Zed" }
    var bundleID: String { self == .rex ? "com.superlogical.rex" : "dev.zed.Zed" }
    static func identify(_ bundleID: String?) -> Self? {
        switch bundleID {
        case "com.superlogical.rex": return .rex
        case "dev.zed.Zed", "dev.zed.Zed-Preview": return .zed
        default: return nil
        }
    }
    static func installed() -> Set<Self> {
        let roots = [URL(fileURLWithPath: "/Applications"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        return Set(allCases.filter { host in
            let names = host == .rex ? ["Rex.app", "Rex Beta.app"] : ["Zed.app", "Zed Preview.app"]
            return roots.contains { root in names.contains { FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) } }
        })
    }
}

/// A view of canonical sessions, never a new provider or agent identity.
struct ApplicationAgentGroup {
    let host: AgentHostApplication
    let sessions: [AgentSession]
    var activeCount: Int { sessions.filter { $0.status.isActive || $0.subagents.contains { $0.status.isActive } }.count }
    static func project(sessions: [AgentSession], claims: [String: AgentHostApplication],
                        installed: Set<AgentHostApplication>) -> [Self] {
        let hosts = installed.union(sessions.compactMap { claims[$0.id] })
        return AgentHostApplication.allCases.filter { hosts.contains($0) }.map { host in
            let owned = sessions.filter { claims[$0.id] == host }
            // Only explicit child-session links suppress a duplicate root row.
            let ownedProviders = Dictionary(uniqueKeysWithValues: owned.map { ($0.id, $0.provider) })
            let nested = Set(owned.flatMap { parent in
                parent.subagents.compactMap { child -> String? in
                    guard let id = child.sessionID, id != parent.id, ownedProviders[id] == parent.provider else { return nil }
                    return id
                }
            })
            return Self(host: host, sessions: owned.filter { !nested.contains($0.id) })
        }
    }
}
