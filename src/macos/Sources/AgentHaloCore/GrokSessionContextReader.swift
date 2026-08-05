import Darwin
import Foundation

/// Live Grok Build session context occupancy, read from the session store.
///
/// End-of-turn occupancy lives in
/// `~/.grok/sessions/<percent-encoded-cwd>/<sessionId>/signals.json`
/// (`contextWindowUsage` / token counters). During a long turn those fields
/// freeze, so the reader also tails `updates.jsonl` for streaming
/// `params._meta.totalTokens` — the same running estimate the TUI uses.
public struct GrokSessionContextSnapshot: Equatable, Sendable {
    public var sessionId: String
    public var contextUsedPercent: Double
    public var contextTokensUsed: Int64?
    public var contextWindowTokens: Int64?
    public var modelName: String?
    public var projectName: String?
    public var sessionTitle: String?
    public var workingDirectory: String?

    public init(
        sessionId: String,
        contextUsedPercent: Double,
        contextTokensUsed: Int64? = nil,
        contextWindowTokens: Int64? = nil,
        modelName: String? = nil,
        projectName: String? = nil,
        sessionTitle: String? = nil,
        workingDirectory: String? = nil
    ) {
        self.sessionId = sessionId
        self.contextUsedPercent = contextUsedPercent
        self.contextTokensUsed = contextTokensUsed
        self.contextWindowTokens = contextWindowTokens
        self.modelName = modelName
        self.projectName = projectName
        self.sessionTitle = sessionTitle
        self.workingDirectory = workingDirectory
    }
}

public struct GrokActiveSessionRef: Equatable, Sendable {
    public var sessionId: String
    public var cwd: String?
    /// Optional process id from `active_sessions.json` (`pid`). Used for cheap
    /// liveness checks via `kill(pid, 0)` — never spawn `ps`.
    public var processId: Int32?

    public init(sessionId: String, cwd: String? = nil, processId: Int32? = nil) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.processId = processId
    }
}

/// Parses `~/.grok/active_sessions.json` (array of `{session_id, cwd, pid, ...}`).
public enum GrokActiveSessionsReader {
    public static func read(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> [GrokActiveSessionRef] {
        let url = homeDirectory
            .appendingPathComponent(".grok", isDirectory: true)
            .appendingPathComponent("active_sessions.json")
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              !data.isEmpty else {
            return []
        }
        if let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return array.compactMap(parseEntry)
        }
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["sessions", "active_sessions"] {
                if let array = root[key] as? [[String: Any]] {
                    return array.compactMap(parseEntry)
                }
            }
        }
        return []
    }

    /// True when `active_sessions.json` lists at least one live session.
    ///
    /// Prefer PID liveness (`kill(pid, 0)` / `EPERM`) when a pid is present.
    /// Entries without a pid still count as present so older file shapes keep
    /// working. Never shells out to `ps` — subprocess presence probes have
    /// hung Agent Halo's Grok activity queue indefinitely.
    public static func hasLiveSession(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        isProcessAlive: (Int32) -> Bool = defaultIsProcessAlive
    ) -> Bool {
        !liveSessionIds(
            homeDirectory: homeDirectory,
            fileManager: fileManager,
            isProcessAlive: isProcessAlive
        ).isEmpty
    }

    /// Session ids that are still backed by a live Grok process.
    ///
    /// Older `active_sessions.json` shapes omitted `pid`; when every entry is
    /// pid-less, keep treating the listed ids as live for compatibility. Once
    /// any pid is available, require its process to still exist so stale file
    /// entries cannot keep an old hook snapshot actionable.
    public static func liveSessionIds(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        isProcessAlive: (Int32) -> Bool = defaultIsProcessAlive
    ) -> Set<String> {
        let sessions = read(homeDirectory: homeDirectory, fileManager: fileManager)
        guard !sessions.isEmpty else {
            return []
        }
        let withPid = sessions.filter { $0.processId != nil }
        if withPid.isEmpty {
            return Set(sessions.map(\.sessionId))
        }
        return Set(withPid.compactMap { session in
            guard let processId = session.processId, isProcessAlive(processId) else {
                return nil
            }
            return session.sessionId
        })
    }

    public static func defaultIsProcessAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else {
            return false
        }
        errno = 0
        return kill(pid, 0) == 0 || errno == EPERM
    }

    private static func parseEntry(_ entry: [String: Any]) -> GrokActiveSessionRef? {
        let sessionId = firstString(entry["session_id"], entry["sessionId"], entry["id"])
        guard !sessionId.isEmpty else {
            return nil
        }
        let cwd = firstString(entry["cwd"], entry["working_directory"], entry["workingDirectory"])
        let processId: Int32?
        if let number = entry["pid"] as? NSNumber, number.int32Value > 0 {
            processId = number.int32Value
        } else if let int = entry["pid"] as? Int, int > 0, int <= Int(Int32.max) {
            processId = Int32(int)
        } else {
            processId = nil
        }
        return GrokActiveSessionRef(
            sessionId: sessionId,
            cwd: cwd.isEmpty ? nil : cwd,
            processId: processId
        )
    }

    private static func firstString(_ values: Any?...) -> String {
        for value in values {
            if let string = value as? String, !string.isEmpty {
                return string
            }
        }
        return ""
    }
}

