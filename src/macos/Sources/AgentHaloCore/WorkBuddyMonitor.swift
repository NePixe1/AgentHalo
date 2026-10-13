import Foundation
import SQLite3

public struct WorkBuddyObservation: Equatable, Sendable {
    public var present: Bool
    public var connected: Bool
    public var hostPid: Int32
    public var sessions: [SessionSnapshot]

    public static let empty = WorkBuddyObservation(
        present: false,
        connected: false,
        hostPid: 0,
        sessions: []
    )

    public init(present: Bool, connected: Bool, hostPid: Int32, sessions: [SessionSnapshot]) {
        self.present = present
        self.connected = connected
        self.hostPid = hostPid
        self.sessions = sessions
    }

    public var preferredSession: SessionSnapshot? {
        sessions.max { $0.lastEventAt < $1.lastEventAt }
    }
}

public struct WorkBuddyTranscriptCursor: Equatable, Sendable {
    public var length: UInt64
    public var modifiedAt: Date
    public var input: Int64
    public var output: Int64
    public var model: String
    public var hasUsage: Bool

    public static let empty = WorkBuddyTranscriptCursor(
        length: 0,
        modifiedAt: .distantPast,
        input: 0,
        output: 0,
        model: "",
        hasUsage: false
    )

    public init(
        length: UInt64,
        modifiedAt: Date,
        input: Int64,
        output: Int64,
        model: String,
        hasUsage: Bool
    ) {
        self.length = length
        self.modifiedAt = modifiedAt
        self.input = input
        self.output = output
        self.model = model
        self.hasUsage = hasUsage
    }
}

/// Read-only WorkBuddy integration. WorkBuddy's own status owns the lifecycle.
public enum WorkBuddyMonitor {
    public static let processNames: Set<String> = ["WorkBuddy", "workbuddy"]
    private static let sessionFileLimit = 65_536
    private static let transcriptChunk = 512 * 1024
    private static let sessionQueryTemplate = """
    SELECT s.id, s.status, coalesce(s.custom_title, s.title), s.cwd, s.model, s.updated_at,
           coalesce(u.used, 0), coalesce(u.size, 0)
    FROM sessions s
    LEFT JOIN session_usage u ON u.session_id = s.id
    WHERE s.deleted_at IS NULL AND (
        s.id IN ({0}) OR s.id IN (
            SELECT id FROM sessions
            WHERE deleted_at IS NULL AND id NOT IN ({0})
            ORDER BY updated_at DESC LIMIT 64
        )
    )
    ORDER BY s.updated_at DESC
    """

    private static func sessionQuery(liveIDs: Set<String>) -> String {
        // Only hex digits enter the SQL; registration IDs remain UTF-8 data.
        let ids = liveIDs.sorted().map { id in
            "CAST(X'" + id.utf8.map { String(format: "%02x", $0) }.joined() + "' AS TEXT)"
        }.joined(separator: ",")
        return sessionQueryTemplate.replacingOccurrences(
            of: "{0}", with: ids.isEmpty ? "SELECT NULL WHERE 0" : ids
        )
    }

    public static func rootDirectory(homeDirectory: URL) -> URL {
        homeDirectory.appendingPathComponent(".workbuddy", isDirectory: true)
    }

    public static func isWorkBuddyProcess(_ process: LiveProcess) -> Bool {
        let base = URL(fileURLWithPath: process.name).lastPathComponent
        return processNames.contains(base)
    }

    public static func scan(
        homeDirectory: URL,
        processes: [LiveProcess],
        transcripts: inout [String: WorkBuddyTranscriptCursor],
        launched: Date,
        fileManager: FileManager = .default
    ) -> WorkBuddyObservation {
        let apps = processes.filter(isWorkBuddyProcess)
        guard let host = apps.min(by: { ($0.startedAt ?? .distantFuture) < ($1.startedAt ?? .distantFuture) }),
              let appStart = host.startedAt
        else {
            return .empty
        }
        let root = rootDirectory(homeDirectory: homeDirectory)
        let liveIDs = liveSessionIDs(
            directory: root.appendingPathComponent("sessions", isDirectory: true),
            processes: processes,
            appStart: appStart,
            fileManager: fileManager
        )
        let queried = querySessions(database: root.appendingPathComponent("workbuddy.db"), liveIDs: liveIDs)
        guard queried.connected else {
            return WorkBuddyObservation(present: true, connected: false, hostPid: host.processId, sessions: [])
        }
        var sessions: [SessionSnapshot] = []
        for row in queried.rows {
            var snapshot = parseRow(row)
            guard isSessionEligible(snapshot, live: liveIDs.contains(snapshot.threadId), appStart: appStart) else {
                continue
            }
            // installedAt is the first run, not this process. A completion from
            // before this launch must not flash COMPLETE.
            suppressHistoricalCompletion(&snapshot, launched: launched)
            if let cursor = readMetrics(
                session: snapshot,
                root: root,
                cursor: transcripts[transcriptPath(root: root, session: snapshot)]
            ) {
                let path = transcriptPath(root: root, session: snapshot)
                transcripts[path] = cursor
                if transcripts.count > 128 {
                    transcripts.removeAll()
                    transcripts[path] = cursor
                }
                apply(cursor, to: &snapshot)
            }
            sessions.append(snapshot)
        }
        return WorkBuddyObservation(
            present: true,
            connected: true,
            hostPid: host.processId,
            sessions: sessions
        )
    }

