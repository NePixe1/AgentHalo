import Foundation

public struct PiLivePid: Equatable, Sendable {
    public var sessionId: String
    public var processId: Int32

    public init(sessionId: String, processId: Int32) {
        self.sessionId = sessionId
        self.processId = processId
    }
}

public struct FocusedSessionLiveEvidence: Equatable, Sendable {
    public var claude: [ClaudeLiveSessionSnapshot]
    public var grok: [GrokActiveSessionRef]
    public var pi: [PiLivePid]
    public var antigravityPresentPids: [Int32]

    public static let empty = FocusedSessionLiveEvidence()

    public init(
        claude: [ClaudeLiveSessionSnapshot] = [],
        grok: [GrokActiveSessionRef] = [],
        pi: [PiLivePid] = [],
        antigravityPresentPids: [Int32] = []
    ) {
        self.claude = claude
        self.grok = grok
        self.pi = pi
        self.antigravityPresentPids = antigravityPresentPids
    }
}

public enum FocusedSessionHostResolver {
    public static func resolveProcessId(
        focusedAgent: AgentKind,
        visibleSessions: [SessionSnapshot],
        hookSnapshots: [SessionSnapshot],
        paused: Bool,
        evidence: FocusedSessionLiveEvidence
    ) -> Int32? {
        guard !paused else { return nil }
        switch focusedAgent {
        case .codex:
            return nil
        case .claudeCode:
            return claudePid(
                visibleSessions: visibleSessions,
                hookSnapshots: hookSnapshots,
                live: evidence.claude
            )
        case .grok:
            return grokPid(visibleSessions: visibleSessions, live: evidence.grok)
        case .pi:
            return piPid(
                visibleSessions: visibleSessions,
                hookSnapshots: hookSnapshots,
                live: evidence.pi
            )
        case .antigravity:
            let unique = Array(Set(evidence.antigravityPresentPids.filter { $0 > 0 }))
            return unique.count == 1 ? unique[0] : nil
        }
    }

    private static func claudePid(
        visibleSessions: [SessionSnapshot],
        hookSnapshots: [SessionSnapshot],
        live: [ClaudeLiveSessionSnapshot]
    ) -> Int32? {
        if let threadId = visibleSessions.first?.threadId,
           let match = live.first(where: { $0.sessionId == threadId }),
           match.processId > 0 {
            return match.processId
        }
        guard visibleSessions.isEmpty else { return nil }
        return ClaudeLiveSessionReader.preferredStandbySession(
            sessions: live,
            hookSnapshots: hookSnapshots
        ).flatMap { $0.processId > 0 ? $0.processId : nil }
    }

    private static func grokPid(
        visibleSessions: [SessionSnapshot],
        live: [GrokActiveSessionRef]
    ) -> Int32? {
        let withPid = live.filter { ($0.processId ?? 0) > 0 }
        if let snapshot = visibleSessions.first {
            if let exact = withPid.first(where: { $0.sessionId == snapshot.threadId }) {
                return exact.processId
            }
            if snapshot.threadId == "grok", withPid.count == 1 {
                return withPid[0].processId
            }
            let directory = normalizedDirectory(snapshot.workingDirectory)
            if !directory.isEmpty {
                let matched = withPid.filter {
                    normalizedDirectory($0.cwd ?? "") == directory
                }
                if matched.count == 1 {
                    return matched[0].processId
                }
            }
            return nil
        }
        return withPid.count == 1 ? withPid[0].processId : nil
    }

    private static func piPid(
        visibleSessions: [SessionSnapshot],
        hookSnapshots: [SessionSnapshot],
        live: [PiLivePid]
    ) -> Int32? {
        let liveById = Dictionary(
            live.filter { $0.processId > 0 && !$0.sessionId.isEmpty }
                .map { ($0.sessionId, $0.processId) },
            uniquingKeysWith: { _, latest in latest }
        )
        if let threadId = visibleSessions.first?.threadId {
            return liveById[threadId]
        }
        return hookSnapshots
            .filter { $0.agent == .pi && liveById[$0.threadId] != nil }
            .max(by: { $0.lastEventAt < $1.lastEventAt })
            .flatMap { liveById[$0.threadId] }
    }

    private static func normalizedDirectory(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return URL(fileURLWithPath: trimmed).standardizedFileURL.path
    }
}
