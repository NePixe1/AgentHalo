import AppKit
import AgentHaloCore

@MainActor
final class DetailsPanel: NSPanel {
    private let stack = NSStackView()
    private let contextValue = NSTextField(labelWithString: "上下文 --")
    private let titleField = NSTextField(labelWithString: "READY")
    private let detailField = NSTextField(labelWithString: "Codex 正在待命")
    private let primaryQuota = QuotaRowView(title: "5 小时额度")
    private let secondaryQuota = QuotaRowView(title: "周额度")
    private let agentToggle = AgentToggleView()
    private let contextPill = NSView()
    private let quotaGroup = NSStackView()
    private let metadataGroup = NSStackView()
    private let projectRow = MetadataRowView(title: "项目")
    private let modelRow = MetadataRowView(title: "模型")
    private let projectModelSeparator = NSView()
    private let modelTokenSeparator = NSView()
    private let tokenRow = MetadataRowView(
        title: "Token",
        valueFont: .systemFont(ofSize: 11.5, weight: .medium)
    )
    var onMouseEntered: (() -> Void)?
    var onMouseExited: (() -> Void)?
    var onAgentSelected: ((AgentKind) -> Void)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 338, height: 191),
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
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 17, bottom: 10, right: 17)
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
        metadataGroup.alignment = .leading
        metadataGroup.translatesAutoresizingMaskIntoConstraints = false
        [projectModelSeparator, modelTokenSeparator].forEach {
            $0.wantsLayer = true
            $0.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.27).cgColor
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
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
            metadataGroup.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -17),
            projectRow.trailingAnchor.constraint(equalTo: metadataGroup.trailingAnchor),
            projectModelSeparator.trailingAnchor.constraint(equalTo: metadataGroup.trailingAnchor),
            projectModelSeparator.heightAnchor.constraint(equalToConstant: 1),
            modelRow.trailingAnchor.constraint(equalTo: metadataGroup.trailingAnchor),
            modelTokenSeparator.trailingAnchor.constraint(equalTo: metadataGroup.trailingAnchor),
            modelTokenSeparator.heightAnchor.constraint(equalToConstant: 1),
            tokenRow.trailingAnchor.constraint(equalTo: metadataGroup.trailingAnchor)
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

        let showsCodexQuota = showsQuota ?? (aggregate.focusedAgent == .codex)
        contextPill.isHidden = contextUsedPercent == nil
        contextValue.stringValue = contextUsedPercent.map {
            "上下文 \(Int($0.rounded()))%"
        } ?? "上下文 --"
        quotaGroup.isHidden = !showsCodexQuota
        primaryQuota.isHidden = !showsCodexQuota
        secondaryQuota.isHidden = !showsCodexQuota
        metadataGroup.isHidden = showsCodexQuota
        projectRow.value = Self.displayValue(sessionDetails?.projectName)
        modelRow.value = Self.displayValue(sessionDetails?.modelName)
        tokenRow.value = "输入 \(Self.compactTokenCount(sessionDetails?.inputTokens)) · 输出 \(Self.compactTokenCount(sessionDetails?.outputTokens))"

        guard showsCodexQuota else {
            primaryQuota.updateUnavailable()
            secondaryQuota.updateUnavailable()
            return
        }

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
            contextValue.stringValue = "上下文 --"
            primaryQuota.updateUnavailable()
            secondaryQuota.updateUnavailable()
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
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = calendar.isDateInToday(date) ? "HH:mm '刷新'" : "M月d日 HH:mm '刷新'"
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

    private static func displayValue(_ value: String?) -> String {
        guard let value, !value.isEmpty else {
            return "--"
        }
        return value
    }

    static func localizedDetail(for aggregate: AggregateSnapshot) -> String {
        let action = aggregate.sessions.first?.action ?? aggregate.detail
        if aggregate.answerStreaming || action.localizedCaseInsensitiveContains("Writing answer") {
            return "正在输出答案"
        }
        if action.localizedCaseInsensitiveContains("command") { return "正在执行命令" }
        if action.localizedCaseInsensitiveContains("Editing") { return "正在编辑文件" }
        if action.localizedCaseInsensitiveContains("Search") { return "正在搜索信息" }
        if action.localizedCaseInsensitiveContains("Compressing context") { return "正在压缩上下文" }
        if action.localizedCaseInsensitiveContains("Context compacted") { return "上下文压缩完成" }
        if action.localizedCaseInsensitiveContains("Awaiting permission") { return "等待你的授权" }
        if action.localizedCaseInsensitiveContains("Permission denied") { return "授权已拒绝" }
        if action.localizedCaseInsensitiveContains("Reviewing result") { return "正在分析结果" }
        switch aggregate.state {
        case .thinking: return "正在思考与规划"
        case .working: return "正在执行任务"
        case .done: return "任务已完成"
        case .attention: return "等待你的授权或输入"
        case .error: return aggregate.detail.isEmpty ? "任务已中断" : aggregate.detail
        case .idle: return aggregate.focusedAgent.localizedStandbyDetail
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
        contextValue.lineBreakMode = .byTruncatingTail
        contextValue.translatesAutoresizingMaskIntoConstraints = false

        row.addSubview(agentToggle)
        row.addSubview(contextPill)
        contextPill.addSubview(contextValue)
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 24),
            agentToggle.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            agentToggle.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            agentToggle.widthAnchor.constraint(equalToConstant: 110),
            agentToggle.heightAnchor.constraint(equalToConstant: 24),
            contextPill.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            contextPill.centerYAnchor.constraint(equalTo: row.centerYAnchor),
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

@MainActor
private final class MetadataRowView: NSView {
    private let nameField: NSTextField
    private let valueField = NSTextField(labelWithString: "--")

    var value: String {
        get { valueField.stringValue }
        set { valueField.stringValue = newValue }
    }

    init(title: String, valueFont: NSFont = .systemFont(ofSize: 12, weight: .semibold)) {
        nameField = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        nameField.font = .systemFont(ofSize: 12)
        nameField.textColor = .labelColor
        valueField.font = valueFont
        valueField.textColor = .labelColor
        valueField.alignment = .right
        valueField.lineBreakMode = .byTruncatingTail
        valueField.maximumNumberOfLines = 1

        [nameField, valueField].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 25),
            nameField.leadingAnchor.constraint(equalTo: leadingAnchor),
            nameField.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameField.widthAnchor.constraint(equalToConstant: 52),
            valueField.leadingAnchor.constraint(greaterThanOrEqualTo: nameField.trailingAnchor, constant: 10),
            valueField.trailingAnchor.constraint(equalTo: trailingAnchor),
            valueField.centerYAnchor.constraint(equalTo: nameField.centerYAnchor)
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
    private let valueField = NSTextField(labelWithString: "暂无数据")
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
            valueField.stringValue = "等待 Codex 刷新"
            resetField.stringValue = ""
            resetField.isHidden = true
            meter.value = 0
            return
        }
        let remaining = min(100, max(0, 100 - usedPercent))
        valueField.stringValue = "剩余 \(Int(remaining.rounded()))%"
        meter.value = remaining
        let resetText = DetailsPanel.formatResetTime(resetAt)
        resetField.stringValue = resetText
        resetField.isHidden = resetText.isEmpty
    }

    func updateUnavailable() {
        valueField.stringValue = "暂无数据"
        resetField.stringValue = ""
        resetField.isHidden = true
        meter.value = 0
    }

    var valueForTesting: String {
        valueField.stringValue
    }

    private func setup() {
        nameField.font = .systemFont(ofSize: 12, weight: .regular)
        nameField.textColor = NSColor(calibratedRed: 0.37, green: 0.44, blue: 0.48, alpha: 1)
        resetField.font = .systemFont(ofSize: 11, weight: .regular)
        resetField.textColor = NSColor(calibratedRed: 0.49, green: 0.56, blue: 0.60, alpha: 1)
        valueField.font = .systemFont(ofSize: 12, weight: .semibold)
        valueField.textColor = NSColor(calibratedRed: 0.18, green: 0.24, blue: 0.29, alpha: 1)
        valueField.alignment = .right

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
