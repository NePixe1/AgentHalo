import Foundation
import AgentHaloCore

func runFocusedSessionHostChecks() {
    testProcessTreeWalkerSkipsHelpersAndFindsITerm()
    testProcessTreeWalkerFindsVSCodeThroughHelper()
    testProcessTreeWalkerActivatesRegularStartPid()
    testProcessTreeWalkerRejectsSshdAndConhostOnly()
    testProcessTreeWalkerRejectsCyclesAndDepth()
    testProcessTreeWalkerSkipsSelfProcess()
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
