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



func testAgentHaloLayoutMigratorMovesFlatLayoutToV2AndKeepsLegacyBinaries() throws {
    let fm = FileManager.default
    let home = fm.temporaryDirectory.appendingPathComponent("agent-halo-migrate-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: home) }
    let paths = AgentHaloPaths(homeDirectory: home)
    try fm.createDirectory(at: paths.root, withIntermediateDirectories: true)

    try "claude-old".write(to: paths.legacyClaudeStatusLog, atomically: true, encoding: .utf8)
    try "grok-old".write(to: paths.legacyGrokStatusLog, atomically: true, encoding: .utf8)
    try "usage-old".write(to: paths.legacyUsageSnapshots, atomically: true, encoding: .utf8)
    try "ccline".write(to: paths.legacyStatuslineOriginalCommand, atomically: true, encoding: .utf8)
    try #"{"legacy":true}"#.write(to: paths.legacyClaudeContextFile, atomically: true, encoding: .utf8)
    try fm.createDirectory(at: paths.legacyClaudeContextsDirectory, withIntermediateDirectories: true)
    try #"{"session":1}"#.write(
        to: paths.legacyClaudeContextsDirectory.appendingPathComponent("sess-a.json"),
        atomically: true,
        encoding: .utf8
    )
    try "#!/bin/sh".write(to: paths.legacyStatusHook, atomically: true, encoding: .utf8)
    try "#!/bin/sh".write(to: paths.legacyStatuslineProxy, atomically: true, encoding: .utf8)

    AgentHaloLayoutMigrator.migrateIfNeeded(paths: paths, fileManager: fm)

    expect(try String(contentsOf: paths.layoutVersionFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "2", "version")
    expect(try String(contentsOf: paths.claudeStatusLog, encoding: .utf8), "claude-old", "claude log moved")
    expect(try String(contentsOf: paths.grokStatusLog, encoding: .utf8), "grok-old", "grok log moved")
    expect(try String(contentsOf: paths.usageSnapshots, encoding: .utf8), "usage-old", "usage moved")
    expect(try String(contentsOf: paths.statuslineOriginalCommand, encoding: .utf8), "ccline", "original command moved")
    expect(
        try String(contentsOf: paths.claudeContextsDirectory.appendingPathComponent("sess-a.json"), encoding: .utf8),
        #"{"session":1}"#,
        "context snapshot moved"
    )

    expect(!fm.fileExists(atPath: paths.legacyClaudeStatusLog.path), "legacy claude log deleted")
    expect(!fm.fileExists(atPath: paths.legacyGrokStatusLog.path), "legacy grok log deleted")
    expect(!fm.fileExists(atPath: paths.legacyUsageSnapshots.path), "legacy usage deleted")
    expect(!fm.fileExists(atPath: paths.legacyStatuslineOriginalCommand.path), "legacy original deleted")
    expect(!fm.fileExists(atPath: paths.legacyClaudeContextFile.path), "legacy context file deleted")
    expect(!fm.fileExists(atPath: paths.legacyClaudeContextsDirectory.path), "legacy contexts dir deleted")
    expect(fm.fileExists(atPath: paths.legacyStatusHook.path), "legacy hook binary kept")
    expect(fm.fileExists(atPath: paths.legacyStatuslineProxy.path), "legacy proxy binary kept")
    expect(fm.fileExists(atPath: paths.binDirectory.path), "bin exists")
    expect(fm.fileExists(atPath: paths.stateDirectory.path), "state exists")
    expect(fm.fileExists(atPath: paths.logsDirectory.path), "logs exists")
    expect(fm.fileExists(atPath: paths.cacheDirectory.path), "cache exists")
}

func testAgentHaloLayoutMigratorPrefersExistingNewPathsAndDeletesOld() throws {
    let fm = FileManager.default
    let home = fm.temporaryDirectory.appendingPathComponent("agent-halo-migrate-new-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: home) }
    let paths = AgentHaloPaths(homeDirectory: home)
    try fm.createDirectory(at: paths.logsDirectory, withIntermediateDirectories: true)
    try "new-claude".write(to: paths.claudeStatusLog, atomically: true, encoding: .utf8)
    try "old-claude".write(to: paths.legacyClaudeStatusLog, atomically: true, encoding: .utf8)

    AgentHaloLayoutMigrator.migrateIfNeeded(paths: paths, fileManager: fm)

    expect(try String(contentsOf: paths.claudeStatusLog, encoding: .utf8), "new-claude", "keep new")
    expect(!fm.fileExists(atPath: paths.legacyClaudeStatusLog.path), "delete old when new exists")
    expect(try String(contentsOf: paths.layoutVersionFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "2", "version written")
}

func testAgentHaloLayoutMigratorScrubsResidueWhenAlreadyVersion2() throws {
    let fm = FileManager.default
    let home = fm.temporaryDirectory.appendingPathComponent("agent-halo-migrate-scrub-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: home) }
    let paths = AgentHaloPaths(homeDirectory: home)
    try fm.createDirectory(at: paths.logsDirectory, withIntermediateDirectories: true)
    try "2\n".write(to: paths.layoutVersionFile, atomically: true, encoding: .utf8)
    try "residue".write(to: paths.legacyClaudeStatusLog, atomically: true, encoding: .utf8)
    try "#!/bin/sh".write(to: paths.legacyStatusHook, atomically: true, encoding: .utf8)

    AgentHaloLayoutMigrator.migrateIfNeeded(paths: paths, fileManager: fm)

    expect(
        try String(contentsOf: paths.claudeStatusLog, encoding: .utf8),
        "residue",
        "version 2 residue should still be reconciled into the live path"
    )
    expect(!fm.fileExists(atPath: paths.legacyClaudeStatusLog.path), "move residual jsonl")
    expect(fm.fileExists(atPath: paths.legacyStatusHook.path), "scrub must not delete binary")
}

func testAgentHaloLayoutMigratorPreservesLegacyDataUntilDestinationIsUsable() throws {
    let fm = FileManager.default
    let home = fm.temporaryDirectory.appendingPathComponent(
        "agent-halo-migrate-failure-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? fm.removeItem(at: home) }
    let paths = AgentHaloPaths(homeDirectory: home)
    try fm.createDirectory(at: paths.logsDirectory, withIntermediateDirectories: true)
    try "legacy-claude".write(
        to: paths.legacyClaudeStatusLog,
        atomically: true,
        encoding: .utf8
    )
    try fm.createDirectory(at: paths.claudeStatusLog, withIntermediateDirectories: true)

    AgentHaloLayoutMigrator.migrateIfNeeded(paths: paths, fileManager: fm)

    expect(
        fm.fileExists(atPath: paths.legacyClaudeStatusLog.path),
        "failed migration must preserve the only legacy copy"
    )
    expect(
        !fm.fileExists(atPath: paths.layoutVersionFile.path),
        "failed migration must not commit layout version"
    )

    try fm.removeItem(at: paths.claudeStatusLog)
    AgentHaloLayoutMigrator.migrateIfNeeded(paths: paths, fileManager: fm)

    expect(
        try String(contentsOf: paths.claudeStatusLog, encoding: .utf8),
        "legacy-claude",
        "retry should migrate preserved legacy data"
    )
    expect(
        !fm.fileExists(atPath: paths.legacyClaudeStatusLog.path),
        "successful retry should remove the legacy copy"
    )
    expect(
        try String(contentsOf: paths.layoutVersionFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
        "2",
        "successful retry should commit layout version"
    )
}

func testAgentHaloPathsLayoutV2() {
    let home = URL(fileURLWithPath: "/tmp/agent-halo-paths-home", isDirectory: true)
    let paths = AgentHaloPaths(homeDirectory: home)
    let root = home.appendingPathComponent(".agent-halo", isDirectory: true)

    expect(AgentHaloPaths.layoutVersion, 2, "layout version")
    expect(paths.root, root, "root")
    expect(paths.binDirectory, root.appendingPathComponent("bin", isDirectory: true), "bin")
    expect(paths.stateDirectory, root.appendingPathComponent("state", isDirectory: true), "state")
    expect(paths.logsDirectory, root.appendingPathComponent("logs", isDirectory: true), "logs")
    expect(paths.cacheDirectory, root.appendingPathComponent("cache", isDirectory: true), "cache")
    expect(paths.layoutVersionFile, root.appendingPathComponent(".layout-version"), "layout version file")

    expect(paths.statusHook.path, root.appendingPathComponent("bin", isDirectory: true).appendingPathComponent("status-hook").path, "status hook")
    expect(paths.statuslineProxy.path, root.appendingPathComponent("bin", isDirectory: true).appendingPathComponent("statusline-proxy").path, "statusline proxy")
    expect(paths.statuslineOriginalCommand.path, root.appendingPathComponent("state", isDirectory: true).appendingPathComponent("statusline-original-command").path, "statusline original")
    expect(paths.claudeStatusLog.path, root.appendingPathComponent("logs", isDirectory: true).appendingPathComponent("claude-status.jsonl").path, "claude status log")
    expect(paths.grokStatusLog.path, root.appendingPathComponent("logs", isDirectory: true).appendingPathComponent("grok-status.jsonl").path, "grok status log")
    expect(paths.piStatusLog.path, root.appendingPathComponent("logs", isDirectory: true).appendingPathComponent("pi-status.jsonl").path, "pi status log")
    expect(paths.claudeContextsDirectory, root.appendingPathComponent("cache", isDirectory: true).appendingPathComponent("claude-contexts", isDirectory: true), "claude contexts")
    expect(paths.usageSnapshots.path, root.appendingPathComponent("cache", isDirectory: true).appendingPathComponent("usage-snapshots-v1.json").path, "usage snapshots")

    expect(paths.legacyStatusHook.lastPathComponent, "claude-code-status-hook", "legacy status hook name")
    expect(paths.legacyStatuslineProxy.lastPathComponent, "claude-code-statusline-proxy", "legacy proxy name")
    expect(paths.legacyStatuslineOriginalCommand.lastPathComponent, "claude-code-statusline-original-command", "legacy original command name")
    expect(paths.legacyClaudeStatusLog.lastPathComponent, "claude-code-status.jsonl", "legacy claude log name")
    expect(paths.legacyGrokStatusLog.lastPathComponent, "grok-build-status.jsonl", "legacy grok log name")
    expect(paths.legacyClaudeContextsDirectory.lastPathComponent, "claude-code-contexts", "legacy contexts dir name")
    expect(paths.legacyClaudeContextFile.lastPathComponent, "claude-code-context.json", "legacy context file name")
    expect(paths.legacyUsageSnapshots.lastPathComponent, "usage-snapshots-v1.json", "legacy usage name")
    expect(paths.legacyUsageSnapshots.deletingLastPathComponent(), root, "legacy usage under root")
    expect(paths.usageSnapshots.deletingLastPathComponent().lastPathComponent, "cache", "usage under cache")
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

func testGrokFocusedAgentPersistence() {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agent-halo-grok-settings-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: root)
    }
    let url = root.appendingPathComponent("settings.json")
    let store = SettingsStore(settingsURL: url)
    let settings = HaloSettings(focusedAgent: .grok)

    expect(settings.focusedAgent, .grok, "settings should accept grok focus")
    expect(AgentKind.grok.segmentedTitle, "Grok", "segmented label must be Grok")
    expect(AgentKind.grok.menuTitle, "Grok", "menu title must be Grok")

    store.save(settings)
    let loaded = store.load()

    expect(loaded.focusedAgent, .grok, "focused agent grok should persist")
}

func testPiFocusedAgentPersistence() {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agent-halo-pi-settings-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: root)
    }
    let url = root.appendingPathComponent("settings.json")
    let store = SettingsStore(settingsURL: url)
    let settings = HaloSettings(focusedAgent: .pi)

    expect(settings.focusedAgent, .pi, "settings should accept pi focus")
    expect(AgentKind.pi.segmentedTitle, "Pi", "segmented label must be Pi")
    expect(AgentKind.pi.menuTitle, "Pi", "menu title must be Pi")
    expect(AgentKind.pi.localizedStandbyDetail.isEmpty, false, "pi standby detail")
    expect(AgentKind.pi.localizedOfflineDetail.isEmpty, false, "pi offline detail")

    store.save(settings)
    let loaded = store.load()

    expect(loaded.focusedAgent, .pi, "focused agent pi should persist")
}

func testAntigravityKindIsOptInAndPersistsWhenEnabled() throws {
    expect(AgentKind.antigravity.menuTitle, "Antigravity", "menu title")
    expect(AgentKind.antigravity.segmentedTitle, "AG", "segmented title")
    expect(
        HaloSettings.defaultEnabledAgents.contains(.antigravity),
        false,
        "new AgentKind must stay opt-in"
    )
    expect(
        HaloSettings.defaultEnabledAgents,
        [.codex, .claudeCode, .grok, .pi],
        "frozen default-on set"
    )

    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("agent-halo-ag-settings-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("settings.json")

    var settings = HaloSettings(focusedAgent: .antigravity, enabledAgents: [.codex, .antigravity])
    expect(settings.enabledAgents.contains(.antigravity), true, "can enable antigravity")
    expect(settings.focusedAgent, .antigravity, "focus can be antigravity when enabled")
    SettingsStore(settingsURL: url).save(settings)
    let loaded = SettingsStore(settingsURL: url).load()
    expect(loaded.focusedAgent, .antigravity, "focused antigravity persists")
    expect(loaded.enabledAgents.contains(.antigravity), true, "enabled antigravity persists")

    settings.setAgent(.antigravity, enabled: false)
    expect(settings.enabledAgents.contains(.antigravity), false, "can disable antigravity")
    expect(settings.focusedAgent, .codex, "focus leaves antigravity when disabled")
}

func testSettingsDefaultsEnabledAgentsAndMenuBarIconWhenMissing() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agent-halo-enabled-legacy-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("settings.json")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try """
    {
      "acknowledged" : {},
      "alwaysOnTop" : true,
      "alwaysOnTopBehaviorVersion" : 1,
      "focusedAgent" : "claudeCode",
      "hasPosition" : false,
      "installedAt" : "2026-06-13T02:00:00Z",
      "left" : 0,
      "paused" : false,
      "top" : 0
    }
    """.data(using: .utf8)!.write(to: url)

    let loaded = SettingsStore(settingsURL: url).load()
    expect(loaded.enabledAgents, HaloSettings.defaultEnabledAgents, "legacy settings enable the frozen default set")
    expect(loaded.showMenuBarIcon, true, "legacy settings show the menu bar icon")
    expect(loaded.focusedAgent, .claudeCode, "legacy focused agent is preserved when still enabled")
}

func testSettingsDefaultEnabledAgentsIsFrozenAllowlist() throws {
    expect(
        HaloSettings.defaultEnabledAgents,
        [.codex, .claudeCode, .grok, .pi],
        "current four agents stay default-on"
    )
    expect(
        HaloSettings().enabledAgents,
        HaloSettings.defaultEnabledAgents,
        "new settings use the frozen default-on list"
    )
    expect(
        Set(HaloSettings.defaultEnabledAgents).isSubset(of: Set(AgentKind.allCases)),
        true,
        "default-on agents must be known AgentKinds"
    )

    let settingsURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("AgentHaloCore/HaloSettings.swift")
    let source = try String(contentsOf: settingsURL, encoding: .utf8)
    expect(
        source.contains("enabledAgents: [AgentKind] = AgentKind.allCases") == false,
        "init must not default enabledAgents to allCases (new kinds would auto-enable)"
    )
    expect(
        source.contains("?? AgentKind.allCases") == false,
        "decode must not fill missing enabledAgents from allCases"
    )
    expect(
        source.contains("ordered = AgentKind.allCases") == false,
        "empty enabledAgents must not fall back to allCases"
    )
}

func testSettingsNormalizesEmptyEnabledAgentsToDefaultEnabledAgents() {
    var settings = HaloSettings(focusedAgent: .codex, enabledAgents: [])
    settings = settings.normalized()
    expect(
        settings.enabledAgents,
        HaloSettings.defaultEnabledAgents,
        "empty enabledAgents falls back to the frozen default-on list"
    )
}

func testSettingsNormalizesDuplicateAndUnknownOrder() {
    let settings = HaloSettings(
        focusedAgent: .grok,
        enabledAgents: [.grok, .codex, .grok, .pi]
    ).normalized()
    expect(
        settings.enabledAgents,
        [.codex, .grok, .pi],
        "enabledAgents is unique and ordered by allCases"
    )
    expect(settings.focusedAgent, .grok, "focused grok stays when still enabled")
}

func testSettingsLoadFiltersUnknownEnabledAgentsWithoutResettingOtherFields() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agent-halo-enabled-unknown-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("settings.json")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try """
    {
      "enabledAgents" : ["futureAgent", "pi", "codex", "futureAgent"],
      "focusedAgent" : "pi",
      "haloSize" : 125,
      "language" : "en",
      "showMenuBarIcon" : false
    }
    """.data(using: .utf8)!.write(to: url)

    let loaded = SettingsStore(settingsURL: url).load()
    expect(loaded.enabledAgents, [.codex, .pi], "unknown agents are filtered while known agents are retained")
    expect(loaded.focusedAgent, .pi, "valid focus survives an unknown enabled agent")
    expect(loaded.haloSize, 125, "unknown enabled agent does not reset halo size")
    expect(loaded.language, "en", "unknown enabled agent does not reset language")
    expect(loaded.showMenuBarIcon, false, "unknown enabled agent does not reset menu bar preference")
}

func testSettingsMovesFocusWhenDisabled() {
    var settings = HaloSettings(
        focusedAgent: .claudeCode,
        enabledAgents: AgentKind.allCases
    )
    settings.setAgent(.claudeCode, enabled: false)
    expect(settings.isAgentEnabled(.claudeCode), false, "claude becomes disabled")
    expect(settings.focusedAgent, .codex, "focus moves to first remaining (codex)")
    expect(settings.enabledAgents.contains(.claudeCode), false, "claude removed from list")
}

func testSettingsCannotDisableTheLastAgent() {
    var settings = HaloSettings(focusedAgent: .pi, enabledAgents: [.pi])
    settings.setAgent(.pi, enabled: false)
    expect(settings.enabledAgents, [.pi], "last agent cannot be disabled")
    expect(settings.focusedAgent, .pi, "focus stays on the last agent")
}

func testSettingsPersistsEnabledAgentsAndMenuBarIcon() {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agent-halo-enabled-persist-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("settings.json")
    let store = SettingsStore(settingsURL: url)
    let settings = HaloSettings(focusedAgent: .codex, enabledAgents: [.codex, .pi], showMenuBarIcon: false)
    store.save(settings)
    let loaded = store.load()
    expect(loaded.enabledAgents, [.codex, .pi], "enabledAgents round-trips")
    expect(loaded.showMenuBarIcon, false, "showMenuBarIcon round-trips")
    expect(loaded.focusedAgent, .codex, "focused agent still round-trips")
}

func testSettingsLoadRepairsFocusOutsideEnabledAgents() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agent-halo-enabled-focus-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("settings.json")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try """
    {
      "enabledAgents" : ["pi"],
      "focusedAgent" : "grok",
      "hasPosition" : false,
      "installedAt" : "2026-06-13T02:00:00Z",
      "left" : 0,
      "top" : 0
    }
    """.data(using: .utf8)!.write(to: url)
    let loaded = SettingsStore(settingsURL: url).load()
    expect(loaded.enabledAgents, [.pi], "pi remains the only enabled agent")
    expect(loaded.focusedAgent, .pi, "load moves focus onto the enabled set")
}

func testPiStatusParseContextSentinelAndMapping() {
    let now = ISO8601DateFormatter().string(from: Date())
    let pid = Int(ProcessInfo.processInfo.processIdentifier)

    let nullContext = PiStatusMonitor.parse(
        #"{"version":1,"timestamp":"\#(now)","source":"pi-extension","event":"turn_start","state":"thinking","pid":\#(pid),"sessionId":"pi-null","cwd":"/tmp/demo","model":"m","contextTokens":null,"contextWindow":null}"#
    )
    expect(nullContext != nil, true, "null context parses")
    expect(nullContext?.contextTokens, Int64(-1), "null tokens -> -1")
    expect(nullContext?.contextWindowTokens, Int64(-1), "null window -> -1")
    let nullSnap = nullContext.flatMap { PiStatusMonitor.toSnapshot($0) }
    expect(nullSnap?.contextUsedPercent == nil, true, "unknown context hides pill")

    let windowOnly = PiStatusMonitor.parse(
        #"{"version":1,"timestamp":"\#(now)","source":"pi-extension","event":"turn_start","state":"thinking","pid":\#(pid),"sessionId":"pi-window","cwd":"/tmp/demo","model":"m","contextTokens":null,"contextWindow":200000}"#
    )
    expect(windowOnly?.contextTokens, Int64(-1), "window-only tokens unknown")
    expect(windowOnly?.contextWindowTokens, Int64(200000), "window-only keeps window")
    expect(windowOnly.flatMap { PiStatusMonitor.toSnapshot($0) }?.contextUsedPercent == nil, true,
           "window-only must not produce 0% pill")

    let zeroContext = PiStatusMonitor.parse(
        #"{"version":1,"timestamp":"\#(now)","source":"pi-extension","event":"agent_settled","state":"done","pid":\#(pid),"sessionId":"pi-zero","cwd":"/tmp/demo","model":"m","contextTokens":0,"contextWindow":200000,"inputTokens":10,"outputTokens":2}"#
    )
    let zeroSnap = zeroContext.flatMap { PiStatusMonitor.toSnapshot($0) }
    expect(zeroSnap?.state, HaloState.done, "done maps")
    expect(zeroSnap?.contextUsedPercent, 0.0, "real zero usage is 0%")
    expect(zeroSnap?.modelName, "m", "model preserved")
    expect(zeroSnap?.inputTokens, Int64(10), "input tokens")
    expect(zeroSnap?.outputTokens, Int64(2), "output tokens")

    let working = PiStatusMonitor.parse(
        #"{"version":1,"timestamp":"\#(now)","source":"pi-extension","event":"tool_execution_start","state":"working","pid":\#(pid),"sessionId":"pi-work","cwd":"/Users/me/AgentHalo","model":"m","toolName":"read","contextTokens":24000,"contextWindow":120000}"#
    )
    let workSnap = working.flatMap { PiStatusMonitor.toSnapshot($0) }
    expect(workSnap?.state, HaloState.working, "working maps")
    expect(workSnap?.active, true, "working is active")
    expect(workSnap?.projectName, "AgentHalo", "project leaf")
    expect(workSnap?.action.contains("read") == true, true, "tool name in action")
    expectAlmost(workSnap?.contextUsedPercent ?? -1, 20.0, tolerance: 0.01, "20% context")
}

func testPiStatusMonitorRefreshAndRotationRetention() throws {
    let home = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agent-halo-pi-status-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let paths = AgentHaloPaths(homeDirectory: home)
    try FileManager.default.createDirectory(at: paths.logsDirectory, withIntermediateDirectories: true)
    let log = paths.piStatusLog
    let now = ISO8601DateFormatter().string(from: Date())
    let pid = Int(ProcessInfo.processInfo.processIdentifier)

    let baseline = """
    {"version":1,"timestamp":"\(now)","source":"pi-extension","event":"thinking_start","state":"thinking","pid":\(pid),"sessionId":"pi-a","cwd":"/a","model":"m"}
    {"version":1,"timestamp":"\(now)","source":"pi-extension","event":"thinking_start","state":"thinking","pid":\(pid),"sessionId":"pi-b","cwd":"/b","model":"m"}
    """
    try baseline.write(to: log, atomically: true, encoding: .utf8)

    let monitor = PiStatusMonitor(statusURL: log)
    expect(monitor.refresh(), true, "baseline refresh")
    expect(monitor.snapshots().count, 2, "two sessions")
    expect(monitor.liveSessionIds().contains("pi-a"), true, "live a")
    expect(monitor.liveSessionIds().contains("pi-b"), true, "live b")

    // Simulate rotation: only session A writes the next event.
    let later = ISO8601DateFormatter().string(from: Date().addingTimeInterval(1))
    let rotated = """
    {"version":1,"timestamp":"\(later)","source":"pi-extension","event":"text_start","state":"working","pid":\(pid),"sessionId":"pi-a","cwd":"/a","model":"m"}
    """
    try rotated.write(to: log, atomically: true, encoding: .utf8)
    // Ensure mtime/size change is visible.
    Thread.sleep(forTimeInterval: 0.05)
    expect(monitor.refresh(), true, "post-rotation refresh")
    let snaps = monitor.snapshots()
    expect(snaps.count, 2, "retain live B across rotation")
    expect(snaps.contains { $0.threadId == "pi-a" && $0.state == .working }, true, "A updated")
    expect(snaps.contains { $0.threadId == "pi-b" && $0.state == .thinking }, true, "B retained")
}

func testPiRuntimeMonitorDetectsPreexistingSession() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agent-halo-pi-runtime-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let sessions = root
        .appendingPathComponent("sessions", isDirectory: true)
        .appendingPathComponent("project", isDirectory: true)
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    let file = sessions.appendingPathComponent("runtime-session.jsonl")
    let contents = """
    {"type":"session","id":"pi-existing","cwd":"/Users/me/AgentHalo"}
    {"type":"message","message":{"role":"assistant","provider":"openai","model":"pi-model","usage":{"input":20,"output":5,"cacheRead":3,"totalTokens":25}}}
    """
    try contents.write(to: file, atomically: true, encoding: .utf8)
    try #"{"providers":{"openai":{"models":[{"id":"pi-model","contextWindow":100}]}}}"#
        .write(to: root.appendingPathComponent("models.json"), atomically: true, encoding: .utf8)
    let now = Date()
    try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)

    let process = PiRuntimeProcess(
        processId: 12001,
        parentProcessId: 1,
        name: "pi",
        startedAt: now.addingTimeInterval(-60)
    )
    let monitor = PiRuntimeMonitor(agentRoot: root, processReader: { [process] })
    expect(monitor.refresh(now: now), true, "runtime monitor refreshes")
    expect(monitor.isRunning, true, "preexisting Pi process is detected")
    let snapshot = monitor.snapshot()
    expect(snapshot?.threadId, "pi-existing", "runtime session id")
    expect(snapshot?.projectName, "AgentHalo", "runtime project")
    expect(snapshot?.state, HaloState.idle, "runtime fallback stays idle")
    expect(snapshot?.modelName, "pi-model", "runtime model")
    expect(snapshot?.inputTokens, Int64(20), "runtime input tokens")
    expect(snapshot?.outputTokens, Int64(5), "runtime output tokens")
    expectAlmost(snapshot?.contextUsedPercent ?? -1, 25, tolerance: 0.01, "runtime context")

    let evidence = PiRuntimeMonitor.readLatestSession(agentRoot: root, now: now)
    let shell = PiRuntimeProcess(
        processId: 12002,
        parentProcessId: 1,
        name: "zsh",
        startedAt: now.addingTimeInterval(-120)
    )
    let node = PiRuntimeProcess(
        processId: 12003,
        parentProcessId: shell.processId,
        name: "node",
        startedAt: now.addingTimeInterval(-60)
    )
    expect(
        PiRuntimeMonitor.isRunning(session: evidence, now: now, processes: [shell, node]),
        true,
        "legacy node Pi with shell parent is detected"
    )
    expect(
        PiRuntimeMonitor.isRunning(session: evidence, now: now, processes: [node]),
        false,
        "unrelated parentless node is rejected"
    )
    let stale = evidence.map {
        PiRuntimeSessionEvidence(
            sessionId: $0.sessionId,
            workingDirectory: $0.workingDirectory,
            path: $0.path,
            lastModified: now.addingTimeInterval(-4 * 24 * 60 * 60),
            length: $0.length
        )
    }
    expect(
        PiRuntimeMonitor.isRunning(session: stale, now: now, processes: [process]),
        false,
        "stale session evidence is rejected"
    )
}

