import Foundation

/// Maps Antigravity `RetrieveUserQuotaSummary` bodies into Gemini-only usage windows.
///
/// Only exact `bucketId` values `gemini-5h` and `gemini-weekly` are kept (session then weekly).
/// `3p-*` and unknown buckets are dropped. Accepts bare `{"groups":…}` and LS-wrapped
/// `{"response":{"groups":…}}`. Missing/unusable `remainingFraction` drops that bucket only.
public enum AntigravityUsageMapper {
    public static let sessionDuration: TimeInterval = 18_000
    public static let weeklyDuration: TimeInterval = 604_800

    private static let geminiSessionBucketID = "gemini-5h"
    private static let geminiWeeklyBucketID = "gemini-weekly"

    public static func mapQuotaSummary(
        response: UsageHTTPResponse,
        accountKey: AccountCacheKey,
        planName: String?,
        now: Date
    ) throws -> UsageSnapshot {
        switch response.statusCode {
        case 200..<300:
            break
        case 401, 403:
            throw UsageProviderFailure.signInAgain
        case 429:
            throw UsageProviderFailure.rateLimited(retryAt: nil)
        case 500...599:
            throw UsageProviderFailure.serviceUnavailable
        default:
            throw UsageProviderFailure.invalidResponse
        }
        guard let windows = windowsFromQuotaSummaryBody(response.body) else {
            throw UsageProviderFailure.invalidResponse
        }
        return UsageSnapshot(
            providerID: .antigravity,
            accountKey: accountKey,
            planName: planName,
            windows: windows,
            refreshedAt: now
        )
    }

    /// Parses a quota-summary body into Gemini windows only.
    /// - Returns `nil` when the body is not a summary (no decodable `groups`).
    /// - Returns a non-nil array (possibly empty) when `groups` is present — authoritative even if empty.
    public static func windowsFromQuotaSummaryBody(_ data: Data) -> [UsageWindow]? {
        guard let envelope = try? JSONDecoder().decode(QuotaSummaryEnvelope.self, from: data),
              let groups = envelope.response?.groups ?? envelope.groups
        else {
            return nil
        }

        var session: UsageWindow?
        var weekly: UsageWindow?
        for bucket in groups.flatMap({ $0.buckets ?? [] }) {
            guard let id = bucket.bucketId else { continue }
            guard let fraction = bucket.remainingFraction, fraction.isFinite else { continue }
            let usedPercent = usedPercent(fromRemaining: fraction)
            let resetsAt = bucket.resetTime.flatMap(parseResetTime)
            switch id {
            case geminiSessionBucketID:
                if session == nil {
                    session = UsageWindow(
                        kind: .session,
                        usedPercent: usedPercent,
                        resetsAt: resetsAt,
                        duration: sessionDuration
                    )
                }
            case geminiWeeklyBucketID:
                if weekly == nil {
                    weekly = UsageWindow(
                        kind: .weekly,
                        usedPercent: usedPercent,
                        resetsAt: resetsAt,
                        duration: weeklyDuration
                    )
                }
            default:
                continue
            }
        }

        var windows: [UsageWindow] = []
        if let session { windows.append(session) }
        if let weekly { windows.append(weekly) }
        return windows
    }

    /// Legacy per-model Gemini pool: worst remaining fraction → one 5h session window. No weekly.
    public static func sessionWindowFromLegacyGeminiConfigs(
        remainingFractions: [Double],
        resetTime: Date?
    ) -> UsageWindow? {
        guard let worst = remainingFractions.min() else { return nil }
        return UsageWindow(
            kind: .session,
            usedPercent: usedPercent(fromRemaining: worst),
            resetsAt: resetTime,
            duration: sessionDuration
        )
    }

    /// `(1 - remaining) * 100`, clamped 0…100. Whole percents (OpenUsage) so float noise does not surface.
    private static func usedPercent(fromRemaining fraction: Double) -> Double {
        min(100, max(0, (1 - fraction) * 100)).rounded()
    }

    /// Normalize a raw plan/tier string. Strips a leading `Google AI ` prefix; otherwise picks
    /// Ultra/Pro/Free when present in the string.
    public static func formatPlan(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }
        if let range = trimmed.range(of: "Google AI "), range.lowerBound == trimmed.startIndex {
            return titleCased(String(trimmed[range.upperBound...]))
        }
        for keyword in ["Ultra", "Pro", "Free"] where trimmed.range(of: keyword, options: .caseInsensitive) != nil {
            return keyword
        }
        return titleCased(trimmed)
    }

    private static func titleCased(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace)
            .map { part in
                guard let first = part.first else { return "" }
                return String(first).uppercased() + part.dropFirst().lowercased()
            }
            .joined(separator: " ")
    }

    private static func parseResetTime(_ raw: String) -> Date? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }
}

// MARK: - Wire types (lenient quota-summary envelope)

/// Bare Cloud Code payload and LS `{"response":…}` wrapper. Every field optional so one bad bucket
/// never voids the summary into the legacy fallback path.
private struct QuotaSummaryEnvelope: Decodable {
    let response: QuotaSummaryRoot?
    let groups: [QuotaSummaryGroup]?
}

private struct QuotaSummaryRoot: Decodable {
    let groups: [QuotaSummaryGroup]?
}

private struct QuotaSummaryGroup: Decodable {
    let buckets: [QuotaSummaryBucket]?
}

/// Malformed elements decode to nil fields instead of failing the whole array.
private struct QuotaSummaryBucket: Decodable {
    let bucketId: String?
    let remainingFraction: Double?
    let resetTime: String?

    private enum CodingKeys: String, CodingKey {
        case bucketId
        case remainingFraction
        case resetTime
    }

    init(from decoder: Decoder) {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        bucketId = container.flatMap { (try? $0.decodeIfPresent(String.self, forKey: .bucketId)) ?? nil }
        remainingFraction = container.flatMap { (try? $0.decodeIfPresent(Double.self, forKey: .remainingFraction)) ?? nil }
        resetTime = container.flatMap { (try? $0.decodeIfPresent(String.self, forKey: .resetTime)) ?? nil }
    }
}
