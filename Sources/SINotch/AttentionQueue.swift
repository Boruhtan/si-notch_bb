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

struct AttentionQueue {
    let requests: [AttentionSessionItem]
    let errors: [AttentionSessionItem]
    let ssh: [AttentionSSHItem]
    var count: Int { requests.count + errors.count + ssh.count }

    func filtered(to group: AgentGroupID) -> Self {
        Self(requests: requests.filter { $0.group == group },
             errors: errors.filter { $0.group == group },
             ssh: ssh.filter { .remote($0.id) == group })
    }
}