func testPiExtensionConfiguratorInstallsFromSource() throws {
    let home = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agent-halo-pi-ext-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: home) }
    setenv("PI_CODING_AGENT_DIR", home.appendingPathComponent("agent").path, 1)
    defer { unsetenv("PI_CODING_AGENT_DIR") }

    let installed = PiExtensionConfigurator.configure(homeDirectory: home)
    expect(installed != nil, true, "extension installed")
    let text = try String(contentsOf: installed!, encoding: .utf8)
    expect(text.contains("agent_settled"), true, "has agent_settled")
    expect(text.contains("hasContextUsage"), true, "pairs context fields")
    expect(text.contains(#"pi.on("input""#), false, "queued input cannot fake thinking")
    expect(text.contains(#"stopReason !== "aborted""#), true, "aborted is terminal failure")
    expect(text.contains("errorMessage: assistant?.errorMessage"), true, "failure detail is emitted")
    expect(
        text.contains("contextWindow: hasContextUsage ? context.contextWindow : null"),
        true,
        "context window only when usage is complete"
    )
    expect(
        text.contains("contextWindow: context?.contextWindow ?? model.contextWindow"),
        false,
        "no lone model window fallback assignment"
    )

    // Second configure is a no-op content match.
    let again = PiExtensionConfigurator.configure(homeDirectory: home)
    expect(again, installed, "idempotent install path")
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

func testSessionReducerCapturesCurrentCodexTurnDetailsAndRateLimitAvailability() {
    var reducer = SessionReducer(filePath: "/tmp/codex-session-details.jsonl")
    reducer.consume(jsonLine: #"{"type":"session_meta","payload":{"id":"codex-details","cwd":"/Users/wjs/work/pyproj/AgentHalo","title":"  Resolve Usage details  "}}"#)
    reducer.consume(jsonLine: #"{"type":"turn_context","payload":{"model":"gpt-5.5"}}"#)
    reducer.consume(jsonLine: #"{"type":"event_msg","payload":{"type":"task_started"}}"#)
    reducer.consume(jsonLine: #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":38000,"output_tokens":1200},"last_token_usage":{"input_tokens":2000,"output_tokens":200},"model_context_window":100000}}}"#)

    expect(reducer.snapshot.projectName, "AgentHalo", "Codex detail project")
    expect(reducer.snapshot.sessionTitle, "Resolve Usage details", "Codex detail session title")
    expect(reducer.snapshot.modelName, "gpt-5.5", "Codex detail model")
    expect(reducer.snapshot.inputTokens, 2_000, "first observed turn should use last input usage")
    expect(reducer.snapshot.outputTokens, 200, "first observed turn should use last output usage")
    expect(reducer.snapshot.hasRateLimits, false, "third-party Codex should have no rate limits")
    expect(reducer.snapshot.contextUsedPercent, 2, "Codex context should come from the current session")

    reducer.consume(jsonLine: #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":40000,"output_tokens":1500},"last_token_usage":{"input_tokens":4000,"output_tokens":500}},"rate_limits":{"primary":{},"secondary":{}}}}"#)
    expect(reducer.snapshot.inputTokens, 4_000, "current turn input should grow from its inferred baseline")
    expect(reducer.snapshot.outputTokens, 500, "current turn output should grow from its inferred baseline")
    expect(reducer.snapshot.hasRateLimits, true, "subscription Codex should report rate limits")

    reducer.consume(jsonLine: #"{"type":"event_msg","payload":{"type":"task_complete"}}"#)
    reducer.consume(jsonLine: #"{"type":"event_msg","payload":{"type":"task_started"}}"#)
    expect(reducer.snapshot.inputTokens == nil, "new turn should hide input tokens until usage arrives")
    expect(reducer.snapshot.outputTokens == nil, "new turn should hide output tokens until usage arrives")
    reducer.consume(jsonLine: #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":40500,"output_tokens":1580},"last_token_usage":{"input_tokens":500,"output_tokens":80}}}}"#)
    expect(reducer.snapshot.inputTokens, 500, "later turn input should subtract the known baseline")
    expect(reducer.snapshot.outputTokens, 80, "later turn output should subtract the known baseline")
}

func testSessionReducerFallsBackToLastTokenUsageWithoutTotals() {
    var reducer = SessionReducer(filePath: "/tmp/codex-last-token-details.jsonl")
    reducer.consume(jsonLine: #"{"type":"event_msg","payload":{"type":"task_started"}}"#)
    reducer.consume(jsonLine: #"{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":90,"output_tokens":12},"model_context_window":1000}}}"#)

    expect(reducer.snapshot.inputTokens, 90, "last input usage should work without cumulative totals")
    expect(reducer.snapshot.outputTokens, 12, "last output usage should work without cumulative totals")
    expect(reducer.snapshot.contextUsedPercent, 9, "last input usage should continue driving context")
}

func testSessionReducerCapturesOnlyExplicitCodexSessionTitles() {
    var legacyTitle = SessionReducer(filePath: "/tmp/codex-legacy-title.jsonl")
    legacyTitle.consume(
        jsonLine: #"{"type":"session_meta","payload":{"id":"legacy","cwd":"/tmp/Project","title":"  ","session_title":"  Legacy title  "}}"#
    )
    expect(legacyTitle.snapshot.sessionTitle, "Legacy title", "session_title should fill blank title")

    var preferredTitle = SessionReducer(filePath: "/tmp/codex-preferred-title.jsonl")
    preferredTitle.consume(
        jsonLine: #"{"type":"session_meta","payload":{"id":"preferred","cwd":"/tmp/Project","title":"Current title","session_title":"Legacy title"}}"#
    )
    expect(preferredTitle.snapshot.sessionTitle, "Current title", "title should precede session_title")

    var missingTitle = SessionReducer(filePath: "/tmp/codex-missing-title.jsonl")
    missingTitle.consume(
        jsonLine: #"{"type":"session_meta","payload":{"id":"thread-must-not-fallback","cwd":"/tmp/Project"}}"#
    )
    expect(missingTitle.snapshot.projectName, "Project", "missing title still preserves project")
    expect(missingTitle.snapshot.sessionTitle == nil, "missing title must not fall back to project or thread")
}

func testCodexSessionTitleReaderUsesLatestValidTitle() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agent-halo-title-index-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let indexURL = root.appendingPathComponent("session_index.jsonl")
    let records = """
    {"id":"thread-a","thread_name":"  First title  ","updated_at":"2026-07-21T01:00:00Z"}
    not-json
    {"id":"thread-empty","thread_name":"   ","updated_at":"2026-07-21T01:01:00Z"}
    {"id":"thread-a","thread_name":"Renamed title","updated_at":"2026-07-21T01:02:00Z"}

    """
    try Data(records.utf8).write(to: indexURL)

    var reader = CodexSessionTitleReader(indexURL: indexURL)
    let titles = reader.read()

    expect(titles["thread-a"], "Renamed title", "latest valid Codex title should win")
    expect(titles["thread-empty"] == nil, "blank Codex titles should be ignored")
    expect(titles.count, 1, "malformed title records should be ignored independently")
}

func testCodexSessionMonitorPrefersIndexTitleAndKeepsMetadataFallback() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agent-halo-title-monitor-\(UUID().uuidString)", isDirectory: true)
    let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let indexedID = "019f841a-336f-79e3-8f28-dab1e7c94958"
    let fallbackID = "019f841a-7d2d-7403-a6b9-24f13051c36e"
    let indexedSession = sessionsRoot.appendingPathComponent("rollout-\(indexedID).jsonl")
    let fallbackSession = sessionsRoot.appendingPathComponent("rollout-\(fallbackID).jsonl")
    try Data("{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(indexedID)\",\"title\":\"Old metadata title\"}}\n".utf8)
        .write(to: indexedSession)
    try Data("{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(fallbackID)\",\"title\":\"Metadata fallback\"}}\n".utf8)
        .write(to: fallbackSession)

    let indexURL = root.appendingPathComponent("session_index.jsonl")
    try Data("{\"id\":\"\(indexedID)\",\"thread_name\":\"Codex sidebar title\"}\n".utf8)
        .write(to: indexURL)
    let monitor = CodexSessionMonitor(
        sessionsRoot: sessionsRoot,
        sessionTitleReader: CodexSessionTitleReader(indexURL: indexURL)
    )

    _ = monitor.refresh()
    let sessions = Dictionary(uniqueKeysWithValues: monitor.snapshots().map { ($0.threadId, $0) })
    expect(sessions[indexedID]?.sessionTitle, "Codex sidebar title", "index title should be authoritative")
    expect(sessions[fallbackID]?.sessionTitle, "Metadata fallback", "metadata title should remain the fallback")
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
    expect(command, "\(home.path)/.agent-halo/bin/status-hook PreToolUse", "Agent Halo hook should be appended to ~/.claude/settings.json")
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

func testGrokHookConfiguratorWritesHooksJSON() throws {
    let home = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agent-halo-grok-hook-config-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: home)
    }
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let bundledHook = home.appendingPathComponent("bundle-hook")
    try Data("fake grok hook".utf8).write(to: bundledHook)

    GrokHookConfigurator.configure(homeDirectory: home, bundledHookBinary: bundledHook)

    let hooksURL = home.appendingPathComponent(".grok/hooks/agent-halo-status.json")
    expect(FileManager.default.fileExists(atPath: hooksURL.path), "hooks json exists")
    let text = try String(contentsOf: hooksURL, encoding: .utf8)
    expect(text.contains("PreToolUse"), "pre tool registered")
    expect(text.contains("SessionStart"), "SessionStart registered")
    expect(text.contains("SessionEnd"), "SessionEnd registered")
    expect(text.contains("PostCompact"), "PostCompact registered")

    let paths = AgentHaloPaths(homeDirectory: home)
    expect(FileManager.default.fileExists(atPath: paths.statusHook.path), "hook binary staged under .agent-halo/bin")

    // Parse JSON so escaped slashes (\/) do not break substring checks.
    let hooksJSON = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
    let hooksMap = hooksJSON["hooks"] as! [String: Any]
    let pre = hooksMap["PreToolUse"] as! [[String: Any]]
    let preHooks = pre[0]["hooks"] as! [[String: Any]]
    let command = preHooks[0]["command"] as! String
    expect(command, paths.statusHook.path, "hooks command is .agent-halo/bin/status-hook")

    // Second call must be idempotent: content and mtime stable when already on preferred path.
    let attrsBefore = try FileManager.default.attributesOfItem(atPath: hooksURL.path)
    let mtimeBefore = attrsBefore[.modificationDate] as? Date
    let contentBefore = try Data(contentsOf: hooksURL)
    Thread.sleep(forTimeInterval: 0.05)
    GrokHookConfigurator.configure(homeDirectory: home, bundledHookBinary: bundledHook)
    let contentAfter = try Data(contentsOf: hooksURL)
    expect(contentAfter, contentBefore, "second configure should not rewrite hooks json content")
    let attrsAfter = try FileManager.default.attributesOfItem(atPath: hooksURL.path)
    let mtimeAfter = attrsAfter[.modificationDate] as? Date
    expect(mtimeAfter, mtimeBefore, "second configure should not bump hooks json mtime")
}

/// v1 flat layout + legacy hook commands → bootstrap leaves every advertised
/// binary path live and rewrites configs without deleting compat mirrors.
func testRuntimeBootstrapUpgradesLayoutV1WithoutStrandingHookPaths() throws {
    let fm = FileManager.default
    let home = fm.temporaryDirectory.appendingPathComponent(
        "agent-halo-bootstrap-v1-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? fm.removeItem(at: home) }

    let paths = AgentHaloPaths(homeDirectory: home)
    try fm.createDirectory(at: paths.root, withIntermediateDirectories: true)

    // Simulate pre-layout-v2 data + root-level binaries + legacy hook configs.
    try "grok-old\n".write(to: paths.legacyGrokStatusLog, atomically: true, encoding: .utf8)
    try "claude-old\n".write(to: paths.legacyClaudeStatusLog, atomically: true, encoding: .utf8)
    try Data("legacy-hook-bytes".utf8).write(to: paths.legacyStatusHook)
    try Data("legacy-proxy-bytes".utf8).write(to: paths.legacyStatuslineProxy)

    let claudeDir = home.appendingPathComponent(".claude", isDirectory: true)
    try fm.createDirectory(at: claudeDir, withIntermediateDirectories: true)
    let legacyHookCmd = "\(paths.legacyStatusHook.path) PreToolUse"
    let claudeSettings: [String: Any] = [
        "hooks": [
            "PreToolUse": [[
                "matcher": ".*",
                "hooks": [["type": "command", "command": legacyHookCmd]],
            ]],
        ],
        "statusLine": [
            "type": "command",
            "command": paths.legacyStatuslineProxy.path,
        ],
    ]
    try JSONSerialization.data(withJSONObject: claudeSettings)
        .write(to: claudeDir.appendingPathComponent("settings.json"))

    let grokHooksDir = home.appendingPathComponent(".grok/hooks", isDirectory: true)
    try fm.createDirectory(at: grokHooksDir, withIntermediateDirectories: true)
    let grokHooks: [String: Any] = [
        "hooks": [
            "PreToolUse": [[
                "matcher": ".*",
                "hooks": [["type": "command", "command": "\(paths.legacyStatusHook.path) PreToolUse"]],
            ]],
            // Intentionally incomplete — bootstrap must repair missing events.
            "SessionStart": [[
                "hooks": [["type": "command", "command": paths.legacyStatusHook.path]],
            ]],
        ],
    ]
    try JSONSerialization.data(withJSONObject: grokHooks)
        .write(to: grokHooksDir.appendingPathComponent("agent-halo-status.json"))

    let bundledHook = home.appendingPathComponent("bundled-hook")
    let bundledProxy = home.appendingPathComponent("bundled-proxy")
    try Data("new-hook-v2".utf8).write(to: bundledHook)
    try Data("new-proxy-v2".utf8).write(to: bundledProxy)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundledHook.path)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundledProxy.path)

    AgentHaloRuntimeBootstrap.bootstrap(
        homeDirectory: home,
        bundledHookBinary: bundledHook,
        bundledStatuslineProxy: bundledProxy,
        fileManager: fm
    )

    // Data moved.
    expect(try String(contentsOf: paths.grokStatusLog, encoding: .utf8), "grok-old\n", "grok log migrated")
    expect(try String(contentsOf: paths.claudeStatusLog, encoding: .utf8), "claude-old\n", "claude log migrated")
    expect(!fm.fileExists(atPath: paths.legacyGrokStatusLog.path), "legacy grok log scrubbed")

    // Preferred binaries live; legacy names are rewritten away then scrubbed.
    expect(fm.isExecutableFile(atPath: paths.statusHook.path), "bin/status-hook live")
    expect(fm.isExecutableFile(atPath: paths.statuslineProxy.path), "bin/statusline-proxy live")
    expect(try String(contentsOf: paths.statusHook, encoding: .utf8), "new-hook-v2", "hook content updated")
    expect(!fm.fileExists(atPath: paths.legacyStatusHook.path), "legacy status-hook scrubbed after rewrite")
    expect(!fm.fileExists(atPath: paths.legacyStatuslineProxy.path), "legacy statusline proxy scrubbed after rewrite")
    let grokHooksJSON = try JSONSerialization.jsonObject(
        with: Data(contentsOf: grokHooksDir.appendingPathComponent("agent-halo-status.json"))
    ) as! [String: Any]
    let grokPre = ((grokHooksJSON["hooks"] as! [String: Any])["PreToolUse"] as! [[String: Any]])
    let grokCmd = ((grokPre[0]["hooks"] as! [[String: Any]])[0]["command"] as! String)
    expect(grokCmd, paths.statusHook.path, "grok config rewritten to .agent-halo/bin/status-hook")

    // Claude settings prefer bin path.
    let claudeJSON = try JSONSerialization.jsonObject(
        with: Data(contentsOf: claudeDir.appendingPathComponent("settings.json"))
    ) as! [String: Any]
    let claudeHooks = claudeJSON["hooks"] as! [String: Any]
    let pre = claudeHooks["PreToolUse"] as! [[String: Any]]
    let cmds = (pre.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }).compactMap { $0["command"] as? String }
    expect(cmds.contains { $0.contains("bin/status-hook") }, "claude hooks rewritten to bin/status-hook")
    expect(
        (claudeJSON["statusLine"] as? [String: Any])?["command"] as? String,
        paths.statuslineProxy.path,
        "statusline uses bin proxy"
    )

    // Grok hooks repaired and healthy.
    let grokFile = grokHooksDir.appendingPathComponent("agent-halo-status.json")
    expect(
        GrokHookConfigurator.isHealthyConfiguration(
            at: grokFile,
            paths: paths,
            homeDirectory: home,
            fileManager: fm
        ),
        "grok hooks healthy after bootstrap"
    )

    // Second bootstrap is idempotent for Grok config content.
    let before = try Data(contentsOf: grokFile)
    AgentHaloRuntimeBootstrap.bootstrap(
        homeDirectory: home,
        bundledHookBinary: bundledHook,
        bundledStatuslineProxy: bundledProxy,
        fileManager: fm
    )
    let after = try Data(contentsOf: grokFile)
    expect(after, before, "second bootstrap must not thrash healthy grok hooks")
}

/// Disabled agents must not receive user-config rewrites; staging still runs.
func testRuntimeBootstrapSkipsDisabledAgentUserConfig() throws {
    let fm = FileManager.default
    let home = fm.temporaryDirectory.appendingPathComponent(
        "agent-halo-bootstrap-skip-\(UUID().uuidString)", isDirectory: true
    )
    defer { try? fm.removeItem(at: home) }

    let claudeSettings = home.appendingPathComponent(".claude/settings.json")
    try fm.createDirectory(at: claudeSettings.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: claudeSettings)
    let beforeClaude = try Data(contentsOf: claudeSettings)

    let grokFile = home.appendingPathComponent(".grok/hooks/agent-halo-status.json")
    try fm.createDirectory(at: grokFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{\"hooks\":{}}".utf8).write(to: grokFile)
    let beforeGrok = try Data(contentsOf: grokFile)

    let piFile = home.appendingPathComponent(".pi/agent/extensions/agent-halo-status.ts")
    try fm.createDirectory(at: piFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("// keep-me\n".utf8).write(to: piFile)
    let beforePi = try Data(contentsOf: piFile)

    let bundledHook = home.appendingPathComponent("bundled-hook")
    let bundledProxy = home.appendingPathComponent("bundled-proxy")
    try Data("hook".utf8).write(to: bundledHook)
    try Data("proxy".utf8).write(to: bundledProxy)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundledHook.path)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundledProxy.path)

    AgentHaloRuntimeBootstrap.bootstrap(
        homeDirectory: home,
        bundledHookBinary: bundledHook,
        bundledStatuslineProxy: bundledProxy,
        fileManager: fm,
        enabledAgents: [.codex]
    )

    expect(try Data(contentsOf: claudeSettings), beforeClaude, "disabled Claude config is not rewritten")
    expect(try Data(contentsOf: grokFile), beforeGrok, "disabled Grok hooks are not rewritten")
    expect(try Data(contentsOf: piFile), beforePi, "disabled Pi extension is not rewritten")
}

func testAntigravityHookConfiguratorCreatesNamedGroupHooksJSON() throws {
    let fm = FileManager.default
    let home = fm.temporaryDirectory.appendingPathComponent(
        "agent-halo-agy-hooks-create-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? fm.removeItem(at: home) }
    try fm.createDirectory(at: home, withIntermediateDirectories: true)

    let bundled = home.appendingPathComponent("bundle-hook")
    try Data("ag-hook".utf8).write(to: bundled)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundled.path)

    AntigravityHookConfigurator.configure(homeDirectory: home, bundledHookBinary: bundled)

    let hooksURL = AntigravityHookConfigurator.hooksFile(homeDirectory: home)
    expect(fm.fileExists(atPath: hooksURL.path), "creates ~/.gemini/config/hooks.json")
    expect(
        !fm.fileExists(atPath: home.appendingPathComponent(".gemini/settings.json").path),
        "must not write ~/.gemini/settings.json"
    )
    expect(
        !fm.fileExists(atPath: home.appendingPathComponent(".gemini/antigravity-cli/settings.json").path),
        "must not write ~/.gemini/antigravity-cli/settings.json"
    )

    let paths = AgentHaloPaths(homeDirectory: home)
    expect(fm.isExecutableFile(atPath: paths.statusHook.path), "status-hook staged under .agent-halo/bin")

    let json = try JSONSerialization.jsonObject(with: Data(contentsOf: hooksURL)) as! [String: Any]
    expect(json.keys.contains(AntigravityHookConfigurator.groupName), "top-level key is agent-halo-status")
    let group = json[AntigravityHookConfigurator.groupName] as! [String: Any]
    for event in ["PreInvocation", "PostInvocation", "Stop"] {
        let command = antigravityFlatHookCommand(group, event: event)
        expect(command?.hasSuffix(" \(event)") == true, "\(event) command ends with event name")
        expect(command?.contains("status-hook") == true, "\(event) command uses status-hook")
        expect(command, "\(paths.statusHook.path) \(event)", "\(event) command is preferred path + event")
    }
    for event in ["PreToolUse", "PostToolUse"] {
        let entries = group[event] as! [[String: Any]]
        expect(entries.first?["matcher"] as? String, "*", "\(event) matcher is *")
        let hooks = entries.first?["hooks"] as? [[String: Any]]
        let command = hooks?.first?["command"] as? String
        expect(command?.hasSuffix(" \(event)") == true, "\(event) nested command ends with event name")
        expect(command, "\(paths.statusHook.path) \(event)", "\(event) nested command is preferred path + event")
    }
}

func testAntigravityHookConfiguratorMergesWithoutReplacingOrcaStatus() throws {
    let fm = FileManager.default
    let home = fm.temporaryDirectory.appendingPathComponent(
        "agent-halo-agy-hooks-merge-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? fm.removeItem(at: home) }

    let hooksURL = AntigravityHookConfigurator.hooksFile(homeDirectory: home)
    try fm.createDirectory(at: hooksURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let orcaCommand = "if [ -x '/tmp/orca/antigravity-hook.sh' ]; then ORCA_ANTIGRAVITY_EVENT='PreInvocation' /bin/sh '/tmp/orca/antigravity-hook.sh'; fi"
    let existing: [String: Any] = [
        "orca-status": [
            "PreInvocation": [[
                "type": "command",
                "command": orcaCommand,
                "timeout": 10,
            ]],
            "PostToolUse": [[
                "matcher": "*",
                "hooks": [[
                    "type": "command",
                    "command": "ORCA_ANTIGRAVITY_EVENT='PostToolUse' /bin/sh '/tmp/orca/antigravity-hook.sh'",
                ]],
            ]],
        ],
        "unrelated-key": "keep-me",
    ]
    try JSONSerialization.data(withJSONObject: existing, options: [.prettyPrinted])
        .write(to: hooksURL)

    let bundled = home.appendingPathComponent("bundle-hook")
    try Data("ag-hook".utf8).write(to: bundled)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundled.path)

    AntigravityHookConfigurator.configure(homeDirectory: home, bundledHookBinary: bundled)

    let json = try JSONSerialization.jsonObject(with: Data(contentsOf: hooksURL)) as! [String: Any]
    let text = try String(contentsOf: hooksURL, encoding: .utf8)
    expect(text.contains(orcaCommand), "orca-status command string is preserved")
    let orca = json["orca-status"] as! [String: Any]
    let orcaPre = orca["PreInvocation"] as! [[String: Any]]
    expect(orcaPre.first?["command"] as? String, orcaCommand, "orca-status PreInvocation command unchanged")
    expect(json["unrelated-key"] as? String, "keep-me", "other top-level keys are left alone")
    expect(json[AntigravityHookConfigurator.groupName] != nil, true, "agent-halo-status group is merged in")
}

func testAntigravityHookConfiguratorLeavesPreferredPathConfigAlone() throws {
    let fm = FileManager.default
    let home = fm.temporaryDirectory.appendingPathComponent(
        "agent-halo-agy-hooks-stable-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? fm.removeItem(at: home) }
    try fm.createDirectory(at: home, withIntermediateDirectories: true)

    let paths = AgentHaloPaths(homeDirectory: home)
    let bundled = home.appendingPathComponent("bundle-hook")
    try Data("ag-hook".utf8).write(to: bundled)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundled.path)
    try AgentHaloBinaryStaging.stageStatusHook(
        from: bundled,
        homeDirectory: home,
        fileManager: fm
    )

    let hooksURL = AntigravityHookConfigurator.hooksFile(homeDirectory: home)
    try fm.createDirectory(at: hooksURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let config: [String: Any] = [
        AntigravityHookConfigurator.groupName: antigravityPreferredHookGroup(statusHook: paths.statusHook.path)
    ]
    try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted])
        .write(to: hooksURL)

    let before = try Data(contentsOf: hooksURL)
    let mtimeBefore = try fm.attributesOfItem(atPath: hooksURL.path)[.modificationDate] as? Date
    Thread.sleep(forTimeInterval: 0.05)
    AntigravityHookConfigurator.configure(homeDirectory: home, bundledHookBinary: bundled)
    let after = try Data(contentsOf: hooksURL)
    let mtimeAfter = try fm.attributesOfItem(atPath: hooksURL.path)[.modificationDate] as? Date
    expect(after, before, "preferred-path five-event group must not be rewritten")
    expect(mtimeAfter, mtimeBefore, "preferred-path five-event group must not bump mtime")
}

func testAntigravityHookConfiguratorAbortsWhenRootIsNotADictionary() throws {
    let fm = FileManager.default
    let home = fm.temporaryDirectory.appendingPathComponent(
        "agent-halo-agy-hooks-bad-root-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? fm.removeItem(at: home) }

    let hooksURL = AntigravityHookConfigurator.hooksFile(homeDirectory: home)
    try fm.createDirectory(at: hooksURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let original = Data("[]".utf8)
    try original.write(to: hooksURL)

    let bundled = home.appendingPathComponent("bundle-hook")
    try Data("ag-hook".utf8).write(to: bundled)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundled.path)

    AntigravityHookConfigurator.configure(homeDirectory: home, bundledHookBinary: bundled)

    expect(try Data(contentsOf: hooksURL), original, "non-dict root must not be overwritten")
}

func testRuntimeBootstrapDoesNotCreateAntigravityHooksWhenDisabled() throws {
    let fm = FileManager.default
    let home = fm.temporaryDirectory.appendingPathComponent(
        "agent-halo-bootstrap-no-agy-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? fm.removeItem(at: home) }
    try fm.createDirectory(at: home, withIntermediateDirectories: true)

    let bundledHook = home.appendingPathComponent("bundled-hook")
    try Data("hook".utf8).write(to: bundledHook)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundledHook.path)

    AgentHaloRuntimeBootstrap.bootstrap(
        homeDirectory: home,
        bundledHookBinary: bundledHook,
        fileManager: fm,
        enabledAgents: [.codex]
    )

    expect(
        !fm.fileExists(atPath: AntigravityHookConfigurator.hooksFile(homeDirectory: home).path),
        "bootstrap(enabledAgents: [.codex]) must not create ~/.gemini/config/hooks.json"
    )
}

func testRuntimeBootstrapCreatesAntigravityHooksWhenEnabled() throws {
    let fm = FileManager.default
    let home = fm.temporaryDirectory.appendingPathComponent(
        "agent-halo-bootstrap-agy-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? fm.removeItem(at: home) }
    try fm.createDirectory(at: home, withIntermediateDirectories: true)

    let bundledHook = home.appendingPathComponent("bundled-hook")
    try Data("hook".utf8).write(to: bundledHook)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundledHook.path)

    AgentHaloRuntimeBootstrap.bootstrap(
        homeDirectory: home,
        bundledHookBinary: bundledHook,
        fileManager: fm,
        enabledAgents: [.antigravity]
    )

    let hooksURL = AntigravityHookConfigurator.hooksFile(homeDirectory: home)
    expect(fm.fileExists(atPath: hooksURL.path), "bootstrap(enabledAgents: [.antigravity]) creates hooks.json")
    let json = try JSONSerialization.jsonObject(with: Data(contentsOf: hooksURL)) as! [String: Any]
    expect(json[AntigravityHookConfigurator.groupName] != nil, true, "bootstrap writes agent-halo-status group")
}

private func antigravityFlatHookCommand(_ group: [String: Any], event: String) -> String? {
    let entries = group[event] as? [[String: Any]]
    return entries?.first?["command"] as? String
}

private func antigravityPreferredHookGroup(statusHook: String) -> [String: Any] {
    func hook(_ event: String) -> [String: Any] {
        [
            "type": "command",
            "command": "\(statusHook) \(event)",
            "timeout": 10,
        ]
    }
    return [
        "PreInvocation": [hook("PreInvocation")],
        "PostInvocation": [hook("PostInvocation")],
        "Stop": [hook("Stop")],
        "PreToolUse": [[
            "matcher": "*",
            "hooks": [hook("PreToolUse")],
        ]],
        "PostToolUse": [[
            "matcher": "*",
            "hooks": [hook("PostToolUse")],
        ]],
    ]
}

/// Preferred-path Grok config must not be rewritten on routine launches.
func testGrokHookConfiguratorLeavesPreferredPathConfigAlone() throws {
    let fm = FileManager.default
    let home = fm.temporaryDirectory.appendingPathComponent(
        "agent-halo-grok-healthy-bin-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? fm.removeItem(at: home) }
    try fm.createDirectory(at: home, withIntermediateDirectories: true)

    let paths = AgentHaloPaths(homeDirectory: home)
    let bundled = home.appendingPathComponent("bundle-hook")
    try Data("hook".utf8).write(to: bundled)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundled.path)

    try AgentHaloBinaryStaging.stageStatusHook(
        from: bundled,
        homeDirectory: home,
        fileManager: fm
    )

    let hooksDir = home.appendingPathComponent(".grok/hooks", isDirectory: true)
    try fm.createDirectory(at: hooksDir, withIntermediateDirectories: true)
    var hooks: [String: Any] = [:]
    let events: [(String, String?)] = [
        ("SessionStart", nil), ("UserPromptSubmit", nil),
        ("PreToolUse", ".*"), ("PostToolUse", ".*"), ("PostToolUseFailure", ".*"),
        ("Notification", nil), ("Stop", nil), ("StopFailure", nil), ("SessionEnd", nil),
        ("PreCompact", ""), ("PostCompact", ""),
    ]
    for (event, matcher) in events {
        var entry: [String: Any] = [
            "hooks": [["type": "command", "command": paths.statusHook.path]],
        ]
        if let matcher { entry["matcher"] = matcher }
        hooks[event] = [entry]
    }
    let hooksFile = hooksDir.appendingPathComponent("agent-halo-status.json")
    try JSONSerialization.data(withJSONObject: ["hooks": hooks], options: [.prettyPrinted])
        .write(to: hooksFile)

    let before = try Data(contentsOf: hooksFile)
    GrokHookConfigurator.configure(homeDirectory: home, bundledHookBinary: bundled)
    let after = try Data(contentsOf: hooksFile)
    expect(after, before, "preferred-path config must not be rewritten")
}

/// Legacy root path in Grok hooks must be rewritten to bin/status-hook on launch.
func testGrokHookConfiguratorRewritesLegacyRootPath() throws {
    let fm = FileManager.default
    let home = fm.temporaryDirectory.appendingPathComponent(
        "agent-halo-grok-rewrite-legacy-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? fm.removeItem(at: home) }
    try fm.createDirectory(at: home, withIntermediateDirectories: true)

    let paths = AgentHaloPaths(homeDirectory: home)
    try fm.createDirectory(at: paths.root, withIntermediateDirectories: true)
    try Data("legacy-bin".utf8).write(to: paths.legacyStatusHook)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.legacyStatusHook.path)

    let hooksDir = home.appendingPathComponent(".grok/hooks", isDirectory: true)
    try fm.createDirectory(at: hooksDir, withIntermediateDirectories: true)
    var hooks: [String: Any] = [:]
    for event in ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                  "PostToolUseFailure", "Notification", "Stop", "StopFailure",
                  "SessionEnd", "PreCompact", "PostCompact"] {
        var entry: [String: Any] = [
            "hooks": [["type": "command", "command": "\(paths.legacyStatusHook.path) \(event)"]],
        ]
        if event.contains("Tool") { entry["matcher"] = ".*" }
        if event.contains("Compact") { entry["matcher"] = "" }
        hooks[event] = [entry]
    }
    try JSONSerialization.data(withJSONObject: ["hooks": hooks])
        .write(to: hooksDir.appendingPathComponent("agent-halo-status.json"))

    let bundled = home.appendingPathComponent("bundle-hook")
    try Data("new".utf8).write(to: bundled)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundled.path)

    GrokHookConfigurator.configure(homeDirectory: home, bundledHookBinary: bundled)
    AgentHaloBinaryStaging.scrubUnreferencedLegacyBinaries(homeDirectory: home, fileManager: fm)

    let hooksFile = hooksDir.appendingPathComponent("agent-halo-status.json")
    expect(
        GrokHookConfigurator.isOnPreferredPath(
            at: hooksFile,
            preferredPath: paths.statusHook.path,
            fileManager: fm
        ),
        "legacy root path rewritten to preferred"
    )
    let cmd = try {
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: hooksFile)) as! [String: Any]
        let pre = (json["hooks"] as! [String: Any])["PreToolUse"] as! [[String: Any]]
        return (pre[0]["hooks"] as! [[String: Any]])[0]["command"] as! String
    }()
    expect(cmd, paths.statusHook.path, "command is bin/status-hook")
    expect(!fm.fileExists(atPath: paths.legacyStatusHook.path), "unreferenced legacy binary removed")
}

/// Dead executable in hooks config must be repaired on next configure.
func testGrokHookConfiguratorRepairsDeadExecutableCommand() throws {
    let fm = FileManager.default
    let home = fm.temporaryDirectory.appendingPathComponent(
        "agent-halo-grok-dead-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? fm.removeItem(at: home) }
    try fm.createDirectory(at: home, withIntermediateDirectories: true)

    let hooksDir = home.appendingPathComponent(".grok/hooks", isDirectory: true)
    try fm.createDirectory(at: hooksDir, withIntermediateDirectories: true)
    let dead = home.appendingPathComponent("missing-binary")
    let hooks: [String: Any] = [
        "hooks": [
            "PreToolUse": [[
                "matcher": ".*",
                "hooks": [["type": "command", "command": "\(dead.path) PreToolUse"]],
            ]],
            "SessionStart": [[
                "hooks": [["type": "command", "command": dead.path]],
            ]],
        ],
    ]
    try JSONSerialization.data(withJSONObject: hooks)
        .write(to: hooksDir.appendingPathComponent("agent-halo-status.json"))

    let bundled = home.appendingPathComponent("bundle-hook")
    try Data("live".utf8).write(to: bundled)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundled.path)

    GrokHookConfigurator.configure(homeDirectory: home, bundledHookBinary: bundled)

    let paths = AgentHaloPaths(homeDirectory: home)
    let hooksFile = hooksDir.appendingPathComponent("agent-halo-status.json")
    expect(
        GrokHookConfigurator.isHealthyConfiguration(
            at: hooksFile,
            paths: paths,
            homeDirectory: home,
            fileManager: fm
        ),
        "dead command repaired to healthy config"
    )
    let repaired = try JSONSerialization.jsonObject(with: Data(contentsOf: hooksFile)) as! [String: Any]
    let repairedPre = ((repaired["hooks"] as! [String: Any])["PreToolUse"] as! [[String: Any]])
    let repairedCmd = ((repairedPre[0]["hooks"] as! [[String: Any]])[0]["command"] as! String)
    expect(repairedCmd, paths.statusHook.path, "preferred .agent-halo/bin command after repair")
    expect(!repairedCmd.contains("missing-binary"), "dead path removed")
}

func testBinaryStagingNeverLeavesDestinationMissing() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(
        "agent-halo-stage-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? fm.removeItem(at: root) }
    try fm.createDirectory(at: root, withIntermediateDirectories: true)

    let dest = root.appendingPathComponent("status-hook")
    let v1 = root.appendingPathComponent("v1")
    let v2 = root.appendingPathComponent("v2")
    try Data("version-1".utf8).write(to: v1)
    try Data("version-2".utf8).write(to: v2)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: v1.path)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: v2.path)

    try AgentHaloBinaryStaging.stageExecutable(from: v1, to: dest, fileManager: fm)
    expect(try String(contentsOf: dest, encoding: .utf8), "version-1", "initial stage")
    expect(fm.isExecutableFile(atPath: dest.path), "executable after stage")

    // Replace in place — path must still exist (atomic replace).
    try AgentHaloBinaryStaging.stageExecutable(from: v2, to: dest, fileManager: fm)
    expect(try String(contentsOf: dest, encoding: .utf8), "version-2", "atomic upgrade")
    expect(fm.isExecutableFile(atPath: dest.path), "still executable after replace")

}

func testStatuslineProxyRecursionCheckUsesExactExecutablePaths() {
    let home = URL(
        fileURLWithPath: "/tmp/agent-halo-statusline-command-check",
        isDirectory: true
    )
    let paths = AgentHaloPaths(homeDirectory: home)

    expect(
        AgentHaloBinaryStaging.commandReferencesExecutable(
            "\"\(paths.statuslineProxy.path)\" --ignored",
            candidates: [paths.statuslineProxy, paths.legacyStatuslineProxy]
        ),
        "preferred proxy executable should be detected exactly"
    )
    expect(
        AgentHaloBinaryStaging.commandReferencesExecutable(
            paths.legacyStatuslineProxy.path,
            candidates: [paths.statuslineProxy, paths.legacyStatuslineProxy]
        ),
        "legacy proxy executable should be detected exactly"
    )
    expect(
        !AgentHaloBinaryStaging.commandReferencesExecutable(
            "/usr/local/bin/my-statusline-proxy --theme statusline-proxy",
            candidates: [paths.statuslineProxy, paths.legacyStatuslineProxy]
        ),
        "unrelated commands containing statusline-proxy must remain runnable"
    )
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
    let installedProxy = home.appendingPathComponent(".agent-halo/bin/statusline-proxy")
    let storedCommand = home.appendingPathComponent(".agent-halo/state/statusline-original-command")

    expect(statusLine["command"] as? String, installedProxy.path, "Claude statusline should use AgentHalo proxy")
    expect(statusLine["padding"] as? Int, 0, "Claude statusline padding should be preserved")
    expect(configured["theme"] as? String, "dark", "unrelated Claude settings should be preserved")
    expect(try String(contentsOf: storedCommand, encoding: .utf8), originalCommand, "existing ccline command should be preserved exactly")
    expect(FileManager.default.isExecutableFile(atPath: installedProxy.path), "installed statusline proxy should be executable")
    expect(
        ClaudeStatusLineConfigurator.isConfigured(homeDirectory: home),
        "fresh AgentHalo proxy configuration should be recognized"
    )

    var externallyRewritten = configured
    externallyRewritten["statusLine"] = [
        "type": "command",
        "command": originalCommand,
        "padding": 0,
    ]
    try JSONSerialization.data(withJSONObject: externallyRewritten).write(to: settingsURL, options: [.atomic])
    expect(
        !ClaudeStatusLineConfigurator.isConfigured(homeDirectory: home),
        "external ccline rewrite should require reconciliation"
    )

    ClaudeStatusLineConfigurator.configure(homeDirectory: home, bundledProxyBinary: bundledProxy)
    let repaired = try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as! [String: Any]
    let repairedStatusLine = repaired["statusLine"] as! [String: Any]
    expect(repairedStatusLine["command"] as? String, installedProxy.path, "proxy should be restored")
    expect(try String(contentsOf: storedCommand, encoding: .utf8), originalCommand, "ccline should remain downstream")
    expect(repaired["theme"] as? String, "dark", "unrelated settings should survive repair")
}


func testClaudeHookConfiguratorRewritesLegacyPathToPreferred() throws {
    let home = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agent-halo-hook-rewrite-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let fm = FileManager.default
    let claudeDir = home.appendingPathComponent(".claude", isDirectory: true)
    try fm.createDirectory(at: claudeDir, withIntermediateDirectories: true)
    let paths = AgentHaloPaths(homeDirectory: home)
    try fm.createDirectory(at: paths.root, withIntermediateDirectories: true)
    try Data("old-binary".utf8).write(to: paths.legacyStatusHook)
    try Data("bundled".utf8).write(to: home.appendingPathComponent("bundle-hook"))
    let legacyCommand = "\(paths.legacyStatusHook.path) PreToolUse"
    let settings: [String: Any] = [
        "hooks": [
            "PreToolUse": [[
                "matcher": ".*",
                "hooks": [["type": "command", "command": legacyCommand]]
            ]]
        ]
    ]
    try JSONSerialization.data(withJSONObject: settings).write(to: claudeDir.appendingPathComponent("settings.json"))

    ClaudeHookConfigurator.configure(
        homeDirectory: home,
        bundledHookBinary: home.appendingPathComponent("bundle-hook")
    )

    let settingsJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: claudeDir.appendingPathComponent("settings.json"))) as! [String: Any]
    let hooks = settingsJSON["hooks"] as! [String: Any]
    let pre = hooks["PreToolUse"] as! [[String: Any]]
    let commands = (pre.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }).compactMap { $0["command"] as? String }
    expect(commands.contains { $0.contains("bin/status-hook") }, "settings should point at bin/status-hook")
    expect(!commands.contains { $0.contains("claude-code-status-hook") }, "legacy command should be rewritten away")
    expect(fm.fileExists(atPath: paths.statusHook.path), "new binary staged")
    AgentHaloBinaryStaging.scrubUnreferencedLegacyBinaries(homeDirectory: home, fileManager: fm)
    expect(!fm.fileExists(atPath: paths.legacyStatusHook.path), "legacy binary scrubbed after rewrite")
}

func testClaudeHookConfiguratorDoesNotDeleteLegacyBinaryWhenBundledMissing() throws {
    let home = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agent-halo-hook-no-bundle-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let fm = FileManager.default
    let paths = AgentHaloPaths(homeDirectory: home)
    try fm.createDirectory(at: paths.root, withIntermediateDirectories: true)
    try Data("old-binary".utf8).write(to: paths.legacyStatusHook)

    ClaudeHookConfigurator.configure(homeDirectory: home, bundledHookBinary: nil)

    expect(fm.fileExists(atPath: paths.legacyStatusHook.path), "missing bundle must not delete legacy binary")
}

func testClaudeStatusLineConfiguratorRewritesLegacyProxyToPreferred() throws {
    let home = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agent-halo-statusline-rewrite-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let fm = FileManager.default
    let claude = home.appendingPathComponent(".claude", isDirectory: true)
    try fm.createDirectory(at: claude, withIntermediateDirectories: true)
    let paths = AgentHaloPaths(homeDirectory: home)
    try fm.createDirectory(at: paths.root, withIntermediateDirectories: true)
    try Data("old-proxy".utf8).write(to: paths.legacyStatuslineProxy)
    let settings: [String: Any] = [
        "statusLine": ["type": "command", "command": paths.legacyStatuslineProxy.path]
    ]
    try JSONSerialization.data(withJSONObject: settings).write(to: claude.appendingPathComponent("settings.json"))
    let bundled = home.appendingPathComponent("bundled-proxy")
    try Data("proxy".utf8).write(to: bundled)

    ClaudeStatusLineConfigurator.configure(homeDirectory: home, bundledProxyBinary: bundled)

    let configured = try JSONSerialization.jsonObject(with: Data(contentsOf: claude.appendingPathComponent("settings.json"))) as! [String: Any]
    let statusLine = configured["statusLine"] as! [String: Any]
    expect(statusLine["command"] as? String, paths.statuslineProxy.path, "statusline uses bin/statusline-proxy")
    expect(fm.fileExists(atPath: paths.statuslineProxy.path), "new proxy staged")
    AgentHaloBinaryStaging.scrubUnreferencedLegacyBinaries(homeDirectory: home, fileManager: fm)
    expect(!fm.fileExists(atPath: paths.legacyStatuslineProxy.path), "legacy proxy scrubbed after rewrite")
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
    expect(aggregate.label, "OFFLINE", "hidden error should return offline")
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

func testRateLimitReaderReadsExplicitMonthlyQuota() {
    let reader = RateLimitReader()
    let line = #"{"payload":{"info":{"rate_limits":{"monthly":{"used_percent":37,"resets_at":4102444800}},"last_token_usage":{"input_tokens":25},"model_context_window":100}}}"#
    let snapshot = reader.parseForTest(lines: [line])
    expect(snapshot?.hasMonthly ?? false, true, "monthly quota should be detected")
    expect(snapshot?.hasPrimary, false, "monthly quota stays separate from Plus primary")
    expect(snapshot?.hasSecondary, false, "monthly quota stays separate from Plus secondary")
    expect(snapshot?.monthlyUsedPercent, 37, "monthly used percent")
    expect(snapshot?.primaryUsedPercent, 0, "Plus primary should be zero when absent")
}

func testRateLimitReaderReadsFreeCreditsRemainingAsMonthlyQuota() {
    let reader = RateLimitReader()
    let line = #"{"payload":{"info":{"rate_limits":{"credits":{"remaining_percent":95,"resets_at":1785628800}},"last_token_usage":{"input_tokens":25},"model_context_window":100}}}"#
    let snapshot = reader.parseForTest(lines: [line])
    expect(snapshot?.hasMonthly ?? false, true, "free credits should be detected as monthly quota")
    expect(snapshot?.monthlyUsedPercent, 5, "credits remaining percent should convert to used percent")
    expect(snapshot?.monthlyResetAt, Date(timeIntervalSince1970: 1_785_628_800), "credits monthly reset")
    expect(snapshot?.hasPrimary, false, "credits monthly quota should not fill Plus primary")
    expect(snapshot?.hasSecondary, false, "credits monthly quota should not fill Plus secondary")
}

func testRateLimitReaderKeepsNewestCompletePlusBucketsOverOlderMonthlyUsage() {
    let reader = RateLimitReader()
    let plus = #"{"payload":{"info":{"last_token_usage":{"input_tokens":25},"model_context_window":100},"rate_limits":{"limit_id":"codex","limit_name":null,"primary":{"used_percent":100,"window_minutes":300,"resets_at":4102441200},"secondary":{"used_percent":60,"window_minutes":10080,"resets_at":4102444800},"credits":{"balance":"0","has_credits":false,"unlimited":false},"individual_limit":null,"plan_type":"plus","rate_limit_reached_type":null}}}"#
    let monthly = #"{"payload":{"info":{"rate_limits":{"credits":{"remaining_percent":82,"resets_at":1785628800}}}}}"#
    let snapshot = reader.parseForTest(lines: [plus, monthly])
    expect(snapshot?.hasMonthly ?? false, false, "older monthly usage should not override a complete newest Plus snapshot")
    expect(snapshot?.monthlyUsedPercent, nil, "Plus compatibility should require explicit monthly data in the same snapshot")
    expect(snapshot?.hasMonthlyPlan ?? false, false, "Plus compatibility should not force monthly layout")
    expect(snapshot?.hasPrimary, true, "newest Plus primary should render as 5-hour quota")
    expect(snapshot?.primaryUsedPercent, 100, "newest Plus primary used percent")
    expect(snapshot?.hasSecondary, true, "newest Plus secondary should render as weekly quota")
    expect(snapshot?.secondaryUsedPercent, 60, "newest Plus secondary used percent")
}

func testRateLimitReaderLeavesResetOnlyMonthlyQuotaPending() {
    let reader = RateLimitReader()
    let line = #"{"payload":{"info":{"rate_limits":{"monthly":{"resets_at":1785628800}},"last_token_usage":{"input_tokens":25},"model_context_window":100}}}"#
    let snapshot = reader.parseForTest(lines: [line])
    expect(snapshot?.hasMonthly ?? false, false, "reset-only monthly bucket should not fabricate usage")
    expect(snapshot?.monthlyUsedPercent, nil, "reset-only monthly bucket should wait for usage data")
    expect(snapshot?.hasMonthlyPlan ?? false, true, "reset-only monthly bucket should still mark monthly layout")
    expect(snapshot?.monthlyResetAt, Date(timeIntervalSince1970: 1_785_628_800), "reset-only monthly bucket should keep reset time")
}

func testRateLimitReaderReadsLongWindowPrimaryAsMonthly() {
    let reader = RateLimitReader()
    // A solo primary with a 30-day window is the free-plan shape — the reader
    // should reclassify it as monthly so the panel shows "月额度" not "5 小时额度".
    let line = #"{"payload":{"info":{"rate_limits":{"primary":{"used_percent":41,"window_minutes":43200,"resets_at":4102444800}}}}}"#
    let snapshot = reader.parseForTest(lines: [line])
    expect(snapshot?.hasMonthly ?? false, true, "long-window primary becomes monthly")
    expect(snapshot?.monthlyUsedPercent, 41, "long-window primary used as monthly")
    expect(snapshot?.hasPrimary, false, "long-window primary should not also fill Plus primary")
}

func testRateLimitReaderDoesNotTreatSecondaryBucketAsMonthly() {
    let reader = RateLimitReader()
    let line = #"{"payload":{"info":{"last_token_usage":{"input_tokens":25},"model_context_window":100},"rate_limits":{"primary":{"used_percent":2,"window_minutes":300,"resets_at":4102441200},"secondary":{"used_percent":45,"window_minutes":10080,"resets_at":4102444800},"credits":null,"plan_type":"free"}}}"#
    let snapshot = reader.parseForTest(lines: [line])
    expect(snapshot?.hasMonthly ?? false, false, "secondary bucket should not become monthly quota")
    expect(snapshot?.monthlyUsedPercent, nil, "monthly used percent should require an explicit monthly bucket")
    expect(snapshot?.hasMonthlyPlan ?? false, true, "free-plan marker should keep the UI on single monthly quota")
    expect(snapshot?.hasPrimary, false, "free-plan primary bucket should not render as 5-hour quota")
    expect(snapshot?.hasSecondary, false, "free-plan secondary bucket should not render as weekly quota")
}

func testRateLimitReaderTreatsNullCreditsCodexCompatibilityAsPlus() {
    let reader = RateLimitReader()
    let line = #"{"payload":{"info":{"last_token_usage":{"input_tokens":25},"model_context_window":100},"rate_limits":{"limit_id":"codex","limit_name":null,"primary":{"used_percent":2,"window_minutes":300,"resets_at":4102441200},"secondary":{"used_percent":45,"window_minutes":10080,"resets_at":4102444800},"credits":null,"individual_limit":null,"plan_type":"plus","rate_limit_reached_type":null}}}"#
    let snapshot = reader.parseForTest(lines: [line])
    expect(snapshot?.hasMonthly ?? false, false, "null credits compatibility should not become monthly")
    expect(snapshot?.monthlyUsedPercent, nil, "monthly used percent should require explicit monthly data")
    expect(snapshot?.hasMonthlyPlan ?? false, false, "null credits compatibility should keep the Plus two-row quota")
    expect(snapshot?.hasPrimary, true, "null credits primary should render as 5-hour quota")
    expect(snapshot?.hasSecondary, true, "null credits secondary should render as weekly quota")
}

func testRateLimitReaderTreatsEmptyCodexCreditsCompatibilityAsPlus() {
    let reader = RateLimitReader()
    let line = #"{"payload":{"info":{"last_token_usage":{"input_tokens":25},"model_context_window":100},"rate_limits":{"limit_id":"codex","limit_name":null,"primary":{"used_percent":100,"window_minutes":300,"resets_at":4102441200},"secondary":{"used_percent":60,"window_minutes":10080,"resets_at":4102444800},"credits":{"balance":"0","has_credits":false,"unlimited":false},"individual_limit":null,"plan_type":"plus","rate_limit_reached_type":null}}}"#
    let snapshot = reader.parseForTest(lines: [line])
    expect(snapshot?.hasMonthly ?? false, false, "empty Codex credits should not fabricate monthly usage")
    expect(snapshot?.monthlyUsedPercent, nil, "empty Codex credits should require explicit monthly data")
    expect(snapshot?.hasMonthlyPlan ?? false, false, "empty Codex credits compatibility should keep the Plus two-row quota")
    expect(snapshot?.hasPrimary, true, "empty Codex credits primary should render as 5-hour quota")
    expect(snapshot?.hasSecondary, true, "empty Codex credits secondary should render as weekly quota")
}

func testRateLimitReaderDoesNotTreatEmptyLegacyCreditsSecondaryAsMonthly() {
    let reader = RateLimitReader()
    let line = #"{"payload":{"info":{"last_token_usage":{"input_tokens":25},"model_context_window":100},"rate_limits":{"primary":{"used_percent":7,"window_minutes":300,"resets_at":4102441200},"secondary":{"used_percent":55,"window_minutes":10080,"resets_at":4102444800},"credits":{"has_credits":false,"unlimited":false,"balance":null},"plan_type":null}}}"#
    let snapshot = reader.parseForTest(lines: [line])
    expect(snapshot?.hasMonthly ?? false, false, "empty legacy credits should not make secondary monthly")
    expect(snapshot?.monthlyUsedPercent, nil, "monthly used percent should require explicit monthly data")
    expect(snapshot?.hasPrimary, true, "primary bucket should stay available")
    expect(snapshot?.hasSecondary, true, "secondary bucket should stay available")
}

func testRateLimitReaderDoesNotReturnEarlyOnContextOnlySnapshot() {
    let reader = RateLimitReader()
    // Newest-first: a context-only snapshot followed by the real rate-limit
    // snapshot. The reader must keep scanning past the context-only line
    // instead of bailing with nil quota.
    let contextOnly = #"{"payload":{"info":{"last_token_usage":{"input_tokens":50},"model_context_window":100}}}"#
    let quota = #"{"payload":{"info":{"rate_limits":{"primary":{"used_percent":25,"resets_at":1781765880},"secondary":{"used_percent":40,"resets_at":1781938560}}}}}"#
    let snapshot = reader.parseForTest(lines: [contextOnly, quota])
    expect(snapshot?.hasPrimary, true, "Plus primary should be found after context-only snapshot")
    expect(snapshot?.primaryUsedPercent, 25, "Plus primary used percent")
    expect(snapshot?.secondaryUsedPercent, 40, "Plus secondary used percent")
    expect(snapshot?.contextUsedPercent, 50, "context usage carried over from earlier snapshot")
}

func testClaudeStatusLineUsageParserReadsAuthoritativeContextPercent() {
    let now = Date()
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

func testGrokSessionContextReaderReadsSignalsPercentAndSummary() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agent-halo-grok-context-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: root)
    }
    let cwd = "/Users/example/work/AgentHalo"
    let sessionId = "019f94e7-1b86-74c2-838f-e42b06d4d9dc"
    let sessionDir = root
        .appendingPathComponent(GrokSessionContextReader.encodeWorkspaceDirectory(cwd), isDirectory: true)
        .appendingPathComponent(sessionId, isDirectory: true)
    try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

    let signals = """
    {"contextWindowUsage":26,"contextTokensUsed":130000,"contextWindowTokens":500000,"primaryModelId":"grok-4.5"}
    """
    try Data(signals.utf8).write(to: sessionDir.appendingPathComponent("signals.json"))

    let summary = """
    {"info":{"id":"\(sessionId)","cwd":"\(cwd)"},"generated_title":"Wire Grok context pill","session_summary":"fallback title","current_model_id":"grok-4.5"}
    """
    try Data(summary.utf8).write(to: sessionDir.appendingPathComponent("summary.json"))

    let reader = GrokSessionContextReader(sessionsRoot: root)
    let byCwd = reader.read(sessionId: sessionId, cwd: cwd)
    expect(byCwd?.contextUsedPercent, 26, "signals contextWindowUsage drives the pill")
    expect(byCwd?.contextTokensUsed, 130_000, "token counters preserved")
    expect(byCwd?.contextWindowTokens, 500_000, "window size preserved")
    expect(byCwd?.modelName, "grok-4.5", "model from signals")
    expect(byCwd?.sessionTitle, "Wire Grok context pill", "title from summary")
    expect(byCwd?.projectName, "AgentHalo", "project from cwd leaf")
    expect(byCwd?.workingDirectory, cwd, "cwd from summary.info")

    let scanned = reader.read(sessionId: sessionId)
    expect(scanned?.contextUsedPercent, 26, "scan fallback finds the session without cwd")

    expect(
        GrokSessionContextReader.encodeWorkspaceDirectory(cwd),
        "%2FUsers%2Fexample%2Fwork%2FAgentHalo",
        "workspace dirs must match Grok percent-encoding"
    )
}

