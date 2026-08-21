import Foundation
import AgentHaloCore

func runFocusedSessionHostChecks() {
    testProcessTreeWalkerSkipsHelpersAndFindsITerm()
    testProcessTreeWalkerFindsVSCodeThroughHelper()
    testProcessTreeWalkerActivatesRegularStartPid()
    testProcessTreeWalkerRejectsSshdAndConhostOnly()
    testProcessTreeWalkerRejectsCyclesAndDepth()
    testProcessTreeWalkerSkipsSelfProcess()
    testResolverUsesVisibleClaudePid()
    testResolverUsesPreferredClaudeStandby()
    testResolverMatchesGrokWorkspaceWhenIdsDiffer()
    testResolverIgnoresGrokEntryWithoutPid()
    testResolverUsesPreferredPiStandby()
    testResolverAntigravityRequiresExactlyOnePresentPid()
    testResolverReturnsNilWhenPausedOfflineOrCodex()
    testActivatorWalksResolvedPidAndSkipsCodexResolver()
    testActivatorSilentWhenHostMissing()
}

private func session(
    _ threadId: String,
    agent: AgentKind,
    state: HaloState = .thinking,
    active: Bool = true,
    cwd: String = "/tmp/proj",
    lastEventAt: Date = Date()
) -> SessionSnapshot {
    SessionSnapshot(
        threadId: threadId,
        projectName: "proj",
        workingDirectory: cwd,
        state: state,
        action: "Thinking",
        lastEventAt: lastEventAt,
        completedAt: nil,
        active: active,
        agent: agent
    )
}

func testResolverUsesVisibleClaudePid() {
    let visible = [session("s-visible", agent: .claudeCode)]
    let evidence = FocusedSessionLiveEvidence(
        claude: [
            ClaudeLiveSessionSnapshot(
                sessionId: "s-other",
                workingDirectory: "/tmp/other",
                processId: 111,
                status: "idle",
                updatedAt: Date()
            ),
            ClaudeLiveSessionSnapshot(
                sessionId: "s-visible",
                workingDirectory: "/tmp/proj",
                processId: 222,
                status: "busy",
                updatedAt: Date()
            )
        ]
    )
    expect(
        FocusedSessionHostResolver.resolveProcessId(
            focusedAgent: .claudeCode,
            visibleSessions: visible,
            hookSnapshots: visible,
            paused: false,
            evidence: evidence
        ),
        222,
        "visible Claude session wins over another live pid"
    )
}

func testResolverUsesPreferredClaudeStandby() {
    let newer = Date()
    let older = newer.addingTimeInterval(-60)
    let hooks = [
        session("s-old", agent: .claudeCode, state: .idle, active: false, lastEventAt: older),
        session("s-new", agent: .claudeCode, state: .idle, active: false, lastEventAt: newer)
    ]
    let evidence = FocusedSessionLiveEvidence(
        claude: [
            ClaudeLiveSessionSnapshot(
                sessionId: "s-old", workingDirectory: "/tmp/a",
                processId: 301, status: "idle", updatedAt: older
            ),
            ClaudeLiveSessionSnapshot(
                sessionId: "s-new", workingDirectory: "/tmp/b",
                processId: 302, status: "idle", updatedAt: newer
            )
        ]
    )
    expect(
        FocusedSessionHostResolver.resolveProcessId(
            focusedAgent: .claudeCode,
            visibleSessions: [],
            hookSnapshots: hooks,
            paused: false,
            evidence: evidence
        ),
        302,
        "STANDBY uses Claude preferred live session"
    )
}

func testResolverMatchesGrokWorkspaceWhenIdsDiffer() {
    let visible = [session("hook-id", agent: .grok, cwd: "/tmp/ws")]
    let evidence = FocusedSessionLiveEvidence(
        grok: [
            GrokActiveSessionRef(sessionId: "live-id", cwd: "/tmp/ws", processId: 404)
        ]
    )
    expect(
        FocusedSessionHostResolver.resolveProcessId(
            focusedAgent: .grok,
            visibleSessions: visible,
            hookSnapshots: visible,
            paused: false,
            evidence: evidence
        ),
        404,
        "Grok workspace match supplies the live pid"
    )
}

func testResolverIgnoresGrokEntryWithoutPid() {
    let visible = [session("abc", agent: .grok)]
    let evidence = FocusedSessionLiveEvidence(
        grok: [GrokActiveSessionRef(sessionId: "abc", cwd: "/tmp/ws", processId: nil)]
    )
    expect(
        FocusedSessionHostResolver.resolveProcessId(
            focusedAgent: .grok,
            visibleSessions: visible,
            hookSnapshots: visible,
            paused: false,
            evidence: evidence
        ),
        nil,
        "Grok entry without pid does not activate"
    )
}

