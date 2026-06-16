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
    var onMouseEntered: (() -> Void)?
    var onMouseExited: (() -> Void)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 338, height: 206),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
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
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 17, bottom: 16, right: 17)
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(Self.makeTopRow(contextValue: contextValue))
        stack.setCustomSpacing(7, after: stack.arrangedSubviews[0])

        titleField.font = .systemFont(ofSize: 24, weight: .bold)
        titleField.lineBreakMode = .byTruncatingTail
        detailField.font = .systemFont(ofSize: 13)
        detailField.textColor = NSColor(calibratedRed: 0.38, green: 0.45, blue: 0.50, alpha: 1)
        detailField.lineBreakMode = .byTruncatingTail
        stack.addArrangedSubview(titleField)
        stack.setCustomSpacing(2, after: titleField)
        stack.addArrangedSubview(detailField)
        stack.setCustomSpacing(13, after: detailField)
        stack.addArrangedSubview(primaryQuota)
        stack.setCustomSpacing(10, after: primaryQuota)
        stack.addArrangedSubview(secondaryQuota)

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
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }

    func update(aggregate: AggregateSnapshot, quota: RateLimitSnapshot?) {
        titleField.stringValue = aggregate.label
        let rgb = HaloVisualModel.stateColor(aggregate.state)
        titleField.textColor = NSColor(calibratedRed: rgb.red / 255, green: rgb.green / 255, blue: rgb.blue / 255, alpha: 1)
        detailField.stringValue = Self.localizedDetail(for: aggregate)
        if let quota {
            contextValue.stringValue = quota.contextUsedPercent.map {
                "上下文 \(Int($0.rounded()))%"
            } ?? "上下文 --"
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

    static func localizedDetail(for aggregate: AggregateSnapshot) -> String {
        let action = aggregate.sessions.first?.action ?? aggregate.detail
        if action.localizedCaseInsensitiveContains("command") { return "正在执行命令" }
        if action.localizedCaseInsensitiveContains("Editing") { return "正在编辑文件" }
        if action.localizedCaseInsensitiveContains("Search") { return "正在搜索信息" }
        switch aggregate.state {
        case .thinking: return "正在思考与规划"
        case .working: return "正在执行任务"
        case .done: return "任务已完成"
        case .attention: return "等待你的授权或输入"
        case .error: return aggregate.detail.isEmpty ? "任务已中断" : aggregate.detail
        case .idle: return "Codex 正在待命"
        }
    }

    private static func makeTopRow(contextValue: NSTextField) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let brand = NSTextField(labelWithString: "Agent Halo")
        brand.font = .systemFont(ofSize: 11.5, weight: .semibold)
        brand.textColor = NSColor(calibratedRed: 0.38, green: 0.46, blue: 0.51, alpha: 1)
        brand.translatesAutoresizingMaskIntoConstraints = false

        let pill = NSView()
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 9
        pill.layer?.backgroundColor = NSColor(calibratedRed: 0.88, green: 0.95, blue: 0.99, alpha: 0.80).cgColor
        pill.layer?.borderWidth = 1
        pill.layer?.borderColor = NSColor(calibratedRed: 0.62, green: 0.78, blue: 0.88, alpha: 0.42).cgColor
        pill.translatesAutoresizingMaskIntoConstraints = false

        contextValue.font = .systemFont(ofSize: 11, weight: .regular)
        contextValue.textColor = NSColor(calibratedRed: 0.22, green: 0.49, blue: 0.57, alpha: 1)
        contextValue.lineBreakMode = .byTruncatingTail
        contextValue.translatesAutoresizingMaskIntoConstraints = false

        row.addSubview(brand)
        row.addSubview(pill)
        pill.addSubview(contextValue)
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 22),
            brand.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            brand.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            pill.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            pill.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            pill.leadingAnchor.constraint(greaterThanOrEqualTo: brand.trailingAnchor, constant: 10),
            contextValue.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 9),
            contextValue.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -9),
            contextValue.topAnchor.constraint(equalTo: pill.topAnchor, constant: 3),
            contextValue.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -3)
        ])
        return row
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
            heightAnchor.constraint(equalToConstant: 38),
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
