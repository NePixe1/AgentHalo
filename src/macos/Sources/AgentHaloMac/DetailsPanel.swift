import AppKit
import AgentHaloCore

enum DetailsPanelContentRole: Equatable {
    case agentSwitcher
    case statusTitle
    case statusDetail
    case usageBody
    case sessionBody
    case unknown
}

enum DetailsPanelSessionBodyRole: Equatable {
    case empty
    case sessionCard
    case unknown
}

@MainActor
class DetailsPanel: NSPanel {
    private static let panelWidth: CGFloat = 304
    private static let contextPillWidth: CGFloat = 46
    private static let contextPillHeight: CGFloat = 24
    /// Fixed session body slot height (Scheme B). Panel fitted height is 192.
    /// Slightly under the original 72 so the card bottom sits higher and outer
    /// bottom padding matches the top chrome more closely (equalizer absorbs the delta).
    private static let sessionBodyHeight: CGFloat = 68
    /// After COMPLETE settles into STANDBY (empty sessions), keep the last live
    /// context percent for this long before hiding. OFFLINE still clears immediately.
    nonisolated static let standbyContextHoldDuration: TimeInterval = 12

    private let stack = NSStackView()
    private let contextValue = NSTextField(labelWithString: L10n.shared["context.empty"])
    private let titleField = NSTextField(labelWithString: "OFFLINE")
    private let detailField = NSTextField(labelWithString: L10n.shared["status.offline_codex"])
    private let primaryQuota = QuotaRowView(title: L10n.shared["quota.5h"])
    private let secondaryQuota = QuotaRowView(title: L10n.shared["quota.weekly"])
    private let agentToggle = AgentToggleView()
    private let contextPill = NSView()
    private let quotaGroup = NSStackView()
    /// Hosts the fixed-height session body slot (empty | session card).
    /// Plain `NSView` (not `NSStackView`) so width is explicit and not ambiguous.
    private let metadataGroup = NSView()
    private let bodySlot = NSView()
    private let emptyBody = EmptySessionBodyView()
    private let sessionCard = SessionCardView()
    private var topRow: NSView?
    private var agentToggleWidthConstraint: NSLayoutConstraint?
    private var sessionBodyMode: DetailsPanelSessionBodyRole = .unknown
    /// Last live context percent used to soft-hold the pill after STANDBY.
    private var heldContextPercent: Double?
    /// When the standby hold started/should end; `nil` means not currently holding.
    private var contextHoldExpiresAt: Date?
    private var contextHoldAgent: AgentKind?
    private var statusMotionKey = ""
    private var statusMotionAgent: AgentKind?
    private let sessionDivider = NSView()
    var onMouseEntered: (() -> Void)?
    var onMouseExited: (() -> Void)?
    var onAgentSelected: ((AgentKind) -> Void)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 192),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        sharingType = .readOnly
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentMinSize = NSSize(width: Self.panelWidth, height: 0)
        contentMaxSize = NSSize(width: Self.panelWidth, height: CGFloat.greatestFiniteMagnitude)

        let container = NSVisualEffectView(frame: contentView?.bounds ?? .zero)
        container.material = .popover
        container.blendingMode = .behindWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 18
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor(
            calibratedRed: 183 / 255,
            green: 199 / 255,
            blue: 207 / 255,
            alpha: 46 / 255
        ).cgColor
        container.translatesAutoresizingMaskIntoConstraints = false

        // Near-opaque cool white. Popover material stays underneath, but the
        // fill covers it so status color and type are not sampled from the desktop.
        let surface = NSView()
        surface.identifier = NSUserInterfaceItemIdentifier("details-panel-surface")
        surface.wantsLayer = true
        surface.layer?.backgroundColor = NSColor(
            calibratedRed: 1,
            green: 1,
            blue: 1,
            alpha: 244 / 255
        ).cgColor
        surface.translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 17, bottom: 4, right: 17)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let topRow = makeTopRow()
        self.topRow = topRow
        stack.addArrangedSubview(topRow)
        stack.setCustomSpacing(12, after: topRow)

        titleField.font = .systemFont(ofSize: 22, weight: .bold)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.maximumNumberOfLines = 1
        titleField.usesSingleLineMode = true
        titleField.cell?.truncatesLastVisibleLine = true
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleField.alignment = .left
        detailField.font = .systemFont(ofSize: 13)
        detailField.textColor = NSColor(
            calibratedRed: 103 / 255,
            green: 117 / 255,
            blue: 126 / 255,
            alpha: 1
        )
        detailField.lineBreakMode = .byTruncatingTail
        detailField.maximumNumberOfLines = 1
        detailField.usesSingleLineMode = true
        detailField.cell?.truncatesLastVisibleLine = true
        detailField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailField.alignment = .left
        stack.addArrangedSubview(titleField)
        stack.setCustomSpacing(2, after: titleField)
        stack.addArrangedSubview(detailField)
        stack.setCustomSpacing(11, after: detailField)

        quotaGroup.orientation = .vertical
        quotaGroup.spacing = 4
        quotaGroup.alignment = .leading
        quotaGroup.translatesAutoresizingMaskIntoConstraints = false
        quotaGroup.addArrangedSubview(primaryQuota)
        quotaGroup.addArrangedSubview(secondaryQuota)
        stack.addArrangedSubview(quotaGroup)

        // Plain container: explicit full-width pin avoids NSStackView width
        // ambiguity that shrank empty/card to label-hugging size (right-biased).
        metadataGroup.translatesAutoresizingMaskIntoConstraints = false
        // Bottom inset keeps the session body contribution aligned with the 70pt
        // usage group (11 + 68 + 7 == 16 + 70) so both panels fit to 192.
        let sessionBodyBottomEqualizer: CGFloat = 7

        bodySlot.translatesAutoresizingMaskIntoConstraints = false
        emptyBody.translatesAutoresizingMaskIntoConstraints = false
        sessionCard.translatesAutoresizingMaskIntoConstraints = false
        // Expand horizontally; never hug label intrinsic width.
        for view in [bodySlot, emptyBody, sessionCard] as [NSView] {
            view.setContentHuggingPriority(.defaultLow, for: .horizontal)
            view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        sessionDivider.wantsLayer = true
        sessionDivider.layer?.backgroundColor = NSColor(
            calibratedRed: 190 / 255,
            green: 205 / 255,
            blue: 215 / 255,
            alpha: 1
        ).cgColor
        sessionDivider.translatesAutoresizingMaskIntoConstraints = false
        bodySlot.addSubview(sessionDivider)
        bodySlot.addSubview(emptyBody)
        bodySlot.addSubview(sessionCard)
        metadataGroup.addSubview(bodySlot)
        metadataGroup.isHidden = true
        stack.addArrangedSubview(metadataGroup)

        emptyBody.isHidden = true
        sessionCard.isHidden = true

        let rootView = TrackingDetailsContentView()
        rootView.owner = self
        contentView = rootView
        contentView?.addSubview(container)
        container.addSubview(surface)
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            contentView!.widthAnchor.constraint(equalToConstant: Self.panelWidth),
            container.leadingAnchor.constraint(equalTo: contentView!.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: contentView!.trailingAnchor),
            container.topAnchor.constraint(equalTo: contentView!.topAnchor),
            container.bottomAnchor.constraint(equalTo: contentView!.bottomAnchor),
            surface.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            surface.topAnchor.constraint(equalTo: container.topAnchor),
            surface.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            topRow.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -17),
            titleField.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 17),
            titleField.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -17),
            detailField.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 17),
            detailField.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -17),
            quotaGroup.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 17),
            quotaGroup.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -17),
            quotaGroup.heightAnchor.constraint(equalToConstant: 70),
            primaryQuota.leadingAnchor.constraint(equalTo: quotaGroup.leadingAnchor),
            primaryQuota.trailingAnchor.constraint(equalTo: quotaGroup.trailingAnchor),
            secondaryQuota.leadingAnchor.constraint(equalTo: quotaGroup.leadingAnchor),
            secondaryQuota.trailingAnchor.constraint(equalTo: quotaGroup.trailingAnchor),
            metadataGroup.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 17),
            metadataGroup.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -17),
            // Full-bleed body slot inside metadata container (+ bottom equalizer).
            bodySlot.leadingAnchor.constraint(equalTo: metadataGroup.leadingAnchor),
            bodySlot.trailingAnchor.constraint(equalTo: metadataGroup.trailingAnchor),
            bodySlot.topAnchor.constraint(equalTo: metadataGroup.topAnchor),
            bodySlot.bottomAnchor.constraint(
                equalTo: metadataGroup.bottomAnchor,
                constant: -sessionBodyBottomEqualizer
            ),
            bodySlot.heightAnchor.constraint(equalToConstant: Self.sessionBodyHeight),
            sessionDivider.leadingAnchor.constraint(equalTo: bodySlot.leadingAnchor),
            sessionDivider.trailingAnchor.constraint(equalTo: bodySlot.trailingAnchor),
            sessionDivider.topAnchor.constraint(equalTo: bodySlot.topAnchor),
            sessionDivider.heightAnchor.constraint(equalToConstant: 1),
            emptyBody.leadingAnchor.constraint(equalTo: bodySlot.leadingAnchor),
            emptyBody.trailingAnchor.constraint(equalTo: bodySlot.trailingAnchor),
            emptyBody.topAnchor.constraint(equalTo: bodySlot.topAnchor),
            emptyBody.bottomAnchor.constraint(equalTo: bodySlot.bottomAnchor),
            sessionCard.leadingAnchor.constraint(equalTo: bodySlot.leadingAnchor),
            sessionCard.trailingAnchor.constraint(equalTo: bodySlot.trailingAnchor),
            sessionCard.topAnchor.constraint(equalTo: bodySlot.topAnchor),
            sessionCard.bottomAnchor.constraint(equalTo: bodySlot.bottomAnchor)
        ])
    }

    func render(aggregate: AggregateSnapshot, model: DetailsPanelViewModel) {
        #if DEBUG
        let startTime = CFAbsoluteTimeGetCurrent()
        defer {
            let duration = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            if duration > 16.67 {
                NSLog("[Performance] DetailsPanel.render took %.2fms (>1 frame)", duration)
            }
        }
        #endif

        updateStatus(aggregate: aggregate)
        let isOffline = aggregate.state == .idle && aggregate.label == "OFFLINE"
        let isStandby = aggregate.label == "STANDBY"
        updateContext(
            model.contextUsedPercent,
            isOffline: isOffline,
            isStandby: isStandby,
            focusedAgent: aggregate.focusedAgent
        )

        quotaGroup.isHidden = true
        metadataGroup.isHidden = true

        switch model.body {
        case .usage(let usage):
            stack.setCustomSpacing(16, after: detailField)
            stack.edgeInsets.bottom = 4
            sessionBodyMode = .unknown
            renderUsage(usage)
            quotaGroup.isHidden = false
        case .session(let session):
            stack.setCustomSpacing(11, after: detailField)
            stack.edgeInsets.bottom = 4
            renderSession(session, isOffline: isOffline)
            metadataGroup.isHidden = false
        }
        resizeToFitContent()
    }

    /// Disk-/statusline-backed agents (Grok, Claude) only refresh context on
    /// full content render. While the panel stays open mid-turn, AppDelegate
    /// can push a fresh percent without rebuilding quota/session rows.
    func updateLiveContextPercent(
        _ contextUsedPercent: Double?,
        aggregate: AggregateSnapshot,
        now: Date = Date()
    ) {
        let isOffline = aggregate.state == .idle && aggregate.label == "OFFLINE"
        let isStandby = aggregate.label == "STANDBY"
        updateContext(
            contextUsedPercent,
            isOffline: isOffline,
            isStandby: isStandby,
            focusedAgent: aggregate.focusedAgent,
            now: now
        )
    }

    private func updateContext(
        _ contextUsedPercent: Double?,
        isOffline: Bool,
        isStandby: Bool = false,
        focusedAgent: AgentKind? = nil,
        now: Date = Date()
    ) {
        if let focusedAgent {
            if let contextHoldAgent, contextHoldAgent != focusedAgent {
                heldContextPercent = nil
                contextHoldExpiresAt = nil
            }
            contextHoldAgent = focusedAgent
        }

        let resolved = Self.resolveContextDisplay(
            contextUsedPercent: contextUsedPercent,
            isOffline: isOffline,
            isStandby: isStandby,
            heldPercent: heldContextPercent,
            holdExpiresAt: contextHoldExpiresAt,
            now: now,
            holdDuration: Self.standbyContextHoldDuration
        )
        heldContextPercent = resolved.heldPercent
        contextHoldExpiresAt = resolved.holdExpiresAt
        contextPill.isHidden = resolved.display == nil
        contextValue.stringValue = resolved.display.map(Self.compactContextPercent)
            ?? L10n.shared["context.empty"]
    }

    /// Pure display/hold state machine for the context pill.
    /// - Live percent: show and remember for a future STANDBY hold.
    /// - STANDBY + remembered percent: keep showing until `holdDuration` elapses.
    /// - OFFLINE: clear immediately (no hold).
    nonisolated static func resolveContextDisplay(
        contextUsedPercent: Double?,
        isOffline: Bool,
        isStandby: Bool,
        heldPercent: Double?,
        holdExpiresAt: Date?,
        now: Date,
        holdDuration: TimeInterval = standbyContextHoldDuration
    ) -> (display: Double?, heldPercent: Double?, holdExpiresAt: Date?) {
        if isOffline {
            return (nil, nil, nil)
        }
        if let contextUsedPercent {
            return (contextUsedPercent, contextUsedPercent, nil)
        }
        guard isStandby, let heldPercent else {
            return (nil, nil, nil)
        }
        let expiresAt = holdExpiresAt ?? now.addingTimeInterval(holdDuration)
        if now < expiresAt {
            return (heldPercent, heldPercent, expiresAt)
        }
        return (nil, nil, nil)
    }

    private func renderUsage(_ usage: UsageDetailsModel) {
        primaryQuota.setTitle(L10n.shared["quota.5h"])
        secondaryQuota.setTitle(L10n.shared["quota.weekly"])
        renderUsageWindow(usage.windows.first { $0.kind == .session }, in: primaryQuota)
        renderUsageWindow(usage.windows.first { $0.kind == .weekly }, in: secondaryQuota)
    }

    private func renderUsageWindow(_ window: UsageWindow?, in row: QuotaRowView) {
        guard let window else {
            row.updateUnavailable()
            return
        }
        row.update(usedPercent: window.usedPercent, resetAt: window.resetsAt)
    }

    private func renderSession(_ session: SessionDetailsSnapshot, isOffline: Bool) {
        // Soft empty rectangle for both OFFLINE and online-with-no-fields so we
        // never show a card full of "--" (STANDBY often has empty snapshots).
        // Same copy for offline and blank/standby: "○ No session".
        if isOffline || !Self.hasSessionCardContent(session) {
            emptyBody.isHidden = false
            sessionCard.isHidden = true
            emptyBody.setText("○ " + L10n.shared["session.empty.api_key"])
            sessionBodyMode = .empty
            // Clear hidden card fields so a11y / subsequent reads do not leak
            // the previous session title, model, or tokens.
            sessionCard.setTitle("--", toolTip: nil)
            sessionCard.setModel("--")
            sessionCard.setTokens(input: nil, output: nil)
            return
        }

        emptyBody.isHidden = true
        sessionCard.isHidden = false
        sessionBodyMode = .sessionCard
        let line = Self.sessionCardLine(session)
        sessionCard.setTitle(line.text, toolTip: line.toolTip)
        sessionCard.setModel(Self.displayValue(session.modelName))
        sessionCard.setTokens(input: session.inputTokens, output: session.outputTokens)
    }

    /// Card is only worth showing when at least one field the card paints has data.
    /// `projectName` alone does not count — the card never surfaces it.
    /// A working directory does: Pi, OpenCode, and WorkBuddy use it as the primary line.
    static func hasSessionCardContent(_ session: SessionDetailsSnapshot) -> Bool {
        if nonEmpty(session.workingDirectory) != nil {
            return true
        }
        if nonEmpty(session.sessionTitle) != nil {
            return true
        }
        if let model = session.modelName, !model.isEmpty {
            return true
        }
        return session.inputTokens != nil || session.outputTokens != nil
    }

    /// Primary session line. A path wins over a raw session name; Claude and
    /// Codex keep the session title when no directory was supplied.
    static func sessionCardLine(
        _ session: SessionDetailsSnapshot
    ) -> (text: String, toolTip: String?) {
        if let path = nonEmpty(session.workingDirectory) {
            return (path, path)
        }
        if let title = nonEmpty(session.sessionTitle) {
            return (title, title)
        }
        return ("--", nil)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func resizeToFitContent() {
        contentView?.layoutSubtreeIfNeeded()
        let scale = effectiveBackingScale
        let fittingHeight = Self.evenPanelHeight(
            for: stack.fittingSize.height,
            backingScaleFactor: scale
        )
        let topEdge = frame.maxY
        let newFrame = NSRect(
            x: frame.minX,
            y: topEdge - fittingHeight,
            width: Self.panelWidth,
            height: fittingHeight
        )
        applyResizeFrame(newFrame, display: false, animate: false)
    }

    func applyResizeFrame(_ frame: NSRect, display: Bool, animate: Bool) {
        setFrame(frame, display: display, animate: animate)
    }

    private var effectiveBackingScale: CGFloat {
        screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
    }

    static func evenPanelHeight(for fittingHeight: CGFloat, backingScaleFactor: CGFloat) -> CGFloat {
        let scale = backingScaleFactor > 0 ? backingScaleFactor : 1
        let pixelAlignedHeight = ceil(fittingHeight * scale) / scale
        return ceil(pixelAlignedHeight / 2) * 2
    }

    func updateStatus(aggregate: AggregateSnapshot, now: Date = Date()) {
        titleField.stringValue = aggregate.label
        let rgb = HaloVisualModel.stateColor(aggregate.state)
        titleField.textColor = NSColor(calibratedRed: rgb.red / 255, green: rgb.green / 255, blue: rgb.blue / 255, alpha: 1)
        detailField.stringValue = Self.localizedDetail(for: aggregate)
        agentToggle.setAgent(aggregate.focusedAgent)
        playStatusMotion(
            agent: aggregate.focusedAgent,
            label: aggregate.label,
            detail: detailField.stringValue
        )
        let isOffline = aggregate.state == .idle && aggregate.label == "OFFLINE"
        let isStandby = aggregate.label == "STANDBY"
        switch aggregate.focusedAgent {
        case .codex:
            // Codex streams context on the status-only path from live snapshots.
            // Empty sessions on STANDBY soft-hold the last percent briefly.
            updateContext(
                aggregate.sessions.first?.contextUsedPercent,
                isOffline: isOffline,
                isStandby: isStandby,
                focusedAgent: .codex,
                now: now
            )
        case .grok, .claudeCode, .pi, .antigravity, .opencode, .workbuddy:
            // Grok/Claude/Pi context is disk-, statusline-, or extension-backed on
            // full content refresh. Only STANDBY/OFFLINE status ticks should touch
            // the pill: STANDBY soft-holds the last live percent; OFFLINE clears
            // immediately. Active labels leave existing metadata alone (status-only
            // path must not wipe context when sessions briefly look empty).
            if isOffline || isStandby {
                updateContext(
                    nil,
                    isOffline: isOffline,
                    isStandby: isStandby,
                    focusedAgent: aggregate.focusedAgent,
                    now: now
                )
            }
        }
    }

    /// Short crossfade plus a few points of travel when the focused agent changes.
    /// Opacity stays high so the panel does not flash white.
    private func playStatusMotion(agent: AgentKind, label: String, detail: String) {
        let key = "\(agent.rawValue)\u{1f}\(label)\u{1f}\(detail)"
        let previousAgent = statusMotionAgent
        let changed = key != statusMotionKey
        statusMotionKey = key
        statusMotionAgent = agent
        guard changed, previousAgent != nil else { return }
        var shift: CGFloat = 0
        if let previousAgent, previousAgent != agent,
           let from = AgentKind.allCases.firstIndex(of: previousAgent),
           let to = AgentKind.allCases.firstIndex(of: agent),
           from != to {
            shift = to > from ? 5 : -5
        }
        for view in [titleField, detailField, metadataGroup, quotaGroup] as [NSView] {
            view.wantsLayer = true
            view.layer?.removeAnimation(forKey: "agenthalo.status.move")
            view.layer?.removeAnimation(forKey: "agenthalo.status.fade")
            let move = CABasicAnimation(keyPath: "transform.translation.x")
            move.fromValue = -shift
            move.toValue = 0
            move.duration = 0.18
            move.timingFunction = CAMediaTimingFunction(name: .easeOut)
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.78
            fade.toValue = 1
            fade.duration = 0.18
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            view.layer?.add(move, forKey: "agenthalo.status.move")
            view.layer?.add(fade, forKey: "agenthalo.status.fade")
        }
    }

    static func formatResetTime(_ date: Date?) -> String {
        guard let date else {
            return ""
        }
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: L10n.shared["date.culture"])
        if calendar.isDateInToday(date) {
            formatter.dateFormat = L10n.shared["date.today_format"]
        } else {
            formatter.dateFormat = L10n.shared["date.other_format"]
        }
        return L10n.shared.format("quota.resets", formatter.string(from: date))
    }

    static func compactTokenCount(_ count: Int64?) -> String {
        guard let count else {
            return "--"
        }
        guard count >= 1_000 else {
            return String(count)
        }
        let thousands = Double(count) / 1_000
        if thousands.rounded() == thousands {
            return "\(Int(thousands))k"
        }
        return String(format: "%.1fk", locale: Locale(identifier: "en_US_POSIX"), thousands)
    }

    static func compactContextPercent(_ value: Double) -> String {
        "\(min(99, max(0, Int(value.rounded()))))%"
    }

    static func formatTokenChip(input: Bool, count: Int64?) -> String {
        (input ? "↑ " : "↓ ") + compactTokenCount(count)
    }

    private static func displayValue(_ value: String?) -> String {
        guard let value, !value.isEmpty else {
            return "--"
        }
        return value
    }

    static func localizedDetail(for aggregate: AggregateSnapshot) -> String {
        if aggregate.state == .idle {
            if aggregate.label == "PAUSED" {
                return L10n.shared["status.paused"]
            }
            if aggregate.label == "CONNECTING" {
                return aggregate.detail.isEmpty
                    ? aggregate.focusedAgent.localizedConnectingDetail
                    : aggregate.detail
            }
            return aggregate.focusedAgent.localizedOfflineDetail
        }
        if aggregate.label == "STANDBY",
           !aggregate.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return aggregate.detail
        }
        let action = aggregate.sessions.first?.action ?? aggregate.detail
        if action.localizedCaseInsensitiveContains("Writing answer") {
            return L10n.shared["status.writing_answer"]
        }
        if action.localizedCaseInsensitiveContains("command") { return L10n.shared["status.running_command"] }
        if action.localizedCaseInsensitiveContains("Editing") { return L10n.shared["status.editing_files"] }
        if action.localizedCaseInsensitiveContains("Search") { return L10n.shared["status.searching"] }
        if action.localizedCaseInsensitiveContains("Compressing context") { return L10n.shared["status.compressing_context"] }
        if action.localizedCaseInsensitiveContains("Context compacted") { return L10n.shared["status.context_compacted"] }
        if action.localizedCaseInsensitiveContains("Awaiting permission") { return L10n.shared["status.awaiting_permission"] }
        if action.localizedCaseInsensitiveContains("Permission denied") { return L10n.shared["status.permission_denied"] }
        if action.localizedCaseInsensitiveContains("Reviewing result") { return L10n.shared["status.reviewing_result"] }
        switch aggregate.state {
        case .thinking: return L10n.shared["status.thinking"]
        case .working: return L10n.shared["status.working"]
        case .done: return L10n.shared["status.done"]
        case .attention: return L10n.shared["status.attention"]
        case .error:
            if let action = aggregate.sessions.first?.action,
               !action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return action
            }
            return aggregate.detail.isEmpty ? L10n.shared["status.error"] : aggregate.detail
        case .idle: return aggregate.focusedAgent.localizedOfflineDetail
        }
    }

    private func makeTopRow() -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        agentToggle.onAgentSelected = { [weak self] agent in
            self?.onAgentSelected?(agent)
        }

        contextPill.wantsLayer = true
        contextPill.layer?.cornerRadius = 8
        contextPill.layer?.masksToBounds = true
        contextPill.layer?.backgroundColor = NSColor(
            calibratedRed: 224 / 255,
            green: 240 / 255,
            blue: 252 / 255,
            alpha: 1
        ).cgColor
        contextPill.layer?.borderWidth = 1
        contextPill.layer?.borderColor = NSColor(
            calibratedRed: 174 / 255,
            green: 205 / 255,
            blue: 224 / 255,
            alpha: 72 / 255
        ).cgColor
        contextPill.translatesAutoresizingMaskIntoConstraints = false

        contextValue.font = .systemFont(ofSize: 15, weight: .bold)
        contextValue.textColor = NSColor(
            calibratedRed: 64 / 255,
            green: 105 / 255,
            blue: 132 / 255,
            alpha: 1
        )
        contextValue.alignment = .center
        contextValue.lineBreakMode = .byTruncatingTail
        contextValue.translatesAutoresizingMaskIntoConstraints = false

        row.addSubview(agentToggle)
        row.addSubview(contextPill)
        contextPill.addSubview(contextValue)

        let toggleWidth = agentToggle.widthAnchor.constraint(
            equalToConstant: AgentToggleView.slotWidth * CGFloat(HaloSettings.defaultEnabledAgents.count)
        )
        agentToggleWidthConstraint = toggleWidth

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 32),
            agentToggle.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            agentToggle.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            toggleWidth,
            agentToggle.heightAnchor.constraint(equalToConstant: 32),
            contextPill.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            contextPill.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            contextPill.widthAnchor.constraint(equalToConstant: Self.contextPillWidth),
            contextPill.heightAnchor.constraint(equalToConstant: Self.contextPillHeight),
            contextPill.leadingAnchor.constraint(greaterThanOrEqualTo: agentToggle.trailingAnchor, constant: 10),
            contextValue.centerXAnchor.constraint(equalTo: contextPill.centerXAnchor),
            contextValue.centerYAnchor.constraint(equalTo: contextPill.centerYAnchor),
            contextValue.leadingAnchor.constraint(greaterThanOrEqualTo: contextPill.leadingAnchor, constant: 2),
            contextValue.trailingAnchor.constraint(lessThanOrEqualTo: contextPill.trailingAnchor, constant: -2)
        ])
        return row
    }

    func setEnabledAgents(_ agents: [AgentKind], focused: AgentKind) {
        agentToggle.setEnabledAgents(
            agents,
            focused: focused,
            maximumWidth: Self.agentToggleMaximumWidth
        )
        agentToggleWidthConstraint?.constant = agentToggle.toggleWidthForTesting
    }

    /// Room left of the context pill inside the fixed 304pt panel:
    /// 304 - insets 34 - pill 46 - gap 10.
    static let agentToggleMaximumWidth: CGFloat = 214

    var enabledAgentsForTesting: [AgentKind] {
        agentToggle.enabledAgentsForTesting
    }

    var agentToggleWidthForTesting: CGFloat {
        agentToggle.toggleWidthForTesting
    }

    var focusedAgentForTesting: AgentKind {
        agentToggle.selectedAgent
    }

    var titleTextForTesting: String {
        titleField.stringValue
    }

    var detailTextForTesting: String {
        detailField.stringValue
    }

    var detailFrameForTesting: CGRect {
        detailField.convert(detailField.bounds, to: contentView)
    }

    var contextPillHiddenForTesting: Bool {
        contextPill.isHidden
    }

    var contextValueForTesting: String {
        contextValue.stringValue
    }

    var contextPillWidthForTesting: CGFloat {
        contextPill.frame.width
    }

    var contextValueWidthForTesting: CGFloat {
        contextValue.bounds.width
    }

    var contextValueIntrinsicWidthForTesting: CGFloat {
        contextValue.intrinsicContentSize.width
    }

    var contextValueExpansionFrameForTesting: CGRect {
        contextValue.cell?.expansionFrame(withFrame: contextValue.bounds, in: contextValue) ?? .zero
    }

    var contentOrderForTesting: [DetailsPanelContentRole] {
        stack.arrangedSubviews.map { view in
            if view === topRow { return .agentSwitcher }
            if view === titleField { return .statusTitle }
            if view === detailField { return .statusDetail }
            if view === quotaGroup { return .usageBody }
            if view === metadataGroup { return .sessionBody }
            return .unknown
        }
    }

    var usageGroupHiddenForTesting: Bool {
        quotaGroup.isHidden
    }

    var sessionGroupHiddenForTesting: Bool {
        metadataGroup.isHidden
    }

    var sessionBodyOrderForTesting: [DetailsPanelSessionBodyRole] {
        // Legacy diagnostics only. Scheme B contract uses sessionBodyModeForTesting.
        [sessionBodyModeForTesting]
    }

    var sessionRowHeightsForTesting: [CGFloat] {
        contentView?.layoutSubtreeIfNeeded()
        return [sessionBodySlotHeightForTesting]
    }

    // MARK: - Scheme B session body accessors

    var sessionBodyModeForTesting: DetailsPanelSessionBodyRole { sessionBodyMode }

    var sessionCardTitleForTesting: String { sessionCard.titleText }

    var sessionCardModelForTesting: String { sessionCard.modelText }

    var sessionCardTokensForTesting: String { sessionCard.tokensText }

    var sessionCardTitleToolTipForTesting: String? { sessionCard.titleToolTipText }

    var sessionBodySlotHeightForTesting: CGFloat {
        contentView?.layoutSubtreeIfNeeded()
        return bodySlot.frame.height
    }

    var sessionCardHeightForTesting: CGFloat {
        contentView?.layoutSubtreeIfNeeded()
        return sessionCard.frame.height
    }

    var sessionEmptyTextForTesting: String { emptyBody.text }

    var emptyBodyHeightForTesting: CGFloat {
        contentView?.layoutSubtreeIfNeeded()
        return emptyBody.frame.height
    }

    var primaryQuotaTitleForTesting: String {
        primaryQuota.titleForTesting
    }

    var secondaryQuotaTitleForTesting: String {
        secondaryQuota.titleForTesting
    }

    var primaryQuotaValueForTesting: String {
        primaryQuota.valueForTesting
    }

    var secondaryQuotaValueForTesting: String {
        secondaryQuota.valueForTesting
    }

    var primaryQuotaResetHiddenForTesting: Bool {
        primaryQuota.resetHiddenForTesting
    }

    var secondaryQuotaResetHiddenForTesting: Bool {
        secondaryQuota.resetHiddenForTesting
    }

    var primaryQuotaMeterFillForTesting: Double {
        primaryQuota.meterFillForTesting
    }

    var secondaryQuotaMeterFillForTesting: Double {
        secondaryQuota.meterFillForTesting
    }

    var primaryQuotaFrameForTesting: CGRect {
        primaryQuota.convert(primaryQuota.bounds, to: contentView)
    }

    var primaryQuotaNameFrameForTesting: CGRect {
        primaryQuota.convert(primaryQuota.nameFrameForTesting, to: contentView)
    }

    var secondaryQuotaFrameForTesting: CGRect {
        secondaryQuota.convert(secondaryQuota.bounds, to: contentView)
    }

    var secondaryQuotaResetFrameForTesting: CGRect {
        secondaryQuota.convert(secondaryQuota.resetFrameForTesting, to: contentView)
    }

    var primaryQuotaHasAmbiguousLayoutForTesting: Bool {
        primaryQuota.hasAmbiguousLayout
    }

    var secondaryQuotaHasAmbiguousLayoutForTesting: Bool {
        secondaryQuota.hasAmbiguousLayout
    }

    var sessionTitleValueForTesting: String {
        sessionCard.titleText
    }

    var modelValueForTesting: String {
        sessionCard.modelText
    }

    var tokenValueForTesting: String {
        sessionCard.tokensText
    }

    var sessionTitleToolTipForTesting: String? {
        sessionCard.titleToolTipText
    }

    var modelToolTipForTesting: String? {
        nil
    }

    var frameWidthForTesting: CGFloat {
        frame.width
    }

    var frameHeightForTesting: CGFloat {
        frame.height
    }

    var stackFittingHeightForTesting: CGFloat {
        stack.fittingSize.height
    }

    var metadataTopInsetForTesting: CGFloat {
        // Session body container is a plain NSView; top inset is always 0
        // (bottom equalizer is applied via bodySlot bottom constraint).
        0
    }

    var backingScaleForTesting: CGFloat {
        effectiveBackingScale
    }

    func selectAgentForTesting(_ agent: AgentKind) {
        agentToggle.setAgent(agent)
        onAgentSelected?(agent)
    }
}