func testGrokSessionContextReaderFallsBackToTokenRatio() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agent-halo-grok-context-ratio-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: root)
    }
    let sessionId = "session-ratio"
    let sessionDir = root
        .appendingPathComponent("%2Ftmp", isDirectory: true)
        .appendingPathComponent(sessionId, isDirectory: true)
    try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
    try Data(#"{"contextTokensUsed":50,"contextWindowTokens":200}"#.utf8)
        .write(to: sessionDir.appendingPathComponent("signals.json"))

    let snapshot = GrokSessionContextReader(sessionsRoot: root).read(sessionId: sessionId)
    expectAlmost(snapshot?.contextUsedPercent ?? -1, 25, tolerance: 0.01, "token ratio fallback")
}

func testGrokSessionContextReaderPrefersLiveUpdatesTotalTokens() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agent-halo-grok-context-live-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: root)
    }
    let sessionId = "session-live"
    let sessionDir = root
        .appendingPathComponent("%2Ftmp", isDirectory: true)
        .appendingPathComponent(sessionId, isDirectory: true)
    try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

    // End-of-previous-turn snapshot freezes at 26% / 130k.
    try Data(
        #"{"contextWindowUsage":26,"contextTokensUsed":130000,"contextWindowTokens":500000,"primaryModelId":"grok-4.5"}"#
            .utf8
    ).write(to: sessionDir.appendingPathComponent("signals.json"))

    // Mid-turn streaming estimate after compaction is much lower.
    let updates = """
    {"timestamp":1,"method":"session/update","params":{"_meta":{"totalTokens":40000},"update":{"sessionUpdate":"agent_thought_chunk"}}}
    {"timestamp":2,"method":"session/update","params":{"_meta":{"totalTokens":65000},"update":{"sessionUpdate":"tool_call"}}}
    {"timestamp":3,"method":"session/update","params":{"update":{"sessionUpdate":"tool_call_update"}}}
    """
    try Data(updates.utf8).write(to: sessionDir.appendingPathComponent("updates.jsonl"))

    let snapshot = GrokSessionContextReader(sessionsRoot: root).read(sessionId: sessionId)
    expect(snapshot?.contextTokensUsed, 65_000, "live totalTokens must override stale signals counters")
    expectAlmost(
        snapshot?.contextUsedPercent ?? -1,
        13,
        tolerance: 0.01,
        "pill percent = liveTokens / contextWindowTokens"
    )
    expect(snapshot?.contextWindowTokens, 500_000, "window size still comes from signals")
}

