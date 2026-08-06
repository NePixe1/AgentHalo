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
    private static let panelWidth: CGFloat = 278
    private static let contextPillWidth: CGFloat = 42
    private static let contextPillHorizontalPadding: CGFloat = 3
    /// Fixed session body slot height (Scheme B). Keep panel fitted height at 172.
    private static let sessionBodyHeight: CGFloat = 72
    private static let apiKeyChipSpacing: CGFloat = 6
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
    private let apiKeyChip = ModeChipView(title: L10n.shared["access.mode.api_key"])
    private let quotaGroup = NSStackView()
    /// Hosts the fixed-height session body slot (empty | session card).
    /// Plain `NSView` (not `NSStackView`) so width is explicit and not ambiguous.
    private let metadataGroup = NSView()
    private let bodySlot = NSView()
    private let emptyBody = EmptySessionBodyView()
    private let sessionCard = SessionCardView()
    private var topRow: NSView?
    private var apiKeyChipWidthConstraint: NSLayoutConstraint?
    private var apiKeyChipContextSpacingConstraint: NSLayoutConstraint?
    private var sessionBodyMode: DetailsPanelSessionBodyRole = .unknown
    /// Last live context percent used to soft-hold the pill after STANDBY.
    private var heldContextPercent: Double?
    /// When the standby hold started/should end; `nil` means not currently holding.
    private var contextHoldExpiresAt: Date?
    private var contextHoldAgent: AgentKind?
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
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 18
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor(calibratedRed: 0.70, green: 0.78, blue: 0.82, alpha: 0.35).cgColor
        // Higher opacity so muted secondary text (e.g. "Resets …") stays readable over dark desktops.
        container.layer?.backgroundColor = NSColor(calibratedRed: 0.98, green: 0.99, blue: 1.0, alpha: 0.96).cgColor
        container.translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 17, bottom: 4, right: 17)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let topRow = makeTopRow()
        self.topRow = topRow
        stack.addArrangedSubview(topRow)
        stack.setCustomSpacing(0, after: topRow)

        titleField.font = .systemFont(ofSize: 22, weight: .bold)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.alignment = .left
        detailField.font = .systemFont(ofSize: 12)
        detailField.textColor = NSColor(calibratedRed: 0.38, green: 0.45, blue: 0.50, alpha: 1)
        detailField.lineBreakMode = .byTruncatingTail
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
        // Bottom inset keeps session body contribution aligned with the 70pt
        // usage group so fitted panel height stays 172 (11 + 72 + 3 == 16 + 70).
        let sessionBodyBottomEqualizer: CGFloat = 3

        bodySlot.translatesAutoresizingMaskIntoConstraints = false
        emptyBody.translatesAutoresizingMaskIntoConstraints = false
        sessionCard.translatesAutoresizingMaskIntoConstraints = false
        // Expand horizontally; never hug label intrinsic width.
        for view in [bodySlot, emptyBody, sessionCard] as [NSView] {
            view.setContentHuggingPriority(.defaultLow, for: .horizontal)
            view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        bodySlot.addSubview(emptyBody)
        bodySlot.addSubview(sessionCard)
        metadataGroup.addSubview(bodySlot)
        metadataGroup.isHidden = true
        stack.addArrangedSubview(metadataGroup)

        emptyBody.isHidden = true
        sessionCard.isHidden = true
        apiKeyChip.isHidden = true

        let rootView = TrackingDetailsContentView()
        rootView.owner = self
        contentView = rootView
        contentView?.addSubview(container)
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            contentView!.widthAnchor.constraint(equalToConstant: Self.panelWidth),
            container.leadingAnchor.constraint(equalTo: contentView!.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: contentView!.trailingAnchor),
            container.topAnchor.constraint(equalTo: contentView!.topAnchor),
            container.bottomAnchor.constraint(equalTo: contentView!.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            topRow.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -17),
            titleField.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -17),
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
            setAPIKeyChipVisible(false)
            sessionBodyMode = .unknown
            renderUsage(usage)
            quotaGroup.isHidden = false
        case .session(let session):
            stack.setCustomSpacing(11, after: detailField)
            stack.edgeInsets.bottom = 4
            setAPIKeyChipVisible(true)
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
            sessionCard.setTokens(Self.formatTokenAttributedString(input: nil, output: nil))
            return
        }

        emptyBody.isHidden = true
        sessionCard.isHidden = false
        sessionBodyMode = .sessionCard
        sessionCard.setTitle(Self.displayValue(session.sessionTitle), toolTip: session.sessionTitle)
        sessionCard.setModel(Self.displayValue(session.modelName))
        if session.inputTokens != nil || session.outputTokens != nil {
            sessionCard.setTokens(Self.formatTokenAttributedString(
                input: session.inputTokens,
                output: session.outputTokens
            ))
        } else {
            sessionCard.setTokens(Self.formatTokenAttributedString(input: nil, output: nil))
        }
    }

    /// Card is only worth showing when at least one field the card paints has data.
    /// `projectName` alone does not count — the card never surfaces it.
    static func hasSessionCardContent(_ session: SessionDetailsSnapshot) -> Bool {
        if let title = session.sessionTitle, !title.isEmpty {
            return true
        }
        if let model = session.modelName, !model.isEmpty {
            return true
        }
        return session.inputTokens != nil || session.outputTokens != nil
    }

    private func setAPIKeyChipVisible(_ visible: Bool) {
        apiKeyChip.isHidden = !visible
        // Collapse width + spacing so the context pill can hug the trailing edge on OAuth.
        apiKeyChipWidthConstraint?.isActive = false
        if visible {
            apiKeyChipWidthConstraint = apiKeyChip.widthAnchor.constraint(
                equalToConstant: apiKeyChip.preferredWidth
            )
            apiKeyChipContextSpacingConstraint?.constant = Self.apiKeyChipSpacing
        } else {
            apiKeyChipWidthConstraint = apiKeyChip.widthAnchor.constraint(equalToConstant: 0)
            apiKeyChipContextSpacingConstraint?.constant = 0
        }
        apiKeyChipWidthConstraint?.isActive = true
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
        case .grok, .claudeCode:
            // Grok/Claude context is disk- or statusline-backed on full content
            // refresh. Only STANDBY/OFFLINE status ticks should touch the pill:
            // STANDBY soft-holds the last live percent; OFFLINE clears immediately.
            // Active labels leave existing metadata alone (status-only path must
            // not wipe context when sessions briefly look empty).
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

    static func formatTokenAttributedString(input: Int64?, output: Int64?) -> NSAttributedString {
        let inputStr = compactTokenCount(input)
        let outputStr = compactTokenCount(output)
        
        let font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        // 莫兰迪蓝灰色：输入 (In)
        let inColor = NSColor(calibratedRed: 0.25, green: 0.45, blue: 0.65, alpha: 1)
        // 莫兰迪绿灰色：输出 (Out)
        let outColor = NSColor(calibratedRed: 0.25, green: 0.55, blue: 0.45, alpha: 1)
        // 中间分隔点颜色
        let sepColor = NSColor.secondaryLabelColor
        
        let attrStr = NSMutableAttributedString()
        
        attrStr.append(NSAttributedString(string: "↑ \(inputStr)", attributes: [
            .font: font,
            .foregroundColor: inColor
        ]))
        
        attrStr.append(NSAttributedString(string: "  ·  ", attributes: [
            .font: font,
            .foregroundColor: sepColor
        ]))
        
        attrStr.append(NSAttributedString(string: "↓ \(outputStr)", attributes: [
            .font: font,
            .foregroundColor: outColor
        ]))
        
        return attrStr
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
        case .error: return aggregate.detail.isEmpty ? L10n.shared["status.error"] : aggregate.detail
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
        contextPill.layer?.cornerRadius = 9
        contextPill.layer?.backgroundColor = NSColor(calibratedRed: 0.88, green: 0.95, blue: 0.99, alpha: 0.80).cgColor
        contextPill.layer?.borderWidth = 1
        contextPill.layer?.borderColor = NSColor(calibratedRed: 0.62, green: 0.78, blue: 0.88, alpha: 0.42).cgColor
        contextPill.translatesAutoresizingMaskIntoConstraints = false

        contextValue.font = .systemFont(ofSize: 11, weight: .regular)
        contextValue.textColor = NSColor(calibratedRed: 0.22, green: 0.49, blue: 0.57, alpha: 1)
        contextValue.alignment = .center
        contextValue.lineBreakMode = .byTruncatingTail
        contextValue.translatesAutoresizingMaskIntoConstraints = false

        apiKeyChip.translatesAutoresizingMaskIntoConstraints = false
        apiKeyChip.isHidden = true

        row.addSubview(agentToggle)
        row.addSubview(contextPill)
        row.addSubview(apiKeyChip)
        contextPill.addSubview(contextValue)

        let chipWidth = apiKeyChip.widthAnchor.constraint(equalToConstant: 0)
        apiKeyChipWidthConstraint = chipWidth
        // Spacing between context pill trailing edge and chip leading edge.
        let chipSpacing = apiKeyChip.leadingAnchor.constraint(
            equalTo: contextPill.trailingAnchor,
            constant: 0
        )
        apiKeyChipContextSpacingConstraint = chipSpacing

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 24),
            agentToggle.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            agentToggle.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            agentToggle.widthAnchor.constraint(equalToConstant: 108),
            agentToggle.heightAnchor.constraint(equalToConstant: 24),
            // Right-to-left: [context][gap][API Key chip]
            apiKeyChip.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            apiKeyChip.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            apiKeyChip.heightAnchor.constraint(equalToConstant: 22),
            chipWidth,
            chipSpacing,
            contextPill.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            contextPill.widthAnchor.constraint(equalToConstant: Self.contextPillWidth),
            contextPill.leadingAnchor.constraint(greaterThanOrEqualTo: agentToggle.trailingAnchor, constant: 10),
            contextValue.leadingAnchor.constraint(equalTo: contextPill.leadingAnchor, constant: Self.contextPillHorizontalPadding),
            contextValue.trailingAnchor.constraint(equalTo: contextPill.trailingAnchor, constant: -Self.contextPillHorizontalPadding),
            contextValue.topAnchor.constraint(equalTo: contextPill.topAnchor, constant: 3),
            contextValue.bottomAnchor.constraint(equalTo: contextPill.bottomAnchor, constant: -3)
        ])
        return row
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

    // MARK: - Scheme B session body / mode-chip accessors

    var apiKeyChipHiddenForTesting: Bool { apiKeyChip.isHidden }

    var apiKeyChipTitleForTesting: String { apiKeyChip.titleText }

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

