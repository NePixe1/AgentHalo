import Foundation

public struct CodexRealtimeActivityReader: Sendable {
    public var logStore: CodexSQLiteLogStore

    public init(
        databaseURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("logs_2.sqlite")
    ) {
        self.logStore = CodexSQLiteLogStore(databaseURL: databaseURL)
    }

    public func readActive(now: Date = Date()) -> CodexRealtimeActivity? {
        let cutoff = now.addingTimeInterval(-120).timeIntervalSince1970
        // Filter `target='codex_api::sse::responses'` server-side so only SSE
        // response rows are materialized and transferred, instead of reading
        // 512 arbitrary rows of every target and discarding the rest in Swift.
        // The timestamp cutoff and body-prefix shape check stay in Swift (no
        // `ts >=` predicate) so the bounded `order by id desc limit` window —
        // not a timestamp scan — drives the query plan.
        let query = """
        select ts || char(9) || coalesce(target,'') || char(9) || \
        replace(replace(coalesce(feedback_log_body,''),char(10),' '),char(13),' ') from logs \
        where target='codex_api::sse::responses' \
        order by id desc limit 512;
        """
        let rows: [String]
        do {
            rows = try logStore.readSingleColumn(query: query)
        } catch {
            AgentHaloLogger.log("Codex realtime sqlite read failed: \(error)")
            return nil
        }
        let bodies = rows.compactMap { line -> String? in
            let parts = line.split(separator: "\t", maxSplits: 2).map(String.init)
            guard parts.count == 3,
                  let seconds = TimeInterval(parts[0]),
                  seconds >= cutoff,
                  parts[1] == "codex_api::sse::responses",
                  parts[2].hasPrefix("SSE event: {\"type\":\"response.") else {
                return nil
            }
            return parts[2]
        }
        return findActive(in: bodies)
    }

    public func findActive(in newestFirst: [String]) -> CodexRealtimeActivity? {
        var completedItemIds = Set<String>()
        var hasArgumentActivity = false
        var hasAttentionArgumentActivity = false
        for body in newestFirst {
            guard let event = Self.parseEvent(from: body) else {
                continue
            }
            let eventType = event.type
            if eventType == "response.output_text.delta" {
                // Streaming the final answer no longer flips the ring into the
                // green "done" presentation — that fired during mid-stream and
                // confused users with the actual completion tone. Stay blue
                // working; only the action label distinguishes a normal answer
                // from a context compaction so the details panel can localize.
                let action = Self.isContextCompressionDelta(event.delta)
                    ? "Compressing context"
                    : "Writing answer"
                return CodexRealtimeActivity(
                    state: .working,
                    action: action,
                    answerStreaming: false
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
            if eventType == "response.function_call_arguments.delta"
                || eventType == "response.function_call_arguments.done" {
                if !event.itemId.isEmpty,
                   completedItemIds.contains(event.itemId) {
                    continue
                }
                hasArgumentActivity = true
                if event.attentionHint {
                    hasAttentionArgumentActivity = true
                }
                continue
            }
            if eventType == "response.output_item.added",
               !completedItemIds.contains(event.itemId) {
                if Self.isAttentionToolName(event.name) {
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
                        answerStreaming: false
                    )
                }
            }
        }
        if hasAttentionArgumentActivity {
            return CodexRealtimeActivity(state: .attention, action: "Needs you")
        }
        if hasArgumentActivity {
            return CodexRealtimeActivity(state: .working, action: "Preparing command")
        }
        return nil
    }

    private struct RealtimeEvent {
        var type: String
        var itemId: String
        var itemType: String
        var name: String
        var attentionHint: Bool
        var delta: String
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
        if eventType == "response.function_call_arguments.delta"
            || eventType == "response.function_call_arguments.done" {
            let itemId = (root["item_id"] as? String) ?? ""
            let delta = (root["delta"] as? String) ?? ""
            let hint = isEscalatedArgumentsFragment(delta)
                || isEscalatedArgumentsFragment(body)
            guard !itemId.isEmpty else { return nil }
            return RealtimeEvent(
                type: eventType,
                itemId: itemId,
                itemType: "",
                name: "",
                attentionHint: hint,
                delta: delta
            )
        }
        let item = root["item"] as? [String: Any]
        return RealtimeEvent(
            type: eventType,
            itemId: (item?["id"] as? String) ?? "",
            itemType: ((item?["type"] as? String) ?? "").lowercased(),
            name: (item?["name"] as? String) ?? "",
            attentionHint: false,
            delta: (root["delta"] as? String) ?? ""
        )
    }

    private static func isAttentionToolName(_ name: String) -> Bool {
        let lower = name.lowercased()
        if lower == "request_user_input" {
            return true
        }
        return lower.contains("approval")
            || lower.contains("permission")
            || lower.contains("request_user")
            || lower.contains("needs_input")
    }

    private static func isEscalatedArgumentsFragment(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.range(of: "require_escalated", options: .caseInsensitive) != nil else {
            return false
        }
        return value.range(of: "sandbox_permissions", options: .caseInsensitive) != nil
            || value.range(of: "justification", options: .caseInsensitive) != nil
    }

    /// True only when a streamed text delta *is* a context-compaction label
    /// (e.g. Codex emitting "Compressing context" / "压缩上下文" as the delta
    /// content), not when a normal answer merely mentions those words. We
    /// match the trimmed delta against the full label after stripping trailing
    /// punctuation/ellipsis, so "Let me try summarizing conversation history…"
    /// — a real answer fragment — no longer flips the action to compaction.
    private static func isContextCompressionDelta(_ delta: String) -> Bool {
        var trimmed = delta.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while let last = trimmed.last,
              "….:：，,、".contains(last) {
            trimmed.removeLast()
            trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !trimmed.isEmpty else { return false }
        let labels: Set<String> = [
            "compressing context",
            "compress context",
            "compacting context",
            "compact context",
            "context compaction",
            "summarizing conversation",
            "summarizing context",
            "压缩上下文",
            "正在压缩",
            "正在压缩上下文"
        ]
        return labels.contains(trimmed)
    }

}
