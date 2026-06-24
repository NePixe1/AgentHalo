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

func testAggregateRemovesSupersededSessionErrors() {
    let now = ISO8601DateFormatter().date(from: "2026-06-22T04:00:00Z")!
    let oldError = SessionSnapshot(
        threadId: "old-error",
        projectName: "OldProject",
        workingDirectory: "/tmp/old",
        state: .error,
        action: "Interrupted",
        lastEventAt: now.addingTimeInterval(-60),
        completedAt: nil,
        active: false
    )
    let newerWorking = SessionSnapshot(
        threadId: "new-working",
        projectName: "NewProject",
        workingDirectory: "/tmp/new",
        state: .working,
        action: "Running command",
        lastEventAt: now,
        completedAt: nil,
        active: true
    )
    let settings = HaloSettings(installedAt: now.addingTimeInterval(-600))

    let working = SessionAggregator.aggregate(
        snapshots: [oldError, newerWorking],
        settings: settings,
        now: now
    )
    expect(working.state, .working, "newer working session replaces old error")
    expect(working.sessions.map(\.threadId), ["new-working"], "old error removed from display sessions")

    let newerDone = SessionSnapshot(
        threadId: "new-done",
        projectName: "NewProject",
        workingDirectory: "/tmp/new",
        state: .done,
        action: "Complete",
        lastEventAt: now,
        completedAt: now,
        active: false
    )
    let done = SessionAggregator.aggregate(
        snapshots: [oldError, newerDone],
        settings: settings,
        now: now
    )
    expect(done.sessions.map(\.threadId), ["new-done"], "newer completion replaces old error")

    let acknowledged = settings.acknowledgingCompletedSessions([newerDone])
    let ready = SessionAggregator.aggregate(
        snapshots: [oldError, newerDone],
        settings: acknowledged,
        now: now
    )
    expect(ready.state, .idle, "acknowledged newer completion does not resurrect old error")
    expect(ready.sessions.isEmpty, "superseded error remains absent after acknowledgement")

    let newerError = SessionSnapshot(
        threadId: "new-error",
        projectName: "NewProject",
        workingDirectory: "/tmp/new",
        state: .error,
        action: "Interrupted",
        lastEventAt: now,
        completedAt: nil,
        active: false
    )
    let olderWorking = SessionSnapshot(
        threadId: "old-working",
        projectName: "OldProject",
        workingDirectory: "/tmp/old",
        state: .working,
        action: "Running command",
        lastEventAt: now.addingTimeInterval(-60),
        completedAt: nil,
        active: true
    )
    let latestError = SessionAggregator.aggregate(
        snapshots: [olderWorking, newerError],
        settings: settings,
        now: now
    )
    expect(latestError.state, .error, "latest error remains primary")
    expect(
        latestError.sessions.map(\.threadId),
        ["new-error", "old-working"],
        "active sessions remain available behind the latest error"
    )

    let metadataOnly = SessionSnapshot(
        threadId: "metadata-only",
        projectName: "Codex",
        workingDirectory: "/tmp/new",
        state: .idle,
        action: "Ready",
        lastEventAt: now,
        completedAt: nil,
        active: false
    )
    let unchanged = SessionAggregator.aggregate(
        snapshots: [oldError, metadataOnly],
        settings: settings,
        now: now
    )
    expect(unchanged.state, .error, "metadata-only session does not suppress error")
    expect(unchanged.sessions.map(\.threadId), ["old-error"], "metadata-only session stays invisible")
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
    defer {
        try? FileManager.default.removeItem(at: root)
    }
    let url = root.appendingPathComponent("settings.json")
    let store = SettingsStore(settingsURL: url)
    let installedAt = ISO8601DateFormatter().date(from: "2026-06-13T02:00:00Z")!
    let acknowledgedErrorAt = installedAt.addingTimeInterval(60)
    let settings = HaloSettings(
        hasPosition: true,
        left: 110,
        top: 220,
        haloSize: 144,
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
    expect(loaded.haloSize, 144, "haloSize should persist")
    expect(loaded.alwaysOnTop, false, "alwaysOnTop should persist")
    expect(loaded.paused, false, "paused should normalize false on load")
    expect(loaded.acknowledged, ["thread": installedAt], "acknowledged should persist")
    expect(loaded.acknowledgedErrorAt, acknowledgedErrorAt, "acknowledgedErrorAt should persist")
}

func testSettingsDefaultsPreferredDisplayPlacementForLegacyFiles() throws {
    let data = Data(#"{"hasPosition":true,"left":1800,"top":600}"#.utf8)
    let settings = try JSONDecoder().decode(HaloSettings.self, from: data)

    expect(settings.preferredDisplayUUID == nil, "legacy settings should not invent a display UUID")
    expect(settings.preferredDisplayOffsetX == nil, "legacy settings should not invent an x offset")
    expect(settings.preferredDisplayOffsetY == nil, "legacy settings should not invent a y offset")
}

func testSettingsPersistPreferredDisplayPlacement() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agent-halo-display-placement-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: root)
    }
    let url = root.appendingPathComponent("settings.json")
    let store = SettingsStore(settingsURL: url)
    let settings = HaloSettings(
        hasPosition: true,
        left: 1800,
        top: 600,
        preferredDisplayUUID: "secondary-display",
        preferredDisplayOffsetX: 120,
        preferredDisplayOffsetY: 80
    )

    store.save(settings)
    let loaded = store.load()

    expect(loaded.preferredDisplayUUID, "secondary-display", "preferred display UUID")
    expect(loaded.preferredDisplayOffsetX, 120, "preferred display x offset")
    expect(loaded.preferredDisplayOffsetY, 80, "preferred display y offset")
}

func testSettingsUsesDefaultHaloSizeForLegacyFilesAndClampsInvalidSizes() {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agent-halo-size-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: root)
    }
    let legacyURL = root.appendingPathComponent("legacy.json")
    let smallURL = root.appendingPathComponent("small.json")
    let largeURL = root.appendingPathComponent("large.json")
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try! """
    {
      "acknowledged" : {},
      "alwaysOnTop" : true,
      "alwaysOnTopBehaviorVersion" : 1,
      "hasPosition" : false,
      "installedAt" : "2026-06-13T12:47:19Z",
      "left" : 0,
      "paused" : false,
      "top" : 0
    }
    """.data(using: .utf8)!.write(to: legacyURL)
    try! """
    {
      "acknowledged" : {},
      "alwaysOnTop" : true,
      "alwaysOnTopBehaviorVersion" : 1,
      "haloSize" : 24,
      "hasPosition" : false,
      "installedAt" : "2026-06-13T12:47:19Z",
      "left" : 0,
      "paused" : false,
      "top" : 0
    }
    """.data(using: .utf8)!.write(to: smallURL)
    try! """
    {
      "acknowledged" : {},
      "alwaysOnTop" : true,
      "alwaysOnTopBehaviorVersion" : 1,
      "haloSize" : 300,
      "hasPosition" : false,
      "installedAt" : "2026-06-13T12:47:19Z",
      "left" : 0,
      "paused" : false,
      "top" : 0
    }
    """.data(using: .utf8)!.write(to: largeURL)

    expect(
        SettingsStore(settingsURL: legacyURL).load().haloSize,
        HaloSettings.defaultHaloSize,
        "legacy settings should use default halo size"
    )
    expect(
        SettingsStore(settingsURL: smallURL).load().haloSize,
        HaloSettings.minimumHaloSize,
        "undersized halo setting should clamp to minimum"
    )
    expect(
        SettingsStore(settingsURL: largeURL).load().haloSize,
        HaloSettings.maximumHaloSize,
        "oversized halo setting should clamp to maximum"
    )
}

func testSettingsMigratesLegacyAlwaysOnTopOffToDefaultOn() {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agent-halo-legacy-topmost-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: root)
    }
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
    defer {
        try? FileManager.default.removeItem(at: root)
    }
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
    defer {
        try? FileManager.default.removeItem(at: root)
    }
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
    defer {
        try? FileManager.default.removeItem(at: root)
    }
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

