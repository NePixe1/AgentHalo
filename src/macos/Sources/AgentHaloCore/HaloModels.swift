import Foundation

public struct SessionSnapshot: Equatable, Sendable {
    public var threadId: String
    public var projectName: String
    public var workingDirectory: String
    public var state: HaloState
    public var action: String
    public var lastEventAt: Date
    public var completedAt: Date?
    public var active: Bool

    public init(
        threadId: String,
        projectName: String,
        workingDirectory: String,
        state: HaloState,
        action: String,
        lastEventAt: Date,
        completedAt: Date?,
        active: Bool
    ) {
        self.threadId = threadId
        self.projectName = projectName
        self.workingDirectory = workingDirectory
        self.state = state
        self.action = action
        self.lastEventAt = lastEventAt
        self.completedAt = completedAt
        self.active = active
    }
}

public struct AggregateSnapshot: Equatable, Sendable {
    public var state: HaloState
    public var label: String
    public var detail: String
    public var sessions: [SessionSnapshot]

    public init(state: HaloState, label: String, detail: String, sessions: [SessionSnapshot]) {
        self.state = state
        self.label = label
        self.detail = detail
        self.sessions = sessions
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