    public static func parseRow(_ row: [String]) -> SessionSnapshot {
        let values = row.count >= 8 ? row : row + Array(repeating: "", count: 8 - row.count)
        let updated = milliseconds(values[5])
        let used = number(values[6])
        let size = number(values[7])
        let (state, action, active, phaseDone) = mappedState(values[1])
        let title = values[2]
        let directoryLeaf = URL(fileURLWithPath: values[3]).lastPathComponent
        let displayTitle = title.isEmpty ? directoryLeaf : title
        return SessionSnapshot(
            threadId: values[0],
            projectName: displayTitle,
            workingDirectory: values[3],
            state: state,
            action: action,
            lastEventAt: updated,
            completedAt: phaseDone ? updated : nil,
            active: active,
            agent: .workbuddy,
            modelName: values[4].isEmpty ? nil : values[4],
            contextUsedPercent: size > 0 ? min(100, Double(used) / Double(size) * 100) : nil,
            sessionTitle: displayTitle.isEmpty ? nil : displayTitle
        )
    }

    /// A prewarm process or an orphaned saved task is not activity.
    /// A live tool is not expired just because its row stopped changing.
    public static func isSessionEligible(
        _ snapshot: SessionSnapshot,
        live: Bool,
        appStart: Date
    ) -> Bool {
        if (snapshot.active || snapshot.state == .error) && !live {
            return false
        }
        return live || snapshot.lastEventAt >= appStart
    }

    public static func suppressHistoricalCompletion(_ snapshot: inout SessionSnapshot, launched: Date) {
        guard snapshot.state == .done, let completedAt = snapshot.completedAt, completedAt < launched else {
            return
        }
        snapshot.state = .idle
        snapshot.completedAt = nil
        snapshot.active = false
        snapshot.action = "Ready"
    }

