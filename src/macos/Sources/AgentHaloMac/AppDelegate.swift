import AppKit
import AgentHaloCore

private let haloSizeMenuWidth: CGFloat = 252
private let haloSizeMenuHeight: CGFloat = 44
private let haloSizeMenuTextInset: CGFloat = 21

struct DetailsPresentation: Equatable {
    var sessionDetails: SessionDetailsSnapshot
    var showsQuota: Bool
    var contextUsedPercent: Double?
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settingsStore: SettingsStore
    private var settings: HaloSettings
    private let monitor = CodexSessionMonitor()
    private let claudeHookMonitor = ClaudeHookStatusMonitor()
    private let claudeSessionMonitor = ClaudeSessionMonitor()
    private var selectedPreview = PreviewPayload.live
    private var aggregate: AggregateSnapshot
    private var statusItem: NSStatusItem!
    private var panel: HaloPanel!
    private var haloView: HaloView!
    private var timer: Timer?
    private var detailsPanel = DetailsPanel()
    private var hoverHideTimer: Timer?
    private var settingsSaveTimer: Timer?
    private var systemOverlaySuspended = false
    private let rateLimitReader = RateLimitReader()
    private let claudeContextUsageReader = ClaudeContextUsageReader()
    private let contextReaderQueue = DispatchQueue(
        label: "com.agenthalo.context-reader",
        qos: .userInteractive
    )
    private let failureReader = CodexFailureReader()
    private let realtimeActivityReader = CodexRealtimeActivityReader()
    private let instanceLock = InstanceLock()
    private let codexActivator: () -> Void
    private var currentHaloSize: CGFloat {
        CGFloat(settings.haloSize)
    }

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
        ClaudeHookConfigurator.configure()
        ClaudeStatusLineConfigurator.configure()
        NSApp.setActivationPolicy(.accessory)
        createStatusItem()
        createHaloPanel()
        recoverHaloIfOffscreen()
        registerSystemOverlayObservers()
        updateSystemOverlaySuspension(for: NSWorkspace.shared.frontmostApplication)
        tick()
        timer = Timer.scheduledTimer(timeInterval: 0.22, target: self, selector: #selector(timerDidFire), userInfo: nil, repeats: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        settingsSaveTimer?.invalidate()
        saveWindowPosition()
        settingsStore.save(settings)
    }

    func applicationDidChangeScreenParameters(_ notification: Notification) {
        recoverHaloIfOffscreen()
    }

    @objc private func timerDidFire() {
        tick()
    }

    private func tick() {
        if haloView?.isDragging == true {
            return
        }
        updateSystemOverlaySuspension(for: NSWorkspace.shared.frontmostApplication)
        _ = monitor.refresh()
        _ = claudeHookMonitor.refresh()
        _ = claudeSessionMonitor.refresh()
        acknowledgeCompletedIfCodexIsForeground()
        aggregate = SessionAggregator.aggregate(
            snapshots: allSnapshots(),
            settings: settings,
            recentFailure: failureReader.readRecent(),
            codexRunning: CodexAppDetector.isCodexRunning(),
            focusedAgent: settings.focusedAgent
        )
        aggregate = Self.claudeStandbyAggregate(
            aggregate: aggregate,
            hasLiveSession: settings.focusedAgent == .claudeCode
                && aggregate.state == .idle
                && ClaudeLiveSessionReader.hasStandbySession()
        )
        applyRealtimeCodexActivity()
        haloView?.aggregate = aggregate
        refreshVisibleDetailsStatus()
        if !systemOverlaySuspended {
            haloView?.needsDisplay = true
        }
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
        let haloSize = currentHaloSize
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
        haloView.onDragStarted = { [weak self] in self?.hideDetailsImmediately() }
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
        panel.sharingType = Self.haloWindowSharingType
        panel.collectionBehavior = Self.haloCollectionBehavior
        applyWindowLevels()
        panel.orderFrontRegardless()
    }

