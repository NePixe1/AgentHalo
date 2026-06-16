import AppKit
import AgentHaloCore

private let haloSize: CGFloat = 112

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settingsStore: SettingsStore
    private var settings: HaloSettings
    private let monitor = CodexSessionMonitor()
    private let claudeMonitor = ClaudeSessionMonitor()
    private var selectedPreview = PreviewPayload.live
    private var aggregate: AggregateSnapshot
    private var statusItem: NSStatusItem!
    private var panel: HaloPanel!
    private var haloView: HaloView!
    private var timer: Timer?
    private var detailsPanel = DetailsPanel()
    private var hoverHideTimer: Timer?
    private let rateLimitReader = RateLimitReader()
    private let failureReader = CodexFailureReader()
    private let instanceLock = InstanceLock()
    private let codexActivator: () -> Void

    init(
        settingsStore: SettingsStore = SettingsStore(),
        codexActivator: @escaping () -> Void = CodexAppDetector.activateCodex
    ) {
        self.settingsStore = settingsStore
        self.codexActivator = codexActivator
        self.settings = settingsStore.load()
        self.aggregate = SessionAggregator.aggregate(
            snapshots: [],
            settings: self.settings,
            focusedAgent: self.settings.focusedAgent
        )
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard instanceLock.acquire() else {
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        createStatusItem()
        createHaloPanel()
        tick()
        timer = Timer.scheduledTimer(timeInterval: 0.22, target: self, selector: #selector(timerDidFire), userInfo: nil, repeats: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        saveWindowPosition()
        settingsStore.save(settings)
    }

    @objc private func timerDidFire() {
        tick()
    }

    private func tick() {
        _ = monitor.refresh()
        _ = claudeMonitor.refresh()
        acknowledgeCompletedIfCodexIsForeground()
        aggregate = SessionAggregator.aggregate(
            snapshots: allSnapshots(),
            settings: settings,
            recentFailure: failureReader.readRecent(),
            codexRunning: CodexAppDetector.isCodexRunning(),
            focusedAgent: settings.focusedAgent
        )
        haloView?.aggregate = aggregate
        haloView?.needsDisplay = true
        if statusItem != nil {
            updateStatusMenu()
        }
    }

    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = StatusIcon.image(color: NSColor.systemTeal)
        statusItem.button?.toolTip = "Agent Halo"
    }

    private func createHaloPanel() {
        let origin = initialWindowOrigin()
        haloView = HaloView(frame: NSRect(x: 0, y: 0, width: haloSize, height: haloSize))
        haloView.onDoubleClick = { [weak self] in
            self?.bringCodexForward()
        }
        haloView.onMoved = { [weak self] frame in
            self?.settings.left = frame.origin.x
            self?.settings.top = frame.origin.y
            self?.settings.hasPosition = true
            if let settings = self?.settings {
                self?.settingsStore.save(settings)
            }
        }
        haloView.onMouseEntered = { [weak self] in self?.showDetails() }
        haloView.onMouseExited = { [weak self] in self?.scheduleHideDetails() }
        haloView.onClick = { [weak self] in self?.handleHaloPrimaryClick() }
        haloView.onRightClick = { [weak self] event in
            self?.showHaloContextMenu(for: event)
        }

        panel = HaloPanel(
            contentRect: NSRect(x: origin.x, y: origin.y, width: haloSize, height: haloSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = haloView
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        applyWindowLevels()
        panel.orderFrontRegardless()
    }

    private func initialWindowOrigin() -> CGPoint {
        if settings.hasPosition {
            return CGPoint(x: settings.left, y: settings.top)
        }
        return defaultWindowOrigin(topOffset: 28)
    }

    private func defaultWindowOrigin(topOffset: CGFloat) -> CGPoint {
        let frame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return CGPoint(x: frame.maxX - haloSize - 28, y: frame.maxY - haloSize - topOffset)
    }

    private func updateStatusMenu() {
        statusItem.menu = makeControlMenu()
        let rgb = HaloVisualModel.stateColor(aggregate.state)
        let color = NSColor(calibratedRed: rgb.red / 255, green: rgb.green / 255, blue: rgb.blue / 255, alpha: 1)
        statusItem.button?.image = StatusIcon.image(color: color)
    }

    private func makeControlMenu() -> NSMenu {
        let menu = NSMenu()
        addCheckItem("始终置顶", checked: settings.alwaysOnTop, action: #selector(toggleAlwaysOnTop), to: menu)
        addCheckItem("开机自动启动", checked: StartupManager.isEnabled(), action: #selector(toggleStartup), to: menu)
        addCheckItem("暂停状态监听", checked: settings.paused, action: #selector(togglePause), to: menu)
        let focus = NSMenuItem(title: "监控对象", action: nil, keyEquivalent: "")
        let focusMenu = NSMenu()
        addFocusedAgentItem(.codex, to: focusMenu)
        addFocusedAgentItem(.claudeCode, to: focusMenu)
        focus.submenu = focusMenu
        menu.addItem(focus)
        addMenuItem("脱离卡死（移到主屏右上角）", #selector(escapeOffscreen), enabled: true, to: menu)
        let preview = NSMenuItem(title: "预览状态", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        addPreviewItem("实时状态", state: nil, presentation: nil, to: submenu)
        addPreviewItem("思考中", state: .thinking, presentation: nil, to: submenu)
        addPreviewItem("执行中", state: .working, presentation: nil, to: submenu)
        addPreviewItem("已完成", state: .done, presentation: nil, to: submenu)
        addPreviewItem("等待授权（双脉冲）", state: .attention, presentation: nil, to: submenu)
        addPreviewItem("故障（爆闪）", state: .error, presentation: .flashing, to: submenu)
        addPreviewItem("故障（常亮）", state: .error, presentation: .bright, to: submenu)
        addPreviewItem("故障（暗红）", state: .error, presentation: .dim, to: submenu)
        addPreviewItem("待机", state: .idle, presentation: nil, to: submenu)
        preview.submenu = submenu
        menu.addItem(preview)
        menu.addItem(.separator())
        addMenuItem("退出", #selector(quit), enabled: true, to: menu)
        return menu
    }

    @objc private func togglePause() {
        settings.paused.toggle()
        tick()
    }

    @objc private func toggleAlwaysOnTop() {
        settings.alwaysOnTop.toggle()
        applyWindowLevels()
        settingsStore.save(settings)
        tick()
    }

    @objc private func toggleStartup() {
        StartupManager.setEnabled(!StartupManager.isEnabled(), appBundleURL: Bundle.main.bundleURL)
        tick()
    }

    @objc private func escapeOffscreen() {
        let origin = defaultWindowOrigin(topOffset: 28)
        panel.setFrameOrigin(origin)
        settings.left = origin.x
        settings.top = origin.y
        settings.hasPosition = true
        settingsStore.save(settings)
    }

    @objc private func bringCodexForward() {
        guard settings.focusedAgent == .codex else {
            return
        }
        codexActivator()
    }

    func handleHaloPrimaryClick() {
        bringCodexForward()
    }

    func setFocusedAgent(_ agent: AgentKind) {
        guard settings.focusedAgent != agent else {
            tick()
            refreshVisibleDetailsPanel()
            return
        }
        settings.focusedAgent = agent
        settingsStore.save(settings)
        tick()
        refreshVisibleDetailsPanel()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func showHaloContextMenu(for event: NSEvent) {
        hoverHideTimer?.invalidate()
        detailsPanel.orderOut(nil)

        NSMenu.popUpContextMenu(makeHaloContextMenu(), with: event, for: haloView)
    }

    func makeHaloContextMenu() -> NSMenu {
        makeControlMenu()
    }

    private func saveWindowPosition() {
        guard let panel else {
            return
        }
        settings.left = panel.frame.origin.x
        settings.top = panel.frame.origin.y
        settings.hasPosition = true
    }

    private func acknowledgeCompletedIfCodexIsForeground() {
        guard settings.focusedAgent == .codex else {
            return
        }
        let updated = settings.acknowledgingCompletedSessions(
            CodexAppDetector.isCodexForeground() ? codexSnapshots() : []
        )
        if updated.acknowledged != settings.acknowledged {
            settings = updated
            settingsStore.save(settings)
        }
    }

    private func codexSnapshots() -> [SessionSnapshot] {
        monitor.snapshots()
    }

    private func claudeSnapshots() -> [SessionSnapshot] {
        claudeMonitor.snapshots()
    }

    private func acknowledgeCompletedSessions(_ sessions: [SessionSnapshot]) {
        let updated = settings.acknowledgingCompletedSessions(sessions)
        if updated.acknowledged != settings.acknowledged {
            settings = updated
            settingsStore.save(settings)
            aggregate = SessionAggregator.aggregate(
                snapshots: allSnapshots(),
                settings: settings,
                recentFailure: failureReader.readRecent(),
                codexRunning: CodexAppDetector.isCodexRunning(),
                focusedAgent: settings.focusedAgent
            )
        }
    }

    private func showDetails() {
        hoverHideTimer?.invalidate()
        if settings.focusedAgent == .claudeCode {
            acknowledgeCompletedSessions(claudeSnapshots())
        }
        let quota = settings.focusedAgent == .codex ? rateLimitReader.read() : nil
        detailsPanel.update(aggregate: displayAggregate(), quota: quota)
        detailsPanel.onMouseEntered = { [weak self] in
            self?.hoverHideTimer?.invalidate()
        }
        detailsPanel.onMouseExited = { [weak self] in
            self?.scheduleHideDetails()
        }
        positionDetailsPanel()
        detailsPanel.orderFrontRegardless()
    }

    private func refreshVisibleDetailsPanel() {
        guard detailsPanel.isVisible else {
            return
        }
        showDetails()
    }

    private func scheduleHideDetails() {
        hoverHideTimer?.invalidate()
        hoverHideTimer = Timer.scheduledTimer(withTimeInterval: 0.22, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.detailsPanel.orderOut(nil)
            }
        }
    }

    private func positionDetailsPanel() {
        guard let panel else { return }
        let screen = NSScreen.screens.first { $0.visibleFrame.intersects(panel.frame) } ?? NSScreen.main
        let area = screen?.visibleFrame ?? panel.frame
        let gap: CGFloat = 10
        var x = panel.frame.minX - detailsPanel.frame.width - gap
        if x < area.minX + 8 {
            x = panel.frame.maxX + gap
        }
        let y = max(area.minY + 8, min(panel.frame.midY - detailsPanel.frame.height / 2, area.maxY - detailsPanel.frame.height - 8))
        detailsPanel.setFrameOrigin(CGPoint(x: max(area.minX + 8, min(x, area.maxX - detailsPanel.frame.width - 8)), y: y))
    }

    private func displayAggregate() -> AggregateSnapshot {
        aggregate
    }

    private func allSnapshots() -> [SessionSnapshot] {
        monitor.snapshots() + claudeMonitor.snapshots()
    }

    private func addMenuItem(_ title: String, _ action: Selector, enabled: Bool, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        menu.addItem(item)
    }

    private func addCheckItem(_ title: String, checked: Bool, action: Selector, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = checked ? .on : .off
        menu.addItem(item)
    }

    private func addPreviewItem(_ title: String, state: HaloState?, presentation: ErrorPresentation?, to menu: NSMenu) {
        let payload = PreviewPayload(state: state, presentation: presentation)
        let item = NSMenuItem(title: title, action: #selector(previewState(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = payload
        item.state = payload == selectedPreview ? .on : .off
        menu.addItem(item)
    }

    private func addFocusedAgentItem(_ agent: AgentKind, to menu: NSMenu) {
        let item = NSMenuItem(title: agent.menuTitle, action: #selector(selectFocusedAgent(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = agent.rawValue
        item.state = settings.focusedAgent == agent ? .on : .off
        menu.addItem(item)
    }

    @objc private func selectFocusedAgent(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let agent = AgentKind(rawValue: rawValue) else {
            return
        }
        setFocusedAgent(agent)
    }

    @objc private func previewState(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? PreviewPayload else {
            return
        }
        selectedPreview = payload
        updatePreviewCheckmarks(in: sender.menu)
        if let state = payload.state {
            haloView?.showPreview(state: state, presentation: payload.presentation ?? .flashing)
        } else {
            haloView?.useLiveState()
        }
    }

    private func updatePreviewCheckmarks(in menu: NSMenu?) {
        for item in menu?.items ?? [] {
            guard let payload = item.representedObject as? PreviewPayload else {
                continue
            }
            item.state = payload == selectedPreview ? .on : .off
        }
    }

    private func applyWindowLevels() {
        let level = Self.haloWindowLevel(alwaysOnTop: settings.alwaysOnTop)
        panel?.level = level
        detailsPanel.level = level
        panel?.orderFrontRegardless()
    }

    static func haloWindowLevel(alwaysOnTop: Bool) -> NSWindow.Level {
        alwaysOnTop ? .screenSaver : .normal
    }

    private struct PreviewPayload: Equatable {
        static let live = PreviewPayload(state: nil, presentation: nil)

        let state: HaloState?
        let presentation: ErrorPresentation?
    }
}
