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
    expect(reducer.snapshot.agent, .codex, "Codex reducer should stamp Codex agent")

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

func testSettingsMigratesLegacyAlwaysOnTopOffToDefaultOn() {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agent-halo-legacy-topmost-\(UUID().uuidString)", isDirectory: true)
    let url = root.appendingPathComponent("settings.json")
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try! """
    {
      "acknowledged" : {},
      "alwaysOnTop" : false,
      "hasPosition" : true,
      "installedAt" : "2026-06-13T12:47:19Z",
      "left" : 1341,
      "paused" : false,
      "top" : 817
    }
    """.data(using: .utf8)!.write(to: url)

    let loaded = SettingsStore(settingsURL: url).load()

    expect(loaded.alwaysOnTop, true, "legacy settings should migrate alwaysOnTop back to true")
    expect(
        loaded.alwaysOnTopBehaviorVersion,
        HaloSettings.currentAlwaysOnTopBehaviorVersion,
        "legacy settings should record the always-on-top behavior version"
    )
}

func testSettingsPreservesExplicitAlwaysOnTopOffAfterMigrationVersion() {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agent-halo-current-topmost-\(UUID().uuidString)", isDirectory: true)
    let url = root.appendingPathComponent("settings.json")
    let store = SettingsStore(settingsURL: url)
    let settings = HaloSettings(alwaysOnTop: false)

    store.save(settings)
    let loaded = store.load()

    expect(loaded.alwaysOnTop, false, "current settings should preserve an explicit alwaysOnTop off choice")
    expect(
        loaded.alwaysOnTopBehaviorVersion,
        HaloSettings.currentAlwaysOnTopBehaviorVersion,
        "current settings should persist the always-on-top behavior version"
    )
}

func testSettingsDefaultsFocusedAgentToCodexWhenMissing() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agent-halo-focus-legacy-\(UUID().uuidString)", isDirectory: true)
    let url = root.appendingPathComponent("settings.json")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try """
    {
      "acknowledged" : {},
      "alwaysOnTop" : true,
      "alwaysOnTopBehaviorVersion" : 1,
      "hasPosition" : false,
      "installedAt" : "2026-06-13T02:00:00Z",
      "left" : 0,
      "paused" : false,
      "top" : 0
    }
    """.data(using: .utf8)!.write(to: url)

    let loaded = SettingsStore(settingsURL: url).load()

    expect(loaded.focusedAgent, .codex, "legacy settings should default focus to Codex")
}

func testSettingsPersistsFocusedAgent() {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agent-halo-focus-persist-\(UUID().uuidString)", isDirectory: true)
    let url = root.appendingPathComponent("settings.json")
    let store = SettingsStore(settingsURL: url)
    let settings = HaloSettings(focusedAgent: .claudeCode)

    store.save(settings)
    let loaded = store.load()

    expect(loaded.focusedAgent, .claudeCode, "focused agent should persist")
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
    expect(monitor.snapshots().first?.agent, .codex, "Codex monitor snapshots should carry Codex agent")

    try Data(#"{"timestamp":"2026-06-13T02:00:02Z","type":"event_msg","payload":{"type":"task_complete"}}"#.utf8).write(to: file)
    _ = monitor.refresh(now: now.addingTimeInterval(2))
    expect(monitor.snapshots().first?.state == .idle, "truncated partial line should not parse")
}

func testAggregatorHidesAcknowledgedErrorsAndShowsStandbyInput() {
    let now = ISO8601DateFormatter().date(from: "2026-06-13T02:00:00Z")!
    let error = SessionSnapshot(
        threadId: "error",
        projectName: "Codex",
        workingDirectory: "",
        state: .error,
        action: "Interrupted",
        lastEventAt: now,
        completedAt: nil,
        active: false
    )
    let settings = HaloSettings(installedAt: now.addingTimeInterval(-600), acknowledgedErrorAt: now.addingTimeInterval(1))
    let aggregate = SessionAggregator.aggregate(snapshots: [error], settings: settings, now: now)
    expect(aggregate.state, .idle, "acknowledged error should hide")
    expect(aggregate.label, "READY", "hidden error should return ready")
}

func testFailureClassification() {
    expect(CodexFailureReader.classify("authentication failed for account"), "认证已失效", "auth failure")
    expect(CodexFailureReader.classify("rate_limit_reached"), "额度已用尽", "rate limit")
    expect(CodexFailureReader.classify("server overloaded"), "服务暂时不可用", "service")
    expect(CodexFailureReader.classify("connect timeout"), "连接 Codex 失败", "network")
    expect(CodexFailureReader.classify("plain info") == nil, "non failure")
}

func testRateLimitReaderFindsNewestTailRateLimit() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agent-halo-rate-\(UUID().uuidString)", isDirectory: true)
    let sessions = root.appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    let file = sessions.appendingPathComponent("a.jsonl")
    let line = #"{"type":"event_msg","payload":{"info":{"rate_limits":{"primary":{"used_percent":25},"secondary":{"used_percent":80}}}}}"#
    try Data((line + "\n").utf8).write(to: file)

    let snapshot = RateLimitReader(roots: [sessions]).read()
    expect(snapshot, RateLimitSnapshot(primaryUsedPercent: 25, secondaryUsedPercent: 80), "rate limit")
}

func testRateLimitReaderFindsContextUsageAndResetTimes() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agent-halo-usage-\(UUID().uuidString)", isDirectory: true)
    let sessions = root.appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    let file = sessions.appendingPathComponent("usage.jsonl")
    let line = #"{"type":"event_msg","payload":{"info":{"rate_limits":{"primary":{"used_percent":47,"resets_at":1781765880},"secondary":{"used_percent":76,"resets_at":1781938560}},"last_token_usage":{"input_tokens":202600},"model_context_window":258400}}}"#
    try Data((line + "\n").utf8).write(to: file)

    let snapshot = RateLimitReader(roots: [sessions]).read()
    expect(snapshot?.primaryResetAt, Date(timeIntervalSince1970: 1_781_765_880), "primary reset time")
    expect(snapshot?.secondaryResetAt, Date(timeIntervalSince1970: 1_781_938_560), "secondary reset time")
    expectAlmost(snapshot?.contextUsedPercent ?? 0, 78.405, tolerance: 0.01, "context usage")
}

