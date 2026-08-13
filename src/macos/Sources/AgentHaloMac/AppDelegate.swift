import AppKit
import AgentHaloCore

struct LiveErrorPresentationUpdate: Equatable {
    var presentation: ErrorPresentation
    var acknowledgeErrorAt: Date?
}

struct StatusMenuSignature: Equatable {
    var settings: HaloSettings
    var selectedPreview: PreviewPayload
    var startupEnabled: Bool
}

struct PreviewPayload: Equatable {
    static let live = PreviewPayload(state: nil, presentation: nil)

    let state: HaloState?
    let presentation: ErrorPresentation?
}

struct UsageTerminationHandshake {
    private enum Phase {
        case running
        case cancelling
        case completed
    }

    private var phase = Phase.running

    var hasCompleted: Bool {
        phase == .completed
    }

    mutating func beginCancellation() -> Bool {
        guard phase == .running else {
            return false
        }
        phase = .cancelling
        return true
    }

    mutating func finishCancellation() -> Bool {
        guard phase == .cancelling else {
            return false
        }
        phase = .completed
        return true
    }
}

struct UsageRequestRecord {
    let token: UUID
    let task: Task<Void, Never>
}

struct LiveErrorPresentationState {
    private(set) var presentation: ErrorPresentation = .flashing
    private var activeErrorAt: Date?
    private var dimmedAt: Date?

    mutating func update(
        aggregate: AggregateSnapshot,
        codexIsForeground: Bool,
        codexWasForeground: Bool,
        now: Date
    ) -> LiveErrorPresentationUpdate {
        guard aggregate.focusedAgent == .codex,
              aggregate.state == .error else {
            presentation = .flashing
            activeErrorAt = nil
            dimmedAt = nil
            return LiveErrorPresentationUpdate(
                presentation: presentation,
                acknowledgeErrorAt: nil
            )
        }

        let errorAt = aggregate.sessions
            .filter { $0.state == .error }
            .map(\.lastEventAt)
            .max() ?? now

        if activeErrorAt == nil || errorAt > activeErrorAt! {
            activeErrorAt = errorAt
            dimmedAt = nil
            presentation = codexIsForeground ? .bright : .flashing
        } else if codexIsForeground {
            presentation = .bright
            dimmedAt = nil
        } else if codexWasForeground {
            presentation = .dim
            dimmedAt = now
        } else if presentation == .dim,
                  let dimmedAt,
                  now.timeIntervalSince(dimmedAt) >= 60 {
            presentation = .flashing
            activeErrorAt = nil
            self.dimmedAt = nil
            return LiveErrorPresentationUpdate(
                presentation: presentation,
                acknowledgeErrorAt: errorAt
            )
        } else if presentation != .dim {
            presentation = .flashing
        }

        return LiveErrorPresentationUpdate(
            presentation: presentation,
            acknowledgeErrorAt: nil
        )
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settingsStore: SettingsStore
    private var settings: HaloSettings
    private let codexActivityMonitor = CodexActivityMonitor()
    private var codexActivitySnapshot = CodexActivitySnapshot.empty
    private let claudeActivityMonitor = ClaudeActivityMonitor()
    private var claudeActivitySnapshot = ClaudeActivitySnapshot.empty
    private let grokActivityMonitor = GrokActivityMonitor()
    private var grokActivitySnapshot = GrokActivitySnapshot.empty
    private let piActivityMonitor = PiActivityMonitor()
    private var piActivitySnapshot = PiActivitySnapshot.empty
    private var nextStatusLineReconciliationAt = Date.distantPast
    private let statusLineReconciliationInterval: TimeInterval = 2
    private var selectedPreview = PreviewPayload.live
    private var aggregate: AggregateSnapshot
    private var statusItem: NSStatusItem?
    private var panel: HaloPanel!
    private var haloView: HaloView!
    private var timer: Timer?
    private var detailsPanel = DetailsPanel()
    private var hoverHideTimer: Timer?
    private var settingsSaveTimer: Timer?
    private var systemOverlaySuspended = false
    private var placementState = HaloPlacementRuntimeState()
    private let usageCoordinator: UsageMonitoringCoordinator
    private var usageStates: [UsageProviderID: UsageMonitorState] = [:]
    private var usageRefreshLoopTask: Task<Void, Never>?
    private var usageRequestTasks: [UsageProviderID: UsageRequestRecord] = [:]
    private let usageRefreshInterval: TimeInterval = 5 * 60
    private var usageTerminationHandshake = UsageTerminationHandshake()
    private let claudeContextUsageReader = ClaudeContextUsageReader()
    private let grokSessionContextReader = GrokSessionContextReader()
    private let contextReaderQueue = DispatchQueue(
        label: "com.agenthalo.context-reader",
        qos: .userInteractive
    )
    /// While details stay open on Grok, re-read disk context on this cadence so
    /// the pill appears as soon as `updates.jsonl` has totalTokens (new sessions
    /// often lack `signals.json` until the first turn ends).
    private let grokContextRefreshInterval: TimeInterval = 1.0
    private var lastGrokContextRefreshAt = Date.distantPast
    private let instanceLock = InstanceLock()
    private let codexActivator: @MainActor () -> Void
    private var liveErrorPresentationState = LiveErrorPresentationState()
    private var codexIsForeground = false
    private var codexWasForeground = false
    private var lastStatusMenuSignature: StatusMenuSignature?
    private var cachedStartupEnabled = false
    private var cachedStartupExpiresAt = Date.distantPast
    private let startupCheckInterval: TimeInterval = 2
    private var currentLanguage: String = "zh"
    private var languageObserver: NSObjectProtocol?
    private var settingsWindowController: SettingsWindowController?
    private var currentHaloSize: CGFloat {
        CGFloat(settings.haloSize)
    }

    init(
        settingsStore: SettingsStore = SettingsStore(),
        codexActivator: @escaping @MainActor () -> Void = CodexAppDetector.activateCodex,
        usageCoordinator: UsageMonitoringCoordinator = .live()
    ) {
        self.settingsStore = settingsStore
        self.codexActivator = codexActivator
        self.usageCoordinator = usageCoordinator
        self.settings = settingsStore.load()
        self.aggregate = SessionAggregator.aggregate(
            snapshots: [],
            settings: self.settings,
            focusedAgent: self.settings.focusedAgent
        )
        super.init()
        activateFocusedUsageProvider(self.settings.focusedAgent)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard instanceLock.acquire() else {
            NSApp.terminate(nil)
            return
        }
        // Single upgrade path: migrate data → stage all hook binaries (no gap)
        // → rewrite configs only when unhealthy. See AgentHaloRuntimeBootstrap.
        AgentHaloRuntimeBootstrap.bootstrap(enabledAgents: settings.enabledAgents)
        NSApp.setActivationPolicy(.accessory)
        applyMenuBarIconVisibility()
        createHaloPanel()
        reconcileHaloPlacement()
        registerSystemOverlayObservers()
        updateFrontmostApplication(NSWorkspace.shared.frontmostApplication)
        codexActivitySnapshot = codexActivityMonitor.snapshot()
        codexActivityMonitor.start { [weak self] snapshot in
            Task { @MainActor in
                self?.codexActivityDidChange(snapshot)
            }
        }
        claudeActivitySnapshot = claudeActivityMonitor.snapshot()
        claudeActivityMonitor.start { [weak self] snapshot in
            Task { @MainActor in
                self?.claudeActivityDidChange(snapshot)
            }
        }
        grokActivitySnapshot = grokActivityMonitor.snapshot()
        grokActivityMonitor.start { [weak self] snapshot in
            Task { @MainActor in
                self?.grokActivityDidChange(snapshot)
            }
        }
        piActivitySnapshot = piActivityMonitor.snapshot()
        piActivityMonitor.start { [weak self] snapshot in
            Task { @MainActor in
                self?.piActivityDidChange(snapshot)
            }
        }
        // Initialize L10n with user's saved preference
        L10n.shared.setLanguage(settings.language)
        currentLanguage = L10n.shared.currentLanguage
        startUsageRefreshLoop()
        if let providerID = Self.usageProviderID(for: settings.focusedAgent) {
            requestUsageRefresh(for: providerID)
        }

        // Observe language changes
        languageObserver = NotificationCenter.default.addObserver(
            forName: L10n.languageDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.currentLanguage = L10n.shared.currentLanguage
                self.settings.language = Self.languagePreferenceAfterResolvedLanguageChange(
                    savedLanguage: self.settings.language,
                    currentLanguage: L10n.shared.currentLanguage,
                    systemLanguage: L10n.detectSystemLanguage()
                )
                // Rebuild menu so all items show new language
                self.lastStatusMenuSignature = nil
                self.tick()
                self.refreshVisibleDetailsPanel()
                if let controller = self.settingsWindowController,
                   controller.window?.isVisible == true {
                    controller.refresh(
                        settings: self.settings,
                        launchAtLogin: StartupManager.isEnabled()
                    )
                }
            }
        }
        tick()
        timer = Timer.scheduledTimer(timeInterval: 0.3, target: self, selector: #selector(timerDidFire), userInfo: nil, repeats: true)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if usageTerminationHandshake.hasCompleted {
            return .terminateNow
        }
        guard usageTerminationHandshake.beginCancellation() else {
            return .terminateLater
        }
        cancelLocalUsageTasks()
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.usageCoordinator.cancelAll()
            guard self.usageTerminationHandshake.finishCancellation() else {
                return
            }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        cancelLocalUsageTasks()
        codexActivityMonitor.stop()
        claudeActivityMonitor.stop()
        grokActivityMonitor.stop()
        piActivityMonitor.stop()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        settingsSaveTimer?.invalidate()
        if placementState.shouldPersistCurrentFrame, let panel {
            commitPreferredPlacement(frame: panel.frame, persist: false)
        }
        settingsStore.save(settings)
    }

