import Foundation
import AgentHaloCore

// Cached Grok lifecycle state produced on a background queue. The main thread
// only reads this snapshot; hook JSONL parsing and presence probes stay off the
// main tick.
struct GrokActivitySnapshot: Equatable, Sendable {
    var sessions: [SessionSnapshot]
    /// True when Grok appears live via `~/.grok/active_sessions.json` (and live
    /// PIDs when present). Drives STANDBY vs OFFLINE when hooks are idle.
    var isPresent: Bool

    static let empty = GrokActivitySnapshot(sessions: [], isPresent: false)
}

// Mirrors ClaudeActivityMonitor: Grok hook polling runs on a utility queue so
// the main tick only reads cached snapshots. Cadence is active when Grok is
// focused or the details panel is visible, idle otherwise. Dispatch is
// throttled so burst hook changes coalesce into one onChange per window.
//
// No click-to-activate terminal path — presence only drives STANDBY vs OFFLINE.
// Presence must stay filesystem-cheap: never spawn `ps` / Process on this queue
// (a hung subprocess freezes hooks and leaves the ring stuck on STANDBY).
final class GrokActivityMonitor: @unchecked Sendable {
    private struct PollingContext: Equatable {
        var focusedAgent: AgentKind = .codex
        var detailsPanelVisible = false
        var enabled = true
    }

    private static let activeIntervalMilliseconds = 300
    private static let idleIntervalMilliseconds = 2_000
    private static let dispatchThrottleSeconds: TimeInterval = 0.3
    // Presence probes only read `active_sessions.json` (+ cheap kill(0)).
    // Refresh when hooks change or this safety interval elapses so the active
    // 0.3s poll stays cheap when nothing moved.
    private static let presencePollIntervalSeconds: TimeInterval = 2

    private let queue = DispatchQueue(label: "com.agenthalo.grok-activity", qos: .utility)
    private let stateLock = NSLock()
    private let hookMonitor: GrokHookStatusMonitor
    private let homeDirectory: URL
    private let fileManager: FileManager
    /// Optional test override. Production default is always false — presence
    /// comes from `active_sessions.json` only (see `isPresent`).
    private let processPresenceProbe: () -> Bool
    private var timer: DispatchSourceTimer?
    private var currentIntervalMilliseconds = GrokActivityMonitor.activeIntervalMilliseconds
    private var latestSnapshot = GrokActivitySnapshot.empty
    private var context = PollingContext()
    private var contextGeneration: UInt64 = 0
    private var onChange: (@Sendable (GrokActivitySnapshot) -> Void)?
    private var pendingSnapshot: GrokActivitySnapshot?
    private var pendingSnapshotGeneration: UInt64?
    private var pendingDispatchWorkItem: DispatchWorkItem?
    private var lastDispatchAt = Date.distantPast
    private var cachedIsPresent = false
    private var cachedLiveSessionIds: Set<String> = []
    private var cachedHasUnscopedPresence = false
    private var lastPresencePollAt = Date.distantPast
    private let pollBarrier: (@Sendable () -> Void)?
    private let preDispatchBarrier: (@Sendable () -> Void)?
    private let callbackDispatch: @Sendable (@escaping @Sendable () -> Void) -> Void

    init(
        hookMonitor: GrokHookStatusMonitor = GrokHookStatusMonitor(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        processPresenceProbe: @escaping () -> Bool = { false },
        pollBarrier: (@Sendable () -> Void)? = nil,
        preDispatchBarrier: (@Sendable () -> Void)? = nil,
        callbackDispatch: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void = {
            DispatchQueue.main.async(execute: $0)
        }
    ) {
        self.hookMonitor = hookMonitor
        self.homeDirectory = homeDirectory
        self.fileManager = fileManager
        self.processPresenceProbe = processPresenceProbe
        self.pollBarrier = pollBarrier
        self.preDispatchBarrier = preDispatchBarrier
        self.callbackDispatch = callbackDispatch
    }

    func start(onChange: @escaping @Sendable (GrokActivitySnapshot) -> Void) {
        stateLock.lock()
        self.onChange = onChange
        let generation = contextGeneration
        stateLock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            guard self.isCurrent(generation: generation, enabled: true) else { return }
            guard self.timer == nil else {
                return
            }
            self.scheduleTimer(intervalMilliseconds: Self.activeIntervalMilliseconds)
        }
    }

    func stop() {
        stateLock.lock()
        contextGeneration &+= 1
        context.enabled = false
        onChange = nil
        stateLock.unlock()
        queue.sync {
            timer?.cancel()
            timer = nil
            pendingDispatchWorkItem?.cancel()
            pendingDispatchWorkItem = nil
            pendingSnapshot = nil
            pendingSnapshotGeneration = nil
        }
    }

