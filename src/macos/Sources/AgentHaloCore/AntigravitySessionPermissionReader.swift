import Foundation
import SQLite3

/// Permission lifecycle from Antigravity conversation `steps.status`.
///
/// `agy` / the desktop app persist `CORTEX_STEP_STATUS_WAITING` (9) while the
/// “Allow reading this URL?” sheet is up. That is the durable analogue of
/// Grok’s `events.jsonl` `permission_requested` / `permission_resolved`.
public struct AntigravityPermissionUpdate: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case requested
        case resolved(decision: String)
    }

    public var at: Date
    public var kind: Kind

    public init(at: Date, kind: Kind) {
        self.at = at
        self.kind = kind
    }
}

public enum AntigravityCortexStepStatus: Int, Equatable, Sendable {
    case unspecified = 0
    case pending = 1
    case running = 2
    case done = 3
    case invalid = 4
    case cleared = 5
    case canceled = 6
    case error = 7
    case generating = 8
    /// “Step is WAITING for user approval.”
    case waiting = 9
    case queued = 11
    case interrupted = 12
}

/// Incrementally polls `~/.gemini/antigravity{,-cli}/conversations/<id>.db`.
public final class AntigravitySessionPermissionReader {
    private struct TailState {
        var lastIndex: Int?
        var lastStatus: Int?
        var lastModified: Date?
        var lastSize: UInt64 = 0
        var sawFile = false
    }

    private var tails: [String: TailState] = [:]
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public static func defaultConversationRoots(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        [
            home.appendingPathComponent(".gemini/antigravity/conversations", isDirectory: true),
            home.appendingPathComponent(".gemini/antigravity-cli/conversations", isDirectory: true),
        ]
    }

    public static func conversationDatabase(
        sessionId: String,
        roots: [URL],
        fileManager: FileManager = .default
    ) -> URL? {
        guard !sessionId.isEmpty else { return nil }
        for root in roots {
            let url = root.appendingPathComponent("\(sessionId).db")
            if fileManager.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    public func poll(databaseURL: URL, now: Date = Date()) -> [AntigravityPermissionUpdate] {
        let key = databaseURL.path
        var state = tails[key] ?? TailState()
        defer { tails[key] = state }

        guard fileManager.fileExists(atPath: databaseURL.path) else {
            state = TailState()
            return []
        }

        let stamp = latestStamp(for: databaseURL)
        if state.sawFile,
           stamp.modified == state.lastModified,
           stamp.size == state.lastSize {
            return []
        }
        state.lastModified = stamp.modified
        state.lastSize = stamp.size

        guard let latest = readLatestStep(at: databaseURL) else {
            state.sawFile = true
            return []
        }

        let previousStatus = state.lastStatus
        let previousIndex = state.lastIndex
        let firstAttach = !state.sawFile
        state.sawFile = true
        state.lastIndex = latest.index
        state.lastStatus = latest.status

        if firstAttach {
            if latest.status == AntigravityCortexStepStatus.waiting.rawValue {
                return [AntigravityPermissionUpdate(at: now, kind: .requested)]
            }
            return []
        }

        let sameRow = previousIndex == latest.index
        let wasWaiting = previousStatus == AntigravityCortexStepStatus.waiting.rawValue
        let isWaiting = latest.status == AntigravityCortexStepStatus.waiting.rawValue

        if isWaiting && (!wasWaiting || !sameRow) {
            return [AntigravityPermissionUpdate(at: now, kind: .requested)]
        }
        if wasWaiting && sameRow && !isWaiting {
            return [AntigravityPermissionUpdate(at: now, kind: .resolved(decision: decision(from: latest.status)))]
        }
        return []
    }

    public func reset() {
        tails.removeAll()
    }

    public func drop(databaseURL: URL) {
        tails.removeValue(forKey: databaseURL.path)
    }

    private func decision(from status: Int) -> String {
        switch AntigravityCortexStepStatus(rawValue: status) {
        case .canceled, .error, .cleared, .invalid, .interrupted:
            return "deny"
        default:
            return "allow"
        }
    }

    private func latestStamp(for databaseURL: URL) -> (modified: Date?, size: UInt64) {
        var modified: Date?
        var size: UInt64 = 0
        for suffix in ["", "-wal"] {
            let url = suffix.isEmpty ? databaseURL : URL(fileURLWithPath: databaseURL.path + suffix)
            let meta = FastFileMetadata.read(url)
            if let m = meta?.modifiedAt, modified.map({ m > $0 }) ?? true {
                modified = m
            }
            size += meta?.size ?? 0
        }
        return (modified, size)
    }

    private func readLatestStep(at databaseURL: URL) -> (index: Int, status: Int)? {
        var database: OpaquePointer?
        let uri = "file:\(databaseURL.path)?mode=ro"
        let opened = sqlite3_open_v2(uri, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        guard opened == SQLITE_OK, let database else {
            if database != nil {
                sqlite3_close(database)
            }
            return nil
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 80)

        let sql = "SELECT idx, status FROM steps ORDER BY idx DESC LIMIT 1"
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK, let statement else {
            if statement != nil {
                sqlite3_finalize(statement)
            }
            return nil
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }
        return (
            index: Int(sqlite3_column_int64(statement, 0)),
            status: Int(sqlite3_column_int64(statement, 1))
        )
    }
}
