import Foundation

public struct ClaudeHookStatusReducer: Sendable {
    public private(set) var snapshot: SessionSnapshot
    /// When set, `applyWorkingVisibility` will fade the snapshot back to `.thinking`
    /// once `now >= workingVisibleUntil`. Anchored on the hook event timestamp so a
    /// delayed Halo tick or a startup replay still settles correctly. `nil` means
    /// "do not auto-fade" (e.g. permission_prompt holds indefinitely).
    private var workingVisibleUntil: Date?
    /// Tracks whether the current `.working` state was entered via a permission_prompt
    /// notification. Per the plan, permission prompts must never auto-fade — the user
    /// must explicitly approve or reject. Distinguished from PreToolUse so the stuck-
    /// tool safety net can recover PreToolUse hangs without breaking permission holds.
    private var isPermissionPrompt = false

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
            // A new session always resets to idle regardless of prior state.
            // Without this, a previous Stop (→ .done) blocks every subsequent
            // SessionStart and the reducer can never return to idle on replay.
            isPermissionPrompt = false
            workingVisibleUntil = nil
            snapshot.active = false
            snapshot.state = .idle
            snapshot.action = "Ready"
            snapshot.completedAt = nil
        case "UserPromptSubmit":
            workingVisibleUntil = nil
            isPermissionPrompt = false
            snapshot.active = true
            snapshot.state = .thinking
            snapshot.action = "Thinking"
            snapshot.completedAt = nil
        case "PreToolUse":
            isPermissionPrompt = false
            // No auto-fade timeout during tool execution — the tool may run for
            // many seconds. If PostToolUse never arrives (crash, stale data),
            // the safety net in applyWorkingVisibility recovers after 30 s.
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
                isPermissionPrompt = true
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
            isPermissionPrompt = false
            workingVisibleUntil = nil
            snapshot.active = false
            snapshot.state = .done
            snapshot.action = "Complete"
            snapshot.completedAt = eventAt
        case "StopFailure":
            isPermissionPrompt = false
            workingVisibleUntil = nil
            snapshot.active = false
            snapshot.state = .error
            snapshot.action = "Claude Code stopped with an error"
            snapshot.completedAt = nil
        case "PreCompact":
            // Compaction is a transient background operation — show Executing while
            // CC compresses the context, then let PostCompact restore to Thinking.
            isPermissionPrompt = false
            workingVisibleUntil = nil
            snapshot.active = true
            snapshot.state = .working
            snapshot.action = "Compressing context"
            snapshot.completedAt = nil
        case "PostCompact":
            // Context compaction finished — return to Thinking as the default
            // active state. The next hook event (PreToolUse, UserPromptSubmit, …)
            // will refine the state further.
            isPermissionPrompt = false
            workingVisibleUntil = nil
            snapshot.active = true
            snapshot.state = .thinking
            snapshot.action = "Thinking"
            snapshot.completedAt = nil
        case "SessionEnd":
            isPermissionPrompt = false
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
        guard snapshot.active, snapshot.state == .working else { return }

        // Normal PostToolUse / PostToolUseFailure fade: anchored on event time.
        if let until = workingVisibleUntil, now >= until {
            workingVisibleUntil = nil
            snapshot.state = .thinking
            snapshot.action = "Thinking"
            return
        }

        // Safety net: when workingVisibleUntil is nil and this is NOT a permission
        // prompt, the reducer is stuck (PreToolUse without PostToolUse, stale test
        // data, etc.). Force-fade after 30 seconds of inactivity so the ring can
        // recover without an explicit Stop event.
        //
        // Permission prompts are exempt — the plan requires them to hold until the
        // user explicitly approves or rejects (tested in
        // testClaudeHookReducerPermissionPromptHoldsUntilResolved).
        if workingVisibleUntil == nil, !isPermissionPrompt {
            if now.timeIntervalSince(snapshot.lastEventAt) > 30 {
                snapshot.state = .thinking
                snapshot.action = "Thinking"
            }
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