/// Empty session copy shares the status text's left edge. No separate dashed box.
@MainActor
private final class EmptySessionBodyView: NSView {
    private let label = NSTextField(labelWithString: "")

    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    /// Prefer expanding to fill body slot; do not hug label width.
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay

        label.font = .systemFont(ofSize: 12, weight: .regular)
        label.textColor = NSColor(calibratedRed: 109 / 255, green: 129 / 255, blue: 144 / 255, alpha: 1)
        label.alignment = .left
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setText(_ text: String) {
        label.stringValue = text
    }
}

/// Online session summary: path or title, then model / input / output chips.
@MainActor
private final class SessionCardView: NSView {
    private let titleLabel = NSTextField(labelWithString: "--")
    private let modelChip = NSView()
    private let modelLabel = NSTextField(labelWithString: "--")
    private let inputChip = NSView()
    private let inputLabel = NSTextField(labelWithString: "↑ --")
    private let outputChip = NSView()
    private let outputLabel = NSTextField(labelWithString: "↓ --")

    var titleText: String { titleLabel.stringValue }
    var modelText: String { modelLabel.stringValue }
    var tokensText: String { "\(inputLabel.stringValue) \(outputLabel.stringValue)" }
    var titleToolTipText: String? { titleLabel.toolTip }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = NSColor(calibratedRed: 30 / 255, green: 44 / 255, blue: 54 / 255, alpha: 1)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.usesSingleLineMode = true
        titleLabel.cell?.truncatesLastVisibleLine = true
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        configureChip(
            modelChip,
            label: modelLabel,
            fill: NSColor(calibratedRed: 238 / 255, green: 241 / 255, blue: 244 / 255, alpha: 1),
            text: NSColor(calibratedRed: 77 / 255, green: 97 / 255, blue: 112 / 255, alpha: 1)
        )
        configureChip(
            inputChip,
            label: inputLabel,
            fill: NSColor(calibratedRed: 228 / 255, green: 242 / 255, blue: 252 / 255, alpha: 1),
            text: NSColor(calibratedRed: 51 / 255, green: 119 / 255, blue: 160 / 255, alpha: 1)
        )
        configureChip(
            outputChip,
            label: outputLabel,
            fill: NSColor(calibratedRed: 228 / 255, green: 246 / 255, blue: 238 / 255, alpha: 1),
            text: NSColor(calibratedRed: 35 / 255, green: 133 / 255, blue: 112 / 255, alpha: 1)
        )
        // Plain chip views have no intrinsic width; protect the token text so
        // the model truncates first while chip width limits can still apply.
        inputLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        outputLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        addSubview(titleLabel)
        addSubview(modelChip)
        addSubview(inputChip)
        addSubview(outputChip)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 11),

            modelChip.leadingAnchor.constraint(equalTo: leadingAnchor),
            modelChip.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            modelChip.heightAnchor.constraint(equalToConstant: 22),
            modelChip.widthAnchor.constraint(lessThanOrEqualToConstant: 160),
            modelChip.trailingAnchor.constraint(lessThanOrEqualTo: inputChip.leadingAnchor, constant: -8),

            inputChip.centerYAnchor.constraint(equalTo: modelChip.centerYAnchor),
            inputChip.heightAnchor.constraint(equalToConstant: 22),
            inputChip.widthAnchor.constraint(lessThanOrEqualToConstant: 75),
            inputChip.trailingAnchor.constraint(equalTo: outputChip.leadingAnchor, constant: -5),

            outputChip.trailingAnchor.constraint(equalTo: trailingAnchor),
            outputChip.centerYAnchor.constraint(equalTo: modelChip.centerYAnchor),
            outputChip.heightAnchor.constraint(equalToConstant: 22),
            outputChip.widthAnchor.constraint(lessThanOrEqualToConstant: 75)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setTitle(_ title: String, toolTip: String?) {
        titleLabel.stringValue = title
        if let toolTip, !toolTip.isEmpty, toolTip != "--" {
            titleLabel.toolTip = toolTip
        } else {
            titleLabel.toolTip = nil
        }
    }

    func setModel(_ model: String) {
        modelLabel.stringValue = model
        modelLabel.toolTip = model == "--" ? nil : model
    }

    func setTokens(input: Int64?, output: Int64?) {
        inputLabel.stringValue = DetailsPanel.formatTokenChip(input: true, count: input)
        outputLabel.stringValue = DetailsPanel.formatTokenChip(input: false, count: output)
    }

    private func configureChip(_ chip: NSView, label: NSTextField, fill: NSColor, text: NSColor) {
        chip.wantsLayer = true
        chip.layer?.cornerRadius = 5
        chip.layer?.backgroundColor = fill.cgColor
        chip.translatesAutoresizingMaskIntoConstraints = false
        chip.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = text
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.usesSingleLineMode = true
        label.cell?.truncatesLastVisibleLine = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        chip.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -7),
            label.centerYAnchor.constraint(equalTo: chip.centerYAnchor)
        ])
    }
}

