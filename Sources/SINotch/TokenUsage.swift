import Foundation
import CoreFoundation
import SINotchCore

/// Input includes cache reads/writes; output includes reasoning. Subsets are
/// never added to the total a second time. Unknown subsets remain unknown.
struct TokenCounts: Codable, Equatable, Sendable {
    var input: Int
    var output: Int
    var cached: Int?
    var cacheWrite: Int?
    var reasoning: Int?
    static let zero = TokenCounts(input: 0, output: 0, cached: 0, cacheWrite: 0, reasoning: 0)
    var total: Int { Self.add(input, output) }
    static func add(_ a: Int, _ b: Int) -> Int { let (n, overflow) = a.addingReportingOverflow(b); return overflow ? Int.max : n }
    func adding(_ other: Self) -> Self {
        func sum(_ a: Int?, _ b: Int?) -> Int? { guard let a, let b else { return nil }; return Self.add(a, b) }
        return Self(input: Self.add(input, other.input), output: Self.add(output, other.output),
                    cached: sum(cached, other.cached), cacheWrite: sum(cacheWrite, other.cacheWrite), reasoning: sum(reasoning, other.reasoning))
    }
    func subtracting(_ old: Self) -> Self {
        func delta(_ a: Int?, _ b: Int?) -> Int? { guard let a, let b else { return nil }; return max(0, a - b) }
        return Self(input: max(0, input - old.input), output: max(0, output - old.output),
                    cached: delta(cached, old.cached), cacheWrite: delta(cacheWrite, old.cacheWrite), reasoning: delta(reasoning, old.reasoning))
    }
    init(input: Int, output: Int, cached: Int? = nil, cacheWrite: Int? = nil, reasoning: Int? = nil) {
        self.input = input; self.output = output
        self.cached = cached.flatMap { (0...max(0, input)).contains($0) ? $0 : nil }
        self.cacheWrite = cacheWrite.flatMap { (0...max(0, input)).contains($0) ? $0 : nil }
        self.reasoning = reasoning.flatMap { (0...max(0, output)).contains($0) ? $0 : nil }
    }
    init?(_ usage: AgentUsage) {
        guard let input = usage.inputTokens, let output = usage.outputTokens, input >= 0, output >= 0 else { return nil }
        self.init(input: input, output: output, cached: usage.cachedInputTokens,
                  cacheWrite: usage.cacheWriteInputTokens, reasoning: usage.reasoningOutputTokens)
    }
    static func count(_ value: Any?) -> Int? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              n.doubleValue.isFinite, n.doubleValue >= 0, n.doubleValue < 1e15,
              n.doubleValue.rounded() == n.doubleValue else { return nil }
        return n.intValue
    }
    static func codex(_ raw: Any?) -> Self? {
        guard let raw = raw as? [String: Any], let input = count(raw["input_tokens"]), let output = count(raw["output_tokens"]) else { return nil }
        return Self(input: input, output: output, cached: count(raw["cached_input_tokens"]),
                    cacheWrite: count(raw["cache_write_input_tokens"]), reasoning: count(raw["reasoning_output_tokens"]))
    }
    static func pi(_ raw: Any?) -> Self? {
        guard let raw = raw as? [String: Any], let input = count(raw["input"]), let output = count(raw["output"]) else { return nil }
        // Pi's input excludes its separately reported cache buckets.
        let cached = count(raw["cacheRead"]), write = count(raw["cacheWrite"])
        if (raw["cacheRead"] != nil && cached == nil) || (raw["cacheWrite"] != nil && write == nil) { return nil }
        return Self(input: add(add(input, cached ?? 0), write ?? 0), output: output, cached: cached,
                    cacheWrite: write, reasoning: count(raw["reasoning"]))
    }
}

struct UsageTurn: Codable, Equatable, Sendable {
    var counts: TokenCounts
    var date: Date
    var model: String?
    var authoritative = false
}