    private func cancelLocalUsageTasks() {
        usageCoordinator.focusController.deactivateAll()
        usageRefreshLoopTask?.cancel()
        usageRefreshLoopTask = nil
        usageRequestTasks.values.forEach { $0.task.cancel() }
        usageRequestTasks.removeAll()
    }

    func applicationDidChangeScreenParameters(_ notification: Notification) {
        reconcileHaloPlacement()
    }

    @objc private func timerDidFire() {
        tick()
    }

    private func tick() {
        if haloView?.isDragging == true {
            return
        }
        let now = Date()
        if settings.isAgentEnabled(.claudeCode) {
            reconcileClaudeStatusLineConfiguration(now: now)
        }
        acknowledgeCompletedIfCodexIsForeground()
        let codexRunning = CodexAppDetector.isCodexRunning()
        codexActivityMonitor.updatePollingContext(
            focusedAgent: settings.focusedAgent,
            codexRunning: codexRunning,
            enabled: settings.isAgentEnabled(.codex)
        )
        claudeActivityMonitor.updatePollingContext(
            focusedAgent: settings.focusedAgent,
            detailsPanelVisible: detailsPanel.isVisible,
            enabled: settings.isAgentEnabled(.claudeCode)
        )
        grokActivityMonitor.updatePollingContext(
            focusedAgent: settings.focusedAgent,
            detailsPanelVisible: detailsPanel.isVisible,
            enabled: settings.isAgentEnabled(.grok)
        )
        piActivityMonitor.updatePollingContext(
            focusedAgent: settings.focusedAgent,
            detailsPanelVisible: detailsPanel.isVisible,
            enabled: settings.isAgentEnabled(.pi)
        )
        refreshAggregateAndUI(now: now, codexRunning: codexRunning)
    }

