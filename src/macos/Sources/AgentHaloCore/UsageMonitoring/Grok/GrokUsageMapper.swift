import Foundation

/// Maps Grok credits billing responses into `UsageSnapshot`.
///
/// Aligns with OpenUsage `GrokCreditsConfigDecoder` / `GrokUsageMapper`:
/// - total-pool `creditUsagePercent` (proto-JSON: absent means 0)
/// - only `USAGE_PERIOD_TYPE_WEEKLY` produces a weekly window
/// - `onDemandCap` / prepaid fields are ignored (no Pay-as-you-go UI)
public enum GrokUsageMapper {
    public static let weeklyPeriodType = "USAGE_PERIOD_TYPE_WEEKLY"

    public static func mapCredits(
        response: UsageHTTPResponse,
        accountKey: AccountCacheKey,
        planName: String?,
        now: Date
    ) throws -> UsageSnapshot {
        switch response.statusCode {
        case 200..<300:
            break
        case 401:
            throw UsageProviderFailure.signInAgain
        case 429:
            throw UsageProviderFailure.rateLimited(retryAt: retryAfterDate(response, now: now))
        case 500...599:
            throw UsageProviderFailure.serviceUnavailable
        default:
            throw UsageProviderFailure.invalidResponse
        }

        let config = try decodeConfig(response.body)
        var windows: [UsageWindow] = []
        if config.periodType == weeklyPeriodType {
            windows.append(
                UsageWindow(
                    kind: .weekly,
                    usedPercent: min(100, max(0, config.usedPercent)),
                    resetsAt: config.periodEnd,
                    duration: config.periodEnd.timeIntervalSince(config.periodStart)
                )
            )
        }
        // Non-weekly periods: return empty windows rather than mislabel monthly as weekly.
        return UsageSnapshot(
            providerID: .grok,
            accountKey: accountKey,
            planName: planName,
            windows: windows,
            refreshedAt: now
        )
    }

    /// Best-effort plan label from `GET /v1/settings`. Non-2xx or blank → nil.
    public static func planName(from response: UsageHTTPResponse) -> String? {
        guard (200..<300).contains(response.statusCode),
              let body = jsonObject(response.body),
              let plan = body["subscription_tier_display"] as? String
        else {
            return nil
        }
        let trimmed = plan.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func retryAfterDate(_ response: UsageHTTPResponse, now: Date) -> Date? {
        guard let raw = response.header("Retry-After")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else {
            return nil
        }
        if let seconds = TimeInterval(raw), seconds >= 0 {
            return now.addingTimeInterval(seconds)
        }
        for format in [
            "EEE',' dd MMM yyyy HH':'mm':'ss zzz",
            "EEEE',' dd-MMM-yy HH':'mm':'ss zzz",
            "EEE MMM d HH':'mm':'ss yyyy",
        ] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) { return date }
        }
        return nil
    }

    // MARK: - Config decode (OpenUsage GrokCreditsConfigDecoder shape)

    private struct CreditsConfig {
        var periodType: String
        var usedPercent: Double
        var periodStart: Date
        var periodEnd: Date
    }

    private static func decodeConfig(_ bodyData: Data) throws -> CreditsConfig {
        guard let body = jsonObject(bodyData),
              let config = body["config"] as? [String: Any],
              let period = config["currentPeriod"] as? [String: Any],
              let periodType = (period["type"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !periodType.isEmpty,
              let start = date(period["start"]),
              let end = date(period["end"]),
              end > start
        else {
            throw UsageProviderFailure.invalidResponse
        }

        // proto-JSON omits zero values: absent percent is genuine 0%.
        // A present non-numeric / non-finite value is schema drift → invalid.
        let percent: Double
        if let raw = config["creditUsagePercent"] {
            guard let number = number(raw), number.isFinite else {
                throw UsageProviderFailure.invalidResponse
            }
            percent = number
        } else {
            percent = 0
        }

        return CreditsConfig(
            periodType: periodType,
            usedPercent: percent,
            periodStart: start,
            periodEnd: end
        )
    }

    private static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let normalized = normalizeTimestamp(text)
        guard !normalized.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: normalized) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: normalized)
    }

    /// Normalize provider timestamps: fractional digits truncated/padded to ms,
    /// space separators, missing timezone → Z (same approach as Claude mapper).
    private static func normalizeTimestamp(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return value }
        if value.hasSuffix(" UTC") {
            value = String(value.dropLast(4)) + "Z"
        }
        if value.contains(" "),
           let range = value.range(
               of: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}"#,
               options: .regularExpression
           ) {
            value.replaceSubrange(
                range,
                with: value[range].replacingOccurrences(of: " ", with: "T")
            )
        }

        let pattern = #"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(\.\d+)?(Z|[+-]\d{2}:\d{2})?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                  in: value,
                  range: NSRange(value.startIndex..., in: value)
              ),
              let headRange = Range(match.range(at: 1), in: value)
        else {
            return value
        }

        var fraction = ""
        if match.range(at: 2).location != NSNotFound,
           let range = Range(match.range(at: 2), in: value) {
            var digits = String(value[range].dropFirst())
            if digits.count > 3 { digits = String(digits.prefix(3)) }
            while digits.count < 3 { digits.append("0") }
            fraction = ".\(digits)"
        }
        let timezone: String
        if match.range(at: 3).location != NSNotFound,
           let range = Range(match.range(at: 3), in: value) {
            timezone = String(value[range])
        } else {
            timezone = "Z"
        }
        return String(value[headRange]) + fraction + timezone
    }

    private static func jsonObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func number(_ value: Any?) -> Double? {
        if value is Bool { return nil }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }
}
