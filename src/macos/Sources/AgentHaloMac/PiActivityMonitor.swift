import Foundation
import AgentHaloCore

/// Cached Pi lifecycle state produced on a background queue. The main thread
/// only reads this snapshot; JSONL parsing and PID probes stay off the main tick.
struct PiActivitySnapshot: Equatable, Sendable {
    var sessions: [SessionSnapshot]
    /// Session ids whose extension record still has a live PID.
    var liveSessionIds: Set<String>
    /// True when at least one Pi session PID is live (drives STANDBY vs OFFLINE).
    var isPresent: Bool

    static let empty = PiActivitySnapshot(
        sessions: [],
        liveSessionIds: [],
        isPresent: false
    )

    /// Newest non-offline session for details panel on STANDBY.
    var preferredStandbySession: SessionSnapshot? {
        sessions
            .filter { $0.agent == .pi && !$0.threadId.isEmpty }
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
    }

    private static let activeIntervalMilliseconds = 300
    private static let idleIntervalMilliseconds = 2_000
    private static let dispatchThrottleSeconds: TimeInterval = 0.3

    private let queue = DispatchQueue(label: "com.agenthalo.pi-activity", qos: .utility)
    private let statusMonitor: PiStatusMonitor
    private var timer: DispatchSourceTimer?
    private var currentIntervalMilliseconds = PiActivityMonitor.activeIntervalMilliseconds
    private var latestSnapshot = PiActivitySnapshot.empty
    private var context = PollingContext()
    private var onChange: (@Sendable (PiActivitySnapshot) -> Void)?
    private var pendingSnapshot: PiActivitySnapshot?
    private var pendingDispatchWorkItem: DispatchWorkItem?
    private var lastDispatchAt = Date.distantPast

    init(statusMonitor: PiStatusMonitor = PiStatusMonitor()) {
        self.statusMonitor = statusMonitor
    }

    func start(onChange: @escaping @Sendable (PiActivitySnapshot) -> Void) {
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
            let desired = (focusedAgent == .pi || detailsPanelVisible)
                ? Self.activeIntervalMilliseconds
                : Self.idleIntervalMilliseconds
            if self.timer != nil, desired != self.currentIntervalMilliseconds {
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
        _ = statusMonitor.refresh()
        let sessions = statusMonitor.snapshots()
        let liveIds = statusMonitor.liveSessionIds()
        let nextSnapshot = PiActivitySnapshot(
            sessions: sessions,
            liveSessionIds: liveIds,
            isPresent: !liveIds.isEmpty
        )
        guard nextSnapshot != latestSnapshot else {
            return
        }
        latestSnapshot = nextSnapshot
        scheduleDispatch(of: nextSnapshot, now: Date())
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
