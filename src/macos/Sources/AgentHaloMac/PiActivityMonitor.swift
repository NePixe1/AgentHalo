import Foundation
import AgentHaloCore

/// Cached Pi lifecycle state produced on a background queue. The main thread
/// only reads this snapshot; JSONL parsing and PID probes stay off the main tick.
struct PiActivitySnapshot: Equatable, Sendable {
    var sessions: [SessionSnapshot]
    /// Session ids whose extension record still has a live PID.
    var liveSessionIds: Set<String>
    /// Live extension / runtime pids used for focused-session host activation.
    var livePids: [PiLivePid]
    /// True when an extension PID or runtime fallback confirms Pi is live.
    var isPresent: Bool

    static let empty = PiActivitySnapshot(
        sessions: [],
        liveSessionIds: [],
        livePids: [],
        isPresent: false
    )

    /// Newest live hook session or runtime idle fallback for STANDBY details.
    var preferredStandbySession: SessionSnapshot? {
        sessions
            .filter {
                $0.agent == .pi
                    && !$0.threadId.isEmpty
                    && ($0.state == .idle || liveSessionIds.contains($0.threadId))
            }
            .max(by: { $0.lastEventAt < $1.lastEventAt })
    }
}

/// Mirrors GrokActivityMonitor: Pi status polling runs on a utility queue so
/// the main tick only reads cached snapshots. Cadence is active when Pi is
/// focused or the details panel is visible, idle otherwise.
final class PiActivityMonitor: @unchecked Sendable {
    private struct PollingContext: Equatable {
        var focusedAgent: AgentKind = .codex
        var detailsPanelVisible = false
        var enabled = true
    }

    private static let activeIntervalMilliseconds = 300
    private static let idleIntervalMilliseconds = 2_000
    private static let dispatchThrottleSeconds: TimeInterval = 0.3

    private let queue = DispatchQueue(label: "com.agenthalo.pi-activity", qos: .utility)
    private let stateLock = NSLock()
    private let statusMonitor: PiStatusMonitor
    private let runtimeMonitor: PiRuntimeMonitor
    private var timer: DispatchSourceTimer?
    private var currentIntervalMilliseconds = PiActivityMonitor.activeIntervalMilliseconds
    private var latestSnapshot = PiActivitySnapshot.empty
    private var context = PollingContext()
    private var contextGeneration: UInt64 = 0
    private var onChange: (@Sendable (PiActivitySnapshot) -> Void)?
    private var pendingSnapshot: PiActivitySnapshot?
    private var pendingSnapshotGeneration: UInt64?
    private var pendingDispatchWorkItem: DispatchWorkItem?
    private var lastDispatchAt = Date.distantPast
    private let pollBarrier: (@Sendable () -> Void)?

    init(
        statusMonitor: PiStatusMonitor = PiStatusMonitor(),
        runtimeMonitor: PiRuntimeMonitor = PiRuntimeMonitor(),
        pollBarrier: (@Sendable () -> Void)? = nil
    ) {
        self.statusMonitor = statusMonitor
        self.runtimeMonitor = runtimeMonitor
        self.pollBarrier = pollBarrier
    }

    func start(onChange: @escaping @Sendable (PiActivitySnapshot) -> Void) {
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
            let desired = (focusedAgent == .pi || detailsPanelVisible)
                ? Self.activeIntervalMilliseconds
                : Self.idleIntervalMilliseconds
            if self.timer == nil {
                self.scheduleTimer(intervalMilliseconds: desired)
                self.poll()
            } else if desired != self.currentIntervalMilliseconds {
                self.scheduleTimer(intervalMilliseconds: desired)
            }
        }
    }

    func requestRefresh() {
        queue.async { [weak self] in
            self?.poll()
        }
    }

    func snapshot() -> PiActivitySnapshot {
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
        _ snapshot: PiActivitySnapshot,
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
            self?.poll()
        }
        timer = next
        currentIntervalMilliseconds = intervalMilliseconds
        next.resume()
    }

    private func poll() {
        stateLock.lock()
        guard context.enabled else {
            stateLock.unlock()
            return
        }
        let generation = contextGeneration
        stateLock.unlock()
        pollBarrier?()
        guard isCurrent(generation: generation, enabled: true) else { return }
        _ = statusMonitor.refresh()
        _ = runtimeMonitor.refresh()
        let liveIds = statusMonitor.liveSessionIds()
        let livePids = Self.collectLivePids(
            statusRecords: statusMonitor.allRecords(),
            runtimeMonitor: runtimeMonitor
        )
        let sessions = Self.projectSessions(
            statusSessions: statusMonitor.snapshots(),
            liveSessionIds: liveIds,
            runtimeSession: runtimeMonitor.snapshot()
        )
        let nextSnapshot = PiActivitySnapshot(
            sessions: sessions,
            liveSessionIds: liveIds,
            livePids: livePids,
            isPresent: !liveIds.isEmpty || runtimeMonitor.isRunning
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
        scheduleDispatch(of: nextSnapshot, now: Date(), generation: generation)
    }

    /// Active/idle hook records are valid only while their originating Pi PID
    /// is live. Terminal records remain available for the normal completion and
    /// error visibility windows. The runtime fallback contributes idle presence
    /// only when the hook stream has no snapshot for the same session.
    static func projectSessions(
        statusSessions: [SessionSnapshot],
        liveSessionIds: Set<String>,
        runtimeSession: SessionSnapshot?
    ) -> [SessionSnapshot] {
        var result = statusSessions.filter { session in
            switch session.state {
            case .idle, .thinking, .working, .attention:
                return liveSessionIds.contains(session.threadId)
            case .done, .error:
                return true
            }
        }
        if let runtimeSession,
           !result.contains(where: { $0.threadId == runtimeSession.threadId }) {
            result.append(runtimeSession)
        }
        return result
    }

    /// Live pids come from status records and the runtime monitor only.
    /// SessionSnapshot never supplies a pid.
    private static func collectLivePids(
        statusRecords: [PiStatusRecord],
        runtimeMonitor: PiRuntimeMonitor
    ) -> [PiLivePid] {
        let statusPids = statusRecords.compactMap { record -> PiLivePid? in
            guard PiStatusMonitor.isLive(record), record.processId > 0 else { return nil }
            return PiLivePid(sessionId: record.sessionId, processId: record.processId)
        }
        let runtimePid = runtimeMonitor.processId
        return mergeLivePids(
            statusPids: statusPids,
            runtimeProcessId: runtimeMonitor.isRunning ? runtimePid : 0,
            runtimeSessionId: runtimeMonitor.snapshot()?.threadId
        )
    }

    static func mergeLivePids(
        statusPids: [PiLivePid],
        runtimeProcessId: Int32,
        runtimeSessionId: String?
    ) -> [PiLivePid] {
        var result: [PiLivePid] = []
        var seenSessionIds = Set<String>()
        for item in statusPids where item.processId > 0 && !item.sessionId.isEmpty {
            guard seenSessionIds.insert(item.sessionId).inserted else { continue }
            result.append(item)
        }
        if runtimeProcessId > 0,
           let runtimeSessionId,
           !runtimeSessionId.isEmpty,
           seenSessionIds.insert(runtimeSessionId).inserted {
            result.append(PiLivePid(sessionId: runtimeSessionId, processId: runtimeProcessId))
        }
        return result
    }

    private func scheduleDispatch(
        of snapshot: PiActivitySnapshot,
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