    /// WorkBuddy escapes the project directory the same way as its CLI.
    /// Only the first character is lowercased; the rest of the casing stays.
    public static func escapeProjectDirectory(_ path: String) -> String {
        var escaped = path
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "\\", with: "-")
            .replacingOccurrences(of: "/", with: "-")
        guard let first = escaped.first else { return escaped }
        escaped.replaceSubrange(
            escaped.startIndex...escaped.startIndex,
            with: String(first).lowercased()
        )
        return escaped
    }

    public static func readMetrics(
        session: SessionSnapshot,
        root: URL,
        cursor: WorkBuddyTranscriptCursor?
    ) -> WorkBuddyTranscriptCursor? {
        let path = transcriptPath(root: root, session: session)
        guard FileManager.default.fileExists(atPath: path) else { return cursor }
        return ingestTranscript(at: URL(fileURLWithPath: path), cursor: cursor)
    }

    public static func ingestTranscript(
        at url: URL,
        cursor: WorkBuddyTranscriptCursor?
    ) -> WorkBuddyTranscriptCursor {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let fileLength = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        let modifiedAt = (attributes?[.modificationDate] as? Date) ?? .distantPast
        var cache = cursor ?? .empty
        guard cursor == nil || cache.length != fileLength || cache.modifiedAt != modifiedAt else {
            return cache
        }
        if cursor == nil || fileLength < cache.length || (fileLength == cache.length && cache.modifiedAt != modifiedAt) {
            cache = .empty
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            cache.modifiedAt = modifiedAt
            return cache
        }
        defer { try? handle.close() }
        let start = cache.length > 0 ? cache.length : (fileLength > UInt64(transcriptChunk) ? fileLength - UInt64(transcriptChunk) : 0)
        if start > 0 {
            try? handle.seek(toOffset: start)
        }
        let data = (try? handle.read(upToCount: transcriptChunk)) ?? Data()
        if let lastNewline = data.lastIndex(of: 10) {
            var slice = data[..<data.index(after: lastNewline)]
            if cache.length == 0 && start > 0, let firstNewline = slice.firstIndex(of: 10) {
                slice = slice[slice.index(after: firstNewline)...]
            }
            if let text = String(data: Data(slice), encoding: .utf8) {
                for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                    applyLine(String(line), to: &cache)
                }
            }
            cache.length = start + UInt64(lastNewline + 1)
        } else if data.count == transcriptChunk {
            cache.length = start + UInt64(data.count)
        }
        cache.modifiedAt = modifiedAt
        return cache
    }

    public static func apply(_ cursor: WorkBuddyTranscriptCursor, to session: inout SessionSnapshot) {
        if cursor.hasUsage {
            session.inputTokens = cursor.input
            session.outputTokens = cursor.output
        }
        if !cursor.model.isEmpty {
            session.modelName = cursor.model
        }
    }

    private static func transcriptPath(root: URL, session: SessionSnapshot) -> String {
        root
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(escapeProjectDirectory(session.workingDirectory), isDirectory: true)
            .appendingPathComponent(session.threadId + ".jsonl")
            .path
    }

    private static func applyLine(_ line: String, to cache: inout WorkBuddyTranscriptCursor) {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        if let provider = object["providerData"] as? [String: Any],
           let model = provider["requestModelName"] as? String,
           !model.isEmpty {
            cache.model = model
        }
        guard let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any]
        else { return }
        let input = number(usage["input_tokens"])
        let output = number(usage["output_tokens"])
        if input > 0 || output > 0 {
            cache.input = input
            cache.output = output
            cache.hasUsage = true
        }
    }

    private static func liveSessionIDs(
        directory: URL,
        processes: [LiveProcess],
        appStart: Date,
        fileManager: FileManager
    ) -> Set<String> {
        guard let urls = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else {
            return []
        }
        let byPid = LiveProcessProbe.indexed(processes)
        var ids = Set<String>()
        for url in urls where url.pathExtension == "json" {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            guard size > 0, size <= sessionFileLimit,
                  let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (object["kind"] as? String) == "interactive"
            else { continue }
            let pid = Int32(number(object["pid"]))
            let registered = milliseconds(object["startedAt"])
            guard let process = byPid[pid],
                  let started = process.startedAt,
                  registered >= started.addingTimeInterval(-5),
                  registered >= appStart.addingTimeInterval(-5)
            else { continue }
            let sessionID = text(object["sessionId"])
            if !sessionID.isEmpty {
                ids.insert(sessionID)
            }
        }
        return ids
    }

    private static func querySessions(database url: URL, liveIDs: Set<String>) -> (connected: Bool, rows: [[String]]) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return (false, [])
        }
        var handle: OpaquePointer?
        guard let uri = readOnlyURI(for: url),
              sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
              let handle
        else {
            if handle != nil { sqlite3_close(handle) }
            return (false, [])
        }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 80)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sessionQuery(liveIDs: liveIDs), -1, &statement, nil) == SQLITE_OK, let statement else {
            if statement != nil { sqlite3_finalize(statement) }
            return (false, [])
        }
        defer { sqlite3_finalize(statement) }
        var rows: [[String]] = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            rows.append((0..<8).map { columnText(statement, Int32($0)) })
            step = sqlite3_step(statement)
        }
        // BUSY, ERROR, or a short WAL read is not an empty task list.
        guard step == SQLITE_DONE else {
            return (false, [])
        }
        return (true, rows)
    }

    private static func columnText(_ statement: OpaquePointer, _ index: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, index) else { return "" }
        let length = Int(sqlite3_column_bytes(statement, index))
        let bytes = UnsafeBufferPointer(start: pointer, count: length)
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func readOnlyURI(for url: URL) -> String? {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "?#")
        guard let encoded = url.path.addingPercentEncoding(withAllowedCharacters: allowed) else {
            return nil
        }
        return "file://\(encoded)?mode=ro"
    }

    private static func mappedState(_ raw: String) -> (HaloState, String, Bool, Bool) {
        switch raw.lowercased() {
        case "planning":
            return (.thinking, "Thinking", true, false)
        case "working", "streaming":
            return (.working, "Using tools", true, false)
        case "pending", "waiting_permission", "waiting_question", "paused":
            return (.attention, "Awaiting permission or input", true, false)
        case "error", "failed", "interrupted":
            return (.error, L10n.shared["status.error"], false, false)
        case "completed":
            return (.done, "Complete", false, true)
        default:
            return (.idle, "Ready", false, false)
        }
    }

    private static func text(_ value: Any?) -> String {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        default:
            return ""
        }
    }

    private static func number(_ value: Any?) -> Int64 {
        switch value {
        case let number as NSNumber:
            return max(0, number.int64Value)
        case let string as String:
            return Int64(string).map { max(0, $0) } ?? 0
        default:
            return 0
        }
    }

    private static func milliseconds(_ value: Any?) -> Date {
        let raw = number(value)
        guard raw > 0, raw < 253_402_300_799_999 else { return .distantPast }
        return Date(timeIntervalSince1970: TimeInterval(raw) / 1000)
    }
}
