import Foundation
import AgentHaloCore

// Cached Grok lifecycle state produced on a background queue. The main thread
// only reads this snapshot; hook JSONL parsing and presence probes stay off the
// main tick.
struct GrokActivitySnapshot: Equatable, Sendable {
    var sessions: [SessionSnapshot]
    /// True when Grok appears live: non-empty `~/.grok/active_sessions.json`
    /// (preferred) or a process whose name contains `grok`.
    var isPresent: Bool

    static let empty = GrokActivitySnapshot(sessions: [], isPresent: false)
}

// Mirrors ClaudeActivityMonitor: Grok hook polling runs on a utility queue so
// the main tick only reads cached snapshots. Cadence is active when Grok is
// focused or the details panel is visible, idle otherwise. Dispatch is
// throttled so burst hook changes coalesce into one onChange per window.
//
// No click-to-activate terminal path — presence only drives STANDBY vs OFFLINE.
final class GrokActivityMonitor: @unchecked Sendable {
    private struct PollingContext: Equatable {
        var focusedAgent: AgentKind = .codex
        var detailsPanelVisible = false
    }

    private static let activeIntervalMilliseconds = 300
    private static let idleIntervalMilliseconds = 2_000
    private static let dispatchThrottleSeconds: TimeInterval = 0.3
    // Presence probes hit the filesystem (and optionally process list). Refresh
    // only when hooks change or this safety interval elapses so the active
    // 0.3s poll stays cheap when nothing moved.
    private static let presencePollIntervalSeconds: TimeInterval = 2

    private let queue = DispatchQueue(label: "com.agenthalo.grok-activity", qos: .utility)
    private let hookMonitor: GrokHookStatusMonitor
    private let homeDirectory: URL
    private let fileManager: FileManager
    private let processPresenceProbe: () -> Bool
    private var timer: DispatchSourceTimer?
    private var currentIntervalMilliseconds = GrokActivityMonitor.activeIntervalMilliseconds
    private var latestSnapshot = GrokActivitySnapshot.empty
    private var context = PollingContext()
    private var onChange: (@Sendable (GrokActivitySnapshot) -> Void)?
    private var pendingSnapshot: GrokActivitySnapshot?
    private var pendingDispatchWorkItem: DispatchWorkItem?
    private var lastDispatchAt = Date.distantPast
    private var cachedIsPresent = false
    private var lastPresencePollAt = Date.distantPast

    init(
        hookMonitor: GrokHookStatusMonitor = GrokHookStatusMonitor(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        processPresenceProbe: @escaping () -> Bool = GrokActivityMonitor.defaultProcessPresenceProbe
    ) {
        self.hookMonitor = hookMonitor
        self.homeDirectory = homeDirectory
        self.fileManager = fileManager
        self.processPresenceProbe = processPresenceProbe
    }

    func start(onChange: @escaping @Sendable (GrokActivitySnapshot) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.onChange = onChange
            guard self.timer == nil else {
                return
            }
            self.scheduleTimer(intervalMilliseconds: Self.activeIntervalMilliseconds)
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            onChange = nil
            pendingDispatchWorkItem?.cancel()
            pendingDispatchWorkItem = nil
            pendingSnapshot = nil
        }
    }