    private func claudeActivityDidChange(_ snapshot: ClaudeActivitySnapshot) {
        guard haloView?.isDragging != true else {
            claudeActivitySnapshot = snapshot
            return
        }
        claudeActivitySnapshot = snapshot
        let codexRunning = CodexAppDetector.isCodexRunning()
        refreshAggregateAndUI(now: Date(), codexRunning: codexRunning)
    }

    private func grokActivityDidChange(_ snapshot: GrokActivitySnapshot) {
        guard haloView?.isDragging != true else {
            grokActivitySnapshot = snapshot
            return
        }
        grokActivitySnapshot = snapshot
        let codexRunning = CodexAppDetector.isCodexRunning()
        refreshAggregateAndUI(now: Date(), codexRunning: codexRunning)
    }

    private func piActivityDidChange(_ snapshot: PiActivitySnapshot) {
        guard haloView?.isDragging != true else {
            piActivitySnapshot = snapshot
            return
        }
        piActivitySnapshot = snapshot
        let codexRunning = CodexAppDetector.isCodexRunning()
        refreshAggregateAndUI(now: Date(), codexRunning: codexRunning)
    }

    private func codexActivityDidChange(_ snapshot: CodexActivitySnapshot) {
        guard haloView?.isDragging != true else {
            codexActivitySnapshot = snapshot
            return
        }
        codexActivitySnapshot = snapshot
        let codexRunning = CodexAppDetector.isCodexRunning()
        codexActivityMonitor.updatePollingContext(
            focusedAgent: settings.focusedAgent,
            codexRunning: codexRunning,
            enabled: settings.isAgentEnabled(.codex)
        )
        refreshAggregateAndUI(now: Date(), codexRunning: codexRunning)
    }

    private func hasLiveSessionForFocusedAgent(codexRunning: Bool) -> Bool {
        switch settings.focusedAgent {
        case .codex:
            return codexRunning
        case .claudeCode:
            return claudeActivitySnapshot.preferredStandbySession != nil
        case .grok:
            return grokActivitySnapshot.isPresent
        case .pi:
            return piActivitySnapshot.isPresent
        }
    }

