import Foundation

public enum SessionAggregator {
    public static func aggregate(
        snapshots: [SessionSnapshot],
        settings: HaloSettings,
        now: Date = Date()
    ) -> AggregateSnapshot {
        if settings.paused {
            return AggregateSnapshot(
                state: .idle,
                label: "PAUSED",
                detail: "Monitoring paused",
                sessions: []
            )
        }

        let visible = snapshots.filter { snapshot in
            if snapshot.state == .done {
                guard let completedAt = snapshot.completedAt else {
                    return false
                }
                let acknowledgedAt = settings.acknowledged[snapshot.threadId] ?? .distantPast
                return completedAt > acknowledgedAt
                    && completedAt >= settings.installedAt
                    && completedAt >= now.addingTimeInterval(-86_400)
            }
            if snapshot.state == .error {
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
            return AggregateSnapshot(
                state: .idle,
                label: "READY",
                detail: "Codex is standing by",
                sessions: []
            )
        }

        let detail = visible.count == 1
            ? "\(primary.projectName) - \(primary.action)"
            : "\(primary.projectName) +\(visible.count - 1)"
        return AggregateSnapshot(
            state: primary.state,
            label: label(for: primary.state),
            detail: detail,
            sessions: visible
        )
    }

    public static func label(for state: HaloState) -> String {
        switch state {
        case .thinking: "THINKING"
        case .working: "EXECUTING"
        case .done: "COMPLETE"
        case .attention: "NEEDS YOU"
        case .error: "INTERRUPTED"
        case .idle: "READY"
        }
    }

    public static func priority(_ state: HaloState) -> Int {
        switch state {
        case .error: 0
        case .attention: 1
        case .working: 2
        case .thinking: 3
        case .done: 4
        case .idle: 5
        }
    }
}
