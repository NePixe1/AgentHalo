import Foundation
import AgentHaloCore

struct CodexActivitySnapshot: Equatable, Sendable {
    var sessions: [SessionSnapshot]
    var recentFailure: CodexFailure?
    var realtimeActivity: CodexRealtimeActivity?

    static let empty = CodexActivitySnapshot(
        sessions: [],
        recentFailure: nil,
        realtimeActivity: nil
    )
}

final class CodexActivityMonitor: @unchecked Sendable {
    private struct PollingContext: Equatable {
        var focusedAgent: AgentKind = .codex
        var codexRunning = false
        var enabled = true
    }

    private static let activeIntervalMilliseconds = 300
    private static let idleIntervalMilliseconds = 2_000
    // Burst changes (e.g. applyWorkingVisibility flips or realtime token jitter) can
    // wake the main thread many times within a single tick. Coalesce them so the
    // main-thread onChange fires at most once per throttle window, with a trailing
    // delivery guaranteeing the final state always lands. Window matches the tick
    // cadence so UI freshness is indistinguishable from the existing tick refresh.
    private static let dispatchThrottleSeconds: TimeInterval = 0.3

    private let queue = DispatchQueue(label: "com.agenthalo.codex-activity", qos: .utility)
    private let stateLock = NSLock()
    private let sessionMonitor: CodexSessionMonitor
    private let failureReader: CodexFailureReader
    private let realtimeActivityReader: CodexRealtimeActivityReader
    private var timer: DispatchSourceTimer?
    private var currentIntervalMilliseconds = CodexActivityMonitor.activeIntervalMilliseconds
    private var latestSnapshot = CodexActivitySnapshot.empty
    private var context = PollingContext()
    private var contextGeneration: UInt64 = 0
    private var lastFailurePollAt = Date.distantPast
    private var lastRealtimePollAt = Date.distantPast
    private var onChange: (@Sendable (CodexActivitySnapshot) -> Void)?
    private var pendingSnapshot: CodexActivitySnapshot?
    private var pendingSnapshotGeneration: UInt64?
    private var pendingDispatchWorkItem: DispatchWorkItem?
    private var lastDispatchAt = Date.distantPast
    private let pollBarrier: (@Sendable () -> Void)?

    init(
        sessionMonitor: CodexSessionMonitor = CodexSessionMonitor(),
        failureReader: CodexFailureReader = CodexFailureReader(),
        realtimeActivityReader: CodexRealtimeActivityReader = CodexRealtimeActivityReader(),
        pollBarrier: (@Sendable () -> Void)? = nil
    ) {
        self.sessionMonitor = sessionMonitor
        self.failureReader = failureReader
        self.realtimeActivityReader = realtimeActivityReader
        self.pollBarrier = pollBarrier
    }

    func start(onChange: @escaping @Sendable (CodexActivitySnapshot) -> Void) {
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

    func updatePollingContext(focusedAgent: AgentKind, codexRunning: Bool, enabled: Bool) {
        let nextContext = PollingContext(
            focusedAgent: focusedAgent,
            codexRunning: codexRunning,
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
            let desired = codexRunning
                ? Self.activeIntervalMilliseconds
                : Self.idleIntervalMilliseconds
            if self.timer == nil {
                self.scheduleTimer(intervalMilliseconds: desired)
                self.poll(forceFailure: true, forceRealtime: true)
            } else if desired != self.currentIntervalMilliseconds {
                self.scheduleTimer(intervalMilliseconds: desired)
            }
        }
    }

    func requestRefresh() {
        queue.async { [weak self] in
            self?.poll(forceFailure: true, forceRealtime: true)
        }
    }

    func snapshot() -> CodexActivitySnapshot {
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
        _ snapshot: CodexActivitySnapshot,
        generation: UInt64,
        enabled: Bool
    ) {
        DispatchQueue.main.async { [weak self] in
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
            self?.poll(forceFailure: false, forceRealtime: false)
        }
        timer = next
        currentIntervalMilliseconds = intervalMilliseconds
        next.resume()
    }

    private func poll(forceFailure: Bool, forceRealtime: Bool) {
        stateLock.lock()
        guard context.enabled else {
            stateLock.unlock()
            return
        }
        let polling = context
        let generation = contextGeneration
        var nextSnapshot = latestSnapshot
        stateLock.unlock()
        pollBarrier?()
        guard isCurrent(generation: generation, enabled: true) else { return }
        let now = Date()
        _ = sessionMonitor.refresh(now: now)

        nextSnapshot.sessions = sessionMonitor.snapshots()

        if forceFailure || now.timeIntervalSince(lastFailurePollAt) >= 2 {
            lastFailurePollAt = now
            nextSnapshot.recentFailure = failureReader.readRecent(now: now)
        }

        if polling.focusedAgent == .codex, polling.codexRunning {
            if forceRealtime || now.timeIntervalSince(lastRealtimePollAt) >= 0.3 {
                lastRealtimePollAt = now
                nextSnapshot.realtimeActivity = realtimeActivityReader.readActive(now: now)
            }
        } else {
            nextSnapshot.realtimeActivity = nil
        }

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
        scheduleDispatch(of: nextSnapshot, now: now, generation: generation)
    }

    private func scheduleDispatch(
        of snapshot: CodexActivitySnapshot,
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
