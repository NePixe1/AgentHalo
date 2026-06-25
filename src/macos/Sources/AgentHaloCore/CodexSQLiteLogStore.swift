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
        guard FileManager.default.fileExists(atPath: databaseURL.path(percentEncoded: false)) else {
            return []
        }

        var database: OpaquePointer?
        let opened = sqlite3_open_v2(
            databaseURL.path(percentEncoded: false),
            &database,
            SQLITE_OPEN_READONLY,
            nil
        )
        guard opened == SQLITE_OK, let database else {
            if database != nil {
                sqlite3_close(database)
            }
            throw StoreError.openFailed(opened)
        }
        defer {
            sqlite3_close(database)
        }

        sqlite3_busy_timeout(database, 80)

        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(database, query, -1, &statement, nil)
        guard prepared == SQLITE_OK, let statement else {
            if statement != nil {
                sqlite3_finalize(statement)
            }
            throw StoreError.prepareFailed(prepared)
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
}