    private func refreshAggregateAndUI(now: Date, codexRunning: Bool) {
        aggregate = SessionAggregator.aggregate(
            snapshots: allSnapshots(),
            settings: settings,
            recentFailure: codexActivitySnapshot.recentFailure,
            codexRunning: codexRunning,
            focusedAgent: settings.focusedAgent
        )
        aggregate = Self.standbyAggregate(
            aggregate: aggregate,
            hasLiveSession: hasLiveSessionForFocusedAgent(codexRunning: codexRunning)
        )
        applyRealtimeCodexActivity(codexActivitySnapshot.realtimeActivity)
        let errorUpdate = liveErrorPresentationState.update(
            aggregate: aggregate,
            codexIsForeground: codexIsForeground,
            codexWasForeground: codexWasForeground,
            now: Date()
        )
        codexWasForeground = codexIsForeground
        if let errorAt = errorUpdate.acknowledgeErrorAt {
            settings = settings.acknowledgingError(at: errorAt)
            settingsStore.save(settings)
            aggregate = SessionAggregator.aggregate(
                snapshots: allSnapshots(),
                settings: settings,
                recentFailure: codexActivitySnapshot.recentFailure,
                codexRunning: codexRunning,
                focusedAgent: settings.focusedAgent
            )
            aggregate = Self.standbyAggregate(
                aggregate: aggregate,
                hasLiveSession: hasLiveSessionForFocusedAgent(codexRunning: codexRunning)
            )
            applyRealtimeCodexActivity(codexActivitySnapshot.realtimeActivity)
        }
        haloView?.updateLiveAggregate(
            aggregate,
            errorPresentation: errorUpdate.presentation
        )
        refreshVisibleDetailsStatus()
        if statusItem != nil {
            updateStatusMenu()
        }
    }

    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.button?.image = StatusIcon.image()
        statusItem?.button?.toolTip = "Agent Halo"
    }

    private func applyMenuBarIconVisibility() {
        if settings.showMenuBarIcon {
            if statusItem == nil {
                lastStatusMenuSignature = nil
                createStatusItem()
            }
            updateStatusMenu()
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
            lastStatusMenuSignature = nil
        }
    }

    private func reconcileClaudeStatusLineConfiguration(now: Date) {
        guard settings.isAgentEnabled(.claudeCode) else { return }
        guard now >= nextStatusLineReconciliationAt else { return }
        nextStatusLineReconciliationAt = now.addingTimeInterval(statusLineReconciliationInterval)
        guard !ClaudeStatusLineConfigurator.isConfigured() else { return }
        ClaudeStatusLineConfigurator.configure()
    }

    private func createHaloPanel() {
        let origin = initialWindowOrigin()
        let haloSize = currentHaloSize
        haloView = HaloView(frame: NSRect(x: 0, y: 0, width: haloSize, height: haloSize))
        haloView.onDoubleClick = { [weak self] in
            self?.bringCodexForward()
        }
        haloView.onMoved = { [weak self] frame in
            self?.commitPreferredPlacement(frame: frame)
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
            selector: #selector(workspaceApplicationDidLaunch(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(workspaceApplicationDidTerminate(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
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

    @objc private func workspaceApplicationDidLaunch(_ notification: Notification) {
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        if CodexAppDetector.noteApplicationDidLaunch(app) {
            tick()
        }
    }

    @objc private func workspaceApplicationDidTerminate(_ notification: Notification) {
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        guard CodexAppDetector.noteApplicationDidTerminate(app) else { return }
        updateFrontmostApplication(NSWorkspace.shared.frontmostApplication)
        tick()
    }

    @objc private func workspaceApplicationDidActivate(_ notification: Notification) {
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        updateFrontmostApplication(app)
    }

    @objc private func workspaceActiveSpaceDidChange(_ notification: Notification) {
        updateFrontmostApplication(NSWorkspace.shared.frontmostApplication)
    }

    private func updateFrontmostApplication(_ app: NSRunningApplication?) {
        codexIsForeground = CodexAppDetector.isCodexForeground(app)
        updateSystemOverlaySuspension(for: app)
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
            haloView?.redrawRing()
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
        rebuildStatusMenuIfNeeded()
    }

    private func rebuildStatusMenuIfNeeded() {
        guard let statusItem else {
            return
        }
        let signature = StatusMenuSignature(
            settings: settings,
            selectedPreview: selectedPreview,
            startupEnabled: currentStartupEnabled()
        )
        if statusItem.menu != nil, lastStatusMenuSignature == signature {
            return
        }
        lastStatusMenuSignature = signature
        statusItem.menu = makeControlMenu()
    }

    private func currentStartupEnabled() -> Bool {
        let now = Date()
        if now < cachedStartupExpiresAt {
            return cachedStartupEnabled
        }
        cachedStartupEnabled = StartupManager.isEnabled()
        cachedStartupExpiresAt = now.addingTimeInterval(startupCheckInterval)
        return cachedStartupEnabled
    }

    private func makeControlMenu() -> NSMenu {
        let menu = NSMenu()
        addCheckItem(L10n.shared["menu.always_on_top"], checked: settings.alwaysOnTop, action: #selector(toggleAlwaysOnTop), to: menu)
        addCheckItem(L10n.shared["menu.pause_monitor"], checked: settings.paused, action: #selector(togglePause), to: menu)
        let focus = NSMenuItem(title: L10n.shared["menu.focus_target"], action: nil, keyEquivalent: "")
        let focusMenu = NSMenu()
        for agent in settings.enabledAgents {
            addFocusedAgentItem(agent, to: focusMenu)
        }
        focus.submenu = focusMenu
        menu.addItem(focus)

        addMenuItem(L10n.shared["menu.escape_offscreen"], #selector(escapeOffscreen), enabled: true, to: menu)
        let preview = NSMenuItem(title: L10n.shared["menu.preview_status"], action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        addPreviewItem(L10n.shared["halo.live_status"], state: nil, presentation: nil, to: submenu)
        addPreviewItem(L10n.shared["halo.thinking_preview"], state: .thinking, presentation: nil, to: submenu)
        addPreviewItem(L10n.shared["halo.working_preview"], state: .working, presentation: nil, to: submenu)
        addPreviewItem(L10n.shared["halo.done_preview"], state: .done, presentation: nil, to: submenu)
        addPreviewItem(L10n.shared["halo.attention_preview"], state: .attention, presentation: nil, to: submenu)
        addPreviewItem(L10n.shared["halo.error_flash_preview"], state: .error, presentation: .flashing, to: submenu)
        addPreviewItem(L10n.shared["halo.error_bright_preview"], state: .error, presentation: .bright, to: submenu)
        addPreviewItem(L10n.shared["halo.error_dim_preview"], state: .error, presentation: .dim, to: submenu)
        addPreviewItem(L10n.shared["halo.idle_preview"], state: .idle, presentation: nil, to: submenu)
        preview.submenu = submenu
        menu.addItem(preview)
        menu.addItem(.separator())
        addMenuItem(L10n.shared["menu.settings"], #selector(openSettings), enabled: true, to: menu)
        addMenuItem(L10n.shared["menu.quit"], #selector(quit), enabled: true, to: menu)
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

    @objc private func openSettings() {
        showSettings()
    }

    @objc private func escapeOffscreen() {
        let origin = defaultWindowOrigin(topOffset: 28)
        panel.setFrameOrigin(origin)
        commitPreferredPlacement(frame: panel.frame)
    }

    private func reconcileHaloPlacement() {
        guard let panel else {
            return
        }
        let displays = displaySnapshots()
        guard !displays.isEmpty else {
            return
        }

        if !settings.hasPosition {
            panel.setFrameOrigin(defaultWindowOrigin(topOffset: 28))
            commitPreferredPlacement(frame: panel.frame)
            return
        }

        if let resolved = HaloPlacementResolver.resolve(
            storedPreferredPlacement(),
            haloSize: currentHaloSize,
            displays: displays
        ) {
            panel.setFrameOrigin(resolved.origin)
            storeResolvedPlacement(resolved)
            placementState.didApplyPreferredPlacement()
            settingsStore.save(settings)
            return
        }

        panel.setFrameOrigin(defaultWindowOrigin(topOffset: 28))
        placementState.didUseTemporaryFallback()
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
        guard settings.isAgentEnabled(agent) else { return }
        guard settings.focusedAgent != agent else {
            tick()
            refreshVisibleDetailsPanel()
            if let providerID = Self.usageProviderID(for: agent) {
                requestUsageRefresh(for: providerID)
            }
            return
        }
        activateFocusedUsageProvider(agent)
        settings.focusedAgent = agent
        settingsStore.save(settings)
        switch agent {
        case .claudeCode:
            claudeActivityMonitor.requestRefresh()
        case .grok:
            grokActivityMonitor.requestRefresh()
        case .pi:
            piActivityMonitor.requestRefresh()
        case .codex:
            break
        }
        tick()
        refreshVisibleDetailsPanel()
        if let providerID = Self.usageProviderID(for: agent) {
            requestUsageRefresh(for: providerID)
        }
    }

    /// Test-only: replace enabledAgents and normalize (may re-focus).
    func applyEnabledAgentsForTesting(_ agents: [AgentKind]) {
        settings.enabledAgents = agents
        settings = settings.normalized()
    }

    /// Test-only: apply a full settings update through the settings-window path.
    func applySettingsFromWindowForTesting(_ next: HaloSettings) {
        applySettingsFromWindow(next)
    }

    /// Test-only: read current focus without exposing full settings.
    var focusedAgentForTesting: AgentKind { settings.focusedAgent }

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

    private func displaySnapshots() -> [HaloDisplaySnapshot] {
        NSScreen.screens.compactMap { screen in
            guard let identifier = HaloScreenIdentity.identifier(for: screen) else {
                return nil
            }
            return HaloDisplaySnapshot(identifier: identifier, visibleFrame: screen.visibleFrame)
        }
    }

    private func storedPreferredPlacement() -> HaloStoredPlacement {
        let relativeOffset: NSPoint?
        if let x = settings.preferredDisplayOffsetX,
           let y = settings.preferredDisplayOffsetY {
            relativeOffset = NSPoint(x: x, y: y)
        } else {
            relativeOffset = nil
        }
        return HaloStoredPlacement(
            displayIdentifier: settings.preferredDisplayUUID,
            absoluteOrigin: NSPoint(x: settings.left, y: settings.top),
            relativeOffset: relativeOffset
        )
    }

    private func commitPreferredPlacement(frame: NSRect, persist: Bool = true) {
        guard let captured = HaloPlacementResolver.capture(
            frame: frame,
            displays: displaySnapshots()
        ) else {
            return
        }
        settings.hasPosition = true
        settings.left = captured.absoluteOrigin.x
        settings.top = captured.absoluteOrigin.y
        settings.preferredDisplayUUID = captured.displayIdentifier
        settings.preferredDisplayOffsetX = captured.relativeOffset.map { Double($0.x) }
        settings.preferredDisplayOffsetY = captured.relativeOffset.map { Double($0.y) }
        placementState.didChoosePlacement()
        if persist {
            settingsStore.save(settings)
        }
    }

    private func storeResolvedPlacement(_ resolved: HaloResolvedPlacement) {
        settings.hasPosition = true
        settings.left = resolved.origin.x
        settings.top = resolved.origin.y
        settings.preferredDisplayUUID = resolved.display.identifier
        settings.preferredDisplayOffsetX = resolved.relativeOffset.x
        settings.preferredDisplayOffsetY = resolved.relativeOffset.y
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
        if placementState.shouldPersistCurrentFrame {
            commitPreferredPlacement(frame: frame, persist: false)
        }
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
            codexIsForeground ? codexSnapshots() : []
        )
        if updated.acknowledged != settings.acknowledged {
            settings = updated
            settingsStore.save(settings)
        }
    }

    private func codexSnapshots() -> [SessionSnapshot] {
        codexActivitySnapshot.sessions
    }

    private func claudeSnapshots() -> [SessionSnapshot] {
        claudeActivitySnapshot.mergedClaudeSnapshots
    }

    private func grokSnapshots() -> [SessionSnapshot] {
        grokActivitySnapshot.sessions
    }

    private func piSnapshots() -> [SessionSnapshot] {
        piActivitySnapshot.sessions
    }

    static func standbyAggregate(
        aggregate: AggregateSnapshot,
        hasLiveSession: Bool
    ) -> AggregateSnapshot {
        guard hasLiveSession,
              aggregate.state == .idle,
              aggregate.label == "OFFLINE" else {
            return aggregate
        }
        return AggregateSnapshot(
            state: .done,
            label: "STANDBY",
            detail: aggregate.focusedAgent.localizedStandbyDetail,
            sessions: [],
            focusedAgent: aggregate.focusedAgent
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
                recentFailure: codexActivitySnapshot.recentFailure,
                codexRunning: CodexAppDetector.isCodexRunning(),
                focusedAgent: settings.focusedAgent
            )
            applyRealtimeCodexActivity(codexActivitySnapshot.realtimeActivity)
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
        updateDetailsPanelContent(rawClaudeSnapshots: rawClaudeSnapshots)
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
        if let providerID = Self.usageProviderID(for: settings.focusedAgent) {
            requestUsageRefresh(for: providerID)
        }
    }

    private func updateDetailsPanelContent(rawClaudeSnapshots: [SessionSnapshot]? = nil) {
        let rawClaudeSnapshots = rawClaudeSnapshots
            ?? (settings.focusedAgent == .claudeCode ? claudeSnapshots() : [])
        let displayedAggregate = displayAggregate()
        let isOffline = displayedAggregate.state == .idle && displayedAggregate.label == "OFFLINE"
        let exactSessionDetails: SessionDetailsSnapshot
        let exactContextUsedPercent: Double?
        switch settings.focusedAgent {
        case .codex:
            let session = displayedAggregate.sessions.first
            exactSessionDetails = SessionDetailsSnapshot(
                projectName: session?.projectName,
                sessionTitle: session?.sessionTitle,
                modelName: session?.modelName,
                inputTokens: session?.inputTokens,
                outputTokens: session?.outputTokens
            )
            exactContextUsedPercent = session?.contextUsedPercent
        case .claudeCode:
            let claudeMainSessionId = Self.claudeMainSessionIdForDetails(
                displayedAggregate: displayedAggregate,
                rawClaudeSnapshots: rawClaudeSnapshots,
                liveSession: claudeActivitySnapshot.preferredStandbySession
            )
            let claudeUsageFreshness = Self.claudeUsageFreshness(
                mainSessionId: claudeMainSessionId,
                liveSessions: claudeActivitySnapshot.liveSessions
            )
            let claudeUsage = claudeMainSessionId.flatMap { sessionId in
                contextReaderQueue.sync {
                    claudeContextUsageReader.read(
                        sessionId: sessionId,
                        freshness: claudeUsageFreshness
                    )
                }
            }
            let resolved = ClaudeMainSessionDetailsResolver.resolve(
                mainSessionId: claudeMainSessionId,
                mainSessions: claudeActivitySnapshot.transcriptSnapshots,
                liveSession: claudeActivitySnapshot.preferredStandbySession,
                usage: claudeUsage
            )
            exactSessionDetails = resolved.sessionDetails
            // Statusline snapshots remain for live/standby sessions; only surface
            // the pill while the aggregate still displays this Claude session
            // (active turn or brief COMPLETE). STANDBY empties sessions — match
            // Codex/Grok so the pill soft-holds then drops instead of sticking.
            exactContextUsedPercent = Self.contextUsedPercentForClaudeDetails(
                displayedSessions: displayedAggregate.sessions,
                resolvedContextPercent: resolved.contextUsedPercent
            )
        case .grok:
            let context = readGrokSessionContext(displayedAggregate: displayedAggregate)
            let hookSession = displayedAggregate.sessions.first
            exactSessionDetails = SessionDetailsSnapshot(
                projectName: context?.projectName ?? hookSession?.projectName,
                sessionTitle: context?.sessionTitle ?? hookSession?.sessionTitle,
                modelName: context?.modelName ?? hookSession?.modelName
            )
            // Disk signals stay after Stop; only surface them while the aggregate
            // still displays this Grok session (active turn or brief COMPLETE).
            // STANDBY empties sessions by design — match Codex so the pill drops.
            exactContextUsedPercent = Self.contextUsedPercentForGrokDetails(
                displayedSessions: displayedAggregate.sessions,
                diskContextPercent: context?.contextUsedPercent
            )
        case .pi:
            // Extension records carry project/model/tokens/context. On STANDBY the
            // aggregate sessions list is empty; fall back to the latest live record.
            let session = displayedAggregate.sessions.first
                ?? piActivitySnapshot.preferredStandbySession
            exactSessionDetails = SessionDetailsSnapshot(
                projectName: session?.projectName,
                sessionTitle: session?.sessionTitle,
                modelName: session?.modelName,
                inputTokens: session?.inputTokens,
                outputTokens: session?.outputTokens
            )
            exactContextUsedPercent = Self.contextUsedPercentForPiDetails(
                displayedSessions: displayedAggregate.sessions,
                standbySession: piActivitySnapshot.preferredStandbySession,
                isStandby: displayedAggregate.label == "STANDBY"
            )
        }

        let model: DetailsPanelViewModel
        if let providerID = Self.usageProviderID(for: settings.focusedAgent) {
            let monitorState = usageStates[providerID]
                ?? UsageMonitorState(providerID: providerID, accessMode: .apiKey)
            model = DetailsContentResolver.resolve(
                providerID: providerID,
                monitorState: monitorState,
                isOffline: isOffline,
                sessionDetails: exactSessionDetails,
                contextUsedPercent: exactContextUsedPercent,
                now: Date()
            )
        } else {
            // Pi (and any future session-only agent): fixed session body, no OAuth windows.
            model = DetailsPanelViewModel(
                providerName: settings.focusedAgent.menuTitle,
                planName: nil,
                usageWarning: nil,
                contextUsedPercent: isOffline ? nil : exactContextUsedPercent,
                body: .session(isOffline ? SessionDetailsSnapshot() : exactSessionDetails)
            )
        }
        detailsPanel.render(aggregate: displayedAggregate, model: model)
    }

    /// Context pill for Claude is statusline-backed, but visibility must follow
    /// the aggregate the same way Codex/Grok do: only while a real Claude
    /// session is currently displayed. STANDBY/OFFLINE deliberately use empty
    /// `sessions` after COMPLETE settles — do not keep the pill up forever from
    /// a live idle session's last statusline snapshot.
    nonisolated static func contextUsedPercentForClaudeDetails(
        displayedSessions: [SessionSnapshot],
        resolvedContextPercent: Double?
    ) -> Double? {
        let hasVisibleClaudeSession = displayedSessions.contains {
            $0.agent == .claudeCode && $0.threadId != "claude-code" && !$0.threadId.isEmpty
        }
        guard hasVisibleClaudeSession else {
            return nil
        }
        return resolvedContextPercent
    }

    /// Context pill for Grok is disk-backed (`signals.json` / live `totalTokens`),
    /// but visibility must follow the aggregate the same way Codex does:
    /// only while a real Grok session is currently displayed. STANDBY/OFFLINE
    /// deliberately use empty `sessions` after COMPLETE settles — do not keep
    /// the pill up from frozen end-of-turn occupancy via hook/active fallbacks.
    nonisolated static func contextUsedPercentForGrokDetails(
        displayedSessions: [SessionSnapshot],
        diskContextPercent: Double?
    ) -> Double? {
        let hasVisibleGrokSession = displayedSessions.contains {
            $0.agent == .grok && $0.threadId != "grok" && !$0.threadId.isEmpty
        }
        guard hasVisibleGrokSession else {
            return nil
        }
        return diskContextPercent
    }

    /// Pi context comes from the extension record. While a turn is displayed
    /// (or STANDBY with a live PID), surface the latest known percent; OFFLINE
    /// clears via the caller.
    nonisolated static func contextUsedPercentForPiDetails(
        displayedSessions: [SessionSnapshot],
        standbySession: SessionSnapshot?,
        isStandby: Bool
    ) -> Double? {
        if let visible = displayedSessions.first(where: {
            $0.agent == .pi && !$0.threadId.isEmpty
        }) {
            return visible.contextUsedPercent
        }
        if isStandby {
            return standbySession?.contextUsedPercent
        }
        return nil
    }

    /// Prefer the hook/aggregate thread id, then the first live active_sessions entry.
    static func grokSessionIdentityForDetails(
        displayedAggregate: AggregateSnapshot,
        hookSessions: [SessionSnapshot],
        activeSessions: [GrokActiveSessionRef]
    ) -> (sessionId: String?, cwd: String?) {
        if let displayed = displayedAggregate.sessions.first(where: {
            $0.agent == .grok && $0.threadId != "grok" && !$0.threadId.isEmpty
        }) {
            let cwd = activeSessions.first(where: { $0.sessionId == displayed.threadId })?.cwd
                ?? (displayed.workingDirectory.isEmpty ? nil : displayed.workingDirectory)
            return (displayed.threadId, cwd)
        }
        if let hook = hookSessions
            .filter({ $0.threadId != "grok" && !$0.threadId.isEmpty })
            .max(by: { $0.lastEventAt < $1.lastEventAt }) {
            let cwd = activeSessions.first(where: { $0.sessionId == hook.threadId })?.cwd
                ?? (hook.workingDirectory.isEmpty ? nil : hook.workingDirectory)
            return (hook.threadId, cwd)
        }
        if let active = activeSessions.first {
            return (active.sessionId, active.cwd)
        }
        return (nil, nil)
    }

    static func claudeMainSessionIdForDetails(
        displayedAggregate: AggregateSnapshot,
        rawClaudeSnapshots: [SessionSnapshot],
        liveSession: ClaudeLiveSessionSnapshot?
    ) -> String? {
        if let displayed = displayedAggregate.sessions.first(where: { $0.threadId != "claude-code" }) {
            return displayed.threadId
        }
        if let liveSession {
            return liveSession.sessionId
        }
        return rawClaudeSnapshots
            .filter { $0.threadId != "claude-code" }
            .max { $0.lastEventAt < $1.lastEventAt }?
            .threadId
    }

    static func claudeUsageFreshness(
        mainSessionId: String?,
        liveSessions: [ClaudeLiveSessionSnapshot]
    ) -> ClaudeContextUsageFreshness {
        guard let mainSessionId,
              liveSessions.contains(where: { $0.sessionId == mainSessionId }) else {
            return .recentOnly
        }
        return .whileSessionIsLive
    }

    /// Official usage/quota providers only. Pi is session-detail only (nil).
    static func usageProviderID(for agent: AgentKind) -> UsageProviderID? {
        switch agent {
        case .codex:
            return .codex
        case .claudeCode:
            return .claude
        case .grok:
            return .grok
        case .pi:
            return nil
        }
    }

    private func startUsageRefreshLoop() {
        usageRefreshLoopTask?.cancel()
        let sleepNanoseconds = UInt64(usageRefreshInterval * 1_000_000_000)
        usageRefreshLoopTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: sleepNanoseconds)
                } catch {
                    return
                }
                guard let self, !Task.isCancelled else {
                    return
                }
                if let providerID = Self.usageProviderID(for: self.settings.focusedAgent) {
                    self.requestUsageRefresh(for: providerID)
                }
            }
        }
    }

    private func requestUsageRefresh(for providerID: UsageProviderID) {
        guard usageCoordinator.focusController.isActive(providerID) else {
            return
        }
        guard usageRequestTasks[providerID] == nil else {
            return
        }
        let token = UUID()
        let coordinator = usageCoordinator
        let task = Task { @MainActor [weak self] in
            defer { self?.clearUsageRequest(for: providerID, token: token) }
            let prepared = await coordinator.prepare(providerID)
            guard !Task.isCancelled,
                  coordinator.focusController.isActive(providerID)
            else {
                return
            }
            self?.publishUsageState(prepared, for: providerID)

            let refreshed = await coordinator.ensureFresh(providerID)
            guard !Task.isCancelled,
                  coordinator.focusController.isActive(providerID)
            else {
                return
            }
            self?.publishUsageState(refreshed, for: providerID)
        }
        usageRequestTasks[providerID] = UsageRequestRecord(token: token, task: task)
    }

    private func activateFocusedUsageProvider(_ agent: AgentKind) {
        guard let providerID = Self.usageProviderID(for: agent) else {
            usageCoordinator.focusController.deactivateAll()
            for key in usageRequestTasks.keys {
                usageRequestTasks[key]?.task.cancel()
                usageRequestTasks[key] = nil
            }
            return
        }
        usageCoordinator.focusController.activate(providerID)
        let inactiveProviderIDs = usageRequestTasks.keys.filter { $0 != providerID }
        for inactiveProviderID in inactiveProviderIDs {
            usageRequestTasks[inactiveProviderID]?.task.cancel()
            usageRequestTasks[inactiveProviderID] = nil
        }
    }

    private func clearUsageRequest(for providerID: UsageProviderID, token: UUID) {
        guard usageRequestTasks[providerID]?.token == token else {
            return
        }
        usageRequestTasks[providerID] = nil
    }

    private func publishUsageState(_ state: UsageMonitorState, for providerID: UsageProviderID) {
        usageStates[providerID] = state
        guard providerID == Self.usageProviderID(for: settings.focusedAgent),
              detailsPanel.isVisible else {
            return
        }
        updateDetailsPanelContent()
    }

    private func refreshVisibleDetailsPanel() {
        guard detailsPanel.isVisible else {
            return
        }
        updateDetailsPanelContent()
    }

    private func refreshVisibleDetailsStatus() {
        guard detailsPanel.isVisible else {
            return
        }
        detailsPanel.updateStatus(aggregate: displayAggregate())
        // Status-only path intentionally skips Grok/Claude context while active.
        // Re-read Grok disk occupancy on a 1s throttle so a panel opened before
        // the first totalTokens (or before signals.json exists) still lights up.
        refreshVisibleGrokContextPillIfNeeded()
    }

    private func refreshVisibleGrokContextPillIfNeeded(now: Date = Date()) {
        guard settings.focusedAgent == .grok else {
            return
        }
        guard now.timeIntervalSince(lastGrokContextRefreshAt) >= grokContextRefreshInterval else {
            return
        }
        lastGrokContextRefreshAt = now
        let displayedAggregate = displayAggregate()
        let context = readGrokSessionContext(displayedAggregate: displayedAggregate)
        let percent = Self.contextUsedPercentForGrokDetails(
            displayedSessions: displayedAggregate.sessions,
            diskContextPercent: context?.contextUsedPercent
        )
        detailsPanel.updateLiveContextPercent(percent, aggregate: displayedAggregate, now: now)
    }

    private func readGrokSessionContext(
        displayedAggregate: AggregateSnapshot
    ) -> GrokSessionContextSnapshot? {
        let activeSessions = GrokActiveSessionsReader.read()
        let (sessionId, cwd) = Self.grokSessionIdentityForDetails(
            displayedAggregate: displayedAggregate,
            hookSessions: grokActivitySnapshot.sessions,
            activeSessions: activeSessions
        )
        return sessionId.flatMap { id in
            contextReaderQueue.sync {
                grokSessionContextReader.read(sessionId: id, cwd: cwd)
            }
        }
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
        let scale = screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        let normalizedHeight = DetailsPanel.evenPanelHeight(
            for: detailsPanel.frame.height,
            backingScaleFactor: scale
        )
        if normalizedHeight != detailsPanel.frame.height {
            let currentFrame = detailsPanel.frame
            detailsPanel.applyResizeFrame(
                NSRect(
                    x: currentFrame.minX,
                    y: currentFrame.maxY - normalizedHeight,
                    width: currentFrame.width,
                    height: normalizedHeight
                ),
                display: false,
                animate: false
            )
        }
        var x = panel.frame.minX - detailsPanel.frame.width - gap
        if x < area.minX + 8 {
            x = panel.frame.maxX + gap
        }
        let y = max(area.minY + 8, min(panel.frame.midY - detailsPanel.frame.height / 2, area.maxY - detailsPanel.frame.height - 8))
        let clampedOrigin = CGPoint(
            x: max(area.minX + 8, min(x, area.maxX - detailsPanel.frame.width - 8)),
            y: y
        )
        detailsPanel.setFrameOrigin(Self.pixelAlignedOrigin(clampedOrigin, backingScaleFactor: scale))
        detailsPanel.contentView?.layoutSubtreeIfNeeded()
        detailsPanel.contentView?.displayIfNeeded()
    }

    static func pixelAlignedOrigin(_ origin: CGPoint, backingScaleFactor: CGFloat) -> CGPoint {
        let scale = backingScaleFactor > 0 ? backingScaleFactor : 1
        return CGPoint(
            x: (origin.x * scale).rounded() / scale,
            y: (origin.y * scale).rounded() / scale
        )
    }

    private func displayAggregate() -> AggregateSnapshot {
        aggregate
    }

    private func applyRealtimeCodexActivity(_ activity: CodexRealtimeActivity?) {
        guard settings.focusedAgent == .codex,
              let activity else {
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
        codexActivitySnapshot.sessions + claudeSnapshots() + grokSnapshots() + piSnapshots()
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

    nonisolated static func languageMenuItemState(
        itemLanguage: String?,
        savedLanguage: String?
    ) -> NSControl.StateValue {
        itemLanguage == savedLanguage ? .on : .off
    }

    nonisolated static func languagePreferenceAfterResolvedLanguageChange(
        savedLanguage: String?,
        currentLanguage: String,
        systemLanguage: String
    ) -> String? {
        savedLanguage
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
        settingsWindowController?.window?.level = NSWindow.Level(rawValue: level.rawValue + 1)
        if !systemOverlaySuspended {
            panel?.orderFrontRegardless()
        }
    }

    func showSettings() {
        if settingsWindowController == nil {
            let controller = SettingsWindowController()
            controller.onSettingsChanged = { [weak self] next in
                self?.applySettingsFromWindow(next)
            }
            controller.onLaunchAtLoginChanged = { enabled in
                StartupManager.setEnabled(enabled, appBundleURL: Bundle.main.bundleURL)
            }
            controller.onResetPosition = { [weak self] in
                self?.escapeOffscreen()
            }
            settingsWindowController = controller
        }
        settingsWindowController?.present(
            settings: settings,
            launchAtLogin: StartupManager.isEnabled()
        )
    }

    private func applySettingsFromWindow(_ next: HaloSettings) {
        let previous = settings
        settings = next.normalized()
        settingsStore.save(settings)
        if previous.haloSize != settings.haloSize {
            applyHaloSize(CGFloat(settings.haloSize))
        } else {
            settingsStore.save(settings)
        }
        if previous.language != settings.language {
            L10n.shared.setLanguage(settings.language)
        }
        applyWindowLevels()
        applyMenuBarIconVisibility()
        detailsPanel.setEnabledAgents(settings.enabledAgents, focused: settings.focusedAgent)
        if previous.focusedAgent != settings.focusedAgent {
            // settings already holds the remapped focus; restore previous so
            // setFocusedAgent sees a real change and activates usage providers.
            let target = settings.focusedAgent
            settings.focusedAgent = previous.focusedAgent
            setFocusedAgent(target)
        }
        for agent in AgentKind.allCases {
            let nowOn = settings.isAgentEnabled(agent)
            let wasOn = previous.isAgentEnabled(agent)
            if nowOn && !wasOn {
                switch agent {
                case .claudeCode: claudeActivityMonitor.requestRefresh()
                case .grok: grokActivityMonitor.requestRefresh()
                case .pi: piActivityMonitor.requestRefresh()
                case .codex: break
                }
            }
        }
        lastStatusMenuSignature = nil
        tick()
        settingsWindowController?.refresh(settings: settings, launchAtLogin: StartupManager.isEnabled())
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

    enum SystemOverlayHaloVisibility {
        case visible
    }
}
