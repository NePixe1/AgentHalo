import Foundation

public enum AgentKind: String, Codable, CaseIterable, Equatable, Sendable {
    case codex
    case claudeCode

    public var menuTitle: String {
        switch self {
        case .codex: return "Codex"
        case .claudeCode: return "Claude Code"
        }
    }

    public var segmentedTitle: String {
        switch self {
        case .codex: return "Codex"
        case .claudeCode: return "CC"
        }
    }

    public var standbyDetail: String {
        switch self {
        case .codex: return "Codex is standing by"
        case .claudeCode: return "Claude Code is standing by"
        }
    }

    public var localizedStandbyDetail: String {
        switch self {
        case .codex: return "Codex 正在待命"
        case .claudeCode: return "Claude Code 正在待命"
        }
    }
}

public struct SessionSnapshot: Equatable, Sendable {
    public var threadId: String
    public var projectName: String
    public var workingDirectory: String
    public var state: HaloState
    public var action: String
    public var lastEventAt: Date
    public var completedAt: Date?
    public var active: Bool
    public var agent: AgentKind
    public var modelName: String?
    public var inputTokens: Int64?
    public var outputTokens: Int64?
    public var hasRateLimits: Bool?
    public var contextUsedPercent: Double?

    public init(
        threadId: String,
        projectName: String,
        workingDirectory: String,
        state: HaloState,
        action: String,
        lastEventAt: Date,
        completedAt: Date?,
        active: Bool,
        agent: AgentKind = .codex,
        modelName: String? = nil,
        inputTokens: Int64? = nil,
        outputTokens: Int64? = nil,
        hasRateLimits: Bool? = nil,
        contextUsedPercent: Double? = nil
    ) {
        self.threadId = threadId
        self.projectName = projectName
        self.workingDirectory = workingDirectory
        self.state = state
        self.action = action
        self.lastEventAt = lastEventAt
        self.completedAt = completedAt
        self.active = active
        self.agent = agent
        self.modelName = modelName
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.hasRateLimits = hasRateLimits
        self.contextUsedPercent = contextUsedPercent
    }
}

public struct AggregateSnapshot: Equatable, Sendable {
    public var state: HaloState
    public var label: String
    public var detail: String
    public var sessions: [SessionSnapshot]
    public var focusedAgent: AgentKind
    public var answerStreaming: Bool

    public init(
        state: HaloState,
        label: String,
        detail: String,
        sessions: [SessionSnapshot],
        focusedAgent: AgentKind = .codex,
        answerStreaming: Bool = false
    ) {
        self.state = state
        self.label = label
        self.detail = detail
        self.sessions = sessions
        self.focusedAgent = focusedAgent
        self.answerStreaming = answerStreaming
    }
}

public struct SessionDetailsSnapshot: Equatable, Sendable {
    public var projectName: String?
    public var modelName: String?
    public var inputTokens: Int64?
    public var outputTokens: Int64?

    public init(
        projectName: String? = nil,
        modelName: String? = nil,
        inputTokens: Int64? = nil,
        outputTokens: Int64? = nil
    ) {
        self.projectName = projectName
        self.modelName = modelName
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

public struct CodexRealtimeActivity: Equatable, Sendable {
    public var state: HaloState
    public var action: String
    public var answerStreaming: Bool

    public init(state: HaloState, action: String, answerStreaming: Bool = false) {
        self.state = state
        self.action = action
        self.answerStreaming = answerStreaming
    }
}

public struct RateLimitSnapshot: Equatable, Sendable {
    public var primaryUsedPercent: Double
    public var secondaryUsedPercent: Double
    public var primaryResetAt: Date?
    public var secondaryResetAt: Date?
    public var contextUsedPercent: Double?

    public init(
        primaryUsedPercent: Double,
        secondaryUsedPercent: Double,
        primaryResetAt: Date? = nil,
        secondaryResetAt: Date? = nil,
        contextUsedPercent: Double? = nil
    ) {
        self.primaryUsedPercent = primaryUsedPercent
        self.secondaryUsedPercent = secondaryUsedPercent
        self.primaryResetAt = primaryResetAt
        self.secondaryResetAt = secondaryResetAt
        self.contextUsedPercent = contextUsedPercent
    }
}

public struct CodexFailure: Equatable, Sendable {
    public var detail: String
    public var eventAt: Date

    public init(detail: String, eventAt: Date) {
        self.detail = detail
        self.eventAt = eventAt
    }
}
