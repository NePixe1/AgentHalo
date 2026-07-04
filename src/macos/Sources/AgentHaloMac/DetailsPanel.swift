import AppKit
import AgentHaloCore

@MainActor
final class DetailsPanel: NSPanel {
    private static let contextPillWidth: CGFloat = 47

    private let stack = NSStackView()
    private let contextValue = NSTextField(labelWithString: L10n.shared["context.empty"])
    private let titleField = NSTextField(labelWithString: "OFFLINE")
    private let detailField = NSTextField(labelWithString: L10n.shared["status.offline_codex"])
    private let primaryQuota = QuotaRowView(title: L10n.shared["quota.5h"])
    private let secondaryQuota = QuotaRowView(title: L10n.shared["quota.weekly"])
    private let agentToggle = AgentToggleView()
    private let contextPill = NSView()
    private let quotaGroup = NSStackView()
    private let metadataGroup = NSStackView()
    private let projectRow = MetadataRowView(
        title: L10n.shared["metadata.project"]
    )
    private let modelRow = MetadataRowView(
        title: L10n.shared["metadata.model"]
    )
    private let projectModelSeparator = SeparatorView()
    private let modelTokenSeparator = SeparatorView()
    private let tokenRow = MetadataRowView(
        title: L10n.shared["metadata.tokens"],
        valueFont: .systemFont(ofSize: 11.5, weight: .medium)
    )
    var onMouseEntered: (() -> Void)?
    var onMouseExited: (() -> Void)?
    var onAgentSelected: ((AgentKind) -> Void)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 268, height: 192),
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

        let container = NSVisualEffectView(frame: contentView?.bounds ?? .zero)
        container.material = .popover
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 18
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor(calibratedRed: 0.70, green: 0.78, blue: 0.82, alpha: 0.35).cgColor
        container.layer?.backgroundColor = NSColor(calibratedRed: 0.98, green: 0.99, blue: 1.0, alpha: 0.90).cgColor
        container.translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 17, bottom: 4, right: 17)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let topRow = makeTopRow()
        stack.addArrangedSubview(topRow)
        stack.setCustomSpacing(7, after: topRow)

        titleField.font = .systemFont(ofSize: 24, weight: .bold)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.alignment = .left
        detailField.font = .systemFont(ofSize: 13)
        detailField.textColor = NSColor(calibratedRed: 0.38, green: 0.45, blue: 0.50, alpha: 1)
        detailField.lineBreakMode = .byTruncatingTail
        detailField.alignment = .left
        stack.addArrangedSubview(titleField)
        stack.setCustomSpacing(2, after: titleField)
        stack.addArrangedSubview(detailField)
        stack.setCustomSpacing(13, after: detailField)

        quotaGroup.orientation = .vertical
        quotaGroup.spacing = 8
        quotaGroup.alignment = .leading
        quotaGroup.translatesAutoresizingMaskIntoConstraints = false
        quotaGroup.addArrangedSubview(primaryQuota)
        quotaGroup.addArrangedSubview(secondaryQuota)
        stack.addArrangedSubview(quotaGroup)

        metadataGroup.orientation = .vertical
        metadataGroup.spacing = 0
        metadataGroup.alignment = .width
        metadataGroup.translatesAutoresizingMaskIntoConstraints = false
        
        metadataGroup.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 0, right: 0)
        metadataGroup.addArrangedSubview(projectRow)
        metadataGroup.addArrangedSubview(projectModelSeparator)
        metadataGroup.addArrangedSubview(modelRow)
        metadataGroup.addArrangedSubview(modelTokenSeparator)
        metadataGroup.addArrangedSubview(tokenRow)
        metadataGroup.isHidden = true
        stack.addArrangedSubview(metadataGroup)

        let rootView = TrackingDetailsContentView()
        rootView.owner = self
        contentView = rootView
        contentView?.addSubview(container)
        container.addSubview(stack)
        NSLayoutConstraint.activate([
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
            quotaGroup.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -17),
            primaryQuota.trailingAnchor.constraint(equalTo: quotaGroup.trailingAnchor),
            secondaryQuota.trailingAnchor.constraint(equalTo: quotaGroup.trailingAnchor),
            metadataGroup.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 17),
            metadataGroup.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -17)
        ])
    }

    func update(
        aggregate: AggregateSnapshot,
        quota: RateLimitSnapshot?,
        contextUsedPercent: Double?,
        sessionDetails: SessionDetailsSnapshot? = nil,
        showsQuota: Bool? = nil
    ) {
        #if DEBUG
        let startTime = CFAbsoluteTimeGetCurrent()
        defer {
            let duration = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            if duration > 16.67 {
                NSLog("[Performance] DetailsPanel.update took %.2fms (>1 frame)", duration)
            }
        }
        #endif

        updateStatus(aggregate: aggregate)

        // OFFLINE: no live session — drop any stale context-usage pill and
        // reset metadata rows to the placeholder so the panel doesn't show
        // numbers from a prior session.
        let isOffline = aggregate.state == .idle && aggregate.label == "OFFLINE"

        let showsCodexQuota = showsQuota ?? (aggregate.focusedAgent == .codex)
        stack.setCustomSpacing(showsCodexQuota ? Self.plusQuotaTopSpacing : 4, after: detailField)
        contextPill.isHidden = isOffline || contextUsedPercent == nil
        contextValue.stringValue = contextUsedPercent.map {
            Self.compactContextPercent($0)
        } ?? L10n.shared["context.empty"]
        // Hide both groups first to avoid a transient state where both
        // are visible at the same time, which spikes the stack height
        // and makes the panel visually "grow" for a frame.
        quotaGroup.isHidden = true
        metadataGroup.isHidden = true
        // Now reveal only the relevant group
        quotaGroup.isHidden = !showsCodexQuota
        primaryQuota.isHidden = !showsCodexQuota
        secondaryQuota.isHidden = !showsCodexQuota
        metadataGroup.isHidden = showsCodexQuota
        projectRow.setTitle(L10n.shared["metadata.project"])
        modelRow.setTitle(L10n.shared["metadata.model"])
        tokenRow.setTitle(L10n.shared["metadata.tokens"])
        if isOffline {
            projectRow.value = "--"
            modelRow.value = "--"
            tokenRow.value = "--"
        } else {
            projectRow.value = Self.displayValue(sessionDetails?.sessionTitle ?? sessionDetails?.projectName)
            modelRow.value = Self.displayValue(sessionDetails?.modelName)
            if sessionDetails?.inputTokens != nil || sessionDetails?.outputTokens != nil {
                tokenRow.attributedStringValue = Self.formatTokenAttributedString(
                    input: sessionDetails?.inputTokens,
                    output: sessionDetails?.outputTokens
                )
            } else {
                tokenRow.value = "--"
            }
        }

        guard showsCodexQuota else {
            primaryQuota.updateUnavailable()
            secondaryQuota.updateUnavailable()
            return
        }

        applyQuotaLayout(quota, contextUsedPercent: contextUsedPercent)
    }

    /// Mirrors the Windows `ApplyQuotaMetrics` switch: Plus accounts get the
    /// 5h + week pair, monthly plans collapse to a single "月额度" row, and a
    /// monthly account that hasn't surfaced a snapshot yet shows the pending
    /// placeholder so the panel doesn't look empty while Codex is starting up.
    private func applyQuotaLayout(_ quota: RateLimitSnapshot?, contextUsedPercent: Double?) {
        if let quota, quota.hasMonthly {
            applyMonthlyQuota(quota, hasMonthlyData: true)
            return
        }
        if let quota, quota.hasPrimary, quota.hasSecondary {
            applyPlusQuota(quota)
            return
        }
        if let quota, quota.hasMonthlyPlan {
            applyMonthlyQuota(quota, hasMonthlyData: quota.hasMonthly)
            return
        }
        // Context-only: we know there's a session but haven't seen rate limits
        // yet. Show a monthly placeholder rather than wiping the panel.
        if contextUsedPercent != nil {
            applyMonthlyQuota(quota, hasMonthlyData: false)
            return
        }
        applyPlusQuota(nil)
    }

    private func applyPlusQuota(_ quota: RateLimitSnapshot?) {
        setQuotaTopSpacing(Self.plusQuotaTopSpacing)
        primaryQuota.setTitle(L10n.shared["quota.5h"])
        secondaryQuota.setTitle(L10n.shared["quota.weekly"])
        primaryQuota.isHidden = false
        secondaryQuota.isHidden = false
        if let quota {
            primaryQuota.update(
                usedPercent: quota.primaryUsedPercent,
                resetAt: quota.primaryResetAt
            )
            secondaryQuota.update(
                usedPercent: quota.secondaryUsedPercent,
                resetAt: quota.secondaryResetAt
            )
        } else {
            primaryQuota.updateUnavailable()
            secondaryQuota.updateUnavailable()
        }
    }

    private func applyMonthlyQuota(_ quota: RateLimitSnapshot?, hasMonthlyData: Bool) {
        setQuotaTopSpacing(Self.monthlyQuotaTopSpacing)
        primaryQuota.setTitle(L10n.shared["quota.monthly"])
        primaryQuota.isHidden = false
        secondaryQuota.isHidden = true
        if hasMonthlyData, let quota, let used = quota.monthlyUsedPercent {
            primaryQuota.update(usedPercent: used, resetAt: quota.monthlyResetAt)
        } else {
            primaryQuota.updatePending()
        }
        secondaryQuota.updateUnavailable()
    }

    private func setQuotaTopSpacing(_ spacing: CGFloat) {
        stack.setCustomSpacing(spacing, after: detailField)
    }

    func updateStatus(aggregate: AggregateSnapshot) {
        titleField.stringValue = aggregate.label
        let rgb = HaloVisualModel.stateColor(aggregate.state)
        titleField.textColor = NSColor(calibratedRed: rgb.red / 255, green: rgb.green / 255, blue: rgb.blue / 255, alpha: 1)
        detailField.stringValue = Self.localizedDetail(for: aggregate)
        agentToggle.setAgent(aggregate.focusedAgent)
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
        return formatter.string(from: date)
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

        row.addSubview(agentToggle)
        row.addSubview(contextPill)
        contextPill.addSubview(contextValue)
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 24),
            agentToggle.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            agentToggle.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            agentToggle.widthAnchor.constraint(equalToConstant: 76),
            agentToggle.heightAnchor.constraint(equalToConstant: 24),
            contextPill.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            contextPill.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            contextPill.widthAnchor.constraint(equalToConstant: Self.contextPillWidth),
            contextPill.leadingAnchor.constraint(greaterThanOrEqualTo: agentToggle.trailingAnchor, constant: 10),
            contextValue.leadingAnchor.constraint(equalTo: contextPill.leadingAnchor, constant: 9),
            contextValue.trailingAnchor.constraint(equalTo: contextPill.trailingAnchor, constant: -9),
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

    var primaryQuotaHiddenForTesting: Bool {
        primaryQuota.isHidden || quotaGroup.isHidden
    }

    var secondaryQuotaHiddenForTesting: Bool {
        secondaryQuota.isHidden || quotaGroup.isHidden
    }

    var primaryQuotaValueForTesting: String {
        primaryQuota.valueForTesting
    }

    var secondaryQuotaValueForTesting: String {
        secondaryQuota.valueForTesting
    }

    var quotaTopSpacingForTesting: CGFloat {
        stack.customSpacing(after: detailField)
    }

    var metadataGroupHiddenForTesting: Bool {
        metadataGroup.isHidden
    }

    var projectValueForTesting: String {
        projectRow.value
    }

    var modelValueForTesting: String {
        modelRow.value
    }

    var tokenValueForTesting: String {
        tokenRow.value
    }

    func selectAgentForTesting(_ agent: AgentKind) {
        agentToggle.setAgent(agent)
        onAgentSelected?(agent)
    }
}

