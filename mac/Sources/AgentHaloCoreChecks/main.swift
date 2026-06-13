import Foundation
import AgentHaloCore

func expect<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    if actual != expected {
        fatalError("\(message): expected \(expected), got \(actual)")
    }
}

func expect(_ condition: Bool, _ message: String) {
    if !condition {
        fatalError(message)
    }
}

func testReducesPlanningWorkingAttentionErrorAndCompleteEvents() {
    var reducer = SessionReducer(filePath: "/tmp/session-019c6e27-e55b-73d1-87d8-4e01f1f75043.jsonl")

    reducer.consume(jsonLine: #"{"timestamp":"2026-06-13T01:00:00Z","type":"session_meta","payload":{"id":"thread-a","cwd":"/Users/wjs/work/pyproj/AgentHalo"}}"#)
    reducer.consume(jsonLine: #"{"timestamp":"2026-06-13T01:00:01Z","type":"event_msg","payload":{"type":"task_started"}}"#)
    expect(reducer.snapshot.threadId, "thread-a", "thread id")
    expect(reducer.snapshot.projectName, "AgentHalo", "project name")
    expect(reducer.snapshot.state, .thinking, "task_started state")
    expect(reducer.snapshot.action, "Planning", "task_started action")
    expect(reducer.snapshot.active, "task_started should be active")

    reducer.consume(jsonLine: #"{"timestamp":"2026-06-13T01:00:02Z","type":"response_item","payload":{"type":"function_call","name":"shell_command"}}"#)
    expect(reducer.snapshot.state, .working, "function_call state")
    expect(reducer.snapshot.action, "Running command", "function_call action")

    reducer.consume(jsonLine: #"{"timestamp":"2026-06-13T01:00:03Z","type":"response_item","payload":{"type":"function_call_output"}}"#)
    expect(reducer.snapshot.state, .working, "function_call_output visible state")
    expect(reducer.snapshot.action, "Reviewing result", "function_call_output action")

    reducer.consume(jsonLine: #"{"timestamp":"2026-06-13T01:00:04Z","type":"event_msg","payload":{"type":"approval_requested"}}"#)
    expect(reducer.snapshot.state, .attention, "approval state")
    expect(reducer.snapshot.action, "Needs you", "approval action")

    reducer.consume(jsonLine: #"{"timestamp":"2026-06-13T01:00:05Z","type":"event_msg","payload":{"type":"turn_failed"}}"#)
    expect(reducer.snapshot.state, .error, "turn_failed state")
    expect(!reducer.snapshot.active, "turn_failed should be inactive")

    reducer.consume(jsonLine: #"{"timestamp":"2026-06-13T01:00:06Z","type":"event_msg","payload":{"type":"task_started"}}"#)
    reducer.consume(jsonLine: #"{"timestamp":"2026-06-13T01:00:07Z","type":"event_msg","payload":{"type":"task_complete"}}"#)
    expect(reducer.snapshot.state, .done, "task_complete state")
    expect(reducer.snapshot.action, "Complete", "task_complete action")
    expect(!reducer.snapshot.active, "task_complete should be inactive")
    expect(reducer.snapshot.completedAt != nil, "task_complete should set completion time")
}

func testAggregatePrioritizesActionableSessions() {
    let now = ISO8601DateFormatter().date(from: "2026-06-13T02:00:00Z")!
    let idle = SessionSnapshot(
        threadId: "idle",
        projectName: "IdleProject",
        workingDirectory: "",
        state: .idle,
        action: "Ready",
        lastEventAt: now,
        completedAt: nil,
        active: false
    )
    let done = SessionSnapshot(
        threadId: "done",
        projectName: "DoneProject",
        workingDirectory: "",
        state: .done,
        action: "Complete",
        lastEventAt: now,
        completedAt: now,
        active: false
    )
    let attention = SessionSnapshot(
        threadId: "attention",
        projectName: "AttentionProject",
        workingDirectory: "",
        state: .attention,
        action: "Needs you",
        lastEventAt: now,
        completedAt: nil,
        active: true
    )

    let aggregate = SessionAggregator.aggregate(
        snapshots: [idle, done, attention],
        settings: HaloSettings(paused: false, installedAt: now.addingTimeInterval(-60), acknowledged: [:]),
        now: now
    )

    expect(aggregate.state, .attention, "aggregate state")
    expect(aggregate.label, "NEEDS YOU", "aggregate label")
    expect(aggregate.detail, "AttentionProject +1", "aggregate detail")
    expect(aggregate.sessions.map(\.threadId), ["attention", "done"], "aggregate sessions")
}

func testAcknowledgingCompletedSessionsStoresLatestVisibleCompletionOnly() {
    let now = ISO8601DateFormatter().date(from: "2026-06-13T02:00:00Z")!
    let earlier = now.addingTimeInterval(-120)
    let later = now.addingTimeInterval(-60)
    let oldCompletion = SessionSnapshot(
        threadId: "done",
        projectName: "AgentHalo",
        workingDirectory: "",
        state: .done,
        action: "Complete",
        lastEventAt: earlier,
        completedAt: earlier,
        active: false
    )
    let latestCompletion = SessionSnapshot(
        threadId: "done",
        projectName: "AgentHalo",
        workingDirectory: "",
        state: .done,
        action: "Complete",
        lastEventAt: later,
        completedAt: later,
        active: false
    )
    let activeSession = SessionSnapshot(
        threadId: "active",
        projectName: "AgentHalo",
        workingDirectory: "",
        state: .working,
        action: "Running command",
        lastEventAt: later,
        completedAt: nil,
        active: true
    )

    let settings = HaloSettings(installedAt: now.addingTimeInterval(-600))
        .acknowledgingCompletedSessions([oldCompletion, latestCompletion, activeSession])

    expect(settings.acknowledged, ["done": later], "acknowledged completions")
}

func testSettingsPersistFormalFieldsAndNormalizePaused() {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agent-halo-settings-\(UUID().uuidString)", isDirectory: true)
    let url = root.appendingPathComponent("settings.json")
    let store = SettingsStore(settingsURL: url)
    let installedAt = ISO8601DateFormatter().date(from: "2026-06-13T02:00:00Z")!
    let acknowledgedErrorAt = installedAt.addingTimeInterval(60)
    let settings = HaloSettings(
        hasPosition: true,
        left: 110,
        top: 220,
        alwaysOnTop: false,
        paused: true,
        installedAt: installedAt,
        acknowledged: ["thread": installedAt],
        acknowledgedErrorAt: acknowledgedErrorAt
    )

    store.save(settings)
    let loaded = store.load(now: installedAt.addingTimeInterval(120))

    expect(loaded.hasPosition, true, "hasPosition should persist")
    expect(loaded.left, 110, "left should persist")
    expect(loaded.top, 220, "top should persist")
    expect(loaded.alwaysOnTop, false, "alwaysOnTop should persist")
    expect(loaded.paused, false, "paused should normalize false on load")
    expect(loaded.acknowledged, ["thread": installedAt], "acknowledged should persist")
    expect(loaded.acknowledgedErrorAt, acknowledgedErrorAt, "acknowledgedErrorAt should persist")
}

func testAcknowledgedErrorVisibilityUsesLatestErrorTime() {
    let now = ISO8601DateFormatter().date(from: "2026-06-13T02:00:00Z")!
    let earlier = now.addingTimeInterval(-60)
    let later = now.addingTimeInterval(60)
    let settings = HaloSettings(installedAt: now, acknowledgedErrorAt: earlier)

    expect(settings.shouldShowError(eventAt: now), true, "newer error should show")
    expect(settings.acknowledgingError(at: now).shouldShowError(eventAt: earlier), false, "older error should hide")
    expect(settings.acknowledgingError(at: now).shouldShowError(eventAt: later), true, "future error should show")
}

func testWorkingVisibilityLiveCallOutputAndInitialTail() {
    let formatter = ISO8601DateFormatter()
    let now = formatter.date(from: "2026-06-13T02:00:00Z")!

    var live = SessionReducer(filePath: "/tmp/live.jsonl", now: now, liveTracking: true)
    live.consume(jsonLine: #"{"timestamp":"2026-06-13T02:00:00Z","type":"event_msg","payload":{"type":"task_started"}}"#, now: now)
    live.consume(jsonLine: #"{"timestamp":"2026-06-13T02:00:01Z","type":"response_item","payload":{"type":"function_call","name":"shell_command"}}"#, now: now.addingTimeInterval(1))
    live.consume(jsonLine: #"{"timestamp":"2026-06-13T02:00:02Z","type":"response_item","payload":{"type":"function_call_output"}}"#, now: now.addingTimeInterval(2))
    live.applyWorkingVisibility(now: now.addingTimeInterval(3.7))
    expect(live.snapshot.state, .working, "live output should remain working before 1.8s expires")
    live.applyWorkingVisibility(now: now.addingTimeInterval(3.9))
    expect(live.snapshot.state, .thinking, "live output should return thinking after 1.8s expires")

    var initial = SessionReducer(filePath: "/tmp/initial.jsonl", now: now, liveTracking: false)
    initial.consume(jsonLine: #"{"timestamp":"2026-06-13T02:00:00Z","type":"event_msg","payload":{"type":"task_started"}}"#, now: now)
    initial.consume(jsonLine: #"{"timestamp":"2026-06-13T02:00:01Z","type":"response_item","payload":{"type":"function_call","name":"shell_command"}}"#, now: now.addingTimeInterval(1))
    initial.consume(jsonLine: #"{"timestamp":"2026-06-13T02:00:02Z","type":"response_item","payload":{"type":"function_call_output"}}"#, now: now.addingTimeInterval(2))
    expect(initial.snapshot.state, .thinking, "initial tail output should not fake working")
}

func testToolFailedDoesNotBecomeFatalError() {
    let now = ISO8601DateFormatter().date(from: "2026-06-13T02:00:00Z")!
    var reducer = SessionReducer(filePath: "/tmp/tool-failed.jsonl", now: now, liveTracking: true)
    reducer.consume(jsonLine: #"{"timestamp":"2026-06-13T02:00:00Z","type":"event_msg","payload":{"type":"task_started"}}"#, now: now)
    reducer.consume(jsonLine: #"{"timestamp":"2026-06-13T02:00:01Z","type":"event_msg","payload":{"type":"tool_failed"}}"#, now: now.addingTimeInterval(1))
    expect(reducer.snapshot.state, .thinking, "tool_failed should keep active thinking state")
    expect(reducer.snapshot.active, true, "tool_failed should not deactivate session")
}

extension FileHandle {
    func withClose(_ body: (FileHandle) throws -> Void) rethrows {
        defer { try? close() }
        try body(self)
    }
}

func testMonitorHandlesPendingLinesAndTruncation() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agent-halo-monitor-\(UUID().uuidString)", isDirectory: true)
    let sessions = root.appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    let file = sessions.appendingPathComponent("session-\(UUID().uuidString).jsonl")
    let now = ISO8601DateFormatter().date(from: "2026-06-13T02:00:00Z")!
    try Data(#"{"timestamp":"2026-06-13T02:00:00Z","type":"event_msg","payload":{"type":"task_started"}}"#.utf8).write(to: file)

    let monitor = CodexSessionMonitor(sessionsRoot: sessions)
    _ = monitor.refresh(now: now)
    expect(monitor.snapshots().first?.state == .idle, "partial line should wait for newline")

    try FileHandle(forWritingTo: file).withClose {
        try $0.seekToEnd()
        try $0.write(contentsOf: Data("\n".utf8))
    }
    _ = monitor.refresh(now: now.addingTimeInterval(1))
    expect(monitor.snapshots().first?.state == .thinking, "completed pending line should parse")

    try Data(#"{"timestamp":"2026-06-13T02:00:02Z","type":"event_msg","payload":{"type":"task_complete"}}"#.utf8).write(to: file)
    _ = monitor.refresh(now: now.addingTimeInterval(2))
    expect(monitor.snapshots().first?.state == .idle, "truncated partial line should not parse")
}

testReducesPlanningWorkingAttentionErrorAndCompleteEvents()
testAggregatePrioritizesActionableSessions()
testAcknowledgingCompletedSessionsStoresLatestVisibleCompletionOnly()
testSettingsPersistFormalFieldsAndNormalizePaused()
testAcknowledgedErrorVisibilityUsesLatestErrorTime()
testWorkingVisibilityLiveCallOutputAndInitialTail()
testToolFailedDoesNotBecomeFatalError()
do {
    try testMonitorHandlesPendingLinesAndTruncation()
} catch {
    fatalError("\(error)")
}
print("PASS AgentHaloCore checks")
