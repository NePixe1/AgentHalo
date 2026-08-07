import Foundation

/// One latest-per-session record from `pi-status.jsonl` (Pi extension output).
public struct PiStatusRecord: Equatable, Sendable {
    public var sessionId: String
    public var state: String
    public var event: String?
    public var workingDirectory: String?
    public var provider: String?
    public var model: String?
    public var toolName: String?
    public var errorMessage: String?
    public var processId: Int32
    public var timestamp: Date
    public var inputTokens: Int64
    public var outputTokens: Int64
    public var cacheReadTokens: Int64
    /// `-1` means unknown (JSON null / missing). Real zero usage stays `0`.
    public var contextTokens: Int64
    /// `-1` means unknown. Paired with `contextTokens` for the context pill.
    public var contextWindowTokens: Int64

    public init(
        sessionId: String,
        state: String,
        event: String? = nil,
        workingDirectory: String? = nil,
        provider: String? = nil,
        model: String? = nil,
        toolName: String? = nil,
        errorMessage: String? = nil,
        processId: Int32,
        timestamp: Date,
        inputTokens: Int64 = 0,
        outputTokens: Int64 = 0,
        cacheReadTokens: Int64 = 0,
        contextTokens: Int64 = -1,
        contextWindowTokens: Int64 = -1
    ) {
        self.sessionId = sessionId
        self.state = state
        self.event = event
        self.workingDirectory = workingDirectory
        self.provider = provider
        self.model = model
        self.toolName = toolName
        self.errorMessage = errorMessage
        self.processId = processId
        self.timestamp = timestamp
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.contextTokens = contextTokens
        self.contextWindowTokens = contextWindowTokens
    }
}

/// Reads `~/.agent-halo/logs/pi-status.jsonl` and maps extension events to
/// session snapshots. Mirrors Windows `PiStatusMonitor` (full-file rebuild with
/// live-PID retention across log rotation).
public final class PiStatusMonitor: @unchecked Sendable {
    private let statusURL: URL
    private let fileManager: FileManager
    private var records: [String: PiStatusRecord] = [:]
    private var lastLength: UInt64 = 0
    private var lastModified: Date?
    private var hasSeenFile = false

    public init(
        statusURL: URL = AgentHaloPaths().piStatusLog,
        fileManager: FileManager = .default
    ) {
        self.statusURL = statusURL
        self.fileManager = fileManager
    }

    @discardableResult
    public func refresh(now: Date = Date()) -> Bool {
        let meta = FastFileMetadata.read(statusURL)
        guard let meta else {
            // File missing: clear any retained sessions once.
            guard !records.isEmpty || hasSeenFile else {
                return false
            }
            records.removeAll()
            lastLength = 0
            lastModified = nil
            hasSeenFile = false
            return true
        }

        if hasSeenFile, meta.size == lastLength, meta.modifiedAt == lastModified {
            return false
        }
        hasSeenFile = true

        var next = Self.readLatest(from: statusURL, fileManager: fileManager)
        // Retain still-live sessions missing from a freshly rotated file so
        // multi-session rings do not flash offline mid-turn.
        for (sessionId, previous) in records where next[sessionId] == nil {
            if Self.isLive(previous) {
                next[sessionId] = previous
            }
        }

        let before = fingerprint(records.values)
        let after = fingerprint(next.values)
        records = next
        lastLength = meta.size
        lastModified = meta.modifiedAt
        return before != after
    }

    public func snapshots() -> [SessionSnapshot] {
        records.values.compactMap { Self.toSnapshot($0) }
    }

    public func liveSessionIds() -> Set<String> {
        Set(records.values.filter { Self.isLive($0) }.map(\.sessionId))
    }

    public func allRecords() -> [PiStatusRecord] {
        Array(records.values)
    }

    // MARK: - Parse / map

    public static func parse(_ line: String) -> PiStatusRecord? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        guard let source = object["source"] as? String,
              source.caseInsensitiveCompare("pi-extension") == .orderedSame
        else {
            return nil
        }