@MainActor
private final class TrackingDetailsContentView: NSView {
    weak var owner: DetailsPanel?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        owner?.onMouseEntered?()
    }

    override func mouseExited(with event: NSEvent) {
        owner?.onMouseExited?()
    }
}

@MainActor
private final class QuotaRowView: NSView {
    private let nameField: NSTextField
    private let resetField = NSTextField(labelWithString: "")
    private let valueField = NSTextField(labelWithString: L10n.shared["quota.no_data"])
    private let meter = RoundedMeterView()

    init(title: String) {
        nameField = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(usedPercent: Double, resetAt: Date?) {
        if let resetAt, resetAt <= Date() {
            valueField.stringValue = L10n.shared["quota.waiting_refresh"]
            resetField.stringValue = ""
            resetField.isHidden = true
            meter.value = 0
            return
        }
        let remaining = min(100, max(0, 100 - usedPercent))
        valueField.stringValue = L10n.shared.format("quota.remaining", Int(remaining.rounded()))
        meter.value = remaining
        let resetText = DetailsPanel.formatResetTime(resetAt)
        resetField.stringValue = resetText
        resetField.isHidden = resetText.isEmpty
    }

    func updateUnavailable() {
        valueField.stringValue = L10n.shared["quota.no_data"]
        resetField.stringValue = ""
        resetField.isHidden = true
        meter.value = 0
    }

    func setTitle(_ title: String) {
        nameField.stringValue = title
    }

    var titleForTesting: String {
        nameField.stringValue
    }

    var valueForTesting: String {
        valueField.stringValue
    }

    var resetHiddenForTesting: Bool {
        resetField.isHidden
    }

    var meterFillForTesting: Double {
        meter.value
    }

    var nameFrameForTesting: CGRect {
        nameField.frame
    }

    var resetFrameForTesting: CGRect {
        resetField.frame
    }

    private func setup() {
        nameField.font = .systemFont(ofSize: 12, weight: .regular)
        nameField.textColor = NSColor(calibratedRed: 0.37, green: 0.44, blue: 0.48, alpha: 1)
        nameField.lineBreakMode = .byTruncatingTail
        nameField.setContentCompressionResistancePriority(.required, for: .horizontal)
        nameField.setContentHuggingPriority(.required, for: .horizontal)
        resetField.font = .systemFont(ofSize: 11, weight: .regular)
        // Darker than the old muted gray so "Resets …" remains legible on dark desktops.
        resetField.textColor = NSColor(calibratedRed: 0.40, green: 0.46, blue: 0.50, alpha: 1)
        resetField.lineBreakMode = .byTruncatingTail
        resetField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        valueField.font = .systemFont(ofSize: 12, weight: .semibold)
        valueField.textColor = NSColor(calibratedRed: 0.18, green: 0.24, blue: 0.29, alpha: 1)
        valueField.alignment = .right
        valueField.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        valueField.setContentHuggingPriority(.required, for: .horizontal)

        [nameField, resetField, valueField, meter].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        resetField.isHidden = true
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 33),
            nameField.leadingAnchor.constraint(equalTo: leadingAnchor),
            nameField.topAnchor.constraint(equalTo: topAnchor),
            resetField.leadingAnchor.constraint(equalTo: nameField.trailingAnchor, constant: 7),
            resetField.centerYAnchor.constraint(equalTo: nameField.centerYAnchor),
            resetField.trailingAnchor.constraint(lessThanOrEqualTo: valueField.leadingAnchor, constant: -8),
            valueField.trailingAnchor.constraint(equalTo: trailingAnchor),
            valueField.centerYAnchor.constraint(equalTo: nameField.centerYAnchor),
            meter.leadingAnchor.constraint(equalTo: leadingAnchor),
            meter.trailingAnchor.constraint(equalTo: trailingAnchor),
            meter.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 7),
            meter.heightAnchor.constraint(equalToConstant: 4)
        ])
    }
}

