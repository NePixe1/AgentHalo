import Foundation

public struct CodexFailureReader: Sendable {
    public var databaseURL: URL
    public var sqlitePath: String

    public init(
        databaseURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("logs_2.sqlite"),
        sqlitePath: String = "/usr/bin/sqlite3"
    ) {
        self.databaseURL = databaseURL
        self.sqlitePath = sqlitePath
    }

    public func readRecent(now: Date = Date()) -> CodexFailure? {
        guard FileManager.default.fileExists(atPath: databaseURL.path(percentEncoded: false)) else {
            return nil
        }
        let cutoff = Int(now.addingTimeInterval(-120).timeIntervalSince1970)
        let query = """
        select ts || char(9) || replace(replace(coalesce(feedback_log_body,''),char(10),' '),char(13),' ') from logs \
        where ts >= \(cutoff) and lower(level)='error' and (\
        lower(target) like '%client%' or lower(target) like '%auth%' or \
        lower(target) like '%response%' or lower(target) like '%session%') \
        order by id desc limit 24;
        """
        let output = runSQLite(query: query)
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2,
                  let seconds = TimeInterval(parts[0]),
                  let detail = Self.classify(parts[1]) else {
                continue
            }
            return CodexFailure(detail: detail, eventAt: Date(timeIntervalSince1970: seconds))
        }
        return nil
    }

    public static func classify(_ text: String) -> String? {
        GeneratedHaloSpec.classifyFailure(text)
    }

    private func runSQLite(query: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sqlitePath)
        process.arguments = [
            "-readonly",
            "-batch",
            databaseURL.path(percentEncoded: false),
            query
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            AgentHaloLogger.log("Codex failure sqlite read failed: \(error)")
            return ""
        }
    }
}
