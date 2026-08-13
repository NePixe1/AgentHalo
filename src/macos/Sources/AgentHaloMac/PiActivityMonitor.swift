import Foundation
import AgentHaloCore

/// Cached Pi lifecycle state produced on a background queue. The main thread
/// only reads this snapshot; JSONL parsing and PID probes stay off the main tick.
struct PiActivitySnapshot: Equatable, Sendable {
    var sessions: [SessionSnapshot]
    /// Session ids whose extension record still has a live PID.
    var liveSessionIds: Set<String>
    /// True when an extension PID or runtime fallback confirms Pi is live.
    var isPresent: Bool

    static let empty = PiActivitySnapshot(
        sessions: [],
        liveSessionIds: [],
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
    private let statusMonitor: PiStatusMonitor
    private let runtimeMonitor: PiRuntimeMonitor
    private var timer: DispatchSourceTimer?
    private var currentIntervalMilliseconds = PiActivityMonitor.activeIntervalMilliseconds
    private var latestSnapshot = PiActivitySnapshot.empty
    private var context = PollingContext()
    private var onChange: (@Sendable (PiActivitySnapshot) -> Void)?
    private var pendingSnapshot: PiActivitySnapshot?
    private var pendingDispatchWorkItem: DispatchWorkItem?
    private var lastDispatchAt = Date.distantPast

    init(
        statusMonitor: PiStatusMonitor = PiStatusMonitor(),
        runtimeMonitor: PiRuntimeMonitor = PiRuntimeMonitor()
    ) {
        self.statusMonitor = statusMonitor
        self.runtimeMonitor = runtimeMonitor
    }

    func start(onChange: @escaping @Sendable (PiActivitySnapshot) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.onChange = onChange
            guard self.timer == nil else {
                return
            }
            guard self.context.enabled else {
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

    func updatePollingContext(focusedAgent: AgentKind, detailsPanelVisible: Bool, enabled: Bool) {
        // Apply disable (timer cancel + empty snapshot) synchronously so callers
        // can read snapshot() immediately without waiting for the monitor queue.
        queue.sync { [weak self] in
            guard let self else { return }
            let wasEnabled = self.context.enabled
            self.context = PollingContext(
                focusedAgent: focusedAgent,
                detailsPanelVisible: detailsPanelVisible,
                enabled: enabled
            )
            if !enabled {
                self.publishDisabledEmptySnapshot(wasEnabled: wasEnabled)
                return
            }
            let desired = (focusedAgent == .pi || detailsPanelVisible)
                ? Self.activeIntervalMilliseconds
                : Self.idleIntervalMilliseconds
            if !wasEnabled {
                self.scheduleTimer(intervalMilliseconds: desired)
                self.poll()
            } else if self.timer != nil, desired != self.currentIntervalMilliseconds {
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
        queue.sync {
            latestSnapshot
        }
    }

    private func publishDisabledEmptySnapshot(wasEnabled: Bool) {
        timer?.cancel()
        timer = nil
        pendingDispatchWorkItem?.cancel()
        pendingDispatchWorkItem = nil
        pendingSnapshot = nil
        let shouldPublish = wasEnabled || latestSnapshot != .empty
        latestSnapshot = .empty
        guard shouldPublish, let onChange else { return }
        lastDispatchAt = Date()
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
            self?.poll()
        }
        timer = next
        currentIntervalMilliseconds = intervalMilliseconds
        next.resume()
    }

    private func poll() {
        guard context.enabled else { return }
        _ = statusMonitor.refresh()
        _ = runtimeMonitor.refresh()
        let liveIds = statusMonitor.liveSessionIds()
        let sessions = Self.projectSessions(
            statusSessions: statusMonitor.snapshots(),
            liveSessionIds: liveIds,
            runtimeSession: runtimeMonitor.snapshot()
        )
        let nextSnapshot = PiActivitySnapshot(
            sessions: sessions,
            liveSessionIds: liveIds,
            isPresent: !liveIds.isEmpty || runtimeMonitor.isRunning
        )
        guard nextSnapshot != latestSnapshot else {
            return
        }
        latestSnapshot = nextSnapshot
        scheduleDispatch(of: nextSnapshot, now: Date())
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

    private func scheduleDispatch(of snapshot: PiActivitySnapshot, now: Date) {
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