public struct GrokSessionContextReader: @unchecked Sendable {
    private let sessionsRoot: URL
    private let fileManager: FileManager

    /// How much of the (often multi‑MB) `updates.jsonl` to scan for the latest
    /// `totalTokens`. Large enough for a long tool/thought burst, small enough
    /// for the 0.3s details refresh path.
    private static let updatesTailByteLimit = 256 * 1024

    /// Grok Build commonly reports a 500k window in `signals.json`. Used when a
    /// brand-new session has live `totalTokens` but no end-of-turn signals yet.
    public static let defaultContextWindowTokens: Int64 = 500_000

    public init(
        sessionsRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true),
        fileManager: FileManager = .default
    ) {
        self.sessionsRoot = sessionsRoot
        self.fileManager = fileManager
    }

    /// Read context occupancy for an exact session id.
    /// - Parameter cwd: Optional workspace path; when present, resolves the
    ///   percent-encoded session directory without scanning.
    public func read(sessionId: String, cwd: String? = nil) -> GrokSessionContextSnapshot? {
        guard !sessionId.isEmpty,
              let sessionDirectory = resolveSessionDirectory(sessionId: sessionId, cwd: cwd) else {
            return nil
        }
        return read(sessionId: sessionId, sessionDirectory: sessionDirectory)
    }

    public func read(sessionId: String, sessionDirectory: URL) -> GrokSessionContextSnapshot? {
        // `signals.json` is end-of-turn only. New sessions and long mid-turn
        // windows may have only streaming `updates.jsonl` totalTokens — still
        // enough to drive the context pill.
        let signalsRoot = loadJSONObject(named: "signals.json", in: sessionDirectory)
        let liveTokens = latestLiveContextTokens(sessionDirectory: sessionDirectory)

        var tokensUsed = signalsRoot.flatMap { int64($0["contextTokensUsed"]) }
        var windowTokens = signalsRoot.flatMap { int64($0["contextWindowTokens"]) }
        var percent = signalsRoot.flatMap { contextUsedPercent(from: $0) }
        var modelName = signalsRoot.flatMap { string($0["primaryModelId"]) }

        if let liveTokens, liveTokens >= 0 {
            tokensUsed = liveTokens
            let window = (windowTokens ?? 0) > 0
                ? windowTokens!
                : Self.defaultContextWindowTokens
            windowTokens = window
            percent = min(100, max(0, Double(liveTokens) * 100 / Double(window)))
        }

        guard let percent else {
            return nil
        }

        var sessionTitle: String?
        var workingDirectory: String?
        var projectName: String?

        if let summary = loadJSONObject(named: "summary.json", in: sessionDirectory) {
            if modelName == nil || modelName?.isEmpty == true {
                modelName = string(summary["current_model_id"])
            }
            sessionTitle = firstNonEmpty(
                string(summary["generated_title"]),
                string(summary["session_summary"])
            )
            if let info = summary["info"] as? [String: Any] {
                workingDirectory = string(info["cwd"])
            }
            workingDirectory = workingDirectory ?? string(summary["working_directory"])
        }

        if let workingDirectory, !workingDirectory.isEmpty {
            let leaf = URL(fileURLWithPath: workingDirectory).lastPathComponent
            projectName = leaf.isEmpty ? nil : leaf
        }

        return GrokSessionContextSnapshot(
            sessionId: sessionId,
            contextUsedPercent: percent,
            contextTokensUsed: tokensUsed,
            contextWindowTokens: windowTokens,
            modelName: modelName.flatMap { $0.isEmpty ? nil : $0 },
            projectName: projectName,
            sessionTitle: sessionTitle,
            workingDirectory: workingDirectory
        )
    }

    /// Grok stores workspace folders as fully percent-encoded absolute paths
    /// (every `/` becomes `%2F`), matching Python `urllib.parse.quote(path, safe="")`.
    public static func encodeWorkspaceDirectory(_ cwd: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return cwd.addingPercentEncoding(withAllowedCharacters: allowed) ?? cwd
    }

    private func resolveSessionDirectory(sessionId: String, cwd: String?) -> URL? {
        if let cwd, !cwd.isEmpty {
            let encoded = Self.encodeWorkspaceDirectory(cwd)
            let candidate = sessionsRoot
                .appendingPathComponent(encoded, isDirectory: true)
                .appendingPathComponent(sessionId, isDirectory: true)
            if isSessionDirectory(candidate) {
                return candidate
            }
        }

        guard fileManager.fileExists(atPath: sessionsRoot.path),
              let workspaces = try? fileManager.contentsOfDirectory(
                at: sessionsRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
              ) else {
            return nil
        }

        for workspace in workspaces {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: workspace.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                continue
            }
            let candidate = workspace.appendingPathComponent(sessionId, isDirectory: true)
            if isSessionDirectory(candidate) {
                return candidate
            }
        }
        return nil
    }

    /// Session dirs may exist with only live `updates.jsonl` before the first
    /// end-of-turn `signals.json` is written.
    private func isSessionDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return false
        }
        for name in ["signals.json", "updates.jsonl", "summary.json", "chat_history.jsonl"] {
            if fileManager.fileExists(atPath: url.appendingPathComponent(name).path) {
                return true
            }
        }
        return false
    }

    private func loadJSONObject(named name: String, in directory: URL) -> [String: Any]? {
        let url = directory.appendingPathComponent(name)
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return root
    }

    private func contextUsedPercent(from root: [String: Any]) -> Double? {
        if let raw = number(root["contextWindowUsage"]), (0...100).contains(raw) {
            return raw
        }
        if let used = number(root["contextTokensUsed"]),
           let window = number(root["contextWindowTokens"]),
           window > 0 {
            return min(100, max(0, used * 100 / window))
        }
        return nil
    }

    /// Tail-scan `updates.jsonl` for the newest `params._meta.totalTokens`.
    /// Returns `nil` when the file is missing or the tail has no token field.
    private func latestLiveContextTokens(sessionDirectory: URL) -> Int64? {
        let updatesURL = sessionDirectory.appendingPathComponent("updates.jsonl")
        guard fileManager.fileExists(atPath: updatesURL.path),
              let handle = try? FileHandle(forReadingFrom: updatesURL) else {
            return nil
        }
        defer {
            try? handle.close()
        }

        let endOffset: UInt64
        do {
            endOffset = try handle.seekToEnd()
        } catch {
            return nil
        }
        guard endOffset > 0 else {
            return nil
        }

        let limit = UInt64(Self.updatesTailByteLimit)
        let startOffset = endOffset > limit ? endOffset - limit : 0
        do {
            try handle.seek(toOffset: startOffset)
        } catch {
            return nil
        }
        guard let data = try? handle.readToEnd(), !data.isEmpty else {
            return nil
        }

        let text = String(decoding: data, as: UTF8.self)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        // Drop a possibly truncated first line when we sought into the middle.
        if startOffset > 0, !lines.isEmpty {
            lines.removeFirst()
        }

        for line in lines.reversed() where line.contains("totalTokens") {
            if let tokens = totalTokens(fromJSONLine: String(line)) {
                return tokens
            }
        }
        return nil
    }

    private func totalTokens(fromJSONLine line: String) -> Int64? {
        guard let data = line.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let meta = (root["params"] as? [String: Any])?["_meta"] as? [String: Any]
        guard let raw = number(meta?["totalTokens"]), raw >= 0 else {
            return nil
        }
        return Int64(raw.rounded())
    }

    private func number(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private func int64(_ value: Any?) -> Int64? {
        number(value).map { Int64($0.rounded()) }
    }

    private func string(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let string = value as? String {
            return string
        }
        return String(describing: value)
    }

    private func firstNonEmpty(_ values: String?...) -> String? {
        for value in values {
            if let value, !value.isEmpty {
                return value
            }
        }
        return nil
    }
}