    func updatePollingContext(focusedAgent: AgentKind, detailsPanelVisible: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.context = PollingContext(
                focusedAgent: focusedAgent,
                detailsPanelVisible: detailsPanelVisible
            )
            let desired = (focusedAgent == .grok || detailsPanelVisible)
                ? Self.activeIntervalMilliseconds
                : Self.idleIntervalMilliseconds
            if self.timer != nil, desired != self.currentIntervalMilliseconds {
                self.scheduleTimer(intervalMilliseconds: desired)
            }
        }
    }

    func requestRefresh() {
        queue.async { [weak self] in
            self?.poll(forcePresence: true)
        }
    }

    func snapshot() -> GrokActivitySnapshot {
        queue.sync {
            latestSnapshot
        }
    }

    /// Prefer non-empty `~/.grok/active_sessions.json`; fall back to process probe.
    static func isPresent(
        homeDirectory: URL,
        fileManager: FileManager = .default,
        processPresenceProbe: () -> Bool = defaultProcessPresenceProbe
    ) -> Bool {
        if hasActiveSessionsFile(homeDirectory: homeDirectory, fileManager: fileManager) {
            return true
        }
        return processPresenceProbe()
    }

    static func hasActiveSessionsFile(
        homeDirectory: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        let url = homeDirectory
            .appendingPathComponent(".grok", isDirectory: true)
            .appendingPathComponent("active_sessions.json")
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              !data.isEmpty else {
            return false
        }
        // Primary shape is a JSON array of session objects.
        if let array = try? JSONSerialization.jsonObject(with: data) as? [Any] {
            return !array.isEmpty
        }
        // Tolerate an object wrapper: {"sessions":[...]} if Grok evolves.
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let sessions = root["sessions"] as? [Any] {
                return !sessions.isEmpty
            }
            if let sessions = root["active_sessions"] as? [Any] {
                return !sessions.isEmpty
            }
        }
        return false
    }

    static func defaultProcessPresenceProbe() -> Bool {
        // Lightweight process-table scan: any command name containing "grok"
        // (e.g. `grok`, `grok-build`). Avoids AppKit so this can run on the
        // utility queue without main-thread affinity.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "comm="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else {
            return false
        }
        return text.split(whereSeparator: \.isNewline).contains { line in
            let name = line.split(separator: "/").last.map(String.init) ?? String(line)
            return name.lowercased().contains("grok")
        }
    }

    private func scheduleTimer(intervalMilliseconds: Int) {
        timer?.cancel()
        let next = DispatchSource.makeTimerSource(queue: queue)
        let leeway = max(50, intervalMilliseconds / 3)
        next.schedule(
            deadline: .now(),
            repeating: .milliseconds(intervalMilliseconds),
            leeway: .milliseconds(leeway)
        )
        next.setEventHandler { [weak self] in
            self?.poll()
        }
        timer = next
        currentIntervalMilliseconds = intervalMilliseconds
        next.resume()
    }

    private func poll(forcePresence: Bool = false) {
        let now = Date()
        let hookChanged = hookMonitor.refresh(now: now)
        let sessions = hookMonitor.snapshots()

        if forcePresence
            || hookChanged
            || now.timeIntervalSince(lastPresencePollAt) >= Self.presencePollIntervalSeconds {
            lastPresencePollAt = now
            cachedIsPresent = Self.isPresent(
                homeDirectory: homeDirectory,
                fileManager: fileManager,
                processPresenceProbe: processPresenceProbe
            )
        }

        let nextSnapshot = GrokActivitySnapshot(
            sessions: sessions,
            isPresent: cachedIsPresent
        )
        guard nextSnapshot != latestSnapshot else {
            return
        }
        latestSnapshot = nextSnapshot
        scheduleDispatch(of: nextSnapshot, now: now)
    }

    private func scheduleDispatch(of snapshot: GrokActivitySnapshot, now: Date) {
        let elapsed = now.timeIntervalSince(lastDispatchAt)
        if elapsed >= Self.dispatchThrottleSeconds {
            lastDispatchAt = now
            pendingSnapshot = nil
            pendingDispatchWorkItem?.cancel()
            pendingDispatchWorkItem = nil
            if let onChange {
                let snapshot = snapshot
                DispatchQueue.main.async {
                    onChange(snapshot)
                }
            }
            return
        }
        pendingSnapshot = snapshot
        guard pendingDispatchWorkItem == nil else { return }
        let remaining = max(0, Self.dispatchThrottleSeconds - elapsed)
        let deadline = DispatchTime.now() + .milliseconds(Int(remaining * 1000))
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingDispatchWorkItem = nil
            guard let pending = self.pendingSnapshot else { return }
            self.pendingSnapshot = nil
            self.lastDispatchAt = Date()
            if let onChange = self.onChange {
                let snapshot = pending
                DispatchQueue.main.async {
                    onChange(snapshot)
                }
            }
        }
        pendingDispatchWorkItem = work
        queue.asyncAfter(deadline: deadline, execute: work)
    }
}
