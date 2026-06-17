import Foundation

public struct ClaudeHookStatusReducer: Sendable {
    public private(set) var snapshot: SessionSnapshot
    /// When set, `applyWorkingVisibility` will fade the snapshot back to `.thinking`
    /// once `now >= workingVisibleUntil`. Anchored on the hook event timestamp so a
    /// delayed Halo tick or a startup replay still settles correctly. `nil` means
    /// "do not auto-fade" (e.g. permission_prompt holds indefinitely).
    private var workingVisibleUntil: Date?

    public init(threadId: String = "claude-code", now: Date = Date()) {
        self.snapshot = SessionSnapshot(
            threadId: threadId,
            projectName: "Claude Code",
            workingDirectory: "",
            state: .idle,
            action: "Ready",
            lastEventAt: now,
            completedAt: nil,
            active: false,
            agent: .claudeCode
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
        case "SessionStart":
            if !snapshot.active && snapshot.state != .done {
                snapshot.state = .idle
                snapshot.action = "Ready"
            }
        case "UserPromptSubmit":
            workingVisibleUntil = nil
            snapshot.active = true
            snapshot.state = .thinking
            snapshot.action = "Thinking"
            snapshot.completedAt = nil
        case "PreToolUse":
            workingVisibleUntil = nil
            snapshot.active = true
            snapshot.state = .working
            snapshot.action = GeneratedHaloSpec.friendlyAction(Self.normalizedToolName(Self.string(root["toolName"])))
            snapshot.completedAt = nil
        case "PostToolUse":
            snapshot.active = true
            snapshot.state = .working
            snapshot.action = "Reviewing result"
            snapshot.completedAt = nil
            // Anchored on event time, NOT `now`. A late tick still gets correct fade behavior.
            workingVisibleUntil = eventAt.addingTimeInterval(1.8)
        case "PostToolUseFailure":
            snapshot.active = true
            snapshot.state = .working
            snapshot.action = "Tool failed"
            snapshot.completedAt = nil
            workingVisibleUntil = eventAt.addingTimeInterval(1.8)
        case "Notification":
            switch Self.string(root["notificationType"]) {
            case "permission_prompt":
                // Block on user approval. No auto-fade — only the next PreToolUse / Stop clears this.
                workingVisibleUntil = nil
                snapshot.active = true
                snapshot.state = .working
                snapshot.action = "Awaiting permission"
                snapshot.completedAt = nil
            case "idle_prompt":
                workingVisibleUntil = nil
                snapshot.active = true
                snapshot.state = .thinking
                snapshot.action = "Awaiting reply"
                snapshot.completedAt = nil
            default:
                break
            }
        case "Stop":
            workingVisibleUntil = nil
            snapshot.active = false
            snapshot.state = .done
            snapshot.action = "Complete"
            snapshot.completedAt = eventAt
        case "StopFailure":
            workingVisibleUntil = nil
            snapshot.active = false
            snapshot.state = .error
            snapshot.action = "Claude Code stopped with an error"
            snapshot.completedAt = nil
        case "SessionEnd":
            if snapshot.active {
                snapshot.active = false
                snapshot.state = .idle
                snapshot.action = "Ready"
            }
        default:
            break
        }
    }

    public mutating func applyWorkingVisibility(now: Date = Date()) {
        if snapshot.active,
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

    private static func normalizedToolName(_ name: String) -> String {
        switch name.lowercased() {
        case "bash":
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
