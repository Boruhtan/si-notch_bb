import Foundation
import SINotchCore

struct UsageRequest: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var aggregateID: String
    var turnID: String?
    var rootSessionKey: String?
    var rootTurnID: String?
    var counts: TokenCounts
    var date: Date
    var startedAt: Date?
    var model: String?
    var kind: String?
    func matchesMeasurement(_ other: Self) -> Bool {
        counts == other.counts && aggregateID == other.aggregateID && turnID == other.turnID &&
        rootSessionKey == other.rootSessionKey && rootTurnID == other.rootTurnID
    }
}

struct UsageTurnInfo: Codable, Equatable, Sendable {
    var startedAt: Date
    var status: AgentStatus = .working
    var parentSessionKey: String?
    var parentTurnID: String?
    var childSessionKeys: Set<String>?
}

struct TaskUsageItem: Identifiable, Equatable, Sendable {
    var id: String
    var sessionKey: String
    var counts: TokenCounts
    var date: Date
    var model: String?
    var isRequest: Bool
    var kind: String?
}

struct UsageTask: Identifiable, Equatable, Sendable {
    var id: String
    var memberIDs: Set<String>
    var sessionKey: String?
    var turnID: String?
    var provider: String
    var title: String?
    var startedAt: Date
    var updatedAt: Date
    var status: AgentStatus?
    var items: [TaskUsageItem] = []
    var partial = false
    var unassigned = false
    var counts: TokenCounts? { items.isEmpty ? nil : items.reduce(.zero) { $0.adding($1.counts) } }
    var requestCount: Int { items.filter(\.isRequest).count }
    static func key(session: String, turn: String) -> String { session + ":turn:" + turn }
}

