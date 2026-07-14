import Foundation

public struct UsageDetailsModel: Equatable, Sendable {
    public var windows: [UsageWindow]
    public var status: UsageDataStatus

    public init(windows: [UsageWindow], status: UsageDataStatus) {
        self.windows = windows
        self.status = status
    }
}

public enum DetailsPanelBody: Equatable, Sendable {
    case usage(UsageDetailsModel)
    case session(SessionDetailsSnapshot)
}

public struct DetailsPanelViewModel: Equatable, Sendable {
    public var providerName: String
    public var planName: String?
    public var usageWarning: String?
    public var contextUsedPercent: Double?
    public var body: DetailsPanelBody

    public init(
        providerName: String,
        planName: String?,
        usageWarning: String?,
        contextUsedPercent: Double?,
        body: DetailsPanelBody
    ) {
        self.providerName = providerName
        self.planName = planName
        self.usageWarning = usageWarning
        self.contextUsedPercent = contextUsedPercent
        self.body = body
    }
}

public enum DetailsContentResolver {
    public static func resolve(
        providerID: UsageProviderID,
        monitorState: UsageMonitorState,
        isOffline: Bool,
        sessionDetails: SessionDetailsSnapshot,
        contextUsedPercent: Double?,
        now: Date
    ) -> DetailsPanelViewModel {
        let providerName = providerName(for: providerID)
        let resolvedContext = isOffline ? nil : contextUsedPercent

        guard monitorState.accessMode == .oauth else {
            return DetailsPanelViewModel(
                providerName: providerName,
                planName: nil,
                usageWarning: nil,
                contextUsedPercent: resolvedContext,
                body: .session(isOffline ? SessionDetailsSnapshot() : sessionDetails)
            )
        }

        let status = monitorState.status ?? .noData
        return DetailsPanelViewModel(
            providerName: providerName,
            planName: monitorState.snapshot?.planName,
            usageWarning: warning(
                providerID: providerID,
                status: status,
                failure: monitorState.lastFailure,
                now: now
            ),
            contextUsedPercent: resolvedContext,
            body: .usage(
                UsageDetailsModel(
                    windows: monitorState.snapshot?.windows ?? [],
                    status: status
                )
            )
        )
    }

    private static func providerName(for providerID: UsageProviderID) -> String {
        switch providerID {
        case .codex:
            return "Codex"
        case .claude:
            return "Claude Code"
        }
    }

    private static func warning(
        providerID: UsageProviderID,
        status: UsageDataStatus,
        failure: UsageFailureReason?,
        now: Date
    ) -> String? {
        if status == .signInAgain || failure == .signInAgain {
            switch providerID {
            case .codex:
                return L10n.shared["usage.warning.sign_in_codex"]
            case .claude:
                return L10n.shared["usage.warning.sign_in_claude"]
            }
        }

        if case .rateLimited = failure {
            return L10n.shared["usage.warning.rate_limited"]
        }

        if case .stale(let updatedAt) = status {
            return L10n.shared.format(
                "usage.warning.stale",
                formatUpdateTime(updatedAt, now: now)
            )
        }

        guard status == .noData, let failure else {
            return nil
        }
        switch failure {
        case .network:
            return L10n.shared["usage.warning.network"]
        case .serviceUnavailable:
            return L10n.shared["usage.warning.service"]
        case .invalidResponse:
            return L10n.shared["usage.warning.invalid"]
        case .rateLimited:
            return L10n.shared["usage.warning.rate_limited"]
        case .signInAgain:
            return nil
        }
    }

    private static func formatUpdateTime(_ date: Date, now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: L10n.shared["date.culture"])
        if Calendar.current.isDate(date, inSameDayAs: now) {
            formatter.dateFormat = L10n.shared["date.today_format"]
        } else {
            formatter.dateFormat = L10n.shared["date.other_format"]
        }
        return formatter.string(from: date)
    }
}
