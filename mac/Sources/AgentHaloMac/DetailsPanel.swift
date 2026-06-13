import AppKit
import AgentHaloCore

@MainActor
final class DetailsPanel: NSPanel {
    private let stack = NSStackView()
    private let titleField = NSTextField(labelWithString: "READY")
    private let detailField = NSTextField(labelWithString: "Codex 正在待命")
    private let primaryQuota = NSTextField(labelWithString: "5 小时额度  暂无数据")
    private let secondaryQuota = NSTextField(labelWithString: "周额度  暂无数据")

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 282, height: 150),
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
        container.translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.spacing = 7
        stack.edgeInsets = NSEdgeInsets(top: 17, left: 14, bottom: 17, right: 15)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let brand = NSTextField(labelWithString: "Agent Halo")
        brand.font = .systemFont(ofSize: 11, weight: .semibold)
        titleField.font = .systemFont(ofSize: 18, weight: .bold)
        detailField.font = .systemFont(ofSize: 13)
        primaryQuota.font = .systemFont(ofSize: 12)
        secondaryQuota.font = .systemFont(ofSize: 12)
        [brand, titleField, detailField, primaryQuota, secondaryQuota].forEach(stack.addArrangedSubview)

        contentView = NSView()
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
        detailField.stringValue = Self.localizedDetail(for: aggregate)
        if let quota {
            primaryQuota.stringValue = "5 小时额度  剩余 \(max(0, Int(100 - quota.primaryUsedPercent)))%"
            secondaryQuota.stringValue = "周额度  剩余 \(max(0, Int(100 - quota.secondaryUsedPercent)))%"
        } else {
            primaryQuota.stringValue = "5 小时额度  暂无数据"
            secondaryQuota.stringValue = "周额度  暂无数据"
        }
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
}