/// Each numeric fact belongs to exactly one task or the unassigned bucket.
/// Attribution follows explicit turn links, never the parent's latest activity.
struct TaskUsageIndex: Sendable {
    var tasks: [UsageTask]
    init(sessions: [UsageSession], groups: [String: [String]] = [:], history: [HistorySummary] = []) {
        let rows = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        var titles: [String: HistorySummary] = [:]
        for record in history.sorted(by: { $0.updatedAt < $1.updatedAt }) {
            if let turn = record.turnID { titles[UsageTask.key(session: record.sessionKey, turn: turn)] = record }
        }
        func owner(_ session: UsageSession, _ turn: String?, rootSession: String? = nil, rootTurn: String? = nil) -> (String, String)? {
            if let rootSession, let rootTurn { return (rootSession, rootTurn) }
            guard let turn else { return nil }
            var key = session.id, current = turn, seen = Set<String>()
            for _ in 0..<32 {
                guard seen.insert(UsageTask.key(session: key, turn: current)).inserted else { return nil }
                guard let row = rows[key] else { return (key, current) }
                if let info = row.turnInfo?[current], let parent = info.parentSessionKey, let parentTurn = info.parentTurnID {
                    key = parent; current = parentTurn
                } else if row.parentID != nil { return nil }
                else { return (key, current) }
            }
            return nil
        }
        var buckets: [String: UsageTask] = [:]
        func add(_ item: TaskUsageItem?, session: UsageSession, turn: String?, rootSession: String? = nil, rootTurn: String? = nil, partial: Bool = false, date: Date) {
            let target = owner(session, turn, rootSession: rootSession, rootTurn: rootTurn)
            let key = target.map { UsageTask.key(session: $0.0, turn: $0.1) } ?? "unassigned:" + session.id
            let root = target.flatMap { rows[$0.0] }
            let info = target.flatMap { rows[$0.0]?.turnInfo?[$0.1] }
            let record = titles[key]
            var task = buckets[key] ?? UsageTask(id: key, memberIDs: [key], sessionKey: target?.0,
                turnID: target?.1, provider: root?.provider ?? session.provider, title: record?.title,
                startedAt: record?.startedAt ?? info?.startedAt ?? date, updatedAt: date,
                status: record?.status ?? info?.status, unassigned: target == nil)
            if let item { task.items.append(item) }
            if let turn { task.memberIDs.insert(UsageTask.key(session: session.id, turn: turn)) }
            task.startedAt = min(task.startedAt, date); task.updatedAt = max(task.updatedAt, date)
            task.partial = task.partial || partial || (item != nil && target == nil)
            buckets[key] = task
        }
        for session in sessions {
            for (turn, info) in session.turnInfo ?? [:] where session.parentID == nil {
                add(nil, session: session, turn: turn, date: info.startedAt)
            }
            var represented: [String: TokenCounts] = [:]
            for request in (session.requests ?? [:]).values.sorted(by: { $0.id < $1.id }) {
                represented[request.aggregateID] = (represented[request.aggregateID] ?? .zero).adding(request.counts)
                let item = TaskUsageItem(id: session.id + ":" + request.id, sessionKey: session.id, counts: request.counts,
                    date: request.date, model: request.model, isRequest: true, kind: request.kind)
                add(item, session: session, turn: request.turnID, rootSession: request.rootSessionKey,
                    rootTurn: request.rootTurnID, partial: session.partial, date: request.date)
            }
            for (aggregate, turn) in session.turns {
                let covered = represented[aggregate] ?? .zero
                let remainder = turn.counts.subtracting(covered)
                guard remainder.total > 0 || (turn.counts.total == 0 && represented[aggregate] == nil) else { continue }
                let inferred = session.provider == "pi" || aggregate == "legacy" || aggregate == "snapshot" ? nil : aggregate
                let links = (session.requests ?? [:]).values.filter { $0.aggregateID == aggregate }
                let rootLinks = Set(links.compactMap { r in r.rootTurnID.map { (r.rootSessionKey ?? "") + ":" + $0 } })
                let link = rootLinks.count == 1 ? links.first(where: { $0.rootTurnID != nil }) : nil
                let item = TaskUsageItem(id: session.id + ":summary:" + aggregate, sessionKey: session.id,
                    counts: remainder, date: turn.date, model: turn.model, isRequest: false, kind: "summary")
                add(item, session: session, turn: inferred, rootSession: link?.rootSessionKey,
                    rootTurn: link?.rootTurnID, partial: true, date: turn.date)
            }
        }
        for session in sessions {
            for (turn, info) in session.turnInfo ?? [:] {
                let key = UsageTask.key(session: session.id, turn: turn)
                if let children = info.childSessionKeys, let task = buckets[key],
                   !children.isSubset(of: Set(task.items.map(\.sessionKey))) { buckets[key]?.partial = true }
            }
        }
        // Groups contain original task IDs only. Overlaps are rejected at write time;
        // also defend against corrupt on-disk groups in deterministic order.
        var claimed = Set<String>()
        for (id, members) in groups.sorted(by: { $0.key < $1.key }) {
            let available = Set(members).subtracting(claimed).filter { buckets[$0] != nil && buckets[$0]?.unassigned == false }
            guard available.count > 1 else { continue }
            let children = available.compactMap { buckets[$0] }.sorted { $0.startedAt < $1.startedAt }
            var combined = children[0]; combined.id = id; combined.memberIDs = Set(children.flatMap(\.memberIDs)); combined.turnID = nil
            combined.items = children.flatMap(\.items); combined.startedAt = children.map(\.startedAt).min()!
            combined.updatedAt = children.map(\.updatedAt).max()!; combined.partial = children.contains(where: \.partial)
            combined.status = children.allSatisfy { $0.status == .completed } ? .completed : nil
            claimed.formUnion(available)
            for member in available { buckets.removeValue(forKey: member) }
            buckets[id] = combined
        }
        tasks = buckets.values.sorted { $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt }
    }
    func task(session: String, turn: String) -> UsageTask? {
        let key = UsageTask.key(session: session, turn: turn)
        return tasks.first { $0.memberIDs.contains(key) }
    }
}