func testSessionReducerCapturesCodexSessionDetailsAndRateLimitAvailability() {
    var reducer = SessionReducer(filePath: "/tmp/codex-session-details.jsonl")
    reducer.consume(jsonLine: #"{"type":"session_meta","payload":{"id":"codex-details","cwd":"/Users/wjs/work/pyproj/AgentHalo"}}"#)
    reducer.consume(jsonLine: #"{"type":"turn_context","payload":{"model":"gpt-5.5"}}"#)
    reducer.consume(jsonLine: #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":38000,"output_tokens":1200},"last_token_usage":{"input_tokens":20000},"model_context_window":100000}}}"#)

    expect(reducer.snapshot.projectName, "AgentHalo", "Codex detail project")
    expect(reducer.snapshot.modelName, "gpt-5.5", "Codex detail model")
    expect(reducer.snapshot.inputTokens, 38_000, "Codex detail input tokens")
    expect(reducer.snapshot.outputTokens, 1_200, "Codex detail output tokens")
    expect(reducer.snapshot.hasRateLimits, false, "third-party Codex should have no rate limits")
    expect(reducer.snapshot.contextUsedPercent, 20, "Codex context should come from the current session")

    reducer.consume(jsonLine: #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":40000,"output_tokens":1500}},"rate_limits":{"primary":{},"secondary":{}}}}"#)

    expect(reducer.snapshot.inputTokens, 40_000, "Codex detail input tokens should refresh")
    expect(reducer.snapshot.outputTokens, 1_500, "Codex detail output tokens should refresh")
    expect(reducer.snapshot.hasRateLimits, true, "subscription Codex should report rate limits")
}

func testToolFailedDoesNotBecomeFatalError() {
    let now = ISO8601DateFormatter().date(from: "2026-06-13T02:00:00Z")!
    var reducer = SessionReducer(filePath: "/tmp/tool-failed.jsonl", now: now, liveTracking: true)
    reducer.consume(jsonLine: #"{"timestamp":"2026-06-13T02:00:00Z","type":"event_msg","payload":{"type":"task_started"}}"#, now: now)
    reducer.consume(jsonLine: #"{"timestamp":"2026-06-13T02:00:01Z","type":"event_msg","payload":{"type":"tool_failed"}}"#, now: now.addingTimeInterval(1))
    expect(reducer.snapshot.state, .thinking, "tool_failed should keep active thinking state")
    expect(reducer.snapshot.active, true, "tool_failed should not deactivate session")
}

func testClaudeHookConfiguratorWritesUserSettingsNotLegacyClaudeJson() throws {
    let home = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agent-halo-hook-config-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: home)
    }
    let claudeDir = home.appendingPathComponent(".claude", isDirectory: true)
    let settingsURL = claudeDir.appendingPathComponent("settings.json")
    let legacyURL = home.appendingPathComponent(".claude.json")
    let bundledHook = home.appendingPathComponent("bundle-hook")
    try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
    try Data("fake hook".utf8).write(to: bundledHook)
    try Data(#"{"hooks":{"PreToolUse":[{"matcher":".*","hooks":[{"type":"command","command":"/old/claude-code-status-hook PreToolUse"}]}]}}"#.utf8)
        .write(to: legacyURL)
    try Data(
        #"{"env":{"AGENT_HALO_TEST":"1"},"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"/usr/local/bin/existing-hook PreToolUse"}]}]}}"#.utf8
    ).write(to: settingsURL)

    ClaudeHookConfigurator.configure(homeDirectory: home, bundledHookBinary: bundledHook)

    let settings = try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any]
    let hooks = settings?["hooks"] as? [String: Any]
    let preToolUse = hooks?["PreToolUse"] as? [[String: Any]]
    expect(preToolUse?.count, 2, "existing PreToolUse hook should be preserved and Agent Halo should append one entry")
    let existingHooks = preToolUse?.first?["hooks"] as? [[String: Any]]
    let existingCommand = existingHooks?.first?["command"] as? String
    expect(existingCommand, "/usr/local/bin/existing-hook PreToolUse", "existing user hook should not be overwritten")
    let agentHaloHooks = preToolUse?.last?["hooks"] as? [[String: Any]]
    let command = agentHaloHooks?.first?["command"] as? String
    expect(command, "\(home.path)/.agent-halo/claude-code-status-hook PreToolUse", "Agent Halo hook should be appended to ~/.claude/settings.json")
    expect(hooks?["PostToolBatch"] != nil, true, "PostToolBatch hook should be configured")
    expect(hooks?["PermissionRequest"] != nil, true, "PermissionRequest hook should be configured")
    expect(hooks?["PermissionDenied"] != nil, true, "PermissionDenied hook should be configured")
    expect(settings?["env"] as? [String: String], ["AGENT_HALO_TEST": "1"], "existing settings should be preserved")

    let legacy = try JSONSerialization.jsonObject(with: Data(contentsOf: legacyURL)) as? [String: Any]
    let legacyHooks = legacy?["hooks"] as? [String: Any]
    let legacyPreToolUse = legacyHooks?["PreToolUse"] as? [[String: Any]]
    let legacyEntryHooks = legacyPreToolUse?.first?["hooks"] as? [[String: Any]]
    let legacyCommand = legacyEntryHooks?.first?["command"] as? String
    expect(legacyCommand, "/old/claude-code-status-hook PreToolUse", "legacy ~/.claude.json should not be rewritten")
}

func testClaudeStatusLineConfiguratorPreservesAndChainsExistingCommand() throws {
    let home = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agent-halo-statusline-config-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: home)
    }
    let claude = home.appendingPathComponent(".claude", isDirectory: true)
    try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
    let settingsURL = claude.appendingPathComponent("settings.json")
    let originalCommand = "~/.claude/ccline/ccline"
    let settings: [String: Any] = [
        "statusLine": ["type": "command", "command": originalCommand, "padding": 0],
        "theme": "dark"
    ]
    try JSONSerialization.data(withJSONObject: settings).write(to: settingsURL)
    let bundledProxy = home.appendingPathComponent("bundled-statusline-proxy")
    try Data("proxy".utf8).write(to: bundledProxy)

    ClaudeStatusLineConfigurator.configure(homeDirectory: home, bundledProxyBinary: bundledProxy)
    ClaudeStatusLineConfigurator.configure(homeDirectory: home, bundledProxyBinary: bundledProxy)

    let configuredData = try Data(contentsOf: settingsURL)
    let configured = try JSONSerialization.jsonObject(with: configuredData) as! [String: Any]
    let statusLine = configured["statusLine"] as! [String: Any]
    let installedProxy = home.appendingPathComponent(".agent-halo/claude-code-statusline-proxy")
    let storedCommand = home.appendingPathComponent(".agent-halo/claude-code-statusline-original-command")

    expect(statusLine["command"] as? String, installedProxy.path, "Claude statusline should use AgentHalo proxy")
    expect(statusLine["padding"] as? Int, 0, "Claude statusline padding should be preserved")
    expect(configured["theme"] as? String, "dark", "unrelated Claude settings should be preserved")
    expect(try String(contentsOf: storedCommand, encoding: .utf8), originalCommand, "existing ccline command should be preserved exactly")
    expect(FileManager.default.isExecutableFile(atPath: installedProxy.path), "installed statusline proxy should be executable")
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
    defer {
        try? FileManager.default.removeItem(at: root)
    }
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
    defer {
        try? FileManager.default.removeItem(at: root)
    }
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
    defer {
        try? FileManager.default.removeItem(at: root)
    }
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

func testRateLimitReaderCombinesSplitQuotaAndContextSnapshots() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agent-halo-split-rate-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let sessions = root.appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    let file = sessions.appendingPathComponent("split.jsonl")
    let quota = #"{"type":"event_msg","payload":{"info":{"rate_limits":{"primary":{"used_percent":25,"resets_at":1781765880},"secondary":{"used_percent":40,"resets_at":1781938560}}}}}"#
    let context = #"{"type":"event_msg","payload":{"info":{"last_token_usage":{"input_tokens":50},"model_context_window":100}}}"#
    try Data("\(quota)\n\(context)\n".utf8).write(to: file)

    let snapshot = RateLimitReader(roots: [sessions]).read()
    expect(snapshot?.primaryUsedPercent, 25, "split snapshot primary quota")
    expect(snapshot?.secondaryUsedPercent, 40, "split snapshot secondary quota")
    expect(snapshot?.contextUsedPercent, 50, "split snapshot context usage")
}

func testClaudeStatusLineUsageParserReadsAuthoritativeContextPercent() {
    let now = ISO8601DateFormatter().date(from: "2026-06-21T08:00:00Z")!
    let data = Data(#"{"session_id":"cc-session","model":{"id":"claude-sonnet-4","display_name":"Sonnet 4"},"context_window":{"used_percentage":52.75,"remaining_percentage":47.25,"context_window_size":200000,"total_input_tokens":38000,"total_output_tokens":1200}}"#.utf8)

    let snapshot = ClaudeStatusLineUsageParser.parse(data: data, updatedAt: now)

    expect(snapshot?.sessionId, "cc-session", "Claude context session id")
    expect(snapshot?.usedPercent, 52.75, "Claude authoritative context percent")
    expect(snapshot?.contextWindowSize, 200_000, "Claude context window size")
    expect(snapshot?.modelName, "claude-sonnet-4", "Claude detail model")
    expect(snapshot?.inputTokens, 38_000, "Claude detail input tokens")
    expect(snapshot?.outputTokens, 1_200, "Claude detail output tokens")
    expect(snapshot?.updatedAt, now, "Claude context capture time")
}

func testClaudeContextUsageReaderKeepsLastKnownUsageForMatchingSession() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agent-halo-claude-context-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: root)
    }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let snapshotURL = root.appendingPathComponent("claude-code-context.json")
    let now = ISO8601DateFormatter().date(from: "2026-06-21T08:00:00Z")!
    let reader = ClaudeContextUsageReader(snapshotURL: snapshotURL)

    let fresh = ClaudeContextUsageSnapshot(
        sessionId: "cc-session",
        usedPercent: 52.75,
        contextWindowSize: 200_000,
        updatedAt: now.addingTimeInterval(-30)
    )
    try JSONEncoder().encode(fresh).write(to: snapshotURL)

    expect(reader.read(sessionIds: ["cc-session"], now: now)?.usedPercent, 52.75, "matching fresh Claude context")
    expect(reader.read(sessionIds: ["other-session"], now: now) == nil, "mismatched Claude session should be rejected")
    expect(reader.read(sessionIds: [], now: now)?.usedPercent, 52.75, "fresh Claude context should survive hook snapshot pruning")
    expect(
        reader.read(sessionIds: ["cc-session"], now: now.addingTimeInterval(301))?.usedPercent,
        52.75,
        "matching Claude context should remain visible after five minutes"
    )
}

