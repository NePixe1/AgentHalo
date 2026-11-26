import Foundation

/// Maps Antigravity `RetrieveUserQuotaSummary` bodies into Gemini and Claude/GPT usage windows.
///
/// Recognizes exact `bucketId` values `gemini-5h`, `gemini-weekly`, `3p-5h`, and `3p-weekly`
/// (in deterministic order: Gemini 5h/Weekly, then Claude/GPT 5h/Weekly). Unknown buckets
/// are dropped. Accepts bare `{"groups":…}` and LS-wrapped `{"response":{"groups":…}}`.
/// Missing/unusable `remainingFraction` drops that bucket only.
public enum AntigravityUsageMapper {
    public static let sessionDuration: TimeInterval = 18_000
    public static let weeklyDuration: TimeInterval = 604_800

    private static let geminiSessionBucketID = "gemini-5h"
    private static let geminiWeeklyBucketID = "gemini-weekly"
    private static let thirdPartySessionBucketID = "3p-5h"
    private static let thirdPartyWeeklyBucketID = "3p-weekly"

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

    /// Parses a quota-summary body into Gemini and Claude/GPT windows.
    /// - Returns `nil` when the body is not a summary (no decodable `groups`).
    /// - Returns a non-nil array (possibly empty) when `groups` is present — authoritative even if empty.
    public static func windowsFromQuotaSummaryBody(_ data: Data) -> [UsageWindow]? {
        guard let envelope = try? JSONDecoder().decode(QuotaSummaryEnvelope.self, from: data),
              let groups = envelope.response?.groups ?? envelope.groups
        else {
            return nil
        }

        var geminiSession: UsageWindow?
        var geminiWeekly: UsageWindow?
        var claudeSession: UsageWindow?
        var claudeWeekly: UsageWindow?
        for bucket in groups.flatMap({ $0.buckets ?? [] }) {
            guard let id = bucket.bucketId else { continue }
            guard let fraction = bucket.remainingFraction, fraction.isFinite else { continue }
            let usedPercent = usedPercent(fromRemaining: fraction)
            let resetsAt = bucket.resetTime.flatMap(parseResetTime)
            switch id {
            case geminiSessionBucketID:
                if geminiSession == nil {
                    geminiSession = UsageWindow(
                        kind: .session,
                        usedPercent: usedPercent,
                        resetsAt: resetsAt,
                        duration: sessionDuration,
                        group: .gemini
                    )
                }
            case geminiWeeklyBucketID:
                if geminiWeekly == nil {
                    geminiWeekly = UsageWindow(
                        kind: .weekly,
                        usedPercent: usedPercent,
                        resetsAt: resetsAt,
                        duration: weeklyDuration,
                        group: .gemini
                    )
                }
            case thirdPartySessionBucketID:
                if claudeSession == nil {
                    claudeSession = UsageWindow(
                        kind: .session,
                        usedPercent: usedPercent,
                        resetsAt: resetsAt,
                        duration: sessionDuration,
                        group: .claudeGPT
                    )
                }
            case thirdPartyWeeklyBucketID:
                if claudeWeekly == nil {
                    claudeWeekly = UsageWindow(
                        kind: .weekly,
                        usedPercent: usedPercent,
                        resetsAt: resetsAt,
                        duration: weeklyDuration,
                        group: .claudeGPT
                    )
                }
            default:
                continue
            }
        }

        return [geminiSession, geminiWeekly, claudeSession, claudeWeekly].compactMap { $0 }
    }

    /// Legacy per-model pool: worst remaining fraction → one 5h session window for `group`. No weekly.
    public static func sessionWindowFromLegacyConfigs(
        remainingFractions: [Double],
        resetTime: Date?,
        group: UsageModelGroup
    ) -> UsageWindow? {
        guard let worst = remainingFractions.min() else { return nil }
        return UsageWindow(
            kind: .session,
            usedPercent: usedPercent(fromRemaining: worst),
            resetsAt: resetTime,
            duration: sessionDuration,
            group: group
        )
    }

    /// Legacy per-model Gemini pool: worst remaining fraction → one 5h session window. No weekly.
    public static func sessionWindowFromLegacyGeminiConfigs(
        remainingFractions: [Double],
        resetTime: Date?
    ) -> UsageWindow? {
        sessionWindowFromLegacyConfigs(
            remainingFractions: remainingFractions,
            resetTime: resetTime,
            group: .gemini
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
        case bucketIdSnake = "bucket_id"
        case remainingFraction
        case remainingFractionSnake = "remaining_fraction"
        case resetTime
        case resetTimeSnake = "reset_time"
    }

    init(from decoder: Decoder) {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        bucketId = Self.firstString(in: container, keys: [.bucketId, .bucketIdSnake])
        remainingFraction = Self.firstDouble(in: container, keys: [.remainingFraction, .remainingFractionSnake])
        resetTime = Self.firstString(in: container, keys: [.resetTime, .resetTimeSnake])
    }

    private static func firstString(
        in container: KeyedDecodingContainer<CodingKeys>?,
        keys: [CodingKeys]
    ) -> String? {
        guard let container else { return nil }
        for key in keys {
            if let value = try? container.decodeIfPresent(String.self, forKey: key) {
                return value
            }
        }
        return nil
    }

    private static func firstDouble(
        in container: KeyedDecodingContainer<CodingKeys>?,
        keys: [CodingKeys]
    ) -> Double? {
        guard let container else { return nil }
        for key in keys {
            if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
                return value
            }
            if let text = try? container.decodeIfPresent(String.self, forKey: key),
               let parsed = Double(text) {
                return parsed
            }
        }
        return nil
    }
}
