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

    private mutating func reduceUser(_ root: [String: Any], now: Date) {
        if isLocalCommandUserRecord(root) {
            return
        }
        if firstContentType(root) == "tool_result" {
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
        return content.contains("<local-command-caveat>")
            || content.contains("<command-name>")
            || content.contains("<command-message>")
    }

    private mutating func reduceAssistant(_ root: [String: Any], now: Date) {
        guard firstContentType(root) == "tool_use" else {
            applyActiveThinkingOrWorking(now: now)
            return
        }

        let toolName = firstContentString(root, key: "name")
        inFlightTools += 1
        extendWorkingVisibility(seconds: 2.2, now: now)
        snapshot.active = true
        snapshot.state = .working
        snapshot.action = GeneratedHaloSpec.friendlyAction(Self.normalizedToolName(toolName))
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

    private func firstContentType(_ root: [String: Any]) -> String {
        firstContentString(root, key: "type")
    }

    private func firstContentString(_ root: [String: Any], key: String) -> String {
        guard let message = root["message"] as? [String: Any],
              let content = message["content"] as? [Any],
              let first = content.first as? [String: Any] else {
            return ""
        }
        return Self.string(first[key])
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