func testClaudeContextUsageReaderDoesNotShareSnapshotsAcrossFiles() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agent-halo-claude-context-cache-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: root)
    }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let firstURL = root.appendingPathComponent("first.json")
    let secondURL = root.appendingPathComponent("second.json")
    let now = ISO8601DateFormatter().date(from: "2026-06-21T08:00:00Z")!
    let first = ClaudeContextUsageSnapshot(sessionId: "shared-session", usedPercent: 10, updatedAt: now)
    let second = ClaudeContextUsageSnapshot(sessionId: "shared-session", usedPercent: 90, updatedAt: now)

    try JSONEncoder().encode(first).write(to: firstURL)
    try JSONEncoder().encode(second).write(to: secondURL)
    let sharedModificationDate = ISO8601DateFormatter().date(from: "2026-06-21T07:59:00Z")!
    try FileManager.default.setAttributes([.modificationDate: sharedModificationDate], ofItemAtPath: firstURL.path)
    try FileManager.default.setAttributes([.modificationDate: sharedModificationDate], ofItemAtPath: secondURL.path)

    let firstRead = ClaudeContextUsageReader(snapshotURL: firstURL).read(sessionIds: ["shared-session"], now: now)
    let secondRead = ClaudeContextUsageReader(snapshotURL: secondURL).read(sessionIds: ["shared-session"], now: now)

    expect(firstRead?.usedPercent, 10, "first Claude context reader should read its own snapshot")
    expect(secondRead?.usedPercent, 90, "second Claude context reader should not reuse another file's snapshot")
}

func testClaudeStatusLineProxyRuntimeCapturesUsageAndForwardsInput() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agent-halo-statusline-runtime-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: root)
    }
    let snapshotURL = root.appendingPathComponent("claude-code-context.json")
    let now = ISO8601DateFormatter().date(from: "2026-06-21T08:00:00Z")!
    let input = Data(#"{"session_id":"cc-session","context_window":{"used_percentage":61.5,"context_window_size":200000}}"#.utf8)

    let captured = try ClaudeStatusLineProxyRuntime.capture(
        input: input,
        snapshotURL: snapshotURL,
        updatedAt: now
    )
    let forwarded = try ClaudeStatusLineProxyRuntime.runOriginalCommand(command: "cat", input: input)

    expect(captured?.usedPercent, 61.5, "statusline proxy should capture Claude context")
    expect(forwarded.standardOutput, input, "statusline proxy should forward input unchanged")
    expect(forwarded.terminationStatus, 0, "statusline proxy should preserve successful command status")
    let stored = try JSONDecoder().decode(ClaudeContextUsageSnapshot.self, from: Data(contentsOf: snapshotURL))
    expect(stored, captured, "statusline proxy should persist the captured context atomically")
}

func testCodexRealtimeActivityReaderDetectsAnswerStreaming() {
    let reader = CodexRealtimeActivityReader()
    let delta = #"SSE event: {"type":"response.output_text.delta","delta":"hello"}"#
    let activity = reader.findActive(in: [delta])

    expect(activity?.state, .working, "answer text delta state")
    expect(activity?.action, "Writing answer", "answer text delta action")
    expect(activity?.answerStreaming, true, "answer text delta should mark streaming")
}

func testCodexRealtimeActivityReaderDetectsRequestUserInput() {
    let reader = CodexRealtimeActivityReader()
    let request = #"SSE event: {"type":"response.output_item.added","item":{"id":"approval-1","type":"custom_tool_call","name":"request_user_input"}}"#
    let activity = reader.findActive(in: [request])

    expect(activity?.state, .attention, "request_user_input state")
    expect(activity?.action, "Needs you", "request_user_input action")
    expect(activity?.answerStreaming, false, "request_user_input should not mark answer streaming")
}

func testCodexRealtimeActivityReaderClearsAnswerStreamingWhenDone() {
    let reader = CodexRealtimeActivityReader()
    let delta = #"SSE event: {"type":"response.output_text.delta","delta":"hello"}"#
    let textDone = #"SSE event: {"type":"response.output_text.done"}"#
    let completed = #"SSE event: {"type":"response.completed","response":{"id":"resp-test"}}"#

    expect(reader.findActive(in: [textDone, delta]) == nil, "text done should clear answer streaming")
    expect(reader.findActive(in: [completed, delta]) == nil, "response completed should clear answer streaming")
}