@MainActor
enum QuotaMeterPalette {
    private struct Stop {
        let percent: Double
        let red: Double
        let green: Double
        let blue: Double
    }

    private static let stops = [
        Stop(percent: 0, red: 202, green: 217, blue: 224),
        Stop(percent: 25, red: 168, green: 191, blue: 202),
        Stop(percent: 50, red: 112, green: 148, blue: 169),
        Stop(percent: 75, red: 82, green: 121, blue: 146),
        Stop(percent: 100, red: 64, green: 105, blue: 132),
    ]

    static func fillColor(for remainingPercent: Double) -> NSColor {
        let clamped = min(100, max(0, remainingPercent))
        guard let upperIndex = stops.firstIndex(where: { clamped <= $0.percent }) else {
            return color(for: stops[stops.count - 1])
        }
        guard upperIndex > 0 else {
            return color(for: stops[0])
        }

        let lower = stops[upperIndex - 1]
        let upper = stops[upperIndex]
        let progress = (clamped - lower.percent) / (upper.percent - lower.percent)
        return NSColor(
            deviceRed: component(from: lower.red, to: upper.red, progress: progress),
            green: component(from: lower.green, to: upper.green, progress: progress),
            blue: component(from: lower.blue, to: upper.blue, progress: progress),
            alpha: 1
        )
    }

