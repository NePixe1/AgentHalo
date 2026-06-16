import Foundation

public enum SessionAggregator {
    private static let claudeCompletedVisibleDuration: TimeInterval = 8
    private static let codexCompletedVisibleDuration: TimeInterval = 86_400

    public static func aggregate(
        snapshots: [SessionSnapshot],
        settings: HaloSettings,
        focusedAgent: AgentKind = .codex,
        now: Date = Date()
    ) -> AggregateSnapshot {
        aggregate(
            snapshots: snapshots,
            settings: settings,
            recentFailure: nil,
            codexRunning: false,
            focusedAgent: focusedAgent,
            now: now
        )
    }

    public static func aggregate(
        snapshots: [SessionSnapshot],
        settings: HaloSettings,
        recentFailure: CodexFailure?,
        codexRunning: Bool,
        focusedAgent: AgentKind = .codex,
        now: Date = Date()
    ) -> AggregateSnapshot {
        if settings.paused {
            return AggregateSnapshot(
                state: .idle,
                label: "PAUSED",
                detail: "Monitoring paused",
                sessions: [],
                focusedAgent: focusedAgent
            )
        }

        let focusedSnapshots = snapshots.filter { $0.agent == focusedAgent }
        let visible = focusedSnapshots.filter { snapshot in
            if snapshot.state == .done {
                guard let completedAt = snapshot.completedAt else {
                    return false
                }
                let acknowledgedAt = settings.acknowledged[snapshot.threadId] ?? .distantPast
                return completedAt > acknowledgedAt
                    && completedAt >= settings.installedAt
                    && completedAt >= now.addingTimeInterval(-completedVisibleDuration(for: snapshot.agent))
            }
            if snapshot.state == .error {
                if !settings.shouldShowError(eventAt: snapshot.lastEventAt) {
                    return false
                }
                return snapshot.lastEventAt >= now.addingTimeInterval(-43_200)
            }
            return snapshot.active
        }
        .sorted { left, right in
            let leftPriority = priority(left.state)
            let rightPriority = priority(right.state)
            if leftPriority != rightPriority {
                return leftPriority < rightPriority
            }
            return left.lastEventAt > right.lastEventAt
        }

        guard let primary = visible.first else {
            if focusedAgent == .codex,
               codexRunning,
               let recentFailure,
               settings.shouldShowError(eventAt: recentFailure.eventAt) {
                let synthetic = SessionSnapshot(
                    threadId: "codex-app",
                    projectName: "Codex",
                    workingDirectory: "",
                    state: .error,
                    action: recentFailure.detail,
                    lastEventAt: recentFailure.eventAt,
                    completedAt: nil,
                    active: false,
                    agent: .codex
                )
                return AggregateSnapshot(
                    state: .error,
                    label: label(for: .error),
                    detail: recentFailure.detail,
                    sessions: [synthetic],
                    focusedAgent: focusedAgent
                )
            }
            return AggregateSnapshot(
                state: .idle,
                label: "READY",
                detail: focusedAgent.standbyDetail,
                sessions: [],
                focusedAgent: focusedAgent
            )
        }

        let detail = visible.count == 1
            ? "\(primary.projectName) - \(primary.action)"
            : "\(primary.projectName) +\(visible.count - 1)"
        return AggregateSnapshot(
            state: primary.state,
            label: label(for: primary.state),
            detail: detail,
            sessions: visible,
            focusedAgent: focusedAgent
        )
    }

    public static func label(for state: HaloState) -> String {
        GeneratedHaloSpec.state(state).label
    }

    public static func priority(_ state: HaloState) -> Int {
        GeneratedHaloSpec.state(state).priority
    }

    private static func completedVisibleDuration(for agent: AgentKind) -> TimeInterval {
        switch agent {
        case .claudeCode:
            return claudeCompletedVisibleDuration
        case .codex:
            return codexCompletedVisibleDuration
        }
    }
}
