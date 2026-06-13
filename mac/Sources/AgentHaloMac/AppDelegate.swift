import AppKit
import AgentHaloCore

private let haloSize: CGFloat = 112

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settingsStore = SettingsStore()
    private var settings: HaloSettings
    private let monitor = CodexSessionMonitor()
    private var aggregate = AggregateSnapshot(
        state: .idle,
        label: "READY",
        detail: "Codex is standing by",
        sessions: []
    )
    private var statusItem: NSStatusItem!
    private var panel: HaloPanel!
    private var haloView: HaloView!
    private var timer: Timer?
    private var detailsPanel = DetailsPanel()
    private var hoverHideTimer: Timer?
    private let rateLimitReader = RateLimitReader()
    private let failureReader = CodexFailureReader()
    private let instanceLock = InstanceLock()

    override init() {
        self.settings = settingsStore.load()
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
        acknowledgeCompletedIfCodexIsForeground()
        aggregate = SessionAggregator.aggregate(
            snapshots: monitor.snapshots(),
            settings: settings,
            recentFailure: failureReader.readRecent(),
            codexRunning: CodexAppDetector.isCodexRunning()
        )
        haloView.aggregate = aggregate
        haloView.needsDisplay = true
        updateStatusMenu()
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
        haloView.onClick = { [weak self] in self?.toggleDetailsOrAcknowledge() }

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
        let menu = NSMenu()
        addMenuItem("确认已完成任务", #selector(dismissCompleted), enabled: aggregate.sessions.contains { $0.state == .done }, to: menu)
        addMenuItem("确认当前错误", #selector(dismissError), enabled: aggregate.state == .error, to: menu)
        menu.addItem(.separator())
        addCheckItem("始终置顶", checked: settings.alwaysOnTop, action: #selector(toggleAlwaysOnTop), to: menu)
        addCheckItem("开机自动启动", checked: StartupManager.isEnabled(), action: #selector(toggleStartup), to: menu)
        addCheckItem("暂停状态监听", checked: settings.paused, action: #selector(togglePause), to: menu)
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
        addMenuItem("切换到 Codex", #selector(bringCodexForward), enabled: true, to: menu)
        addMenuItem("退出 Agent Halo", #selector(quit), enabled: true, to: menu)
        statusItem.menu = menu
        let rgb = HaloVisualModel.stateColor(aggregate.state)
        let color = NSColor(calibratedRed: rgb.red / 255, green: rgb.green / 255, blue: rgb.blue / 255, alpha: 1)
        statusItem.button?.image = StatusIcon.image(color: color)
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
        CodexAppDetector.activateCodex()
    }

    @objc private func dismissCompleted() {
        settings = settings.acknowledgingCompletedSessions(aggregate.sessions)
        settingsStore.save(settings)
        tick()
    }

    @objc private func dismissError() {
        let newestErrorAt = aggregate.sessions
            .filter { $0.state == .error }
            .map(\.lastEventAt)
            .max()
        guard let newestErrorAt else {
            return
        }
        settings = settings.acknowledgingError(at: newestErrorAt)
        settingsStore.save(settings)
        tick()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
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
        let updated = settings.acknowledgingCompletedSessions(
            CodexAppDetector.isCodexForeground() ? monitor.snapshots() : []
        )
        if updated.acknowledged != settings.acknowledged {
            settings = updated
            settingsStore.save(settings)
        }
    }

    private func showDetails() {
        hoverHideTimer?.invalidate()
        detailsPanel.update(aggregate: displayAggregate(), quota: rateLimitReader.read())
        detailsPanel.onMouseEntered = { [weak self] in
            self?.hoverHideTimer?.invalidate()
        }
        detailsPanel.onMouseExited = { [weak self] in
            self?.scheduleHideDetails()
        }
        positionDetailsPanel()
        detailsPanel.orderFrontRegardless()
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

    private func toggleDetailsOrAcknowledge() {
        if aggregate.state == .done {
            dismissCompleted()
        } else if aggregate.state == .error {
            dismissError()
        } else if detailsPanel.isVisible {
            detailsPanel.orderOut(nil)
        } else {
            showDetails()
        }
    }

    private func displayAggregate() -> AggregateSnapshot {
        aggregate
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
        let item = NSMenuItem(title: title, action: #selector(previewState(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = PreviewPayload(state: state, presentation: presentation)
        menu.addItem(item)
    }

    @objc private func previewState(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? PreviewPayload else {
            return
        }
        if let state = payload.state {
            haloView.showPreview(state: state, presentation: payload.presentation ?? .flashing)
        } else {
            haloView.useLiveState()
        }
    }

    private func applyWindowLevels() {
        let level: NSWindow.Level = settings.alwaysOnTop ? .floating : .normal
        panel?.level = level
        detailsPanel.level = level
    }

    private struct PreviewPayload {
        let state: HaloState?
        let presentation: ErrorPresentation?
    }
}