    private func registerSystemOverlayObservers() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            self,
            selector: #selector(workspaceApplicationDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(workspaceActiveSpaceDidChange(_:)),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
    }

    @objc private func workspaceApplicationDidActivate(_ notification: Notification) {
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        updateSystemOverlaySuspension(for: app)
    }

    @objc private func workspaceActiveSpaceDidChange(_ notification: Notification) {
        updateSystemOverlaySuspension(for: NSWorkspace.shared.frontmostApplication)
    }

    private func updateSystemOverlaySuspension(for app: NSRunningApplication?) {
        setSystemOverlaySuspended(Self.shouldSuspendForSystemOverlay(
            frontmostBundleIdentifier: app?.bundleIdentifier,
            frontmostLocalizedName: app?.localizedName
        ))
    }

    private func setSystemOverlaySuspended(_ suspended: Bool) {
        guard systemOverlaySuspended != suspended else {
            return
        }
        systemOverlaySuspended = suspended
        haloView?.setSystemOverlaySuspended(suspended)
        if suspended {
            hoverHideTimer?.invalidate()
            if detailsPanel.isVisible {
                detailsPanel.orderFrontRegardless()
            }
            if Self.haloWindowVisibilityDuringSystemOverlay == .visible {
                panel?.orderFrontRegardless()
            }
        } else {
            haloView?.aggregate = aggregate
            haloView?.needsDisplay = true
            panel?.orderFrontRegardless()
            reconcileDetailsVisibilityAfterSystemOverlay()
        }
    }

    private func initialWindowOrigin() -> CGPoint {
        if settings.hasPosition {
            return CGPoint(x: settings.left, y: settings.top)
        }
        return defaultWindowOrigin(topOffset: 28)
    }

    private func defaultWindowOrigin(topOffset: CGFloat) -> CGPoint {
        let frame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let haloSize = currentHaloSize
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
        addHaloSizeItem(to: menu)
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

    private func recoverHaloIfOffscreen() {
        guard let panel else {
            return
        }
        let visibleFrames = NSScreen.screens.map(\.visibleFrame)
        guard !Self.isHaloFrameVisible(panel.frame, in: visibleFrames) else {
            return
        }
        escapeOffscreen()
    }

    @objc private func haloSizeSliderChanged(_ sender: NSSlider) {
        let value = Int(CGFloat(sender.doubleValue).rounded())
        if let valueLabel = sender.superview?.subviews.first(where: { $0.identifier?.rawValue == "halo-size-value" }) as? NSTextField {
            valueLabel.stringValue = "\(value)"
        }
        applyHaloSize(CGFloat(sender.doubleValue))
    }

    @objc private func bringCodexForward() {
        guard settings.focusedAgent == .codex else {
            return
        }
        codexActivator()
    }

    func handleHaloPrimaryClick() {
        // Keep single-click non-activating. Double-click remains the explicit
        // path for bringing Codex forward.
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
        hideDetailsImmediately()

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

    private func applyHaloSize(_ size: CGFloat) {
        let clampedSize = CGFloat(HaloSettings.clampedHaloSize(Double(size)))
        settings.haloSize = Double(clampedSize)
        guard let panel, let haloView else {
            scheduleSettingsSave()
            return
        }

        let oldFrame = panel.frame
        let frame = Self.haloFrameByKeepingOrigin(oldFrame: oldFrame, requestedSize: clampedSize)
        panel.setFrame(frame, display: true)
        haloView.resizeForHaloSize(clampedSize)
        settings.left = frame.origin.x
        settings.top = frame.origin.y
        settings.hasPosition = true
        scheduleSettingsSave()
        positionDetailsPanel()
    }

    private func scheduleSettingsSave() {
        settingsSaveTimer?.invalidate()
        let timer = Timer(timeInterval: 0.18, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.settingsStore.save(self.settings)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        settingsSaveTimer = timer
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
        ClaudeStatusSourceMerger.merge(
            hookSnapshots: claudeHookMonitor.snapshots(),
            transcriptSnapshots: claudeSessionMonitor.snapshots()
        )
    }

    static func claudeStandbyAggregate(
        aggregate: AggregateSnapshot,
        hasLiveSession: Bool
    ) -> AggregateSnapshot {
        guard hasLiveSession,
              aggregate.focusedAgent == .claudeCode,
              aggregate.state == .idle else {
            return aggregate
        }
        return AggregateSnapshot(
            state: .done,
            label: "STANDBY",
            detail: AgentKind.claudeCode.localizedStandbyDetail,
            sessions: [],
            focusedAgent: .claudeCode
        )
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
            applyRealtimeCodexActivity()
        }
    }

    private func showDetails() {
        guard !systemOverlaySuspended else {
            return
        }
        hoverHideTimer?.invalidate()
        let rawClaudeSnapshots = settings.focusedAgent == .claudeCode ? claudeSnapshots() : []
        if settings.focusedAgent == .claudeCode {
            acknowledgeCompletedSessions(rawClaudeSnapshots)
        }
        let displayedAggregate = displayAggregate()
        let quota = settings.focusedAgent == .codex ? rateLimitReader.read() : nil
        let claudeSessionIds = rawClaudeSnapshots.isEmpty
            ? displayedAggregate.sessions.map(\.threadId)
            : rawClaudeSnapshots.map(\.threadId)
        let claudeUsage = settings.focusedAgent == .claudeCode
            ? contextReaderQueue.sync {
                claudeContextUsageReader.read(
                    sessionIds: claudeSessionIds.filter { $0 != "claude-code" }
                )
            }
            : nil
        let presentation = Self.detailsPresentationForDetails(
            focusedAgent: settings.focusedAgent,
            displayedAggregate: displayedAggregate,
            rawClaudeSnapshots: rawClaudeSnapshots,
            quota: quota,
            claudeUsage: claudeUsage
        )
        detailsPanel.update(
            aggregate: displayedAggregate,
            quota: quota,
            contextUsedPercent: presentation.contextUsedPercent,
            sessionDetails: presentation.sessionDetails,
            showsQuota: presentation.showsQuota
        )
        detailsPanel.onMouseEntered = { [weak self] in
            self?.hoverHideTimer?.invalidate()
        }
        detailsPanel.onMouseExited = { [weak self] in
            self?.scheduleHideDetails()
        }
        detailsPanel.onAgentSelected = { [weak self] agent in
            self?.setFocusedAgent(agent)
        }
        positionDetailsPanel()
        detailsPanel.orderFrontRegardless()
    }

    static func contextUsedPercentForDetails(
        focusedAgent: AgentKind,
        quota: RateLimitSnapshot?,
        displayedAggregate: AggregateSnapshot,
        rawClaudeSnapshots: [SessionSnapshot],
        claudeContextUsageReader: ClaudeContextUsageReader,
        contextReaderQueue: DispatchQueue,
        now: Date = Date()
    ) -> Double? {
        switch focusedAgent {
        case .codex:
            return quota?.contextUsedPercent
        case .claudeCode:
            let sessionIds = rawClaudeSnapshots.isEmpty
                ? displayedAggregate.sessions.map(\.threadId)
                : rawClaudeSnapshots.map(\.threadId)
            let comparableSessionIds = sessionIds.filter { $0 != "claude-code" }
            return contextReaderQueue.sync {
                claudeContextUsageReader.read(
                    sessionIds: comparableSessionIds,
                    now: now
                )?.usedPercent
            }
        }
    }

    static func detailsPresentationForDetails(
        focusedAgent: AgentKind,
        displayedAggregate: AggregateSnapshot,
        rawClaudeSnapshots: [SessionSnapshot],
        quota: RateLimitSnapshot?,
        claudeUsage: ClaudeContextUsageSnapshot?
    ) -> DetailsPresentation {
        switch focusedAgent {
        case .codex:
            let session = displayedAggregate.sessions.first
            let showsQuota = session?.hasRateLimits ?? (quota != nil)
            return DetailsPresentation(
                sessionDetails: SessionDetailsSnapshot(
                    projectName: session?.projectName,
                    modelName: session?.modelName,
                    inputTokens: session?.inputTokens,
                    outputTokens: session?.outputTokens
                ),
                showsQuota: showsQuota,
                contextUsedPercent: session?.contextUsedPercent
                    ?? (showsQuota ? quota?.contextUsedPercent : nil)
            )
        case .claudeCode:
            let matchingRawSession = claudeUsage.flatMap { usage in
                rawClaudeSnapshots.first { $0.threadId == usage.sessionId }
            }
            let session = matchingRawSession
                ?? displayedAggregate.sessions.first
                ?? rawClaudeSnapshots.first
            let matchingUsage = session.flatMap { session in
                claudeUsage?.sessionId == session.threadId ? claudeUsage : nil
            }
            return DetailsPresentation(
                sessionDetails: SessionDetailsSnapshot(
                    projectName: session?.projectName,
                    modelName: matchingUsage?.modelName,
                    inputTokens: matchingUsage?.inputTokens,
                    outputTokens: matchingUsage?.outputTokens
                ),
                showsQuota: false,
                contextUsedPercent: matchingUsage?.usedPercent
            )
        }
    }

    private func refreshVisibleDetailsPanel() {
        guard detailsPanel.isVisible else {
            return
        }
        showDetails()
    }

    private func refreshVisibleDetailsStatus() {
        guard detailsPanel.isVisible else {
            return
        }
        detailsPanel.updateStatus(aggregate: displayAggregate())
    }

    private func scheduleHideDetails() {
        hoverHideTimer?.invalidate()
        guard !systemOverlaySuspended else {
            return
        }
        hoverHideTimer = Timer.scheduledTimer(withTimeInterval: 0.22, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.systemOverlaySuspended else {
                    return
                }
                self.detailsPanel.orderOut(nil)
            }
        }
    }

    private func hideDetailsImmediately() {
        hoverHideTimer?.invalidate()
        detailsPanel.orderOut(nil)
    }

    private func reconcileDetailsVisibilityAfterSystemOverlay() {
        guard detailsPanel.isVisible, let haloFrame = panel?.frame else {
            return
        }
        guard !Self.shouldKeepDetailsVisibleAfterSystemOverlay(
            mouseLocation: NSEvent.mouseLocation,
            haloFrame: haloFrame,
            detailsFrame: detailsPanel.frame
        ) else {
            return
        }
        scheduleHideDetails()
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

    private func applyRealtimeCodexActivity() {
        guard settings.focusedAgent == .codex,
              let activity = realtimeActivityReader.readActive() else {
            return
        }
        let projectName = aggregate.sessions.first?.projectName ?? "Codex"
        aggregate = AggregateSnapshot(
            state: activity.state,
            label: SessionAggregator.label(for: activity.state),
            detail: "\(projectName) - \(activity.action)",
            sessions: aggregate.sessions,
            focusedAgent: .codex,
            answerStreaming: activity.answerStreaming
        )
    }

    private func allSnapshots() -> [SessionSnapshot] {
        monitor.snapshots() + claudeSnapshots()
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

    private func addHaloSizeItem(to menu: NSMenu) {
        let item = NSMenuItem(title: "圆环大小", action: nil, keyEquivalent: "")
        let container = NSView(frame: NSRect(x: 0, y: 0, width: haloSizeMenuWidth, height: haloSizeMenuHeight))
        let label = NSTextField(labelWithString: "圆环大小")
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        let slider = NSSlider(
            value: settings.haloSize,
            minValue: HaloSettings.minimumHaloSize,
            maxValue: HaloSettings.maximumHaloSize,
            target: self,
            action: #selector(haloSizeSliderChanged(_:))
        )
        slider.isContinuous = true
        slider.translatesAutoresizingMaskIntoConstraints = false

        let valueLabel = NSTextField(labelWithString: "\(Int(settings.haloSize.rounded()))")
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right
        valueLabel.identifier = NSUserInterfaceItemIdentifier("halo-size-value")
        valueLabel.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(label)
        container.addSubview(slider)
        container.addSubview(valueLabel)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: haloSizeMenuTextInset),
            label.centerYAnchor.constraint(equalTo: slider.centerYAnchor),
            label.widthAnchor.constraint(equalToConstant: 58),
            slider.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 10),
            slider.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            valueLabel.leadingAnchor.constraint(equalTo: slider.trailingAnchor, constant: 8),
            valueLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            valueLabel.centerYAnchor.constraint(equalTo: slider.centerYAnchor),
            valueLabel.widthAnchor.constraint(equalToConstant: 32)
        ])
        item.view = container
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
        if !systemOverlaySuspended {
            panel?.orderFrontRegardless()
        }
    }

    static func haloWindowLevel(alwaysOnTop: Bool) -> NSWindow.Level {
        alwaysOnTop ? .floating : .normal
    }

    static let haloCollectionBehavior: NSWindow.CollectionBehavior = [
        .canJoinAllSpaces,
        .fullScreenAuxiliary,
        .transient
    ]

    static let haloWindowSharingType: NSWindow.SharingType = .readOnly

    static let haloWindowVisibilityDuringSystemOverlay = SystemOverlayHaloVisibility.visible

    static func isSystemOverlayApplication(bundleIdentifier: String?, localizedName: String?) -> Bool {
        let systemOverlayBundleIdentifiers: Set<String> = [
            "com.apple.screenshot.launcher",
            "com.apple.screencaptureui",
            "com.apple.dock",
            "com.snipaste.Snipaste"
        ]
        if let bundleIdentifier, systemOverlayBundleIdentifiers.contains(bundleIdentifier) {
            return true
        }

        let normalizedName = localizedName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalizedName == "screenshot" || normalizedName == "snipaste"
    }

    static func shouldSuspendForSystemOverlay(
        frontmostBundleIdentifier: String?,
        frontmostLocalizedName: String?
    ) -> Bool {
        isSystemOverlayApplication(
            bundleIdentifier: frontmostBundleIdentifier,
            localizedName: frontmostLocalizedName
        )
    }

    static func shouldKeepDetailsVisibleAfterSystemOverlay(
        mouseLocation: NSPoint,
        haloFrame: NSRect,
        detailsFrame: NSRect
    ) -> Bool {
        HaloGeometry.contains(point: mouseLocation, in: haloFrame) || detailsFrame.contains(mouseLocation)
    }

    static func haloFrameByKeepingOrigin(oldFrame: NSRect, requestedSize: CGFloat) -> NSRect {
        let size = CGFloat(HaloSettings.clampedHaloSize(Double(requestedSize)))
        return NSRect(x: oldFrame.origin.x, y: oldFrame.origin.y, width: size, height: size)
    }

    static func isHaloFrameVisible(_ frame: NSRect, in visibleFrames: [NSRect]) -> Bool {
        visibleFrames.contains { $0.intersects(frame) }
    }

    private struct PreviewPayload: Equatable {
        static let live = PreviewPayload(state: nil, presentation: nil)

        let state: HaloState?
        let presentation: ErrorPresentation?
    }

    enum SystemOverlayHaloVisibility {
        case visible
    }
}
