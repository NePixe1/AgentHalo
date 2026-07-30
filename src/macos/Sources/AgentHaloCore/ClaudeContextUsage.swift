import Darwin
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

public enum ClaudeContextUsageFreshness: Equatable, Sendable {
    case recentOnly
    case whileSessionIsLive
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
    private static let pruneLock = NSLock()
    private static let pruneLockFilename = ".prune.lock"
    private static let pruneMarkerFilename = ".last-prune"

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
        prune(directory: directory, force: false)
    }

    /// Best-effort GC for `cache/claude-contexts`.
    ///
    /// - Age: delete files older than ``ClaudeContextUsageConstants.diskMaxAge``
    ///   (prefer JSON `updatedAt`, else mtime).
    /// - Count: if more than ``maxFiles`` remain, delete oldest entries that are
    ///   older than ``minRetainAge`` until under the cap.
    /// - Throttle: when `force` is false, at most once per ``pruneThrottle``
    ///   across statusline-proxy processes.
    @discardableResult
    public static func prune(
        directory: URL = AgentHaloPaths().claudeContextsDirectory,
        force: Bool = false,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) -> Int {
        pruneLock.lock()
        defer { pruneLock.unlock() }

        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDir),
              isDir.boolValue else { return 0 }

        let lockURL = directory.appendingPathComponent(pruneLockFilename)
        let lockDescriptor = open(lockURL.path, O_CREAT | O_RDWR, mode_t(0o600))
        guard lockDescriptor >= 0 else {
            AgentHaloLogger.log(
                "ClaudeContextUsageStorage.prune: open lock failed: \(String(cString: strerror(errno)))"
            )
            return 0
        }
        defer { close(lockDescriptor) }
        _ = fchmod(lockDescriptor, mode_t(0o600))
        guard flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            return 0
        }
        defer { flock(lockDescriptor, LOCK_UN) }

        let markerURL = directory.appendingPathComponent(pruneMarkerFilename)
        if !force,
           let last = readPruneMarker(markerURL),
           now.timeIntervalSince(last) >= 0,
           now.timeIntervalSince(last) < ClaudeContextUsageConstants.pruneThrottle {
            return 0
        }

        let children: [URL]
        do {
            children = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            AgentHaloLogger.log("ClaudeContextUsageStorage.prune: list failed: \(error)")
            return 0
        }

        struct Entry {
            let url: URL
            let ageAnchor: Date
        }

        var entries: [Entry] = []
        for url in children {
            guard url.pathExtension == "json" else { continue }
            let resourceValues = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            guard resourceValues?.isRegularFile == true else { continue }
            let mtime = resourceValues?.contentModificationDate ?? now
            let ageAnchor = decodeUpdatedAt(url) ?? mtime
            entries.append(Entry(url: url, ageAnchor: ageAnchor))
        }

        var deleted = 0
        var remaining = entries

        // 1) Age prune
        remaining = remaining.filter { entry in
            let age = now.timeIntervalSince(entry.ageAnchor)
            if age > ClaudeContextUsageConstants.diskMaxAge {
                if (try? fileManager.removeItem(at: entry.url)) != nil {
                    deleted += 1
                    return false
                }
            }
            return true
        }

        // 2) Count prune (protect young files)
        if remaining.count > ClaudeContextUsageConstants.maxFiles {
            let sortedOldestFirst = remaining.sorted { $0.ageAnchor < $1.ageAnchor }
            var keep = remaining.count
            for entry in sortedOldestFirst {
                if keep <= ClaudeContextUsageConstants.maxFiles { break }
                let age = now.timeIntervalSince(entry.ageAnchor)
                if age < ClaudeContextUsageConstants.minRetainAge {
                    continue
                }
                if (try? fileManager.removeItem(at: entry.url)) != nil {
                    deleted += 1
                    keep -= 1
                }
            }
        }

        writePruneMarker(now, to: markerURL, fileManager: fileManager)
        return deleted
    }

    private static func decodeUpdatedAt(_ url: URL) -> Date? {
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(ClaudeContextUsageSnapshot.self, from: data) else {
            return nil
        }
        return snapshot.updatedAt
    }

    private static func readPruneMarker(_ url: URL) -> Date? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8),
              let seconds = TimeInterval(
                  raw.trimmingCharacters(in: .whitespacesAndNewlines)
              ) else {
            return nil
        }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func writePruneMarker(
        _ date: Date,
        to url: URL,
        fileManager: FileManager
    ) {
        do {
            try "\(date.timeIntervalSince1970)\n".write(
                to: url,
                atomically: true,
                encoding: .utf8
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        } catch {
            AgentHaloLogger.log(
                "ClaudeContextUsageStorage.prune: write marker failed: \(error)"
            )
        }
    }

    /// Compatibility test helper. Throttle state now lives in each cache
    /// directory's `.last-prune` marker instead of process memory.
    public static func resetPruneThrottleForTests() {
        // No process-global state remains.
    }
}

public struct ClaudeContextUsageReader: Sendable {
    public var snapshotsDirectory: URL

    public init(
        snapshotsDirectory: URL = AgentHaloPaths().claudeContextsDirectory
    ) {
        self.snapshotsDirectory = snapshotsDirectory
    }

    public func read(
        sessionId: String,
        now: Date = Date(),
        freshness: ClaudeContextUsageFreshness = .recentOnly
    ) -> ClaudeContextUsageSnapshot? {
        guard let snapshotURL = ClaudeContextUsageStorage.snapshotURL(
            directory: snapshotsDirectory,
            sessionId: sessionId
        ) else {
            return nil
        }

        if let snapshot = decode(snapshotURL),
           isUsable(snapshot, sessionId: sessionId, now: now, freshness: freshness) {
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
        now: Date,
        freshness: ClaudeContextUsageFreshness
    ) -> Bool {
        guard snapshot.sessionId == sessionId else { return false }
        let age = now.timeIntervalSince(snapshot.updatedAt)
        guard age >= -ClaudeContextUsageConstants.clockSkewTolerance else {
            return false
        }
        switch freshness {
        case .recentOnly:
            return age <= ClaudeContextUsageConstants.snapshotMaxAge
        case .whileSessionIsLive:
            return true
        }
    }
}
