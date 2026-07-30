import Foundation

public struct GrokHookStatusReducer: Sendable {
    public private(set) var snapshot: SessionSnapshot
    /// When set, `applyWorkingVisibility` will fade the snapshot back to `.thinking`
    /// once `now >= workingVisibleUntil`. Anchored on the hook event timestamp so a
    /// delayed Halo tick or a startup replay still settles correctly. `nil` means
    /// "do not auto-fade" (e.g. permission_prompt holds indefinitely).
    private var workingVisibleUntil: Date?
    private var thinkingVisibleUntil: Date?
    private var pendingWorkingAction: String?
    /// Tracks whether the current `.working`/`.attention` state was entered via a
    /// permission_prompt notification. Permission prompts must never auto-fade.
    private var isPermissionPrompt = false
    /// Whether the session was active immediately before PreCompact.
    private var wasActiveBeforeCompaction: Bool?

    public init(threadId: String = "grok", now: Date = Date()) {
        self.snapshot = SessionSnapshot(
            threadId: threadId,
            projectName: "Grok",
            workingDirectory: "",
            state: .idle,
            action: "Ready",
            lastEventAt: now,
            completedAt: nil,
            active: false,
            agent: .grok
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
            if wasActiveBeforeCompaction != nil {
                isPermissionPrompt = false
                workingVisibleUntil = nil
                thinkingVisibleUntil = nil
                pendingWorkingAction = nil
                snapshot.active = true
                snapshot.state = .working
                snapshot.action = "Compressing context"
                snapshot.completedAt = nil
                break
            }
            // A new session always resets to idle regardless of prior state.
            isPermissionPrompt = false
            workingVisibleUntil = nil
            thinkingVisibleUntil = nil
            pendingWorkingAction = nil
            snapshot.active = false
            snapshot.state = .idle
            snapshot.action = "Ready"
            snapshot.completedAt = nil
        case "UserPromptSubmit":
            wasActiveBeforeCompaction = nil
            workingVisibleUntil = nil
            thinkingVisibleUntil = eventAt.addingTimeInterval(0.7)
            pendingWorkingAction = nil
            isPermissionPrompt = false
            snapshot.active = true
            snapshot.state = .thinking
            snapshot.action = "Thinking"
            snapshot.completedAt = nil
        case "PreToolUse":
            wasActiveBeforeCompaction = nil
            isPermissionPrompt = false
            // No auto-fade timeout during tool execution — the tool may run for
            // many seconds. If PostToolUse never arrives, the safety net in
            // applyWorkingVisibility recovers after 180 s.
            workingVisibleUntil = nil
            snapshot.active = true
            let action = GeneratedHaloSpec.friendlyAction(Self.normalizedToolName(Self.string(root["toolName"])))
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
        case "PostToolUse", "PostToolBatch":
            wasActiveBeforeCompaction = nil
            isPermissionPrompt = false
            snapshot.active = true
            if snapshot.state == .thinking,
               let thinkingVisibleUntil,
               eventAt < thinkingVisibleUntil {
                pendingWorkingAction = "Reviewing result"
            } else {
                thinkingVisibleUntil = nil
                pendingWorkingAction = nil
                snapshot.state = .working
                snapshot.action = "Reviewing result"
            }
            snapshot.completedAt = nil
            workingVisibleUntil = max(eventAt, thinkingVisibleUntil ?? eventAt).addingTimeInterval(0.65)
        case "PostToolUseFailure":
            wasActiveBeforeCompaction = nil
            isPermissionPrompt = false
            snapshot.active = true
            if snapshot.state == .thinking,
               let thinkingVisibleUntil,
               eventAt < thinkingVisibleUntil {
                pendingWorkingAction = "Tool failed"
            } else {
                thinkingVisibleUntil = nil
                pendingWorkingAction = nil
                snapshot.state = .working
                snapshot.action = "Tool failed"
            }
            snapshot.completedAt = nil
            workingVisibleUntil = max(eventAt, thinkingVisibleUntil ?? eventAt).addingTimeInterval(0.65)
        case "Notification":
            switch Self.string(root["notificationType"]) {
            case "permission_prompt":
                wasActiveBeforeCompaction = nil
                // Block on user approval. Render as `.attention` so the ring is
                // visually distinct. No auto-fade until PreToolUse / Stop / prompt.
                isPermissionPrompt = true
                workingVisibleUntil = nil
                thinkingVisibleUntil = nil
                pendingWorkingAction = nil
                snapshot.active = true
                snapshot.state = .attention
                snapshot.action = "Awaiting permission"
                snapshot.completedAt = nil
            case "idle_prompt":
                wasActiveBeforeCompaction = nil
                isPermissionPrompt = false
                workingVisibleUntil = nil
                thinkingVisibleUntil = nil
                pendingWorkingAction = nil
                snapshot.active = false
                snapshot.state = .idle
                snapshot.action = "Ready"
                snapshot.completedAt = nil
            default:
                break
            }
        case "PermissionRequest":
            wasActiveBeforeCompaction = nil
            isPermissionPrompt = true
            workingVisibleUntil = nil
            thinkingVisibleUntil = nil
            pendingWorkingAction = nil
            snapshot.active = true
            snapshot.state = .attention
            snapshot.action = "Awaiting permission"
            snapshot.completedAt = nil
        case "PermissionDenied":
            wasActiveBeforeCompaction = nil
            isPermissionPrompt = false
            workingVisibleUntil = nil
            thinkingVisibleUntil = nil
            pendingWorkingAction = nil
            snapshot.active = true
            snapshot.state = .attention
            snapshot.action = "Permission denied"
            snapshot.completedAt = nil
        case "Stop":
            wasActiveBeforeCompaction = nil
            isPermissionPrompt = false
            workingVisibleUntil = nil
            thinkingVisibleUntil = nil
            pendingWorkingAction = nil
            snapshot.active = false
            snapshot.state = .done
            snapshot.action = "Complete"
            snapshot.completedAt = eventAt
        case "StopFailure":
            wasActiveBeforeCompaction = nil
            isPermissionPrompt = false
            workingVisibleUntil = nil
            thinkingVisibleUntil = nil
            pendingWorkingAction = nil
            snapshot.active = false
            snapshot.state = .error
            snapshot.action = "Grok stopped with an error"
            snapshot.completedAt = nil
        case "PreCompact":
            if wasActiveBeforeCompaction == nil {
                wasActiveBeforeCompaction = snapshot.active
            }
            isPermissionPrompt = false
            workingVisibleUntil = nil
            thinkingVisibleUntil = nil
            pendingWorkingAction = nil
            snapshot.active = true
            snapshot.state = .working
            snapshot.action = "Compressing context"
            snapshot.completedAt = nil
        case "PostCompact":
            let shouldResumeActiveTurn = wasActiveBeforeCompaction
            wasActiveBeforeCompaction = nil
            isPermissionPrompt = false
            workingVisibleUntil = nil
            thinkingVisibleUntil = nil
            pendingWorkingAction = nil
            switch shouldResumeActiveTurn {
            case .some(let shouldResumeActiveTurn):
                if shouldResumeActiveTurn {
                    snapshot.active = true
                    snapshot.state = .thinking
                    snapshot.action = "Thinking"
                    snapshot.completedAt = nil
                } else {
                    snapshot.active = false
                    snapshot.state = .done
                    snapshot.action = "Context compacted"
                    snapshot.completedAt = eventAt
                }
            case .none:
                snapshot.active = false
                snapshot.state = .idle
                snapshot.action = "Ready"
                snapshot.completedAt = nil
            }
        case "SessionEnd":
            wasActiveBeforeCompaction = nil
            isPermissionPrompt = false
            workingVisibleUntil = nil
            thinkingVisibleUntil = nil
            pendingWorkingAction = nil
            if snapshot.active {
                snapshot.active = false
                snapshot.state = .idle
                snapshot.action = "Ready"
            }
        default:
            break
        }
    }