    private static func color(for stop: Stop) -> NSColor {
        NSColor(
            deviceRed: CGFloat(stop.red) / 255,
            green: CGFloat(stop.green) / 255,
            blue: CGFloat(stop.blue) / 255,
            alpha: 1
        )
    }

    private static func component(from start: Double, to end: Double, progress: Double) -> CGFloat {
        CGFloat(start + (end - start) * progress) / 255
    }
}

@MainActor
final class RoundedMeterView: NSView {
    var value: Double = 0 {
        didSet {
            needsDisplay = true
        }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let bounds = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
        let radius = bounds.height / 2
        NSColor(calibratedRed: 0.72, green: 0.79, blue: 0.84, alpha: 0.30).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()

        let rawFillWidth = bounds.width * min(100, max(0, value)) / 100
        guard rawFillWidth > 0 else {
            return
        }
        let fillWidth = max(bounds.height, rawFillWidth)
        QuotaMeterPalette.fillColor(for: value).setFill()
        NSBezierPath(
            roundedRect: NSRect(x: 0, y: 0, width: fillWidth, height: bounds.height),
            xRadius: radius,
            yRadius: radius
        ).fill()
    }
}

@MainActor
final class AgentToggleView: NSView {
    /// Historical 144pt / 4 default-on agents. Do not divide by `allCases.count`
    /// or adding a fifth kind shrinks every existing slot. The details panel
    /// passes a maximum width only when the full catalog would cover the pill.
    static let slotWidth: CGFloat = 36

