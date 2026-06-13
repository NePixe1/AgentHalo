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

    override init() {
        self.settings = settingsStore.load()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        createStatusItem()
        createHaloPanel()
        tick()
        timer = Timer.scheduledTimer(
            timeInterval: 0.35,
            target: self,
            selector: #selector(timerDidFire),
            userInfo: nil,
            repeats: true
        )
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
            settings: settings
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
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.orderFrontRegardless()
    }

    private func initialWindowOrigin() -> CGPoint {
        if settings.hasPosition {
            return CGPoint(x: settings.left, y: settings.top)
        }
        let frame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return CGPoint(x: frame.maxX - haloSize - 36, y: frame.maxY - haloSize - 36)
    }

    private func updateStatusMenu() {
        let menu = NSMenu()
        let status = NSMenuItem(title: "\(aggregate.label) - \(aggregate.detail)", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        let pause = NSMenuItem(
            title: settings.paused ? "Resume Monitoring" : "Pause Monitoring",
            action: #selector(togglePause),
            keyEquivalent: ""
        )
        pause.target = self
        menu.addItem(pause)

        let bring = NSMenuItem(title: "Bring Codex Forward", action: #selector(bringCodexForward), keyEquivalent: "")
        bring.target = self
        menu.addItem(bring)

        let dismissCompleted = NSMenuItem(
            title: "Dismiss Completed",
            action: #selector(dismissCompleted),
            keyEquivalent: ""
        )
        dismissCompleted.target = self
        dismissCompleted.isEnabled = aggregate.sessions.contains { $0.state == .done }
        menu.addItem(dismissCompleted)

        let recenter = NSMenuItem(title: "Recenter Halo", action: #selector(recenterHalo), keyEquivalent: "")
        recenter.target = self
        menu.addItem(recenter)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Agent Halo", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
        statusItem.button?.image = StatusIcon.image(color: haloView.colorForCurrentState())
    }

    @objc private func togglePause() {
        settings.paused.toggle()
        tick()
    }

    @objc private func bringCodexForward() {
        let apps = NSWorkspace.shared.runningApplications.filter { app in
            let bundle = app.bundleIdentifier?.lowercased() ?? ""
            let name = app.localizedName?.lowercased() ?? ""
            return bundle.contains("codex") || name.contains("codex")
        }
        apps.first?.activate(options: [.activateIgnoringOtherApps])
    }

    @objc private func dismissCompleted() {
        settings = settings.acknowledgingCompletedSessions(aggregate.sessions)
        settingsStore.save(settings)
        tick()
    }

    @objc private func recenterHalo() {
        let frame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = CGPoint(x: frame.maxX - haloSize - 36, y: frame.maxY - haloSize - 36)
        panel.setFrameOrigin(origin)
        settings.left = origin.x
        settings.top = origin.y
        settings.hasPosition = true
        settingsStore.save(settings)
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
            isCodexForeground() ? monitor.snapshots() : []
        )
        if updated.acknowledged != settings.acknowledged {
            settings = updated
            settingsStore.save(settings)
        }
    }

    private func isCodexForeground() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return false
        }
        let bundle = app.bundleIdentifier?.lowercased() ?? ""
        let name = app.localizedName?.lowercased() ?? ""
        return bundle.contains("codex") || name.contains("codex")
    }
}
