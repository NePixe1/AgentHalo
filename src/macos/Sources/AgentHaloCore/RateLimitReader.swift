import Foundation

public struct RateLimitReader: @unchecked Sendable {
    public var roots: [URL]
    public var fileManager: FileManager

    public init(
        roots: [URL] = [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/archived_sessions", isDirectory: true)
        ],
        fileManager: FileManager = .default
    ) {
        self.roots = roots
        self.fileManager = fileManager
    }

    public func read() -> RateLimitSnapshot? {
        var metrics = UsageMetrics()
        for file in recentJSONLFiles().prefix(GeneratedHaloSpec.rateLimitRecentFileCount) {
            for line in tailLines(file).suffix(GeneratedHaloSpec.rateLimitRecentLineCount)
                .reversed() where line.contains(GeneratedHaloSpec.rateLimitMarker)
                    || line.contains("\"last_token_usage\"") {
                applyLine(line, into: &metrics)
                if hasCompleteMetrics(metrics) {
                    return metrics.toSnapshot()
                }
            }
        }
        return metrics.toSnapshot()
    }

    private func applyLine(_ line: String, into metrics: inout UsageMetrics) {
        guard let data = line.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root[GeneratedHaloSpec.ratePayloadKey] as? [String: Any] else {
            return
        }
        let info = payload[GeneratedHaloSpec.rateInfoKey] as? [String: Any]
        let limits = (payload[GeneratedHaloSpec.rateLimitsKey] as? [String: Any])
            ?? (info?[GeneratedHaloSpec.rateLimitsKey] as? [String: Any])

        if metrics.contextUsedPercent == nil {
            metrics.contextUsedPercent = Self.contextUsedPercent(info: info)
        }

        guard let limits else { return }

        let primary = limits[GeneratedHaloSpec.ratePrimaryKey] as? [String: Any]
        let secondary = limits[GeneratedHaloSpec.rateSecondaryKey] as? [String: Any]
        let secondaryLooksMonthlyPlan = secondary != nil
            && Self.looksLikeMonthlyPlanWithoutExplicitUsage(in: limits)

        // Monthly quota: explicit `monthly`-style buckets first, then the
        // "credits" container free / basic plans expose.
        if metrics.monthlyUsedPercent == nil,
           let monthly = Self.findMonthlyLimit(limits) {
            metrics.hasMonthlyPlan = true
            metrics.monthlyUsedPercent = Self.usedPercentOrNil(monthly)
            metrics.monthlyResetAt = Self.unixTime(monthly["resets_at"])
        }

        // A solo primary entry with a 30-day window or a `monthly`-flavored
        // plan name is the Codex free-plan shape — treat it as monthly instead
        // of the Plus 5-hour bucket so the panel shows the right title.
        let primaryLooksMonthly = primary != nil
            && secondary == nil
            && Self.looksLikeMonthlyLimit(primary, in: limits)

        if metrics.monthlyUsedPercent == nil, primaryLooksMonthly, let primary,
           let used = Self.usedPercentOrNil(primary) {
            metrics.hasMonthlyPlan = true
            metrics.monthlyUsedPercent = used
            metrics.monthlyResetAt = Self.unixTime(primary["resets_at"])
        }

        if metrics.monthlyUsedPercent == nil, secondaryLooksMonthlyPlan {
            metrics.hasMonthlyPlan = true
        }

        if metrics.primaryUsedPercent == nil, !primaryLooksMonthly, !secondaryLooksMonthlyPlan,
           let primary,
           let used = Self.usedPercentOrNil(primary) {
            metrics.primaryUsedPercent = used
            metrics.primaryResetAt = Self.unixTime(primary["resets_at"])
        }
        if metrics.secondaryUsedPercent == nil, !secondaryLooksMonthlyPlan,
           let secondary,
           let used = Self.usedPercentOrNil(secondary) {
            metrics.secondaryUsedPercent = used
            metrics.secondaryResetAt = Self.unixTime(secondary["resets_at"])
        }
    }

    // Plus tier needs both 5h + week buckets together with context to be
    // considered complete; monthly tiers only need actual monthly usage
    // plus context. A plan marker without usage is a fallback shape, not a
    // terminal snapshot, because older lines may still contain the quota.
    private func hasCompleteMetrics(_ metrics: UsageMetrics) -> Bool {
        guard metrics.contextUsedPercent != nil else { return false }
        if metrics.primaryUsedPercent != nil && metrics.secondaryUsedPercent != nil {
            return true
        }
        return metrics.monthlyUsedPercent != nil
    }

    private struct UsageMetrics {
        var primaryUsedPercent: Double?
        var secondaryUsedPercent: Double?
        var primaryResetAt: Date?
        var secondaryResetAt: Date?
        var monthlyUsedPercent: Double?
        var monthlyResetAt: Date?
        var contextUsedPercent: Double?
        var hasMonthlyPlan = false

        var hasAny: Bool {
            primaryUsedPercent != nil
                || secondaryUsedPercent != nil
                || monthlyUsedPercent != nil
                || hasMonthlyPlan
                || contextUsedPercent != nil
        }

