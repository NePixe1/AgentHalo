import Foundation

public struct AntigravityHookStatusReducer: Sendable {
    public private(set) var snapshot: SessionSnapshot
    /// When set, `applyWorkingVisibility` will fade the snapshot back to `.thinking`
    /// once `now >= workingVisibleUntil`. Anchored on the hook event timestamp so a
    /// delayed Halo tick or a startup replay still settles correctly.
    private var workingVisibleUntil: Date?
    private var thinkingVisibleUntil: Date?
    private var pendingWorkingAction: String?
    /// Conversation-DB `WAITING` / hook `PermissionRequest` that has not yet
    /// been promoted. Same role as Grok's `pendingPermissionRequestedAt`.
    private var pendingPermissionRequestedAt: Date?
    /// Genuine user-permission hold. Must not auto-fade via the stuck-tool net.
    private var isPermissionPrompt = false
    /// State/action to restore after a human allow. Antigravity does not emit a
    /// second PreToolUse after the sheet; the tool just starts running.
    private var prePermissionResume: (state: HaloState, action: String)?

    /// Hold before painting attention so a same-poll auto resolve never flashes.
    /// `WAITING` is already human-only; the delay is for observation-time replay.
    public static let pendingPermissionAttentionDelay: TimeInterval = 0.25

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
            clearPermissionHold()
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
            if isPermissionPrompt {
                break
            }
            pendingPermissionRequestedAt = nil
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
            // Fires when the tool is *requested*. Auto-allowed tools follow
            // with PostToolUse in tens of ms; permission sheets sit here.
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
            clearPermissionHold()
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
        case "Notification":
            if Self.string(root["notificationType"]) == "permission_prompt" {
                applyPermissionRequested(at: eventAt, observedAt: now)
            }
        case "PermissionRequest":
            applyPermissionRequested(at: eventAt, observedAt: now)
        case "PermissionDenied":
            applyPermissionResolved(decision: "deny", at: eventAt)
        case "Stop":
            clearPermissionHold()
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

    public mutating func applyPermissionUpdate(
        _ update: AntigravityPermissionUpdate,
        now: Date = Date()
    ) {
        switch update.kind {
        case .requested:
            applyPermissionRequested(at: update.at, observedAt: now)
        case .resolved(let decision):
            applyPermissionResolved(decision: decision, at: update.at)
        }
    }

    public mutating func applyPermissionRequested(at eventAt: Date = Date(), observedAt: Date? = nil) {
        armPendingPermission(eventAt: eventAt, observedAt: observedAt ?? eventAt)
    }

    public mutating func applyPermissionResolved(decision: String, at eventAt: Date = Date()) {
        pendingPermissionRequestedAt = nil
        if eventAt > snapshot.lastEventAt {
            snapshot.lastEventAt = eventAt
        }

        if Self.isDeniedDecision(decision) {
            isPermissionPrompt = true
            prePermissionResume = nil
            workingVisibleUntil = nil
            thinkingVisibleUntil = nil
            pendingWorkingAction = nil
            snapshot.active = true
            snapshot.state = .attention
            snapshot.action = "Permission denied"
            snapshot.completedAt = nil
            return
        }

        if snapshot.state == .attention || isPermissionPrompt {
            isPermissionPrompt = false
            snapshot.active = true
            if snapshot.state == .attention {
                restoreAfterPermissionAllow()
            } else {
                prePermissionResume = nil
            }
            snapshot.completedAt = nil
        }
    }

    public mutating func applyWorkingVisibility(now: Date = Date()) {
        applyPermissionVisibility(now: now)

        guard snapshot.active else { return }

        if let pendingWorkingAction,
           let thinkingVisibleUntil,
           now >= thinkingVisibleUntil {
            self.pendingWorkingAction = nil
            self.thinkingVisibleUntil = nil
            snapshot.state = .working
            snapshot.action = pendingWorkingAction
        }

        guard snapshot.state == .working, !isPermissionPrompt else { return }

        if let until = workingVisibleUntil, now >= until {
            workingVisibleUntil = nil
            snapshot.state = .thinking
            snapshot.action = "Thinking"
            return
        }

        if workingVisibleUntil == nil,
           pendingPermissionRequestedAt == nil,
           now.timeIntervalSince(snapshot.lastEventAt) > 180 {
            snapshot.state = .thinking
            snapshot.action = "Thinking"
        }
    }

    public mutating func applyPermissionVisibility(now: Date = Date()) {
        guard let pendingAt = pendingPermissionRequestedAt else { return }
        guard now.timeIntervalSince(pendingAt) >= Self.pendingPermissionAttentionDelay else {
            return
        }
        pendingPermissionRequestedAt = nil
        capturePrePermissionResume()
        isPermissionPrompt = true
        workingVisibleUntil = nil
        thinkingVisibleUntil = nil
        pendingWorkingAction = nil
        snapshot.active = true
        snapshot.state = .attention
        snapshot.action = "Awaiting permission"
        snapshot.completedAt = nil
        if now > snapshot.lastEventAt {
            snapshot.lastEventAt = now
        }
    }

    private mutating func armPendingPermission(eventAt: Date, observedAt: Date) {
        if pendingPermissionRequestedAt == nil {
            pendingPermissionRequestedAt = observedAt
        }
        if eventAt > snapshot.lastEventAt {
            snapshot.lastEventAt = eventAt
        }
        if !snapshot.active,
           snapshot.state == .idle || snapshot.state == .done {
            snapshot.active = true
        }
    }

    private mutating func capturePrePermissionResume() {
        guard prePermissionResume == nil else { return }
        if snapshot.state == .working {
            prePermissionResume = (state: .working, action: snapshot.action)
            return
        }
        if let pendingWorkingAction, !pendingWorkingAction.isEmpty {
            prePermissionResume = (state: .working, action: pendingWorkingAction)
            return
        }
        if snapshot.state == .thinking {
            prePermissionResume = (state: .thinking, action: snapshot.action)
            return
        }
        prePermissionResume = (state: .thinking, action: "Thinking")
    }

    private mutating func restoreAfterPermissionAllow() {
        snapshot.active = true
        if let resume = prePermissionResume {
            snapshot.state = resume.state
            snapshot.action = resume.action
            prePermissionResume = nil
            return
        }
        snapshot.state = .thinking
        snapshot.action = "Thinking"
    }

    private mutating func clearPermissionHold() {
        pendingPermissionRequestedAt = nil
        isPermissionPrompt = false
        prePermissionResume = nil
    }

    private static func isDeniedDecision(_ decision: String) -> Bool {
        let lower = decision.lowercased()
        return lower.contains("reject") || lower.contains("deny") || lower == "denied"
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
        guard let value, !(value is NSNull) else {
            return ""
        }
        if let value = value as? String {
            return value
        }
        if let value = value as? NSNumber {
            return value.stringValue
        }
        return String(describing: value)
    }
}