func testGrokSessionContextReaderLiveTokensWithoutSignals() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agent-halo-grok-context-no-signals-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: root)
    }
    let cwd = "/Users/example/work/AgentHalo"
    let sessionId = "session-first-turn"
    let sessionDir = root
        .appendingPathComponent(GrokSessionContextReader.encodeWorkspaceDirectory(cwd), isDirectory: true)
        .appendingPathComponent(sessionId, isDirectory: true)
    try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

    // Brand-new session: Grok streams totalTokens before writing end-of-turn signals.
    let updates = """
    {"timestamp":1,"method":"session/update","params":{"_meta":{"totalTokens":25000},"update":{"sessionUpdate":"agent_thought_chunk"}}}
    {"timestamp":2,"method":"session/update","params":{"_meta":{"totalTokens":50000},"update":{"sessionUpdate":"tool_call"}}}
    """
    try Data(updates.utf8).write(to: sessionDir.appendingPathComponent("updates.jsonl"))

    let summary = """
    {"info":{"id":"\(sessionId)","cwd":"\(cwd)"},"generated_title":"First turn pill","current_model_id":"grok-4.5"}
    """
    try Data(summary.utf8).write(to: sessionDir.appendingPathComponent("summary.json"))

    let snapshot = GrokSessionContextReader(sessionsRoot: root).read(sessionId: sessionId, cwd: cwd)
    expect(snapshot?.contextTokensUsed, 50_000, "live totalTokens alone must drive the pill")
    expect(snapshot?.contextWindowTokens, GrokSessionContextReader.defaultContextWindowTokens, "default window when signals missing")
    expectAlmost(
        snapshot?.contextUsedPercent ?? -1,
        10,
        tolerance: 0.01,
        "percent = liveTokens / default window"
    )
    expect(snapshot?.sessionTitle, "First turn pill", "summary still loads without signals")
    expect(snapshot?.modelName, "grok-4.5", "model from summary without signals")

    let scanned = GrokSessionContextReader(sessionsRoot: root).read(sessionId: sessionId)
    expect(scanned?.contextTokensUsed, 50_000, "scan must find sessions that only have updates.jsonl")
}

func testGrokActiveSessionsReaderParsesArrayEntries() throws {
    let home = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agent-halo-grok-active-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: home)
    }
    let grokDir = home.appendingPathComponent(".grok", isDirectory: true)
    try FileManager.default.createDirectory(at: grokDir, withIntermediateDirectories: true)
    let body = """
    [{"session_id":"live-1","cwd":"/Users/me/proj","pid":123},{"sessionId":"live-2","working_directory":"/tmp"}]
    """
    try Data(body.utf8).write(to: grokDir.appendingPathComponent("active_sessions.json"))

    let sessions = GrokActiveSessionsReader.read(homeDirectory: home)
    expect(sessions.count, 2, "both active entries")
    expect(sessions[0].sessionId, "live-1", "snake_case session_id")
    expect(sessions[0].cwd, "/Users/me/proj", "cwd field")
    expect(sessions[0].processId, Int32(123), "pid field")
    expect(sessions[1].sessionId, "live-2", "camelCase sessionId")
    expect(sessions[1].cwd, "/tmp", "working_directory alias")
    expect(sessions[1].processId == nil, "missing pid stays nil")

    // Dead pid → not live; live pid → live.
    expect(
        !GrokActiveSessionsReader.hasLiveSession(
            homeDirectory: home,
            isProcessAlive: { _ in false }
        ),
        "dead pid entries should not report a live session"
    )
    expect(
        GrokActiveSessionsReader.liveSessionIds(
            homeDirectory: home,
            isProcessAlive: { _ in false }
        ).isEmpty,
        "dead pid entries should expose no live session ids"
    )
    expect(
        GrokActiveSessionsReader.hasLiveSession(
            homeDirectory: home,
            isProcessAlive: { $0 == 123 }
        ),
        "alive pid should report a live session"
    )
    expect(
        GrokActiveSessionsReader.liveSessionIds(
            homeDirectory: home,
            isProcessAlive: { $0 == 123 }
        ) == Set(["live-1"]),
        "only the pid-backed live Grok session id should survive"
    )
    let liveSessions = GrokActiveSessionsReader.liveSessions(
        homeDirectory: home,
        isProcessAlive: { $0 == 123 }
    )
    expect(liveSessions.count, 1, "only one live registry entry")
    expect(liveSessions.first?.cwd, "/Users/me/proj", "live session keeps workspace evidence")
    expect(liveSessions.first?.processId, Int32(123), "live session keeps process evidence")

    try Data(#"[{"session_id":"legacy"}]"#.utf8)
        .write(to: grokDir.appendingPathComponent("active_sessions.json"))
    expect(
        GrokActiveSessionsReader.liveSessionIds(homeDirectory: home) == Set(["legacy"]),
        "pid-less legacy entries should still expose their session id"
    )
}

func testClaudeContextUsageReaderKeepsLastKnownUsageForMatchingSession() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agent-halo-claude-context-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: root)
    }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let now = Date()
    let reader = ClaudeContextUsageReader(snapshotsDirectory: root)

    let fresh = ClaudeContextUsageSnapshot(
        sessionId: "cc-session",
        usedPercent: 52.75,
        contextWindowSize: 200_000,
        updatedAt: now.addingTimeInterval(-30)
    )
    try ClaudeContextUsageStorage.write(fresh, directory: root)

    expect(reader.read(sessionIds: ["cc-session"], now: now)?.usedPercent, 52.75, "matching fresh Claude context")
    expect(reader.read(sessionIds: ["other-session"], now: now) == nil, "mismatched Claude session should be rejected")
    expect(reader.read(sessionIds: [], now: now) == nil, "missing session identity must not select arbitrary context")
    expect(
        reader.read(sessionIds: ["cc-session"], now: now.addingTimeInterval(301)) == nil,
        "Claude context older than five minutes should expire"
    )
}

func testClaudeContextUsageReaderDoesNotShareSnapshotsAcrossFiles() throws {
    let firstRoot = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agent-halo-claude-context-a-\(UUID().uuidString)", isDirectory: true)
    let secondRoot = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agent-halo-claude-context-b-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: firstRoot)
        try? FileManager.default.removeItem(at: secondRoot)
    }
    try FileManager.default.createDirectory(at: firstRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
    let now = Date()
    let first = ClaudeContextUsageSnapshot(sessionId: "shared-session", usedPercent: 10, updatedAt: now)
    let second = ClaudeContextUsageSnapshot(sessionId: "shared-session", usedPercent: 90, updatedAt: now)

    try ClaudeContextUsageStorage.write(first, directory: firstRoot)
    try ClaudeContextUsageStorage.write(second, directory: secondRoot)

    let firstRead = ClaudeContextUsageReader(snapshotsDirectory: firstRoot).read(sessionIds: ["shared-session"], now: now)
    let secondRead = ClaudeContextUsageReader(snapshotsDirectory: secondRoot).read(sessionIds: ["shared-session"], now: now)

    expect(firstRead?.usedPercent, 10, "first Claude context reader should read its own snapshot")
    expect(secondRead?.usedPercent, 90, "second Claude context reader should not reuse another file's snapshot")
}

func testClaudeContextUsageStorageSeparatesSessionsAndRejectsUnsafeIds() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agent-halo-session-usage-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let first = ClaudeContextUsageStorage.snapshotURL(directory: root, sessionId: "session-a")
    let second = ClaudeContextUsageStorage.snapshotURL(directory: root, sessionId: "session-b")

    expect(first != nil, "safe session id should produce a snapshot URL")
    expect(second != nil, "second safe session id should produce a snapshot URL")
    expect(first != second, "different sessions must not share a snapshot URL")
    expect(
        ClaudeContextUsageStorage.snapshotURL(directory: root, sessionId: "../escape") == nil,
        "path traversal session id must be rejected"
    )
}

func testClaudeContextUsageReaderRequiresExactFreshSession() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agent-halo-exact-usage-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let now = Date()
    let first = ClaudeContextUsageSnapshot(
        sessionId: "session-a",
        usedPercent: 26.5,
        modelName: "glm-latest",
        inputTokens: 53_100,
        outputTokens: 1_200,
        updatedAt: now
    )
    let second = ClaudeContextUsageSnapshot(sessionId: "session-b", usedPercent: 80, updatedAt: now)
    try ClaudeContextUsageStorage.write(first, directory: root)
    try ClaudeContextUsageStorage.write(second, directory: root)

    let reader = ClaudeContextUsageReader(snapshotsDirectory: root)
    expect(reader.read(sessionId: "session-a", now: now)?.usedPercent, 26.5, "exact session usage")
    expect(reader.read(sessionId: "missing", now: now) == nil, "another session must not be substituted")
    expect(
        reader.read(sessionId: "session-a", now: now.addingTimeInterval(301)) == nil,
        "usage older than five minutes must be rejected"
    )
}

func testClaudeContextUsageReaderRetainsExactUsageWhileSessionIsLive() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agent-halo-live-usage-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let now = Date()
    let stale = ClaudeContextUsageSnapshot(
        sessionId: "live-main",
        usedPercent: 27,
        modelName: "glm-5.2",
        inputTokens: 53_016,
        outputTokens: 852,
        updatedAt: now.addingTimeInterval(-600)
    )
    try ClaudeContextUsageStorage.write(stale, directory: root)

    let reader = ClaudeContextUsageReader(snapshotsDirectory: root)
    expect(
        reader.read(sessionId: "live-main", now: now, freshness: .whileSessionIsLive)?.modelName,
        "glm-5.2",
        "an exact live Claude session should retain its last known usage beyond five minutes"
    )
    expect(
        reader.read(sessionId: "other-main", now: now, freshness: .whileSessionIsLive) == nil,
        "live-session retention must never substitute another session's usage"
    )
    expect(
        reader.read(sessionId: "live-main", now: now, freshness: .recentOnly) == nil,
        "the normal policy should continue rejecting usage older than five minutes"
    )
}


func testClaudeContextUsageGCAgeCountProtectAndThrottle() throws {
    ClaudeContextUsageStorage.resetPruneThrottleForTests()
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("agent-halo-context-gc2-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: root) }
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    let now = ISO8601DateFormatter().date(from: "2026-06-23T12:00:00Z")!

    let stale = ClaudeContextUsageSnapshot(
        sessionId: "stale",
        usedPercent: 1,
        updatedAt: now.addingTimeInterval(-(ClaudeContextUsageConstants.diskMaxAge + 60))
    )
    try JSONEncoder().encode(stale).write(
        to: root.appendingPathComponent("stale.json"),
        options: [.atomic]
    )

    for i in 0..<(ClaudeContextUsageConstants.maxFiles + 5) {
        let snap = ClaudeContextUsageSnapshot(
            sessionId: "young-\(i)",
            usedPercent: Double(i),
            updatedAt: now.addingTimeInterval(-30)
        )
        try JSONEncoder().encode(snap).write(
            to: root.appendingPathComponent("young-\(i).json"),
            options: [.atomic]
        )
    }
    for i in 0..<10 {
        let snap = ClaudeContextUsageSnapshot(
            sessionId: "mid-\(i)",
            usedPercent: Double(i),
            updatedAt: now.addingTimeInterval(-(ClaudeContextUsageConstants.minRetainAge + 60 + TimeInterval(i)))
        )
        try JSONEncoder().encode(snap).write(
            to: root.appendingPathComponent("mid-\(i).json"),
            options: [.atomic]
        )
    }

    let deleted = ClaudeContextUsageStorage.prune(directory: root, force: true, now: now, fileManager: fm)
    expect(deleted > 0, "prune should delete something")
    expect(!fm.fileExists(atPath: root.appendingPathComponent("stale.json").path), "age prune removes stale")
    expect(
        fm.fileExists(atPath: root.appendingPathComponent(".last-prune").path),
        "successful prune should persist a cross-process throttle marker"
    )

    let remaining = try fm.contentsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".json") }
    let youngLeft = remaining.filter { $0.hasPrefix("young-") }.count
    expect(youngLeft, ClaudeContextUsageConstants.maxFiles + 5, "young files protected by minRetainAge")
    expect(remaining.count >= youngLeft, "cannot delete young to meet count")

    let stale2 = ClaudeContextUsageSnapshot(
        sessionId: "stale2",
        usedPercent: 2,
        updatedAt: now.addingTimeInterval(-(ClaudeContextUsageConstants.diskMaxAge + 120))
    )
    try JSONEncoder().encode(stale2).write(to: root.appendingPathComponent("stale2.json"), options: [.atomic])
    let throttled = ClaudeContextUsageStorage.prune(directory: root, force: false, now: now, fileManager: fm)
    expect(throttled, 0, "non-force prune within throttle window is no-op")
    expect(fm.fileExists(atPath: root.appendingPathComponent("stale2.json").path), "stale2 survives throttle")

    let forced = ClaudeContextUsageStorage.prune(directory: root, force: true, now: now, fileManager: fm)
    expect(forced >= 1, "force prune bypasses throttle")
    expect(!fm.fileExists(atPath: root.appendingPathComponent("stale2.json").path), "force prune removes stale2")

    let stale3 = ClaudeContextUsageSnapshot(
        sessionId: "stale3",
        usedPercent: 3,
        updatedAt: now.addingTimeInterval(-(ClaudeContextUsageConstants.diskMaxAge + 180))
    )
    try JSONEncoder().encode(stale3).write(
        to: root.appendingPathComponent("stale3.json"),
        options: [.atomic]
    )
    try "\(now.addingTimeInterval(3600).timeIntervalSince1970)\n".write(
        to: root.appendingPathComponent(".last-prune"),
        atomically: true,
        encoding: .utf8
    )
    let afterClockRollback = ClaudeContextUsageStorage.prune(
        directory: root,
        force: false,
        now: now,
        fileManager: fm
    )
    expect(afterClockRollback >= 1, "future prune marker must not block GC after clock rollback")
    expect(
        !fm.fileExists(atPath: root.appendingPathComponent("stale3.json").path),
        "clock rollback recovery should still remove stale snapshots"
    )
}

func testClaudeContextUsageReaderDoesNotReadLegacySingleFile() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agent-halo-context-no-legacy-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let legacyURL = root.appendingPathComponent("claude-code-context.json")
    let now = Date()
    let snapshot = ClaudeContextUsageSnapshot(
        sessionId: "sess-legacy",
        usedPercent: 42,
        updatedAt: now
    )
    try JSONEncoder().encode(snapshot).write(to: legacyURL)
    let reader = ClaudeContextUsageReader(snapshotsDirectory: root)
    expect(
        reader.read(sessionId: "sess-legacy", now: now) == nil,
        "layout v2 reader must not fall back to legacy single-file context"
    )
}