func testAggregatorInjectsUnacknowledgedCodexFailureWhenIdle() {
    let now = ISO8601DateFormatter().date(from: "2026-06-13T02:00:00Z")!
    let failure = CodexFailure(detail: "认证已失效", eventAt: now)
    let aggregate = SessionAggregator.aggregate(
        snapshots: [],
        settings: HaloSettings(installedAt: now.addingTimeInterval(-600)),
        recentFailure: failure,
        codexRunning: true,
        focusedAgent: .codex,
        now: now
    )

    expect(aggregate.state, .error, "recent failure should surface as error")
    expect(aggregate.label, "INTERRUPTED", "recent failure label")
    expect(aggregate.detail, "认证已失效", "recent failure detail")
    expect(aggregate.sessions.map(\.threadId), ["codex-app"], "synthetic failure session")

    let acknowledged = SessionAggregator.aggregate(
        snapshots: [],
        settings: HaloSettings(installedAt: now.addingTimeInterval(-600), acknowledgedErrorAt: now),
        recentFailure: failure,
        codexRunning: true,
        focusedAgent: .codex,
        now: now
    )
    expect(acknowledged.state, .idle, "acknowledged failure should hide")
}

func testAggregatorFiltersByFocusedAgent() {
    let now = ISO8601DateFormatter().date(from: "2026-06-13T02:00:00Z")!
    let codexDone = SessionSnapshot(
        threadId: "codex-done",
        projectName: "CodexProject",
        workingDirectory: "",
        state: .done,
        action: "Complete",
        lastEventAt: now,
        completedAt: now,
        active: false,
        agent: .codex
    )
    let claudeWorking = SessionSnapshot(
        threadId: "claude-working",
        projectName: "ClaudeProject",
        workingDirectory: "",
        state: .working,
        action: "Running command",
        lastEventAt: now.addingTimeInterval(1),
        completedAt: nil,
        active: true,
        agent: .claudeCode
    )

    let codexAggregate = SessionAggregator.aggregate(
        snapshots: [codexDone, claudeWorking],
        settings: HaloSettings(paused: false, installedAt: now.addingTimeInterval(-60), acknowledged: [:]),
        focusedAgent: .codex,
        now: now.addingTimeInterval(2)
    )
    expect(codexAggregate.focusedAgent, .codex, "Codex aggregate should stamp focus")
    expect(codexAggregate.state, .done, "Codex focus should ignore active Claude state")
    expect(codexAggregate.detail, "CodexProject - Complete", "Codex focus detail")
    expect(codexAggregate.sessions.map(\.threadId), ["codex-done"], "Codex focus sessions")

    let claudeAggregate = SessionAggregator.aggregate(
        snapshots: [codexDone, claudeWorking],
        settings: HaloSettings(paused: false, installedAt: now.addingTimeInterval(-60), acknowledged: [:]),
        focusedAgent: .claudeCode,
        now: now.addingTimeInterval(2)
    )
    expect(claudeAggregate.focusedAgent, .claudeCode, "Claude aggregate should stamp focus")
    expect(claudeAggregate.state, .working, "Claude focus should use Claude state")
    expect(claudeAggregate.detail, "ClaudeProject - Running command", "Claude focus detail")
    expect(claudeAggregate.sessions.map(\.threadId), ["claude-working"], "Claude focus sessions")
}

func testAggregatorIdleDetailUsesFocusedAgent() {
    let now = ISO8601DateFormatter().date(from: "2026-06-13T02:00:00Z")!

    let codexAggregate = SessionAggregator.aggregate(
        snapshots: [],
        settings: HaloSettings(installedAt: now.addingTimeInterval(-60)),
        focusedAgent: .codex,
        now: now
    )
    let claudeAggregate = SessionAggregator.aggregate(
        snapshots: [],
        settings: HaloSettings(installedAt: now.addingTimeInterval(-60)),
        focusedAgent: .claudeCode,
        now: now
    )

    expect(codexAggregate.detail, "Codex is standing by", "Codex standby detail")
    expect(claudeAggregate.detail, "Claude Code is standing by", "Claude standby detail")
}

func testAggregatorDoesNotInjectCodexFailureForClaudeFocus() {
    let now = ISO8601DateFormatter().date(from: "2026-06-13T02:00:00Z")!
    let failure = CodexFailure(detail: "认证已失效", eventAt: now)
    let aggregate = SessionAggregator.aggregate(
        snapshots: [],
        settings: HaloSettings(installedAt: now.addingTimeInterval(-600)),
        recentFailure: failure,
        codexRunning: true,
        focusedAgent: .claudeCode,
        now: now
    )

    expect(aggregate.state, .idle, "Claude focus should ignore Codex synthetic failure")
    expect(aggregate.detail, "Claude Code is standing by", "Claude focus should keep Claude standby")
    expect(aggregate.sessions.isEmpty, "Claude focus should not include synthetic Codex session")
}

