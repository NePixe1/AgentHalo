import Foundation

public enum SessionAggregator {
    /// Brief green flash after a turn ends, then settle to STANDBY/OFFLINE.
    /// Codex previously held done for 24h; that blocked offline and standby.
    private static let completedVisibleDuration: TimeInterval = 8

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
            codexRunning: true,
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
        let displayCandidates = focusedSnapshots.filter { snapshot in
            !isSupersededError(snapshot, among: focusedSnapshots)
        }
        let visible = displayCandidates.filter { snapshot in
            if snapshot.state == .done {
                // Codex done is only meaningful while the app is still present;
                // quitting Codex must surface OFFLINE instead of a sticky COMPLETE.
                if snapshot.agent == .codex && !codexRunning {
                    return false
                }
                guard let completedAt = snapshot.completedAt else {
                    return false
                }
                let acknowledgedAt = settings.acknowledged[snapshot.threadId] ?? .distantPast
                return completedAt > acknowledgedAt
                    && completedAt >= settings.installedAt
                    && completedAt >= now.addingTimeInterval(-Self.completedVisibleDuration)
            }
            if snapshot.state == .error {
                if !settings.shouldShowError(eventAt: snapshot.lastEventAt) {
                    return false
                }
                return snapshot.lastEventAt >= now.addingTimeInterval(-43_200)
            }
            guard snapshot.active else {
                return false
            }
            if snapshot.agent == .codex && !codexRunning {
                return false
            }
            // Hide stale thinking/working after 10 minutes. Do NOT apply this to
            // `.attention` — awaiting user approval may legitimately sit idle for
            // a long time without new events (and must not fall back to STANDBY).
            if (snapshot.state == .thinking || snapshot.state == .working)
                && now.timeIntervalSince(snapshot.lastEventAt) >= 600 {
                return false
            }
            return true
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
                label: label(for: .idle),
                detail: focusedAgent.offlineDetail,
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

    private static func isSupersededError(
        _ snapshot: SessionSnapshot,
        among snapshots: [SessionSnapshot]
    ) -> Bool {
        guard snapshot.state == .error else {
            return false
        }
        return snapshots.contains { candidate in
            candidate.agent == snapshot.agent
                && candidate.threadId != snapshot.threadId
                && isMeaningful(candidate)
                && candidate.lastEventAt > snapshot.lastEventAt
        }
    }

    private static func isMeaningful(_ snapshot: SessionSnapshot) -> Bool {
        snapshot.active || snapshot.state == .done || snapshot.state == .error
    }
}