func testSessionReducerMapsCustomToolRequestUserInputToAttention() {
    var reducer = SessionReducer(filePath: "/tmp/custom-tool-request-user-input.jsonl")

    reducer.consume(jsonLine: #"{"timestamp":"2026-06-19T01:00:00Z","type":"event_msg","payload":{"type":"task_started"}}"#)
    reducer.consume(jsonLine: #"{"timestamp":"2026-06-19T01:00:01Z","type":"response_item","payload":{"type":"custom_tool_call","name":"request_user_input"}}"#)

    expect(reducer.snapshot.state, .attention, "custom_tool_call request_user_input state")
    expect(reducer.snapshot.action, "Needs you", "custom_tool_call request_user_input action")
    expect(reducer.snapshot.active, "custom_tool_call request_user_input should keep session active")
}

func testSessionReducerMapsEscalatedExecCommandToAttention() {
    var reducer = SessionReducer(filePath: "/tmp/escalated-exec-command.jsonl")
    let arguments = #"{"cmd":"swift build","sandbox_permissions":"require_escalated","justification":"Allow build?"}"#

    reducer.consume(jsonLine: #"{"timestamp":"2026-06-19T01:00:00Z","type":"event_msg","payload":{"type":"task_started"}}"#)
    reducer.consume(jsonLine: #"{"timestamp":"2026-06-19T01:00:01Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"\#(arguments.replacingOccurrences(of: "\"", with: "\\\""))"}}"#)

    expect(reducer.snapshot.state, .attention, "escalated exec_command state")
    expect(reducer.snapshot.action, "Needs you", "escalated exec_command action")
    expect(reducer.snapshot.active, "escalated exec_command should keep session active")
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

func testClaudeHookReducerPreservesThinkingBeforeQuickToolAndUsesShortResultHold() {
    let now = ISO8601DateFormatter().date(from: "2026-06-16T04:00:00Z")!
    var reducer = ClaudeHookStatusReducer(threadId: "quick-tool", now: now)

    reducer.consume(jsonLine: #"{"timestamp":"2026-06-16T04:00:00Z","event":"UserPromptSubmit","sessionId":"quick-tool","cwd":"/tmp","source":"claude-hook"}"#, now: now)
    reducer.consume(jsonLine: #"{"timestamp":"2026-06-16T04:00:00.120Z","event":"PreToolUse","sessionId":"quick-tool","cwd":"/tmp","toolName":"Bash","source":"claude-hook"}"#, now: now.addingTimeInterval(0.12))

    expect(reducer.snapshot.state, .thinking, "quick PreToolUse should preserve the initial thinking beat")
    reducer.applyWorkingVisibility(now: now.addingTimeInterval(0.5))
    expect(reducer.snapshot.state, .thinking, "thinking beat should remain visible for 0.7 seconds")
    reducer.applyWorkingVisibility(now: now.addingTimeInterval(0.8))
    expect(reducer.snapshot.state, .working, "pending tool action should appear after the thinking beat")
    expect(reducer.snapshot.action, "Running command", "pending tool action should preserve the friendly tool name")

    reducer.consume(jsonLine: #"{"timestamp":"2026-06-16T04:00:01Z","event":"PostToolUse","sessionId":"quick-tool","cwd":"/tmp","toolName":"Bash","source":"claude-hook"}"#, now: now.addingTimeInterval(1))
    reducer.applyWorkingVisibility(now: now.addingTimeInterval(1.5))
    expect(reducer.snapshot.state, .working, "PostToolUse should remain blue inside the short hold")
    reducer.applyWorkingVisibility(now: now.addingTimeInterval(1.8))
    expect(reducer.snapshot.state, .thinking, "PostToolUse should fade after the 0.65 second hold")
}

func testClaudeHookReducerMapsBatchAndDirectPermissionEvents() {
    let now = ISO8601DateFormatter().date(from: "2026-06-16T04:00:00Z")!
    var reducer = ClaudeHookStatusReducer(threadId: "new-hook-events", now: now)

    reducer.consume(jsonLine: #"{"timestamp":"2026-06-16T04:00:00Z","event":"UserPromptSubmit","sessionId":"new-hook-events","cwd":"/tmp","source":"claude-hook"}"#, now: now)
    reducer.consume(jsonLine: #"{"timestamp":"2026-06-16T04:00:01Z","event":"PostToolBatch","sessionId":"new-hook-events","cwd":"/tmp","source":"claude-hook"}"#, now: now.addingTimeInterval(1))
    expect(reducer.snapshot.state, .working, "PostToolBatch should use the post-tool working state")
    expect(reducer.snapshot.action, "Reviewing result", "PostToolBatch action")

    reducer.consume(jsonLine: #"{"timestamp":"2026-06-16T04:00:02Z","event":"PermissionRequest","sessionId":"new-hook-events","cwd":"/tmp","source":"claude-hook"}"#, now: now.addingTimeInterval(2))
    expect(reducer.snapshot.state, .attention, "PermissionRequest should request attention")
    expect(reducer.snapshot.action, "Awaiting permission", "PermissionRequest action")

    reducer.consume(jsonLine: #"{"timestamp":"2026-06-16T04:00:03Z","event":"PermissionDenied","sessionId":"new-hook-events","cwd":"/tmp","source":"claude-hook"}"#, now: now.addingTimeInterval(3))
    expect(reducer.snapshot.state, .attention, "PermissionDenied should remain attention")
    expect(reducer.snapshot.action, "Permission denied", "PermissionDenied action")
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

    expect(reducer.snapshot.state, .attention, "permission_prompt should show attention")
    expect(reducer.snapshot.action, "Awaiting permission", "permission_prompt action")
    expect(reducer.snapshot.active, true, "permission_prompt keeps the turn active")

    // No fade-out: even minutes later, the state must still reflect the pending prompt
    // until a real PreToolUse / Stop arrives.
    reducer.applyWorkingVisibility(now: now.addingTimeInterval(120))
    expect(reducer.snapshot.state, .attention, "permission_prompt should not fade automatically")
    expect(reducer.snapshot.action, "Awaiting permission", "permission_prompt action persists")
}

func testClaudeHookReducerIdlePromptReturnsToReady() {
    let now = ISO8601DateFormatter().date(from: "2026-06-16T04:00:00Z")!
    var reducer = ClaudeHookStatusReducer(threadId: "idle", now: now)

    reducer.consume(jsonLine: #"{"timestamp":"2026-06-16T04:00:00Z","event":"UserPromptSubmit","sessionId":"idle","cwd":"/tmp","source":"claude-hook"}"#, now: now)
    reducer.consume(jsonLine: #"{"timestamp":"2026-06-16T04:00:01Z","event":"Notification","sessionId":"idle","cwd":"/tmp","notificationType":"idle_prompt","source":"claude-hook"}"#, now: now.addingTimeInterval(1))

    expect(reducer.snapshot.state, .idle, "idle_prompt should return to idle")
    expect(reducer.snapshot.action, "Ready", "idle_prompt action")
    expect(reducer.snapshot.active, false, "idle_prompt should not keep the turn active")
}

func testClaudeHookIdlePromptDoesNotDriveThinkingAggregate() {
    let now = ISO8601DateFormatter().date(from: "2026-06-18T08:24:00Z")!
    var reducer = ClaudeHookStatusReducer(threadId: "idle-aggregate", now: now)
    let settings = HaloSettings(
        paused: false,
        focusedAgent: .claudeCode,
        installedAt: now.addingTimeInterval(-60)
    )

    reducer.consume(jsonLine: #"{"timestamp":"2026-06-18T08:24:00Z","event":"SessionStart","sessionId":"idle-aggregate","cwd":"/Users/wjs/work/pyproj/AgentHalo","source":"claude-hook"}"#, now: now)
    reducer.consume(jsonLine: #"{"timestamp":"2026-06-18T08:24:05Z","event":"PostCompact","sessionId":"idle-aggregate","cwd":"/Users/wjs/work/pyproj/AgentHalo","source":"claude-hook"}"#, now: now.addingTimeInterval(5))
    reducer.consume(jsonLine: #"{"timestamp":"2026-06-18T08:25:05Z","event":"Notification","sessionId":"idle-aggregate","cwd":"/Users/wjs/work/pyproj/AgentHalo","notificationType":"idle_prompt","source":"claude-hook"}"#, now: now.addingTimeInterval(65))

    let aggregate = SessionAggregator.aggregate(
        snapshots: [reducer.snapshot],
        settings: settings,
        focusedAgent: .claudeCode,
        now: now.addingTimeInterval(66)
    )
    expect(aggregate.state, .idle, "idle_prompt should not surface as Thinking")
    expect(aggregate.label, "READY", "idle_prompt aggregate label")
    expect(aggregate.detail, "Claude Code is standing by", "idle_prompt aggregate detail")
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

func testClaudeHookReducerStuckPreToolUseRecoversAfterSafetyTimeout() {
    let now = ISO8601DateFormatter().date(from: "2026-06-16T04:00:00Z")!
    var reducer = ClaudeHookStatusReducer(threadId: "stuck-pretool", now: now)

    // Simulate a PreToolUse event that is never followed by PostToolUse
    // (e.g. crash, test noise, hook misconfiguration).
    reducer.consume(jsonLine: #"{"timestamp":"2026-06-16T04:00:00Z","event":"UserPromptSubmit","sessionId":"stuck-pretool","cwd":"/tmp","source":"claude-hook"}"#, now: now)
    reducer.consume(jsonLine: #"{"timestamp":"2026-06-16T04:00:01Z","event":"PreToolUse","sessionId":"stuck-pretool","cwd":"/tmp","toolName":"Bash","source":"claude-hook"}"#, now: now.addingTimeInterval(1))

    expect(reducer.snapshot.state, .working, "PreToolUse should enter working")

    // After 60 seconds, still working — tool may legitimately be running.
    reducer.applyWorkingVisibility(now: now.addingTimeInterval(61))
    expect(reducer.snapshot.state, .working, "60 s after PreToolUse should keep working (tool may run long)")

    // After 181 seconds with no follow-up event, safety net forces fade to thinking.
    reducer.applyWorkingVisibility(now: now.addingTimeInterval(182))
    expect(reducer.snapshot.state, .thinking, ">180 s after PreToolUse with no PostToolUse should force-fade to thinking")
    expect(reducer.snapshot.action, "Thinking", "safety-net fade action")
}

func testClaudeHookReducerManualCompactShowsDoneThenReady() {
    let now = ISO8601DateFormatter().date(from: "2026-06-17T04:00:00Z")!
    var reducer = ClaudeHookStatusReducer(threadId: "manual-compact", now: now)
    let settings = HaloSettings(
        paused: false,
        focusedAgent: .claudeCode,
        installedAt: now.addingTimeInterval(-60)
    )

    reducer.consume(jsonLine: #"{"timestamp":"2026-06-17T04:00:00Z","event":"SessionStart","sessionId":"manual-compact","cwd":"/tmp","source":"claude-hook"}"#, now: now)
    reducer.consume(jsonLine: #"{"timestamp":"2026-06-17T04:00:01Z","event":"PreCompact","sessionId":"manual-compact","cwd":"/tmp","source":"claude-hook"}"#, now: now.addingTimeInterval(1))
    expect(reducer.snapshot.state, .working, "manual PreCompact should show Executing")
    expect(reducer.snapshot.action, "Compressing context", "manual PreCompact action")

    // Claude Code emits another SessionStart while rebuilding the compacted session.
    // It must not erase the fact that compaction began while the prompt was idle.
    reducer.consume(jsonLine: #"{"timestamp":"2026-06-17T04:00:02Z","event":"SessionStart","sessionId":"manual-compact","cwd":"/tmp","source":"claude-hook"}"#, now: now.addingTimeInterval(2))
    expect(reducer.snapshot.state, .working, "SessionStart during compaction should keep Executing")
    expect(reducer.snapshot.action, "Compressing context", "SessionStart should preserve compaction action")

    reducer.consume(jsonLine: #"{"timestamp":"2026-06-17T04:00:03Z","event":"PostCompact","sessionId":"manual-compact","cwd":"/tmp","source":"claude-hook"}"#, now: now.addingTimeInterval(3))
    expect(reducer.snapshot.state, .done, "manual PostCompact should show completion")
    expect(reducer.snapshot.action, "Context compacted", "manual PostCompact action")
    expect(reducer.snapshot.active, false, "manual PostCompact should deactivate")
    expect(reducer.snapshot.completedAt, now.addingTimeInterval(3), "manual PostCompact completion time")

    let fresh = SessionAggregator.aggregate(
        snapshots: [reducer.snapshot],
        settings: settings,
        focusedAgent: .claudeCode,
        now: now.addingTimeInterval(4)
    )
    expect(fresh.state, .done, "manual compact should briefly show green Done")

    let settled = SessionAggregator.aggregate(
        snapshots: [reducer.snapshot],
        settings: settings,
        focusedAgent: .claudeCode,
        now: now.addingTimeInterval(12)
    )
    expect(settled.state, .idle, "manual compact should settle to gray Ready")
    expect(settled.label, "READY", "manual compact settled label")
}

func testClaudeHookReducerActiveCompactRestoresThinking() {
    let now = ISO8601DateFormatter().date(from: "2026-06-17T04:00:00Z")!
    var reducer = ClaudeHookStatusReducer(threadId: "compact", now: now)

    // Start a normal turn.
    reducer.consume(jsonLine: #"{"timestamp":"2026-06-17T04:00:00Z","event":"UserPromptSubmit","sessionId":"compact","cwd":"/tmp","source":"claude-hook"}"#, now: now)
    expect(reducer.snapshot.state, .thinking, "start in thinking")

    // PreCompact should switch to working with "Compressing context".
    reducer.consume(jsonLine: #"{"timestamp":"2026-06-17T04:00:01Z","event":"PreCompact","sessionId":"compact","cwd":"/tmp","source":"claude-hook"}"#, now: now.addingTimeInterval(1))
    expect(reducer.snapshot.state, .working, "PreCompact should show Executing")
    expect(reducer.snapshot.action, "Compressing context", "PreCompact action")
    expect(reducer.snapshot.active, true, "PreCompact keeps the turn active")

    // A compaction-time SessionStart must preserve the active resume state.
    reducer.consume(jsonLine: #"{"timestamp":"2026-06-17T04:00:02Z","event":"SessionStart","sessionId":"compact","cwd":"/tmp","source":"claude-hook"}"#, now: now.addingTimeInterval(2))
    expect(reducer.snapshot.state, .working, "SessionStart during active compaction should keep Executing")

    // PostCompact should restore to thinking for an active turn.
    reducer.consume(jsonLine: #"{"timestamp":"2026-06-17T04:00:03Z","event":"PostCompact","sessionId":"compact","cwd":"/tmp","source":"claude-hook"}"#, now: now.addingTimeInterval(3))
    expect(reducer.snapshot.state, .thinking, "PostCompact should restore to thinking")
    expect(reducer.snapshot.action, "Thinking", "PostCompact action")
    expect(reducer.snapshot.active, true, "PostCompact keeps the turn active")

    // Safety net: PreCompact without PostCompact should force-fade like PreToolUse.
    var reducer2 = ClaudeHookStatusReducer(threadId: "compact-stuck", now: now)
    reducer2.consume(jsonLine: #"{"timestamp":"2026-06-17T04:00:00Z","event":"UserPromptSubmit","sessionId":"compact-stuck","cwd":"/tmp","source":"claude-hook"}"#, now: now)
    reducer2.consume(jsonLine: #"{"timestamp":"2026-06-17T04:00:01Z","event":"PreCompact","sessionId":"compact-stuck","cwd":"/tmp","source":"claude-hook"}"#, now: now.addingTimeInterval(1))
    expect(reducer2.snapshot.state, .working, "PreCompact shows working")

    // After >180 s with no PostCompact, safety net recovers.
    reducer2.applyWorkingVisibility(now: now.addingTimeInterval(182))
    expect(reducer2.snapshot.state, .thinking, "stuck PreCompact should force-fade to thinking after >180 s")
}

func testClaudeHookReducerIdleCompactTimeoutReturnsToReady() {
    let now = ISO8601DateFormatter().date(from: "2026-06-17T04:00:00Z")!
    var reducer = ClaudeHookStatusReducer(threadId: "idle-compact-timeout", now: now)

    reducer.consume(jsonLine: #"{"timestamp":"2026-06-17T04:00:00Z","event":"SessionStart","sessionId":"idle-compact-timeout","cwd":"/tmp","source":"claude-hook"}"#, now: now)
    reducer.consume(jsonLine: #"{"timestamp":"2026-06-17T04:00:01Z","event":"PreCompact","sessionId":"idle-compact-timeout","cwd":"/tmp","source":"claude-hook"}"#, now: now.addingTimeInterval(1))
    reducer.applyWorkingVisibility(now: now.addingTimeInterval(182))

    expect(reducer.snapshot.state, .idle, "stuck idle PreCompact should recover to Ready")
    expect(reducer.snapshot.action, "Ready", "stuck idle PreCompact recovery action")
    expect(reducer.snapshot.active, false, "stuck idle PreCompact should deactivate")
}

func testClaudeHookMonitorPrunesStaleReducers() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agent-halo-claude-hook-prune-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: root)
    }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let statusFile = root.appendingPathComponent("claude-code-status.jsonl")
    let now = ISO8601DateFormatter().date(from: "2026-06-16T04:00:00Z")!

    // Write two completions from different sessions, both long ago.
    let old = [
        #"{"timestamp":"2026-06-16T03:50:00Z","event":"UserPromptSubmit","sessionId":"old-session","cwd":"/tmp","source":"claude-hook"}"#,
        #"{"timestamp":"2026-06-16T03:50:01Z","event":"PreToolUse","sessionId":"old-session","cwd":"/tmp","toolName":"Bash","source":"claude-hook"}"#,
        #"{"timestamp":"2026-06-16T03:55:00Z","event":"UserPromptSubmit","sessionId":"newer-session","cwd":"/tmp","source":"claude-hook"}"#,
        #"{"timestamp":"2026-06-16T03:55:01Z","event":"Stop","sessionId":"newer-session","cwd":"/tmp","source":"claude-hook"}"#,
    ].joined(separator: "\n") + "\n"
    try Data(old.utf8).write(to: statusFile)

    let monitor = ClaudeHookStatusMonitor(statusURL: statusFile)
    _ = monitor.refresh(now: now.addingTimeInterval(-30))
    // Both sessions processed: old-session is active+working, newer-session is done.
    let before = monitor.snapshots()
    expect(before.count >= 1, true, "at least one snapshot before pruning")

    // Advance time so both reducers exceed their stale thresholds. Active uses
    // 600 s, inactive uses 300 s. The old session's last event is at 03:50:01
    // (~10 min before `now`); adding 700 s on top lifts elapsed time to ~17 min,
    // pruning both. The done session is well past its 300 s window.
    _ = monitor.refresh(now: now.addingTimeInterval(700))
    let after = monitor.snapshots()
    expect(after.isEmpty, true, "stale reducers pruned → empty hook snapshots")
}

func testClaudeMonitorHandlesDiscoveryPendingLinesAndTruncation() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agent-halo-claude-monitor-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: root)
    }
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
    defer {
        try? FileManager.default.removeItem(at: root)
    }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let statusFile = root.appendingPathComponent("claude-code-status.jsonl")
    let now = ISO8601DateFormatter().date(from: "2026-06-16T04:00:00Z")!

    try Data(#"{"timestamp":"2026-06-16T04:00:00Z","event":"UserPromptSubmit","sessionId":"hook-monitor","cwd":"/Users/wjs/work/pyproj/AgentHalo","source":"claude-hook"}"#.utf8).write(to: statusFile)

    let monitor = ClaudeHookStatusMonitor(statusURL: statusFile)
    _ = monitor.refresh(now: now)
    expect(monitor.snapshots().isEmpty, true, "partial hook line should not produce a snapshot")

    try FileHandle(forWritingTo: statusFile).withClose {
        try $0.seekToEnd()
        try $0.write(contentsOf: Data("\n".utf8))
    }
    _ = monitor.refresh(now: now.addingTimeInterval(1))
    expect(monitor.snapshots().first?.state == .thinking, "completed hook line should parse")
    expect(monitor.snapshots().first?.agent, .claudeCode, "hook monitor snapshots should carry Claude Code agent")

    try Data(#"{"timestamp":"2026-06-16T04:00:02Z","event":"Stop","sessionId":"hook-monitor","cwd":"/Users/wjs/work/pyproj/AgentHalo","source":"claude-hook"}"#.utf8).write(to: statusFile)
    _ = monitor.refresh(now: now.addingTimeInterval(2))
    expect(monitor.snapshots().isEmpty, true, "truncated partial hook line should not produce a snapshot")
}

func testClaudeMonitorIgnoresSubagentTranscripts() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agent-halo-claude-subagents-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: root)
    }
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

func testClaudeStatusMergerFallsBackToTranscriptWhenNoHookSnapshotExists() {
    let now = ISO8601DateFormatter().date(from: "2026-06-16T04:00:10Z")!
    let transcriptThinking = SessionSnapshot(
        threadId: "transcript-only",
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
        hookSnapshots: [],
        transcriptSnapshots: [transcriptThinking],
        now: now
    )

    expect(merged.map(\.threadId), ["transcript-only"], "transcript should drive Claude status only when hook data is unavailable")
}

func testClaudeTranscriptReducerHandlesMultipleItemsAttentionAndErrors() {
    let now = ISO8601DateFormatter().date(from: "2026-06-16T04:00:00Z")!
    var reducer = ClaudeSessionReducer(filePath: "/tmp/transcript-parity.jsonl", now: now)

    reducer.consume(jsonLine: #"{"type":"user","timestamp":"2026-06-16T04:00:00Z","sessionId":"transcript-parity","message":{"content":"work"}}"#, now: now)
    reducer.consume(jsonLine: #"{"type":"assistant","timestamp":"2026-06-16T04:00:01Z","sessionId":"transcript-parity","message":{"content":[{"type":"text","text":"checking"},{"type":"tool_use","name":"Bash"},{"type":"tool_use","name":"Read"}]}}"#, now: now.addingTimeInterval(1))
    expect(reducer.snapshot.state, .working, "tool_use should be found beyond the first transcript content item")
    expect(reducer.snapshot.action, "Running command", "first tool action should be localized through the shared spec")

    reducer.consume(jsonLine: #"{"type":"assistant","timestamp":"2026-06-16T04:00:02Z","sessionId":"transcript-parity","message":{"content":[{"type":"text","text":"analysis continues"}]}}"#, now: now.addingTimeInterval(2))
    expect(reducer.snapshot.state, .thinking, "assistant text should interrupt a stale working hold")

    reducer.consume(jsonLine: #"{"type":"assistant","timestamp":"2026-06-16T04:00:03Z","sessionId":"transcript-parity","message":{"content":[{"type":"tool_use","name":"AskUserQuestion"}]}}"#, now: now.addingTimeInterval(3))
    expect(reducer.snapshot.state, .attention, "AskUserQuestion should request attention")
    expect(reducer.snapshot.action, "Awaiting permission", "AskUserQuestion action")

    reducer.consume(jsonLine: #"{"type":"system","subtype":"api_error","timestamp":"2026-06-16T04:00:04Z","sessionId":"transcript-parity"}"#, now: now.addingTimeInterval(4))
    expect(reducer.snapshot.state, .error, "api_error should become an error state")
    expect(reducer.snapshot.action, "Service unavailable", "api_error action")
    expect(reducer.snapshot.active, false, "api_error should deactivate the session")
}

func testClaudeLiveSessionReaderRequiresLiveWaitingProcess() throws {
    let home = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agent-halo-live-session-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let sessions = home.appendingPathComponent(".claude/sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    let file = sessions.appendingPathComponent("live.json")

    try Data(#"{"status":"waiting","pid":99999999,"sessionId":"dead"}"#.utf8).write(to: file)
    expect(ClaudeLiveSessionReader.hasStandbySession(homeDirectory: home), false, "dead Claude session pid should not show standby")

    let live = #"{"status":"idle","pid":\#(ProcessInfo.processInfo.processIdentifier),"sessionId":"live"}"#
    try Data(live.utf8).write(to: file)
    expect(ClaudeLiveSessionReader.hasStandbySession(homeDirectory: home), true, "live idle Claude session should show standby")
}

func testClaudeStatusMergerKeepsHookWhenTranscriptCompletionIsNewer() {
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

    expect(merged.map(\.state), [.working], "hook state should remain authoritative over transcript completion")
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

func testClaudeHookStopShowsDoneThenReadyWhileWaitingForInput() {
    let start = ISO8601DateFormatter().date(from: "2026-06-16T04:00:00Z")!
    var reducer = ClaudeHookStatusReducer(threadId: "done-ready", now: start)
    let settings = HaloSettings(
        paused: false,
        focusedAgent: .claudeCode,
        installedAt: start.addingTimeInterval(-60)
    )

    reducer.consume(jsonLine: #"{"timestamp":"2026-06-16T04:00:00Z","event":"UserPromptSubmit","sessionId":"done-ready","cwd":"/Users/wjs/work/pyproj/AgentHalo","source":"claude-hook"}"#, now: start)
    reducer.consume(jsonLine: #"{"timestamp":"2026-06-16T04:00:02Z","event":"Stop","sessionId":"done-ready","cwd":"/Users/wjs/work/pyproj/AgentHalo","source":"claude-hook"}"#, now: start.addingTimeInterval(2))

    let fresh = SessionAggregator.aggregate(
        snapshots: [reducer.snapshot],
        settings: settings,
        focusedAgent: .claudeCode,
        now: start.addingTimeInterval(3)
    )
    expect(fresh.state, .done, "Claude Stop should show Done immediately")
    expect(fresh.label, "COMPLETE", "Claude Stop label")

    let settled = SessionAggregator.aggregate(
        snapshots: [reducer.snapshot],
        settings: settings,
        focusedAgent: .claudeCode,
        now: start.addingTimeInterval(11)
    )
    expect(settled.state, .idle, "Claude waiting for user input should settle to Ready")
    expect(settled.label, "READY", "Claude settled label")
    expect(settled.detail, "Claude Code is standing by", "Claude waiting-for-input detail")
}

func testStartupExecutablePathUsesAppBundleRoot() {
    let bundleURL = URL(fileURLWithPath: "/tmp/AgentHalo.app")
    let path = StartupLaunchAgent.executablePath(appBundleURL: bundleURL)
    expect(path, "/tmp/AgentHalo.app/Contents/MacOS/AgentHaloMac", "startup executable path")
}

// MARK: - Plan Mode 收尾保持等待用户确认

func testPlanModePlainFinalAnswerDoesNotHoldAttentionAtTaskComplete() {
    var reducer = SessionReducer(filePath: "/tmp/session-019c6e27-e55b-73d1-87d8-4e01f1f75044.jsonl")

    reducer.consume(jsonLine: #"{"timestamp":"2026-06-18T01:00:00Z","type":"event_msg","payload":{"type":"task_started","collaboration_mode_kind":"plan"}}"#)
    expect(reducer.snapshot.state, .thinking, "plan task_started state")

    reducer.consume(jsonLine: #"{"timestamp":"2026-06-18T01:00:01Z","type":"event_msg","payload":{"type":"agent_message","phase":"final_answer","content":[{"type":"output_text","text":"plain answer"}]}}"#)
    expect(reducer.snapshot.active, "plan agent_message keeps active")

    reducer.consume(jsonLine: #"{"timestamp":"2026-06-18T01:00:02Z","type":"event_msg","payload":{"type":"task_complete"}}"#)
    expect(reducer.snapshot.state, .done, "plain plan final_answer -> done")
    expect(reducer.snapshot.action, "Complete", "plain plan final_answer action")
    expect(!reducer.snapshot.active, "plain plan final_answer should deactivate")
}

func testPlanModeProposedPlanFromTaskStartedHoldsAttentionAtTaskComplete() {
    var reducer = SessionReducer(filePath: "/tmp/session-019c6e27-e55b-73d1-87d8-4e01f1f75045.jsonl")

    reducer.consume(jsonLine: #"{"timestamp":"2026-06-18T01:10:00Z","type":"event_msg","payload":{"type":"task_started","collaboration_mode_kind":"plan"}}"#)
    reducer.consume(jsonLine: #"{"timestamp":"2026-06-18T01:10:01Z","type":"event_msg","payload":{"type":"agent_message","phase":"final_answer","content":[{"type":"output_text","text":"<proposed_plan>"}]}}"#)
    reducer.consume(jsonLine: #"{"timestamp":"2026-06-18T01:10:02Z","type":"event_msg","payload":{"type":"task_complete"}}"#)
    expect(reducer.snapshot.state, .attention, "proposed plan task_complete -> attention")
    expect(reducer.snapshot.action, "Waiting for your choice", "proposed plan task_complete action")
    expect(reducer.snapshot.active, "proposed plan task_complete keeps active")
}

func testPlanModeFromTurnContextHoldsAttentionAtTaskComplete() {
    var reducer = SessionReducer(filePath: "/tmp/session-019c6e27-e55b-73d1-87d8-4e01f1f75045.jsonl")

    // turn_context 在 task_started 之前到达。
    reducer.consume(jsonLine: #"{"timestamp":"2026-06-18T02:00:00Z","type":"turn_context","payload":{"collaboration_mode":{"mode":"plan"}}}"#)
    reducer.consume(jsonLine: #"{"timestamp":"2026-06-18T02:00:01Z","type":"event_msg","payload":{"type":"task_started"}}"#)
    reducer.consume(jsonLine: #"{"timestamp":"2026-06-18T02:00:02Z","type":"response_item","payload":{"type":"message","phase":"final_answer","content":[{"type":"output_text","text":"<proposed_plan>"}]}}"#)
    reducer.consume(jsonLine: #"{"timestamp":"2026-06-18T02:00:03Z","type":"event_msg","payload":{"type":"task_complete"}}"#)
    expect(reducer.snapshot.state, .attention, "turn_context plan -> attention at task_complete")
    expect(reducer.snapshot.action, "Waiting for your choice", "turn_context plan action")
}

func testPlanModeCompletedPlanItemHoldsAttentionAtTaskComplete() {
    var reducer = SessionReducer(filePath: "/tmp/session-019c6e27-e55b-73d1-87d8-4e01f1f75046.jsonl")

    reducer.consume(jsonLine: #"{"timestamp":"2026-06-18T02:10:00Z","type":"event_msg","payload":{"type":"task_started","collaboration_mode_kind":"plan"}}"#)
    reducer.consume(jsonLine: #"{"timestamp":"2026-06-18T02:10:01Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"Plan","text":"Plan body"}}}"#)
    reducer.consume(jsonLine: #"{"timestamp":"2026-06-18T02:10:02Z","type":"event_msg","payload":{"type":"task_complete"}}"#)
    expect(reducer.snapshot.state, .attention, "completed plan item -> attention at task_complete")
    expect(reducer.snapshot.action, "Waiting for your choice", "completed plan item action")
}

func testNonPlanTaskCompleteStillTurnsGreen() {
    var reducer = SessionReducer(filePath: "/tmp/session-019c6e27-e55b-73d1-87d8-4e01f1f75046.jsonl")

    reducer.consume(jsonLine: #"{"timestamp":"2026-06-18T03:00:00Z","type":"event_msg","payload":{"type":"task_started"}}"#)
    reducer.consume(jsonLine: #"{"timestamp":"2026-06-18T03:00:01Z","type":"event_msg","payload":{"type":"agent_message","phase":"final_answer"}}"#)
    reducer.consume(jsonLine: #"{"timestamp":"2026-06-18T03:00:02Z","type":"event_msg","payload":{"type":"task_complete"}}"#)
    expect(reducer.snapshot.state, .done, "non-plan task_complete stays done")
    expect(reducer.snapshot.action, "Complete", "non-plan task_complete action")
    expect(!reducer.snapshot.active, "non-plan task_complete inactive")
}

func testPlanModeWithoutFinalAnswerStillTurnsGreen() {
    // Plan 模式但本轮没有产出 final_answer(被打断或仅做工具调用),
    // 视为普通完成,仍走 .done 绿色,避免假阳性等待。
    var reducer = SessionReducer(filePath: "/tmp/session-019c6e27-e55b-73d1-87d8-4e01f1f75047.jsonl")

    reducer.consume(jsonLine: #"{"timestamp":"2026-06-18T04:00:00Z","type":"event_msg","payload":{"type":"task_started","collaboration_mode_kind":"plan"}}"#)
    reducer.consume(jsonLine: #"{"timestamp":"2026-06-18T04:00:01Z","type":"event_msg","payload":{"type":"task_complete"}}"#)
    expect(reducer.snapshot.state, .done, "plan w/o final_answer -> done")
}

func testPlanModeFlagResetsAcrossTurns() {
    // 第 1 轮 plan + proposed plan -> attention;
    // 第 2 轮普通 task -> 必须回到 .done,不应残留 plan 标志。
    var reducer = SessionReducer(filePath: "/tmp/session-019c6e27-e55b-73d1-87d8-4e01f1f75048.jsonl")

    reducer.consume(jsonLine: #"{"timestamp":"2026-06-18T05:00:00Z","type":"event_msg","payload":{"type":"task_started","collaboration_mode_kind":"plan"}}"#)
    reducer.consume(jsonLine: #"{"timestamp":"2026-06-18T05:00:01Z","type":"event_msg","payload":{"type":"agent_message","phase":"final_answer","content":[{"type":"output_text","text":"<proposed_plan>"}]}}"#)
    reducer.consume(jsonLine: #"{"timestamp":"2026-06-18T05:00:02Z","type":"event_msg","payload":{"type":"task_complete"}}"#)
    expect(reducer.snapshot.state, .attention, "round 1 attention")

    reducer.consume(jsonLine: #"{"timestamp":"2026-06-18T05:00:10Z","type":"event_msg","payload":{"type":"task_started"}}"#)
    reducer.consume(jsonLine: #"{"timestamp":"2026-06-18T05:00:11Z","type":"event_msg","payload":{"type":"task_complete"}}"#)
    expect(reducer.snapshot.state, .done, "round 2 falls back to done")
}

func testPlanModeFlagResetsAfterFatalTurn() {
    var reducer = SessionReducer(filePath: "/tmp/session-019c6e27-e55b-73d1-87d8-4e01f1f75049.jsonl")

    reducer.consume(jsonLine: #"{"timestamp":"2026-06-18T06:00:00Z","type":"event_msg","payload":{"type":"task_started","collaboration_mode_kind":"plan"}}"#)
    reducer.consume(jsonLine: #"{"timestamp":"2026-06-18T06:00:01Z","type":"event_msg","payload":{"type":"turn_failed"}}"#)
    expect(reducer.snapshot.state, .error, "plan fatal turn becomes error")

    reducer.consume(jsonLine: #"{"timestamp":"2026-06-18T06:00:10Z","type":"event_msg","payload":{"type":"task_started"}}"#)
    reducer.consume(jsonLine: #"{"timestamp":"2026-06-18T06:00:11Z","type":"response_item","payload":{"type":"message","phase":"final_answer"}}"#)
    reducer.consume(jsonLine: #"{"timestamp":"2026-06-18T06:00:12Z","type":"event_msg","payload":{"type":"task_complete"}}"#)
    expect(reducer.snapshot.state, .done, "normal turn after plan fatal should not inherit plan mode")
    expect(!reducer.snapshot.active, "normal turn after plan fatal should deactivate")
}

func testDiagnosticsCreatesParentDirectoryForOutput() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agent-halo-diagnostics-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: root)
    }
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
testAggregateRemovesSupersededSessionErrors()
testAcknowledgingCompletedSessionsStoresLatestVisibleCompletionOnly()
testSettingsPersistFormalFieldsAndNormalizePaused()
do {
    try testSettingsDefaultsPreferredDisplayPlacementForLegacyFiles()
    try testSettingsPersistPreferredDisplayPlacement()
} catch {
    fatalError("preferred display placement settings checks failed: \(error)")
}
testSettingsUsesDefaultHaloSizeForLegacyFilesAndClampsInvalidSizes()
testSettingsMigratesLegacyAlwaysOnTopOffToDefaultOn()
testSettingsPreservesExplicitAlwaysOnTopOffAfterMigrationVersion()
do {
    try testSettingsDefaultsFocusedAgentToCodexWhenMissing()
} catch {
    fatalError("\(error)")
}
testSettingsPersistsFocusedAgent()
testAcknowledgedErrorVisibilityUsesLatestErrorTime()
testWorkingVisibilityLiveCallOutputAndInitialTail()
testSessionReducerCapturesCodexSessionDetailsAndRateLimitAvailability()
testToolFailedDoesNotBecomeFatalError()
do {
    try testClaudeHookConfiguratorWritesUserSettingsNotLegacyClaudeJson()
} catch {
    fatalError("\(error)")
}
do {
    try testClaudeStatusLineConfiguratorPreservesAndChainsExistingCommand()
} catch {
    fatalError("\(error)")
}
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
do {
    try testRateLimitReaderCombinesSplitQuotaAndContextSnapshots()
} catch {
    fatalError("\(error)")
}
testClaudeStatusLineUsageParserReadsAuthoritativeContextPercent()
do {
    try testClaudeContextUsageReaderKeepsLastKnownUsageForMatchingSession()
} catch {
    fatalError("\(error)")
}
do {
    try testClaudeContextUsageReaderDoesNotShareSnapshotsAcrossFiles()
} catch {
    fatalError("\(error)")
}
do {
    try testClaudeStatusLineProxyRuntimeCapturesUsageAndForwardsInput()
} catch {
    fatalError("\(error)")
}
testCodexRealtimeActivityReaderDetectsAnswerStreaming()
testCodexRealtimeActivityReaderClearsAnswerStreamingWhenDone()
testSessionReducerMapsCustomToolRequestUserInputToAttention()
testSessionReducerMapsEscalatedExecCommandToAttention()
testCodexRealtimeActivityReaderDetectsRequestUserInput()
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
testClaudeHookReducerPreservesThinkingBeforeQuickToolAndUsesShortResultHold()
testClaudeHookReducerMapsBatchAndDirectPermissionEvents()
testClaudeHookReducerPostToolUseFailureSurfacesThenSettles()
testClaudeHookReducerPermissionPromptHoldsUntilResolved()
testClaudeHookReducerIdlePromptReturnsToReady()
testClaudeHookIdlePromptDoesNotDriveThinkingAggregate()
testClaudeHookReducerStopFailureMapsToError()
testClaudeHookReducerStuckPreToolUseRecoversAfterSafetyTimeout()
testClaudeHookReducerManualCompactShowsDoneThenReady()
testClaudeHookReducerActiveCompactRestoresThinking()
testClaudeHookReducerIdleCompactTimeoutReturnsToReady()
do {
    try testClaudeHookMonitorPrunesStaleReducers()
} catch {
    fatalError("\(error)")
}
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
testClaudeStatusMergerFallsBackToTranscriptWhenNoHookSnapshotExists()
testClaudeStatusMergerKeepsHookWhenTranscriptCompletionIsNewer()
testClaudeStatusMergerSurvivesDuplicateThreadIds()
testClaudeTranscriptReducerHandlesMultipleItemsAttentionAndErrors()
do {
    try testClaudeLiveSessionReaderRequiresLiveWaitingProcess()
} catch {
    fatalError("\(error)")
}
testClaudeHookStopShowsDoneThenReadyWhileWaitingForInput()
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
testPlanModePlainFinalAnswerDoesNotHoldAttentionAtTaskComplete()
testPlanModeProposedPlanFromTaskStartedHoldsAttentionAtTaskComplete()
testPlanModeFromTurnContextHoldsAttentionAtTaskComplete()
testPlanModeCompletedPlanItemHoldsAttentionAtTaskComplete()
testNonPlanTaskCompleteStillTurnsGreen()
testPlanModeWithoutFinalAnswerStillTurnsGreen()
testPlanModeFlagResetsAfterFatalTurn()
testAggregateFiltersInactiveAndTimedOutSessions()
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

func testAggregateFiltersInactiveAndTimedOutSessions() {
    let now = Date()
    let activeSnap = SessionSnapshot(
        threadId: "active-codex",
        projectName: "CodexActive",
        workingDirectory: "",
        state: .thinking,
        action: "Thinking",
        lastEventAt: now,
        completedAt: nil,
        active: true,
        agent: .codex
    )
    
    // 1. 测试正常状态下 activeSnap 在 10 分钟内应判定为活跃
    let freshAgg = SessionAggregator.aggregate(
        snapshots: [activeSnap],
        settings: HaloSettings(paused: false),
        recentFailure: nil,
        codexRunning: true,
        focusedAgent: .codex,
        now: now
    )
    expect(freshAgg.state, .thinking, "fresh active session should show thinking")
    expect(freshAgg.sessions.count, 1, "should contain 1 session")

    // 2. 测试 10 分钟（600秒）超时过滤
    let timedOutSnap = SessionSnapshot(
        threadId: "timedout-codex",
        projectName: "CodexTimedOut",
        workingDirectory: "",
        state: .thinking,
        action: "Thinking",
        lastEventAt: now.addingTimeInterval(-601),
        completedAt: nil,
        active: true,
        agent: .codex
    )
    let timedOutAgg = SessionAggregator.aggregate(
        snapshots: [timedOutSnap],
        settings: HaloSettings(paused: false),
        recentFailure: nil,
        codexRunning: true,
        focusedAgent: .codex,
        now: now
    )
    expect(timedOutAgg.state, .idle, "timed out active session should filter out to idle")
    expect(timedOutAgg.sessions.count, 0, "should filter out timed out session")

    // 2b. 测试 attention 状态（等待授权等）即使超过 10 分钟也不应该被超时过滤
    let timedOutAttentionSnap = SessionSnapshot(
        threadId: "timedout-attention-codex",
        projectName: "CodexTimedOutAttention",
        workingDirectory: "",
        state: .attention,
        action: "Needs you",
        lastEventAt: now.addingTimeInterval(-601),
        completedAt: nil,
        active: true,
        agent: .codex
    )
    let timedOutAttentionAgg = SessionAggregator.aggregate(
        snapshots: [timedOutAttentionSnap],
        settings: HaloSettings(paused: false),
        recentFailure: nil,
        codexRunning: true,
        focusedAgent: .codex,
        now: now
    )
    expect(timedOutAttentionAgg.state, .attention, "timed out attention session should NOT filter out")
    expect(timedOutAttentionAgg.sessions.count, 1, "should preserve timed out attention session")

    // 3. 测试 codexRunning == false 时的过滤
    let notRunningAgg = SessionAggregator.aggregate(
        snapshots: [activeSnap],
        settings: HaloSettings(paused: false),
        recentFailure: nil,
        codexRunning: false,
        focusedAgent: .codex,
        now: now
    )
    expect(notRunningAgg.state, .idle, "not running codex should filter out active session to idle")
    expect(notRunningAgg.sessions.count, 0, "should filter out when codex is not running")

    // 4. 测试当活跃会话过滤掉时，能够正确触发 recentFailure
    let failure = CodexFailure(detail: "额度已用尽", eventAt: now.addingTimeInterval(-10))
    let failureAgg = SessionAggregator.aggregate(
        snapshots: [timedOutSnap],
        settings: HaloSettings(paused: false, installedAt: now.addingTimeInterval(-600)),
        recentFailure: failure,
        codexRunning: true,
        focusedAgent: .codex,
        now: now
    )
    expect(failureAgg.state, .error, "should surface synthetic error when active session is filtered out")
    expect(failureAgg.detail, "额度已用尽", "should show correct failure detail")
}
