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
        var primaryUsedPercent: Double?
        var secondaryUsedPercent: Double?
        var primaryResetAt: Date?
        var secondaryResetAt: Date?
        var contextUsedPercent: Double?

        for file in recentJSONLFiles().prefix(GeneratedHaloSpec.rateLimitRecentFileCount) {
            for line in tailLines(file).suffix(GeneratedHaloSpec.rateLimitRecentLineCount)
                .reversed() where line.contains(GeneratedHaloSpec.rateLimitMarker)
                    || line.contains("\"last_token_usage\"") {
                guard let data = line.data(using: .utf8),
                      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let payload = root[GeneratedHaloSpec.ratePayloadKey] as? [String: Any] else {
                    continue
                }
                let info = payload[GeneratedHaloSpec.rateInfoKey] as? [String: Any]
                let limits = (payload[GeneratedHaloSpec.rateLimitsKey] as? [String: Any])
                    ?? (info?[GeneratedHaloSpec.rateLimitsKey] as? [String: Any])
                if primaryUsedPercent == nil,
                   let primary = limits?[GeneratedHaloSpec.ratePrimaryKey] as? [String: Any],
                   let used = Self.number(primary[GeneratedHaloSpec.rateUsedPercentKey]) {
                    primaryUsedPercent = used
                    primaryResetAt = Self.unixTime(primary["resets_at"])
                }
                if secondaryUsedPercent == nil,
                   let secondary = limits?[GeneratedHaloSpec.rateSecondaryKey] as? [String: Any],
                   let used = Self.number(secondary[GeneratedHaloSpec.rateUsedPercentKey]) {
                    secondaryUsedPercent = used
                    secondaryResetAt = Self.unixTime(secondary["resets_at"])
                }
                if contextUsedPercent == nil {
                    contextUsedPercent = Self.contextUsedPercent(info: info)
                }
                if let primaryUsedPercent, let secondaryUsedPercent, contextUsedPercent != nil {
                    return RateLimitSnapshot(
                        primaryUsedPercent: primaryUsedPercent,
                        secondaryUsedPercent: secondaryUsedPercent,
                        primaryResetAt: primaryResetAt,
                        secondaryResetAt: secondaryResetAt,
                        contextUsedPercent: contextUsedPercent
                    )
                }
            }
        }
        guard let primaryUsedPercent, let secondaryUsedPercent else {
            return nil
        }
        return RateLimitSnapshot(
            primaryUsedPercent: primaryUsedPercent,
            secondaryUsedPercent: secondaryUsedPercent,
            primaryResetAt: primaryResetAt,
            secondaryResetAt: secondaryResetAt,
            contextUsedPercent: contextUsedPercent
        )
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