        func toSnapshot() -> RateLimitSnapshot? {
            guard hasAny else { return nil }
            return RateLimitSnapshot(
                primaryUsedPercent: primaryUsedPercent ?? 0,
                secondaryUsedPercent: secondaryUsedPercent ?? 0,
                primaryResetAt: primaryResetAt,
                secondaryResetAt: secondaryResetAt,
                contextUsedPercent: contextUsedPercent,
                hasPrimary: primaryUsedPercent != nil,
                hasSecondary: secondaryUsedPercent != nil,
                hasMonthlyPlan: hasMonthlyPlan,
                monthlyUsedPercent: monthlyUsedPercent,
                monthlyResetAt: monthlyResetAt
            )
        }
    }

    private static func findMonthlyLimit(_ limits: [String: Any]) -> [String: Any]? {
        let keys = ["monthly", "month", "monthly_usage", "monthly_quota"]
        for key in keys {
            if let child = limits[key] as? [String: Any] {
                return child
            }
        }
        if let credits = limits["credits"] as? [String: Any],
           hasAnyNumber(credits, keys: ["used_percent", "remaining_percent", "resets_at"]) {
            return credits
        }
        return nil
    }

    private static func looksLikeMonthlyLimit(_ limit: [String: Any]?, in limits: [String: Any]) -> Bool {
        guard let limit else { return false }
        if let window = number(limit["window_minutes"]),
           window >= Double(28 * 24 * 60) {
            return true
        }
        // Fall back to an exact plan_type/limit_name token. Substring matching
        // here risks misclassifying a Plus plan whose name happens to embed one
        // of these words (e.g. "plus_basic", "month_end_reset") as monthly,
        // which would hide the 5h/week buckets behind a single "月额度" row.
        // Explicit `monthly`-keyed buckets are already caught by
        // findMonthlyLimit before this runs, so the token match only needs to
        // recognise a solo `primary` bucket on a free/basic/monthly plan.
        let plan = (limits["plan_type"] as? String)?.lowercased() ?? ""
        let name = (limits["limit_name"] as? String)?.lowercased() ?? ""
        let monthlyTokens: Set<String> = ["monthly", "month", "free", "basic"]
        return monthlyTokens.contains(plan) || monthlyTokens.contains(name)
    }

    private static func looksLikeMonthlyPlanWithoutExplicitUsage(in limits: [String: Any]) -> Bool {
        let plan = (limits["plan_type"] as? String)?.lowercased() ?? ""
        let name = (limits["limit_name"] as? String)?.lowercased() ?? ""
        let monthlyTokens: Set<String> = ["monthly", "month", "free", "basic"]
        if monthlyTokens.contains(plan) || monthlyTokens.contains(name) {
            return true
        }
        return false
    }

    /// Used-percent for a quota bucket, preferring `used_percent` and falling
    /// back to `100 - remaining_percent`. Returns nil when neither field is
    /// present so an empty bucket doesn't masquerade as a real 0% — the
    /// hasPrimary/hasSecondary/hasMonthly flags rely on that distinction.
    private static func usedPercentOrNil(_ source: [String: Any]) -> Double? {
        if let used = number(source[GeneratedHaloSpec.rateUsedPercentKey]) {
            return used
        }
        if let remaining = number(source["remaining_percent"]) {
            return 100 - remaining
        }
        return nil
    }

    private static func hasAnyNumber(_ source: [String: Any], keys: [String]) -> Bool {
        for key in keys {
            if number(source[key]) != nil {
                return true
            }
        }
        return false
    }

    private func recentJSONLFiles() -> [URL] {
        roots.flatMap { root -> [URL] in
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]
            ) else {
                return []
            }
            return enumerator.compactMap { item in
                guard let url = item as? URL, url.pathExtension == "jsonl" else {
                    return nil
                }
                return url
            }
        }
        .sorted {
            modificationDate($0) > modificationDate($1)
        }
    }

    private func tailLines(_ url: URL) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return []
        }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let tailBytes = UInt64(GeneratedHaloSpec.rateLimitTailBytes)
        let start = size > tailBytes ? size - tailBytes : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(),
              var text = String(data: data, encoding: .utf8) else {
            return []
        }
        if start > 0, let newline = text.firstIndex(of: "\n") {
            text.removeSubrange(text.startIndex...newline)
        }
        return text.split(whereSeparator: \.isNewline).map(String.init)
    }

    private static func number(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func unixTime(_ value: Any?) -> Date? {
        guard let seconds = number(value), seconds > 0 else {
            return nil
        }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func contextUsedPercent(info: [String: Any]?) -> Double? {
        guard let info,
              let usage = info["last_token_usage"] as? [String: Any],
              let inputTokens = number(usage["input_tokens"]),
              let contextWindow = number(info["model_context_window"]),
              contextWindow > 0 else {
            return nil
        }
        return min(100, max(0, inputTokens * 100 / contextWindow))
    }

    private func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}

extension RateLimitReader {
    /// Test seam: feed pre-collected JSONL lines (newest first) into the parser
    /// without touching the disk. Mirrors the Windows
    /// `TryReadFromNewestLinesForTest` entry point so the self-test fixtures
    /// can stay platform-agnostic.
    public func parseForTest(lines: [String]) -> RateLimitSnapshot? {
        var metrics = UsageMetrics()
        for line in lines {
            applyLine(line, into: &metrics)
            if hasCompleteMetrics(metrics) {
                return metrics.toSnapshot()
            }
        }
        return metrics.toSnapshot()
    }
}
