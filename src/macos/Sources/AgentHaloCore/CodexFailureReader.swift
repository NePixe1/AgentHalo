import Foundation

public struct CodexFailureReader: Sendable {
    public var logStore: CodexSQLiteLogStore

    public init(
        databaseURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("logs_2.sqlite")
    ) {
        self.logStore = CodexSQLiteLogStore(databaseURL: databaseURL)
    }

    public func readRecent(now: Date = Date()) -> CodexFailure? {
        let cutoff = now.addingTimeInterval(-120).timeIntervalSince1970
        // Filter `level='error'` server-side so only error rows (and their
        // feedback_log_body) are materialized and transferred, instead of
        // reading 256 arbitrary rows of every level and discarding the rest in
        // Swift. The 120s cutoff is pushed into SQL as `ts >= ?` so SQLite seeks
        // `idx_logs_ts (ts>?)` and scans only the last 120s of rows. Without it,
        // `order by id desc` plus the non-indexable `lower(level)` predicate
        // forced a full backward btree scan of the entire `logs` table (~95k
        // rows) on every 2s poll. `order by ts desc, ts_nanos desc, id desc`
        // matches idx_logs_ts exactly, so no temp btree is needed and the
        // most-recent error still comes first. The Swift `seconds >= cutoff`
        // check below is kept as a no-op safety filter (rows are already within
        // the window).
        let cutoffSeconds = Int(cutoff)
        let query = """
        select ts || char(9) || coalesce(level,'') || char(9) || coalesce(target,'') || char(9) || \
        replace(replace(coalesce(feedback_log_body,''),char(10),' '),char(13),' ') from logs \
        where lower(level)='error' and ts>=\(cutoffSeconds) \
        order by ts desc, ts_nanos desc, id desc limit 256;
        """
        let rows: [String]
        do {
            rows = try logStore.readSingleColumn(query: query)
        } catch {
            AgentHaloLogger.log("Codex failure sqlite read failed: \(error)")
            return nil
        }
        for line in rows {
            let parts = line.split(separator: "\t", maxSplits: 3).map(String.init)
            guard parts.count == 4,
                  let seconds = TimeInterval(parts[0]),
                  seconds >= cutoff,
                  parts[1].lowercased() == "error",
                  Self.isRelevantTarget(parts[2]),
                  let detail = Self.classify(parts[3]) else {
                continue
            }
            return CodexFailure(detail: detail, eventAt: Date(timeIntervalSince1970: seconds))
        }
        return nil
    }

    public static func classify(_ text: String) -> String? {
        guard let key = GeneratedHaloSpec.classifyFailure(text) else { return nil }
        return L10n.shared[key]
    }

    private static func isRelevantTarget(_ target: String) -> Bool {
        let value = target.lowercased()
        return value.contains("client")
            || value.contains("auth")
            || value.contains("response")
            || value.contains("session")
    }
}
