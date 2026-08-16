import Foundation

public struct GrokHookStatusReducer: Sendable {
    public private(set) var snapshot: SessionSnapshot
    /// When set, `applyWorkingVisibility` will fade the snapshot back to `.thinking`
    /// once `now >= workingVisibleUntil`. Anchored on the hook event timestamp so a
    /// delayed Halo tick or a startup replay still settles correctly. `nil` means
    /// "do not auto-fade" (e.g. genuine permission holds indefinitely).
    private var workingVisibleUntil: Date?
    private var thinkingVisibleUntil: Date?
    private var pendingWorkingAction: String?
    /// Tracks whether the current `.attention` state is a genuine user-permission
    /// hold. Those must not auto-fade via the stuck-tool safety net.
    private var isPermissionPrompt = false
    /// Whether the session was active immediately before PreCompact.
    private var wasActiveBeforeCompaction: Bool?
    /// `permission_requested` from `events.jsonl` that has not yet resolved.
    /// Used to delay painting NEEDS YOU so Auto mode (wait_ms ≈ 0) never flashes.
    private var pendingPermissionRequestedAt: Date?
    /// Last known Grok `permissionMode` from hooks (`default` / `auto` / `plan` /
    /// `bypassPermissions`). Auto and bypass never need a purple NEEDS YOU ring —
    /// shell tools still emit permission_* with multi-second `wait_ms` under Auto.
    private var permissionMode: String?
    /// State/action to restore after a human permission allow. Grok's real order is
    /// PreToolUse → permission_requested → permission_resolved → PostToolUse; there
    /// is no second PreToolUse after approve, so we must not drop back to Thinking
    /// while the tool is still running.
    private var prePermissionResume: (state: HaloState, action: String)?
    /// Newest `promptId` from `UserPromptSubmit`. Used to drop a late
    /// `StopCancelled` that belongs to an already-replaced turn.
    private var currentPromptId = ""

    /// Fast path resolutions (read/grep Auto, rule allow) complete well under this.
    /// Shell Auto often sits in the 1.5–3 s band; those are gated by `permissionMode`
    /// instead of this threshold alone.
    public static let autoResolveWaitMsThreshold = 300
    /// Hold before painting attention when mode is unknown/default so same-poll
    /// auto resolve never flashes purple. Measured Auto shell waits are multi-second;
    /// `permissionMode == auto` suppresses attention entirely (preferred path).
    public static let pendingPermissionAttentionDelay: TimeInterval = 0.25

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

        let previousLastEventAt = snapshot.lastEventAt
        let eventAt = Self.parseDate(Self.string(root["timestamp"])) ?? now
        snapshot.lastEventAt = eventAt
        updateIdentity(from: root)
        updatePermissionMode(from: root)

