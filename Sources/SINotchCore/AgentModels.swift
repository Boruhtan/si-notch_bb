import Foundation

public enum AgentStatus: String, Codable, CaseIterable, Sendable {
    case idle, working, waiting, approval, completed, failed, ended

    public var isActive: Bool {
        switch self {
        case .working, .waiting, .approval: return true
        default: return false
        }
    }
}

public enum AgentEventKind: String, Codable, CaseIterable, Sendable {
    case agentPresence = "agent.presence"
    case sessionStarted = "session.start"
    case working = "agent.working"
    case toolStarted = "tool.start"
    case toolFinished = "tool.finish"
    case toolFailed = "tool.failed"
    case waiting = "agent.waiting"
    case approvalRequested = "approval.request"
    case completed = "agent.completed"
    case failed = "agent.failed"
    case sessionEnded = "session.end"
    case taskUpdated = "task.update"
    case subagentStarted = "subagent.start"
    case subagentEnded = "subagent.end"
    case usageUpdated = "usage.update"
    case unknown
}

public struct AgentTask: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var status: AgentStatus
    public var completed: Bool { status == .completed || status == .ended }

    public init(id: String, title: String, status: AgentStatus = .working) {
        self.id = id
        self.title = title
        self.status = status
    }

    enum CodingKeys: String, CodingKey { case id, title, status, completed }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        if let explicitStatus = try values.decodeIfPresent(AgentStatus.self, forKey: .status) {
            status = explicitStatus
        } else {
            status = try values.decodeIfPresent(Bool.self, forKey: .completed) == true ? .completed : .working
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(title, forKey: .title)
        try values.encode(status, forKey: .status)
    }
}

public struct AgentSubagent: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var status: AgentStatus
    public var sessionID: String?
    public var parentTurnID: String?

    public init(id: String, name: String, status: AgentStatus = .working, sessionID: String? = nil, parentTurnID: String? = nil) {
        self.id = id
        self.name = name
        self.status = status
        self.sessionID = sessionID
        self.parentTurnID = parentTurnID
    }
}

/// Usage values are cumulative snapshots. Missing values preserve previous values.
public struct AgentUsage: Codable, Equatable, Sendable {
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var cachedInputTokens: Int?
    public var cacheWriteInputTokens: Int?
    public var reasoningOutputTokens: Int?
    /// A stable provider request ID makes these counts one request, not a session snapshot.
    public var requestID: String?
    public var parentSessionID: String?
    public var parentTurnID: String?
    public var startedAt: Double?
    public var endedAt: Double?
    public var callKind: String?
    public var incomplete: Bool?
    public var contextTokens: Int?
    public var contextWindow: Int?
    public var costUSD: Double?
    public var primaryUsedPercent: Double?
    public var secondaryUsedPercent: Double?

    public var usedPercent: Double? {
        if let primaryUsedPercent { return primaryUsedPercent }
        guard let contextTokens, let contextWindow, contextWindow > 0 else { return nil }
        return min(100, max(0, Double(contextTokens) / Double(contextWindow) * 100))
    }

    public init(inputTokens: Int? = nil, outputTokens: Int? = nil, contextTokens: Int? = nil,
                contextWindow: Int? = nil, costUSD: Double? = nil,
                primaryUsedPercent: Double? = nil, secondaryUsedPercent: Double? = nil,
                cachedInputTokens: Int? = nil, cacheWriteInputTokens: Int? = nil,
                reasoningOutputTokens: Int? = nil, requestID: String? = nil,
                parentSessionID: String? = nil, parentTurnID: String? = nil,
                startedAt: Double? = nil, endedAt: Double? = nil, callKind: String? = nil, incomplete: Bool? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens
        self.cacheWriteInputTokens = cacheWriteInputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
        self.requestID = requestID
        self.parentSessionID = parentSessionID; self.parentTurnID = parentTurnID
        self.startedAt = startedAt; self.endedAt = endedAt; self.callKind = callKind; self.incomplete = incomplete
        self.contextTokens = contextTokens
        self.contextWindow = contextWindow
        self.costUSD = costUSD
        self.primaryUsedPercent = primaryUsedPercent
        self.secondaryUsedPercent = secondaryUsedPercent
    }

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens", outputTokens = "output_tokens"
        case cachedInputTokens = "cached_input_tokens", cacheWriteInputTokens = "cache_write_input_tokens"
        case reasoningOutputTokens = "reasoning_output_tokens", requestID = "request_id"
        case parentSessionID = "parent_session_id", parentTurnID = "parent_turn_id"
        case startedAt = "started_at", endedAt = "ended_at", callKind = "call_kind", incomplete
        case contextTokens = "context_tokens", contextWindow = "context_window"
        case costUSD = "cost_usd", primaryUsedPercent = "primary_used_percent"
        case secondaryUsedPercent = "secondary_used_percent"
    }

    func merging(_ newer: AgentUsage) -> AgentUsage {
        AgentUsage(inputTokens: newer.inputTokens ?? inputTokens,
                   outputTokens: newer.outputTokens ?? outputTokens,
                   contextTokens: newer.contextTokens ?? contextTokens,
                   contextWindow: newer.contextWindow ?? contextWindow,
                   costUSD: newer.costUSD ?? costUSD,
                   primaryUsedPercent: newer.primaryUsedPercent ?? primaryUsedPercent,
                   secondaryUsedPercent: newer.secondaryUsedPercent ?? secondaryUsedPercent,
                   cachedInputTokens: newer.cachedInputTokens ?? cachedInputTokens,
                   cacheWriteInputTokens: newer.cacheWriteInputTokens ?? cacheWriteInputTokens,
                   reasoningOutputTokens: newer.reasoningOutputTokens ?? reasoningOutputTokens)
    }
}

public struct AgentSession: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var sessionID: String { id }
    public var provider: String
    public var connectionID: String?
    public var connectionName: String?
    public var title: String
    public var projectPath: String?
    public var status: AgentStatus
    public var createdAt: Date
    public var updatedAt: Date
    public var lastEventAt: Date
    public var lastEventID: String?
    public var lastSequence: Int?
    public var lastMessage: String?
    public var currentTool: String?
    public var tasks: [AgentTask]
    public var subagents: [AgentSubagent]
    public var usage: AgentUsage?
    public var terminalBundleID: String?
    public var targetURL: String?
    public var approvalID: String?
    public var modelName: String?
    public var reasoningEffort: String?
    public var firstPrompt: String?
    public var turnID: String?
    public var isWorkSession: Bool?

    public init(id: String, provider: String = "custom", title: String = "Agent session",
                projectPath: String? = nil, status: AgentStatus = .idle,
                createdAt: Date = Date(), updatedAt: Date? = nil) {
        self.id = id
        self.provider = provider
        self.title = title
        self.projectPath = projectPath
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        lastEventAt = createdAt
        tasks = []
        subagents = []
    }
}