    func updatePollingContext(focusedAgent: AgentKind, detailsPanelVisible: Bool, enabled: Bool) {
        let nextContext = PollingContext(
            focusedAgent: focusedAgent,
            detailsPanelVisible: detailsPanelVisible,
            enabled: enabled
        )
        stateLock.lock()
        let wasEnabled = context.enabled
        if context != nextContext {
            context = nextContext
            contextGeneration &+= 1
        }
        let generation = contextGeneration
        let shouldPublishEmpty = !enabled && (wasEnabled || latestSnapshot != .empty)
        if !enabled {
            latestSnapshot = .empty
        }
        stateLock.unlock()

        if !enabled {
            queue.async { [weak self] in
                guard let self,
                      self.isCurrent(generation: generation, enabled: false) else { return }
                self.cancelTimerAndPending()
            }
            if shouldPublishEmpty {
                publishOnMain(.empty, generation: generation, enabled: false)
            }
            return
        }

        queue.async { [weak self] in
            guard let self else { return }
            guard self.isCurrent(generation: generation, enabled: true) else { return }
            let desired = (focusedAgent == .grok || detailsPanelVisible)
                ? Self.activeIntervalMilliseconds
                : Self.idleIntervalMilliseconds
            if self.timer == nil {
                self.scheduleTimer(intervalMilliseconds: desired)
                self.poll(forcePresence: true)
            } else if desired != self.currentIntervalMilliseconds {
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
        stateLock.lock()
        defer { stateLock.unlock() }
        return latestSnapshot
    }

    private func isCurrent(generation: UInt64, enabled: Bool) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return contextGeneration == generation && context.enabled == enabled
    }

    private func cancelTimerAndPending() {
        timer?.cancel()
        timer = nil
        pendingDispatchWorkItem?.cancel()
        pendingDispatchWorkItem = nil
        pendingSnapshot = nil
        pendingSnapshotGeneration = nil
        lastDispatchAt = Date()
    }

    private func publishOnMain(
        _ snapshot: GrokActivitySnapshot,
        generation: UInt64,
        enabled: Bool
    ) {
        callbackDispatch { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            guard self.contextGeneration == generation,
                  self.context.enabled == enabled,
                  let onChange = self.onChange else {
                self.stateLock.unlock()
                return
            }
            self.stateLock.unlock()
            onChange(snapshot)
        }
    }

    /// Prefer live entries in `~/.grok/active_sessions.json` (PID-checked when
    /// present; entries without a pid still count). Optional
    /// `processPresenceProbe` is a test-only override — production never
    /// shells out to `ps`.
    static func isPresent(
        homeDirectory: URL,
        fileManager: FileManager = .default,
        processPresenceProbe: () -> Bool = { false }
    ) -> Bool {
        if GrokActiveSessionsReader.hasLiveSession(
            homeDirectory: homeDirectory,
            fileManager: fileManager
        ) {
            return true
        }
        return processPresenceProbe()
    }

    static func hasActiveSessionsFile(
        homeDirectory: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        !GrokActiveSessionsReader.read(
            homeDirectory: homeDirectory,
            fileManager: fileManager
        ).isEmpty
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
        stateLock.lock()
        guard context.enabled else {
            stateLock.unlock()
            return
        }
        let generation = contextGeneration
        stateLock.unlock()
        pollBarrier?()
        guard isCurrent(generation: generation, enabled: true) else { return }
        let now = Date()
        let hookChanged = hookMonitor.refresh(now: now)
        let sessions = hookMonitor.snapshots()

        if forcePresence
            || hookChanged
            || now.timeIntervalSince(lastPresencePollAt) >= Self.presencePollIntervalSeconds {
            lastPresencePollAt = now
            cachedLiveSessionIds = GrokActiveSessionsReader.liveSessionIds(
                homeDirectory: homeDirectory,
                fileManager: fileManager
            )
            cachedHasUnscopedPresence = cachedLiveSessionIds.isEmpty && processPresenceProbe()
            cachedIsPresent = !cachedLiveSessionIds.isEmpty || cachedHasUnscopedPresence
        }

        let verifiedSessions = Self.sessionsWithVerifiedLiveness(
            sessions,
            liveSessionIds: cachedLiveSessionIds,
            hasUnscopedPresence: cachedHasUnscopedPresence
        )
        let nextSnapshot = GrokActivitySnapshot(
            sessions: verifiedSessions,
            isPresent: cachedIsPresent
        )
        stateLock.lock()
        guard context.enabled, contextGeneration == generation else {
            stateLock.unlock()
            return
        }
        guard nextSnapshot != latestSnapshot else {
            stateLock.unlock()
            return
        }
        latestSnapshot = nextSnapshot
        stateLock.unlock()
        preDispatchBarrier?()
        scheduleDispatch(of: nextSnapshot, now: now, generation: generation)
    }

    static func sessionsWithVerifiedLiveness(
        _ sessions: [SessionSnapshot],
        liveSessionIds: Set<String>,
        hasUnscopedPresence: Bool = false
    ) -> [SessionSnapshot] {
        sessions.map { snapshot in
            guard snapshot.active, !hasUnscopedPresence else {
                return snapshot
            }
            var verified = snapshot
            let hasMatchingSession = liveSessionIds.contains(snapshot.threadId)
                || (snapshot.threadId == "grok" && !liveSessionIds.isEmpty)
            if !hasMatchingSession {
                verified.active = false
            }
            return verified
        }
    }

    private func scheduleDispatch(
        of snapshot: GrokActivitySnapshot,
        now: Date,
        generation: UInt64
    ) {
        let elapsed = now.timeIntervalSince(lastDispatchAt)
        if elapsed >= Self.dispatchThrottleSeconds {
            lastDispatchAt = now
            pendingSnapshot = nil
            pendingSnapshotGeneration = nil
            pendingDispatchWorkItem?.cancel()
            pendingDispatchWorkItem = nil
            publishOnMain(snapshot, generation: generation, enabled: true)
            return
        }
        pendingSnapshot = snapshot
        pendingSnapshotGeneration = generation
        guard pendingDispatchWorkItem == nil else { return }
        let remaining = max(0, Self.dispatchThrottleSeconds - elapsed)
        let deadline = DispatchTime.now() + .milliseconds(Int(remaining * 1000))
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingDispatchWorkItem = nil
            guard let pending = self.pendingSnapshot,
                  let generation = self.pendingSnapshotGeneration else { return }
            self.pendingSnapshot = nil
            self.pendingSnapshotGeneration = nil
            self.lastDispatchAt = Date()
            self.publishOnMain(pending, generation: generation, enabled: true)
        }
        pendingDispatchWorkItem = work
        queue.asyncAfter(deadline: deadline, execute: work)
    }
}
