import Foundation

public struct ClaudeContextUsageSnapshot: Codable, Equatable, Sendable {
    public var sessionId: String
    public var usedPercent: Double
    public var contextWindowSize: Int?
    public var updatedAt: Date

    public init(
        sessionId: String,
        usedPercent: Double,
        contextWindowSize: Int? = nil,
        updatedAt: Date
    ) {
        self.sessionId = sessionId
        self.usedPercent = usedPercent
        self.contextWindowSize = contextWindowSize
        self.updatedAt = updatedAt
    }
}

public enum ClaudeStatusLineUsageParser {
    public static func parse(data: Data, updatedAt: Date = Date()) -> ClaudeContextUsageSnapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessionId = root["session_id"] as? String,
              !sessionId.isEmpty,
              let context = root["context_window"] as? [String: Any],
              let usedPercent = number(context["used_percentage"]),
              (0...100).contains(usedPercent) else {
            return nil
        }

        return ClaudeContextUsageSnapshot(
            sessionId: sessionId,
            usedPercent: usedPercent,
            contextWindowSize: number(context["context_window_size"]).map { Int($0) },
            updatedAt: updatedAt
        )
    }

    private static func number(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }
}

public struct ClaudeContextUsageReader: Sendable {
    public var snapshotURL: URL

    public init(
        snapshotURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".agent-halo", isDirectory: true)
            .appendingPathComponent("claude-code-context.json")
    ) {
        self.snapshotURL = snapshotURL
    }

    public func read(sessionIds: [String], now: Date = Date()) -> ClaudeContextUsageSnapshot? {
        guard let data = try? Data(contentsOf: snapshotURL),
              let snapshot = try? JSONDecoder().decode(ClaudeContextUsageSnapshot.self, from: data) else {
            return nil
        }
        if !sessionIds.isEmpty, !sessionIds.contains(snapshot.sessionId) {
            return nil
        }

        let age = now.timeIntervalSince(snapshot.updatedAt)
        guard age >= -30 else {
            return nil
        }
        return snapshot
    }
}
