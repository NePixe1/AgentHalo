import Foundation
import AgentHaloCore

private func isoFractionalString(from date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

func testOpenCodeParseFiltersChildCompletionAndKeepsAttention() {
    let launched = Date(timeIntervalSince1970: 1_700_000_000)
    let object = jsonObject("""
    {"sessions":[
      {"id":"root","title":"Monitor tests","state":"thinking","input":120,"output":10,"cacheRead":4,"context":400,"contextWindow":1000,"directory":"/work/app"},
      {"id":"child","parentID":"root","state":"done"},
      {"id":"ask","parentID":"root","state":"attention","updatedAt":"\(isoFractionalString(from:  launched))"}
    ]}
    """)
    let sessions = OpenCodeStatusReducer.parseSessions(object, launched: launched)
    expect(sessions.count, 2, "child done does not complete root")
    expect(sessions[0].state, .thinking, "root stays thinking")
    expect(sessions[0].inputTokens, 120, "OpenCode input")
    expect(sessions[0].outputTokens, 10, "OpenCode output")
    expect(sessions[0].contextUsedPercent, Optional(40.0), "context is input+cache+output over the window")
    expect(sessions[0].sessionTitle, "Monitor tests", "session title")
    expect(sessions[1].state, .attention, "child permission reaches attention")

    let zero = OpenCodeStatusReducer.parseSessions(jsonObject("""
    {"sessions":[{"id":"root","state":"idle","input":0,"output":0,"context":0,"contextWindow":0}]}
    """), launched: launched)
    expect(zero[0].inputTokens, nil, "missing usage stays missing")
    expect(zero[0].contextUsedPercent, nil, "missing context window is not zero percent")

    let cached = OpenCodeStatusReducer.parseSessions(jsonObject("""
    {"sessions":[{"id":"root","state":"idle","input":0,"output":0,"cacheRead":20,"context":20,"contextWindow":100}]}
    """), launched: launched)
    expect(cached[0].inputTokens, nil, "cache-only usage does not paint zero tokens")
    expect(cached[0].outputTokens, nil, "cache-only output stays missing")
    expect(cached[0].contextUsedPercent, Optional(20.0), "cache still counts toward context")
}

func testOpenCodeHeartbeatRequiresLiveProcessAndSettlesCompletion() {
    let started = Date(timeIntervalSince1970: 1_700_000_000)
    let now = started.addingTimeInterval(20)
    let launched = started.addingTimeInterval(-60)
    let live = LiveProcess(processId: 42, name: "opencode", startedAt: started)
    let body = openCodeSnapshot(pid: 42, started: started, now: now, state: "thinking", completed: nil)
    let online = OpenCodeStatusReducer.reduce(
        files: [(now, body)],
        processes: [live],
        launched: launched,
        now: now
    )
    expect(online.pluginPresent, true, "matching start time keeps the heartbeat")
    expect(online.processPresent, true, "opencode process counts as present")
    expect(online.hostPid, 42, "host pid comes from the plugin snapshot")
    expect(online.sessions.first?.state, .thinking, "thinking snapshot")

    let staleProcess = OpenCodeStatusReducer.reduce(
        files: [(now, body)],
        processes: [LiveProcess(processId: 42, name: "opencode", startedAt: started.addingTimeInterval(30))],
        launched: launched,
        now: now
    )
    expect(staleProcess.pluginPresent, false, "pid reuse drops the old snapshot")
    expect(staleProcess.processPresent, true, "a live process without a heartbeat is still present")

    let dead = OpenCodeStatusReducer.reduce(
        files: [(now, body)],
        processes: [],
        launched: launched,
        now: now
    )
    expect(dead.pluginPresent, false, "dead pid is rejected")
    expect(dead.processPresent, false, "no process is offline")

    let settings = HaloSettings(
        focusedAgent: .opencode,
        enabledAgents: [.codex, .pi],
        installedAt: launched
    )
    expect(settings.enabledAgents.contains(.opencode), false, "existing enabled agents are preserved")
    var enabled = settings
    enabled.setAgent(.opencode, enabled: true)
    enabled.focusedAgent = .opencode
    let doneBody = openCodeSnapshot(pid: 42, started: started, now: now, state: "done", completed: now)
    let done = OpenCodeStatusReducer.reduce(
        files: [(now, doneBody)],
        processes: [live],
        launched: launched,
        now: now
    )
    let fresh = SessionAggregator.aggregate(
        snapshots: done.sessions,
        settings: enabled,
        focusedAgent: .opencode,
        now: now
    )
    expect(fresh.label, "COMPLETE", "fresh completion")
    let settled = SessionAggregator.aggregate(
        snapshots: done.sessions,
        settings: enabled,
        focusedAgent: .opencode,
        now: now.addingTimeInterval(10)
    )
    let standby = AppDelegateStandIn.standby(settled, live: done.pluginPresent)
    expect(standby.label, "STANDBY", "completion settles without losing presence")

    let connecting = OpenCodeStatusReducer.reduce(files: [], processes: [live], launched: launched, now: now)
    expect(connecting.pluginPresent, false, "running without plugin is not online")
    expect(connecting.processPresent, true, "running without plugin is connecting, not offline")
    expect(L10n.shared["status.connecting_opencode"].isEmpty, false, "connecting copy exists")
}

func testOpenCodePluginInstallRespectsConfigDirAndSkipsUnchangedFile() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("agent-halo-opencode-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let custom = root.appendingPathComponent("custom-config", isDirectory: true)
    let installed = OpenCodePluginConfigurator.configure(
        homeDirectory: root,
        environment: ["OPENCODE_CONFIG_DIR": custom.path]
    )
    let expected = custom
        .appendingPathComponent("plugins", isDirectory: true)
        .appendingPathComponent("agent-halo-status.js")
    expect(installed?.path, expected.path, "OPENCODE_CONFIG_DIR selects the plugin path")
    let source = try String(contentsOf: expected, encoding: .utf8)
    expect(source.contains("AgentHaloStatus"), true, "plugin source is installed")
    let again = OpenCodePluginConfigurator.configure(
        homeDirectory: root,
        environment: ["OPENCODE_CONFIG_DIR": custom.path]
    )
    expect(again?.path, expected.path, "unchanged plugin is left in place")

    let xdg = root.appendingPathComponent("xdg", isDirectory: true)
    _ = OpenCodePluginConfigurator.configure(
        homeDirectory: root,
        environment: ["XDG_CONFIG_HOME": xdg.path]
    )
    expect(
        FileManager.default.fileExists(atPath: xdg.appendingPathComponent("opencode/plugins/agent-halo-status.js").path),
        true,
        "XDG_CONFIG_HOME/opencode receives the plugin"
    )

    AgentHaloRuntimeBootstrap.bootstrap(
        homeDirectory: root,
        enabledAgents: [.codex],
        environment: [:]
    )
    expect(
        FileManager.default.fileExists(atPath: root.appendingPathComponent(".config/opencode/plugins/agent-halo-status.js").path),
        false,
        "disabled OpenCode does not install the plugin"
    )
    AgentHaloRuntimeBootstrap.bootstrap(
        homeDirectory: root,
        enabledAgents: [.codex, .opencode],
        environment: [:]
    )
    expect(
        FileManager.default.fileExists(atPath: root.appendingPathComponent(".config/opencode/plugins/agent-halo-status.js").path),
        true,
        "enabling OpenCode installs the plugin under ~/.config"
    )
}

func testWorkBuddyStateMappingEligibilityAndTranscript() throws {
    let now = Date()
    let timestamp = String(Int64(now.timeIntervalSince1970 * 1000))
    let cases: [(String, HaloState)] = [
        ("planning", .thinking),
        ("working", .working),
        ("streaming", .working),
        ("pending", .attention),
        ("waiting_permission", .attention),
        ("waiting_question", .attention),
        ("paused", .attention),
        ("completed", .done),
        ("error", .error),
        ("failed", .error),
        ("interrupted", .error),
        ("idle", .idle)
    ]
    for pair in cases {
        let session = WorkBuddyMonitor.parseRow(["session", pair.0, "Fixture", "/work", "model", timestamp, "120", "1000"])
        expect(session.state, pair.1, "\(pair.0) mapping")
        expect(session.contextUsedPercent, Optional(12.0), "context comes from used/size")
    }
    expect(WorkBuddyMonitor.escapeProjectDirectory(#"C:\Work"#), "c-Work", "windows directory escape")
    expect(WorkBuddyMonitor.escapeProjectDirectory("/Users/wjs/Work"), "-Users-wjs-Work", "posix directory escape keeps casing")

    var working = WorkBuddyMonitor.parseRow(["s", "working", "Fixture", "/work", "model", timestamp, "0", "0"])
    expect(WorkBuddyMonitor.isSessionEligible(working, live: false, appStart: now), false, "orphaned working record is not activity")
    working.lastEventAt = now.addingTimeInterval(-7200)
    expect(WorkBuddyMonitor.isSessionEligible(working, live: true, appStart: now), true, "long live tool is not timed out")
    let settings = HaloSettings(
        focusedAgent: .workbuddy,
        enabledAgents: [.workbuddy],
        installedAt: now.addingTimeInterval(-86_400)
    )
    let aggregate = SessionAggregator.aggregate(
        snapshots: [working],
        settings: settings,
        focusedAgent: .workbuddy,
        now: now
    )
    expect(aggregate.state, .working, "aggregator keeps a long WorkBuddy tool")

    let completed = WorkBuddyMonitor.parseRow(["s", "completed", "Fixture", "/work", "model", timestamp, "0", "0"])
    expect(
        WorkBuddyMonitor.isSessionEligible(completed, live: false, appStart: now.addingTimeInterval(60)),
        false,
        "completion before app launch is stale"
    )
    let haloLaunch = now
    let finishedEarly = String(Int64(haloLaunch.addingTimeInterval(-3).timeIntervalSince1970 * 1000))
    var replay = WorkBuddyMonitor.parseRow(["s", "completed", "Fixture", "/work", "model", finishedEarly, "0", "0"])
    expect(
        WorkBuddyMonitor.isSessionEligible(replay, live: true, appStart: haloLaunch.addingTimeInterval(-120)),
        true,
        "a live row that finished before this launch is still stored"
    )
    WorkBuddyMonitor.suppressHistoricalCompletion(&replay, launched: haloLaunch)
    expect(replay.state, .idle, "completion before this launch does not stay done")
    let replayed = SessionAggregator.aggregate(
        snapshots: [replay],
        settings: HaloSettings(
            focusedAgent: .workbuddy,
            enabledAgents: [.workbuddy],
            installedAt: haloLaunch.addingTimeInterval(-86_400)
        ),
        focusedAgent: .workbuddy,
        now: haloLaunch
    )
    expect(replayed.label, "OFFLINE", "historical completion does not flash complete")
    let finishedNow = String(Int64(haloLaunch.addingTimeInterval(1).timeIntervalSince1970 * 1000))
    var freshCompletion = WorkBuddyMonitor.parseRow(["s", "completed", "Fixture", "/work", "model", finishedNow, "0", "0"])
    WorkBuddyMonitor.suppressHistoricalCompletion(&freshCompletion, launched: haloLaunch)
    expect(freshCompletion.state, .done, "completion after launch stays complete")
    let freshAggregate = SessionAggregator.aggregate(
        snapshots: [freshCompletion],
        settings: HaloSettings(
            focusedAgent: .workbuddy,
            enabledAgents: [.workbuddy],
            installedAt: haloLaunch.addingTimeInterval(-86_400)
        ),
        focusedAgent: .workbuddy,
        now: haloLaunch.addingTimeInterval(1)
    )
    expect(freshAggregate.label, "COMPLETE", "fresh completion still shows")
    let staleError = SessionSnapshot(
        threadId: "err",
        projectName: "Fixture",
        workingDirectory: "/work",
        state: .error,
        action: "Interrupted",
        lastEventAt: now.addingTimeInterval(-86_400),
        completedAt: nil,
        active: false,
        agent: .workbuddy
    )
    let errorAggregate = SessionAggregator.aggregate(
        snapshots: [staleError],
        settings: HaloSettings(
            focusedAgent: .workbuddy,
            enabledAgents: [.workbuddy],
            installedAt: now.addingTimeInterval(-200_000),
            acknowledgedErrorAt: now
        ),
        focusedAgent: .workbuddy,
        now: now
    )
    expect(errorAggregate.state, .error, "a current WorkBuddy error stays visible")
    let newerWork = SessionSnapshot(
        threadId: "work",
        projectName: "Fixture",
        workingDirectory: "/work",
        state: .working,
        action: "Using tools",
        lastEventAt: now,
        completedAt: nil,
        active: true,
        agent: .workbuddy
    )
    let sibling = SessionAggregator.aggregate(
        snapshots: [staleError, newerWork],
        settings: HaloSettings(
            focusedAgent: .workbuddy,
            enabledAgents: [.workbuddy],
            installedAt: now.addingTimeInterval(-200_000)
        ),
        focusedAgent: .workbuddy,
        now: now
    )
    expect(sibling.label, "INTERRUPTED", "a newer sibling does not hide a current error")
    let agedDone = SessionSnapshot(
        threadId: "done",
        projectName: "Fixture",
        workingDirectory: "/work",
        state: .done,
        action: "Complete",
        lastEventAt: now.addingTimeInterval(-20),
        completedAt: now.addingTimeInterval(-20),
        active: false,
        agent: .opencode
    )
    let openCodeError = SessionSnapshot(
        threadId: "err",
        projectName: "Fixture",
        workingDirectory: "/work",
        state: .error,
        action: "Interrupted",
        lastEventAt: now.addingTimeInterval(-80),
        completedAt: nil,
        active: false,
        agent: .opencode
    )
    let aged = SessionAggregator.aggregate(
        snapshots: [openCodeError, agedDone],
        settings: HaloSettings(
            focusedAgent: .opencode,
            enabledAgents: [.opencode],
            installedAt: now.addingTimeInterval(-200_000)
        ),
        focusedAgent: .opencode,
        now: now
    )
    expect(aged.label, "INTERRUPTED", "an aged completion does not clear a current OpenCode error")
    let untitled = WorkBuddyMonitor.parseRow(["s", "working", "", "/Users/wjs/Work", "model", timestamp, "1", "10"])
    expect(untitled.sessionTitle, "Work", "untitled WorkBuddy task uses the directory name")
    expect(untitled.projectName, "Work", "untitled project name matches the card title")

    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("agent-halo-workbuddy-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let directory = home
        .appendingPathComponent(".workbuddy/projects/c-Work", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let path = directory.appendingPathComponent("fixture.jsonl")
    let session = SessionSnapshot(
        threadId: "fixture",
        projectName: "Fixture",
        workingDirectory: #"C:\Work"#,
        state: .working,
        action: "Using tools",
        lastEventAt: now,
        completedAt: nil,
        active: true,
        agent: .workbuddy
    )
    try (record(input: 120, output: 30, model: "Fixture Model") + "\n").write(to: path, atomically: true, encoding: .utf8)
    var cursor = WorkBuddyMonitor.ingestTranscript(at: path, cursor: nil)
    var measured = session
    WorkBuddyMonitor.apply(cursor, to: &measured)
    expect(measured.modelName, "Fixture Model", "native transcript model")
    expect(measured.inputTokens, 120, "native transcript input")
    expect(measured.outputTokens, 30, "native transcript output")

    let handle = try FileHandle(forWritingTo: path)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(record(input: 240, output: 40, model: nil).utf8))
    try handle.close()
    cursor = WorkBuddyMonitor.ingestTranscript(at: path, cursor: cursor)
    measured = session
    WorkBuddyMonitor.apply(cursor, to: &measured)
    expect(measured.inputTokens, 120, "incomplete last line keeps last valid usage")

    let finish = try FileHandle(forWritingTo: path)
    try finish.seekToEnd()
    try finish.write(contentsOf: Data(("\n" + record(input: 0, output: 0, model: nil) + "\n").utf8))
    try finish.close()
    cursor = WorkBuddyMonitor.ingestTranscript(at: path, cursor: cursor)
    measured = session
    WorkBuddyMonitor.apply(cursor, to: &measured)
    expect(measured.inputTokens, 240, "append and zero placeholder handling")
    expect(measured.outputTokens, 40, "zero output does not replace the last real usage")

    try (record(input: 9, output: 2, model: nil) + "\n").write(to: path, atomically: true, encoding: .utf8)
    cursor = WorkBuddyMonitor.ingestTranscript(at: path, cursor: cursor)
    measured = session
    WorkBuddyMonitor.apply(cursor, to: &measured)
    expect(measured.inputTokens, 9, "truncated transcript resets cursor")

    try (record(input: 8, output: 3, model: nil) + "\n").write(to: path, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.modificationDate: Date().addingTimeInterval(2)],
        ofItemAtPath: path.path
    )
    cursor = WorkBuddyMonitor.ingestTranscript(at: path, cursor: cursor)
    measured = session
    WorkBuddyMonitor.apply(cursor, to: &measured)
    expect(measured.inputTokens, 8, "same-length replacement refreshes usage")
    expect(measured.outputTokens, 3, "same-length replacement refreshes output")
}

func testWorkBuddyScanReadsDatabaseAndIgnoresPrewarm() throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("agent-halo-workbuddy-db-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let root = home.appendingPathComponent(".workbuddy", isDirectory: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("sessions"), withIntermediateDirectories: true)
    let database = root.appendingPathComponent("workbuddy.db")
    let started = Date(timeIntervalSince1970: 1_700_000_100)
    let updated = Int64(started.addingTimeInterval(5).timeIntervalSince1970 * 1000)
    let sql = """
    CREATE TABLE sessions (id TEXT, status TEXT, custom_title TEXT, title TEXT, cwd TEXT, model TEXT, updated_at INTEGER, deleted_at INTEGER);
    CREATE TABLE session_usage (session_id TEXT, used INTEGER, size INTEGER);
    INSERT INTO sessions VALUES ('live', 'working', NULL, 'Live', '/work', 'db-model', \(updated), NULL);
    INSERT INTO sessions VALUES ('orphan', 'working', NULL, 'Old', '/work', 'db-model', \(updated), NULL);
    INSERT INTO sessions VALUES ('gone', 'completed', NULL, 'Deleted', '/work', 'db-model', \(updated), 1);
    INSERT INTO session_usage VALUES ('live', 120, 1000);
    """
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    process.arguments = [database.path, sql]
    try process.run()
    process.waitUntilExit()
    expect(process.terminationStatus, 0, "sqlite fixture")
    let sessionFile = root.appendingPathComponent("sessions/live.json")
    let registration = """
    {"kind":"interactive","pid":77,"startedAt":\(updated),"sessionId":"live"}
    """
    try registration.write(to: sessionFile, atomically: true, encoding: .utf8)
    try #"{"kind":"prewarm","pid":78,"startedAt":\#(updated),"sessionId":"warm"}"#.write(
        to: root.appendingPathComponent("sessions/warm.json"),
        atomically: true,
        encoding: .utf8
    )
    let processes = [
        LiveProcess(processId: 70, name: "WorkBuddy", startedAt: started),
        LiveProcess(processId: 77, name: "workbuddy", startedAt: started)
    ]
    var transcripts: [String: WorkBuddyTranscriptCursor] = [:]
    let observation = WorkBuddyMonitor.scan(
        homeDirectory: home,
        processes: processes,
        transcripts: &transcripts,
        launched: started
    )
    expect(observation.present, true, "WorkBuddy process is present")
    expect(observation.connected, true, "database is readable")
    expect(observation.hostPid, 70, "earliest app process is the host")
    expect(observation.sessions.count, 1, "orphan and deleted rows are excluded")
    expect(observation.sessions[0].threadId, "live", "live interactive session")
    expect(observation.sessions[0].contextUsedPercent, Optional(12.0), "usage join")

    // More recent history must never evict an older registered live task.
    let history = Process()
    history.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    history.arguments = [database.path, (0..<80).map { index in
        "INSERT INTO sessions VALUES ('history-\(index)', 'completed', NULL, 'History', '/work', 'model', \(updated + Int64(index) + 1), NULL);"
    }.joined()]
    try history.run()
    history.waitUntilExit()
    expect(history.terminationStatus, 0, "history fixture")
    let crowded = WorkBuddyMonitor.scan(
        homeDirectory: home, processes: processes, transcripts: &transcripts, launched: started
    )
    expect(crowded.sessions.contains { $0.threadId == "live" && $0.state == .working }, true,
           "80 newer completed tasks cannot hide a registered live task")
    expect(crowded.sessions.count, 65, "only historical rows are capped at 64")

    let offline = WorkBuddyMonitor.scan(
        homeDirectory: home,
        processes: [],
        transcripts: &transcripts,
        launched: started
    )
    expect(offline.present, false, "exit suppresses saved data")
    expect(offline.sessions.isEmpty, true, "offline hides old sessions")

    let fifo = root.appendingPathComponent("lock.fifo")
    let mkfifo = Process()
    mkfifo.executableURL = URL(fileURLWithPath: "/usr/bin/mkfifo")
    mkfifo.arguments = [fifo.path]
    try mkfifo.run()
    mkfifo.waitUntilExit()
    let fd = open(fifo.path, O_RDWR)
    expect(fd >= 0, true, "lock fifo opens")
    let marker = root.appendingPathComponent("lock-ready.txt")
    let locker = Process()
    locker.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    locker.arguments = [database.path]
    let input = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
    locker.standardInput = input
    locker.standardOutput = Pipe()
    locker.standardError = Pipe()
    try locker.run()
    defer {
        if locker.isRunning {
            locker.terminate()
        }
        close(fd)
    }
    // A reader started while BEGIN EXCLUSIVE is still pending makes that
    // statement fail once. sqlite3 then sits at the next prompt with no lock.
    // The marker is written only after the exclusive transaction is open.
    let command = """
    .bail on
    .timeout 3000
    BEGIN EXCLUSIVE;
    .once \(marker.path)
    SELECT 'ready';

    """
    try input.write(contentsOf: Data(command.utf8))
    let deadline = Date().addingTimeInterval(3)
    var ready = false
    while Date() < deadline {
        if let text = try? String(contentsOf: marker, encoding: .utf8), text.contains("ready") {
            ready = true
            break
        }
        if !locker.isRunning {
            break
        }
        Thread.sleep(forTimeInterval: 0.02)
    }
    expect(ready && locker.isRunning, true, "database lock is held")
    let probe = Process()
    probe.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    probe.arguments = ["file:\(database.path)?mode=ro", "SELECT id FROM sessions;"]
    probe.standardOutput = Pipe()
    probe.standardError = Pipe()
    try probe.run()
    probe.waitUntilExit()
    expect(probe.terminationStatus != 0, true, "exclusive lock blocks a read-only query")
    var blockedTranscripts: [String: WorkBuddyTranscriptCursor] = [:]
    let blocked = WorkBuddyMonitor.scan(
        homeDirectory: home,
        processes: processes,
        transcripts: &blockedTranscripts,
        launched: started
    )
    expect(blocked.present, true, "process remains present while the database is locked")
    expect(blocked.connected, false, "a failed sqlite step is not a successful read")
    expect(blocked.sessions.isEmpty, true, "a failed read publishes no rows")
}

func testOpenCodeAndWorkBuddyHostPidsResolve() {
    let open = FocusedSessionHostResolver.resolveProcessId(
        focusedAgent: .opencode,
        visibleSessions: [],
        hookSnapshots: [],
        paused: false,
        evidence: FocusedSessionLiveEvidence(opencodeHostPid: 42)
    )
    expect(open, 42, "OpenCode activates the plugin process")
    let paused = FocusedSessionHostResolver.resolveProcessId(
        focusedAgent: .workbuddy,
        visibleSessions: [],
        hookSnapshots: [],
        paused: true,
        evidence: FocusedSessionLiveEvidence(workbuddyHostPid: 7)
    )
    expect(paused, nil, "paused monitoring does not activate a host")
    expect(ProcessTreeHostWalker.shouldSkipName("opencode"), true, "OpenCode CLI walks up to its GUI host")
    expect(ProcessTreeHostWalker.shouldSkipName("WorkBuddy"), false, "WorkBuddy itself is the desktop host")
    let current = LiveProcessProbe.lookup(ProcessInfo.processInfo.processIdentifier)
    expect(current?.startedAt != nil, true, "limited query reads the current process start time")
    expect(current?.name.isEmpty == false, true, "limited query reads the process name")
    expect(LiveProcessProbe.lookup(Int32.max), nil, "dead pid is rejected")
    let indexed = LiveProcessProbe.indexed([
        LiveProcess(processId: 7, name: "old", startedAt: nil),
        LiveProcess(processId: 7, name: "new", startedAt: nil)
    ])
    expect(indexed[7]?.name, "new", "repeated pids keep the latest record")
}

private func jsonObject(_ text: String) -> [String: Any] {
    let data = Data(text.utf8)
    return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}

private func openCodeSnapshot(pid: Int32, started: Date, now: Date, state: String, completed: Date?) -> String {
    let completedText = completed.map { "\"completedAt\":\"\(isoFractionalString(from:  $0))\"" } ?? "\"completedAt\":null"
    return """
    {"version":1,"pid":\(pid),"startedAt":"\(isoFractionalString(from:  started))","timestamp":"\(isoFractionalString(from:  now))","sessions":[{"id":"root","title":"Monitor","state":"\(state)","updatedAt":"\(isoFractionalString(from:  now))",\(completedText)}]}
    """
}

private func record(input: Int, output: Int, model: String?) -> String {
    let provider = model.map { "{\"requestModelName\":\"\($0)\"}" } ?? "{}"
    return """
    {"providerData":\(provider),"message":{"usage":{"input_tokens":\(input),"output_tokens":\(output)}}}
    """
}

private enum AppDelegateStandIn {
    static func standby(_ aggregate: AggregateSnapshot, live: Bool) -> AggregateSnapshot {
        guard live, aggregate.state == .idle, aggregate.label == "OFFLINE" else { return aggregate }
        return AggregateSnapshot(
            state: .done,
            label: "STANDBY",
            detail: aggregate.focusedAgent.localizedStandbyDetail,
            sessions: [],
            focusedAgent: aggregate.focusedAgent
        )
    }
}
