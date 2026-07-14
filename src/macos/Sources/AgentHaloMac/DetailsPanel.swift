import AppKit
import AgentHaloCore

enum DetailsPanelContentRole: Equatable {
    case agentSwitcher
    case provider
    case statusTitle
    case statusDetail
    case usageBody
    case sessionBody
    case unknown
}

enum DetailsPanelSessionBodyRole: Equatable {
    case project
    case separator
    case sessionTitle
    case model
    case tokens
    case unknown
}

@MainActor
class DetailsPanel: NSPanel {
    private static let panelWidth: CGFloat = 268
    private static let contextPillWidth: CGFloat = 42
    private static let contextPillHorizontalPadding: CGFloat = 3

    private let stack = NSStackView()
    private let contextValue = NSTextField(labelWithString: L10n.shared["context.empty"])
    private let titleField = NSTextField(labelWithString: "OFFLINE")
    private let detailField = NSTextField(labelWithString: L10n.shared["status.offline_codex"])
    private let providerHeader = ProviderHeaderView()
    private let primaryQuota = QuotaRowView(title: L10n.shared["quota.5h"])
    private let secondaryQuota = QuotaRowView(title: L10n.shared["quota.weekly"])
    private let agentToggle = AgentToggleView()
    private let contextPill = NSView()
    private let quotaGroup = NSStackView()
    private let metadataGroup = NSStackView()
    private let projectRow = MetadataRowView(
        title: L10n.shared["metadata.project"]
    )
    private let sessionTitleRow = MetadataRowView(
        title: L10n.shared["metadata.session_title"]
    )
    private let modelRow = MetadataRowView(
        title: L10n.shared["metadata.model"]
    )
    private let projectTitleSeparator = SeparatorView()
    private let titleModelSeparator = SeparatorView()
    private let modelTokenSeparator = SeparatorView()
    private let tokenRow = MetadataRowView(
        title: L10n.shared["metadata.tokens"],
        valueFont: .systemFont(ofSize: 11.5, weight: .medium)
    )
    private var topRow: NSView?
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
        container.layer?.backgroundColor = NSColor(calibratedRed: 0.98, green: 0.99, blue: 1.0, alpha: 0.90).cgColor
        container.translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 17, bottom: 4, right: 17)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let topRow = makeTopRow()
        self.topRow = topRow
        stack.addArrangedSubview(topRow)
        stack.setCustomSpacing(5, after: topRow)

        stack.addArrangedSubview(providerHeader)
        stack.setCustomSpacing(7, after: providerHeader)

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
        metadataGroup.addArrangedSubview(projectTitleSeparator)
        metadataGroup.addArrangedSubview(sessionTitleRow)
        metadataGroup.addArrangedSubview(titleModelSeparator)
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
            providerHeader.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -17),
            titleField.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -17),
            detailField.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -17),
            quotaGroup.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -17),
            primaryQuota.trailingAnchor.constraint(equalTo: quotaGroup.trailingAnchor),
            secondaryQuota.trailingAnchor.constraint(equalTo: quotaGroup.trailingAnchor),
            metadataGroup.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 17),
            metadataGroup.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -17)
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
        providerHeader.update(
            providerName: model.providerName,
            planName: model.planName,
            warning: model.usageWarning
        )
        updateContext(model.contextUsedPercent, isOffline: isOffline)

        quotaGroup.isHidden = true
        metadataGroup.isHidden = true

        switch model.body {
        case .usage(let usage):
            renderUsage(usage)
            quotaGroup.isHidden = false
        case .session(let session):
            renderSession(session, isOffline: isOffline)
            metadataGroup.isHidden = false
        }
        resizeToFitContent()
    }

    private func updateContext(_ contextUsedPercent: Double?, isOffline: Bool) {
        contextPill.isHidden = isOffline || contextUsedPercent == nil
        contextValue.stringValue = contextUsedPercent.map(Self.compactContextPercent)
            ?? L10n.shared["context.empty"]
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
        projectRow.setTitle(L10n.shared["metadata.project"])
        sessionTitleRow.setTitle(L10n.shared["metadata.session_title"])
        modelRow.setTitle(L10n.shared["metadata.model"])
        tokenRow.setTitle(L10n.shared["metadata.tokens"])

        if isOffline {
            projectRow.setValue("--")
            sessionTitleRow.setValue("--")
            modelRow.setValue("--")
            tokenRow.setValue("--")
            return
        }

        projectRow.setValue(Self.displayValue(session.projectName), toolTip: session.projectName)
        sessionTitleRow.setValue(Self.displayValue(session.sessionTitle), toolTip: session.sessionTitle)
        modelRow.setValue(Self.displayValue(session.modelName), toolTip: session.modelName)
        if session.inputTokens != nil || session.outputTokens != nil {
            tokenRow.attributedStringValue = Self.formatTokenAttributedString(
                input: session.inputTokens,
                output: session.outputTokens
            )
        } else {
            tokenRow.setValue("--")
        }
    }

    private func resizeToFitContent() {
        contentView?.layoutSubtreeIfNeeded()
        let scale = effectiveBackingScale
        let fittingHeight = ceil(stack.fittingSize.height * scale) / scale
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

    // Task 11 replaces the AppDelegate call site with DetailsContentResolver.
    // Keep this module-local adapter until that wiring lands so Task 10 remains
    // independently buildable without retaining the old panel layout logic.
    func update(
        aggregate: AggregateSnapshot,
        quota: RateLimitSnapshot?,
        contextUsedPercent: Double?,
        sessionDetails: SessionDetailsSnapshot? = nil,
        showsQuota: Bool? = nil
    ) {
        let providerName = aggregate.focusedAgent == .codex ? "Codex" : "Claude Code"
        let shouldShowUsage = showsQuota ?? (aggregate.focusedAgent == .codex)
        if shouldShowUsage {
            var windows: [UsageWindow] = []
            if let quota, quota.hasPrimary {
                windows.append(UsageWindow(
                    kind: .session,
                    usedPercent: quota.primaryUsedPercent,
                    resetsAt: quota.primaryResetAt,
                    duration: 18_000
                ))
            }
            if let quota, quota.hasSecondary {
                windows.append(UsageWindow(
                    kind: .weekly,
                    usedPercent: quota.secondaryUsedPercent,
                    resetsAt: quota.secondaryResetAt,
                    duration: 604_800
                ))
            }
            render(
                aggregate: aggregate,
                model: DetailsPanelViewModel(
                    providerName: providerName,
                    planName: nil,
                    usageWarning: nil,
                    contextUsedPercent: contextUsedPercent,
                    body: .usage(UsageDetailsModel(windows: windows, status: .noData))
                )
            )
        } else {
            render(
                aggregate: aggregate,
                model: DetailsPanelViewModel(
                    providerName: providerName,
                    planName: nil,
                    usageWarning: nil,
                    contextUsedPercent: contextUsedPercent,
                    body: .session(sessionDetails ?? SessionDetailsSnapshot())
                )
            )
        }
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
            if view === providerHeader { return .provider }
            if view === titleField { return .statusTitle }
            if view === detailField { return .statusDetail }
            if view === quotaGroup { return .usageBody }
            if view === metadataGroup { return .sessionBody }
            return .unknown
        }
    }

    var providerRowHeightForTesting: CGFloat {
        contentView?.layoutSubtreeIfNeeded()
        return providerHeader.frame.height
    }

    var providerTextForTesting: String {
        providerHeader.providerText
    }

    var planTextForTesting: String {
        providerHeader.planText
    }

    var planHiddenForTesting: Bool {
        providerHeader.isPlanHidden
    }

    var warningHiddenForTesting: Bool {
        providerHeader.isWarningHidden
    }

    var warningToolTipForTesting: String? {
        providerHeader.warningToolTip
    }

    var warningAccessibilityLabelForTesting: String? {
        providerHeader.warningAccessibilityLabel
    }

    var warningColorForTesting: NSColor? {
        providerHeader.warningColor
    }

    var usageGroupHiddenForTesting: Bool {
        quotaGroup.isHidden
    }

    var sessionGroupHiddenForTesting: Bool {
        metadataGroup.isHidden
    }

    var sessionBodyOrderForTesting: [DetailsPanelSessionBodyRole] {
        metadataGroup.arrangedSubviews.map { view in
            if view === projectRow { return .project }
            if view === sessionTitleRow { return .sessionTitle }
            if view === modelRow { return .model }
            if view === tokenRow { return .tokens }
            if view is SeparatorView { return .separator }
            return .unknown
        }
    }

    var sessionRowHeightsForTesting: [CGFloat] {
        contentView?.layoutSubtreeIfNeeded()
        return [projectRow, sessionTitleRow, modelRow, tokenRow].map(\.frame.height)
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

    var projectValueForTesting: String {
        projectRow.value
    }

    var sessionTitleValueForTesting: String {
        sessionTitleRow.value
    }

    var modelValueForTesting: String {
        modelRow.value
    }

    var tokenValueForTesting: String {
        tokenRow.value
    }

    var projectToolTipForTesting: String? {
        projectRow.valueToolTip
    }

    var sessionTitleToolTipForTesting: String? {
        sessionTitleRow.valueToolTip
    }

    var modelToolTipForTesting: String? {
        modelRow.valueToolTip
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

    var backingScaleForTesting: CGFloat {
        effectiveBackingScale
    }

    func selectAgentForTesting(_ agent: AgentKind) {
        agentToggle.setAgent(agent)
        onAgentSelected?(agent)
    }
}

@MainActor
private final class ProviderHeaderView: NSView {
    private let providerField = NSTextField(labelWithString: "")
    private let planField = NSTextField(labelWithString: "")
    private let warningImage = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        providerField.font = .systemFont(ofSize: 12, weight: .semibold)
        providerField.textColor = .labelColor
        providerField.lineBreakMode = .byTruncatingTail
        providerField.maximumNumberOfLines = 1
        providerField.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        planField.font = .systemFont(ofSize: 11, weight: .regular)
        planField.textColor = .secondaryLabelColor
        planField.lineBreakMode = .byTruncatingTail
        planField.maximumNumberOfLines = 1
        planField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        warningImage.image = NSImage(
            systemSymbolName: "exclamationmark.triangle.fill",
            accessibilityDescription: "exclamationmark.triangle.fill"
        )
        warningImage.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
        warningImage.contentTintColor = .systemYellow
        warningImage.imageScaling = .scaleProportionallyDown
        warningImage.isHidden = true

        [providerField, planField, warningImage].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 20),
            providerField.leadingAnchor.constraint(equalTo: leadingAnchor),
            providerField.centerYAnchor.constraint(equalTo: centerYAnchor),
            planField.leadingAnchor.constraint(equalTo: providerField.trailingAnchor, constant: 7),
            planField.centerYAnchor.constraint(equalTo: centerYAnchor),
            warningImage.leadingAnchor.constraint(equalTo: planField.trailingAnchor, constant: 7),
            warningImage.trailingAnchor.constraint(equalTo: trailingAnchor),
            warningImage.centerYAnchor.constraint(equalTo: centerYAnchor),
            warningImage.widthAnchor.constraint(equalToConstant: 12),
            warningImage.heightAnchor.constraint(equalToConstant: 12),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(providerName: String, planName: String?, warning: String?) {
        providerField.stringValue = providerName
        providerField.toolTip = providerName

        planField.stringValue = planName ?? ""
        planField.toolTip = planName
        planField.isHidden = planName == nil

        warningImage.isHidden = warning == nil
        warningImage.toolTip = warning
        warningImage.setAccessibilityLabel(warning)
    }

    var providerText: String { providerField.stringValue }
    var planText: String { planField.stringValue }
    var isPlanHidden: Bool { planField.isHidden }
    var isWarningHidden: Bool { warningImage.isHidden }
    var warningToolTip: String? { warningImage.toolTip }
    var warningAccessibilityLabel: String? { warningImage.accessibilityLabel() }
    var warningColor: NSColor? { warningImage.contentTintColor }
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
        set { setValue(newValue) }
    }

    var attributedStringValue: NSAttributedString {
        get { valueField.attributedStringValue }
        set {
            valueField.attributedStringValue = newValue
            valueField.toolTip = nil
        }
    }

    var valueToolTip: String? { valueField.toolTip }

    func setValue(_ value: String, toolTip: String? = nil) {
        valueField.stringValue = value
        valueField.toolTip = toolTip
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
        nameField.setContentCompressionResistancePriority(.required, for: .horizontal)
        nameField.setContentHuggingPriority(.required, for: .horizontal)
        nameField.translatesAutoresizingMaskIntoConstraints = false

        valueField.font = valueFont
        valueField.textColor = .labelColor
        valueField.alignment = .right
        valueField.lineBreakMode = .byTruncatingTail
        valueField.maximumNumberOfLines = 1
        valueField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        valueField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        valueField.translatesAutoresizingMaskIntoConstraints = false

        valueBackground.translatesAutoresizingMaskIntoConstraints = false
        valueBackground.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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
