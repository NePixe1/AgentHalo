import Foundation

public enum ClaudeUsageMapper {
    public static let sessionDuration: TimeInterval = 18_000
    public static let weeklyDuration: TimeInterval = 604_800

    public static func map(
        response: UsageHTTPResponse,
        accountKey: AccountCacheKey,
        planHint: OAuthPlanHint?,
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

        guard let body = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] else {
            throw UsageProviderFailure.invalidResponse
        }
        let planName = formatPlan(
            subscriptionType: planHint?.subscriptionType,
            rateLimitTier: planHint?.rateLimitTier
        )
        let windows = [
            window(body["five_hour"], kind: .session, duration: sessionDuration),
            window(body["seven_day"], kind: .weekly, duration: weeklyDuration),
        ].compactMap { $0 }
        guard planName != nil || !windows.isEmpty else {
            throw UsageProviderFailure.invalidResponse
        }
        return UsageSnapshot(
            providerID: .claude,
            accountKey: accountKey,
            planName: planName,
            windows: windows,
            refreshedAt: now
        )
    }

    public static func formatPlan(subscriptionType: String?, rateLimitTier: String?) -> String? {
        guard let raw = subscriptionType?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else {
            return nil
        }
        let base = raw.split(whereSeparator: { $0 == " " || $0 == "_" || $0 == "-" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
        guard let tier = rateLimitTier,
              let range = tier.range(of: #"\d+x"#, options: [.regularExpression, .caseInsensitive])
        else {
            return base
        }
        return "\(base) \(tier[range].lowercased())"
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

    private static func window(
        _ value: Any?,
        kind: UsageWindowKind,
        duration: TimeInterval
    ) -> UsageWindow? {
        guard let object = value as? [String: Any],
              let utilization = number(object["utilization"])
        else {
            return nil
        }
        return UsageWindow(
            kind: kind,
            usedPercent: min(100, max(0, utilization)),
            resetsAt: resetDate(object["resets_at"]),
            duration: duration
        )
    }

    private static func resetDate(_ value: Any?) -> Date? {
        if let text = value as? String {
            let normalized = normalizeTimestamp(text)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: normalized) { return date }
            if let date = ISO8601DateFormatter().date(from: normalized) { return date }
        }
        guard let raw = number(value), raw.isFinite else { return nil }
        let seconds = abs(raw) < 10_000_000_000 ? raw : raw / 1000
        return Date(timeIntervalSince1970: seconds)
    }

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

    private static func number(_ value: Any?) -> Double? {
        if value is Bool { return nil }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }
}
