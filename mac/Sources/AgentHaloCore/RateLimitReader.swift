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
        for file in recentJSONLFiles().prefix(16) {
            for line in tailLines(file).suffix(300).reversed() where line.contains("\"rate_limits\"") {
                guard let data = line.data(using: .utf8),
                      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let payload = root["payload"] as? [String: Any] else {
                    continue
                }
                let info = payload["info"] as? [String: Any]
                let limits = (payload["rate_limits"] as? [String: Any]) ?? (info?["rate_limits"] as? [String: Any])
                guard let primary = limits?["primary"] as? [String: Any],
                      let secondary = limits?["secondary"] as? [String: Any],
                      let primaryUsed = Self.number(primary["used_percent"]),
                      let secondaryUsed = Self.number(secondary["used_percent"]) else {
                    continue
                }
                return RateLimitSnapshot(primaryUsedPercent: primaryUsed, secondaryUsedPercent: secondaryUsed)
            }
        }
        return nil
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
        let start = size > 1_048_576 ? size - 1_048_576 : 0
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
        if let string = value as? String { return Double(string) }
        return nil
    }

    private func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}