func testAggregatorReturnsReadyAfterCompletedSessionSettles() {
    let now = ISO8601DateFormatter().date(from: "2026-06-13T02:00:00Z")!
    let completion = SessionSnapshot(
        threadId: "done",
        projectName: "ClaudeProject",
        workingDirectory: "",
        state: .done,
        action: "Complete",
        lastEventAt: now,
        completedAt: now,
        active: false,
        agent: .claudeCode
    )

    let fresh = SessionAggregator.aggregate(
        snapshots: [completion],
        settings: HaloSettings(installedAt: now.addingTimeInterval(-60)),
        focusedAgent: .claudeCode,
        now: now.addingTimeInterval(2)
    )
    expect(fresh.state, .done, "fresh completion should show done")

    let settled = SessionAggregator.aggregate(
        snapshots: [completion],
        settings: HaloSettings(installedAt: now.addingTimeInterval(-60)),
        focusedAgent: .claudeCode,
        now: now.addingTimeInterval(12)
    )
    expect(settled.state, .idle, "settled completion should return ready")
    expect(settled.sessions.isEmpty, "settled completion should no longer be visible")
}

func testAggregatorKeepsCodexCompletionVisibleUntilAcknowledged() {
    let now = ISO8601DateFormatter().date(from: "2026-06-13T02:00:00Z")!
    let completion = SessionSnapshot(
        threadId: "codex-done",
        projectName: "CodexProject",
        workingDirectory: "",
        state: .done,
        action: "Complete",
        lastEventAt: now,
        completedAt: now,
        active: false,
        agent: .codex
    )

    let aggregate = SessionAggregator.aggregate(
        snapshots: [completion],
        settings: HaloSettings(installedAt: now.addingTimeInterval(-60)),
        focusedAgent: .codex,
        now: now.addingTimeInterval(12)
    )

    expect(aggregate.state, .done, "Codex completion should remain visible until acknowledged")
    expect(aggregate.sessions.map(\.threadId), ["codex-done"], "Codex completion should stay in visible sessions")
}

