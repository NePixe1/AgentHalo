import Foundation

public struct AntigravityHookStatusReducer: Sendable {
    public private(set) var snapshot: SessionSnapshot
    /// When set, `applyWorkingVisibility` will fade the snapshot back to `.thinking`
    /// once `now >= workingVisibleUntil`. Anchored on the hook event timestamp so a
    /// delayed Halo tick or a startup replay still settles correctly.
    private var workingVisibleUntil: Date?
    private var thinkingVisibleUntil: Date?
    private var pendingWorkingAction: String?

    public init(threadId: String = "antigravity", now: Date = Date()) {
        self.snapshot = SessionSnapshot(
            threadId: threadId,
            projectName: "Antigravity",
            workingDirectory: "",
            state: .idle,
            action: "Ready",
            lastEventAt: now,
            completedAt: nil,
            active: false,
            agent: .antigravity
        )
    }

    public mutating func consume(jsonLine: String, now: Date = Date()) {
        guard let data = jsonLine.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        let eventAt = Self.parseDate(Self.string(root["timestamp"])) ?? now
        snapshot.lastEventAt = eventAt
        updateIdentity(from: root)

        switch Self.string(root["event"]) {
        case "PreInvocation":
            workingVisibleUntil = nil
            thinkingVisibleUntil = eventAt.addingTimeInterval(0.7)
            pendingWorkingAction = nil
            snapshot.active = true
            snapshot.state = .thinking
            snapshot.action = "Thinking"
            snapshot.completedAt = nil
        case "PostInvocation":
            snapshot.active = true
            snapshot.completedAt = nil
            if snapshot.state == .working,
               let until = workingVisibleUntil,
               now < until {
                break
            }
            thinkingVisibleUntil = nil
            pendingWorkingAction = nil
            snapshot.state = .thinking
            snapshot.action = "Thinking"
        case "PreToolUse":
            // No auto-fade during tool execution. If PostToolUse never arrives,
            // applyWorkingVisibility recovers after 180 s.
            workingVisibleUntil = nil
            snapshot.active = true
            let action = GeneratedHaloSpec.friendlyAction(Self.normalizedToolName(Self.toolName(from: root)))
            if snapshot.state == .thinking,
               let thinkingVisibleUntil,
               eventAt < thinkingVisibleUntil {
                pendingWorkingAction = action
                snapshot.action = "Thinking"
            } else {
                thinkingVisibleUntil = nil
                pendingWorkingAction = nil
                snapshot.state = .working
                snapshot.action = action
            }
            snapshot.completedAt = nil
        case "PostToolUse":
            snapshot.active = true
            let failed = !Self.string(root["errorText"]).isEmpty
            let action = failed ? "Tool failed" : "Reviewing result"
            if snapshot.state == .thinking,
               let thinkingVisibleUntil,
               eventAt < thinkingVisibleUntil {
                pendingWorkingAction = action
            } else {
                thinkingVisibleUntil = nil
                pendingWorkingAction = nil
                snapshot.state = .working
                snapshot.action = action
            }
            snapshot.completedAt = nil
            workingVisibleUntil = eventAt.addingTimeInterval(0.65)
        case "Stop":
            workingVisibleUntil = nil
            thinkingVisibleUntil = nil
            pendingWorkingAction = nil
            snapshot.active = false
            if Self.isStopFailure(root) {
                snapshot.state = .error
                snapshot.action = "Antigravity stopped with an error"
                snapshot.completedAt = nil
            } else {
                snapshot.state = .done
                snapshot.action = "Complete"
                snapshot.completedAt = eventAt
            }
        default:
            break
        }
    }

    public mutating func applyWorkingVisibility(now: Date = Date()) {
        guard snapshot.active else { return }

        if let pendingWorkingAction,
           let thinkingVisibleUntil,
           now >= thinkingVisibleUntil {
            self.pendingWorkingAction = nil
            self.thinkingVisibleUntil = nil
            snapshot.state = .working
            snapshot.action = pendingWorkingAction
            return
        }

        guard snapshot.state == .working else { return }

        if let until = workingVisibleUntil, now >= until {
            workingVisibleUntil = nil
            snapshot.state = .thinking
            snapshot.action = "Thinking"
            return
        }

        // Safety net: stuck PreToolUse without PostToolUse. Force-fade after
        // 180 seconds of inactivity so the ring can recover without Stop.
        if workingVisibleUntil == nil,
           now.timeIntervalSince(snapshot.lastEventAt) > 180 {
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
            snapshot.projectName = projectName.isEmpty ? "Antigravity" : projectName
        }
        let title = Self.firstNonEmpty(root["sessionTitle"], root["session_title"], root["title"])
        if !title.isEmpty {
            snapshot.sessionTitle = title
        }
        let model = Self.firstNonEmpty(root["modelName"], root["model_name"], root["model"])
        if !model.isEmpty {
            snapshot.modelName = model
        }
    }

    private static func isStopFailure(_ root: [String: Any]) -> Bool {
        if isTruthy(root["fatal"]) {
            return true
        }
        return !string(root["errorText"]).isEmpty
    }

    private static func isTruthy(_ value: Any?) -> Bool {
        if let value = value as? Bool {
            return value
        }
        if let value = value as? NSNumber {
            return value != 0
        }
        switch string(value).lowercased() {
        case "true", "1", "yes":
            return true
        default:
            return false
        }
    }

    private static func toolName(from root: [String: Any]) -> String {
        let name = string(root["toolName"])
        if !name.isEmpty {
            return name
        }
        return string(root["tool"])
    }

    private static func firstNonEmpty(_ values: Any?...) -> String {
        for value in values {
            let text = string(value)
            if !text.isEmpty {
                return text
            }
        }
        return ""
    }

    private static func normalizedToolName(_ name: String) -> String {
        switch name.lowercased() {
        case "bash", "run_command", "run_terminal_command":
            return "shell_command"
        default:
            return name
        }
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
