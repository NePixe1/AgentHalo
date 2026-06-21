import Foundation

public struct SessionReducer: Sendable {
    public private(set) var snapshot: SessionSnapshot
    private var inFlightTools = 0
    private var workingVisibleUntil: Date?
    private var liveTracking: Bool
    private var currentTurnIsPlanMode = false
    private var planProposalSeen = false

    public init(filePath: String, now: Date = Date(), liveTracking: Bool = true) {
        self.snapshot = SessionSnapshot(
            threadId: Self.threadId(from: filePath),
            projectName: "Codex",
            workingDirectory: "",
            state: .idle,
            action: "Ready",
            lastEventAt: now,
            completedAt: nil,
            active: false,
            agent: .codex
        )
        self.liveTracking = liveTracking
    }

    public mutating func consume(jsonLine: String, now: Date = Date()) {
        guard let data = jsonLine.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        let topType = root.string("type")
        let payload = root.dictionary("payload")
        let eventAt = Self.parseDate(root.string("timestamp")) ?? now
        snapshot.lastEventAt = eventAt

        if topType == "turn_context", let payload {
            let model = payload.string("model")
            if !model.isEmpty {
                snapshot.modelName = model
            }
            updatePlanModeFromTurnContext(payload)
            return
        }

        if topType == "session_meta", let payload {
            let cwd = payload.string("cwd")
            if !cwd.isEmpty {
                snapshot.workingDirectory = cwd
                snapshot.projectName = URL(fileURLWithPath: cwd).lastPathComponent
                if snapshot.projectName.isEmpty {
                    snapshot.projectName = cwd
                }
            }
            let id = payload.string("id")
            if !id.isEmpty {
                snapshot.threadId = id
            }
            return
        }

        guard let payload else {
            return
        }

        let payloadType = payload.string("type")
        if topType == "event_msg" {
            if payloadType == "token_count" {
                updateSessionDetails(from: payload)
            }
            reduceEvent(payloadType.lowercased(), payload: payload, eventAt: eventAt, now: now)
        } else if topType == "response_item" {
            reduceResponse(payloadType.lowercased(), payload: payload, now: now)
        }
    }

    public mutating func setLiveTracking(_ value: Bool) {
        liveTracking = value
    }

    public mutating func applyWorkingVisibility(now: Date = Date()) {
        if snapshot.active,
           inFlightTools == 0,
           snapshot.state == .working,
           let until = workingVisibleUntil,
           now >= until {
            workingVisibleUntil = nil
            snapshot.state = .thinking
            snapshot.action = "Reviewing result"
        }
    }

    private mutating func reduceEvent(_ type: String, payload: [String: Any], eventAt: Date, now: Date) {
        if GeneratedHaloSpec.isTaskStartEvent(type) {
            inFlightTools = 0
            workingVisibleUntil = nil
            if type == "task_started" {
                // task_started 自身可能携带 collaboration_mode_kind="plan"。
                // 与提前到达的 turn_context 标志位取并集,允许两种事件顺序。
                if Self.isPlanModePayload(payload) {
                    currentTurnIsPlanMode = true
                }
                // 注意:不在此处清掉 currentTurnIsPlanMode,以兼容 turn_context 早于 task_started 的情况。
                // task_complete 末尾会做最终清理,确保不会跨轮次残留。
            }
            planProposalSeen = false
            snapshot.active = true
            snapshot.state = .thinking
            snapshot.action = "Planning"
        } else if GeneratedHaloSpec.isTaskCompleteEvent(type) {
            inFlightTools = 0
            workingVisibleUntil = nil
            if currentTurnIsPlanMode && planProposalSeen {
                snapshot.active = true
                snapshot.state = .attention
                snapshot.action = "Waiting for your choice"
            } else {
                snapshot.active = false
                snapshot.state = .done
                snapshot.action = "Complete"
            }
            snapshot.completedAt = eventAt
            currentTurnIsPlanMode = false
            planProposalSeen = false
        } else if type == "agent_message" || type.hasSuffix("_end") {
            if type.hasSuffix("_end"), inFlightTools > 0 {
                inFlightTools -= 1
            }
            if type == "agent_message",
               currentTurnIsPlanMode,
               Self.isFinalAnswerPayload(payload),
               Self.containsProposedPlan(payload) {
                planProposalSeen = true
            }
            applyActiveThinkingOrWorking(now: now)
        } else if GeneratedHaloSpec.isAttentionEvent(type) {
            snapshot.active = true
            snapshot.state = .attention
            snapshot.action = "Needs you"
        } else if type == "item_completed" {
            if currentTurnIsPlanMode, Self.isCompletedPlanItem(payload) {
                planProposalSeen = true
            }
        } else if GeneratedHaloSpec.isFatalEvent(type) {
            inFlightTools = 0
            workingVisibleUntil = nil
            currentTurnIsPlanMode = false
            planProposalSeen = false
            snapshot.active = false
            snapshot.state = .error
            snapshot.action = "Interrupted"
        } else if type.hasSuffix("_begin") || type.hasSuffix("_start") {
            snapshot.active = true
            snapshot.state = .working
            snapshot.action = GeneratedHaloSpec.friendlyAction(type)
        }
    }