    var onAgentSelected: ((AgentKind) -> Void)?

    private(set) var selectedAgent: AgentKind = .codex {
        didSet {
            updateSelectedState(animated: true)
        }
    }

    private var enabledAgents: [AgentKind] = HaloSettings.defaultEnabledAgents
    var enabledAgentsForTesting: [AgentKind] { enabledAgents }
    var toggleWidthForTesting: CGFloat { widthConstraint.constant }

    private let bgView = AgentToggleContentView()
    private let activeBg = NSView()
    private let codexIcon = NSImageView()
    private let claudeIcon = NSImageView()
    private let grokIcon = NSImageView()
    private let piIcon = NSImageView()
    private let antigravityIcon = NSImageView()
    private let openCodeIcon = NSImageView()
    private let workBuddyIcon = NSImageView()
    private var colorIconImages: [AgentKind: NSImage] = [:]
    private var grayIconImages: [AgentKind: NSImage] = [:]
    private var maximumWidth: CGFloat?
    private var activeBgConstraints: [NSLayoutConstraint] = []
    private var iconLayoutConstraints: [NSLayoutConstraint] = []
    private var slotGuides: [NSView] = []
    private var widthConstraint: NSLayoutConstraint!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false

        bgView.wantsLayer = true
        bgView.layer?.cornerRadius = 16
        bgView.layer?.borderWidth = 1
        bgView.layer?.borderColor = NSColor(
            calibratedRed: 221 / 255,
            green: 233 / 255,
            blue: 238 / 255,
            alpha: 1
        ).cgColor
        bgView.layer?.backgroundColor = NSColor(
            calibratedRed: 244 / 255,
            green: 248 / 255,
            blue: 250 / 255,
            alpha: 1
        ).cgColor
        bgView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bgView)

        activeBg.wantsLayer = true
        activeBg.layer?.cornerRadius = 13
        activeBg.layer?.borderWidth = 1
        activeBg.layer?.borderColor = NSColor(
            calibratedRed: 183 / 255,
            green: 235 / 255,
            blue: 246 / 255,
            alpha: 1
        ).cgColor
        activeBg.layer?.backgroundColor = NSColor(
            calibratedRed: 225 / 255,
            green: 249 / 255,
            blue: 255 / 255,
            alpha: 1
        ).cgColor
        activeBg.layer?.shadowColor = NSColor(calibratedRed: 0.26, green: 0.70, blue: 0.80, alpha: 1).cgColor
        activeBg.layer?.shadowOpacity = 0.12
        activeBg.layer?.shadowRadius = 5
        activeBg.layer?.shadowOffset = .zero
        activeBg.translatesAutoresizingMaskIntoConstraints = false
        bgView.addSubview(activeBg)

        configureIcon(codexIcon, assetName: "codex", accessibilityLabel: "Codex")
        configureIcon(claudeIcon, assetName: "claude-code", accessibilityLabel: "Claude Code")
        configureIcon(grokIcon, assetName: "grok", accessibilityLabel: "Grok")
        configureIcon(piIcon, assetName: "pi", accessibilityLabel: "Pi")
        configureIcon(antigravityIcon, assetName: "antigravity", accessibilityLabel: "Antigravity")
        configureIcon(openCodeIcon, assetName: "opencode", accessibilityLabel: "OpenCode")
        configureIcon(workBuddyIcon, assetName: "workbuddy", accessibilityLabel: "WorkBuddy")
        for agent in AgentKind.allCases {
            guard let image = icon(for: agent).image else { continue }
            colorIconImages[agent] = image
            grayIconImages[agent] = AgentIconAssets.grayscale(image)
        }
        bgView.addSubview(codexIcon)
        bgView.addSubview(claudeIcon)
        bgView.addSubview(grokIcon)
        bgView.addSubview(piIcon)
        bgView.addSubview(antigravityIcon)
        bgView.addSubview(openCodeIcon)
        bgView.addSubview(workBuddyIcon)

        widthConstraint = widthAnchor.constraint(
            equalToConstant: Self.slotWidth * CGFloat(HaloSettings.defaultEnabledAgents.count)
        )

        NSLayoutConstraint.activate([
            widthConstraint,
            bgView.leadingAnchor.constraint(equalTo: leadingAnchor),
            bgView.trailingAnchor.constraint(equalTo: trailingAnchor),
            bgView.topAnchor.constraint(equalTo: topAnchor),
            bgView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        applyEnabledAgents(HaloSettings.defaultEnabledAgents, focused: .codex, animated: false)
    }

    func setEnabledAgents(_ agents: [AgentKind], focused: AgentKind, maximumWidth: CGFloat? = nil) {
        self.maximumWidth = maximumWidth
        applyEnabledAgents(agents, focused: focused, animated: true)
    }

    func setAgent(_ agent: AgentKind) {
        guard selectedAgent != agent else { return }
        selectedAgent = agent
    }

    func selectAgentAtXForTesting(_ x: CGFloat) {
        selectAgent(atX: x)
    }

    private func applyEnabledAgents(_ agents: [AgentKind], focused: AgentKind, animated: Bool) {
        var visible = AgentKind.allCases.filter { agents.contains($0) }
        if visible.isEmpty {
            visible = HaloSettings.defaultEnabledAgents
        }
        enabledAgents = visible

        for agent in AgentKind.allCases {
            icon(for: agent).isHidden = !visible.contains(agent)
        }

        rebuildIconLayout(visible: visible)
        let natural = Self.slotWidth * CGFloat(visible.count)
        widthConstraint.constant = maximumWidth.map { min(natural, $0) } ?? natural

        let nextSelected = visible.contains(focused) ? focused : visible[0]
        if selectedAgent != nextSelected {
            selectedAgent = nextSelected
        } else {
            updateSelectedState(animated: animated)
        }
    }

    private func rebuildIconLayout(visible: [AgentKind]) {
        NSLayoutConstraint.deactivate(iconLayoutConstraints)
        iconLayoutConstraints = []
        slotGuides.forEach { $0.removeFromSuperview() }
        slotGuides = []

        guard !visible.isEmpty else { return }

        // Chaining `width = slot - 2` makes each later icon start early. Once the
        // panel compresses the row, that left edge falls in the previous hit slot.
        let fraction = 1.0 / CGFloat(visible.count)
        for (index, agent) in visible.enumerated() {
            let imageView = icon(for: agent)
            let guide = NSView()
            guide.translatesAutoresizingMaskIntoConstraints = false
            bgView.addSubview(guide)
            slotGuides.append(guide)
            iconLayoutConstraints.append(contentsOf: [
                guide.leadingAnchor.constraint(equalTo: bgView.leadingAnchor),
                guide.widthAnchor.constraint(
                    equalTo: bgView.widthAnchor,
                    multiplier: CGFloat(index) * fraction
                ),
                guide.centerYAnchor.constraint(equalTo: bgView.centerYAnchor),
                guide.heightAnchor.constraint(equalToConstant: 0),
                imageView.leadingAnchor.constraint(equalTo: guide.trailingAnchor, constant: 1),
                imageView.centerYAnchor.constraint(equalTo: bgView.centerYAnchor),
                imageView.widthAnchor.constraint(
                    equalTo: bgView.widthAnchor,
                    multiplier: fraction,
                    constant: -2
                ),
                imageView.heightAnchor.constraint(equalToConstant: 18),
            ])
        }

        NSLayoutConstraint.activate(iconLayoutConstraints)
    }

    private func updateSelectedState(animated: Bool) {
        NSLayoutConstraint.deactivate(activeBgConstraints)

        let targetIcon = icon(for: selectedAgent)

        activeBgConstraints = [
            activeBg.leadingAnchor.constraint(equalTo: targetIcon.leadingAnchor),
            activeBg.trailingAnchor.constraint(equalTo: targetIcon.trailingAnchor),
            activeBg.topAnchor.constraint(equalTo: bgView.topAnchor, constant: 3),
            activeBg.bottomAnchor.constraint(equalTo: bgView.bottomAnchor, constant: -3)
        ]

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.allowsImplicitAnimation = true
                NSLayoutConstraint.activate(activeBgConstraints)
                self.layoutSubtreeIfNeeded()
            }
        } else {
            NSLayoutConstraint.activate(activeBgConstraints)
        }

        for agent in AgentKind.allCases {
            let imageView = icon(for: agent)
            let isSelected = agent == selectedAgent
            let grayImage = grayIconImages[agent]
            imageView.image = isSelected ? colorIconImages[agent] : (grayImage ?? colorIconImages[agent])
            let inactiveAlpha: CGFloat = agent == .workbuddy && grayImage != nil ? 1 : 0.40
            imageView.alphaValue = isSelected ? 1 : inactiveAlpha
        }
    }

    private func icon(for agent: AgentKind) -> NSImageView {
        switch agent {
        case .codex: return codexIcon
        case .claudeCode: return claudeIcon
        case .grok: return grokIcon
        case .pi: return piIcon
        case .antigravity: return antigravityIcon
        case .opencode: return openCodeIcon
        case .workbuddy: return workBuddyIcon
        }
    }

    private func configureIcon(_ imageView: NSImageView, assetName: String, accessibilityLabel: String) {
        imageView.image = AgentIconAssets.image(named: assetName)
        imageView.imageScaling = .scaleProportionallyDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.setAccessibilityLabel(accessibilityLabel)
        imageView.setAccessibilityRole(.image)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        selectAgent(atX: point.x)
    }

    private func selectAgent(atX x: CGFloat) {
        guard !enabledAgents.isEmpty else { return }
        let width = bounds.width > 1 ? bounds.width : Self.slotWidth * CGFloat(enabledAgents.count)
        let slot = max(width / CGFloat(enabledAgents.count), 1)
        let index = min(enabledAgents.count - 1, max(0, Int(x / slot)))
        let newAgent = enabledAgents[index]
        if newAgent != selectedAgent {
            selectedAgent = newAgent
            onAgentSelected?(newAgent)
        }
    }
}

