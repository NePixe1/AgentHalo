import Foundation

public struct ClaudeMainSessionDetails: Equatable, Sendable {
    public var sessionDetails: SessionDetailsSnapshot
    public var contextUsedPercent: Double?

    public init(sessionDetails: SessionDetailsSnapshot, contextUsedPercent: Double?) {
        self.sessionDetails = sessionDetails
        self.contextUsedPercent = contextUsedPercent
    }
}

public enum ClaudeMainSessionDetailsResolver {
    public static func resolve(
        mainSessionId: String?,
        mainSessions: [SessionSnapshot],
        liveSession: ClaudeLiveSessionSnapshot?,
        usage: ClaudeContextUsageSnapshot?
    ) -> ClaudeMainSessionDetails {
        guard let mainSessionId,
              !mainSessionId.isEmpty,
              mainSessionId != "claude-code" else {
            return emptyDetails
        }

        let mainSession = mainSessions.first { $0.threadId == mainSessionId }
        let exactLiveSession = liveSession?.sessionId == mainSessionId ? liveSession : nil
        let exactUsage = usage?.sessionId == mainSessionId ? usage : nil
        let projectName = safeProjectName(mainSession) ?? exactLiveSession?.safeProjectName

        return ClaudeMainSessionDetails(
            sessionDetails: SessionDetailsSnapshot(
                projectName: projectName,
                modelName: exactUsage?.modelName,
                inputTokens: exactUsage?.inputTokens,
                outputTokens: exactUsage?.outputTokens
            ),
            contextUsedPercent: exactUsage?.usedPercent
        )
    }

    private static var emptyDetails: ClaudeMainSessionDetails {
        ClaudeMainSessionDetails(
            sessionDetails: SessionDetailsSnapshot(),
            contextUsedPercent: nil
        )
    }

    private static func safeProjectName(_ session: SessionSnapshot?) -> String? {
        guard let session else { return nil }
        let liveShape = ClaudeLiveSessionSnapshot(
            sessionId: session.threadId,
            workingDirectory: session.workingDirectory,
            processId: 0,
            status: "",
            updatedAt: session.lastEventAt
        )
        guard liveShape.safeProjectName != nil,
              !session.projectName.isEmpty,
              session.projectName != "Claude Code" else {
            return nil
        }
        return session.projectName
    }
}
