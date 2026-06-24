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

public enum ClaudeContextUsageStorage {
    public static func snapshotURL(directory: URL, sessionId: String) -> URL? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        guard !sessionId.isEmpty,
              sessionId.count <= 128,
              sessionId.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return nil
        }
        return directory.appendingPathComponent("\(sessionId).json", isDirectory: false)
    }

    public static func write(_ snapshot: ClaudeContextUsageSnapshot, directory: URL) throws {
        guard let url = snapshotURL(directory: directory, sessionId: snapshot.sessionId) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try JSONEncoder().encode(snapshot).write(to: url, options: [.atomic])
    }
}

public struct ClaudeContextUsageReader: Sendable {
    public var snapshotsDirectory: URL
    public var legacySnapshotURL: URL?

    public init(
        snapshotsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".agent-halo", isDirectory: true)
            .appendingPathComponent("claude-code-contexts", isDirectory: true),
        legacySnapshotURL: URL? = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".agent-halo", isDirectory: true)
            .appendingPathComponent("claude-code-context.json", isDirectory: false)
    ) {
        self.snapshotsDirectory = snapshotsDirectory
        self.legacySnapshotURL = legacySnapshotURL
    }

    /// Compatibility initializer for callers that still provide the legacy
    /// single-file location. Reads remain exact-session and freshness checked.
    public init(snapshotURL: URL) {
        snapshotsDirectory = snapshotURL.deletingLastPathComponent()
            .appendingPathComponent("claude-code-contexts", isDirectory: true)
        legacySnapshotURL = snapshotURL
    }

    public func read(sessionId: String, now: Date = Date()) -> ClaudeContextUsageSnapshot? {
        guard let snapshotURL = ClaudeContextUsageStorage.snapshotURL(
            directory: snapshotsDirectory,
            sessionId: sessionId
        ) else {
            return nil
        }

        if let snapshot = decode(snapshotURL), isUsable(snapshot, sessionId: sessionId, now: now) {
            return snapshot
        }

        if let legacySnapshotURL,
           let snapshot = decode(legacySnapshotURL),
           isUsable(snapshot, sessionId: sessionId, now: now) {
            return snapshot
        }
        return nil
    }

    public func read(sessionIds: [String], now: Date = Date()) -> ClaudeContextUsageSnapshot? {
        for sessionId in sessionIds where sessionId != "claude-code" {
            if let snapshot = read(sessionId: sessionId, now: now) {
                return snapshot
            }
        }
        return nil
    }

    private func decode(_ url: URL) -> ClaudeContextUsageSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ClaudeContextUsageSnapshot.self, from: data)
    }

    private func isUsable(
        _ snapshot: ClaudeContextUsageSnapshot,
        sessionId: String,
        now: Date
    ) -> Bool {
        guard snapshot.sessionId == sessionId else { return false }
        let age = now.timeIntervalSince(snapshot.updatedAt)
        return age >= -ClaudeContextUsageConstants.clockSkewTolerance
            && age <= ClaudeContextUsageConstants.snapshotMaxAge
    }
}
