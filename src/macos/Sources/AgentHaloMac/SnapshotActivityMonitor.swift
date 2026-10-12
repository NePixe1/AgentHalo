import Foundation
import AgentHaloCore

/// Background poller for a local snapshot. The main thread only reads the
/// latest value. Scans only while this agent is focused.
final class SnapshotActivityMonitor<Snapshot: Equatable & Sendable>: @unchecked Sendable {
    private struct PollingContext: Equatable {
        var focusedAgent: AgentKind = .codex
        var paused = false
        var enabled = true
    }

    private let activeIntervalMilliseconds = 500
    private let queue: DispatchQueue
    private let stateLock = NSLock()
    private let activeAgent: AgentKind
    private let pauseStopsPolling: Bool
    private let empty: Snapshot
    private let scan: @Sendable () -> Snapshot
    private var timer: DispatchSourceTimer?
    private var latest: Snapshot
    private var context = PollingContext()
    private var contextGeneration: UInt64 = 0
    private var onChange: (@Sendable (Snapshot) -> Void)?

    init(
        queueLabel: String,
        activeAgent: AgentKind,
        pauseStopsPolling: Bool = false,
        empty: Snapshot,
        scan: @escaping @Sendable () -> Snapshot
    ) {
        self.queue = DispatchQueue(label: queueLabel, qos: .utility)
        self.activeAgent = activeAgent
        self.pauseStopsPolling = pauseStopsPolling
        self.empty = empty
        self.scan = scan
        self.latest = empty
    }

    static func shouldPoll(
        activeAgent: AgentKind,
        focusedAgent: AgentKind,
        paused: Bool,
        pauseStopsPolling: Bool,
        enabled: Bool
    ) -> Bool {
        enabled && focusedAgent == activeAgent && !(pauseStopsPolling && paused)
    }

    func start(onChange: @escaping @Sendable (Snapshot) -> Void) {
        stateLock.lock()
        self.onChange = onChange
        stateLock.unlock()
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
        }
    }

    func updatePollingContext(focusedAgent: AgentKind, paused: Bool, enabled: Bool) {
        let next = PollingContext(
            focusedAgent: focusedAgent,
            paused: paused,
            enabled: enabled
        )
        stateLock.lock()
        let wasEnabled = context.enabled
        if context != next {
            context = next
            contextGeneration &+= 1
        }
        let generation = contextGeneration
        let shouldPublishEmpty = !enabled && (wasEnabled || latest != empty)
        if !enabled {
            latest = empty
        }
        stateLock.unlock()

        if !enabled {
            queue.async { [weak self] in
                guard let self, self.isCurrent(generation: generation, enabled: false) else { return }
                self.timer?.cancel()
                self.timer = nil
            }
            if shouldPublishEmpty {
                publish(empty, generation: generation, enabled: false)
            }
            return
        }

        let shouldPoll = Self.shouldPoll(
            activeAgent: activeAgent,
            focusedAgent: focusedAgent,
            paused: paused,
            pauseStopsPolling: pauseStopsPolling,
            enabled: enabled
        )
        queue.async { [weak self] in
            guard let self, self.isCurrent(generation: generation, enabled: true) else { return }
            guard shouldPoll else {
                self.timer?.cancel()
                self.timer = nil
                return
            }
            if self.timer == nil {
                self.scheduleTimer(intervalMilliseconds: self.activeIntervalMilliseconds)
                self.poll()
            }
        }
    }

    func requestRefresh() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let focusedAgent = self.context.focusedAgent
            let paused = self.context.paused
            let enabled = self.context.enabled
            self.stateLock.unlock()
            guard Self.shouldPoll(
                activeAgent: self.activeAgent,
                focusedAgent: focusedAgent,
                paused: paused,
                pauseStopsPolling: self.pauseStopsPolling,
                enabled: enabled
            ) else { return }
            self.poll()
        }
    }

    func snapshot() -> Snapshot {
        stateLock.lock()
        defer { stateLock.unlock() }
        return latest
    }

    private func isCurrent(generation: UInt64, enabled: Bool) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return contextGeneration == generation && context.enabled == enabled
    }

    private func scheduleTimer(intervalMilliseconds: Int) {
        timer?.cancel()
        let next = DispatchSource.makeTimerSource(queue: queue)
        next.schedule(
            deadline: .now() + .milliseconds(intervalMilliseconds),
            repeating: .milliseconds(intervalMilliseconds),
            leeway: .milliseconds(max(50, intervalMilliseconds / 3))
        )
        next.setEventHandler { [weak self] in
            self?.poll()
        }
        timer = next
        next.resume()
    }

    private func poll() {
        stateLock.lock()
        let enabled = context.enabled
        let generation = contextGeneration
        stateLock.unlock()
        guard enabled else { return }
        let scanned = scan()
        stateLock.lock()
        guard contextGeneration == generation, context.enabled else {
            stateLock.unlock()
            return
        }
        let changed = latest != scanned
        latest = scanned
        stateLock.unlock()
        if changed {
            publish(scanned, generation: generation, enabled: true)
        }
    }

    private func publish(_ snapshot: Snapshot, generation: UInt64, enabled: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            guard self.contextGeneration == generation,
                  self.context.enabled == enabled,
                  let onChange = self.onChange
            else {
                self.stateLock.unlock()
                return
            }
            self.stateLock.unlock()
            onChange(snapshot)
        }
    }
}

enum OpenCodeActivityLaunch {
    static let date = Date()
}

final class WorkBuddyScanner: @unchecked Sendable {
    private let lock = NSLock()
    private let launched: Date
    private var transcripts: [String: WorkBuddyTranscriptCursor] = [:]

    init(launched: Date = OpenCodeActivityLaunch.date) {
        self.launched = launched
    }

    func scan() -> WorkBuddyObservation {
        lock.lock()
        defer { lock.unlock() }
        return WorkBuddyMonitor.scan(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            processes: LiveProcessProbe.processes(),
            transcripts: &transcripts,
            launched: launched
        )
    }
}