struct UsageSession: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var sessionID: String
    var provider: String
    var connectionID: String?
    var connectionName: String?
    var parentID: String?
    var title: String
    var project: String?
    var model: String?
    var startedAt: Date
    var updatedAt: Date
    var turns: [String: UsageTurn] = [:]
    var partial = false
    var requests: [String: UsageRequest]?
    var turnInfo: [String: UsageTurnInfo]?
    var counts: TokenCounts? { turns.isEmpty ? nil : turns.values.reduce(.zero) { $0.adding($1.counts) } }
    static func key(provider: String, connection: String? = nil, session: String) -> String {
        // Same canonical identity as History, so archived entries can link without storing transcript content.
        (try? HistoryStore.sessionKey(AgentEvent(sessionID: session, provider: provider, kind: .usageUpdated, connectionID: connection))) ?? ""
    }
    init(sessionID: String, provider: String, connectionID: String? = nil, title: String? = nil, date: Date) {
        self.id = Self.key(provider: provider, connection: connectionID, session: sessionID)
        self.sessionID = sessionID; self.provider = provider; self.connectionID = connectionID
        self.title = title ?? String(sessionID.prefix(12)); self.startedAt = date; self.updatedAt = date
    }
}

/// Parses only metadata and numeric counters; no prompts, tool output, reasoning
/// text or credentials enter the journal. State is checkpointed with the offset.
struct UsageLogParser: Codable {
    var session: UsageSession?
    var turnID: String?
    var lastTotal: TokenCounts = .zero
    var ownedResponses: Set<String> = []
    var ownsCurrentTurn = false
    var forked = false
    var ownActivity = false
    var headerDate: Date?
    var messageTurns: [String: String]?

