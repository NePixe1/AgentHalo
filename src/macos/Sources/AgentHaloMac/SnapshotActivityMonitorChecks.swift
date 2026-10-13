import Foundation
import AgentHaloCore

private final class SnapshotCheckCallbacks: @unchecked Sendable {
    private let lock = NSLock()
    private var callbacks: [@Sendable () -> Void] = []
    func enqueue(_ callback: @escaping @Sendable () -> Void) {
        lock.lock(); callbacks.append(callback); lock.unlock()
    }
    func deliver() {
        lock.lock(); let pending = callbacks; callbacks.removeAll(); lock.unlock()
        for callback in pending { callback() }
    }
}

private final class SnapshotCheckValues: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []
    private var count = 0
    func scan() -> Int {
        lock.lock(); defer { lock.unlock() }; count += 1; return 1
    }
    func append(_ value: Int) { lock.lock(); values.append(value); lock.unlock() }
    func read() -> [Int] { lock.lock(); defer { lock.unlock() }; return values }
    func scans() -> Int { lock.lock(); defer { lock.unlock() }; return count }
}

// No sleeps or real files: hold publication callbacks until the polling
// context has changed, then retry an identical scan in the new context.
func runSnapshotActivityMonitorChecks() {
    for transition in ["focus", "pause", "disable"] {
        let callbacks = SnapshotCheckCallbacks()
        let values = SnapshotCheckValues()
        let monitor = SnapshotActivityMonitor(
            queueLabel: "snapshot-check-\(transition)", activeAgent: .workbuddy,
            pauseStopsPolling: true, empty: 0,
            callbackDispatch: callbacks.enqueue, scan: values.scan
        )
        monitor.start(onChange: values.append)
        monitor.updatePollingContext(focusedAgent: .workbuddy, paused: false, enabled: true)
        monitor.synchronizePollingForChecks()
        precondition(monitor.snapshot() == 1, "first scan must finish before the race")
        precondition(values.read().isEmpty, "publication is intentionally held")
        monitor.updatePollingContext(
            focusedAgent: transition == "focus" ? .codex : .workbuddy,
            paused: transition == "pause", enabled: transition != "disable"
        )
        monitor.synchronizePollingForChecks()
        let scans = values.scans()
        monitor.requestRefresh()
        monitor.synchronizePollingForChecks()
        precondition(values.scans() == scans, "inactive WorkBuddy must not scan")
        callbacks.deliver()
        precondition(!values.read().contains(1), "stale callback must be rejected")
        monitor.updatePollingContext(focusedAgent: .workbuddy, paused: false, enabled: true)
        monitor.requestRefresh()
        monitor.synchronizePollingForChecks()
        callbacks.deliver()
        precondition(values.read().last == 1, "\(transition): stable data must be redelivered")
        let delivered = values.read()
        monitor.requestRefresh()
        monitor.synchronizePollingForChecks()
        callbacks.deliver()
        precondition(values.read() == delivered, "already delivered stable data is deduplicated")

        // A disable callback invalidated by another disabled context update
        // must also be retried, even though snapshot() is already empty.
        monitor.updatePollingContext(focusedAgent: .workbuddy, paused: false, enabled: false)
        monitor.updatePollingContext(focusedAgent: .codex, paused: false, enabled: false)
        monitor.synchronizePollingForChecks()
        callbacks.deliver()
        precondition(values.read().last == 0, "latest disabled context must deliver empty")
        monitor.updatePollingContext(focusedAgent: .workbuddy, paused: false, enabled: true)
        monitor.synchronizePollingForChecks()
        callbacks.deliver()
        precondition(values.read().last == 1, "re-enable after delivered empty republishes stable data")
        monitor.stop()
    }
    print("PASS snapshot publication races: focus, pause, disable, stable retries and scan gating")
}