func testResolverUsesPreferredPiStandby() {
    let hooks = [
        session("pi-old", agent: .pi, state: .idle, active: false, lastEventAt: Date().addingTimeInterval(-30)),
        session("pi-new", agent: .pi, state: .idle, active: false, lastEventAt: Date())
    ]
    let evidence = FocusedSessionLiveEvidence(
        pi: [
            PiLivePid(sessionId: "pi-old", processId: 501),
            PiLivePid(sessionId: "pi-new", processId: 502)
        ]
    )
    expect(
        FocusedSessionHostResolver.resolveProcessId(
            focusedAgent: .pi,
            visibleSessions: [],
            hookSnapshots: hooks,
            paused: false,
            evidence: evidence
        ),
        502,
        "STANDBY Pi uses newest live record"
    )
}

func testResolverAntigravityRequiresExactlyOnePresentPid() {
    expect(
        FocusedSessionHostResolver.resolveProcessId(
            focusedAgent: .antigravity,
            visibleSessions: [session("ag", agent: .antigravity)],
            hookSnapshots: [],
            paused: false,
            evidence: FocusedSessionLiveEvidence(antigravityPresentPids: [701])
        ),
        701,
        "exactly one Antigravity present pid"
    )
    expect(
        FocusedSessionHostResolver.resolveProcessId(
            focusedAgent: .antigravity,
            visibleSessions: [session("ag", agent: .antigravity)],
            hookSnapshots: [],
            paused: false,
            evidence: FocusedSessionLiveEvidence(antigravityPresentPids: [701, 702])
        ),
        nil,
        "multiple Antigravity pids are ambiguous"
    )
    expect(
        FocusedSessionHostResolver.resolveProcessId(
            focusedAgent: .antigravity,
            visibleSessions: [],
            hookSnapshots: [],
            paused: false,
            evidence: FocusedSessionLiveEvidence(antigravityPresentPids: [])
        ),
        nil,
        "zero Antigravity pids"
    )
}

func testResolverReturnsNilWhenPausedOfflineOrCodex() {
    let evidence = FocusedSessionLiveEvidence(
        claude: [
            ClaudeLiveSessionSnapshot(
                sessionId: "s1", workingDirectory: "/tmp",
                processId: 1, status: "busy", updatedAt: Date()
            )
        ]
    )
    expect(
        FocusedSessionHostResolver.resolveProcessId(
            focusedAgent: .claudeCode,
            visibleSessions: [session("s1", agent: .claudeCode)],
            hookSnapshots: [],
            paused: true,
            evidence: evidence
        ),
        nil,
        "paused does not activate"
    )
    expect(
        FocusedSessionHostResolver.resolveProcessId(
            focusedAgent: .claudeCode,
            visibleSessions: [],
            hookSnapshots: [],
            paused: false,
            evidence: .empty
        ),
        nil,
        "offline Claude has no pid"
    )
    expect(
        FocusedSessionHostResolver.resolveProcessId(
            focusedAgent: .codex,
            visibleSessions: [session("c", agent: .codex)],
            hookSnapshots: [],
            paused: false,
            evidence: .empty
        ),
        nil,
        "Codex is not resolved via session pid"
    )
}

private func proc(
    _ pid: Int32,
    parent: Int32,
    _ name: String,
    regular: Bool
) -> HostProcessRecord {
    HostProcessRecord(
        processId: pid,
        parentProcessId: parent,
        name: name,
        isRegularApp: regular
    )
}

private func table(_ records: [HostProcessRecord]) -> [Int32: HostProcessRecord] {
    Dictionary(uniqueKeysWithValues: records.map { ($0.processId, $0) })
}

func testProcessTreeWalkerSkipsHelpersAndFindsITerm() {
    let processes = table([
        proc(10, parent: 1, "iTerm2", regular: true),
        proc(11, parent: 10, "zsh", regular: false),
        proc(12, parent: 11, "claude", regular: false)
    ])
    expect(
        ProcessTreeHostWalker.resolveHost(
            startingProcessId: 12,
            processes: processes,
            selfProcessId: 99
        ),
        10,
        "claude → zsh → iTerm2"
    )
}

func testProcessTreeWalkerFindsVSCodeThroughHelper() {
    let processes = table([
        proc(20, parent: 1, "Code", regular: true),
        proc(21, parent: 20, "Code Helper", regular: false),
        proc(22, parent: 21, "node", regular: false)
    ])
    expect(
        ProcessTreeHostWalker.resolveHost(
            startingProcessId: 22,
            processes: processes,
            selfProcessId: 99
        ),
        20,
        "node → Code Helper → Code"
    )
}

func testProcessTreeWalkerActivatesRegularStartPid() {
    let processes = table([
        proc(30, parent: 1, "Antigravity", regular: true)
    ])
    expect(
        ProcessTreeHostWalker.resolveHost(
            startingProcessId: 30,
            processes: processes,
            selfProcessId: 99
        ),
        30,
        "regular Antigravity app is the host"
    )
}