func testClaudeStatusLineProxyRuntimeCapturesUsageAndForwardsInput() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agent-halo-statusline-runtime-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: root)
    }
    let snapshotsDirectory = root.appendingPathComponent("claude-code-contexts", isDirectory: true)
    // Use wall-clock time so post-write contexts GC does not treat fixtures as >24h old.
    let now = Date()
    let input = Data(#"{"session_id":"cc-session","context_window":{"used_percentage":61.5,"context_window_size":200000}}"#.utf8)
    let otherInput = Data(#"{"session_id":"other-session","context_window":{"used_percentage":18,"context_window_size":200000}}"#.utf8)

    let captured = try ClaudeStatusLineProxyRuntime.capture(
        input: input,
        snapshotsDirectory: snapshotsDirectory,
        updatedAt: now
    )
    _ = try ClaudeStatusLineProxyRuntime.capture(
        input: otherInput,
        snapshotsDirectory: snapshotsDirectory,
        updatedAt: now
    )
    let forwarded = try ClaudeStatusLineProxyRuntime.runOriginalCommand(command: "cat", input: input)
    let guardedEnvironment = try ClaudeStatusLineProxyRuntime.runOriginalCommand(
        command: "printf \"$AGENT_HALO_STATUSLINE_PROXY_ACTIVE\"",
        input: Data()
    )

    expect(captured?.usedPercent, 61.5, "statusline proxy should capture Claude context")
    expect(forwarded.standardOutput, input, "statusline proxy should forward input unchanged")
    expect(forwarded.terminationStatus, 0, "statusline proxy should preserve successful command status")
    expect(
        guardedEnvironment.standardOutput,
        Data("1".utf8),
        "downstream commands should inherit the recursion guard"
    )
    let snapshotURL = ClaudeContextUsageStorage.snapshotURL(
        directory: snapshotsDirectory,
        sessionId: "cc-session"
    )!
    let stored = try JSONDecoder().decode(ClaudeContextUsageSnapshot.self, from: Data(contentsOf: snapshotURL))
    expect(stored, captured, "statusline proxy should persist the captured context atomically")
    let otherURL = ClaudeContextUsageStorage.snapshotURL(
        directory: snapshotsDirectory,
        sessionId: "other-session"
    )!
    expect(FileManager.default.fileExists(atPath: otherURL.path), "another Claude session should have its own snapshot")
}

func testCodexRealtimeActivityReaderDetectsAnswerStreaming() {
    let reader = CodexRealtimeActivityReader()
    let delta = #"SSE event: {"type":"response.output_text.delta","delta":"hello"}"#
    let activity = reader.findActive(in: [delta])

    expect(activity?.state, .working, "answer text delta state")
    expect(activity?.action, "Writing answer", "answer text delta action")
    // Streaming text used to flip the ring into the green "done" presentation
    // mid-answer (via `answerStreaming = true`). PR #10 keeps it blue working
    // so users can't confuse mid-stream with completion.
    expect(activity?.answerStreaming, false, "answer text delta should stay blue working, not flip to done")
}

func testCodexRealtimeActivityReaderDetectsContextCompactionStream() {
    let reader = CodexRealtimeActivityReader()
    let delta = #"SSE event: {"type":"response.output_text.delta","delta":"Compressing context"}"#
    let activity = reader.findActive(in: [delta])

    expect(activity?.state, .working, "context compaction state")
    expect(activity?.action, "Compressing context", "context compaction action")
    expect(activity?.answerStreaming, false, "compaction stream should not mark answer streaming")
}

func testCodexRealtimeActivityReaderDetectsArgumentStream() {
    let reader = CodexRealtimeActivityReader()
    let argsDelta = #"SSE event: {"type":"response.function_call_arguments.delta","item_id":"fc-1","delta":"{\"cmd\":\"git"}"#
    let activity = reader.findActive(in: [argsDelta])

    expect(activity?.state, .working, "argument stream keeps Codex active")
    expect(activity?.action, "Preparing command", "argument stream action")
}

func testCodexRealtimeActivityReaderEscalatedArgumentsAttention() {
    let reader = CodexRealtimeActivityReader()
    let escalated = #"SSE event: {"type":"response.function_call_arguments.delta","item_id":"fc-2","delta":"require_escalated sandbox_permissions justification"}"#
    let activity = reader.findActive(in: [escalated])

    expect(activity?.state, .attention, "escalated argument stream state")
    expect(activity?.action, "Needs you", "escalated argument stream action")
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

    expect(reader.findActive(in: [textDone, delta]) == nil, "text done should clear realtime working")
    expect(reader.findActive(in: [completed, delta]) == nil, "response completed should clear realtime working")
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

func testSessionReducerMapsApprovalNamedToolToAttention() {
    var reducer = SessionReducer(filePath: "/tmp/approval-tool.jsonl")
    reducer.consume(jsonLine: #"{"timestamp":"2026-06-19T01:00:00Z","type":"event_msg","payload":{"type":"task_started"}}"#)
    // PR #10: tool names containing approval/permission/request_user/needs_input
    // are attention signals even without a sandbox_permissions escalation.
    reducer.consume(jsonLine: #"{"timestamp":"2026-06-19T01:00:01Z","type":"response_item","payload":{"type":"function_call","name":"request_permission","arguments":"{}"}}"#)

    expect(reducer.snapshot.state, .attention, "approval-named tool state")
    expect(reducer.snapshot.action, "Needs you", "approval-named tool action")
    expect(reducer.snapshot.active, "approval-named tool should keep session active")
}

func testSessionReducerMapsEscalatedArgumentsStringToAttention() {
    var reducer = SessionReducer(filePath: "/tmp/escalated-args.jsonl")
    let arguments = #"{"sandbox_permissions":"require_escalated","justification":"Allow build?"}"#
    reducer.consume(jsonLine: #"{"timestamp":"2026-06-19T01:00:00Z","type":"event_msg","payload":{"type":"task_started"}}"#)
    // An unrecognized tool name whose arguments carry the escalation markers
    // should still surface as attention via the argument-string fallback.
    reducer.consume(jsonLine: #"{"timestamp":"2026-06-19T01:00:01Z","type":"response_item","payload":{"type":"function_call","name":"custom_shell","arguments":"\#(arguments.replacingOccurrences(of: "\"", with: "\\\""))"}}"#)

    expect(reducer.snapshot.state, .attention, "escalated arguments state")
    expect(reducer.snapshot.action, "Needs you", "escalated arguments action")
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

func testAggregatorFiltersClaudeAndGrokByFocusedAgent() {
    let now = ISO8601DateFormatter().date(from: "2026-07-25T02:00:00Z")!
    let claudeWorking = SessionSnapshot(
        threadId: "claude-working",
        projectName: "ClaudeProject",
        workingDirectory: "",
        state: .working,
        action: "Running command",
        lastEventAt: now,
        completedAt: nil,
        active: true,
        agent: .claudeCode
    )
    let grokWorking = SessionSnapshot(
        threadId: "grok-working",
        projectName: "GrokProject",
        workingDirectory: "",
        state: .working,
        action: "Running command",
        lastEventAt: now.addingTimeInterval(1),
        completedAt: nil,
        active: true,
        agent: .grok
    )
    let settings = HaloSettings(
        paused: false,
        installedAt: now.addingTimeInterval(-60),
        acknowledged: [:]
    )

    let grokAggregate = SessionAggregator.aggregate(
        snapshots: [claudeWorking, grokWorking],
        settings: settings,
        focusedAgent: .grok,
        now: now.addingTimeInterval(2)
    )
    expect(grokAggregate.focusedAgent, .grok, "Grok aggregate should stamp focus")
    expect(grokAggregate.state, .working, "Grok focus should use Grok working state")
    expect(grokAggregate.sessions.map(\.threadId), ["grok-working"], "Grok focus should only keep Grok sessions")
    expect(grokAggregate.detail, "GrokProject - Running command", "Grok focus detail")

    let claudeAggregate = SessionAggregator.aggregate(
        snapshots: [claudeWorking, grokWorking],
        settings: settings,
        focusedAgent: .claudeCode,
        now: now.addingTimeInterval(2)
    )
    expect(claudeAggregate.focusedAgent, .claudeCode, "Claude aggregate should stamp focus")
    expect(claudeAggregate.state, .working, "Claude focus should ignore concurrent Grok working")
    expect(claudeAggregate.sessions.map(\.threadId), ["claude-working"], "Claude focus should not include Grok sessions")
    expect(claudeAggregate.detail, "ClaudeProject - Running command", "Claude focus detail should stay Claude-only")
}

func testAggregatorFiltersByAntigravityFocusedAgent() {
    let now = Date(timeIntervalSince1970: 2_000)
    let grokWorking = SessionSnapshot(
        threadId: "grok-working",
        projectName: "GrokProject",
        workingDirectory: "",
        state: .working,
        action: "Running command",
        lastEventAt: now,
        completedAt: nil,
        active: true,
        agent: .grok
    )
    let agWorking = SessionSnapshot(
        threadId: "ag-working",
        projectName: "AGProject",
        workingDirectory: "",
        state: .working,
        action: "Thinking",
        lastEventAt: now.addingTimeInterval(1),
        completedAt: nil,
        active: true,
        agent: .antigravity
    )
    let settings = HaloSettings(
        paused: false,
        installedAt: now.addingTimeInterval(-60),
        acknowledged: [:]
    )

    let agAggregate = SessionAggregator.aggregate(
        snapshots: [grokWorking, agWorking],
        settings: settings,
        focusedAgent: .antigravity,
        now: now.addingTimeInterval(2)
    )
    expect(agAggregate.focusedAgent, .antigravity, "AG aggregate should stamp focus")
    expect(agAggregate.state, .working, "AG focus should use AG working state")
    expect(agAggregate.sessions.map(\.threadId), ["ag-working"], "AG focus should only keep AG sessions")
    expect(agAggregate.detail, "AGProject - Thinking", "AG focus detail")

    let grokAggregate = SessionAggregator.aggregate(
        snapshots: [grokWorking, agWorking],
        settings: settings,
        focusedAgent: .grok,
        now: now.addingTimeInterval(2)
    )
    expect(grokAggregate.sessions.map(\.threadId), ["grok-working"], "Grok focus should not include AG sessions")
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
    let grokAggregate = SessionAggregator.aggregate(
        snapshots: [],
        settings: HaloSettings(installedAt: now.addingTimeInterval(-60)),
        focusedAgent: .grok,
        now: now
    )

    expect(codexAggregate.label, "OFFLINE", "Codex idle label is offline")
    expect(codexAggregate.detail, "Codex is not running", "Codex offline detail")
    expect(claudeAggregate.label, "OFFLINE", "Claude idle label is offline")
    expect(claudeAggregate.detail, "Claude Code is not running", "Claude offline detail")
    expect(grokAggregate.label, "OFFLINE", "Grok idle label is offline")
    expect(grokAggregate.detail, "Grok is not running", "Grok offline detail")
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
    expect(aggregate.detail, "Claude Code is not running", "Claude focus should keep Claude offline")
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

func testAggregatorReturnsReadyAfterGrokCompletedSessionSettles() {
    let now = ISO8601DateFormatter().date(from: "2026-07-25T02:00:00Z")!
    let completion = SessionSnapshot(
        threadId: "grok-done",
        projectName: "GrokProject",
        workingDirectory: "",
        state: .done,
        action: "Complete",
        lastEventAt: now,
        completedAt: now,
        active: false,
        agent: .grok
    )

    let fresh = SessionAggregator.aggregate(
        snapshots: [completion],
        settings: HaloSettings(installedAt: now.addingTimeInterval(-60)),
        focusedAgent: .grok,
        now: now.addingTimeInterval(2)
    )
    expect(fresh.state, .done, "fresh Grok completion should show done")

    // Same short completion window as the other agents (~8s).
    let settled = SessionAggregator.aggregate(
        snapshots: [completion],
        settings: HaloSettings(installedAt: now.addingTimeInterval(-60)),
        focusedAgent: .grok,
        now: now.addingTimeInterval(12)
    )
    expect(settled.state, .idle, "settled Grok completion should return ready after ~12s")
    expect(settled.sessions.isEmpty, "settled Grok completion should no longer be visible")
}

func testAggregatorSettlesCodexCompletionLikeClaude() {
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
    let settings = HaloSettings(installedAt: now.addingTimeInterval(-60))

    let fresh = SessionAggregator.aggregate(
        snapshots: [completion],
        settings: settings,
        recentFailure: nil,
        codexRunning: true,
        focusedAgent: .codex,
        now: now.addingTimeInterval(2)
    )
    expect(fresh.state, .done, "fresh Codex completion should show done while the app is running")
    expect(fresh.sessions.map(\.threadId), ["codex-done"], "fresh Codex completion stays visible briefly")

    let settled = SessionAggregator.aggregate(
        snapshots: [completion],
        settings: settings,
        recentFailure: nil,
        codexRunning: true,
        focusedAgent: .codex,
        now: now.addingTimeInterval(12)
    )
    expect(settled.state, .idle, "Codex completion should settle after ~8s so standby can appear")
    expect(settled.sessions.isEmpty, "settled Codex completion should no longer be visible")

    let offlineWhileComplete = SessionAggregator.aggregate(
        snapshots: [completion],
        settings: settings,
        recentFailure: nil,
        codexRunning: false,
        focusedAgent: .codex,
        now: now.addingTimeInterval(2)
    )
    expect(offlineWhileComplete.state, .idle, "quitting Codex must hide done and show offline")
    expect(offlineWhileComplete.label, "OFFLINE", "offline label when Codex process is gone")
    expect(offlineWhileComplete.sessions.isEmpty, "done sessions must not survive process exit")
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
    expect(aggregate.label, "OFFLINE", "idle_prompt aggregate label")
    expect(aggregate.detail, "Claude Code is not running", "idle_prompt aggregate detail")
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

func testAntigravityReducerLifecycle() {
    let now = Date(timeIntervalSince1970: 1_000)
    var reducer = AntigravityHookStatusReducer(threadId: "t1", now: now)
    expect(reducer.snapshot.projectName, "Antigravity", "default projectName")
    expect(reducer.snapshot.agent, .antigravity, "agent stamp")
    reducer.consume(jsonLine: line(event: "PreInvocation", ts: now, cwd: "/tmp/my-repo"), now: now)
    expect(reducer.snapshot.state, .thinking, "pre invocation")
    expect(reducer.snapshot.projectName, "my-repo", "cwd last path component")
    reducer.consume(jsonLine: line(event: "PostInvocation", ts: now.addingTimeInterval(1)), now: now.addingTimeInterval(1))
    expect(reducer.snapshot.state, .thinking, "post invocation is not done")
    reducer.consume(jsonLine: line(event: "PreToolUse", tool: "run_command", ts: now.addingTimeInterval(2)), now: now.addingTimeInterval(2))
    expect(reducer.snapshot.state, .working, "pre tool")
    reducer.consume(jsonLine: line(event: "PostToolUse", ts: now.addingTimeInterval(3)), now: now.addingTimeInterval(3))
    expect(reducer.snapshot.state, .working, "reviewing")
    reducer.applyWorkingVisibility(now: now.addingTimeInterval(3.7))
    expect(reducer.snapshot.state, .thinking, "fade after 0.65s")
    reducer.consume(jsonLine: line(event: "Stop", ts: now.addingTimeInterval(5)), now: now.addingTimeInterval(5))
    expect(reducer.snapshot.state, .done, "stop")
    expect(reducer.snapshot.agent, .antigravity, "agent stamp")
}

func testAntigravityReducerIgnoresBadLineAndUnknownEvent() {
    let now = Date(timeIntervalSince1970: 1_000)
    var reducer = AntigravityHookStatusReducer(threadId: "t1", now: now)
    reducer.consume(jsonLine: #"{"event":"PreInvocation","timestamp":"1970-01-01T00:16:40Z","sessionId":"t1"}"#, now: now)
    let before = reducer.snapshot
    reducer.consume(jsonLine: "not-json", now: now.addingTimeInterval(1))
    expect(reducer.snapshot.state, before.state, "bad line keeps state")
    reducer.consume(
        jsonLine: #"{"event":"TotallyUnknown","timestamp":"1970-01-01T00:16:42Z","sessionId":"t1"}"#,
        now: now.addingTimeInterval(2)
    )
    expect(reducer.snapshot.state, .thinking, "unknown event does not change state")
    expect(reducer.snapshot.lastEventAt != before.lastEventAt, true, "unknown event updates lastEventAt")
}

func testAntigravityReducerStopFailureAndToolFailureSemantics() {
    let now = Date(timeIntervalSince1970: 1_000)
    var toolFail = AntigravityHookStatusReducer(threadId: "t1", now: now)
    toolFail.consume(jsonLine: line(event: "PreInvocation", ts: now), now: now)
    toolFail.consume(jsonLine: line(event: "PreToolUse", tool: "run_command", ts: now.addingTimeInterval(2)), now: now.addingTimeInterval(2))
    toolFail.consume(jsonLine: line(event: "PostToolUse", ts: now.addingTimeInterval(3), errorText: "exit 1"), now: now.addingTimeInterval(3))
    expect(toolFail.snapshot.state, .working, "single tool failure stays working")
    expect(toolFail.snapshot.action, "Tool failed", "tool failure action")
    expect(toolFail.snapshot.active, true, "single tool failure stays active")
    toolFail.applyWorkingVisibility(now: now.addingTimeInterval(3.7))
    expect(toolFail.snapshot.state, .thinking, "tool failure fades to thinking")

    var fatalStop = AntigravityHookStatusReducer(threadId: "t1", now: now)
    fatalStop.consume(jsonLine: line(event: "PreInvocation", ts: now), now: now)
    fatalStop.consume(jsonLine: line(event: "Stop", ts: now.addingTimeInterval(5), fatal: true), now: now.addingTimeInterval(5))
    expect(fatalStop.snapshot.state, .error, "fatal stop is whole-turn error")
    expect(fatalStop.snapshot.active, false, "fatal stop deactivates")
    expect(fatalStop.snapshot.completedAt == nil, true, "fatal stop has no completedAt")

    var errorStop = AntigravityHookStatusReducer(threadId: "t1", now: now)
    errorStop.consume(jsonLine: line(event: "PreInvocation", ts: now), now: now)
    errorStop.consume(jsonLine: line(event: "Stop", ts: now.addingTimeInterval(5), errorText: "boom"), now: now.addingTimeInterval(5))
    expect(errorStop.snapshot.state, .error, "stop errorText is whole-turn error")
    expect(errorStop.snapshot.active, false, "stop errorText deactivates")

    // Live hook JSONL writes `"errorText":null` / `"fatal":null` on successful
    // Stop. NSNull must not be treated as a failure string.
    var nullStop = AntigravityHookStatusReducer(threadId: "t1", now: now)
    nullStop.consume(jsonLine: line(event: "PreInvocation", ts: now), now: now)
    nullStop.consume(
        jsonLine: #"{"cwd":"/Users/wjs/.gemini/config","errorText":null,"event":"Stop","fatal":null,"notificationType":null,"permissionMode":null,"sessionId":"t1","source":"antigravity-hook","timestamp":"2026-08-16T05:24:03.883Z","toolName":null}"#,
        now: now.addingTimeInterval(5)
    )
    expect(nullStop.snapshot.state, .done, "Stop with JSON null errorText is success")
    expect(nullStop.snapshot.action, "Complete", "successful Stop action")
    expect(nullStop.snapshot.active, false, "successful Stop deactivates")
    expect(nullStop.snapshot.completedAt != nil, true, "successful Stop has completedAt")
}

func testAntigravityReducerIdentityPostInvocationHoldAndPermission() {
    let now = Date(timeIntervalSince1970: 1_000)
    var reducer = AntigravityHookStatusReducer(threadId: "t1", now: now)
    expect(reducer.snapshot.sessionTitle == nil, true, "title starts empty")
    expect(reducer.snapshot.modelName == nil, true, "model starts empty")
    reducer.consume(
        jsonLine: line(event: "PreInvocation", ts: now, cwd: "/tmp/my-repo", sessionTitle: "Wire AG", modelName: "gemini-3"),
        now: now
    )
    expect(reducer.snapshot.sessionTitle, "Wire AG", "title filled when present")
    expect(reducer.snapshot.modelName, "gemini-3", "model filled when present")
    reducer.consume(jsonLine: line(event: "PreInvocation", ts: now.addingTimeInterval(0.5)), now: now.addingTimeInterval(0.5))
    expect(reducer.snapshot.sessionTitle, "Wire AG", "missing title does not clear")
    expect(reducer.snapshot.modelName, "gemini-3", "missing model does not clear")

    reducer.consume(jsonLine: line(event: "PreToolUse", tool: "run_command", ts: now.addingTimeInterval(2)), now: now.addingTimeInterval(2))
    reducer.consume(jsonLine: line(event: "PostToolUse", ts: now.addingTimeInterval(3)), now: now.addingTimeInterval(3))
    reducer.consume(jsonLine: line(event: "PostInvocation", ts: now.addingTimeInterval(3.2)), now: now.addingTimeInterval(3.2))
    expect(reducer.snapshot.state, .working, "post invocation keeps working hold")
    reducer.applyWorkingVisibility(now: now.addingTimeInterval(3.7))
    expect(reducer.snapshot.state, .thinking, "working hold still fades at 0.65s")
    reducer.consume(jsonLine: line(event: "PostInvocation", ts: now.addingTimeInterval(4)), now: now.addingTimeInterval(4))
    expect(reducer.snapshot.state, .thinking, "post invocation after hold is thinking")

    reducer.consume(
        jsonLine: #"{"event":"Notification","notificationType":"permission_prompt","timestamp":"1970-01-01T00:16:45Z","sessionId":"t1"}"#,
        now: now.addingTimeInterval(5)
    )
    expect(reducer.snapshot.state, .thinking, "permission_prompt only arms, like Grok")
    reducer.applyWorkingVisibility(
        now: now.addingTimeInterval(5 + AntigravityHookStatusReducer.pendingPermissionAttentionDelay + 0.05)
    )
    expect(reducer.snapshot.state, .attention, "permission_prompt becomes attention after delay")
    expect(reducer.snapshot.action, "Awaiting permission", "permission_prompt action")
    expect(reducer.snapshot.active, true, "permission_prompt stays active")
    reducer.applyWorkingVisibility(now: now.addingTimeInterval(30))
    expect(reducer.snapshot.state, .attention, "permission hold does not fade")
}

func testAntigravityReducerUsesSessionPermissionLifecycleLikeGrok() {
    let now = Date(timeIntervalSince1970: 1_000)
    let delay = AntigravityHookStatusReducer.pendingPermissionAttentionDelay
    let toolAt = now.addingTimeInterval(2)

    var hang = AntigravityHookStatusReducer(threadId: "t1", now: now)
    hang.consume(jsonLine: line(event: "PreInvocation", ts: now), now: now)
    hang.consume(jsonLine: line(event: "PreToolUse", tool: "read_url_content", ts: toolAt), now: toolAt)
    expect(hang.snapshot.state, .working, "pre tool starts working")
    hang.applyWorkingVisibility(now: toolAt.addingTimeInterval(delay + 1))
    expect(hang.snapshot.state, .working, "bare PreToolUse must not become attention")

    hang.applyPermissionUpdate(
        AntigravityPermissionUpdate(at: toolAt, kind: .requested),
        now: toolAt
    )
    expect(hang.snapshot.state, .working, "requested only arms the delay")
    expect(hang.snapshot.action, "Executing", "tool action preserved while pending")
    hang.applyWorkingVisibility(now: toolAt.addingTimeInterval(delay - 0.05))
    expect(hang.snapshot.state, .working, "still working before permission delay")
    hang.applyWorkingVisibility(now: toolAt.addingTimeInterval(delay + 0.05))
    expect(hang.snapshot.state, .attention, "WAITING step is awaiting permission")
    expect(hang.snapshot.action, "Awaiting permission", "permission action")
    hang.applyWorkingVisibility(now: toolAt.addingTimeInterval(181))
    expect(hang.snapshot.state, .attention, "permission hold does not use the 180s fade")

    hang.applyPermissionUpdate(
        AntigravityPermissionUpdate(at: toolAt.addingTimeInterval(200), kind: .resolved(decision: "allow")),
        now: toolAt.addingTimeInterval(200)
    )
    expect(hang.snapshot.state, .working, "allow restores the in-flight tool")
    expect(hang.snapshot.action, "Executing", "resume the PreToolUse action")

    var deny = AntigravityHookStatusReducer(threadId: "t2", now: now)
    deny.consume(jsonLine: line(event: "PreInvocation", ts: now), now: now)
    deny.consume(jsonLine: line(event: "PreToolUse", tool: "read_url_content", ts: toolAt), now: toolAt)
    deny.applyPermissionUpdate(AntigravityPermissionUpdate(at: toolAt, kind: .requested), now: toolAt)
    deny.applyWorkingVisibility(now: toolAt.addingTimeInterval(delay + 0.05))
    deny.applyPermissionUpdate(
        AntigravityPermissionUpdate(at: toolAt.addingTimeInterval(3), kind: .resolved(decision: "deny")),
        now: toolAt.addingTimeInterval(3)
    )
    expect(deny.snapshot.state, .attention, "deny stays attention")
    expect(deny.snapshot.action, "Permission denied", "deny action")

    var request = AntigravityHookStatusReducer(threadId: "t3", now: now)
    request.consume(jsonLine: line(event: "PreInvocation", ts: now), now: now)
    request.consume(jsonLine: line(event: "PreToolUse", tool: "read_url_content", ts: toolAt), now: toolAt)
    request.consume(
        jsonLine: #"{"event":"PermissionRequest","timestamp":"1970-01-01T00:16:42Z","sessionId":"t3"}"#,
        now: toolAt.addingTimeInterval(0.05)
    )
    expect(request.snapshot.state, .working, "PermissionRequest hook only arms")
    request.applyWorkingVisibility(now: toolAt.addingTimeInterval(delay + 0.1))
    expect(request.snapshot.state, .attention, "PermissionRequest promotes after delay")
}

func testAntigravityReducerStuckPreToolUseRecoversAfterSafetyTimeout() {
    let now = Date(timeIntervalSince1970: 1_000)
    var reducer = AntigravityHookStatusReducer(threadId: "t1", now: now)
    reducer.consume(jsonLine: line(event: "PreInvocation", ts: now), now: now)
    reducer.consume(jsonLine: line(event: "PreToolUse", tool: "run_command", ts: now.addingTimeInterval(2)), now: now.addingTimeInterval(2))
    expect(reducer.snapshot.state, .working, "pre tool working")
    reducer.applyWorkingVisibility(now: now.addingTimeInterval(2 + 179))
    expect(reducer.snapshot.state, .working, "still working before 180s")
    reducer.applyWorkingVisibility(now: now.addingTimeInterval(2 + 181))
    expect(reducer.snapshot.state, .thinking, "stuck tool without WAITING fades after 180s")
}

func testAntigravityPermissionReaderEmitsRequestedAndResolved() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agent-halo-ag-perm-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let db = root.appendingPathComponent("s1.db")
    try writeAntigravityConversationSteps(at: db, rows: [(0, 3), (1, 9)])

    let reader = AntigravitySessionPermissionReader()
    let first = reader.poll(databaseURL: db, now: Date(timeIntervalSince1970: 10))
    expect(first.count, 1, "first attach of WAITING is requested")
    expect(first.first?.kind, .requested, "WAITING → requested")

    let again = reader.poll(databaseURL: db, now: Date(timeIntervalSince1970: 11))
    expect(again.isEmpty, true, "unchanged WAITING does not re-emit")

    try writeAntigravityConversationSteps(at: db, rows: [(0, 3), (1, 2)])
    let allowed = reader.poll(databaseURL: db, now: Date(timeIntervalSince1970: 12))
    expect(allowed.first?.kind, .resolved(decision: "allow"), "WAITING → RUNNING is allow")

    try writeAntigravityConversationSteps(at: db, rows: [(0, 3), (1, 9)])
    _ = reader.poll(databaseURL: db, now: Date(timeIntervalSince1970: 13))
    try writeAntigravityConversationSteps(at: db, rows: [(0, 3), (1, 6)])
    let denied = reader.poll(databaseURL: db, now: Date(timeIntervalSince1970: 14))
    expect(denied.first?.kind, .resolved(decision: "deny"), "WAITING → CANCELED is deny")
}

func testAntigravityHookStatusMonitorAppliesConversationPermission() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agent-halo-ag-perm-mon-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let conversations = root.appendingPathComponent("conversations", isDirectory: true)
    try FileManager.default.createDirectory(at: conversations, withIntermediateDirectories: true)
    let db = conversations.appendingPathComponent("s1.db")
    try writeAntigravityConversationSteps(at: db, rows: [(0, 3), (1, 9)])

    let statusFile = root.appendingPathComponent("antigravity-status.jsonl")
    let now = Date(timeIntervalSince1970: 1_000)
    let pre = line(event: "PreInvocation", ts: now, sessionId: "s1")
    let tool = line(event: "PreToolUse", tool: "read_url_content", ts: now.addingTimeInterval(2), sessionId: "s1")
    try Data("\(pre)\n\(tool)\n".utf8).write(to: statusFile)

    let monitor = AntigravityHookStatusMonitor(
        statusURL: statusFile,
        conversationRoots: [conversations]
    )
    _ = monitor.refresh(now: now.addingTimeInterval(2))
    expect(monitor.snapshots().first?.state, .working, "first poll arms WAITING without flashing")
    _ = monitor.refresh(
        now: now.addingTimeInterval(2 + AntigravityHookStatusReducer.pendingPermissionAttentionDelay + 0.05)
    )
    expect(monitor.snapshots().first?.state, .attention, "monitor promotes WAITING to attention")
    expect(monitor.snapshots().first?.action, "Awaiting permission", "monitor permission action")

    try writeAntigravityConversationSteps(at: db, rows: [(0, 3), (1, 2)])
    _ = monitor.refresh(now: now.addingTimeInterval(4))
    expect(monitor.snapshots().first?.state, .working, "RUNNING after WAITING restores working")
}

private func line(
    event: String,
    tool: String? = nil,
    ts: Date,
    cwd: String? = nil,
    sessionId: String = "t1",
    errorText: String? = nil,
    fatal: Bool? = nil,
    sessionTitle: String? = nil,
    modelName: String? = nil
) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    var obj: [String: Any] = [
        "event": event,
        "timestamp": formatter.string(from: ts),
        "sessionId": sessionId,
        "source": "antigravity-hook",
    ]
    if let cwd { obj["cwd"] = cwd }
    if let tool { obj["toolName"] = tool }
    if let errorText { obj["errorText"] = errorText }
    if let fatal { obj["fatal"] = fatal }
    if let sessionTitle { obj["sessionTitle"] = sessionTitle }
    if let modelName { obj["modelName"] = modelName }
    let data = try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    return String(data: data, encoding: .utf8)!
}

private func writeAntigravityConversationSteps(at url: URL, rows: [(Int, Int)]) throws {
    if FileManager.default.fileExists(atPath: url.path) {
        try FileManager.default.removeItem(at: url)
        let wal = url.path + "-wal"
        let shm = url.path + "-shm"
        if FileManager.default.fileExists(atPath: wal) {
            try FileManager.default.removeItem(at: URL(fileURLWithPath: wal))
        }
        if FileManager.default.fileExists(atPath: shm) {
            try FileManager.default.removeItem(at: URL(fileURLWithPath: shm))
        }
    }
    var sql = "CREATE TABLE steps (idx INTEGER PRIMARY KEY, step_type INTEGER DEFAULT 0, status INTEGER DEFAULT 0);\n"
    for (idx, status) in rows {
        sql += "INSERT INTO steps(idx, status) VALUES (\(idx), \(status));\n"
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    process.arguments = [url.path]
    let stdin = Pipe()
    let stderr = Pipe()
    process.standardInput = stdin
    process.standardError = stderr
    try process.run()
    try stdin.fileHandleForWriting.write(contentsOf: Data(sql.utf8))
    try stdin.fileHandleForWriting.close()
    process.waitUntilExit()
    if process.terminationStatus != 0 {
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        throw NSError(domain: "ag-perm-fixture", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: err])
    }
}

func testAntigravityHookStatusMonitorMapsLifecycleAndSkipsBadLines() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agent-halo-ag-hook-monitor-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: root)
    }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let statusFile = root.appendingPathComponent("antigravity-status.jsonl")
    let now = Date(timeIntervalSince1970: 1_000)
    let pre = line(event: "PreInvocation", ts: now, cwd: "/tmp/my-repo", sessionId: "s1")
    let stop = line(event: "Stop", ts: now.addingTimeInterval(5), sessionId: "s1")
    try Data("\(pre)\nnot-json\n\(stop)\n".utf8).write(to: statusFile)

    let monitor = AntigravityHookStatusMonitor(statusURL: statusFile)
    _ = monitor.refresh(now: now.addingTimeInterval(5))
    let snapshots = monitor.snapshots()
    expect(snapshots.count, 1, "one session after pre+stop")
    expect(snapshots[0].agent, .antigravity, "agent stamp")
    expect(snapshots[0].state, .done, "final state is done")
    expect(snapshots[0].threadId, "s1", "session id")
}

func testGrokHookReducerLifecycle() {
    var r = GrokHookStatusReducer(threadId: "s1", now: Date(timeIntervalSince1970: 0))
    r.consume(jsonLine: #"{"timestamp":"2026-07-25T00:00:01Z","event":"UserPromptSubmit","sessionId":"s1","cwd":"/p/AgentHalo","permissionMode":"auto","source":"grok-hook"}"#, now: Date(timeIntervalSince1970: 1))
    expect(r.snapshot.state, .thinking, "prompt → thinking")
    expect(r.snapshot.agent, .grok, "agent kind")
    expect(r.snapshot.projectName, "AgentHalo", "cwd basename")

    r.consume(jsonLine: #"{"timestamp":"2026-07-25T00:00:02Z","event":"PreToolUse","sessionId":"s1","cwd":"/p/AgentHalo","toolName":"run_terminal_command","permissionMode":"auto","source":"grok-hook"}"#, now: Date(timeIntervalSince1970: 2))
    expect(r.snapshot.state, .working, "tool → working")
    expect(r.snapshot.action, "Running command", "run_terminal_command → shell friendly action")

    // Auto mode: permission_prompt is suppressed (shell still has multi-second wait_ms).
    r.consume(jsonLine: #"{"timestamp":"2026-07-25T00:00:03Z","event":"Notification","sessionId":"s1","notificationType":"permission_prompt","permissionMode":"auto","source":"grok-hook"}"#, now: Date(timeIntervalSince1970: 3))
    expect(r.snapshot.state, .working, "permission_prompt after PreToolUse must not become attention")
    expect(r.snapshot.action, "Running command", "tool action preserved under auto permission noise")
    r.applyWorkingVisibility(
        now: Date(timeIntervalSince1970: 3).addingTimeInterval(GrokHookStatusReducer.pendingPermissionAttentionDelay + 0.5)
    )
    expect(r.snapshot.state, .working, "auto mode never promotes permission noise to attention")

    r.consume(jsonLine: #"{"timestamp":"2026-07-25T00:00:05Z","event":"Stop","sessionId":"s1","source":"grok-hook"}"#, now: Date(timeIntervalSince1970: 5))
    expect(r.snapshot.state, .done, "stop → done")
}

/// Strategy A (default mode): permission_prompt arms delay, then attention.
func testGrokHookReducerPermissionPromptWhileThinkingIsAttention() {
    var r = GrokHookStatusReducer(threadId: "s1", now: Date(timeIntervalSince1970: 0))
    r.consume(
        jsonLine: #"{"timestamp":"2026-07-25T00:00:01Z","event":"UserPromptSubmit","sessionId":"s1","cwd":"/p","permissionMode":"default","source":"grok-hook"}"#,
        now: Date(timeIntervalSince1970: 1)
    )
    r.consume(
        jsonLine: #"{"timestamp":"2026-07-25T00:00:02Z","event":"Notification","sessionId":"s1","notificationType":"permission_prompt","permissionMode":"default","source":"grok-hook"}"#,
        now: Date(timeIntervalSince1970: 2)
    )
    expect(r.snapshot.state, .thinking, "hook arms delay — not immediate attention")
    r.applyWorkingVisibility(now: Date(timeIntervalSince1970: 2.1))
    expect(r.snapshot.state, .thinking, "within delay still thinking")
    r.applyWorkingVisibility(
        now: Date(timeIntervalSince1970: 2).addingTimeInterval(GrokHookStatusReducer.pendingPermissionAttentionDelay + 0.05)
    )
    expect(r.snapshot.state, .attention, "after delay → attention (default mode)")
    expect(r.snapshot.action, "Awaiting permission", "attention action")
    r.applyWorkingVisibility(now: Date(timeIntervalSince1970: 10))
    expect(r.snapshot.state, .attention, "genuine permission hold does not auto-fade")
}

/// Auto mode: multi-second shell permission wait must never flash purple.
func testGrokHookReducerAutoModeShellPermissionNeverAttention() {
    var r = GrokHookStatusReducer(threadId: "s1", now: Date(timeIntervalSince1970: 0))
    r.consume(
        jsonLine: #"{"timestamp":"2026-07-25T00:00:01Z","event":"UserPromptSubmit","sessionId":"s1","cwd":"/p","permissionMode":"auto","source":"grok-hook"}"#,
        now: Date(timeIntervalSince1970: 1)
    )
    r.consume(
        jsonLine: #"{"timestamp":"2026-07-25T00:00:02Z","event":"PreToolUse","sessionId":"s1","cwd":"/p","toolName":"run_terminal_command","permissionMode":"auto","source":"grok-hook"}"#,
        now: Date(timeIntervalSince1970: 2)
    )
    // Measured: Auto shell wait_ms often 1.8–2.9s — events still fire.
    r.applyPermissionRequested(at: Date(timeIntervalSince1970: 2.01))
    r.consume(
        jsonLine: #"{"timestamp":"2026-07-25T00:00:02.020Z","event":"Notification","sessionId":"s1","notificationType":"permission_prompt","permissionMode":"auto","source":"grok-hook"}"#,
        now: Date(timeIntervalSince1970: 2.02)
    )
    r.applyWorkingVisibility(now: Date(timeIntervalSince1970: 4.5))
    expect(r.snapshot.state, .working, "auto mode: 2.5s shell wait stays working (no purple)")
    expect(r.snapshot.action, "Running command", "tool action preserved under auto shell wait")

    r.applyPermissionResolved(decision: "allow", waitMs: 2630, at: Date(timeIntervalSince1970: 4.64))
    r.applyWorkingVisibility(now: Date(timeIntervalSince1970: 5))
    expect(r.snapshot.state, .working, "auto shell resolve keeps working")
}

/// Strategy C: instant auto resolve (wait_ms=0) never paints NEEDS YOU.
func testGrokHookReducerAutoPermissionResolveDoesNotAttention() {
    var r = GrokHookStatusReducer(threadId: "s1", now: Date(timeIntervalSince1970: 0))
    r.consume(
        jsonLine: #"{"timestamp":"2026-07-25T00:00:01Z","event":"UserPromptSubmit","sessionId":"s1","cwd":"/p","source":"grok-hook"}"#,
        now: Date(timeIntervalSince1970: 1)
    )
    r.applyPermissionRequested(at: Date(timeIntervalSince1970: 2))
    r.applyPermissionResolved(decision: "allow", waitMs: 0, at: Date(timeIntervalSince1970: 2.01))
    r.applyWorkingVisibility(now: Date(timeIntervalSince1970: 3))
    expect(r.snapshot.state, .thinking, "auto resolve stays thinking, not attention")
    expect(r.snapshot.state != .attention, "auto wait_ms=0 never NEEDS YOU")
}

/// Strategy C: pending permission without resolve becomes attention after delay.
func testGrokHookReducerPendingPermissionBecomesAttentionAfterDelay() {
    var r = GrokHookStatusReducer(threadId: "s1", now: Date(timeIntervalSince1970: 0))
    r.consume(
        jsonLine: #"{"timestamp":"2026-07-25T00:00:01Z","event":"UserPromptSubmit","sessionId":"s1","cwd":"/p","permissionMode":"default","source":"grok-hook"}"#,
        now: Date(timeIntervalSince1970: 1)
    )
    let requestedAt = Date(timeIntervalSince1970: 2)
    r.applyPermissionRequested(at: requestedAt)
    r.applyWorkingVisibility(now: requestedAt.addingTimeInterval(0.1))
    expect(r.snapshot.state, .thinking, "before delay still thinking")

    r.applyWorkingVisibility(
        now: requestedAt.addingTimeInterval(GrokHookStatusReducer.pendingPermissionAttentionDelay + 0.05)
    )
    expect(r.snapshot.state, .attention, "after delay → attention (human wait)")
    expect(r.snapshot.action, "Awaiting permission", "human wait action")
}

/// Strategy C: human wait without prior PreToolUse falls back to thinking on allow.
func testGrokHookReducerHumanPermissionResolveClearsAttention() {
    var r = GrokHookStatusReducer(threadId: "s1", now: Date(timeIntervalSince1970: 0))
    r.consume(
        jsonLine: #"{"timestamp":"2026-07-25T00:00:01Z","event":"UserPromptSubmit","sessionId":"s1","cwd":"/p","permissionMode":"default","source":"grok-hook"}"#,
        now: Date(timeIntervalSince1970: 1)
    )
    r.applyPermissionRequested(at: Date(timeIntervalSince1970: 2))
    r.applyWorkingVisibility(now: Date(timeIntervalSince1970: 3))
    expect(r.snapshot.state, .attention, "precondition: attention after delay")

    r.applyPermissionResolved(decision: "allow", waitMs: 5000, at: Date(timeIntervalSince1970: 7))
    expect(r.snapshot.state, .thinking, "human allow without PreToolUse → thinking")
    expect(r.snapshot.action, "Thinking", "resume thinking when no tool was staged")
}

/// Strategy A + C: working + permission events auto resolve stays working.
func testGrokHookReducerAutoNoiseDuringToolExecutionStaysWorking() {
    var r = GrokHookStatusReducer(threadId: "s1", now: Date(timeIntervalSince1970: 0))
    r.consume(
        jsonLine: #"{"timestamp":"2026-07-25T00:00:01Z","event":"UserPromptSubmit","sessionId":"s1","cwd":"/p","permissionMode":"auto","source":"grok-hook"}"#,
        now: Date(timeIntervalSince1970: 1)
    )
    r.consume(
        jsonLine: #"{"timestamp":"2026-07-25T00:00:03Z","event":"PreToolUse","sessionId":"s1","cwd":"/p","toolName":"run_terminal_command","permissionMode":"auto","source":"grok-hook"}"#,
        now: Date(timeIntervalSince1970: 3)
    )
    r.applyPermissionRequested(at: Date(timeIntervalSince1970: 3.01))
    r.applyPermissionResolved(decision: "allow", waitMs: 12, at: Date(timeIntervalSince1970: 3.02))
    r.consume(
        jsonLine: #"{"timestamp":"2026-07-25T00:00:03.050Z","event":"Notification","sessionId":"s1","notificationType":"permission_prompt","permissionMode":"auto","source":"grok-hook"}"#,
        now: Date(timeIntervalSince1970: 3.05)
    )
    r.applyWorkingVisibility(now: Date(timeIntervalSince1970: 4))
    expect(r.snapshot.state, .working, "auto noise during tool stays working")
    expect(r.snapshot.action, "Running command", "tool action preserved")
}

/// Grok fires PreToolUse *before* the human permission UI. After the delay with
/// no resolve, state must become attention (purple NEEDS YOU) even though we
/// were already `.working`.
func testGrokHookReducerHumanWaitAfterPreToolUseBecomesAttention() {
    var r = GrokHookStatusReducer(threadId: "s1", now: Date(timeIntervalSince1970: 0))
    r.consume(
        jsonLine: #"{"timestamp":"2026-07-25T00:00:01Z","event":"UserPromptSubmit","sessionId":"s1","cwd":"/p","permissionMode":"default","source":"grok-hook"}"#,
        now: Date(timeIntervalSince1970: 1)
    )
    r.consume(
        jsonLine: #"{"timestamp":"2026-07-25T00:00:02Z","event":"PreToolUse","sessionId":"s1","cwd":"/p","toolName":"run_terminal_command","permissionMode":"default","source":"grok-hook"}"#,
        now: Date(timeIntervalSince1970: 2)
    )
    expect(r.snapshot.state, .working, "precondition: PreToolUse → working")

    let requestedAt = Date(timeIntervalSince1970: 2.015)
    r.applyPermissionRequested(at: requestedAt)
    r.consume(
        jsonLine: #"{"timestamp":"2026-07-25T00:00:02.020Z","event":"Notification","sessionId":"s1","notificationType":"permission_prompt","permissionMode":"default","source":"grok-hook"}"#,
        now: Date(timeIntervalSince1970: 2.02)
    )
    expect(r.snapshot.state, .working, "still working before delay (no purple flash)")

    r.applyWorkingVisibility(now: requestedAt.addingTimeInterval(0.1))
    expect(r.snapshot.state, .working, "within delay still working")

    r.applyWorkingVisibility(
        now: requestedAt.addingTimeInterval(GrokHookStatusReducer.pendingPermissionAttentionDelay + 0.05)
    )
    expect(r.snapshot.state, .attention, "human wait after PreToolUse → attention")
    expect(r.snapshot.action, "Awaiting permission", "human wait action")
    expect(r.snapshot.active, true, "human wait keeps turn active")

    // Multi-second human allow must restore working — Grok does not re-emit PreToolUse
    // before PostToolUse, so tool execution UI would otherwise be lost.
    r.applyPermissionResolved(decision: "allow", waitMs: 9678, at: Date(timeIntervalSince1970: 12))
    expect(r.snapshot.state, .working, "human allow restores working (tool still running)")
    expect(r.snapshot.action, "Running command", "human allow restores tool action")
    expect(r.snapshot.active, true, "human allow keeps turn active during tool run")

    // PostToolUse still advances normally after the restored working hold.
    r.consume(
        jsonLine: #"{"timestamp":"2026-07-25T00:00:15Z","event":"PostToolUse","sessionId":"s1","cwd":"/p","toolName":"run_terminal_command","permissionMode":"default","source":"grok-hook"}"#,
        now: Date(timeIntervalSince1970: 15)
    )
    expect(r.snapshot.state, .working, "PostToolUse after allow → reviewing")
    expect(r.snapshot.action, "Reviewing result", "PostToolUse action after restored working")
}

func testGrokHookReducerMapsEscCancelToInterrupted() {
    var r = GrokHookStatusReducer(threadId: "s1", now: Date(timeIntervalSince1970: 0))
    r.consume(
        jsonLine: #"{"timestamp":"2026-07-25T00:00:01Z","event":"UserPromptSubmit","sessionId":"s1","cwd":"/p/AgentHalo","source":"grok-hook"}"#,
        now: Date(timeIntervalSince1970: 1)
    )
    r.consume(
        jsonLine: #"{"timestamp":"2026-07-25T00:00:02Z","event":"PreToolUse","sessionId":"s1","cwd":"/p/AgentHalo","toolName":"read_file","source":"grok-hook"}"#,
        now: Date(timeIntervalSince1970: 2)
    )
    expect(r.snapshot.state, .working, "precondition: working")
    expect(r.snapshot.active, true, "precondition: active")

    // Esc cancel does not emit Stop/StopFailure — only session events do.
    r.applyTurnCancelled(at: Date(timeIntervalSince1970: 3))
    expect(r.snapshot.state, .error, "esc cancel → error ring")
    expect(r.snapshot.action, "Interrupted", "esc cancel action matches Codex interrupt")
    expect(r.snapshot.active, false, "esc cancel clears active turn")
    expect(r.snapshot.completedAt == nil, "interrupt is not a done completion")

    // Idle Ready should not be overwritten by a late cancel.
    var idle = GrokHookStatusReducer(threadId: "s2", now: Date(timeIntervalSince1970: 0))
    idle.applyTurnCancelled(at: Date(timeIntervalSince1970: 1))
    expect(idle.snapshot.state, .idle, "cancel on idle Ready is a no-op")
}

func testGrokSessionTurnEventsReaderDetectsCancelledTurnEnded() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agent-halo-grok-turn-events-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let eventsURL = root.appendingPathComponent("events.jsonl")

    let seed = """
    {"ts":"2026-07-30T08:00:00.000Z","type":"turn_started"}
    {"ts":"2026-07-30T08:00:01.000Z","type":"phase_changed","phase":"thinking"}

    """
    try Data(seed.utf8).write(to: eventsURL)

    let reader = GrokSessionTurnEventsReader()
    expect(reader.poll(eventsURL: eventsURL).isEmpty, "no turn_ended yet")
    expect(reader.turnState(eventsURL: eventsURL).isOpen, "seed turn_started records an open turn")

    // Append without rewriting: mirrors Grok's live jsonl growth.
    let cancelLine = #"{"ts":"2026-07-30T08:00:05.000Z","type":"turn_ended","outcome":"cancelled","cancellation_category":"mid_turn_abort","cancellation_context":{"trigger":"esc"}}"# + "\n"
    let handle = try FileHandle(forWritingTo: eventsURL)
    defer { try? handle.close() }
    _ = try handle.seekToEnd()
    try handle.write(contentsOf: Data(cancelLine.utf8))
    try handle.synchronize()

    let ended = reader.poll(eventsURL: eventsURL)
    expect(ended.turnEnd != nil, "cancelled turn_ended is not nil")
    expect(ended.turnEnd?.outcome, Optional.some(GrokSessionTurnEndOutcome.cancelled), "poll surfaces cancelled turn_ended")
    expect(!reader.turnState(eventsURL: eventsURL).isOpen, "turn_ended closes durable turn state")

    expect(reader.poll(eventsURL: eventsURL).isEmpty, "second poll with no growth is empty")
}

func testGrokSessionTurnStateEqualTimestampsStayOpen() {
    let at = Date(timeIntervalSince1970: 1_778_000_000)
    let same = GrokSessionTurnState(lastStartedAt: at, lastEndedAt: at)
    expect(same.isOpen, "equal start/end timestamps stay open like steer supersede")
    let closed = GrokSessionTurnState(
        lastStartedAt: at,
        lastEndedAt: at.addingTimeInterval(0.001)
    )
    expect(!closed.isOpen, "a later end still closes the turn")
}

func testGrokSessionTurnEventsReaderFirstAttachFindsBuriedTurnBoundaries() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(
            "agent-halo-grok-turn-tail-\(UUID().uuidString)",
            isDirectory: true
        )
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let paddingLine = Data(
        #"{"ts":"2026-07-30T08:00:03.000Z","type":"phase_changed","phase":"thinking"}"#.utf8
            + Data([0x0A])
    )
    let paddingBytes = 1024 * 1024 + 8192

    let openURL = root.appendingPathComponent("open-events.jsonl")
    try writeGrokEventsWithBuriedBoundary(
        to: openURL,
        prefix: """
        {"ts":"2026-07-30T08:00:00.000Z","type":"turn_started"}
        {"ts":"2026-07-30T08:00:01.000Z","type":"turn_ended","outcome":"completed"}
        {"ts":"2026-07-30T08:00:02.000Z","type":"turn_started"}

        """,
        paddingLine: paddingLine,
        paddingBytes: paddingBytes
    )
    let openReader = GrokSessionTurnEventsReader()
    _ = openReader.poll(eventsURL: openURL)
    let openState = openReader.turnState(eventsURL: openURL)
    expect(openState.isOpen, "first attach must find a turn_started buried before a 1MB phase tail")
    expect(
        openState.lastStartedAt != nil,
        "buried open turn records lastStartedAt"
    )

    let closedURL = root.appendingPathComponent("closed-events.jsonl")
    try writeGrokEventsWithBuriedBoundary(
        to: closedURL,
        prefix: """
        {"ts":"2026-07-30T08:00:00.000Z","type":"turn_started"}
        {"ts":"2026-07-30T08:00:01.000Z","type":"turn_ended","outcome":"completed"}

        """,
        paddingLine: paddingLine,
        paddingBytes: paddingBytes
    )
    let closedReader = GrokSessionTurnEventsReader()
    _ = closedReader.poll(eventsURL: closedURL)
    let closedState = closedReader.turnState(eventsURL: closedURL)
    expect(!closedState.isOpen, "first attach must see a completed turn buried before a 1MB phase tail")
    expect(
        closedState.lastEndedAt != nil,
        "buried completed turn records lastEndedAt for terminal-wins"
    )

    let laterEnd = #"{"ts":"2026-07-30T08:00:10.000Z","type":"turn_ended","outcome":"completed"}"# + "\n"
    let handle = try FileHandle(forWritingTo: openURL)
    defer { try? handle.close() }
    _ = try handle.seekToEnd()
    try handle.write(contentsOf: Data(laterEnd.utf8))
    try handle.synchronize()
    let appended = openReader.poll(eventsURL: openURL)
    expect(appended.turnEnd?.outcome, Optional.some(GrokSessionTurnEndOutcome.completed), "incremental poll after first attach still sees a new end")
    expect(!openReader.turnState(eventsURL: openURL).isOpen, "appended end closes the previously buried open turn")
}

private func writeGrokEventsWithBuriedBoundary(
    to url: URL,
    prefix: String,
    paddingLine: Data,
    paddingBytes: Int
) throws {
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.write(contentsOf: Data(prefix.utf8))
    var written = 0
    while written < paddingBytes {
        try handle.write(contentsOf: paddingLine)
        written += paddingLine.count
    }
}

func testGrokSessionTurnEventsReaderParsesPermissionLifecycle() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agent-halo-grok-perm-events-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let eventsURL = root.appendingPathComponent("events.jsonl")

    let seed = """
    {"ts":"2026-07-30T08:00:00.000Z","type":"permission_requested","tool_name":"run_terminal_command"}
    {"ts":"2026-07-30T08:00:00.012Z","type":"permission_resolved","tool_name":"run_terminal_command","decision":"allow","wait_ms":12}

    """
    try Data(seed.utf8).write(to: eventsURL)

    let reader = GrokSessionTurnEventsReader()
    let delta = reader.poll(eventsURL: eventsURL)
    expect(delta.permissionUpdates.count, 2, "requested + resolved")
    if case .requested(let tool) = delta.permissionUpdates[0].kind {
        expect(tool, "run_terminal_command", "requested tool")
    } else {
        expect(false, "first update is requested")
    }
    if case .resolved(let tool, let decision, let waitMs) = delta.permissionUpdates[1].kind {
        expect(tool, "run_terminal_command", "resolved tool")
        expect(decision, "allow", "resolved decision")
        expect(waitMs, 12, "resolved wait_ms")
    } else {
        expect(false, "second update is resolved")
    }
}

func testGrokHookStatusMonitorMapsSessionEscCancelToError() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agent-halo-grok-monitor-cancel-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let logs = root.appendingPathComponent("logs", isDirectory: true)
    let sessions = root.appendingPathComponent("sessions", isDirectory: true)
    let cwd = "/tmp/AgentHaloCancelTest"
    let sessionId = "sess-esc-1"
    let encoded = GrokSessionContextReader.encodeWorkspaceDirectory(cwd)
    let sessionDir = sessions
        .appendingPathComponent(encoded, isDirectory: true)
        .appendingPathComponent(sessionId, isDirectory: true)
    try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

    let statusURL = logs.appendingPathComponent("grok-status.jsonl")
    let eventsURL = sessionDir.appendingPathComponent("events.jsonl")

    // Space PreToolUse past the 0.7s thinking hold so the ring is clearly .working.
    let hookLines = """
    {"timestamp":"2026-07-30T08:00:01.000Z","event":"UserPromptSubmit","sessionId":"\(sessionId)","cwd":"\(cwd)","source":"grok-hook"}
    {"timestamp":"2026-07-30T08:00:03.000Z","event":"PreToolUse","sessionId":"\(sessionId)","cwd":"\(cwd)","toolName":"read_file","source":"grok-hook"}

    """
    try Data(hookLines.utf8).write(to: statusURL)
    try Data(#"{"ts":"2026-07-30T08:00:01.500Z","type":"turn_started"}"#.utf8 + Data([0x0A]))
        .write(to: eventsURL)

    let monitor = GrokHookStatusMonitor(statusURL: statusURL, sessionsRoot: sessions)
    let now = ISO8601DateFormatter().date(from: "2026-07-30T08:00:03Z") ?? Date()
    expect(monitor.refresh(now: now), true, "hooks load")
    let working = monitor.snapshots().first
    expect(working?.state, .working, "precondition: working from PreToolUse")
    expect(working?.active == true, "precondition: active")

    // Esc cancel: no Stop hook, only events.jsonl turn_ended cancelled.
    let cancel = #"{"ts":"2026-07-30T08:00:04.000Z","type":"turn_ended","outcome":"cancelled","cancellation_category":"mid_turn_abort","cancellation_context":{"trigger":"esc"}}"# + "\n"
    let handle = try FileHandle(forWritingTo: eventsURL)
    defer { try? handle.close() }
    _ = try handle.seekToEnd()
    try handle.write(contentsOf: Data(cancel.utf8))
    try handle.synchronize()

    let cancelNow = ISO8601DateFormatter().date(from: "2026-07-30T08:00:04Z") ?? Date()
    expect(monitor.refresh(now: cancelNow), true, "cancel via events should change state")
    let interrupted = monitor.snapshots().first
    expect(interrupted?.state, .error, "esc cancel → error")
    expect(interrupted?.action, "Interrupted", "esc cancel action")
    expect(interrupted?.active == false, "esc cancel not active")
}

func testGrokHookReducerSteerCancelDoesNotPaintError() {
    var r = GrokHookStatusReducer(threadId: "s1", now: Date(timeIntervalSince1970: 0))
    r.consume(
        jsonLine: #"{"timestamp":"2026-07-25T00:00:01Z","event":"UserPromptSubmit","sessionId":"s1","cwd":"/p","source":"grok-hook"}"#,
        now: Date(timeIntervalSince1970: 1)
    )
    r.consume(
        jsonLine: #"{"timestamp":"2026-07-25T00:00:02Z","event":"PreToolUse","sessionId":"s1","cwd":"/p","toolName":"read_file","source":"grok-hook"}"#,
        now: Date(timeIntervalSince1970: 2)
    )
    expect(r.snapshot.state, .working, "precondition: working")

    // Sent now / steer soft-ends without the red fault ring.
    r.applySteerCancel(at: Date(timeIntervalSince1970: 3))
    expect(r.snapshot.state, .idle, "steer cancel → idle not error")
    expect(r.snapshot.action, "Ready", "steer cancel action is Ready")
    expect(r.snapshot.active, false, "steer cancel clears active")
}

func testGrokSessionTurnEventsReaderSupersedesCancelWithSteerStart() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agent-halo-grok-steer-events-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let eventsURL = root.appendingPathComponent("events.jsonl")

    // Same-chunk: cancel then turn_started with cancel_then_send (real steer path).
    let chunk = """
    {"ts":"2026-07-30T08:00:00.000Z","type":"turn_started"}
    {"ts":"2026-07-30T08:00:04.000Z","type":"turn_ended","outcome":"cancelled","cancellation_category":"mid_turn_abort","cancellation_context":{"trigger":"esc"}}
    {"ts":"2026-07-30T08:00:04.010Z","type":"turn_started","redirect_kind":"cancel_then_send"}

    """
    try Data(chunk.utf8).write(to: eventsURL)

    let reader = GrokSessionTurnEventsReader()
    let delta = reader.poll(eventsURL: eventsURL)
    expect(delta.turnEnd == nil, "steer start supersedes cancelled turn_ended in same chunk")
    expect(delta.turnStart != nil, "turn_started is surfaced")
    expect(delta.turnStart?.redirectKind, "cancel_then_send", "redirect_kind parsed")
    expect(delta.turnStart?.isSteerRedirect == true, "cancel_then_send is steer redirect")
}

func testGrokSessionTurnEventsReaderParsesSendNowTrigger() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agent-halo-grok-send-now-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let eventsURL = root.appendingPathComponent("events.jsonl")

    let line = #"{"ts":"2026-07-30T08:00:04.000Z","type":"turn_ended","outcome":"cancelled","cancellation_category":"mid_turn_abort","cancellation_context":{"trigger":"send_now"}}"# + "\n"
    try Data(line.utf8).write(to: eventsURL)

    let reader = GrokSessionTurnEventsReader()
    let delta = reader.poll(eventsURL: eventsURL)
    expect(delta.turnEnd?.outcome, Optional.some(GrokSessionTurnEndOutcome.cancelled), "send_now is cancelled outcome")
    expect(delta.turnEnd?.cancellationTrigger, "send_now", "trigger parsed")
    expect(delta.turnEnd?.isSteerLikeCancel == true, "send_now is steer-like")
}

/// Sent now: UserPromptSubmit arrives ~4ms after turn_ended cancelled. The cancel
/// must not overwrite thinking with the red Interrupted ring.
func testGrokHookStatusMonitorSendNowDoesNotPaintError() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agent-halo-grok-monitor-send-now-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let logs = root.appendingPathComponent("logs", isDirectory: true)
    let sessions = root.appendingPathComponent("sessions", isDirectory: true)
    let cwd = "/tmp/AgentHaloSendNowTest"
    let sessionId = "sess-send-now-1"
    let encoded = GrokSessionContextReader.encodeWorkspaceDirectory(cwd)
    let sessionDir = sessions
        .appendingPathComponent(encoded, isDirectory: true)
        .appendingPathComponent(sessionId, isDirectory: true)
    try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

    let statusURL = logs.appendingPathComponent("grok-status.jsonl")
    let eventsURL = sessionDir.appendingPathComponent("events.jsonl")

    let hookLines = """
    {"timestamp":"2026-07-30T08:00:01.000Z","event":"UserPromptSubmit","sessionId":"\(sessionId)","cwd":"\(cwd)","source":"grok-hook"}
    {"timestamp":"2026-07-30T08:00:03.000Z","event":"PreToolUse","sessionId":"\(sessionId)","cwd":"\(cwd)","toolName":"read_file","source":"grok-hook"}

    """
    try Data(hookLines.utf8).write(to: statusURL)
    try Data(#"{"ts":"2026-07-30T08:00:01.500Z","type":"turn_started"}"#.utf8 + Data([0x0A]))
        .write(to: eventsURL)

    let monitor = GrokHookStatusMonitor(statusURL: statusURL, sessionsRoot: sessions)
    let now = ISO8601DateFormatter().date(from: "2026-07-30T08:00:03Z") ?? Date()
    expect(monitor.refresh(now: now), true, "hooks load")
    expect(monitor.snapshots().first?.state, .working, "precondition: working")

    // Same refresh: new UserPromptSubmit + send_now cancel (real Sent now race).
    let newPrompt = #"{"timestamp":"2026-07-30T08:00:04.004Z","event":"UserPromptSubmit","sessionId":"\#(sessionId)","cwd":"\#(cwd)","source":"grok-hook"}"# + "\n"
    let handleHooks = try FileHandle(forWritingTo: statusURL)
    defer { try? handleHooks.close() }
    _ = try handleHooks.seekToEnd()
    try handleHooks.write(contentsOf: Data(newPrompt.utf8))
    try handleHooks.synchronize()

    let cancel = #"{"ts":"2026-07-30T08:00:04.000Z","type":"turn_ended","outcome":"cancelled","cancellation_category":"mid_turn_abort","cancellation_context":{"trigger":"send_now"}}"# + "\n"
    let start = #"{"ts":"2026-07-30T08:00:04.004Z","type":"turn_started","redirect_kind":"queued_after_cancel"}"# + "\n"
    let handleEvents = try FileHandle(forWritingTo: eventsURL)
    defer { try? handleEvents.close() }
    _ = try handleEvents.seekToEnd()
    try handleEvents.write(contentsOf: Data((cancel + start).utf8))
    try handleEvents.synchronize()

    let steerNow = ISO8601DateFormatter().date(from: "2026-07-30T08:00:04.010Z")
        ?? Date(timeIntervalSince1970: 1_753_862_404.01)
    expect(monitor.refresh(now: steerNow), true, "send_now refresh changes state")
    let after = monitor.snapshots().first
    expect(after?.state, .thinking, "send_now keeps thinking from UserPromptSubmit")
    expect(after?.state != .error, "send_now must not paint red Interrupted")
    expect(after?.active == true, "send_now new turn is active")
    expect(after?.action, "Thinking", "send_now action is Thinking")
}

/// Monitor integration: Auto-mode permission lines in events.jsonl + post-tool
/// permission_prompt hook must not paint NEEDS YOU while a tool is running.
func testGrokHookStatusMonitorIgnoresAutoPermissionDuringTool() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agent-halo-grok-monitor-auto-perm-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let logs = root.appendingPathComponent("logs", isDirectory: true)
    let sessions = root.appendingPathComponent("sessions", isDirectory: true)
    let cwd = "/tmp/AgentHaloAutoPermTest"
    let sessionId = "sess-auto-perm-1"
    let encoded = GrokSessionContextReader.encodeWorkspaceDirectory(cwd)
    let sessionDir = sessions
        .appendingPathComponent(encoded, isDirectory: true)
        .appendingPathComponent(sessionId, isDirectory: true)
    try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

    let statusURL = logs.appendingPathComponent("grok-status.jsonl")
    let eventsURL = sessionDir.appendingPathComponent("events.jsonl")

    let hookLines = """
    {"timestamp":"2026-07-30T08:00:01.000Z","event":"UserPromptSubmit","sessionId":"\(sessionId)","cwd":"\(cwd)","permissionMode":"auto","source":"grok-hook"}
    {"timestamp":"2026-07-30T08:00:03.000Z","event":"PreToolUse","sessionId":"\(sessionId)","cwd":"\(cwd)","toolName":"run_terminal_command","permissionMode":"auto","source":"grok-hook"}
    {"timestamp":"2026-07-30T08:00:03.020Z","event":"Notification","sessionId":"\(sessionId)","cwd":"\(cwd)","notificationType":"permission_prompt","permissionMode":"auto","source":"grok-hook"}

    """
    try Data(hookLines.utf8).write(to: statusURL)

    // Auto shell often resolves with wait_ms in the 1.5–3s band — still not human.
    let eventsSeed = """
    {"ts":"2026-07-30T08:00:03.000Z","type":"permission_requested","tool_name":"run_terminal_command"}
    {"ts":"2026-07-30T08:00:05.630Z","type":"permission_resolved","tool_name":"run_terminal_command","decision":"allow","wait_ms":2630}

    """
    try Data(eventsSeed.utf8).write(to: eventsURL)

    let monitor = GrokHookStatusMonitor(statusURL: statusURL, sessionsRoot: sessions)
    let midWait = ISO8601DateFormatter().date(from: "2026-07-30T08:00:04Z") ?? Date()
    expect(monitor.refresh(now: midWait), true, "hooks+events load mid auto wait")
    let mid = monitor.snapshots().first
    expect(mid?.state, .working, "auto shell mid-wait stays working (no purple)")
    expect(mid?.action, "Running command", "tool action kept mid-wait")
    expect(mid?.state != .attention, "must not be NEEDS YOU mid auto wait")

    // Append is not needed — seed already has resolved; re-refresh after resolve time.
    let afterResolve = ISO8601DateFormatter().date(from: "2026-07-30T08:00:06Z") ?? Date()
    _ = monitor.refresh(now: afterResolve)
    let snap = monitor.snapshots().first
    expect(snap?.state, .working, "auto permission during tool stays working")
    expect(snap?.action, "Running command", "tool action kept")
    expect(snap?.state != .attention, "must not be NEEDS YOU")
}

// MARK: - Durable ClaudeCodeStatusHook isolation (Grok vs Claude status files)

/// Locate a fresh shared status-hook binary for isolation tests.
///
/// Always rebuilds the package product before selecting a candidate so layout
/// path changes (and other hook logic) cannot leave CoreChecks running a stale
/// `.build/*/ClaudeCodeStatusHook` that still writes legacy status files.
private func resolveClaudeCodeStatusHookBinary() throws -> URL {
    let fm = FileManager.default
    let argv0 = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()

    // Walk up from CWD / argv0 looking for Package.swift, rebuild, then pick product.
    let searchRoots: [URL] = [
        URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true),
        argv0.deletingLastPathComponent(),
    ]
    for root in searchRoots {
        var dir = root
        for _ in 0..<8 {
            let package = dir.appendingPathComponent("Package.swift")
            if fm.fileExists(atPath: package.path) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
                process.arguments = ["build", "--product", "ClaudeCodeStatusHook"]
                process.currentDirectoryURL = dir
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try process.run()
                process.waitUntilExit()
                expect(process.terminationStatus, 0, "swift build ClaudeCodeStatusHook should succeed")

                let candidates = [
                    dir.appendingPathComponent(".build/debug/ClaudeCodeStatusHook"),
                    dir.appendingPathComponent(".build/arm64-apple-macosx/debug/ClaudeCodeStatusHook"),
                    dir.appendingPathComponent(".build/x86_64-apple-macosx/debug/ClaudeCodeStatusHook"),
                    dir.appendingPathComponent(".build/release/ClaudeCodeStatusHook"),
                    dir.appendingPathComponent(".build/arm64-apple-macosx/release/ClaudeCodeStatusHook"),
                    // After rebuild, sibling of this test process is also valid.
                    argv0.deletingLastPathComponent().appendingPathComponent("ClaudeCodeStatusHook"),
                ]
                for candidate in candidates where fm.isExecutableFile(atPath: candidate.path) {
                    return candidate
                }
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
    }
    throw NSError(
        domain: "AgentHaloCoreChecks",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "ClaudeCodeStatusHook binary not found; build product ClaudeCodeStatusHook first"]
    )
}

private func runClaudeCodeStatusHook(
    binary: URL,
    home: URL,
    arguments: [String],
    environment: [String: String],
    stdinJSON: String
) throws {
    let process = Process()
    process.executableURL = binary
    process.arguments = arguments
    var env = ProcessInfo.processInfo.environment
    // Isolate HOME so status files land under the temp tree only.
    env["HOME"] = home.path
    for (key, value) in environment {
        env[key] = value
    }
    // Drop inherited GROK_* / ANTIGRAVITY_* unless the caller set them explicitly.
    if environment["GROK_SESSION_ID"] == nil {
        env.removeValue(forKey: "GROK_SESSION_ID")
    }
    if environment["GROK_HOOK_EVENT"] == nil {
        env.removeValue(forKey: "GROK_HOOK_EVENT")
    }
    if environment["ANTIGRAVITY_AGENT"] == nil {
        env.removeValue(forKey: "ANTIGRAVITY_AGENT")
    }
    if environment["ANTIGRAVITY_TRAJECTORY_ID"] == nil {
        env.removeValue(forKey: "ANTIGRAVITY_TRAJECTORY_ID")
    }
    if environment["ANTIGRAVITY_CONVERSATION_ID"] == nil {
        env.removeValue(forKey: "ANTIGRAVITY_CONVERSATION_ID")
    }
    process.environment = env

    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardInput = stdinPipe
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    try process.run()
    if let data = stdinJSON.data(using: .utf8) {
        stdinPipe.fileHandleForWriting.write(data)
    }
    stdinPipe.fileHandleForWriting.closeFile()
    process.waitUntilExit()
    expect(process.terminationStatus, 0, "ClaudeCodeStatusHook should exit 0")
}

/// End-to-end: shared hook binary routes Grok env to logs/grok-status.jsonl only,
/// Claude path to logs/claude-status.jsonl, and normalizes snake_case events.
func testClaudeCodeStatusHookIsolatesGrokAndClaudeStatusFiles() throws {
    let home = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agent-halo-hook-isolation-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: home) }
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

    let binary = try resolveClaudeCodeStatusHookBinary()
    let paths = AgentHaloPaths(homeDirectory: home)
    let grokStatus = paths.grokStatusLog
    let claudeStatus = paths.claudeStatusLog

    // Grok path: GROK_SESSION_ID set; snake_case CLI event should become PreToolUse.
    try runClaudeCodeStatusHook(
        binary: binary,
        home: home,
        arguments: ["pre_tool_use"],
        environment: [
            "GROK_SESSION_ID": "test-grok-session",
            "GROK_HOOK_EVENT": "pre_tool_use",
        ],
        stdinJSON: #"{"sessionId":"test-grok-session","cwd":"/tmp/proj","toolName":"run_terminal_command","permissionMode":"auto","timestamp":"2026-07-25T00:00:00Z"}"#
    )

    expect(FileManager.default.fileExists(atPath: grokStatus.path), "Grok path should write logs/grok-status.jsonl")
    let grokText = try String(contentsOf: grokStatus, encoding: .utf8)
    expect(grokText.contains("grok-hook"), "Grok record source should be grok-hook")
    expect(grokText.contains("test-grok-session"), "Grok record should include session id")
    expect(grokText.contains("\"PreToolUse\""), "snake_case pre_tool_use should normalize to PreToolUse")
    expect(grokText.contains("\"permissionMode\":\"auto\""), "hook should persist permissionMode for Auto ring gating")
    if FileManager.default.fileExists(atPath: claudeStatus.path) {
        let existingClaude = try String(contentsOf: claudeStatus, encoding: .utf8)
        expect(!existingClaude.contains("test-grok-session"), "Grok session id must not appear in logs/claude-status.jsonl")
    }

    // Claude path: no GROK_* env — must write claude file only (for this session).
    try runClaudeCodeStatusHook(
        binary: binary,
        home: home,
        arguments: ["PreToolUse"],
        environment: [:],
        stdinJSON: #"{"session_id":"claude-1","cwd":"/tmp/c","tool_name":"Bash"}"#
    )

    expect(FileManager.default.fileExists(atPath: claudeStatus.path), "Claude path should write logs/claude-status.jsonl")
    let claudeText = try String(contentsOf: claudeStatus, encoding: .utf8)
    expect(claudeText.contains("claude-hook"), "Claude record source should be claude-hook")
    expect(claudeText.contains("claude-1"), "Claude record should include session id")
    expect(claudeText.contains("\"PreToolUse\""), "Claude PreToolUse event should be PascalCase")
    let grokAfterClaude = try String(contentsOf: grokStatus, encoding: .utf8)
    expect(!grokAfterClaude.contains("claude-1"), "Claude session id must not be written to logs/grok-status.jsonl")
    expect(!claudeText.contains("test-grok-session"), "Grok session must not leak into Claude status file")
}