        let pid = int32(object["pid"]) ?? 0
        var sessionId = string(object["sessionId"]) ?? ""
        if sessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sessionId = "pi-\(pid)"
        }
        guard let timestamp = date(object["timestamp"]) else {
            return nil
        }

        return PiStatusRecord(
            sessionId: sessionId,
            state: string(object["state"]) ?? "idle",
            event: string(object["event"]),
            workingDirectory: string(object["cwd"]),
            provider: string(object["provider"]),
            model: string(object["model"]),
            toolName: string(object["toolName"]),
            errorMessage: string(object["errorMessage"]),
            processId: pid,
            timestamp: timestamp,
            inputTokens: int64(object["inputTokens"]) ?? 0,
            outputTokens: int64(object["outputTokens"]) ?? 0,
            cacheReadTokens: int64(object["cacheRead"]) ?? 0,
            contextTokens: optionalInt64(object["contextTokens"]),
            contextWindowTokens: optionalInt64(object["contextWindow"])
        )
    }

    public static func toSnapshot(_ record: PiStatusRecord) -> SessionSnapshot? {
        if record.state.caseInsensitiveCompare("offline") == .orderedSame {
            return nil
        }

        var state: HaloState = .idle
        var active = false
        var completedAt: Date?
        var action = "Ready"

        switch record.state.lowercased() {
        case "thinking":
            state = .thinking
            active = true
            action = "Thinking"
        case "working":
            state = .working
            active = true
            if let tool = record.toolName, !tool.isEmpty {
                action = "Using tool: \(tool)"
            } else {
                action = "Writing answer"
            }
        case "done":
            state = .done
            action = "Complete"
            completedAt = record.timestamp
        case "error":
            state = .error
            action = (record.errorMessage?.isEmpty == false)
                ? (record.errorMessage ?? "Task failed")
                : "Task failed"
        default:
            state = .idle
            action = "Ready"
        }

        let contextPercent: Double?
        if record.contextTokens >= 0, record.contextWindowTokens > 0 {
            contextPercent = min(
                100,
                max(0, Double(record.contextTokens) * 100.0 / Double(record.contextWindowTokens))
            )
        } else {
            contextPercent = nil
        }

        let cwd = record.workingDirectory ?? ""
        return SessionSnapshot(
            threadId: record.sessionId,
            projectName: projectName(from: cwd),
            workingDirectory: cwd,
            state: state,
            action: action,
            lastEventAt: record.timestamp,
            completedAt: completedAt,
            active: active,
            agent: .pi,
            modelName: record.model,
            inputTokens: record.inputTokens > 0 ? record.inputTokens : nil,
            outputTokens: record.outputTokens > 0 ? record.outputTokens : nil,
            contextUsedPercent: contextPercent
        )
    }

    public static func isLive(_ record: PiStatusRecord) -> Bool {
        if record.processId <= 0 {
            return false
        }
        if record.state.caseInsensitiveCompare("offline") == .orderedSame {
            return false
        }
        return isProcessAlive(pid: record.processId)
    }

    public static func isProcessAlive(pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0
    }

    // MARK: - File

    private static func readLatest(
        from url: URL,
        fileManager: FileManager
    ) -> [String: PiStatusRecord] {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return [:]
        }
        defer { try? handle.close() }
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8)
        else {
            return [:]
        }

        var result: [String: PiStatusRecord] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let record = parse(String(line)) else { continue }
            if let previous = result[record.sessionId],
               previous.timestamp > record.timestamp {
                continue
            }
            result[record.sessionId] = record
        }
        return result
    }

    private func fingerprint(_ values: Dictionary<String, PiStatusRecord>.Values) -> String {
        values
            .sorted { $0.sessionId < $1.sessionId }
            .map {
                "\($0.sessionId):\($0.state):\($0.timestamp.timeIntervalSince1970)"
            }
            .joined(separator: "|")
    }

    private static func projectName(from workingDirectory: String) -> String {
        let trimmed = workingDirectory.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return "Pi" }
        let leaf = (trimmed as NSString).lastPathComponent
        return leaf.isEmpty ? "Pi" : leaf
    }

    private static func string(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        if let text = value as? String { return text }
        return String(describing: value)
    }

    private static func int32(_ value: Any?) -> Int32? {
        guard let number = int64(value) else { return nil }
        return Int32(clamping: number)
    }

    private static func int64(_ value: Any?) -> Int64? {
        guard let value, !(value is NSNull) else { return nil }
        if let number = value as? NSNumber {
            return number.int64Value
        }
        if let text = value as? String {
            return Int64(text)
        }
        return nil
    }

    /// Missing / null → `-1` (unknown). Present zero stays `0`.
    private static func optionalInt64(_ value: Any?) -> Int64 {
        guard let value, !(value is NSNull) else { return -1 }
        if let number = value as? NSNumber {
            return number.int64Value
        }
        if let text = value as? String, let parsed = Int64(text) {
            return parsed
        }
        return -1
    }

    private static func date(_ value: Any?) -> Date? {
        guard let text = string(value) else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