func testClaudeReducerMapsTranscriptEvents() {
    let now = ISO8601DateFormatter().date(from: "2026-06-13T02:00:00Z")!
    var reducer = ClaudeSessionReducer(filePath: "/tmp/304976ed-0876-44e9-99ce-2c9a74ab4ee2.jsonl", now: now)

    reducer.consume(jsonLine: #"{"type":"user","message":{"role":"user","content":"Build Claude status"},"uuid":"user-1","timestamp":"2026-06-13T02:00:00Z","cwd":"/Users/wjs/work/pyproj/AgentHalo","sessionId":"claude-thread"}"#, now: now)
    expect(reducer.snapshot.threadId, "claude-thread", "Claude thread id")
    expect(reducer.snapshot.projectName, "AgentHalo", "Claude project name")
    expect(reducer.snapshot.state, .thinking, "Claude prompt state")
    expect(reducer.snapshot.action, "Thinking", "Claude prompt action")
    expect(reducer.snapshot.active, "Claude prompt should be active")
    expect(reducer.snapshot.agent, .claudeCode, "Claude reducer should stamp Claude Code agent")

    reducer.consume(jsonLine: #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"swift build"}}]},"uuid":"assistant-1","timestamp":"2026-06-13T02:00:01Z","cwd":"/Users/wjs/work/pyproj/AgentHalo","sessionId":"claude-thread"}"#, now: now.addingTimeInterval(1))
    expect(reducer.snapshot.state, .working, "Claude tool use state")
    expect(reducer.snapshot.action, "Running command", "Claude tool use action")

    reducer.consume(jsonLine: #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_1","type":"tool_result","content":"ok","is_error":false}]},"uuid":"tool-result-1","timestamp":"2026-06-13T02:00:02Z","cwd":"/Users/wjs/work/pyproj/AgentHalo","sessionId":"claude-thread"}"#, now: now.addingTimeInterval(2))
    expect(reducer.snapshot.state, .working, "Claude tool result visible state")
    expect(reducer.snapshot.action, "Reviewing result", "Claude tool result action")

    reducer.applyWorkingVisibility(now: now.addingTimeInterval(4))
    expect(reducer.snapshot.state, .thinking, "Claude tool result should return to thinking")

    reducer.consume(jsonLine: #"{"type":"system","subtype":"turn_duration","durationMs":3000,"timestamp":"2026-06-13T02:00:05Z","cwd":"/Users/wjs/work/pyproj/AgentHalo","sessionId":"claude-thread"}"#, now: now.addingTimeInterval(5))
    expect(reducer.snapshot.state, .done, "Claude turn duration state")
    expect(reducer.snapshot.action, "Complete", "Claude turn duration action")
    expect(!reducer.snapshot.active, "Claude completion should be inactive")
    expect(reducer.snapshot.completedAt != nil, "Claude completion should set completion time")
}

func testClaudeReducerIgnoresLocalCommandUserRecords() {
    let now = ISO8601DateFormatter().date(from: "2026-06-13T02:00:00Z")!
    var reducer = ClaudeSessionReducer(filePath: "/tmp/local-command.jsonl", now: now)

    reducer.consume(jsonLine: #"{"type":"user","message":{"role":"user","content":"Build Claude status"},"timestamp":"2026-06-13T01:59:55Z","cwd":"/Users/wjs/work/pyproj/AgentHalo","sessionId":"claude-local-command"}"#, now: now.addingTimeInterval(-5))
    reducer.consume(jsonLine: #"{"type":"system","subtype":"turn_duration","durationMs":3000,"timestamp":"2026-06-13T01:59:58Z","cwd":"/Users/wjs/work/pyproj/AgentHalo","sessionId":"claude-local-command"}"#, now: now.addingTimeInterval(-2))
    reducer.consume(jsonLine: #"{"type":"user","isMeta":true,"message":{"role":"user","content":"<local-command-caveat>Caveat: The messages below were generated by the user while running local commands. DO NOT respond to these messages or otherwise consider them in your response unless the user explicitly asks you to.</local-command-caveat>"},"timestamp":"2026-06-13T02:00:00Z","cwd":"/Users/wjs/work/pyproj/AgentHalo","sessionId":"claude-local-command"}"#, now: now)
    reducer.consume(jsonLine: #"{"type":"user","message":{"role":"user","content":"<command-name>/clear</command-name>\n<command-message>clear</command-message>\n<command-args></command-args>"},"timestamp":"2026-06-13T02:00:01Z","cwd":"/Users/wjs/work/pyproj/AgentHalo","sessionId":"claude-local-command"}"#, now: now.addingTimeInterval(1))
    reducer.consume(jsonLine: #"{"type":"user","message":{"role":"user","content":"<local-command-stdout>(no content)</local-command-stdout>"},"timestamp":"2026-06-13T02:00:02Z","cwd":"/Users/wjs/work/pyproj/AgentHalo","sessionId":"claude-local-command"}"#, now: now.addingTimeInterval(2))

    expect(reducer.snapshot.state, .done, "Claude local command output should not reactivate a completed turn")
    expect(!reducer.snapshot.active, "Claude local command should not activate the session")
}

func testClaudeHookReducerMapsLifecycleEvents() {
    let now = ISO8601DateFormatter().date(from: "2026-06-16T04:00:00Z")!
    var reducer = ClaudeHookStatusReducer(threadId: "hook-thread", now: now)

    reducer.consume(jsonLine: #"{"timestamp":"2026-06-16T04:00:00Z","event":"UserPromptSubmit","sessionId":"hook-thread","cwd":"/Users/wjs/work/pyproj/AgentHalo","source":"claude-hook"}"#, now: now)
    expect(reducer.snapshot.threadId, "hook-thread", "hook thread id")
    expect(reducer.snapshot.projectName, "AgentHalo", "hook project name")
    expect(reducer.snapshot.state, .thinking, "UserPromptSubmit should enter thinking")
    expect(reducer.snapshot.action, "Thinking", "UserPromptSubmit action")
    expect(reducer.snapshot.active, true, "UserPromptSubmit should activate")
    expect(reducer.snapshot.agent, .claudeCode, "hook reducer should stamp Claude Code agent")

    reducer.consume(jsonLine: #"{"timestamp":"2026-06-16T04:00:01Z","event":"PreToolUse","sessionId":"hook-thread","cwd":"/Users/wjs/work/pyproj/AgentHalo","toolName":"Bash","source":"claude-hook"}"#, now: now.addingTimeInterval(1))
    expect(reducer.snapshot.state, .working, "PreToolUse should enter working")
    expect(reducer.snapshot.action, "Running command", "PreToolUse should map Bash to friendly command action")

    reducer.consume(jsonLine: #"{"timestamp":"2026-06-16T04:00:02Z","event":"PostToolUse","sessionId":"hook-thread","cwd":"/Users/wjs/work/pyproj/AgentHalo","toolName":"Bash","source":"claude-hook"}"#, now: now.addingTimeInterval(2))
    expect(reducer.snapshot.state, .working, "PostToolUse should remain briefly working")
    expect(reducer.snapshot.action, "Reviewing result", "PostToolUse action")

    // Visibility window is anchored on the event timestamp (04:00:02 + 1.8s = 04:00:03.8),
    // not on `now`. A delayed tick at 04:00:04 must already see the fade.
    reducer.applyWorkingVisibility(now: now.addingTimeInterval(4))
    expect(reducer.snapshot.state, .thinking, "PostToolUse should settle back to thinking")

    reducer.consume(jsonLine: #"{"timestamp":"2026-06-16T04:00:05Z","event":"Stop","sessionId":"hook-thread","cwd":"/Users/wjs/work/pyproj/AgentHalo","source":"claude-hook"}"#, now: now.addingTimeInterval(5))
    expect(reducer.snapshot.state, .done, "Stop should enter done")
    expect(reducer.snapshot.action, "Complete", "Stop action")
    expect(reducer.snapshot.active, false, "Stop should deactivate")
    expect(reducer.snapshot.completedAt, now.addingTimeInterval(5), "Stop should set completedAt")
}

func testClaudeHookReducerPostToolUseFailureSurfacesThenSettles() {
    let now = ISO8601DateFormatter().date(from: "2026-06-16T04:00:00Z")!
    var reducer = ClaudeHookStatusReducer(threadId: "tool-failure", now: now)

    reducer.consume(jsonLine: #"{"timestamp":"2026-06-16T04:00:00Z","event":"UserPromptSubmit","sessionId":"tool-failure","cwd":"/tmp","source":"claude-hook"}"#, now: now)
    reducer.consume(jsonLine: #"{"timestamp":"2026-06-16T04:00:01Z","event":"PreToolUse","sessionId":"tool-failure","cwd":"/tmp","toolName":"Bash","source":"claude-hook"}"#, now: now.addingTimeInterval(1))
    reducer.consume(jsonLine: #"{"timestamp":"2026-06-16T04:00:02Z","event":"PostToolUseFailure","sessionId":"tool-failure","cwd":"/tmp","toolName":"Bash","errorText":"exit 1","source":"claude-hook"}"#, now: now.addingTimeInterval(2))

    expect(reducer.snapshot.state, .working, "PostToolUseFailure should stay briefly working")
    expect(reducer.snapshot.action, "Tool failed", "PostToolUseFailure action")
    expect(reducer.snapshot.active, true, "PostToolUseFailure keeps the turn active")

    reducer.applyWorkingVisibility(now: now.addingTimeInterval(4))
    expect(reducer.snapshot.state, .thinking, "PostToolUseFailure fades back to thinking after the visibility window")
}

func testClaudeHookReducerPermissionPromptHoldsUntilResolved() {
    let now = ISO8601DateFormatter().date(from: "2026-06-16T04:00:00Z")!
    var reducer = ClaudeHookStatusReducer(threadId: "perm", now: now)

    reducer.consume(jsonLine: #"{"timestamp":"2026-06-16T04:00:00Z","event":"UserPromptSubmit","sessionId":"perm","cwd":"/tmp","source":"claude-hook"}"#, now: now)
    reducer.consume(jsonLine: #"{"timestamp":"2026-06-16T04:00:01Z","event":"Notification","sessionId":"perm","cwd":"/tmp","notificationType":"permission_prompt","source":"claude-hook"}"#, now: now.addingTimeInterval(1))

    expect(reducer.snapshot.state, .working, "permission_prompt should show working")
    expect(reducer.snapshot.action, "Awaiting permission", "permission_prompt action")
    expect(reducer.snapshot.active, true, "permission_prompt keeps the turn active")

    // No fade-out: even minutes later, the state must still reflect the pending prompt
    // until a real PreToolUse / Stop arrives.
    reducer.applyWorkingVisibility(now: now.addingTimeInterval(120))
    expect(reducer.snapshot.state, .working, "permission_prompt should not fade automatically")
    expect(reducer.snapshot.action, "Awaiting permission", "permission_prompt action persists")
}

func testClaudeHookReducerIdlePromptShowsAwaitingReply() {
    let now = ISO8601DateFormatter().date(from: "2026-06-16T04:00:00Z")!
    var reducer = ClaudeHookStatusReducer(threadId: "idle", now: now)

    reducer.consume(jsonLine: #"{"timestamp":"2026-06-16T04:00:00Z","event":"UserPromptSubmit","sessionId":"idle","cwd":"/tmp","source":"claude-hook"}"#, now: now)
    reducer.consume(jsonLine: #"{"timestamp":"2026-06-16T04:00:01Z","event":"Notification","sessionId":"idle","cwd":"/tmp","notificationType":"idle_prompt","source":"claude-hook"}"#, now: now.addingTimeInterval(1))

    expect(reducer.snapshot.state, .thinking, "idle_prompt should keep thinking")
    expect(reducer.snapshot.action, "Awaiting reply", "idle_prompt action")
    expect(reducer.snapshot.active, true, "idle_prompt keeps the turn active")
}

func testClaudeHookReducerStopFailureMapsToError() {
    let now = ISO8601DateFormatter().date(from: "2026-06-16T04:00:00Z")!
    var reducer = ClaudeHookStatusReducer(threadId: "hook-failure", now: now)

    reducer.consume(jsonLine: #"{"timestamp":"2026-06-16T04:00:00Z","event":"UserPromptSubmit","sessionId":"hook-failure","cwd":"/tmp","source":"claude-hook"}"#, now: now)
    reducer.consume(jsonLine: #"{"timestamp":"2026-06-16T04:00:01Z","event":"StopFailure","sessionId":"hook-failure","cwd":"/tmp","source":"claude-hook"}"#, now: now.addingTimeInterval(1))

    expect(reducer.snapshot.state, .error, "StopFailure should become error")
    expect(reducer.snapshot.action, "Claude Code stopped with an error", "StopFailure action")
    expect(reducer.snapshot.active, false, "StopFailure should deactivate")
}

func testClaudeMonitorHandlesDiscoveryPendingLinesAndTruncation() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agent-halo-claude-monitor-\(UUID().uuidString)", isDirectory: true)
    let projects = root.appendingPathComponent("projects", isDirectory: true)
    let project = projects.appendingPathComponent("-Users-wjs-work-pyproj-AgentHalo", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let file = project.appendingPathComponent("\(UUID().uuidString).jsonl")
    let now = ISO8601DateFormatter().date(from: "2026-06-13T02:00:00Z")!
    try Data(#"{"type":"user","message":{"role":"user","content":"Build Claude status"},"timestamp":"2026-06-13T02:00:00Z","cwd":"/Users/wjs/work/pyproj/AgentHalo","sessionId":"claude-monitor"}"#.utf8).write(to: file)

    let monitor = ClaudeSessionMonitor(projectsRoot: projects)
    _ = monitor.refresh(now: now)
    expect(monitor.snapshots().first?.state == .idle, "Claude partial line should wait for newline")

    try FileHandle(forWritingTo: file).withClose {
        try $0.seekToEnd()
        try $0.write(contentsOf: Data("\n".utf8))
    }
    _ = monitor.refresh(now: now.addingTimeInterval(1))
    expect(monitor.snapshots().first?.state == .thinking, "Claude completed pending line should parse")
    expect(monitor.snapshots().first?.projectName, "AgentHalo", "Claude monitor project name")
    expect(monitor.snapshots().first?.agent, .claudeCode, "Claude monitor snapshots should carry Claude Code agent")

    try Data(#"{"type":"system","subtype":"turn_duration","durationMs":3000,"timestamp":"2026-06-13T02:00:02Z","cwd":"/Users/wjs/work/pyproj/AgentHalo","sessionId":"claude-monitor"}"#.utf8).write(to: file)
    _ = monitor.refresh(now: now.addingTimeInterval(2))
    expect(monitor.snapshots().first?.state == .idle, "Claude truncated partial line should not parse")
}

func testClaudeHookMonitorHandlesPendingLinesAndTruncation() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agent-halo-claude-hook-monitor-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let statusFile = root.appendingPathComponent("claude-code-status.jsonl")
    let now = ISO8601DateFormatter().date(from: "2026-06-16T04:00:00Z")!

    try Data(#"{"timestamp":"2026-06-16T04:00:00Z","event":"UserPromptSubmit","sessionId":"hook-monitor","cwd":"/Users/wjs/work/pyproj/AgentHalo","source":"claude-hook"}"#.utf8).write(to: statusFile)

    let monitor = ClaudeHookStatusMonitor(statusURL: statusFile)
    _ = monitor.refresh(now: now)
    expect(monitor.snapshots().first?.state == .idle, "partial hook line should wait for newline")

    try FileHandle(forWritingTo: statusFile).withClose {
        try $0.seekToEnd()
        try $0.write(contentsOf: Data("\n".utf8))
    }
    _ = monitor.refresh(now: now.addingTimeInterval(1))
    expect(monitor.snapshots().first?.state == .thinking, "completed hook line should parse")
    expect(monitor.snapshots().first?.agent, .claudeCode, "hook monitor snapshots should carry Claude Code agent")

    try Data(#"{"timestamp":"2026-06-16T04:00:02Z","event":"Stop","sessionId":"hook-monitor","cwd":"/Users/wjs/work/pyproj/AgentHalo","source":"claude-hook"}"#.utf8).write(to: statusFile)
    _ = monitor.refresh(now: now.addingTimeInterval(2))
    expect(monitor.snapshots().first?.state == .idle, "truncated partial hook line should not parse")
}

func testClaudeMonitorIgnoresSubagentTranscripts() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agent-halo-claude-subagents-\(UUID().uuidString)", isDirectory: true)
    let projects = root.appendingPathComponent("projects", isDirectory: true)
    let project = projects.appendingPathComponent("-Users-wjs-work-pyproj-AgentHalo", isDirectory: true)
    let subagents = project
        .appendingPathComponent("parent-session", isDirectory: true)
        .appendingPathComponent("subagents", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
    let mainFile = project.appendingPathComponent("\(UUID().uuidString).jsonl")
    let subagentFile = subagents.appendingPathComponent("agent-active.jsonl")
    let now = ISO8601DateFormatter().date(from: "2026-06-13T02:00:00Z")!
    let mainTranscript = [
        #"{"type":"user","message":{"role":"user","content":"Build Claude status"},"timestamp":"2026-06-13T02:00:00Z","cwd":"/Users/wjs/work/pyproj/AgentHalo","sessionId":"claude-main"}"#,
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Done"}]},"timestamp":"2026-06-13T02:00:01Z","cwd":"/Users/wjs/work/pyproj/AgentHalo","sessionId":"claude-main"}"#,
        #"{"type":"system","subtype":"turn_duration","durationMs":1000,"timestamp":"2026-06-13T02:00:02Z","cwd":"/Users/wjs/work/pyproj/AgentHalo","sessionId":"claude-main"}"#
    ].joined(separator: "\n") + "\n"
    let subagentTranscript = [
        #"{"type":"user","isSidechain":true,"message":{"role":"user","content":"subtask"},"timestamp":"2026-06-13T02:00:03Z","cwd":"/Users/wjs/work/pyproj/AgentHalo","sessionId":"claude-subagent"}"#,
        #"{"type":"assistant","isSidechain":true,"message":{"role":"assistant","content":[{"type":"text","text":"subtask result"}]},"timestamp":"2026-06-13T02:00:04Z","cwd":"/Users/wjs/work/pyproj/AgentHalo","sessionId":"claude-subagent"}"#
    ].joined(separator: "\n") + "\n"
    try Data(mainTranscript.utf8).write(to: mainFile)
    try Data(subagentTranscript.utf8).write(to: subagentFile)

    let monitor = ClaudeSessionMonitor(projectsRoot: projects)
    _ = monitor.refresh(now: now.addingTimeInterval(5))

    expect(monitor.snapshots().map(\.threadId), ["claude-main"], "Claude monitor should ignore subagent transcripts")
    expect(monitor.snapshots().first?.state, .done, "main Claude transcript should still be visible as done")
}

func testClaudeStatusMergerPrefersHookDoneOverTranscriptThinking() {
    let now = ISO8601DateFormatter().date(from: "2026-06-16T04:00:10Z")!
    let hookDone = SessionSnapshot(
        threadId: "same-thread",
        projectName: "AgentHalo",
        workingDirectory: "/Users/wjs/work/pyproj/AgentHalo",
        state: .done,
        action: "Complete",
        lastEventAt: now.addingTimeInterval(-1),
        completedAt: now.addingTimeInterval(-1),
        active: false,
        agent: .claudeCode
    )
    let transcriptThinking = SessionSnapshot(
        threadId: "same-thread",
        projectName: "AgentHalo",
        workingDirectory: "/Users/wjs/work/pyproj/AgentHalo",
        state: .thinking,
        action: "Thinking",
        lastEventAt: now,
        completedAt: nil,
        active: true,
        agent: .claudeCode
    )

    let merged = ClaudeStatusSourceMerger.merge(
        hookSnapshots: [hookDone],
        transcriptSnapshots: [transcriptThinking],
        now: now
    )

    expect(merged.map(\.state), [.done], "recent hook completion should suppress transcript reactivation")
}

func testClaudeStatusMergerUsesTranscriptCompletionWhenHookStopWasMissed() {
    let now = ISO8601DateFormatter().date(from: "2026-06-16T04:00:10Z")!
    let hookWorking = SessionSnapshot(
        threadId: "same-thread",
        projectName: "AgentHalo",
        workingDirectory: "/Users/wjs/work/pyproj/AgentHalo",
        state: .working,
        action: "Running command",
        lastEventAt: now.addingTimeInterval(-5),
        completedAt: nil,
        active: true,
        agent: .claudeCode
    )
    let transcriptDone = SessionSnapshot(
        threadId: "same-thread",
        projectName: "AgentHalo",
        workingDirectory: "/Users/wjs/work/pyproj/AgentHalo",
        state: .done,
        action: "Complete",
        lastEventAt: now.addingTimeInterval(-1),
        completedAt: now.addingTimeInterval(-1),
        active: false,
        agent: .claudeCode
    )

    let merged = ClaudeStatusSourceMerger.merge(
        hookSnapshots: [hookWorking],
        transcriptSnapshots: [transcriptDone],
        now: now
    )

    expect(merged.map(\.state), [.done], "newer transcript completion should recover from a missed hook Stop")
}

func testClaudeStatusMergerSurvivesDuplicateThreadIds() {
    let now = ISO8601DateFormatter().date(from: "2026-06-16T04:00:10Z")!
    let older = SessionSnapshot(
        threadId: "dup",
        projectName: "AgentHalo",
        workingDirectory: "/tmp",
        state: .working,
        action: "Running command",
        lastEventAt: now.addingTimeInterval(-10),
        completedAt: nil,
        active: true,
        agent: .claudeCode
    )
    let newer = SessionSnapshot(
        threadId: "dup",
        projectName: "AgentHalo",
        workingDirectory: "/tmp",
        state: .thinking,
        action: "Thinking",
        lastEventAt: now,
        completedAt: nil,
        active: true,
        agent: .claudeCode
    )

    // Two snapshots sharing the same threadId from a single source must NOT crash;
    // the newer one (by lastEventAt) wins.
    let merged = ClaudeStatusSourceMerger.merge(
        hookSnapshots: [older, newer],
        transcriptSnapshots: [],
        now: now
    )

    expect(merged.count, 1, "duplicate threadIds collapse to one entry")
    expect(merged.first?.state, .thinking, "duplicate-threadId merge keeps the newer snapshot")
}

func testStartupExecutablePathUsesAppBundleRoot() {
    let bundleURL = URL(fileURLWithPath: "/tmp/AgentHalo.app")
    let path = StartupLaunchAgent.executablePath(appBundleURL: bundleURL)
    expect(path, "/tmp/AgentHalo.app/Contents/MacOS/AgentHaloMac", "startup executable path")
}

func testDiagnosticsCreatesParentDirectoryForOutput() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agent-halo-diagnostics-\(UUID().uuidString)", isDirectory: true)
    let output = root.appendingPathComponent("self-test.txt")
    try DiagnosticsOutput.write("PASS\n", to: output.path(percentEncoded: false))
    expect(FileManager.default.fileExists(atPath: output.path(percentEncoded: false)), "diagnostics output should create parent directory")
}

func testHaloMathMatchesProgramConstants() {
    expect(GeneratedHaloSpec.contractVersion, 2, "generated shared contract version")
    expect(GeneratedHaloSpec.releaseVersion, "0.13.0", "generated shared release version")
    expect(GeneratedHaloSpec.state(.attention).label, "NEEDS YOU", "generated state labels")
    expect(GeneratedHaloSpec.friendlyAction("apply_patch"), "Editing files", "generated action rules")
    expect(GeneratedHaloSpec.classifyFailure("server overloaded"), "服务暂时不可用", "generated failure rules")
    expectAlmost(HaloMath.stateBreath(.thinking, time: 1.0), 1.0, tolerance: 0.08, "thinking bright plateau")
    expect(HaloMath.targetPowered(.done, time: 8.0) < 0.20, "done powered should dip close to dark")
    expect(HaloMath.transitionLight(from: 0.9, to: 0.0, progress: 0.99) < 0.01, "steady green transition should finish dark")
    expect(HaloMath.diagnosticBrightDuration(.thinking) < HaloMath.diagnosticBrightDuration(.working), "thinking bright duration shorter than working")
    expectAlmost(HaloMath.diagnosticGapSeparation(0), 40, tolerance: 0.001, "gap repulsion start")
    expectAlmost(HaloMath.diagnosticGapSeparation(1), 150, tolerance: 0.001, "gap repulsion end")
    expect(HaloMath.repulsionDurationFromOrbit(28) > HaloMath.repulsionDurationFromOrbit(80), "slow orbit uses longer repulsion")
}

func testLinearSRGBMixAvoidsGammaLerp() {
    let mixed = HaloMath.mixColor(
        HaloRGB(red: 226, green: 170, blue: 31),
        HaloRGB(red: 52, green: 158, blue: 199),
        amount: 0.5
    )
    expect(mixed.red > 150, "linear red midpoint should be brighter than gamma midpoint")
    expect(mixed.blue > 145, "linear blue midpoint should be brighter than gamma midpoint")
}

func testWindowsStyleVisualTransitionAndMaterial() {
    let from = HaloVisualModel.targetVisual(
        state: .thinking,
        time: 1.0,
        errorPresentation: .flashing,
        steadyDone: false
    )
    let to = HaloVisualModel.targetVisual(
        state: .working,
        time: 0.8,
        errorPresentation: .flashing,
        steadyDone: false
    )
    let dimmed = HaloVisualModel.transitionVisual(from: from, to: to, progress: 0.48)
    expect(dimmed.powered < 0.12, "transition should dim before power-up")
    expect(dimmed.coreWhite > min(from.coreWhite, to.coreWhite) && dimmed.coreWhite < max(from.coreWhite, to.coreWhite), "core white should transition as a scalar")

    let material = HaloVisualModel.materialSnapshot(color: to.color, visual: to, intensity: 1.0)
    expect(material.poweredCore.red > to.color.red, "powered core should move toward white")
    expect(material.glowAlphas[1] > material.glowAlphas[0], "middle glow should be brighter than outer glow")
    expect(material.whiteSparkAlpha > 180, "powered visual should retain a white center spark")
}

func testCompletionDoubleFlashMatchesWindowsCadence() {
    expect(HaloVisualModel.completionDoubleFlash(sinceState: 0.28) > 0.95, "first completion flash should peak early")
    expect(HaloVisualModel.completionDoubleFlash(sinceState: 0.92) > 0.80, "second completion flash should peak later")
    expect(HaloVisualModel.completionDoubleFlash(sinceState: 1.45) < 0.02, "completion flash should fade out")
}

func expectAlmost(_ actual: Double, _ expected: Double, tolerance: Double, _ message: String) {
    if abs(actual - expected) > tolerance {
        fatalError("\(message): expected \(expected) +/- \(tolerance), got \(actual)")
    }
}

testReducesPlanningWorkingAttentionErrorAndCompleteEvents()
testAggregatePrioritizesActionableSessions()
testAcknowledgingCompletedSessionsStoresLatestVisibleCompletionOnly()
testSettingsPersistFormalFieldsAndNormalizePaused()
do {
    try testSettingsDefaultsFocusedAgentToCodexWhenMissing()
} catch {
    fatalError("\(error)")
}
testSettingsPersistsFocusedAgent()
testAcknowledgedErrorVisibilityUsesLatestErrorTime()
testWorkingVisibilityLiveCallOutputAndInitialTail()
testToolFailedDoesNotBecomeFatalError()
do {
    try testMonitorHandlesPendingLinesAndTruncation()
} catch {
    fatalError("\(error)")
}
testAggregatorHidesAcknowledgedErrorsAndShowsStandbyInput()
testFailureClassification()
do {
    try testRateLimitReaderFindsNewestTailRateLimit()
} catch {
    fatalError("\(error)")
}
do {
    try testRateLimitReaderFindsContextUsageAndResetTimes()
} catch {
    fatalError("\(error)")
}
testAggregatorInjectsUnacknowledgedCodexFailureWhenIdle()
testAggregatorFiltersByFocusedAgent()
testAggregatorIdleDetailUsesFocusedAgent()
testAggregatorDoesNotInjectCodexFailureForClaudeFocus()
testClaudeReducerDoesNotCompleteWithoutExplicitCompletionEvent()
testAggregatorReturnsReadyAfterCompletedSessionSettles()
testAggregatorKeepsCodexCompletionVisibleUntilAcknowledged()
testClaudeReducerMapsTranscriptEvents()
testClaudeReducerIgnoresLocalCommandUserRecords()
testClaudeHookReducerMapsLifecycleEvents()
testClaudeHookReducerPostToolUseFailureSurfacesThenSettles()
testClaudeHookReducerPermissionPromptHoldsUntilResolved()
testClaudeHookReducerIdlePromptShowsAwaitingReply()
testClaudeHookReducerStopFailureMapsToError()
do {
    try testClaudeMonitorHandlesDiscoveryPendingLinesAndTruncation()
} catch {
    fatalError("\(error)")
}
do {
    try testClaudeHookMonitorHandlesPendingLinesAndTruncation()
} catch {
    fatalError("\(error)")
}
do {
    try testClaudeMonitorIgnoresSubagentTranscripts()
} catch {
    fatalError("\(error)")
}
testClaudeStatusMergerPrefersHookDoneOverTranscriptThinking()
testClaudeStatusMergerUsesTranscriptCompletionWhenHookStopWasMissed()
testClaudeStatusMergerSurvivesDuplicateThreadIds()
testStartupExecutablePathUsesAppBundleRoot()
do {
    try testDiagnosticsCreatesParentDirectoryForOutput()
} catch {
    fatalError("\(error)")
}
testHaloMathMatchesProgramConstants()
testLinearSRGBMixAvoidsGammaLerp()
testWindowsStyleVisualTransitionAndMaterial()
testCompletionDoubleFlashMatchesWindowsCadence()
print("PASS AgentHaloCore checks")

func testClaudeReducerDoesNotCompleteWithoutExplicitCompletionEvent() {
    let base = ISO8601DateFormatter().date(from: "2026-06-16T08:00:00Z")!
    var reducer = ClaudeSessionReducer(filePath: "/test/session.jsonl", now: base, liveTracking: true)

    let userMessage = """
    {"type":"user","timestamp":"2026-06-16T08:00:01Z","message":{"role":"user","content":"check status"}}
    """
    reducer.consume(jsonLine: userMessage, now: base.addingTimeInterval(1))
    expect(reducer.snapshot.active, true, "Should be active after user message")
    expect(reducer.snapshot.state, .thinking, "Should be thinking")

    reducer.applyWorkingVisibility(now: base.addingTimeInterval(6))
    expect(reducer.snapshot.state, .thinking, "Should still be thinking after 5s (no assistant output yet)")
    expect(reducer.snapshot.active, true, "Should still be active")

    let toolUse = """
    {"type":"assistant","timestamp":"2026-06-16T08:00:07Z","message":{"role":"assistant","content":[{"type":"tool_use","name":"Read"}]}}
    """
    reducer.consume(jsonLine: toolUse, now: base.addingTimeInterval(7))
    expect(reducer.snapshot.state, .working, "Should be working after tool use")

    let toolResult = """
    {"type":"user","timestamp":"2026-06-16T08:00:08Z","message":{"role":"user","content":[{"type":"tool_result"}]}}
    """
    reducer.consume(jsonLine: toolResult, now: base.addingTimeInterval(8))

    reducer.applyWorkingVisibility(now: base.addingTimeInterval(8.5))
    expect(reducer.snapshot.state, .working, "Should extend working visibility")

    reducer.applyWorkingVisibility(now: base.addingTimeInterval(10.0))
    expect(reducer.snapshot.state, .thinking, "Should be thinking after working visibility expires")
    expect(reducer.snapshot.active, true, "Should still be active")

    reducer.applyWorkingVisibility(now: base.addingTimeInterval(12.0))
    expect(reducer.snapshot.state, .thinking, "Should still be thinking (only 2s since thinking started)")

    reducer.applyWorkingVisibility(now: base.addingTimeInterval(14.0))
    expect(reducer.snapshot.state, .thinking, "Should not complete without an explicit Claude completion event")
    expect(reducer.snapshot.active, true, "Should remain active without an explicit Claude completion event")
    expect(reducer.snapshot.completedAt == nil, "Should not set completedAt without an explicit Claude completion event")
}