/// End-to-end: shared hook binary routes Antigravity to logs/antigravity-status.jsonl,
/// never pollutes Claude/Grok, and keeps Grok first when both signals exist.
func testClaudeCodeStatusHookIsolatesAntigravityStatusFiles() throws {
    let home = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agent-halo-ag-hook-isolation-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: home) }
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

    let binary = try resolveClaudeCodeStatusHookBinary()
    let paths = AgentHaloPaths(homeDirectory: home)
    let grokStatus = paths.grokStatusLog
    let claudeStatus = paths.claudeStatusLog
    let agStatus = paths.antigravityStatusLog

    // 1. ANTIGRAVITY_AGENT + trajectory id; snake_case pre_invocation → PreInvocation.
    try runClaudeCodeStatusHook(
        binary: binary,
        home: home,
        arguments: ["pre_invocation"],
        environment: [
            "ANTIGRAVITY_AGENT": "1",
            "ANTIGRAVITY_TRAJECTORY_ID": "traj-ag-1",
        ],
        stdinJSON: #"{"cwd":"/tmp/ag-proj"}"#
    )

    expect(FileManager.default.fileExists(atPath: agStatus.path), "AG path should write logs/antigravity-status.jsonl")
    let agText = try String(contentsOf: agStatus, encoding: .utf8)
    expect(agText.contains("antigravity-hook"), "AG record source should be antigravity-hook")
    expect(agText.contains("\"PreInvocation\""), "snake_case pre_invocation should normalize to PreInvocation")
    expect(agText.contains("traj-ag-1"), "AG sessionId should come from ANTIGRAVITY_TRAJECTORY_ID")
    expect(!agText.contains("errorText"), "successful AG hook must omit empty errorText")
    expect(!agText.contains("\"fatal\""), "successful AG hook must omit false fatal")
    if FileManager.default.fileExists(atPath: claudeStatus.path) {
        let existingClaude = try String(contentsOf: claudeStatus, encoding: .utf8)
        expect(!existingClaude.contains("traj-ag-1"), "AG session id must not appear in logs/claude-status.jsonl")
    }
    if FileManager.default.fileExists(atPath: grokStatus.path) {
        let existingGrok = try String(contentsOf: grokStatus, encoding: .utf8)
        expect(!existingGrok.contains("traj-ag-1"), "AG session id must not appear in logs/grok-status.jsonl")
    }

    // 2. GROK_SESSION_ID + AG env → Grok wins.
    try runClaudeCodeStatusHook(
        binary: binary,
        home: home,
        arguments: ["pre_invocation"],
        environment: [
            "GROK_SESSION_ID": "test-grok-wins",
            "ANTIGRAVITY_AGENT": "1",
            "ANTIGRAVITY_TRAJECTORY_ID": "traj-should-not-win",
        ],
        stdinJSON: #"{"cwd":"/tmp/g"}"#
    )
    expect(FileManager.default.fileExists(atPath: grokStatus.path), "Grok priority should write logs/grok-status.jsonl")
    let grokText = try String(contentsOf: grokStatus, encoding: .utf8)
    expect(grokText.contains("grok-hook"), "Grok-priority record source should be grok-hook")
    expect(grokText.contains("test-grok-wins"), "Grok-priority record should include Grok session id")
    let agAfterGrok = try String(contentsOf: agStatus, encoding: .utf8)
    expect(!agAfterGrok.contains("test-grok-wins"), "Grok session id must not appear in AG log")
    expect(!agAfterGrok.contains("traj-should-not-win"), "Grok-priority AG trajectory must not write AG log")

    // 3. transcript_path under antigravity-cli, no AG env → AG.
    try runClaudeCodeStatusHook(
        binary: binary,
        home: home,
        arguments: ["post_invocation"],
        environment: [:],
        stdinJSON: #"{"transcript_path":"/Users/x/.gemini/antigravity-cli/brain/c1/transcript.jsonl","cwd":"/tmp/cli","session_id":"cli-session"}"#
    )
    let agAfterTranscript = try String(contentsOf: agStatus, encoding: .utf8)
    expect(agAfterTranscript.contains("cli-session"), "antigravity-cli transcript should write AG log")
    expect(agAfterTranscript.contains("\"PostInvocation\""), "post_invocation should normalize to PostInvocation")
    expect(agAfterTranscript.contains("antigravity-hook"), "transcript-path AG record source should be antigravity-hook")
    if FileManager.default.fileExists(atPath: claudeStatus.path) {
        let existingClaude = try String(contentsOf: claudeStatus, encoding: .utf8)
        expect(!existingClaude.contains("cli-session"), "AG transcript session must not appear in Claude log")
    }

    // 4. Desktop app path /antigravity/ (Antigravity 2.0), no AG env → AG.
    try runClaudeCodeStatusHook(
        binary: binary,
        home: home,
        arguments: ["PreInvocation"],
        environment: [:],
        stdinJSON: #"{"transcriptPath":"/Users/x/.gemini/antigravity/transcript.jsonl","conversationId":"desk-1"}"#
    )
    let agAfterDesktop = try String(contentsOf: agStatus, encoding: .utf8)
    expect(agAfterDesktop.contains("desk-1"), "desktop /antigravity/ transcript should write AG log")
    expect(agAfterDesktop.contains("antigravity-hook"), "desktop transcript record source should be antigravity-hook")
    expect(agAfterDesktop.contains("\"PreInvocation\""), "desktop PreInvocation should stay PreInvocation")
    if FileManager.default.fileExists(atPath: claudeStatus.path) {
        let existingClaude = try String(contentsOf: claudeStatus, encoding: .utf8)
        expect(!existingClaude.contains("desk-1"), "desktop conversation must not appear in Claude log")
    }

    // 4b. IDE path /antigravity-ide/ → Claude, not AG.
    try runClaudeCodeStatusHook(
        binary: binary,
        home: home,
        arguments: ["UserPromptSubmit"],
        environment: [:],
        stdinJSON: #"{"transcript_path":"/Users/x/.gemini/antigravity-ide/brain/c1/transcript.jsonl","cwd":"/tmp/ide","session_id":"ide-session"}"#
    )
    expect(FileManager.default.fileExists(atPath: claudeStatus.path), "IDE /antigravity-ide/ path should write Claude log")
    let claudeAfterIDE = try String(contentsOf: claudeStatus, encoding: .utf8)
    expect(claudeAfterIDE.contains("claude-hook"), "IDE path should be treated as Claude")
    expect(claudeAfterIDE.contains("ide-session"), "IDE session should land in Claude log")
    let agAfterIDE = try String(contentsOf: agStatus, encoding: .utf8)
    expect(!agAfterIDE.contains("ide-session"), "/antigravity-ide/ must not write AG log")

    // 4c. Official desktop payload: toolCall.name + workspacePaths.
    try runClaudeCodeStatusHook(
        binary: binary,
        home: home,
        arguments: ["PreToolUse"],
        environment: [:],
        stdinJSON: #"{"transcriptPath":"/Users/x/proj/.gemini/antigravity/transcript.jsonl","conversationId":"desk-tool","workspacePaths":["/tmp/AgentHalo"],"toolCall":{"name":"run_command"}}"#
    )
    let agAfterOfficial = try String(contentsOf: agStatus, encoding: .utf8)
    expect(agAfterOfficial.contains("desk-tool"), "official desktop conversationId should write AG log")
    expect(agAfterOfficial.contains("run_command"), "official toolCall.name should persist as toolName")
    expect(agAfterOfficial.contains("AgentHalo"), "official workspacePaths[0] should persist as cwd")
    expect(agAfterOfficial.contains("antigravity-hook"), "official desktop payload source should be antigravity-hook")
    if FileManager.default.fileExists(atPath: claudeStatus.path) {
        let existingClaude = try String(contentsOf: claudeStatus, encoding: .utf8)
        expect(!existingClaude.contains("desk-tool"), "official desktop conversation must not appear in Claude log")
    }

    // 5. No AG/Grok signal → Claude.
    try runClaudeCodeStatusHook(
        binary: binary,
        home: home,
        arguments: ["PreToolUse"],
        environment: [:],
        stdinJSON: #"{"session_id":"claude-plain","cwd":"/tmp/c","tool_name":"Bash"}"#
    )
    let claudeAfterPlain = try String(contentsOf: claudeStatus, encoding: .utf8)
    expect(claudeAfterPlain.contains("claude-hook"), "no-signal record source should be claude-hook")
    expect(claudeAfterPlain.contains("claude-plain"), "no-signal session should write Claude log")
    let agAfterPlain = try String(contentsOf: agStatus, encoding: .utf8)
    expect(!agAfterPlain.contains("claude-plain"), "Claude session must not appear in AG log")

    // 6. Claude / Grok files must never contain AG session ids.
    expect(!claudeAfterPlain.contains("traj-ag-1"), "AG session id must not appear in Claude log")
    expect(!claudeAfterPlain.contains("cli-session"), "AG transcript session must not appear in Claude log")
    expect(!claudeAfterPlain.contains("desk-1"), "desktop conversation must not appear in Claude log")
    expect(!claudeAfterPlain.contains("desk-tool"), "official desktop conversation must not appear in Claude log")
    if FileManager.default.fileExists(atPath: grokStatus.path) {
        let grokAfter = try String(contentsOf: grokStatus, encoding: .utf8)
        expect(!grokAfter.contains("traj-ag-1"), "AG session id must not appear in Grok log")
        expect(!grokAfter.contains("cli-session"), "AG transcript session must not appear in Grok log")
        expect(!grokAfter.contains("desk-1"), "desktop conversation must not appear in Grok log")
        expect(!grokAfter.contains("claude-plain"), "Claude session must not appear in Grok log")
    }
}

