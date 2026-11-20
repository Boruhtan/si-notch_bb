import Foundation
import SINotchCore

enum AgentGroupID: Hashable {
    case localHermes
    case remote(UUID)
    case application(AgentHostApplication)

    var key: String {
        switch self {
        case .localHermes: LocalHermesAgentGroup.id
        case .remote(let id): id.uuidString
        case .application(let host): host.rawValue
        }
    }
}

struct AgentGroupCounts: Equatable {
    var waiting = 0
    var working = 0
    var completed = 0
    var errors = 0
}

struct AttentionSessionItem: Identifiable {
    let session: AgentSession
    let profileName: String
    let machineName: String
    var group: AgentGroupID? = nil
    var waitingSince: Date? = nil
    var deadline: Date? = nil
    var id: String { session.id }

    static func prioritized(_ items: [Self], at now: Date) -> [Self] {
        items.sorted { left, right in
            let urgencyThreshold = now.addingTimeInterval(30)
            let leftUrgent = left.deadline.map { $0 <= urgencyThreshold } ?? false
            let rightUrgent = right.deadline.map { $0 <= urgencyThreshold } ?? false
            if leftUrgent != rightUrgent { return leftUrgent }
            if leftUrgent, let leftDeadline = left.deadline, let rightDeadline = right.deadline,
               leftDeadline != rightDeadline { return leftDeadline < rightDeadline }
            let leftStart = left.waitingSince ?? .distantFuture
            let rightStart = right.waitingSince ?? .distantFuture
            return leftStart == rightStart ? left.id < right.id : leftStart < rightStart
        }
    }
}

struct AttentionSSHItem: Identifiable {
    let id: UUID
    let name: String
    let state: RemoteConnectionState
}

struct RexAttentionItem: Identifiable, Equatable, Sendable {
    enum State: String, CaseIterable, Sendable { case blocked, error }

    let block: RexTerminal.Block
    let state: State
    let provider: String?
    var id: String { block.session + "/" + block.block + "/" + state.rawValue }

    static func items(from snapshot: [String: Any], block: RexTerminal.Block) -> [Self] {
        guard let records = snapshot["records"] as? [[String: Any]] else { return [] }
        // Consolidate per pane and state. Titles and messages are terminal
        // output and can contain secrets, so they are never copied.
        return State.allCases.compactMap { state in
            let matches = records.filter { $0["state"] as? String == state.rawValue }
            guard !matches.isEmpty else { return nil }
            let providers = matches.compactMap { record -> String? in
                guard let value = (record["effective_app"] ?? record["app"]) as? String,
                      HarnessKind(rawValue: value) != nil else { return nil }
                return value
            }
            let provider = providers.count == matches.count && Set(providers).count == 1 ? providers.first : nil
            return Self(block: block, state: state, provider: provider)
        }
    }

    func matches(_ session: AgentSession, in group: AgentGroupID?) -> Bool {
        group == .application(.rex) && provider == session.provider &&
            session.rexSessionID == block.session && session.rexBlockID == block.block
    }
}

struct AttentionQueue {
    let requests: [AttentionSessionItem]
    let errors: [AttentionSessionItem]
    let ssh: [AttentionSSHItem]
    var rex: [RexAttentionItem] = []
    var rexWaiting: [RexAttentionItem] { rex.filter { $0.state == .blocked } }
    var rexErrors: [RexAttentionItem] { rex.filter { $0.state == .error } }
    var waitingCount: Int { requests.count + rexWaiting.count }
    var count: Int { requests.count + errors.count + ssh.count + rex.count }

    func filtered(to group: AgentGroupID) -> Self {
        Self(requests: requests.filter { $0.group == group },
             errors: errors.filter { $0.group == group },
             ssh: ssh.filter { .remote($0.id) == group },
             rex: group == .application(.rex) ? rex : [])
    }
}
