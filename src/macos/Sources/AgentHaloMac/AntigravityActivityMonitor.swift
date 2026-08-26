import Darwin
import Foundation
import AgentHaloCore

// Cached Antigravity lifecycle state produced on a background queue. The main
// thread only reads this snapshot; hook JSONL parsing and presence probes stay
// off the main tick.
struct AntigravityActivitySnapshot: Equatable, Sendable {
    var sessions: [SessionSnapshot]
    /// True when a retained hook snapshot is inside the 600s/300s windows, or
    /// a process named exactly `agy` / `Antigravity` is running. Drives
    /// STANDBY vs OFFLINE.
    var isPresent: Bool

    static let empty = AntigravityActivitySnapshot(sessions: [], isPresent: false)
}

// Mirrors GrokActivityMonitor: hook polling runs on a utility queue so the
// main tick only reads cached snapshots. Cadence is active when Antigravity
// is focused or the details panel is visible, idle otherwise. Dispatch is
// throttled so burst hook changes coalesce into one onChange per window.
//
// No click-to-activate path. Presence is recent hook snapshots or an exact
// `agy` / `Antigravity` process name — never `language_server` or helpers.
final class AntigravityActivityMonitor: @unchecked Sendable {
    private struct PollingContext: Equatable {
        var focusedAgent: AgentKind = .codex
        var detailsPanelVisible = false
        var enabled = true
    }

    private static let activeIntervalMilliseconds = 300
    private static let idleIntervalMilliseconds = 2_000
    private static let dispatchThrottleSeconds: TimeInterval = 0.3
    private static let presencePollIntervalSeconds: TimeInterval = 2

    private let queue = DispatchQueue(label: "com.agenthalo.antigravity-activity", qos: .utility)
    private let stateLock = NSLock()
    private let hookMonitor: AntigravityHookStatusMonitor
    /// Production default scans for `agy` or the `Antigravity` desktop app.
    /// Tests inject.
    private let processPresenceProbe: () -> Bool
    private var timer: DispatchSourceTimer?
    private var currentIntervalMilliseconds = AntigravityActivityMonitor.activeIntervalMilliseconds
    private var latestSnapshot = AntigravityActivitySnapshot.empty
    private var context = PollingContext()
    private var contextGeneration: UInt64 = 0
    private var onChange: (@Sendable (AntigravityActivitySnapshot) -> Void)?
    private var pendingSnapshot: AntigravityActivitySnapshot?
    private var pendingSnapshotGeneration: UInt64?
    private var pendingDispatchWorkItem: DispatchWorkItem?
    private var lastDispatchAt = Date.distantPast
    private var cachedProcessPresent = false
    private var lastPresencePollAt = Date.distantPast
    private let pollBarrier: (@Sendable () -> Void)?
    private let preDispatchBarrier: (@Sendable () -> Void)?
    private let callbackDispatch: @Sendable (@escaping @Sendable () -> Void) -> Void

    init(
        hookMonitor: AntigravityHookStatusMonitor = AntigravityHookStatusMonitor(),
        processPresenceProbe: @escaping () -> Bool = AntigravityActivityMonitor.agentProcessIsRunning,
        pollBarrier: (@Sendable () -> Void)? = nil,
        preDispatchBarrier: (@Sendable () -> Void)? = nil,
        callbackDispatch: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void = {
            DispatchQueue.main.async(execute: $0)
        }
    ) {
        self.hookMonitor = hookMonitor
        self.processPresenceProbe = processPresenceProbe
        self.pollBarrier = pollBarrier
        self.preDispatchBarrier = preDispatchBarrier
        self.callbackDispatch = callbackDispatch
    }

    func start(onChange: @escaping @Sendable (AntigravityActivitySnapshot) -> Void) {
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
            let desired = (focusedAgent == .antigravity || detailsPanelVisible)
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

    func snapshot() -> AntigravityActivitySnapshot {
        stateLock.lock()
        defer { stateLock.unlock() }
        return latestSnapshot
    }

    /// Present when a retained hook snapshot is still inside the Claude hook
    /// windows (active 600s / idle 300s), or `processPresenceProbe()` is true.
    /// The production probe matches `agy` or the desktop app `Antigravity` —
    /// never `language_server` or `Antigravity Helper`.
    static func isPresent(
        sessions: [SessionSnapshot],
        now: Date,
        processPresenceProbe: () -> Bool
    ) -> Bool {
        if sessions.contains(where: { ClaudeHookStatusMonitor.shouldRetainSnapshot($0, now: now) }) {
            return true
        }
        return processPresenceProbe()
    }

    /// Production presence probe: `agy` CLI or the `Antigravity` desktop app.
    static func agentProcessIsRunning() -> Bool {
        hasPresentProcess()
    }

    /// Exact last-path-component match for presence. `agy` is the CLI;
    /// `Antigravity` is the Antigravity 2.0 desktop app (not the IDE).
    /// Helpers and `language_server` stay out.
    static func countsAsPresentProcess(comm: String, name: String) -> Bool {
        let commBase = URL(fileURLWithPath: comm).lastPathComponent
        let nameBase = URL(fileURLWithPath: name).lastPathComponent
        return presentProcessNames.contains(commBase) || presentProcessNames.contains(nameBase)
    }

    private static let presentProcessNames: Set<String> = ["agy", "Antigravity"]

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
        _ snapshot: AntigravityActivitySnapshot,
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
            cachedProcessPresent = processPresenceProbe()
        }

        let nextSnapshot = AntigravityActivitySnapshot(
            sessions: sessions,
            isPresent: Self.isPresent(
                sessions: sessions,
                now: now,
                processPresenceProbe: { cachedProcessPresent }
            )
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

    private func scheduleDispatch(
        of snapshot: AntigravityActivitySnapshot,
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

    /// Exact process-name match via libproc. Does not spawn `/bin/ps`, and
    /// never treats `language_server` or Helper processes as present.
    static func presentProcessIds() -> [Int32] {
        let requested = proc_listallpids(nil, 0)
        guard requested > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(requested) + 64)
        let count = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard count > 0 else { return [] }
        var matches: [Int32] = []
        for pid in pids.prefix(Int(count)) where pid > 0 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            let read = withUnsafeMutablePointer(to: &info) { pointer in
                proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, pointer, size)
            }
            guard read == size else { continue }
            let comm = processCString(info.pbi_comm)
            let name = processCString(info.pbi_name)
            if countsAsPresentProcess(comm: comm, name: name) {
                matches.append(pid)
            }
        }
        return matches
    }

    private static func hasPresentProcess() -> Bool {
        !presentProcessIds().isEmpty
    }

    private static func processCString<T>(_ value: T) -> String {
        var copy = value
        return withUnsafeBytes(of: &copy) { buffer in
            guard let base = buffer.baseAddress else { return "" }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
    }
}