    /// Grok skips `Stop` / `StopFailure` hooks on user interrupt (Esc / Ctrl+C).
    /// Session `events.jsonl` records `turn_ended` with `outcome: "cancelled"`
    /// instead — map that to the same fault ring Codex uses for interruptions.
    public mutating func applyTurnCancelled(at eventAt: Date = Date()) {
        applyInterruptedTurn(at: eventAt, action: "Interrupted")
    }

    /// Non-cancel terminal failures observed in `events.jsonl` (e.g. outcome
    /// `error` / `failed`) when hooks did not emit `StopFailure`.
    public mutating func applyTurnFailed(at eventAt: Date = Date()) {
        applyInterruptedTurn(at: eventAt, action: "Grok stopped with an error")
    }

    private mutating func applyInterruptedTurn(at eventAt: Date, action: String) {
        // Only override an in-flight turn. Idle/done/error already terminal.
        guard snapshot.active
            || snapshot.state == .thinking
            || snapshot.state == .working
            || snapshot.state == .attention else {
            return
        }
        wasActiveBeforeCompaction = nil
        isPermissionPrompt = false
        workingVisibleUntil = nil
        thinkingVisibleUntil = nil
        pendingWorkingAction = nil
        snapshot.active = false
        snapshot.state = .error
        snapshot.action = action
        snapshot.lastEventAt = eventAt
        snapshot.completedAt = nil
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

        // Safety net: stuck PreToolUse without PostToolUse. Permission prompts exempt.
        if workingVisibleUntil == nil, !isPermissionPrompt {
            if now.timeIntervalSince(snapshot.lastEventAt) > 180 {
                if let shouldResumeActiveTurn = wasActiveBeforeCompaction {
                    wasActiveBeforeCompaction = nil
                    snapshot.active = shouldResumeActiveTurn
                    snapshot.state = shouldResumeActiveTurn ? .thinking : .idle
                    snapshot.action = shouldResumeActiveTurn ? "Thinking" : "Ready"
                    snapshot.completedAt = nil
                    return
                }
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
            snapshot.projectName = projectName.isEmpty ? "Grok" : projectName
        }
    }

    /// Normalize Grok Build tool names to shared friendly-action keys.
    /// `run_terminal_command` (and bash) map to shell_command → "Running command".
    private static func normalizedToolName(_ name: String) -> String {
        switch name.lowercased() {
        case "bash", "run_terminal_command":
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