    private mutating func reduceResponse(_ type: String, payload: [String: Any], now: Date) {
        if type == "function_call" || type == "custom_tool_call" {
            let name = payload.string("name")
            snapshot.active = true
            if name == "request_user_input" || Self.requiresApproval(name: name, payload: payload) {
                snapshot.state = .attention
                snapshot.action = "Needs you"
            } else {
                inFlightTools += 1
                extendWorkingVisibility(seconds: 2.2, now: now)
                snapshot.state = .working
                snapshot.action = GeneratedHaloSpec.friendlyAction(name)
            }
        } else if type == "message", Self.isFinalAnswerPayload(payload) {
            // Plan Mode 下,只有真正的 proposed plan 才会在结束时等待选择。
            // 仅置标志位,保持原有 .thinking/.working 视觉状态。
            if currentTurnIsPlanMode, Self.containsProposedPlan(payload) {
                planProposalSeen = true
            }
            applyActiveThinkingOrWorking(now: now)
        } else if GeneratedHaloSpec.isToolCall(type) || type.hasSuffix("_call") {
            inFlightTools += 1
            extendWorkingVisibility(seconds: 2.2, now: now)
            snapshot.active = true
            snapshot.state = .working
            snapshot.action = GeneratedHaloSpec.friendlyAction(type)
        } else if GeneratedHaloSpec.isToolOutput(type) || type.hasSuffix("_output") {
            if inFlightTools > 0 {
                inFlightTools -= 1
            }
            if snapshot.active {
                if inFlightTools > 0 {
                    snapshot.state = .working
                } else if liveTracking {
                    extendWorkingVisibility(seconds: 1.8, now: now)
                    snapshot.state = .working
                    snapshot.action = "Reviewing result"
                } else {
                    snapshot.state = .thinking
                    snapshot.action = "Reviewing result"
                }
            }
        } else if type == "reasoning" {
            applyActiveThinkingOrWorking(now: now)
        }
    }

    private mutating func applyActiveThinkingOrWorking(now: Date) {
        guard snapshot.active else {
            return
        }
        if inFlightTools > 0 {
            snapshot.state = .working
        } else if let until = workingVisibleUntil, now < until {
            snapshot.state = .working
            snapshot.action = "Reviewing result"
        } else {
            snapshot.state = .thinking
            snapshot.action = "Thinking"
        }
    }

    private mutating func extendWorkingVisibility(seconds: TimeInterval, now: Date) {
        guard liveTracking else {
            return
        }
        let candidate = now.addingTimeInterval(seconds)
        if workingVisibleUntil == nil || candidate > workingVisibleUntil! {
            workingVisibleUntil = candidate
        }
    }

    private mutating func updatePlanModeFromTurnContext(_ payload: [String: Any]) {
        let collaborationMode = payload.dictionary("collaboration_mode")
        let mode = collaborationMode?.string("mode") ?? ""
        if mode.caseInsensitiveCompare("plan") == .orderedSame {
            currentTurnIsPlanMode = true
        }
    }

    private mutating func updateSessionDetails(from payload: [String: Any]) {
        let info = payload.dictionary("info")
        let totalUsage = info?.dictionary("total_token_usage")
        if let inputTokens = Self.int64(totalUsage?["input_tokens"]) {
            snapshot.inputTokens = inputTokens
        }
        if let outputTokens = Self.int64(totalUsage?["output_tokens"]) {
            snapshot.outputTokens = outputTokens
        }
        let lastUsage = info?.dictionary("last_token_usage")
        if let contextTokens = Self.int64(lastUsage?["input_tokens"]),
           let contextWindow = Self.int64(info?["model_context_window"]),
           contextWindow > 0 {
            snapshot.contextUsedPercent = min(
                100,
                max(0, Double(contextTokens) * 100 / Double(contextWindow))
            )
        }
        snapshot.hasRateLimits = payload.dictionary("rate_limits") != nil
            || info?.dictionary("rate_limits") != nil
    }

    private static func isPlanModePayload(_ payload: [String: Any]) -> Bool {
        let mode = payload.string("collaboration_mode_kind")
        return mode.caseInsensitiveCompare("plan") == .orderedSame
    }

    private static func isFinalAnswerPayload(_ payload: [String: Any]) -> Bool {
        let phase = payload.string("phase")
        return phase.caseInsensitiveCompare("final_answer") == .orderedSame
    }

    private static func isCompletedPlanItem(_ payload: [String: Any]) -> Bool {
        guard let item = payload.dictionary("item") else {
            return false
        }
        return item.string("type").caseInsensitiveCompare("Plan") == .orderedSame
    }

    private static func containsProposedPlan(_ value: Any) -> Bool {
        if let text = value as? String {
            return text.range(of: "<proposed_plan", options: .caseInsensitive) != nil
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.values.contains(where: containsProposedPlan)
        }
        if let array = value as? [Any] {
            return array.contains(where: containsProposedPlan)
        }
        return false
    }

    private static func requiresApproval(name: String, payload: [String: Any]) -> Bool {
        guard name == "exec_command" || name == "shell_command" else {
            return false
        }
        if let dictionary = payload["arguments"] as? [String: Any] {
            return dictionary.string("sandbox_permissions") == "require_escalated"
        }
        let text = payload.string("arguments")
        guard let data = text.data(using: .utf8),
              let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return dictionary.string("sandbox_permissions") == "require_escalated"
    }

    private static func threadId(from filePath: String) -> String {
        let name = URL(fileURLWithPath: filePath).deletingPathExtension().lastPathComponent
        if name.count >= 36 {
            let suffix = String(name.suffix(36))
            if UUID(uuidString: suffix) != nil {
                return suffix
            }
        }
        return name
    }

    private static func parseDate(_ value: String) -> Date? {
        guard !value.isEmpty else {
            return nil
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }

    private static func int64(_ value: Any?) -> Int64? {
        if let int = value as? Int { return Int64(int) }
        if let int64 = value as? Int64 { return int64 }
        if let number = value as? NSNumber { return number.int64Value }
        if let string = value as? String { return Int64(string) }
        return nil
    }

}

fileprivate extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String {
        if let value = self[key] {
            return String(describing: value)
        }
        return ""
    }

    func dictionary(_ key: String) -> [String: Any]? {
        self[key] as? [String: Any]
    }
}