/// AG Stop / PostToolUse carry errorText + fatal on the live events (agy has
/// no StopFailure). Those keys must land in antigravity-status.jsonl only.
func testClaudeCodeStatusHookPersistsAntigravityFailureFields() throws {
    let home = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agent-halo-ag-hook-failure-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: home) }
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

    let binary = try resolveClaudeCodeStatusHookBinary()
    let paths = AgentHaloPaths(homeDirectory: home)
    let grokStatus = paths.grokStatusLog
    let claudeStatus = paths.claudeStatusLog
    let agStatus = paths.antigravityStatusLog

    try runClaudeCodeStatusHook(
        binary: binary,
        home: home,
        arguments: ["stop"],
        environment: [
            "ANTIGRAVITY_AGENT": "1",
            "ANTIGRAVITY_TRAJECTORY_ID": "traj-fail-stop",
        ],
        stdinJSON: #"{"cwd":"/tmp/ag-fail","errorText":"turn boom","fatal":true,"timestamp":"2026-08-15T00:00:00Z"}"#
    )

    expect(FileManager.default.fileExists(atPath: agStatus.path), "AG failure Stop should write antigravity-status.jsonl")
    let stopText = try String(contentsOf: agStatus, encoding: .utf8)
    expect(stopText.contains("antigravity-hook"), "AG failure record source should be antigravity-hook")
    expect(stopText.contains("\"Stop\""), "stop should normalize to Stop")
    expect(stopText.contains("traj-fail-stop"), "AG failure session should come from trajectory id")
    expect(stopText.contains("\"errorText\":\"turn boom\""), "AG Stop errorText must be persisted")
    expect(stopText.contains("\"fatal\":true"), "AG Stop fatal must be persisted")
    expect(!FileManager.default.fileExists(atPath: claudeStatus.path), "AG Stop failure must not create Claude status file")
    expect(!FileManager.default.fileExists(atPath: grokStatus.path), "AG Stop failure must not create Grok status file")

    try runClaudeCodeStatusHook(
        binary: binary,
        home: home,
        arguments: ["post_tool_use"],
        environment: [
            "ANTIGRAVITY_AGENT": "1",
            "ANTIGRAVITY_TRAJECTORY_ID": "traj-fail-tool",
        ],
        stdinJSON: #"{"cwd":"/tmp/ag-fail","error":"exit 1","tool_name":"run_command","timestamp":"2026-08-15T00:00:01Z"}"#
    )

    let toolText = try String(contentsOf: agStatus, encoding: .utf8)
    expect(toolText.contains("traj-fail-tool"), "AG PostToolUse failure session should write AG log")
    expect(toolText.contains("\"PostToolUse\""), "post_tool_use should normalize to PostToolUse")
    expect(toolText.contains("\"errorText\":\"exit 1\""), "AG PostToolUse error equivalent must become errorText")
    if FileManager.default.fileExists(atPath: claudeStatus.path) {
        let claudeText = try String(contentsOf: claudeStatus, encoding: .utf8)
        expect(!claudeText.contains("traj-fail-stop"), "AG Stop failure must not appear in Claude log")
        expect(!claudeText.contains("traj-fail-tool"), "AG tool failure must not appear in Claude log")
        expect(!claudeText.contains("turn boom"), "AG errorText must not appear in Claude log")
    }
    if FileManager.default.fileExists(atPath: grokStatus.path) {
        let grokText = try String(contentsOf: grokStatus, encoding: .utf8)
        expect(!grokText.contains("traj-fail-stop"), "AG Stop failure must not appear in Grok log")
        expect(!grokText.contains("traj-fail-tool"), "AG tool failure must not appear in Grok log")
        expect(!grokText.contains("turn boom"), "AG errorText must not appear in Grok log")
    }
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
    expect(settled.state, .idle, "manual compact should settle to gray Offline")
    expect(settled.label, "OFFLINE", "manual compact settled label")
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
    let statusFile = root.appendingPathComponent("claude-status.jsonl")
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

