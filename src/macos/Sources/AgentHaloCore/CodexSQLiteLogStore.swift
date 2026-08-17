import Darwin
import Foundation
import SQLite3

public struct CodexSQLiteLogStore: Sendable {
    public enum StoreError: Error {
        case openFailed(Int32)
        case prepareFailed(Int32)
    }

    public var databaseURL: URL

    public init(
        databaseURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("logs_2.sqlite")
    ) {
        self.databaseURL = databaseURL
    }

    public func readSingleColumn(query: String) throws -> [String] {
        try SharedCache.shared.read(databaseURL: databaseURL, query: query)
    }
}

// Keep one read-only connection per database and skip SQLite entirely when the
// db/WAL signature has not changed. Codex realtime polling hits this every
// 300ms while Codex is focused; opening, schema-init, scanning, and closing
// on every call dominated the utility-queue sample.
private final class SharedCache: @unchecked Sendable {
    static let shared = SharedCache()

    private let lock = NSLock()
    private var states: [String: DatabaseState] = [:]

    private static let maxCachedDatabases = 4
    private static let maxCachedQueriesPerDatabase = 8

    private struct FileSignature: Equatable {
        var dbSize: UInt64
        var dbMtimeSec: Int64
        var dbMtimeNsec: Int64
        var walSize: UInt64
        var walMtimeSec: Int64
        var walMtimeNsec: Int64
    }

    private final class DatabaseState {
        var database: OpaquePointer?
        var signature: FileSignature?
        var queryCache: [String: [String]] = [:]
        var queryOrder: [String] = []
    }

    func read(databaseURL: URL, query: String) throws -> [String] {
        let path = databaseURL.path(percentEncoded: false)
        lock.lock()
        defer { lock.unlock() }

        guard FileManager.default.fileExists(atPath: path) else {
            closeState(for: path)
            return []
        }

        let signature = Self.fileSignature(databasePath: path)
        let state = state(for: path)
        if state.signature == signature, let cached = state.queryCache[query] {
            return cached
        }
        if state.signature != signature {
            state.queryCache.removeAll(keepingCapacity: true)
            state.queryOrder.removeAll(keepingCapacity: true)
        }

        if state.database == nil {
            try open(state: state, path: path)
        }

        let rows: [String]
        do {
            rows = try execute(state: state, query: query)
        } catch {
            close(state)
            try open(state: state, path: path)
            rows = try execute(state: state, query: query)
        }

        state.signature = signature
        remember(query: query, rows: rows, in: state)
        return rows
    }

    private func state(for path: String) -> DatabaseState {
        if let existing = states[path] {
            return existing
        }
        let created = DatabaseState()
        states[path] = created
        evictIfNeeded(keeping: path)
        return created
    }

    private func evictIfNeeded(keeping path: String) {
        guard states.count > Self.maxCachedDatabases else {
            return
        }
        for key in Array(states.keys) where key != path {
            closeState(for: key)
            if states.count <= Self.maxCachedDatabases {
                return
            }
        }
    }

    private func open(state: DatabaseState, path: String) throws {
        close(state)
        var database: OpaquePointer?
        let opened = sqlite3_open_v2(
            path,
            &database,
            SQLITE_OPEN_READONLY,
            nil
        )
        guard opened == SQLITE_OK, let database else {
            if database != nil {
                sqlite3_close(database)
            }
            throw CodexSQLiteLogStore.StoreError.openFailed(opened)
        }
        sqlite3_busy_timeout(database, 80)
        state.database = database
    }

    private func execute(state: DatabaseState, query: String) throws -> [String] {
        guard let database = state.database else {
            throw CodexSQLiteLogStore.StoreError.openFailed(SQLITE_MISUSE)
        }
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(database, query, -1, &statement, nil)
        guard prepared == SQLITE_OK, let statement else {
            if statement != nil {
                sqlite3_finalize(statement)
            }
            throw CodexSQLiteLogStore.StoreError.prepareFailed(prepared)
        }
        defer {
            sqlite3_finalize(statement)
        }

        var rows: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let pointer = sqlite3_column_text(statement, 0) else {
                continue
            }
            let length = Int(sqlite3_column_bytes(statement, 0))
            let bytes = UnsafeBufferPointer(start: pointer, count: length)
            rows.append(String(decoding: bytes, as: UTF8.self))
        }
        return rows
    }

    private func remember(query: String, rows: [String], in state: DatabaseState) {
        if state.queryCache[query] == nil {
            state.queryOrder.append(query)
        }
        state.queryCache[query] = rows
        while state.queryOrder.count > Self.maxCachedQueriesPerDatabase {
            let oldest = state.queryOrder.removeFirst()
            state.queryCache.removeValue(forKey: oldest)
        }
    }

    private func close(_ state: DatabaseState) {
        if let database = state.database {
            sqlite3_close(database)
            state.database = nil
        }
        state.signature = nil
        state.queryCache.removeAll()
        state.queryOrder.removeAll()
    }

    private func closeState(for path: String) {
        guard let state = states.removeValue(forKey: path) else {
            return
        }
        close(state)
    }

    private static func fileSignature(databasePath: String) -> FileSignature {
        var db = stat()
        let dbOk = stat(databasePath, &db) == 0
        var wal = stat()
        let walOk = stat(databasePath + "-wal", &wal) == 0
        return FileSignature(
            dbSize: dbOk ? UInt64(max(0, db.st_size)) : 0,
            dbMtimeSec: dbOk ? Int64(db.st_mtimespec.tv_sec) : 0,
            dbMtimeNsec: dbOk ? Int64(db.st_mtimespec.tv_nsec) : 0,
            walSize: walOk ? UInt64(max(0, wal.st_size)) : 0,
            walMtimeSec: walOk ? Int64(wal.st_mtimespec.tv_sec) : 0,
            walMtimeNsec: walOk ? Int64(wal.st_mtimespec.tv_nsec) : 0
        )
    }
}
