import Foundation

/// Live Grok Build session context occupancy, read from the session store.
///
/// Grok persists `contextWindowUsage` (percent) plus token counters in
/// `~/.grok/sessions/<percent-encoded-cwd>/<sessionId>/signals.json`. This is
/// the same figure `/context` and the TUI status line use.
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

    public init(sessionId: String, cwd: String? = nil) {
        self.sessionId = sessionId
        self.cwd = cwd
    }
}

/// Parses `~/.grok/active_sessions.json` (array of `{session_id, cwd, ...}`).
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

    private static func parseEntry(_ entry: [String: Any]) -> GrokActiveSessionRef? {
        let sessionId = firstString(entry["session_id"], entry["sessionId"], entry["id"])
        guard !sessionId.isEmpty else {
            return nil
        }
        let cwd = firstString(entry["cwd"], entry["working_directory"], entry["workingDirectory"])
        return GrokActiveSessionRef(
            sessionId: sessionId,
            cwd: cwd.isEmpty ? nil : cwd
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
        let signalsURL = sessionDirectory.appendingPathComponent("signals.json")
        guard fileManager.fileExists(atPath: signalsURL.path),
              let data = try? Data(contentsOf: signalsURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        guard let percent = contextUsedPercent(from: root) else {
            return nil
        }

        var modelName = string(root["primaryModelId"])
        var sessionTitle: String?
        var workingDirectory: String?
        var projectName: String?

        let summaryURL = sessionDirectory.appendingPathComponent("summary.json")
        if fileManager.fileExists(atPath: summaryURL.path),
           let summaryData = try? Data(contentsOf: summaryURL),
           let summary = try? JSONSerialization.jsonObject(with: summaryData) as? [String: Any] {
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
            contextTokensUsed: int64(root["contextTokensUsed"]),
            contextWindowTokens: int64(root["contextWindowTokens"]),
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
            if fileManager.fileExists(atPath: candidate.path) {
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
            if fileManager.fileExists(atPath: candidate.appendingPathComponent("signals.json").path) {
                return candidate
            }
        }
        return nil
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