/// Long human permission waits must not be age-pruned into STANDBY.
func testHookMonitorsRetainAttentionDespiteStaleLastEvent() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let old = now.addingTimeInterval(-1800) // 30 minutes ago
    let attention = SessionSnapshot(
        threadId: "awaiting",
        projectName: "P",
        workingDirectory: "/p",
        state: .attention,
        action: "Awaiting permission",
        lastEventAt: old,
        completedAt: nil,
        active: true,
        agent: .grok
    )
    let staleWorking = SessionSnapshot(
        threadId: "stuck",
        projectName: "P",
        workingDirectory: "/p",
        state: .working,
        action: "Running command",
        lastEventAt: old,
        completedAt: nil,
        active: true,
        agent: .grok
    )
    expect(
        GrokHookStatusMonitor.shouldRetainSnapshot(attention, now: now),
        true,
        "Grok attention survives 30m lastEvent age"
    )
    expect(
        ClaudeHookStatusMonitor.shouldRetainSnapshot(attention, now: now),
        true,
        "Claude attention survives 30m lastEvent age"
    )
    expect(
        GrokHookStatusMonitor.shouldRetainSnapshot(staleWorking, now: now),
        false,
        "Grok stale working is still pruned"
    )
    expect(
        ClaudeHookStatusMonitor.shouldRetainSnapshot(staleWorking, now: now),
        false,
        "Claude stale working is still pruned"
    )

    // Aggregator visibility: attention stays; stale working is hidden.
    let settings = HaloSettings(installedAt: now.addingTimeInterval(-3600))
    let keepAttention = SessionAggregator.aggregate(
        snapshots: [attention],
        settings: settings,
        focusedAgent: .grok,
        now: now
    )
    expect(keepAttention.state, .attention, "aggregator keeps long-held attention")
    expect(keepAttention.sessions.count, 1, "attention session remains visible")

    let hideWorking = SessionAggregator.aggregate(
        snapshots: [staleWorking],
        settings: settings,
        focusedAgent: .grok,
        now: now
    )
    expect(hideWorking.sessions.isEmpty, true, "stale working still hidden after 10m")
}

func testClaudeHookMonitorKeepsLongHeldPermissionAttention() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agent-halo-claude-attn-hold-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: root)
    }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let statusFile = root.appendingPathComponent("claude-status.jsonl")
    let t0 = ISO8601DateFormatter().date(from: "2026-06-16T04:00:00Z")!
    let lines = [
        #"{"timestamp":"2026-06-16T04:00:00Z","event":"UserPromptSubmit","sessionId":"perm-hold","cwd":"/tmp","source":"claude-hook"}"#,
        #"{"timestamp":"2026-06-16T04:00:01Z","event":"PermissionRequest","sessionId":"perm-hold","cwd":"/tmp","source":"claude-hook"}"#,
    ].joined(separator: "\n") + "\n"
    try Data(lines.utf8).write(to: statusFile)

    let monitor = ClaudeHookStatusMonitor(statusURL: statusFile)
    _ = monitor.refresh(now: t0.addingTimeInterval(2))
    expect(monitor.snapshots().first?.state, .attention, "precondition: attention")
    // Far past the normal 10m active prune window.
    _ = monitor.refresh(now: t0.addingTimeInterval(2000))
    let after = monitor.snapshots()
    expect(after.count, 1, "permission hold not pruned after ~33m")
    expect(after.first?.state, .attention, "still NEEDS YOU after long wait")
    expect(after.first?.action, "Awaiting permission", "action preserved")
}

func testGrokHookMonitorKeepsLongHeldPermissionAttention() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agent-halo-grok-attn-hold-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: root)
    }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let statusFile = root.appendingPathComponent("grok-status.jsonl")
    let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
    let t0 = ISO8601DateFormatter().date(from: "2026-07-30T08:00:00Z")!
    let sessionId = "perm-hold-grok"
    let cwd = "/tmp/AgentHaloPermHold"
    let encoded = GrokSessionContextReader.encodeWorkspaceDirectory(cwd)
    let sessionDir = sessionsRoot.appendingPathComponent(encoded, isDirectory: true)
        .appendingPathComponent(sessionId, isDirectory: true)
    try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

    let hooks = [
        #"{"timestamp":"2026-07-30T08:00:00Z","event":"UserPromptSubmit","sessionId":"\#(sessionId)","cwd":"\#(cwd)","permissionMode":"default","source":"grok-hook"}"#,
        #"{"timestamp":"2026-07-30T08:00:01Z","event":"PreToolUse","sessionId":"\#(sessionId)","cwd":"\#(cwd)","toolName":"run_terminal_command","permissionMode":"default","source":"grok-hook"}"#,
    ].joined(separator: "\n") + "\n"
    try Data(hooks.utf8).write(to: statusFile)
    let events = [
        #"{"ts":"2026-07-30T08:00:00.500Z","type":"turn_started"}"#,
        #"{"ts":"2026-07-30T08:00:01.100Z","type":"permission_requested"}"#,
    ].joined(separator: "\n") + "\n"
    try Data(events.utf8).write(to: sessionDir.appendingPathComponent("events.jsonl"))

    let monitor = GrokHookStatusMonitor(statusURL: statusFile, sessionsRoot: sessionsRoot)
    // First refresh arms the pending timer from observation time; a second tick
    // after pendingPermissionAttentionDelay paints NEEDS YOU.
    _ = monitor.refresh(now: t0.addingTimeInterval(2))
    _ = monitor.refresh(
        now: t0.addingTimeInterval(2 + GrokHookStatusReducer.pendingPermissionAttentionDelay + 0.05)
    )
    expect(monitor.snapshots().first?.state, .attention, "precondition: attention after delay")
    _ = monitor.refresh(now: t0.addingTimeInterval(2000))
    let after = monitor.snapshots()
    expect(after.count, 1, "Grok permission hold not pruned after ~33m")
    expect(after.first?.state, .attention, "Grok still NEEDS YOU after long wait")
    expect(after.first?.action, "Awaiting permission", "Grok action preserved")
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
    let statusFile = root.appendingPathComponent("claude-status.jsonl")
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

    let live = #"{"status":"idle","pid":\#(ProcessInfo.processInfo.processIdentifier),"sessionId":"live","cwd":"/tmp/live-project","updatedAt":2000}"#
    try Data(live.utf8).write(to: file)
    expect(ClaudeLiveSessionReader.hasStandbySession(homeDirectory: home), true, "live idle Claude session should show standby")

    let busyFile = sessions.appendingPathComponent("busy.json")
    let busy = #"{"status":"busy","pid":\#(ProcessInfo.processInfo.processIdentifier),"sessionId":"busy","cwd":"/tmp/busy-project","updatedAt":4000}"#
    try Data(busy.utf8).write(to: busyFile)
    expect(
        ClaudeLiveSessionReader.liveSessions(homeDirectory: home).contains { $0.sessionId == "busy" },
        true,
        "a live busy Claude session should be available for metadata retention"
    )
    // PR #10: Claude Code keeps `status` at "busy" mid-turn, so standby
    // detection no longer filters on waiting/idle — a live pid is enough.
    expect(
        ClaudeLiveSessionReader.standbySessions(homeDirectory: home).contains { $0.sessionId == "busy" },
        true,
        "a live busy Claude session should be classified as standby"
    )

    let newerFile = sessions.appendingPathComponent("newer.json")
    let newer = #"{"status":"waiting","pid":\#(ProcessInfo.processInfo.processIdentifier),"sessionId":"newer","cwd":"/tmp/newer-project","updatedAt":3000}"#
    try Data(newer.utf8).write(to: newerFile)
    let standbySessions = ClaudeLiveSessionReader.standbySessions(homeDirectory: home)
    expect(standbySessions.count, 3, "all live Claude sessions should be returned as standby")
    expect(
        ClaudeLiveSessionReader.preferredStandbySession(
            sessions: standbySessions,
            hookSnapshots: []
        )?.sessionId,
        "busy",
        "most recently updated live session should win without hook evidence"
    )

    let recentHook = SessionSnapshot(
        threadId: "live",
        projectName: "live-project",
        workingDirectory: "/tmp/live-project",
        state: .done,
        action: "Complete",
        lastEventAt: Date(timeIntervalSince1970: 10),
        completedAt: Date(timeIntervalSince1970: 10),
        active: false,
        agent: .claudeCode
    )
    expect(
        ClaudeLiveSessionReader.preferredStandbySession(
            sessions: standbySessions,
            hookSnapshots: [recentHook]
        )?.sessionId,
        "live",
        "recent matching hook activity should identify the visible standby session"
    )
}

func testClaudeMainSessionDetailsResolverUsesExactSessionAndSafeLiveProject() {
    let now = ISO8601DateFormatter().date(from: "2026-06-23T02:00:00Z")!
    let main = SessionSnapshot(
        threadId: "main-session",
        projectName: "text-extract",
        workingDirectory: "/Users/wjs/work/xisoft/text-extract",
        state: .idle,
        action: "Ready",
        lastEventAt: now,
        completedAt: nil,
        active: false,
        agent: .claudeCode
    )
    let live = ClaudeLiveSessionSnapshot(
        sessionId: "main-session",
        workingDirectory: "/Users/wjs/work/xisoft/text-extract",
        processId: 1,
        status: "idle",
        updatedAt: now
    )
    let usage = ClaudeContextUsageSnapshot(
        sessionId: "main-session",
        usedPercent: 26.5,
        modelName: "glm-latest",
        inputTokens: 53_100,
        outputTokens: 1_200,
        updatedAt: now
    )

    let resolved = ClaudeMainSessionDetailsResolver.resolve(
        mainSessionId: "main-session",
        mainSessions: [main],
        liveSession: live,
        usage: usage
    )
    expect(resolved.sessionDetails.projectName, "text-extract", "main transcript project")
    expect(resolved.sessionDetails.modelName, "glm-latest", "exact statusline model")
    expect(resolved.sessionDetails.inputTokens, 53_100, "exact statusline input tokens")
    expect(resolved.contextUsedPercent, 26.5, "exact statusline context")

    let liveOnly = ClaudeMainSessionDetailsResolver.resolve(
        mainSessionId: "main-session",
        mainSessions: [],
        liveSession: live,
        usage: usage
    )
    expect(liveOnly.sessionDetails.projectName, "text-extract", "standby live session should retain a safe project")

    var mismatched = usage
    mismatched.sessionId = "other-session"
    let rejected = ClaudeMainSessionDetailsResolver.resolve(
        mainSessionId: "main-session",
        mainSessions: [main],
        liveSession: live,
        usage: mismatched
    )
    expect(rejected.sessionDetails.modelName == nil, "another session model must be rejected")
    expect(rejected.contextUsedPercent == nil, "another session context must be rejected")

    let worktree = ClaudeLiveSessionSnapshot(
        sessionId: "missing-main",
        workingDirectory: "/Users/wjs/work/xisoft/text-extract/.claude/worktrees/agent-a47ee146bdd2ba852",
        processId: 1,
        status: "idle",
        updatedAt: now
    )
    let unsafe = ClaudeMainSessionDetailsResolver.resolve(
        mainSessionId: "missing-main",
        mainSessions: [],
        liveSession: worktree,
        usage: nil
    )
    expect(unsafe.sessionDetails.projectName == nil, "agent worktree name must not become the project")
}

func testClaudeMainSessionDetailsResolverPrefersTranscriptSessionTitle() {
    let now = ISO8601DateFormatter().date(from: "2026-06-29T03:00:00Z")!
    var reducer = ClaudeSessionReducer(filePath: "/tmp/session-title.jsonl", now: now)
    reducer.consume(jsonLine: #"{"type":"user","timestamp":"2026-06-29T03:00:00Z","cwd":"/Users/wjs/work/pyproj/AgentHalo","sessionId":"main-session","message":{"role":"user","content":"整理归档"}}"#, now: now)
    reducer.consume(jsonLine: #"{"type":"ai-title","timestamp":"2026-06-29T03:00:01Z","cwd":"/Users/wjs/work/pyproj/AgentHalo","sessionId":"main-session","aiTitle":"整理归档 2026q3 测试"}"#, now: now.addingTimeInterval(1))

    let usage = ClaudeContextUsageSnapshot(
        sessionId: "main-session",
        usedPercent: 26.5,
        modelName: "claude-sonnet-4",
        inputTokens: 12_000,
        outputTokens: 900,
        updatedAt: now
    )
    let resolved = ClaudeMainSessionDetailsResolver.resolve(
        mainSessionId: "main-session",
        mainSessions: [reducer.snapshot],
        liveSession: nil,
        usage: usage
    )

    expect(resolved.sessionDetails.projectName, "AgentHalo", "safe project name should remain the directory leaf")
    expect(resolved.sessionDetails.sessionTitle, "整理归档 2026q3 测试", "Claude details should preserve transcript ai-title")
}

/// `/rename` writes `type=custom-title` with `customTitle` (not `ai-title`/`aiTitle`).
func testClaudeSessionReducerReadsCustomTitleFromRename() {
    let now = ISO8601DateFormatter().date(from: "2026-08-07T09:17:59Z")!
    var reducer = ClaudeSessionReducer(filePath: "/tmp/custom-title.jsonl", now: now)
    reducer.consume(
        jsonLine: #"{"type":"user","timestamp":"2026-08-07T09:17:00Z","cwd":"/Users/wjs/work/xisoft/BidCheck","sessionId":"rename-session","message":{"role":"user","content":"你好"}}"#,
        now: now
    )
    reducer.consume(
        jsonLine: #"{"type":"custom-title","customTitle":"测试","sessionId":"rename-session"}"#,
        now: now.addingTimeInterval(1)
    )
    expect(reducer.snapshot.sessionTitle, "测试", "custom-title from /rename should become sessionTitle")
}

func testClaudeSessionReducerCustomTitleOverridesAITitle() {
    let now = ISO8601DateFormatter().date(from: "2026-08-07T09:17:59Z")!
    var reducer = ClaudeSessionReducer(filePath: "/tmp/custom-over-ai.jsonl", now: now)
    reducer.consume(
        jsonLine: #"{"type":"ai-title","timestamp":"2026-08-07T09:17:00Z","sessionId":"s1","aiTitle":"Auto generated"}"#,
        now: now
    )
    expect(reducer.snapshot.sessionTitle, "Auto generated", "ai-title alone should still work")
    reducer.consume(
        jsonLine: #"{"type":"custom-title","customTitle":"测试","sessionId":"s1"}"#,
        now: now.addingTimeInterval(1)
    )
    expect(reducer.snapshot.sessionTitle, "测试", "user rename should replace ai-title")
    reducer.consume(
        jsonLine: #"{"type":"ai-title","timestamp":"2026-08-07T09:18:00Z","sessionId":"s1","aiTitle":"Later auto title"}"#,
        now: now.addingTimeInterval(2)
    )
    expect(reducer.snapshot.sessionTitle, "测试", "later ai-title must not overwrite custom-title")

    let resolved = ClaudeMainSessionDetailsResolver.resolve(
        mainSessionId: "s1",
        mainSessions: [reducer.snapshot],
        liveSession: nil,
        usage: ClaudeContextUsageSnapshot(
            sessionId: "s1",
            usedPercent: 14,
            modelName: "deepseek-v4-flash",
            inputTokens: 28_423,
            outputTokens: 263,
            updatedAt: now
        )
    )
    expect(resolved.sessionDetails.sessionTitle, "测试", "details card should surface custom-title")
    expect(resolved.sessionDetails.modelName, "deepseek-v4-flash", "model still comes from usage")
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
    expect(settled.state, .idle, "Claude waiting for user input should settle to Offline")
    expect(settled.label, "OFFLINE", "Claude settled label")
    expect(settled.detail, "Claude Code is not running", "Claude waiting-for-input detail")
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
    expect(GeneratedHaloSpec.releaseVersion, "1.0.0", "generated shared release version")
    expect(GeneratedHaloSpec.state(.attention).label, "NEEDS YOU", "generated state labels")
    expect(GeneratedHaloSpec.friendlyAction("apply_patch"), "Editing files", "generated action rules")
    expect(GeneratedHaloSpec.classifyFailure("server overloaded"), "failure.service_unavailable", "generated failure rules")
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

testAgentHaloPathsLayoutV2()
do {
    try testAgentHaloLayoutMigratorMovesFlatLayoutToV2AndKeepsLegacyBinaries()
    try testAgentHaloLayoutMigratorPrefersExistingNewPathsAndDeletesOld()
    try testAgentHaloLayoutMigratorScrubsResidueWhenAlreadyVersion2()
    try testAgentHaloLayoutMigratorPreservesLegacyDataUntilDestinationIsUsable()
} catch {
    fatalError("layout migrator checks failed: \(error)")
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
testGrokFocusedAgentPersistence()
testPiFocusedAgentPersistence()
do {
    try testAntigravityKindIsOptInAndPersistsWhenEnabled()
} catch {
    fatalError("antigravity kind checks failed: \(error)")
}
do {
    try testSettingsDefaultsEnabledAgentsAndMenuBarIconWhenMissing()
    try testSettingsDefaultEnabledAgentsIsFrozenAllowlist()
    testSettingsNormalizesEmptyEnabledAgentsToDefaultEnabledAgents()
    testSettingsNormalizesDuplicateAndUnknownOrder()
    try testSettingsLoadFiltersUnknownEnabledAgentsWithoutResettingOtherFields()
    testSettingsMovesFocusWhenDisabled()
    testSettingsCannotDisableTheLastAgent()
    testSettingsPersistsEnabledAgentsAndMenuBarIcon()
    try testSettingsLoadRepairsFocusOutsideEnabledAgents()
} catch {
    fatalError("enabledAgents settings checks failed: \(error)")
}
testPiStatusParseContextSentinelAndMapping()
do {
    try testPiStatusMonitorRefreshAndRotationRetention()
    try testPiRuntimeMonitorDetectsPreexistingSession()
    try testPiExtensionConfiguratorInstallsFromSource()
} catch {
    fatalError("Pi status checks failed: \(error)")
}
testAcknowledgedErrorVisibilityUsesLatestErrorTime()
testWorkingVisibilityLiveCallOutputAndInitialTail()
testSessionReducerCapturesCurrentCodexTurnDetailsAndRateLimitAvailability()
testSessionReducerFallsBackToLastTokenUsageWithoutTotals()
testSessionReducerCapturesOnlyExplicitCodexSessionTitles()
do {
    try testCodexSessionTitleReaderUsesLatestValidTitle()
    try testCodexSessionMonitorPrefersIndexTitleAndKeepsMetadataFallback()
} catch {
    fatalError("Codex session title checks failed: \(error)")
}
testToolFailedDoesNotBecomeFatalError()
do {
    try testClaudeHookConfiguratorWritesUserSettingsNotLegacyClaudeJson()
} catch {
    fatalError("\(error)")
}
do {
    try testGrokHookConfiguratorWritesHooksJSON()
    try testRuntimeBootstrapUpgradesLayoutV1WithoutStrandingHookPaths()
    try testRuntimeBootstrapSkipsDisabledAgentUserConfig()
    try testAntigravityHookConfiguratorCreatesNamedGroupHooksJSON()
    try testAntigravityHookConfiguratorMergesWithoutReplacingOrcaStatus()
    try testAntigravityHookConfiguratorLeavesPreferredPathConfigAlone()
    try testAntigravityHookConfiguratorAbortsWhenRootIsNotADictionary()
    try testRuntimeBootstrapDoesNotCreateAntigravityHooksWhenDisabled()
    try testRuntimeBootstrapCreatesAntigravityHooksWhenEnabled()
    try testGrokHookConfiguratorLeavesPreferredPathConfigAlone()
    try testGrokHookConfiguratorRewritesLegacyRootPath()
    try testGrokHookConfiguratorRepairsDeadExecutableCommand()
    try testBinaryStagingNeverLeavesDestinationMissing()
    testStatuslineProxyRecursionCheckUsesExactExecutablePaths()
} catch {
    fatalError("\(error)")
}
do {
    try testClaudeStatusLineConfiguratorPreservesAndChainsExistingCommand()
    try testClaudeHookConfiguratorRewritesLegacyPathToPreferred()
    try testClaudeHookConfiguratorDoesNotDeleteLegacyBinaryWhenBundledMissing()
    try testClaudeStatusLineConfiguratorRewritesLegacyProxyToPreferred()
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
testRateLimitReaderReadsExplicitMonthlyQuota()
testRateLimitReaderReadsFreeCreditsRemainingAsMonthlyQuota()
testRateLimitReaderKeepsNewestCompletePlusBucketsOverOlderMonthlyUsage()
testRateLimitReaderLeavesResetOnlyMonthlyQuotaPending()
testRateLimitReaderReadsLongWindowPrimaryAsMonthly()
testRateLimitReaderDoesNotTreatSecondaryBucketAsMonthly()
testRateLimitReaderTreatsNullCreditsCodexCompatibilityAsPlus()
testRateLimitReaderTreatsEmptyCodexCreditsCompatibilityAsPlus()
testRateLimitReaderDoesNotTreatEmptyLegacyCreditsSecondaryAsMonthly()
testRateLimitReaderDoesNotReturnEarlyOnContextOnlySnapshot()
testClaudeStatusLineUsageParserReadsAuthoritativeContextPercent()
do {
    try testGrokSessionContextReaderReadsSignalsPercentAndSummary()
    try testGrokSessionContextReaderFallsBackToTokenRatio()
    try testGrokSessionContextReaderPrefersLiveUpdatesTotalTokens()
    try testGrokSessionContextReaderLiveTokensWithoutSignals()
    try testGrokActiveSessionsReaderParsesArrayEntries()
    try testGrokSessionTurnEventsReaderDetectsCancelledTurnEnded()
    testGrokSessionTurnStateEqualTimestampsStayOpen()
    try testGrokSessionTurnEventsReaderFirstAttachFindsBuriedTurnBoundaries()
    try testGrokSessionTurnEventsReaderParsesPermissionLifecycle()
    try testGrokSessionTurnEventsReaderSupersedesCancelWithSteerStart()
    try testGrokSessionTurnEventsReaderParsesSendNowTrigger()
    try testGrokHookStatusMonitorMapsSessionEscCancelToError()
    try testGrokHookStatusMonitorSendNowDoesNotPaintError()
    try testGrokHookStatusMonitorIgnoresAutoPermissionDuringTool()
} catch {
    fatalError("\(error)")
}
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
    try testClaudeContextUsageStorageSeparatesSessionsAndRejectsUnsafeIds()
    try testClaudeContextUsageReaderRequiresExactFreshSession()
    try testClaudeContextUsageReaderRetainsExactUsageWhileSessionIsLive()
    try testClaudeContextUsageGCAgeCountProtectAndThrottle()
    try testClaudeContextUsageReaderDoesNotReadLegacySingleFile()
} catch {
    fatalError("\(error)")
}
do {
    try testClaudeStatusLineProxyRuntimeCapturesUsageAndForwardsInput()
} catch {
    fatalError("\(error)")
}
testCodexRealtimeActivityReaderDetectsAnswerStreaming()
testCodexRealtimeActivityReaderDetectsContextCompactionStream()
testCodexRealtimeActivityReaderDetectsArgumentStream()
testCodexRealtimeActivityReaderEscalatedArgumentsAttention()
testCodexRealtimeActivityReaderClearsAnswerStreamingWhenDone()
testSessionReducerMapsCustomToolRequestUserInputToAttention()
testSessionReducerMapsEscalatedExecCommandToAttention()
testSessionReducerMapsApprovalNamedToolToAttention()
testSessionReducerMapsEscalatedArgumentsStringToAttention()
testCodexRealtimeActivityReaderDetectsRequestUserInput()
testAggregatorInjectsUnacknowledgedCodexFailureWhenIdle()
testAggregatorFiltersByFocusedAgent()
testAggregatorFiltersClaudeAndGrokByFocusedAgent()
testAggregatorFiltersByAntigravityFocusedAgent()
testAggregatorIdleDetailUsesFocusedAgent()
testAggregatorDoesNotInjectCodexFailureForClaudeFocus()
testClaudeReducerDoesNotCompleteWithoutExplicitCompletionEvent()
testAggregatorReturnsReadyAfterCompletedSessionSettles()
testAggregatorReturnsReadyAfterGrokCompletedSessionSettles()
testAggregatorSettlesCodexCompletionLikeClaude()
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
testAntigravityReducerLifecycle()
testAntigravityReducerIgnoresBadLineAndUnknownEvent()
testAntigravityReducerStopFailureAndToolFailureSemantics()
testAntigravityReducerIdentityPostInvocationHoldAndPermission()
testAntigravityReducerUsesSessionPermissionLifecycleLikeGrok()
testAntigravityReducerStuckPreToolUseRecoversAfterSafetyTimeout()
do {
    try testAntigravityPermissionReaderEmitsRequestedAndResolved()
    try testAntigravityHookStatusMonitorMapsLifecycleAndSkipsBadLines()
    try testAntigravityHookStatusMonitorAppliesConversationPermission()
} catch {
    fatalError("\(error)")
}
testGrokHookReducerLifecycle()
testGrokHookReducerPermissionPromptWhileThinkingIsAttention()
testGrokHookReducerAutoModeShellPermissionNeverAttention()
testGrokHookReducerAutoPermissionResolveDoesNotAttention()
testGrokHookReducerPendingPermissionBecomesAttentionAfterDelay()
testGrokHookReducerHumanPermissionResolveClearsAttention()
testGrokHookReducerAutoNoiseDuringToolExecutionStaysWorking()
testGrokHookReducerHumanWaitAfterPreToolUseBecomesAttention()
testGrokHookReducerMapsEscCancelToInterrupted()
testGrokHookReducerSteerCancelDoesNotPaintError()
do {
    try testClaudeCodeStatusHookIsolatesGrokAndClaudeStatusFiles()
    try testClaudeCodeStatusHookIsolatesAntigravityStatusFiles()
    try testClaudeCodeStatusHookPersistsAntigravityFailureFields()
} catch {
    fatalError("hook isolation check failed: \(error)")
}
testClaudeHookReducerStuckPreToolUseRecoversAfterSafetyTimeout()
testClaudeHookReducerManualCompactShowsDoneThenReady()
testClaudeHookReducerActiveCompactRestoresThinking()
testClaudeHookReducerIdleCompactTimeoutReturnsToReady()
do {
    try testClaudeHookMonitorPrunesStaleReducers()
} catch {
    fatalError("\(error)")
}
testHookMonitorsRetainAttentionDespiteStaleLastEvent()
do {
    try testClaudeHookMonitorKeepsLongHeldPermissionAttention()
    try testGrokHookMonitorKeepsLongHeldPermissionAttention()
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
testClaudeMainSessionDetailsResolverUsesExactSessionAndSafeLiveProject()
testClaudeMainSessionDetailsResolverPrefersTranscriptSessionTitle()
testClaudeSessionReducerReadsCustomTitleFromRename()
testClaudeSessionReducerCustomTitleOverridesAITitle()
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
await runUsageModelChecks()
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
