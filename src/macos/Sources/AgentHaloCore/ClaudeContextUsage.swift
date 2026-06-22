import Foundation

public struct ClaudeContextUsageSnapshot: Codable, Equatable, Sendable {
    public var sessionId: String
    public var usedPercent: Double
    public var contextWindowSize: Int?
    public var modelName: String?
    public var inputTokens: Int64?
    public var outputTokens: Int64?
    public var updatedAt: Date

    public init(
        sessionId: String,
        usedPercent: Double,
        contextWindowSize: Int? = nil,
        modelName: String? = nil,
        inputTokens: Int64? = nil,
        outputTokens: Int64? = nil,
        updatedAt: Date
    ) {
        self.sessionId = sessionId
        self.usedPercent = usedPercent
        self.contextWindowSize = contextWindowSize
        self.modelName = modelName
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.updatedAt = updatedAt
    }
}

public enum ClaudeStatusLineUsageParser {
    public static func parse(data: Data, updatedAt: Date = Date()) -> ClaudeContextUsageSnapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            AgentHaloLogger.log("ClaudeStatusLineUsageParser: invalid JSON format")
            return nil
        }

        guard let sessionId = root["session_id"] as? String, !sessionId.isEmpty else {
            AgentHaloLogger.log("ClaudeStatusLineUsageParser: missing or empty session_id")
            return nil
        }

        guard let context = root["context_window"] as? [String: Any] else {
            AgentHaloLogger.log("ClaudeStatusLineUsageParser: missing context_window object")
            return nil
        }

        guard let usedPercent = number(context["used_percentage"]) else {
            AgentHaloLogger.log("ClaudeStatusLineUsageParser: invalid used_percentage value: \(context["used_percentage"] ?? "nil")")
            return nil
        }

        guard (0...100).contains(usedPercent) else {
            AgentHaloLogger.log("ClaudeStatusLineUsageParser: used_percentage out of range: \(usedPercent)")
            return nil
        }

        return ClaudeContextUsageSnapshot(
            sessionId: sessionId,
            usedPercent: usedPercent,
            contextWindowSize: number(context["context_window_size"]).map { Int($0) },
            modelName: modelName(root["model"]),
            inputTokens: number(context["total_input_tokens"]).map { Int64($0) },
            outputTokens: number(context["total_output_tokens"]).map { Int64($0) },
            updatedAt: updatedAt
        )
    }

    private static func modelName(_ value: Any?) -> String? {
        guard let model = value as? [String: Any] else {
            return nil
        }
        for key in ["id", "display_name"] {
            if let value = model[key] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
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

    private struct CachedSnapshot: Sendable {
        var snapshotURL: URL
        var snapshot: ClaudeContextUsageSnapshot
        var fileModificationDate: Date
    }

    private final class Cache: @unchecked Sendable {
        private let queue = DispatchQueue(label: "com.agenthalo.context-cache")
        private var cachedSnapshot: CachedSnapshot?

        func get() -> CachedSnapshot? {
            queue.sync { cachedSnapshot }
        }

        func set(_ snapshot: CachedSnapshot?) {
            queue.sync { cachedSnapshot = snapshot }
        }
    }

    private static let cache = Cache()

    public init(
        snapshotURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".agent-halo", isDirectory: true)
            .appendingPathComponent("claude-code-context.json")
    ) {
        self.snapshotURL = snapshotURL
    }

    public func read(sessionIds: [String], now: Date = Date()) -> ClaudeContextUsageSnapshot? {
        let normalizedSnapshotURL = snapshotURL.standardizedFileURL
        let attributes = try? FileManager.default.attributesOfItem(atPath: snapshotURL.path)
        guard let modDate = attributes?[.modificationDate] as? Date else {
            return nil
        }

        if let cachedValue = Self.cache.get(),
           cachedValue.snapshotURL == normalizedSnapshotURL,
           cachedValue.fileModificationDate == modDate,
           (sessionIds.isEmpty || sessionIds.contains(cachedValue.snapshot.sessionId)) {
            let age = now.timeIntervalSince(cachedValue.snapshot.updatedAt)
            guard age >= -ClaudeContextUsageConstants.clockSkewTolerance else {
                return nil
            }
            return cachedValue.snapshot
        }

        guard let data = try? Data(contentsOf: snapshotURL),
              let snapshot = try? JSONDecoder().decode(ClaudeContextUsageSnapshot.self, from: data) else {
            Self.cache.set(nil)
            return nil
        }

        if !sessionIds.isEmpty, !sessionIds.contains(snapshot.sessionId) {
            Self.cache.set(nil)
            return nil
        }

        let age = now.timeIntervalSince(snapshot.updatedAt)
        guard age >= -ClaudeContextUsageConstants.clockSkewTolerance else {
            Self.cache.set(nil)
            return nil
        }

        Self.cache.set(CachedSnapshot(
            snapshotURL: normalizedSnapshotURL,
            snapshot: snapshot,
            fileModificationDate: modDate
        ))
        return snapshot
    }
}
