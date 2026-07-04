import Foundation

public struct ClaudeSessionReducer: Sendable {
    public private(set) var snapshot: SessionSnapshot
    private var inFlightTools = 0
    private var workingVisibleUntil: Date?
    private var liveTracking: Bool

    public init(filePath: String, now: Date = Date(), liveTracking: Bool = true) {
        self.snapshot = SessionSnapshot(
            threadId: Self.threadId(from: filePath),
            projectName: "Claude Code",
            workingDirectory: "",
            state: .idle,
            action: "Ready",
            lastEventAt: now,
            completedAt: nil,
            active: false,
            agent: .claudeCode
        )
        self.liveTracking = liveTracking
    }

    public mutating func consume(jsonLine: String, now: Date = Date()) {
        guard let data = jsonLine.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        let eventAt = Self.parseDate(Self.string(root["timestamp"])) ?? now
        snapshot.lastEventAt = eventAt
        updateIdentity(from: root)

        switch Self.string(root["type"]) {
        case "user":
            reduceUser(root, now: now)
        case "assistant":
            reduceAssistant(root, now: now)
        case "system":
            reduceSystem(root, eventAt: eventAt)
        case "ai-title":
            updateSessionTitle(from: root)
        default:
            break
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
            snapshot.action = "Thinking"
        }
    }

    private mutating func updateIdentity(from root: [String: Any]) {
        let sessionId = Self.string(root["sessionId"])
        if !sessionId.isEmpty {
            snapshot.threadId = sessionId
        }
        let cwd = Self.string(root["cwd"])
        if !cwd.isEmpty {
            snapshot.workingDirectory = cwd
            let projectName = URL(fileURLWithPath: cwd).lastPathComponent
            snapshot.projectName = projectName.isEmpty ? "Claude Code" : projectName
        }
    }

    private mutating func updateSessionTitle(from root: [String: Any]) {
        let title = Self.string(root["aiTitle"]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty {
            snapshot.sessionTitle = title
        }
    }

    private mutating func reduceUser(_ root: [String: Any], now: Date) {
        if isLocalCommandUserRecord(root) {
            return
        }
        if containsContentType(root, type: "tool_result") {
            if inFlightTools > 0 {
                inFlightTools -= 1
            }
            if snapshot.active {
                if inFlightTools > 0 {
                    snapshot.state = .working
                } else if liveTracking {
                    setWorkingVisibility(seconds: 0.65, now: now)
                    snapshot.state = .working
                    snapshot.action = "Reviewing result"
                } else {
                    snapshot.state = .thinking
                    snapshot.action = "Thinking"
                }
            }
            return
        }

        inFlightTools = 0
        workingVisibleUntil = nil
        snapshot.active = true
        snapshot.state = .thinking
        snapshot.action = "Thinking"
    }

    private func isLocalCommandUserRecord(_ root: [String: Any]) -> Bool {
        let content = messageContentString(root)
        return content.contains("<local-command-")
            || content.contains("<command-name>")
            || content.contains("<command-message>")
            || content.contains("<command-args>")
    }

    private mutating func reduceAssistant(_ root: [String: Any], now: Date) {
        let toolNames = contentItems(root)
            .filter { Self.string($0["type"]).caseInsensitiveCompare("tool_use") == .orderedSame }
            .map { Self.string($0["name"]) }
        if let toolName = toolNames.first,
           toolName.caseInsensitiveCompare("AskUserQuestion") == .orderedSame {
            inFlightTools = 0
            workingVisibleUntil = nil
            snapshot.active = true
            snapshot.state = .attention
            snapshot.action = "Awaiting permission"
            snapshot.completedAt = nil
            return
        }
        if let toolName = toolNames.first {
            inFlightTools += toolNames.count
            extendWorkingVisibility(seconds: 1.0, now: now)
            snapshot.active = true
            snapshot.state = .working
            snapshot.action = GeneratedHaloSpec.friendlyAction(Self.normalizedToolName(toolName))
            snapshot.completedAt = nil
            return
        }
        if containsContentType(root, type: "thinking") || containsContentType(root, type: "text") {
            inFlightTools = 0
            workingVisibleUntil = nil
            snapshot.active = true
            snapshot.state = .thinking
            snapshot.action = "Thinking"
            snapshot.completedAt = nil
            return
        }
        applyActiveThinkingOrWorking(now: now)
    }

    private mutating func reduceSystem(_ root: [String: Any], eventAt: Date) {
        let subtype = Self.string(root["subtype"])
        if subtype == "turn_duration" || subtype == "stop_hook_summary" {
            inFlightTools = 0
            workingVisibleUntil = nil
            snapshot.active = false
            snapshot.state = .done
            snapshot.action = "Complete"
            snapshot.completedAt = eventAt
        } else if subtype == "api_error" {
            inFlightTools = 0
            workingVisibleUntil = nil
            snapshot.active = false
            snapshot.state = .error
            snapshot.action = "Service unavailable"
            snapshot.completedAt = nil
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

    private mutating func setWorkingVisibility(seconds: TimeInterval, now: Date) {
        guard liveTracking else {
            return
        }
        workingVisibleUntil = now.addingTimeInterval(seconds)
    }

    private func containsContentType(_ root: [String: Any], type: String) -> Bool {
        contentItems(root).contains {
            Self.string($0["type"]).caseInsensitiveCompare(type) == .orderedSame
        }
    }

    private func contentItems(_ root: [String: Any]) -> [[String: Any]] {
        guard let message = root["message"] as? [String: Any],
              let content = message["content"] as? [Any] else {
            return []
        }
        return content.compactMap { $0 as? [String: Any] }
    }

    private func messageContentString(_ root: [String: Any]) -> String {
        guard let message = root["message"] as? [String: Any] else {
            return ""
        }
        return Self.string(message["content"])
    }

    private static func normalizedToolName(_ name: String) -> String {
        switch name.lowercased() {
        case "bash":
            return "shell_command"
        default:
            return name
        }
    }

    private static func threadId(from filePath: String) -> String {
        let name = URL(fileURLWithPath: filePath).deletingPathExtension().lastPathComponent
        if UUID(uuidString: name) != nil {
            return name
        }
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

    private static func string(_ value: Any?) -> String {
        if let value {
            return String(describing: value)
        }
        return ""
    }
}
