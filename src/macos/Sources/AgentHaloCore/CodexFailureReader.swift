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
        let query = """
        select ts || char(9) || coalesce(level,'') || char(9) || coalesce(target,'') || char(9) || \
        replace(replace(coalesce(feedback_log_body,''),char(10),' '),char(13),' ') from logs \
        order by id desc limit 256;
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
        GeneratedHaloSpec.classifyFailure(text)
    }

    private static func isRelevantTarget(_ target: String) -> Bool {
        let value = target.lowercased()
        return value.contains("client")
            || value.contains("auth")
            || value.contains("response")
            || value.contains("session")
    }
}