    mutating func consume(_ row: [String: Any], provider: String) {
        let type = row["type"] as? String
        let payload = row["payload"] as? [String: Any] ?? [:]
        if provider == "codex" {
            let eventType = payload["type"] as? String
            guard type == "session_meta" || type == "turn_context" || type == "token_usage_record" ||
                (type == "event_msg" && (["token_count", "task_started", "task_complete", "turn_aborted", "turn_cancelled"].contains(eventType ?? ""))) else { return }
        }
        let date = Self.date(row["timestamp"])
        if type == "session_meta" || (provider == "pi" && type == "session") {
            let meta = provider == "pi" ? row : payload
            guard let sid = Self.identifier(meta["id"]), let date else { return }
            if session == nil { session = UsageSession(sessionID: sid, provider: provider, date: date) }
            headerDate = date
            session?.project = Self.text(meta["cwd"], max: 4096)
            let source = meta["source"] as? [String: Any]
            let sub = source?["subagent"] as? [String: Any]
            let spawn = sub?["thread_spawn"] as? [String: Any]
            let parent = Self.identifier(meta["parent_thread_id"] ?? spawn?["parent_thread_id"] ?? meta["parentSessionId"])
            if let parent { session?.parentID = UsageSession.key(provider: provider, session: parent) }
            forked = parent != nil || meta["forked_from_id"] is String
            if let name = Self.text(meta["agent_nickname"] ?? spawn?["agent_nickname"] ?? sub?["other"], max: 160) { session?.title = name }
            return
        }
        guard var current = session, let date else { return }
        defer { session = current }
        if provider == "pi" {
            if type == "session_info", let title = Self.text(row["name"], max: 160) { current.title = title }
            guard date >= (headerDate ?? .distantPast) else { return }
            guard let id = Self.identifier(row["id"]) else { return }
            let parent = Self.identifier(row["parentId"])
            let owner = parent.flatMap { messageTurns?[$0] }
            if let owner { messageTurns = messageTurns ?? [:]; messageTurns?[id] = owner }
            guard type == "message", let message = row["message"] as? [String: Any] else { return }
            if message["role"] as? String == "user" {
                turnID = id
                messageTurns = messageTurns ?? [:]; messageTurns?[id] = id
                current.turnInfo = current.turnInfo ?? [:]
                if current.turnInfo?[id] == nil { current.turnInfo?[id] = UsageTurnInfo(startedAt: date) }
                return
            }
            guard message["role"] as? String == "assistant" else { return }
            guard let counts = TokenCounts.pi(message["usage"]) else { current.partial = true; return }
            if counts.cached == nil || counts.cacheWrite == nil { current.partial = true }
            let model = Self.text(message["model"], max: 256)
            if let previous = current.requests?[id] {
                if previous.counts != counts || previous.turnID != owner { current.partial = true }
                return
            }
            current.requests = current.requests ?? [:]
            current.requests?[id] = UsageRequest(id: id, aggregateID: id, turnID: owner, counts: counts, date: date, model: model)
            current.turns[id] = UsageTurn(counts: counts, date: date, model: model)
            if let owner, message["stopReason"] as? String == "stop" { current.turnInfo?[owner]?.status = .completed }
            current.model = model ?? current.model
            current.updatedAt = max(current.updatedAt, date)
            return
        }
        if type == "turn_context" {
            current.model = Self.text(payload["model"], max: 256) ?? current.model
            if let turn = Self.identifier(payload["turn_id"]) { turnID = turn }
        }
        if type == "event_msg", payload["type"] as? String == "task_started", date >= (headerDate ?? .distantPast) {
            turnID = Self.identifier(payload["turn_id"])
            ownActivity = true; ownsCurrentTurn = false
            if let turnID {
                current.turnInfo = current.turnInfo ?? [:]
                if current.turnInfo?[turnID] == nil { current.turnInfo?[turnID] = UsageTurnInfo(startedAt: date) }
            }
        }
        if type == "event_msg", let kind = payload["type"] as? String,
           ["task_complete", "turn_aborted", "turn_cancelled"].contains(kind),
           let turn = Self.identifier(payload["turn_id"]) ?? turnID, date >= (headerDate ?? .distantPast) {
            current.turnInfo = current.turnInfo ?? [:]
            if current.turnInfo?[turn] == nil { current.turnInfo?[turn] = UsageTurnInfo(startedAt: date) }
            current.turnInfo?[turn]?.status = kind == "task_complete" ? .completed : .ended
        }
        if type == "token_usage_record" {
            // Execution session_id can name the root. thread_id owns the tokens.
            guard payload["thread_id"] as? String == current.sessionID,
                  date >= (headerDate ?? .distantPast), let id = Self.identifier(payload["response_id"]),
                  let turn = Self.identifier(payload["turn_id"]),
                  let counts = TokenCounts.codex(payload["usage"]) else { return }
            if ownedResponses.contains(id) {
                if let prior = current.requests?[id], prior.counts != counts || prior.turnID != turn || prior.rootTurnID != Self.identifier(payload["root_turn_id"]) { current.partial = true }
                return
            }
            ownedResponses.insert(id)
            current.requests = current.requests ?? [:]
            let rootTurn = Self.identifier(payload["root_turn_id"])
            let rootSession = Self.identifier(payload["session_id"])
            current.requests?[id] = UsageRequest(id: id, aggregateID: turn, turnID: turn,
                rootSessionKey: rootTurn != nil ? rootSession.map { UsageSession.key(provider: provider, session: $0) } : nil,
                rootTurnID: rootTurn, counts: counts, date: date, model: current.model)
            let prior = current.turns[turn]
            let sum = (prior?.authoritative == true ? prior!.counts : .zero).adding(counts)
            let cumulative = TokenCounts.codex(payload["turn_token_usage"])
            let recorded = cumulative.map { $0.total >= sum.total ? $0 : sum } ?? sum
            current.turns[turn] = UsageTurn(counts: recorded, date: date, model: current.model, authoritative: true)
            current.updatedAt = max(current.updatedAt, date)
            ownsCurrentTurn = true
            return
        }
        guard type == "event_msg", payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any],
              let total = TokenCounts.codex(info["total_token_usage"]) else { return }
        // Copied parent history supplies a baseline, never child consumption.
        if date < (headerDate ?? .distantPast) || (forked && !ownActivity) { lastTotal = total; return }
        guard total.input >= lastTotal.input, total.output >= lastTotal.output else {
            // A reset alone is not proof of another request. Owned records remain exact.
            if !ownsCurrentTurn { current.partial = true }
            return
        }
        let delta = total.subtracting(lastTotal); lastTotal = total
        let turn = turnID ?? "legacy"
        if current.turns[turn]?.authoritative != true, delta.total > 0 {
            let previous = current.turns[turn]?.counts ?? .zero
            current.turns[turn] = UsageTurn(counts: previous.adding(delta), date: date, model: current.model)
        }
        current.updatedAt = max(current.updatedAt, date)
    }
    static func identifier(_ raw: Any?) -> String? {
        guard let value = text(raw, max: 512), value.range(of: "^[A-Za-z0-9_.:-]+$", options: .regularExpression) != nil else { return nil }
        return value
    }
    static func text(_ raw: Any?, max: Int) -> String? {
        guard let value = raw as? String, !value.isEmpty, !value.unicodeScalars.contains(where: { $0.value < 32 }) else { return nil }
        return String(value.prefix(max))
    }
    static func date(_ raw: Any?) -> Date? {
        guard let raw = raw as? String else { return nil }
        let parser = ISO8601DateFormatter(); parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return parser.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }
}
