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
    private var nextStatusLineReconciliationAt = Date.distantPast
    private let statusLineReconciliationInterval: TimeInterval = 2
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
    private var placementState = HaloPlacementRuntimeState()
    private let rateLimitReader = RateLimitReader()
    private let claudeContextUsageReader = ClaudeContextUsageReader()
    private let contextReaderQueue = DispatchQueue(
        label: "com.agenthalo.context-reader",
        qos: .userInteractive
    )
    private let instanceLock = InstanceLock()
    private let codexActivator: @MainActor () -> Void
    private var liveErrorPresentationState = LiveErrorPresentationState()
    private var codexWasForeground = false
    private var lastStatusMenuSignature: StatusMenuSignature?
    private var lastStatusIconState: HaloState?
    private var cachedStartupEnabled = false
    private var cachedStartupExpiresAt = Date.distantPast
    private let startupCheckInterval: TimeInterval = 2
    private var currentLanguage: String = "zh"
    private var languageObserver: NSObjectProtocol?
    private var currentHaloSize: CGFloat {
        CGFloat(settings.haloSize)
    }

    init(
        settingsStore: SettingsStore = SettingsStore(),
        codexActivator: @escaping @MainActor () -> Void = CodexAppDetector.activateCodex
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
        reconcileHaloPlacement()
        registerSystemOverlayObservers()
        updateSystemOverlaySuspension(for: NSWorkspace.shared.frontmostApplication)
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
        // Initialize L10n with user's saved preference
        L10n.shared.setLanguage(settings.language)
        currentLanguage = L10n.shared.currentLanguage

        // Observe language changes
        languageObserver = NotificationCenter.default.addObserver(
            forName: L10n.languageDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.currentLanguage = L10n.shared.currentLanguage
                // Persist preference
                self?.settings.language = L10n.shared.currentLanguage == L10n.detectSystemLanguage() ? nil : L10n.shared.currentLanguage
                self?.settingsStore.save(self!.settings)
                // Rebuild menu so all items show new language
                self?.lastStatusMenuSignature = nil
                self?.tick()
            }
        }
        tick()
        timer = Timer.scheduledTimer(timeInterval: 0.3, target: self, selector: #selector(timerDidFire), userInfo: nil, repeats: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        codexActivityMonitor.stop()
        claudeActivityMonitor.stop()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        settingsSaveTimer?.invalidate()
        if placementState.shouldPersistCurrentFrame, let panel {
            commitPreferredPlacement(frame: panel.frame, persist: false)
        }
        settingsStore.save(settings)
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
        reconcileClaudeStatusLineConfiguration(now: now)
        updateSystemOverlaySuspension(for: NSWorkspace.shared.frontmostApplication)
        acknowledgeCompletedIfCodexIsForeground()
        let codexRunning = CodexAppDetector.isCodexRunning()
        codexActivityMonitor.updatePollingContext(
            focusedAgent: settings.focusedAgent,
            codexRunning: codexRunning
        )
        claudeActivityMonitor.updatePollingContext(
            focusedAgent: settings.focusedAgent,
            detailsPanelVisible: detailsPanel.isVisible
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

    private func codexActivityDidChange(_ snapshot: CodexActivitySnapshot) {
        guard haloView?.isDragging != true else {
            codexActivitySnapshot = snapshot
            return
        }
        codexActivitySnapshot = snapshot
        let codexRunning = CodexAppDetector.isCodexRunning()
        codexActivityMonitor.updatePollingContext(
            focusedAgent: settings.focusedAgent,
            codexRunning: codexRunning
        )
        refreshAggregateAndUI(now: Date(), codexRunning: codexRunning)
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
            hasLiveSession: settings.focusedAgent == .codex
                ? codexRunning
                : claudeActivitySnapshot.preferredStandbySession != nil
        )
        applyRealtimeCodexActivity(codexActivitySnapshot.realtimeActivity)
        let codexIsForeground = CodexAppDetector.isCodexForeground()
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
                hasLiveSession: settings.focusedAgent == .codex
                    ? codexRunning
                    : claudeActivitySnapshot.preferredStandbySession != nil
            )
            applyRealtimeCodexActivity(codexActivitySnapshot.realtimeActivity)
        }
        haloView?.updateLiveAggregate(
            aggregate,
            errorPresentation: errorUpdate.presentation
        )
        refreshVisibleDetailsPanel()
        if !systemOverlaySuspended {
            haloView?.redrawRing()
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

    private func reconcileClaudeStatusLineConfiguration(now: Date) {
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
        updateStatusIcon()
    }

    private func updateStatusIcon() {
        guard let statusItem else {
            return
        }
        if lastStatusIconState == aggregate.state {
            return
        }
        lastStatusIconState = aggregate.state
        let rgb = HaloVisualModel.stateColor(aggregate.state)
        let color = NSColor(calibratedRed: rgb.red / 255, green: rgb.green / 255, blue: rgb.blue / 255, alpha: 1)
        statusItem.button?.image = StatusIcon.image(color: color)
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
        addCheckItem(L10n.shared["menu.launch_at_startup"], checked: currentStartupEnabled(), action: #selector(toggleStartup), to: menu)
        addCheckItem(L10n.shared["menu.pause_monitor"], checked: settings.paused, action: #selector(togglePause), to: menu)
        addHaloSizeItem(to: menu)
        let focus = NSMenuItem(title: L10n.shared["menu.focus_target"], action: nil, keyEquivalent: "")
        let focusMenu = NSMenu()
        addFocusedAgentItem(.codex, to: focusMenu)
        addFocusedAgentItem(.claudeCode, to: focusMenu)
        focus.submenu = focusMenu
        menu.addItem(focus)

        // Language submenu
        let languageItem = NSMenuItem(title: L10n.shared["menu.language"], action: nil, keyEquivalent: "")
        let languageMenu = NSMenu()
        addLanguageItem(nil, to: languageMenu)           // Follow System
        addLanguageItem("zh", to: languageMenu)           // 中文
        addLanguageItem("en", to: languageMenu)           // English
        languageItem.submenu = languageMenu
        menu.addItem(languageItem)

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

    @objc private func toggleStartup() {
        StartupManager.setEnabled(!StartupManager.isEnabled(), appBundleURL: Bundle.main.bundleURL)
        cachedStartupExpiresAt = .distantPast
        tick()
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
        if agent == .claudeCode {
            claudeActivityMonitor.requestRefresh()
        }
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
            CodexAppDetector.isCodexForeground() ? codexSnapshots() : []
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
    }

    private func updateDetailsPanelContent(rawClaudeSnapshots: [SessionSnapshot]? = nil) {
        let rawClaudeSnapshots = rawClaudeSnapshots
            ?? (settings.focusedAgent == .claudeCode ? claudeSnapshots() : [])
        let displayedAggregate = displayAggregate()
        let quota = settings.focusedAgent == .codex ? rateLimitReader.read() : nil
        let claudeMainSessionId = settings.focusedAgent == .claudeCode
            ? Self.claudeMainSessionIdForDetails(
                displayedAggregate: displayedAggregate,
                rawClaudeSnapshots: rawClaudeSnapshots,
                liveSession: claudeActivitySnapshot.preferredStandbySession
            )
            : nil
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
        let presentation = Self.detailsPresentationForDetails(
            focusedAgent: settings.focusedAgent,
            displayedAggregate: displayedAggregate,
            claudeMainSessionId: claudeMainSessionId,
            mainClaudeSessions: claudeActivitySnapshot.transcriptSnapshots,
            liveClaudeSession: claudeActivitySnapshot.preferredStandbySession,
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

    static func detailsPresentationForDetails(
        focusedAgent: AgentKind,
        displayedAggregate: AggregateSnapshot,
        claudeMainSessionId: String?,
        mainClaudeSessions: [SessionSnapshot],
        liveClaudeSession: ClaudeLiveSessionSnapshot?,
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
            let resolved = ClaudeMainSessionDetailsResolver.resolve(
                mainSessionId: claudeMainSessionId,
                mainSessions: mainClaudeSessions,
                liveSession: liveClaudeSession,
                usage: claudeUsage
            )
            return DetailsPresentation(
                sessionDetails: resolved.sessionDetails,
                showsQuota: false,
                contextUsedPercent: resolved.contextUsedPercent
            )
        }
    }

    private func refreshVisibleDetailsPanel() {
        guard detailsPanel.isVisible else {
            return
        }
        updateDetailsPanelContent()
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
        codexActivitySnapshot.sessions + claudeSnapshots()
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
        let item = NSMenuItem(title: L10n.shared["halo.size"], action: nil, keyEquivalent: "")
        let container = NSView(frame: NSRect(x: 0, y: 0, width: haloSizeMenuWidth, height: haloSizeMenuHeight))
        let label = NSTextField(labelWithString: L10n.shared["halo.size"])
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

    private func addLanguageItem(_ lang: String?, to menu: NSMenu) {
        let title: String
        if let lang {
            // lang is a language code like "zh" or "en"
            title = L10n.shared["menu.language.\(lang)"]
        } else {
            title = L10n.shared["menu.language.auto"]
        }
        let item = NSMenuItem(title: title, action: #selector(selectLanguage(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = lang as NSString?
        // Checkmark: nil = follow system
        let effectiveLanguage = settings.language ?? L10n.detectSystemLanguage()
        item.state = (lang == effectiveLanguage) ? .on : .off
        menu.addItem(item)
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        let lang = sender.representedObject as? String  // nil = follow system
        settings.language = lang
        settingsStore.save(settings)
        L10n.shared.setLanguage(lang)
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

    enum SystemOverlayHaloVisibility {
        case visible
    }
}