@MainActor
private final class AgentToggleContentView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

enum AgentIconAssets {
    static func image(named name: String) -> NSImage? {
        guard let url = url(named: name),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return NSImage(data: data)
    }

    private static func url(named name: String) -> URL? {
        for ext in ["svg", "png"] {
            if let bundled = Bundle.main.url(
                forResource: name,
                withExtension: ext,
                subdirectory: "agent-switch"
            ) {
                return bundled
            }
        }

        let srcRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let repoRoot = srcRoot.deletingLastPathComponent()
        let candidates = [
            srcRoot.appendingPathComponent("shared/assets/agent-switch/\(name).svg"),
            srcRoot.appendingPathComponent("shared/assets/agent-switch/\(name).png"),
            repoRoot.appendingPathComponent("docs/assets/agent-switch/\(name).png"),
            repoRoot.appendingPathComponent("docs/assets/agent-switch/\(name).svg")
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Unselected icons keep their silhouette and transparency, without brand colors.
    @MainActor
    static func grayscale(_ image: NSImage) -> NSImage? {
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        // Rasterize small icons at 2x for Retina, bounded to their UI needs.
        let scale = min(2, 64 / max(image.size.width, image.size.height))
        let width = max(1, Int(ceil(image.size.width * scale)))
        let height = max(1, Int(ceil(image.size.height * scale)))
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bitmapFormat: [], bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap),
           let pixels = bitmap.bitmapData else { return nil }

        let bounds = NSRect(x: 0, y: 0, width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.clear(bounds)
        image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        for y in 0..<height {
            for x in 0..<width {
                let pixel = pixels.advanced(by: y * bitmap.bytesPerRow + x * 4)
                let luminance = 54 * Int(pixel[0]) + 183 * Int(pixel[1]) + 19 * Int(pixel[2])
                let gray = UInt8((luminance + 128) / 256)
                pixel[0] = gray
                pixel[1] = gray
                pixel[2] = gray
            }
        }
        bitmap.size = image.size
        let result = NSImage(size: image.size)
        result.addRepresentation(bitmap)
        return result
    }
}