        switch Self.string(root["event"]) {
        case "SessionStart":
            currentPromptId = ""
            if wasActiveBeforeCompaction != nil {
                clearPermissionHold()
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
            clearPermissionHold()
            workingVisibleUntil = nil
            thinkingVisibleUntil = nil
            pendingWorkingAction = nil
            snapshot.active = false
            snapshot.state = .idle
            snapshot.action = "Ready"
            snapshot.completedAt = nil
        case "UserPromptSubmit":
            wasActiveBeforeCompaction = nil
            currentPromptId = Self.firstString(root["promptId"], root["prompt_id"])
            workingVisibleUntil = nil
            thinkingVisibleUntil = eventAt.addingTimeInterval(0.7)
            pendingWorkingAction = nil
            clearPermissionHold()
            snapshot.active = true
            snapshot.state = .thinking
            snapshot.action = "Thinking"
            snapshot.completedAt = nil
        case "PreToolUse":
            wasActiveBeforeCompaction = nil
            // Tool is proceeding → permission is done (auto or user approved).
            clearPermissionHold()
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
            clearPermissionHold()
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
            clearPermissionHold()
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
                applyPermissionPromptHook(at: eventAt, observedAt: now)
            case "idle_prompt":
                wasActiveBeforeCompaction = nil
                clearPermissionHold()
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
            // Grok does not emit this hook today; keep parity with Claude path
            // but apply the same Auto-safe rules as permission_prompt.
            applyPermissionPromptHook(at: eventAt, observedAt: now)
        case "PermissionDenied":
            if Self.hasSubagentType(root) {
                snapshot.lastEventAt = previousLastEventAt
                break
            }
            wasActiveBeforeCompaction = nil
            pendingPermissionRequestedAt = nil
            isPermissionPrompt = true
            prePermissionResume = nil
            workingVisibleUntil = nil
            thinkingVisibleUntil = nil
            pendingWorkingAction = nil
            snapshot.active = true
            snapshot.state = .attention
            snapshot.action = "Permission denied"
            snapshot.completedAt = nil
        case "Stop":
            wasActiveBeforeCompaction = nil
            clearPermissionHold()
            workingVisibleUntil = nil
            thinkingVisibleUntil = nil
            pendingWorkingAction = nil
            snapshot.active = false
            snapshot.state = .done
            snapshot.action = "Complete"
            snapshot.completedAt = eventAt
        case "StopFailure":
            wasActiveBeforeCompaction = nil
            clearPermissionHold()
            workingVisibleUntil = nil
            thinkingVisibleUntil = nil
            pendingWorkingAction = nil
            snapshot.active = false
            snapshot.state = .error
            snapshot.action = "Grok stopped with an error"
            snapshot.completedAt = nil
        case "StopCancelled":
            if !applyStopCancelled(from: root, at: eventAt) {
                snapshot.lastEventAt = previousLastEventAt
            }
        case "PreCompact":
            if wasActiveBeforeCompaction == nil {
                wasActiveBeforeCompaction = snapshot.active
            }
            clearPermissionHold()
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
            clearPermissionHold()
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
            clearPermissionHold()
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

    // MARK: - Strategy A: hook permission_prompt

    /// Grok fires `Notification:permission_prompt` for both Auto and real waits,
    /// and typically *after* `PreToolUse` (which already painted `.working`).
    ///
    /// Never paint attention from the hook alone:
    /// - `permissionMode` auto / bypass → suppress entirely (shell Auto still has
    ///   multi-second `wait_ms`; purple would flash for the whole decision window).
    /// - Otherwise arm Strategy C's delayed pending (events stream owns promote).
    private mutating func applyPermissionPromptHook(at eventAt: Date, observedAt: Date) {
        wasActiveBeforeCompaction = nil

        if suppressesPermissionAttention {
            pendingPermissionRequestedAt = nil
            return
        }

        // Mid-tool (working) or thinking-min hold: arm delay only. Immediate
        // purple here was the Auto flash when PreToolUse kept `.thinking`.
        // Delay clock uses observation time so a late poll of an old eventAt
        // does not instantly promote.
        armPendingPermission(eventAt: eventAt, observedAt: observedAt)
    }

    // MARK: - Strategy C: events.jsonl permission lifecycle

    public mutating func applyPermissionUpdate(_ update: GrokPermissionUpdate, now: Date = Date()) {
        switch update.kind {
        case .requested:
            applyPermissionRequested(at: update.at, observedAt: now)
        case .resolved(_, let decision, let waitMs):
            applyPermissionResolved(decision: decision, waitMs: waitMs, at: update.at)
        }
    }

    /// Begin a permission decision. Do not paint attention yet — Auto resolves
    /// in tens of ms for reads, or multi-second under Auto shell. Real human
    /// waits are multi-second in `default` mode.
    ///
    /// Important: Grok emits `PreToolUse` *before* the permission UI for shell
    /// tools, so state is often already `.working` when this arrives. We must
    /// still arm the pending timer in ask modes; ignoring `.working` made real
    /// waits stay blue.
    public mutating func applyPermissionRequested(at eventAt: Date = Date(), observedAt: Date? = nil) {
        if suppressesPermissionAttention {
            pendingPermissionRequestedAt = nil
            if eventAt > snapshot.lastEventAt {
                snapshot.lastEventAt = eventAt
            }
            return
        }
        armPendingPermission(eventAt: eventAt, observedAt: observedAt ?? eventAt)
    }

    public mutating func applyPermissionResolved(
        decision: String,
        waitMs: Int,
        at eventAt: Date = Date()
    ) {
        pendingPermissionRequestedAt = nil
        if eventAt > snapshot.lastEventAt {
            snapshot.lastEventAt = eventAt
        }

        let denied = Self.isDeniedDecision(decision)
        let auto = waitMs < Self.autoResolveWaitMsThreshold
            || suppressesPermissionAttention

        if auto && !denied {
            // Instant auto-approve (or Auto/bypass mode): drop any false attention.
            // Prefer keeping / restoring `.working` when PreToolUse already started
            // the tool (Grok does not re-emit PreToolUse after allow).
            isPermissionPrompt = false
            if snapshot.state == .attention {
                restoreAfterPermissionAllow()
            } else {
                prePermissionResume = nil
            }
            return
        }

        if denied {
            // In Auto/bypass the user is not holding a prompt; still surface deny
            // so a blocked tool is visible, then leave attention until next event.
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

        // Human wait finished with allow — tool execution continues without a
        // second PreToolUse. Restore the pre-hold working state/action when we
        // had one (typical: PreToolUse → wait → allow → PostToolUse).
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

    /// Promote a still-pending `permission_requested` to NEEDS YOU after a short
    /// delay so Auto resolve never flashes purple. Applies even when state is
    /// `.working`, because Grok's PreToolUse runs before the human prompt UI.
    /// Suppressed entirely while `permissionMode` is auto / bypass.
    public mutating func applyPermissionVisibility(now: Date = Date()) {
        guard let pendingAt = pendingPermissionRequestedAt else { return }
        if suppressesPermissionAttention {
            pendingPermissionRequestedAt = nil
            return
        }
        guard now.timeIntervalSince(pendingAt) >= Self.pendingPermissionAttentionDelay else {
            return
        }
        pendingPermissionRequestedAt = nil
        // Capture resume target before overwriting with NEEDS YOU. Real Grok
        // order is PreToolUse (working) → wait → allow → tool runs → PostToolUse.
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
        // Delay is measured from first observation, not event timestamp — late
        // polls of already-old permission_requested lines must not instantly purple.
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

    /// Remember state/action so human allow can resume tool execution UI.
    private mutating func capturePrePermissionResume() {
        guard prePermissionResume == nil else { return }
        if snapshot.state == .working {
            prePermissionResume = (state: .working, action: snapshot.action)
            return
        }
        if let pendingWorkingAction, !pendingWorkingAction.isEmpty {
            // PreToolUse during thinking min-hold: tool action is deferred.
            prePermissionResume = (state: .working, action: pendingWorkingAction)
            return
        }
        if snapshot.state == .thinking {
            prePermissionResume = (state: .thinking, action: snapshot.action)
            return
        }
        prePermissionResume = (state: .thinking, action: "Thinking")
    }

    /// After allow: restore working tool UI when we had one; otherwise Thinking.
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
        isPermissionPrompt = false
        pendingPermissionRequestedAt = nil
        prePermissionResume = nil
    }

    /// Auto / always-approve modes must not drive the purple ring. Grok still
    /// emits permission_prompt + permission_requested/resolved (shell Auto
    /// wait_ms often 1.5–3 s) — that is not a human hold.
    private var suppressesPermissionAttention: Bool {
        Self.isAutoLikePermissionMode(permissionMode)
    }

    private mutating func updatePermissionMode(from root: [String: Any]) {
        let mode = Self.string(root["permissionMode"])
        if !mode.isEmpty {
            permissionMode = mode
        }
    }

    public static func isAutoLikePermissionMode(_ mode: String?) -> Bool {
        guard let mode, !mode.isEmpty else { return false }
        switch mode.lowercased() {
        case "auto",
             "bypasspermissions",
             "bypass_permissions",
             "always-approve",
             "always_approve",
             "yolo",
             "dontask",
             "dont_ask":
            return true
        default:
            return false
        }
    }

    private static func isDeniedDecision(_ decision: String) -> Bool {
        let lower = decision.lowercased()
        return lower.contains("reject") || lower.contains("deny") || lower == "denied"
    }

    /// First-class Grok 1.0.4+ hook for a turn that ended without completing.
    /// Returns false when the event must be ignored (nested subagent, or a
    /// stale `promptId` from a turn the session already replaced).
    ///
    /// `events.jsonl` `turn_ended cancelled` remains the fallback for older
    /// Grok builds that never emit this hook.
    @discardableResult
    mutating func applyStopCancelled(from root: [String: Any], at eventAt: Date) -> Bool {
        if Self.hasSubagentType(root) {
            return false
        }
        let incomingPromptId = Self.firstString(root["promptId"], root["prompt_id"])
        if shouldIgnoreStopCancelled(incomingPromptId: incomingPromptId) {
            return false
        }
        let reason = Self.firstString(root["reason"]).lowercased()
        switch reason {
        case "permission_rejected":
            applyInterruptedTurn(
                at: eventAt, action: "Permission denied", asError: true, refineTerminal: true)
        case "permission_cancelled":
            applyInterruptedTurn(
                at: eventAt, action: "Ready", asError: false, refineTerminal: true)
        case "max_turns", "no_progress":
            applyInterruptedTurn(
                at: eventAt, action: "Grok stopped with an error", asError: true, refineTerminal: true)
        default:
            applyInterruptedTurn(
                at: eventAt, action: "Interrupted", asError: true, refineTerminal: true)
        }
        return true
    }

    private func shouldIgnoreStopCancelled(incomingPromptId: String) -> Bool {
        if !incomingPromptId.isEmpty, !currentPromptId.isEmpty,
           incomingPromptId != currentPromptId {
            return true
        }
        // Unlabeled cancel only threatens a still-running identified turn.
        // After done/error, the same turn's late StopCancelled must still refine.
        if incomingPromptId.isEmpty, !currentPromptId.isEmpty, isInFlight {
            return true
        }
        return false
    }

    private var isInFlight: Bool {
        snapshot.active
            || snapshot.state == .thinking
            || snapshot.state == .working
            || snapshot.state == .attention
    }

    /// Fallback for pre-1.0.4 Grok, which skipped `Stop` / `StopFailure` on
    /// Esc / Ctrl+C. Session `events.jsonl` records `turn_ended` with
    /// `outcome: "cancelled"` — map that to the same fault ring Codex uses.
    ///
    /// Steer / Sent now also emits `cancelled` (often `trigger: send_now`). Those
    /// must not paint red — call `applySteerCancel` instead.
    public mutating func applyTurnCancelled(at eventAt: Date = Date()) {
        applyInterruptedTurn(at: eventAt, action: "Interrupted", asError: true)
    }

    /// Soft end for steer / cancel-then-send: clear the in-flight turn without
    /// the red fault ring. The subsequent `UserPromptSubmit` / new turn hooks
    /// re-activate thinking almost immediately.
    public mutating func applySteerCancel(at eventAt: Date = Date()) {
        applyInterruptedTurn(at: eventAt, action: "Ready", asError: false)
    }

    /// Non-cancel terminal failures observed in `events.jsonl` (e.g. outcome
    /// `error` / `failed`) when hooks did not emit `StopFailure`.
    public mutating func applyTurnFailed(at eventAt: Date = Date()) {
        applyInterruptedTurn(at: eventAt, action: "Grok stopped with an error", asError: true)
    }

    private mutating func applyInterruptedTurn(
        at eventAt: Date,
        action: String,
        asError: Bool,
        refineTerminal: Bool = false
    ) {
        // events.jsonl / Stop may already have parked the turn as error/done.
        // Same-turn StopCancelled still needs to refine that terminal state.
        let sameTurnTerminal = refineTerminal
            && (snapshot.state == .done || snapshot.state == .error)
        guard isInFlight || sameTurnTerminal else {
            return
        }
        wasActiveBeforeCompaction = nil
        clearPermissionHold()
        workingVisibleUntil = nil
        thinkingVisibleUntil = nil
        pendingWorkingAction = nil
        snapshot.active = false
        snapshot.state = asError ? .error : .idle
        snapshot.action = action
        snapshot.lastEventAt = eventAt
        snapshot.completedAt = nil
    }

    public mutating func applyWorkingVisibility(now: Date = Date()) {
        // Pending human permission → attention after delay (Strategy C).
        applyPermissionVisibility(now: now)

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

        // Safety net: stuck PreToolUse without PostToolUse. Permission holds exempt.
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

    private static func firstString(_ values: Any?...) -> String {
        for value in values {
            let text = string(value)
            if !text.isEmpty {
                return text
            }
        }
        return ""
    }

    private static func hasSubagentType(_ root: [String: Any]) -> Bool {
        !firstString(root["subagentType"], root["subagent_type"]).isEmpty
    }
}