func testProcessTreeWalkerRejectsSshdAndConhostOnly() {
    let ssh = table([
        proc(40, parent: 1, "sshd", regular: false),
        proc(41, parent: 40, "agy", regular: false)
    ])
    expect(
        ProcessTreeHostWalker.resolveHost(
            startingProcessId: 41,
            processes: ssh,
            selfProcessId: 99
        ),
        nil,
        "agy under sshd has no GUI host"
    )
    let conhost = table([
        proc(50, parent: 1, "conhost", regular: false),
        proc(51, parent: 50, "grok", regular: false)
    ])
    expect(
        ProcessTreeHostWalker.resolveHost(
            startingProcessId: 51,
            processes: conhost,
            selfProcessId: 99
        ),
        nil,
        "conhost-only chain is not a host"
    )
}

func testProcessTreeWalkerRejectsCyclesAndDepth() {
    let cycled = table([
        proc(60, parent: 61, "zsh", regular: false),
        proc(61, parent: 60, "claude", regular: false)
    ])
    expect(
        ProcessTreeHostWalker.resolveHost(
            startingProcessId: 61,
            processes: cycled,
            selfProcessId: 99
        ),
        nil,
        "cycle returns nil"
    )

    var deep: [HostProcessRecord] = [
        proc(1, parent: 0, "launchd", regular: false)
    ]
    for pid in Int32(70)...Int32(70 + ProcessTreeHostWalker.maxDepth) {
        deep.append(proc(pid, parent: pid == 70 ? 1 : pid - 1, "zsh", regular: false))
    }
    let last = 70 + Int32(ProcessTreeHostWalker.maxDepth)
    expect(
        ProcessTreeHostWalker.resolveHost(
            startingProcessId: last,
            processes: table(deep),
            selfProcessId: 99
        ),
        nil,
        "depth beyond maxDepth returns nil"
    )
}

func testProcessTreeWalkerSkipsSelfProcess() {
    let processes = table([
        proc(80, parent: 1, "AgentHaloMac", regular: true),
        proc(81, parent: 80, "claude", regular: false)
    ])
    expect(
        ProcessTreeHostWalker.resolveHost(
            startingProcessId: 81,
            processes: processes,
            selfProcessId: 80
        ),
        nil,
        "must not activate Agent Halo itself"
    )
    expect(ProcessTreeHostWalker.shouldSkipName("Code Helper"), true, "Helper suffix")
    expect(ProcessTreeHostWalker.shouldSkipName("language_server"), true, "language_server")
    expect(ProcessTreeHostWalker.shouldSkipName("iTerm2"), false, "iTerm is not skipped")
}

func testActivatorWalksResolvedPidAndSkipsCodexResolver() {
    var hostPids: [Int32] = []
    var codexCalls = 0
    let processes = table([
        proc(10, parent: 1, "iTerm2", regular: true),
        proc(12, parent: 10, "claude", regular: false)
    ])
    let evidence = FocusedSessionLiveEvidence(
        claude: [
            ClaudeLiveSessionSnapshot(
                sessionId: "s1", workingDirectory: "/tmp/proj",
                processId: 12, status: "busy", updatedAt: Date()
            )
        ]
    )
    FocusedAgentActivator.activate(
        focusedAgent: .claudeCode,
        visibleSessions: [session("s1", agent: .claudeCode)],
        hookSnapshots: [],
        paused: false,
        evidence: evidence,
        processes: processes,
        selfProcessId: 99,
        activateCodex: { codexCalls += 1 },
        activateHost: { hostPids.append($0) }
    )
    expect(hostPids, [10], "activator walks Claude pid to iTerm")
    expect(codexCalls, 0, "non-Codex focus must not call Codex activator")

    FocusedAgentActivator.activate(
        focusedAgent: .codex,
        visibleSessions: [],
        hookSnapshots: [],
        paused: false,
        evidence: .empty,
        processes: processes,
        selfProcessId: 99,
        activateCodex: { codexCalls += 1 },
        activateHost: { hostPids.append($0) }
    )
    expect(codexCalls, 1, "Codex focus uses the desktop-app activator")
    expect(hostPids, [10], "Codex focus does not walk a session pid")
}

func testActivatorSilentWhenHostMissing() {
    var calls = 0
    FocusedAgentActivator.activate(
        focusedAgent: .pi,
        visibleSessions: [],
        hookSnapshots: [],
        paused: false,
        evidence: .empty,
        processes: [:],
        selfProcessId: 1,
        activateCodex: { calls += 1 },
        activateHost: { _ in calls += 1 }
    )
    expect(calls, 0, "missing pid is silent")
}
