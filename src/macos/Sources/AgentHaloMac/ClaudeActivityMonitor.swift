import Foundation
import AgentHaloCore

// Cached Claude state produced on a background queue. The main thread reads these
// arrays directly instead of touching the monitors' reducers (which would race
// with the background refresh). `mergedClaudeSnapshots` is precomputed on the
// background queue so the main tick never runs the merger.
struct ClaudeActivitySnapshot: Equatable, Sendable {
    var mergedClaudeSnapshots: [SessionSnapshot]
    var transcriptSnapshots: [SessionSnapshot]
    var liveSessions: [ClaudeLiveSessionSnapshot]
    var preferredStandbySession: ClaudeLiveSessionSnapshot?

    static let empty = ClaudeActivitySnapshot(
        mergedClaudeSnapshots: [],
        transcriptSnapshots: [],
        liveSessions: [],
        preferredStandbySession: nil
    )
}

// Mirrors CodexActivityMonitor: Claude hook/transcript/live-session polling runs
// on a utility queue so the main tick only reads cached snapshots. Polling cadence
// adapts to focus (active when Claude Code is focused or the details panel is
// visible, idle otherwise) and dispatch to the main thread is throttled so burst
// changes coalesce into one onChange per throttle window.
final class ClaudeActivityMonitor: @unchecked Sendable {
    private struct PollingContext: Equatable {
        var focusedAgent: AgentKind = .codex
        var detailsPanelVisible = false
    }

    private static let activeIntervalMilliseconds = 300
    private static let idleIntervalMilliseconds = 2_000
    // Same throttle rationale as CodexActivityMonitor: burst changes (e.g.
    // applyWorkingVisibility flips or live-session pid probes) should not wake the
    // main thread more than once per tick. Trailing delivery guarantees the final
    // state always lands.
    private static let dispatchThrottleSeconds: TimeInterval = 0.3
    // Mirrors Windows: live-session JSON parsing + pid probes are expensive
    // (directory listing + per-file read + kill(pid, 0) per session), so they must
    // not run on every 0.3s poll. Refresh only when the hook/transcript sources
    // actually changed (a turn event is what flips a session toward standby) or
    // when this safety interval elapses. `preferredStandbySession` is recomputed
    // every poll from the cached live sessions + fresh hook snapshots, which is
    // pure dictionary work, so standby selection stays responsive to hook changes
    // without re-reading the sessions directory.
    private static let liveSessionsPollIntervalSeconds: TimeInterval = 2

    private let queue = DispatchQueue(label: "com.agenthalo.claude-activity", qos: .utility)
    private let hookMonitor: ClaudeHookStatusMonitor
    private let sessionMonitor: ClaudeSessionMonitor
    private var timer: DispatchSourceTimer?
    private var currentIntervalMilliseconds = ClaudeActivityMonitor.activeIntervalMilliseconds
    private var latestSnapshot = ClaudeActivitySnapshot.empty
    private var context = PollingContext()
    private var onChange: (@Sendable (ClaudeActivitySnapshot) -> Void)?
    private var pendingSnapshot: ClaudeActivitySnapshot?
    private var pendingDispatchWorkItem: DispatchWorkItem?
    private var lastDispatchAt = Date.distantPast
    private var cachedLiveSessions: [ClaudeLiveSessionSnapshot] = []
    private var lastLiveSessionsPollAt = Date.distantPast

    init(
        hookMonitor: ClaudeHookStatusMonitor = ClaudeHookStatusMonitor(),
        sessionMonitor: ClaudeSessionMonitor = ClaudeSessionMonitor()
    ) {
        self.hookMonitor = hookMonitor
        self.sessionMonitor = sessionMonitor
    }

    func start(onChange: @escaping @Sendable (ClaudeActivitySnapshot) -> Void) {
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
            let desired = (focusedAgent == .claudeCode || detailsPanelVisible)
                ? Self.activeIntervalMilliseconds
                : Self.idleIntervalMilliseconds
            if self.timer != nil, desired != self.currentIntervalMilliseconds {
                self.scheduleTimer(intervalMilliseconds: desired)
            }
        }
    }

    func requestRefresh() {
        queue.async { [weak self] in
            self?.poll(forceLiveSessions: true)
        }
    }

    func snapshot() -> ClaudeActivitySnapshot {
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

    private func poll(forceLiveSessions: Bool = false) {
        let now = Date()
        let hookChanged = hookMonitor.refresh(now: now)
        let transcriptChanged = sessionMonitor.refresh(now: now)
        let hookSnapshots = hookMonitor.snapshots()
        let transcriptSnapshots = sessionMonitor.snapshots()
        let merged = ClaudeStatusSourceMerger.merge(
            hookSnapshots: hookSnapshots,
            transcriptSnapshots: transcriptSnapshots
        )
        // Only re-read the sessions directory when something actually moved (a
        // hook/transcript change is the signal that a session may have shifted
        // toward standby) or when the safety interval elapses. Between those, the
        // cached live sessions are reused so the 0.3s poll stays cheap.
        if forceLiveSessions
            || hookChanged
            || transcriptChanged
            || now.timeIntervalSince(lastLiveSessionsPollAt) >= Self.liveSessionsPollIntervalSeconds {
            lastLiveSessionsPollAt = now
            cachedLiveSessions = ClaudeLiveSessionReader.liveSessions()
        }

        // Post-process the merged snapshots to ensure we only report active = true
        // for sessions that actually have an active background process (i.e. present in cachedLiveSessions).
        var verifiedSnapshots = merged
        let liveSessionIds = Set(cachedLiveSessions.map(\.sessionId))
        for i in 0..<verifiedSnapshots.count {
            if verifiedSnapshots[i].active && !liveSessionIds.contains(verifiedSnapshots[i].threadId) {
                verifiedSnapshots[i].active = false
            }
        }

        // A live Claude Code session is a standby candidate regardless of its
        // `status` field — Claude keeps `status` at "busy" while a turn is in
        // flight and only briefly visits "waiting"/"idle" between turns. The
        // old `waiting`/`idle` filter here cancelled standby during long
        // answers, so the idle→STANDBY projection dropped out and the ring
        // flickered to gray mid-turn. `cachedLiveSessions` already carries
        // only live-pid sessions, which is the real liveness gate.
        let preferred = ClaudeLiveSessionReader.preferredStandbySession(
            sessions: cachedLiveSessions,
            hookSnapshots: hookSnapshots
        )
        let nextSnapshot = ClaudeActivitySnapshot(
            mergedClaudeSnapshots: verifiedSnapshots,
            transcriptSnapshots: transcriptSnapshots,
            liveSessions: cachedLiveSessions,
            preferredStandbySession: preferred
        )
        guard nextSnapshot != latestSnapshot else {
            return
        }
        latestSnapshot = nextSnapshot
        scheduleDispatch(of: nextSnapshot, now: now)
    }

    private func scheduleDispatch(of snapshot: ClaudeActivitySnapshot, now: Date) {
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
