import Foundation

public enum CodexUsageMapper {
    public static let sessionDuration: TimeInterval = 18_000
    public static let weeklyDuration: TimeInterval = 604_800

    public static func map(
        response: UsageHTTPResponse,
        accountKey: AccountCacheKey,
        now: Date = Date()
    ) throws -> UsageSnapshot {
        switch response.statusCode {
        case 200..<300:
            break
        case 401:
            throw UsageProviderFailure.signInAgain
        case 429:
            throw UsageProviderFailure.rateLimited(retryAt: nil)
        case 500...599:
            throw UsageProviderFailure.serviceUnavailable
        default:
            throw UsageProviderFailure.invalidResponse
        }

        guard let body = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] else {
            throw UsageProviderFailure.invalidResponse
        }

        let planName = mapPlan(body["plan_type"])
        let rateLimit = body["rate_limit"] as? [String: Any]
        let candidates = [
            candidate(rateLimit?["primary_window"], fallbackKind: .session, fallbackDuration: sessionDuration, now: now),
            candidate(rateLimit?["secondary_window"], fallbackKind: .weekly, fallbackDuration: weeklyDuration, now: now),
        ].compactMap { $0 }
        let windows = [
            classifiedWindow(.session, candidates: candidates),
            classifiedWindow(.weekly, candidates: candidates),
        ].compactMap { $0 }

        guard planName != nil || !windows.isEmpty else {
            throw UsageProviderFailure.invalidResponse
        }
        return UsageSnapshot(
            providerID: .codex,
            accountKey: accountKey,
            planName: planName,
            windows: windows,
            refreshedAt: now
        )
    }

    private struct Candidate {
        var window: UsageWindow
        var explicitKind: UsageWindowKind?
        var fallbackKind: UsageWindowKind
    }

    private static func candidate(
        _ value: Any?,
        fallbackKind: UsageWindowKind,
        fallbackDuration: TimeInterval,
        now: Date
    ) -> Candidate? {
        guard let object = value as? [String: Any],
              let rawPercent = number(object["used_percent"])
        else {
            return nil
        }
        let explicitDuration = number(object["limit_window_seconds"])
        let explicitKind: UsageWindowKind?
        switch explicitDuration {
        case sessionDuration:
            explicitKind = .session
        case weeklyDuration:
            explicitKind = .weekly
        default:
            explicitKind = nil
        }
        let kind = explicitKind ?? fallbackKind
        return Candidate(
            window: UsageWindow(
                kind: kind,
                usedPercent: min(100, max(0, rawPercent)),
                resetsAt: resetDate(object, now: now),
                duration: explicitDuration ?? fallbackDuration
            ),
            explicitKind: explicitKind,
            fallbackKind: fallbackKind
        )
    }

    private static func classifiedWindow(
        _ kind: UsageWindowKind,
        candidates: [Candidate]
    ) -> UsageWindow? {
        if var exact = candidates.first(where: { $0.explicitKind == kind })?.window {
            exact.kind = kind
            return exact
        }
        guard var fallback = candidates.first(where: {
            $0.explicitKind == nil && $0.fallbackKind == kind
        })?.window else {
            return nil
        }
        fallback.kind = kind
        return fallback
    }

    private static func mapPlan(_ value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        switch trimmed.lowercased() {
        case "prolite": return "Pro 5x"
        case "pro": return "Pro 20x"
        case "free": return "Free"
        case "plus": return "Plus"
        default:
            return trimmed.split(separator: "_", omittingEmptySubsequences: true)
                .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
                .joined(separator: " ")
        }
    }

    private static func resetDate(_ object: [String: Any], now: Date) -> Date? {
        if let seconds = number(object["reset_at"]) {
            return Date(timeIntervalSince1970: seconds)
        }
        if let string = object["reset_at"] as? String {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: string) {
                return date
            }
            if let date = ISO8601DateFormatter().date(from: string) {
                return date
            }
        }
        if let seconds = number(object["reset_after_seconds"]) {
            return now.addingTimeInterval(seconds)
        }
        return nil
    }

    private static func number(_ value: Any?) -> Double? {
        if value is Bool { return nil }
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }
}
