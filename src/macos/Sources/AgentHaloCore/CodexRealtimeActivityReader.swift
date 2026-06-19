import Foundation

public struct CodexRealtimeActivityReader: Sendable {
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

    public func readActive(now: Date = Date()) -> CodexRealtimeActivity? {
        guard FileManager.default.fileExists(atPath: databaseURL.path(percentEncoded: false)) else {
            return nil
        }
        let cutoff = Int(now.addingTimeInterval(-120).timeIntervalSince1970)
        let query = """
        select replace(replace(coalesce(feedback_log_body,''),char(10),' '),char(13),' ') from logs \
        where ts >= \(cutoff) and target='codex_api::sse::responses' and \
        feedback_log_body like 'SSE event: {"type":"response.%' \
        order by id desc limit 96;
        """
        let rows = runSQLite(query: query)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        return findActive(in: rows)
    }

    public func findActive(in newestFirst: [String]) -> CodexRealtimeActivity? {
        var completedItemIds = Set<String>()
        for body in newestFirst {
            guard let event = Self.parseEvent(from: body) else {
                continue
            }
            let eventType = event.type
            if eventType == "response.output_text.delta" {
                return CodexRealtimeActivity(
                    state: .working,
                    action: "Writing answer",
                    answerStreaming: true
                )
            }
            if eventType == "response.completed"
                || eventType == "response.output_text.done"
                || eventType == "response.content_part.done" {
                return nil
            }
            if eventType == "response.output_item.done" {
                if !event.itemId.isEmpty {
                    completedItemIds.insert(event.itemId)
                }
                continue
            }
            if eventType == "response.output_item.added",
               !completedItemIds.contains(event.itemId) {
                if event.name.caseInsensitiveCompare("request_user_input") == .orderedSame {
                    return CodexRealtimeActivity(state: .attention, action: "Needs you")
                }
                if event.itemType == "function_call"
                    || event.itemType == "custom_tool_call"
                    || event.itemType == "tool_search_call"
                    || event.itemType == "message" {
                    return CodexRealtimeActivity(
                        state: .working,
                        action: event.itemType == "message"
                            ? "Writing answer"
                            : GeneratedHaloSpec.friendlyAction(event.name.isEmpty ? event.itemType : event.name),
                        answerStreaming: event.itemType == "message"
                    )
                }
            }
        }
        return nil
    }

    private struct RealtimeEvent {
        var type: String
        var itemId: String
        var itemType: String
        var name: String
    }

    private static func parseEvent(from body: String) -> RealtimeEvent? {
        let prefix = "SSE event: "
        let jsonText: String
        if let range = body.range(of: prefix) {
            jsonText = String(body[range.upperBound...])
        } else {
            jsonText = body
        }
        guard let data = jsonText.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let eventType = (root["type"] as? String) ?? ""
        let item = root["item"] as? [String: Any]
        return RealtimeEvent(
            type: eventType,
            itemId: (item?["id"] as? String) ?? "",
            itemType: ((item?["type"] as? String) ?? "").lowercased(),
            name: (item?["name"] as? String) ?? ""
        )
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
            AgentHaloLogger.log("Codex realtime sqlite read failed: \(error)")
            return ""
        }
    }
}