/// Top-row access-mode pill: light cyan fill + leading status dot.
@MainActor
private final class ModeChipView: NSView {
    private let dot = NSView()
    private let label: NSTextField

    var titleText: String { label.stringValue }

    var preferredWidth: CGFloat {
        let textWidth = ceil(label.intrinsicContentSize.width)
        // leading 8 + dot 6 + gap 5 + text + trailing 8
        return 8 + 6 + 5 + textWidth + 8
    }

    init(title: String) {
        label = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.backgroundColor = NSColor(calibratedRed: 52 / 255, green: 158 / 255, blue: 199 / 255, alpha: 0.10).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(calibratedRed: 52 / 255, green: 158 / 255, blue: 199 / 255, alpha: 0.22).cgColor

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        dot.layer?.backgroundColor = NSColor(calibratedRed: 42 / 255, green: 111 / 255, blue: 143 / 255, alpha: 0.75).cgColor
        dot.translatesAutoresizingMaskIntoConstraints = false

        label.font = .systemFont(ofSize: 10.5, weight: .semibold)
        label.textColor = NSColor(calibratedRed: 42 / 255, green: 111 / 255, blue: 143 / 255, alpha: 1)
        label.lineBreakMode = .byClipping
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false

        addSubview(dot)
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 22),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// Offline empty rectangle: dashed border + centered copy.
@MainActor
private final class EmptySessionBodyView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let dashLayer = CAShapeLayer()

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
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.45).cgColor

        dashLayer.fillColor = nil
        dashLayer.strokeColor = NSColor(calibratedRed: 130 / 255, green: 150 / 255, blue: 165 / 255, alpha: 0.28).cgColor
        dashLayer.lineWidth = 1
        dashLayer.lineDashPattern = [4, 3]
        dashLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        layer?.addSublayer(dashLayer)

        label.font = .systemFont(ofSize: 12, weight: .regular)
        label.textColor = NSColor(calibratedRed: 109 / 255, green: 129 / 255, blue: 144 / 255, alpha: 1)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setText(_ text: String) {
        label.stringValue = text
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // Keep dash stroke in view coordinates (frame = bounds origin 0).
        dashLayer.frame = bounds
        dashLayer.contentsScale = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
        let path = CGPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            cornerWidth: 12,
            cornerHeight: 12,
            transform: nil
        )
        dashLayer.path = path
    }
}