private extension DetailsPanel {
    static let plusQuotaTopSpacing: CGFloat = 13
    static let monthlyQuotaTopSpacing: CGFloat = 22
}

@MainActor
private final class SeparatorView: NSView {
    private let line = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 1).isActive = true

        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.textColor.withAlphaComponent(0.06).cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)

        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 0),
            line.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 0),
            line.topAnchor.constraint(equalTo: topAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

@MainActor
private final class MetadataRowView: NSView {
    private let nameField: NSTextField
    private let valueField = NSTextField(labelWithString: "--")
    private let valueBackground = NSView()

    var value: String {
        get { valueField.stringValue }
        set { valueField.stringValue = newValue }
    }

    var attributedStringValue: NSAttributedString {
        get { valueField.attributedStringValue }
        set { valueField.attributedStringValue = newValue }
    }

    func setTitle(_ title: String) {
        nameField.stringValue = title
    }

    init(title: String, isTagStyle: Bool = false, valueFont: NSFont = .systemFont(ofSize: 12, weight: .semibold)) {
        nameField = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        nameField.font = .systemFont(ofSize: 11.5)
        nameField.textColor = .secondaryLabelColor
        nameField.translatesAutoresizingMaskIntoConstraints = false
        
        valueField.font = valueFont
        valueField.textColor = .labelColor
        valueField.alignment = .right
        valueField.lineBreakMode = .byTruncatingTail
        valueField.maximumNumberOfLines = 1
        valueField.translatesAutoresizingMaskIntoConstraints = false

        valueBackground.translatesAutoresizingMaskIntoConstraints = false
        if isTagStyle {
            valueBackground.wantsLayer = true
            valueBackground.layer?.cornerRadius = 5
            valueBackground.layer?.backgroundColor = NSColor.textColor.withAlphaComponent(0.06).cgColor
            valueBackground.layer?.borderWidth = 0.5
            valueBackground.layer?.borderColor = NSColor.textColor.withAlphaComponent(0.08).cgColor
        }

        addSubview(nameField)
        addSubview(valueBackground)
        valueBackground.addSubview(valueField)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),

            nameField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 0),
            nameField.centerYAnchor.constraint(equalTo: centerYAnchor),

            valueBackground.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 0),
            valueBackground.centerYAnchor.constraint(equalTo: centerYAnchor),
            valueBackground.leadingAnchor.constraint(greaterThanOrEqualTo: nameField.trailingAnchor, constant: 10),

            valueField.leadingAnchor.constraint(equalTo: valueBackground.leadingAnchor, constant: isTagStyle ? 6 : 0),
            valueField.trailingAnchor.constraint(equalTo: valueBackground.trailingAnchor, constant: isTagStyle ? -6 : 0),
            valueField.topAnchor.constraint(equalTo: valueBackground.topAnchor, constant: isTagStyle ? 2 : 0),
            valueField.bottomAnchor.constraint(equalTo: valueBackground.bottomAnchor, constant: isTagStyle ? -2 : 0),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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

    /// Placeholder for the monthly bucket when we know the plan is monthly
    /// but Codex hasn't surfaced a rate-limit snapshot yet. Mirrors the
    /// Windows "等待 Codex 刷新" pending row.
    func updatePending() {
        valueField.stringValue = L10n.shared["quota.waiting_refresh"]
        resetField.stringValue = ""
        resetField.isHidden = true
        meter.value = 0
    }

    func setTitle(_ title: String) {
        nameField.stringValue = title
    }

    var valueForTesting: String {
        valueField.stringValue
    }

    private func setup() {
        nameField.font = .systemFont(ofSize: 12, weight: .regular)
        nameField.textColor = NSColor(calibratedRed: 0.37, green: 0.44, blue: 0.48, alpha: 1)
        nameField.lineBreakMode = .byTruncatingTail
        nameField.setContentCompressionResistancePriority(.required, for: .horizontal)
        nameField.setContentHuggingPriority(.required, for: .horizontal)
        resetField.font = .systemFont(ofSize: 11, weight: .regular)
        resetField.textColor = NSColor(calibratedRed: 0.49, green: 0.56, blue: 0.60, alpha: 1)
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
            heightAnchor.constraint(equalToConstant: 34),
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
private final class RoundedMeterView: NSView {
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
        NSColor(calibratedRed: 0.29, green: 0.68, blue: 0.79, alpha: 1).setFill()
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
        bgView.addSubview(codexIcon)
        bgView.addSubview(claudeIcon)

        NSLayoutConstraint.activate([
            bgView.leadingAnchor.constraint(equalTo: leadingAnchor),
            bgView.trailingAnchor.constraint(equalTo: trailingAnchor),
            bgView.topAnchor.constraint(equalTo: topAnchor),
            bgView.bottomAnchor.constraint(equalTo: bottomAnchor),

            codexIcon.leadingAnchor.constraint(equalTo: bgView.leadingAnchor, constant: 4),
            codexIcon.centerYAnchor.constraint(equalTo: bgView.centerYAnchor),
            codexIcon.widthAnchor.constraint(equalTo: bgView.widthAnchor, multiplier: 0.5, constant: -4),
            codexIcon.heightAnchor.constraint(equalToConstant: 18),

            claudeIcon.trailingAnchor.constraint(equalTo: bgView.trailingAnchor, constant: -4),
            claudeIcon.centerYAnchor.constraint(equalTo: bgView.centerYAnchor),
            claudeIcon.widthAnchor.constraint(equalTo: bgView.widthAnchor, multiplier: 0.5, constant: -4),
            claudeIcon.heightAnchor.constraint(equalToConstant: 18),
        ])

        updateSelectedState(animated: false)
    }

    func setAgent(_ agent: AgentKind) {
        guard selectedAgent != agent else { return }
        selectedAgent = agent
    }

    private func updateSelectedState(animated: Bool) {
        NSLayoutConstraint.deactivate(activeBgConstraints)

        let targetIcon = selectedAgent == .codex ? codexIcon : claudeIcon

        activeBgConstraints = [
            activeBg.leadingAnchor.constraint(equalTo: targetIcon.leadingAnchor, constant: -2),
            activeBg.trailingAnchor.constraint(equalTo: targetIcon.trailingAnchor, constant: 2),
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

        codexIcon.alphaValue = selectedAgent == .codex ? 1 : 0.58
        claudeIcon.alphaValue = selectedAgent == .claudeCode ? 1 : 0.58
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
        let isLeft = point.x < bounds.width / 2
        let newAgent: AgentKind = isLeft ? .codex : .claudeCode
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
