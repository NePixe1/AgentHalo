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
    private var lastFailurePollAt = Date.distantPast
    private var lastRealtimePollAt = Date.distantPast
    private var onChange: (@Sendable (CodexActivitySnapshot) -> Void)?
    private var pendingSnapshot: CodexActivitySnapshot?
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
        self.onChange = onChange
        queue.async { [weak self] in
            guard let self else { return }
            guard self.timer == nil else {
                return
            }
            guard self.isEnabled() else {
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

    func updatePollingContext(focusedAgent: AgentKind, codexRunning: Bool, enabled: Bool) {
        if !enabled {
            let shouldPublish = applyDisabledSnapshot()
            queue.async { [weak self] in
                self?.cancelTimerAndPending()
            }
            if shouldPublish {
                publishEmptyOnMain()
            }
            return
        }

        queue.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let wasEnabled = self.context.enabled
            self.context = PollingContext(
                focusedAgent: focusedAgent,
                codexRunning: codexRunning,
                enabled: true
            )
            self.stateLock.unlock()
            let desired = codexRunning
                ? Self.activeIntervalMilliseconds
                : Self.idleIntervalMilliseconds
            if !wasEnabled {
                self.scheduleTimer(intervalMilliseconds: desired)
                self.poll(forceFailure: true, forceRealtime: true)
            } else if self.timer != nil, desired != self.currentIntervalMilliseconds {
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

    private func isEnabled() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return context.enabled
    }

    private func applyDisabledSnapshot() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        let wasEnabled = context.enabled
        context.enabled = false
        let shouldPublish = wasEnabled || latestSnapshot != .empty
        latestSnapshot = .empty
        return shouldPublish
    }

    private func cancelTimerAndPending() {
        timer?.cancel()
        timer = nil
        pendingDispatchWorkItem?.cancel()
        pendingDispatchWorkItem = nil
        pendingSnapshot = nil
        lastDispatchAt = Date()
    }

    private func publishEmptyOnMain() {
        guard let onChange else { return }
        DispatchQueue.main.async {
            onChange(.empty)
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
        var nextSnapshot = latestSnapshot
        stateLock.unlock()
        pollBarrier?()
        guard isEnabled() else { return }
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
        guard context.enabled else {
            stateLock.unlock()
            return
        }
        guard nextSnapshot != latestSnapshot else {
            stateLock.unlock()
            return
        }
        latestSnapshot = nextSnapshot
        stateLock.unlock()
        scheduleDispatch(of: nextSnapshot, now: now)
    }

    private func scheduleDispatch(of snapshot: CodexActivitySnapshot, now: Date) {
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