/// Online session summary card: title + model chip + token counts.
@MainActor
private final class SessionCardView: NSView {
    private let titleLabel = NSTextField(labelWithString: "--")
    private let modelChip = NSView()
    private let modelLabel = NSTextField(labelWithString: "--")
    private let tokenLabel = NSTextField(labelWithString: "↑ --  ·  ↓ --")

    var titleText: String { titleLabel.stringValue }
    var modelText: String { modelLabel.stringValue }
    var tokensText: String { tokenLabel.stringValue }
    var titleToolTipText: String? { titleLabel.toolTip }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.62).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(calibratedRed: 140 / 255, green: 160 / 255, blue: 175 / 255, alpha: 0.18).cgColor
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = NSColor(calibratedRed: 30 / 255, green: 44 / 255, blue: 54 / 255, alpha: 1)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.usesSingleLineMode = true
        titleLabel.cell?.truncatesLastVisibleLine = true
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        modelChip.wantsLayer = true
        modelChip.layer?.cornerRadius = 6
        modelChip.layer?.backgroundColor = NSColor.textColor.withAlphaComponent(0.06).cgColor
        modelChip.layer?.borderWidth = 0.5
        modelChip.layer?.borderColor = NSColor.textColor.withAlphaComponent(0.08).cgColor
        modelChip.translatesAutoresizingMaskIntoConstraints = false
        modelChip.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        modelChip.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        modelLabel.font = .systemFont(ofSize: 11, weight: .medium)
        modelLabel.textColor = NSColor(calibratedRed: 0.30, green: 0.38, blue: 0.44, alpha: 1)
        modelLabel.lineBreakMode = .byTruncatingTail
        modelLabel.maximumNumberOfLines = 1
        modelLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        modelLabel.translatesAutoresizingMaskIntoConstraints = false

        tokenLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        tokenLabel.alignment = .right
        tokenLabel.lineBreakMode = .byTruncatingTail
        tokenLabel.maximumNumberOfLines = 1
        tokenLabel.setContentHuggingPriority(.required, for: .horizontal)
        tokenLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        tokenLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleLabel)
        addSubview(modelChip)
        modelChip.addSubview(modelLabel)
        addSubview(tokenLabel)

        // Content vertically centered inside the fixed 72pt body slot.
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -11),

            modelChip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            modelChip.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            modelChip.heightAnchor.constraint(equalToConstant: 20),
            modelChip.trailingAnchor.constraint(lessThanOrEqualTo: tokenLabel.leadingAnchor, constant: -8),

            modelLabel.leadingAnchor.constraint(equalTo: modelChip.leadingAnchor, constant: 7),
            modelLabel.trailingAnchor.constraint(equalTo: modelChip.trailingAnchor, constant: -7),
            modelLabel.centerYAnchor.constraint(equalTo: modelChip.centerYAnchor),

            tokenLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            tokenLabel.centerYAnchor.constraint(equalTo: modelChip.centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setTitle(_ title: String, toolTip: String?) {
        titleLabel.stringValue = title
        // Only expose a tooltip when a real title exists.
        if let toolTip, !toolTip.isEmpty {
            titleLabel.toolTip = toolTip
        } else {
            titleLabel.toolTip = nil
        }
    }

    func setModel(_ model: String) {
        modelLabel.stringValue = model
    }

    func setTokens(_ tokens: NSAttributedString) {
        tokenLabel.attributedStringValue = tokens
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
    var onAgentSelected: ((AgentKind) -> Void)?

    private(set) var selectedAgent: AgentKind = .codex {
        didSet {
            updateSelectedState(animated: true)
        }
    }

    private let bgView = AgentToggleContentView()
    private let activeBg = NSView()
    private let codexIcon = NSImageView()
    private let claudeIcon = NSImageView()
    private let grokIcon = NSImageView()
    private var activeBgConstraints: [NSLayoutConstraint] = []

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
        bgView.layer?.cornerRadius = 12
        bgView.layer?.borderWidth = 1
        bgView.layer?.borderColor = NSColor(calibratedRed: 0.88, green: 0.88, blue: 0.88, alpha: 0.7).cgColor
        bgView.layer?.backgroundColor = NSColor(calibratedRed: 0.96, green: 0.96, blue: 0.96, alpha: 0.7).cgColor
        bgView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bgView)

        activeBg.wantsLayer = true
        activeBg.layer?.cornerRadius = 10
        activeBg.layer?.borderWidth = 1
        activeBg.layer?.borderColor = NSColor(calibratedRed: 0.72, green: 0.92, blue: 0.97, alpha: 0.85).cgColor
        activeBg.layer?.backgroundColor = NSColor(calibratedRed: 0.88, green: 0.97, blue: 1.0, alpha: 1.0).cgColor
        activeBg.layer?.shadowColor = NSColor(calibratedRed: 0.26, green: 0.70, blue: 0.80, alpha: 1).cgColor
        activeBg.layer?.shadowOpacity = 0.12
        activeBg.layer?.shadowRadius = 5
        activeBg.layer?.shadowOffset = .zero
        activeBg.translatesAutoresizingMaskIntoConstraints = false
        bgView.addSubview(activeBg)

        configureIcon(codexIcon, assetName: "codex", accessibilityLabel: "Codex")
        configureIcon(claudeIcon, assetName: "claude-code", accessibilityLabel: "Claude Code")
        configureIcon(grokIcon, assetName: "grok", accessibilityLabel: "Grok")
        bgView.addSubview(codexIcon)
        bgView.addSubview(claudeIcon)
        bgView.addSubview(grokIcon)

        NSLayoutConstraint.activate([
            bgView.leadingAnchor.constraint(equalTo: leadingAnchor),
            bgView.trailingAnchor.constraint(equalTo: trailingAnchor),
            bgView.topAnchor.constraint(equalTo: topAnchor),
            bgView.bottomAnchor.constraint(equalTo: bottomAnchor),

            codexIcon.leadingAnchor.constraint(equalTo: bgView.leadingAnchor, constant: 3),
            codexIcon.centerYAnchor.constraint(equalTo: bgView.centerYAnchor),
            codexIcon.widthAnchor.constraint(equalTo: bgView.widthAnchor, multiplier: 1.0 / 3.0, constant: -2),
            codexIcon.heightAnchor.constraint(equalToConstant: 18),

            claudeIcon.centerXAnchor.constraint(equalTo: bgView.centerXAnchor),
            claudeIcon.centerYAnchor.constraint(equalTo: bgView.centerYAnchor),
            claudeIcon.widthAnchor.constraint(equalTo: bgView.widthAnchor, multiplier: 1.0 / 3.0, constant: -2),
            claudeIcon.heightAnchor.constraint(equalToConstant: 18),

            grokIcon.trailingAnchor.constraint(equalTo: bgView.trailingAnchor, constant: -3),
            grokIcon.centerYAnchor.constraint(equalTo: bgView.centerYAnchor),
            grokIcon.widthAnchor.constraint(equalTo: bgView.widthAnchor, multiplier: 1.0 / 3.0, constant: -2),
            grokIcon.heightAnchor.constraint(equalToConstant: 18),
        ])

        updateSelectedState(animated: false)
    }

    func setAgent(_ agent: AgentKind) {
        guard selectedAgent != agent else { return }
        selectedAgent = agent
    }

    func selectAgentAtXForTesting(_ x: CGFloat) {
        selectAgent(atX: x)
    }

    private func updateSelectedState(animated: Bool) {
        NSLayoutConstraint.deactivate(activeBgConstraints)

        let targetIcon = icon(for: selectedAgent)

        activeBgConstraints = [
            activeBg.leadingAnchor.constraint(equalTo: targetIcon.leadingAnchor),
            activeBg.trailingAnchor.constraint(equalTo: targetIcon.trailingAnchor),
            activeBg.topAnchor.constraint(equalTo: bgView.topAnchor, constant: 2),
            activeBg.bottomAnchor.constraint(equalTo: bgView.bottomAnchor, constant: -2)
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

        codexIcon.alphaValue = selectedAgent == .codex ? 1 : 0.40
        claudeIcon.alphaValue = selectedAgent == .claudeCode ? 1 : 0.40
        grokIcon.alphaValue = selectedAgent == .grok ? 1 : 0.40
    }

    private func icon(for agent: AgentKind) -> NSImageView {
        switch agent {
        case .codex: return codexIcon
        case .claudeCode: return claudeIcon
        case .grok: return grokIcon
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
        let third = bounds.width / 3
        let newAgent: AgentKind
        if x < third {
            newAgent = .codex
        } else if x < third * 2 {
            newAgent = .claudeCode
        } else {
            newAgent = .grok
        }
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

private enum AgentIconAssets {
    static func image(named name: String) -> NSImage? {
        guard let url = url(named: name),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return NSImage(data: data)
    }

    private static func url(named name: String) -> URL? {
        if let bundled = Bundle.main.url(
            forResource: name,
            withExtension: "svg",
            subdirectory: "agent-switch"
        ) {
            return bundled
        }

        let srcRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceAsset = srcRoot
            .appendingPathComponent("shared/assets/agent-switch", isDirectory: true)
            .appendingPathComponent("\(name).svg")
        return FileManager.default.fileExists(atPath: sourceAsset.path) ? sourceAsset : nil
    }
}
