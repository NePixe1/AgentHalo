# Focused Agent Host Activation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Double-clicking the halo activates the host app of the session currently driving the ring for Claude / Grok / Pi / Antigravity; Codex keeps its existing desktop-app scan.

**Architecture:** A pure resolver picks one live PID from existing session evidence. A pure process-tree walker climbs parents to the first regular GUI host. Platform entry points only gather cached evidence on double-click and call `activate`. No `SessionSnapshot.processId`, no tick-time process walk, no `ps`.

**Tech Stack:** Swift 6 / AgentHaloCore + AppKit on macOS; C# / .NET Framework 4.8 on Windows; existing `AgentHaloCoreChecks`, `AgentHaloMac --self-check`, `AgentHalo.exe --self-test`.

**Spec:** [2026-08-18-focused-agent-host-activation-design.md](../specs/2026-08-18-focused-agent-host-activation-design.md)

## Global Constraints

- Double-click only. Single-click must stay non-activating.
- Codex activation stays the existing desktop-app scan and must not require a session PID.
- Do not add `processId` to shared `SessionSnapshot`.
- Do not walk the process tree or spawn `ps` on the 0.3s tick.
- Missing PID, dead PID, or no GUI host → silent return. No user-visible error, no settings, no Accessibility prompt, no app launch.
- Activate the host **app**, not a specific tab.
- Antigravity remains macOS-only. Windows `AgentKind` has no Antigravity case.
- Antigravity PID rule: exactly one present process (`agy` or `Antigravity` main app). Zero or many → no-op.
- Windows Claude live reader may expose pid, but only for this double-click path (existing liveness rules stay).
- Every task is TDD: failing check → confirm fail → minimal impl → focused check passes → commit.
- `git status --short` before each commit; stage only that task's files.
- Windows `--self-test` can only be run on a Windows machine. On macOS, still land the C# and do not claim those tests passed.

---

## File map

Create:

```text
src/macos/Sources/AgentHaloCore/ProcessTreeHostWalker.swift
src/macos/Sources/AgentHaloCore/FocusedSessionHostResolver.swift
src/macos/Sources/AgentHaloCore/FocusedAgentActivator.swift
src/macos/Sources/AgentHaloCoreChecks/FocusedSessionHostChecks.swift
src/windows/ProcessTreeHostWalker.cs
src/windows/FocusedSessionHostResolver.cs
src/windows/FocusedAgentActivator.cs
```

Modify:

```text
src/macos/Sources/AgentHaloCoreChecks/main.swift
src/macos/Sources/AgentHaloMac/AppDelegate.swift
src/macos/Sources/AgentHaloMac/HaloInteractionChecks.swift
src/windows/ClaudeCodeMonitor.cs
src/windows/HaloWindow.cs
src/windows/Diagnostics.cs
README.md
README.zh-CN.md
docs/PRODUCT.md
AGENTS.md
docs/superpowers/specs/2026-07-25-macos-grok-build-usage-lifecycle-design.md
docs/superpowers/specs/2026-07-29-windows-grok-build-parity-design.md
docs/superpowers/specs/2026-08-14-antigravity-agent-macos-design.md
docs/superpowers/specs/2026-08-18-focused-agent-host-activation-design.md
```

Locked interfaces (every later task uses these names):

```swift
public struct HostProcessRecord: Equatable, Sendable {
    public var processId: Int32
    public var parentProcessId: Int32
    public var name: String
    public var isRegularApp: Bool
    public init(processId: Int32, parentProcessId: Int32, name: String, isRegularApp: Bool)
}

public enum ProcessTreeHostWalker {
    public static let maxDepth = 32
    public static func resolveHost(
        startingProcessId: Int32,
        processes: [Int32: HostProcessRecord],
        selfProcessId: Int32
    ) -> Int32?
    public static func shouldSkipName(_ name: String) -> Bool
}

public struct PiLivePid: Equatable, Sendable {
    public var sessionId: String
    public var processId: Int32
    public init(sessionId: String, processId: Int32)
}

public struct FocusedSessionLiveEvidence: Equatable, Sendable {
    public var claude: [ClaudeLiveSessionSnapshot]
    public var grok: [GrokActiveSessionRef]
    public var pi: [PiLivePid]
    public var antigravityPresentPids: [Int32]
    public static let empty: FocusedSessionLiveEvidence
    public init(
        claude: [ClaudeLiveSessionSnapshot] = [],
        grok: [GrokActiveSessionRef] = [],
        pi: [PiLivePid] = [],
        antigravityPresentPids: [Int32] = []
    )
}

public enum FocusedSessionHostResolver {
    public static func resolveProcessId(
        focusedAgent: AgentKind,
        visibleSessions: [SessionSnapshot],
        hookSnapshots: [SessionSnapshot],
        paused: Bool,
        evidence: FocusedSessionLiveEvidence
    ) -> Int32?
}

public enum FocusedAgentActivator {
    public static func activate(
        focusedAgent: AgentKind,
        visibleSessions: [SessionSnapshot],
        hookSnapshots: [SessionSnapshot],
        paused: Bool,
        evidence: FocusedSessionLiveEvidence,
        processes: [Int32: HostProcessRecord],
        selfProcessId: Int32,
        activateCodex: () -> Void,
        activateHost: (Int32) -> Void
    )
}
```

Windows twins (same shapes, PascalCase):

```csharp
public sealed class HostProcessRecord
{
    public int ProcessId;
    public int ParentProcessId;
    public string Name;
    public bool IsRegularApp;
}

public static class ProcessTreeHostWalker
{
    public const int MaxDepth = 32;
    public static int? ResolveHost(
        int startingProcessId,
        IDictionary<int, HostProcessRecord> processes,
        int selfProcessId);
    public static bool ShouldSkipName(string name);
    public static bool IsKnownGuiName(string name);
}

public sealed class PiLivePid
{
    public string SessionId;
    public int ProcessId;
}

public sealed class FocusedSessionLiveEvidence
{
    public List<ClaudeLiveSessionRef> Claude;
    public List<GrokActiveSessionRef> Grok;
    public List<PiLivePid> Pi;
}

public static class FocusedSessionHostResolver
{
    public static int? ResolveProcessId(
        AgentKind focusedAgent,
        IList<SessionSnapshot> visibleSessions,
        IList<SessionSnapshot> hookSnapshots,
        bool paused,
        FocusedSessionLiveEvidence evidence);
}

public static class FocusedAgentActivator
{
    public static void Activate(
        AgentKind focusedAgent,
        IList<SessionSnapshot> visibleSessions,
        IList<SessionSnapshot> hookSnapshots,
        bool paused,
        FocusedSessionLiveEvidence evidence,
        IDictionary<int, HostProcessRecord> processes,
        int selfProcessId,
        Action activateCodex,
        Action<int> activateHost);
}

public sealed class ClaudeLiveSessionRef
{
    public string SessionId;
    public string WorkingDirectory;
    public int ProcessId;
    public DateTime UpdatedAtUtc;
}
```

`int?` on .NET 4.8 is `System.Nullable<int>`. Use `int` sentinel `0` if the file's surrounding style avoids nullable reference types; prefer `int?` when the file already uses it. If `csc` is the Framework 4.8 compiler without nullable annotations, return `0` for "none" and document that `0` means no host. **Lock this: Windows APIs return `int` where `0` means none.**

---

### Task 1: macOS process-tree walker

**Files:**
- Create: `src/macos/Sources/AgentHaloCore/ProcessTreeHostWalker.swift`
- Create: `src/macos/Sources/AgentHaloCoreChecks/FocusedSessionHostChecks.swift`
- Modify: `src/macos/Sources/AgentHaloCoreChecks/main.swift` (call `runFocusedSessionHostChecks()` after `testAggregateFiltersInactiveAndTimedOutSessions()`)

**Interfaces:**
- Consumes: nothing from later tasks
- Produces: `HostProcessRecord`, `ProcessTreeHostWalker.resolveHost`, `ProcessTreeHostWalker.shouldSkipName`, `ProcessTreeHostWalker.maxDepth`

- [ ] **Step 1: Write the failing checks**

Add `src/macos/Sources/AgentHaloCoreChecks/FocusedSessionHostChecks.swift`:

```swift
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
```

In `main.swift`, after `testAggregateFiltersInactiveAndTimedOutSessions()` add:

```swift
runFocusedSessionHostChecks()
```

- [ ] **Step 2: Run checks to verify they fail**

Run:

```bash
cd src/macos && swift run AgentHaloCoreChecks
```

Expected: compile error `cannot find 'ProcessTreeHostWalker' in scope` (or `HostProcessRecord`).

- [ ] **Step 3: Write the walker**

Create `src/macos/Sources/AgentHaloCore/ProcessTreeHostWalker.swift`:

```swift
import Foundation

public struct HostProcessRecord: Equatable, Sendable {
    public var processId: Int32
    public var parentProcessId: Int32
    public var name: String
    public var isRegularApp: Bool

    public init(
        processId: Int32,
        parentProcessId: Int32,
        name: String,
        isRegularApp: Bool
    ) {
        self.processId = processId
        self.parentProcessId = parentProcessId
        self.name = name
        self.isRegularApp = isRegularApp
    }
}

public enum ProcessTreeHostWalker {
    public static let maxDepth = 32

    private static let skipNames: Set<String> = [
        "claude", "grok", "pi", "agy", "node", "bun",
        "conhost", "openconsole", "wslrelay", "wslhost",
        "language_server", "agenthalo", "agenthalomac"
    ]

    public static func shouldSkipName(_ name: String) -> Bool {
        let normalized = normalize(name)
        if skipNames.contains(normalized) {
            return true
        }
        return normalized.hasSuffix(" helper")
    }

    public static func resolveHost(
        startingProcessId: Int32,
        processes: [Int32: HostProcessRecord],
        selfProcessId: Int32
    ) -> Int32? {
        var current = startingProcessId
        var visited = Set<Int32>()
        var depth = 0
        while current > 1, depth < maxDepth {
            if visited.contains(current) {
                return nil
            }
            visited.insert(current)
            guard let record = processes[current] else {
                return nil
            }
            let skipSelf = record.processId == selfProcessId
            if !skipSelf && !shouldSkipName(record.name) && record.isRegularApp {
                return record.processId
            }
            current = record.parentProcessId
            depth += 1
        }
        return nil
    }

    private static func normalize(_ name: String) -> String {
        var value = URL(fileURLWithPath: name).lastPathComponent.lowercased()
        if value.hasSuffix(".exe") {
            value = String(value.dropLast(4))
        }
        return value
    }
}
```

- [ ] **Step 4: Run checks to verify they pass**

Run:

```bash
cd src/macos && swift run AgentHaloCoreChecks
```

Expected: process exits 0. If a walker case fails, fix only the walker.

- [ ] **Step 5: Commit**

```bash
git add \
  src/macos/Sources/AgentHaloCore/ProcessTreeHostWalker.swift \
  src/macos/Sources/AgentHaloCoreChecks/FocusedSessionHostChecks.swift \
  src/macos/Sources/AgentHaloCoreChecks/main.swift
git commit -m "$(cat <<'EOF'
feat(macos): add process-tree walker for session host activation

Walk injected process records to the first regular GUI ancestor,
skipping CLI binaries, helpers, console pads, and Agent Halo itself.
EOF
)"
```

---

### Task 2: macOS session / PID resolver

**Files:**
- Create: `src/macos/Sources/AgentHaloCore/FocusedSessionHostResolver.swift`
- Modify: `src/macos/Sources/AgentHaloCoreChecks/FocusedSessionHostChecks.swift`

**Interfaces:**
- Consumes: `ClaudeLiveSessionSnapshot`, `ClaudeLiveSessionReader.preferredStandbySession`, `GrokActiveSessionRef`, `SessionSnapshot`, `AgentKind`
- Produces: `PiLivePid`, `FocusedSessionLiveEvidence`, `FocusedSessionHostResolver.resolveProcessId`

- [ ] **Step 1: Write the failing resolver checks**

Append to `runFocusedSessionHostChecks()` and add:

```swift
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
```

- [ ] **Step 2: Run checks to verify they fail**

Run:

```bash
cd src/macos && swift run AgentHaloCoreChecks
```

Expected: compile error `cannot find 'FocusedSessionHostResolver' in scope`.

- [ ] **Step 3: Write the resolver**

Create `src/macos/Sources/AgentHaloCore/FocusedSessionHostResolver.swift`:

```swift
import Foundation

public struct PiLivePid: Equatable, Sendable {
    public var sessionId: String
    public var processId: Int32

    public init(sessionId: String, processId: Int32) {
        self.sessionId = sessionId
        self.processId = processId
    }
}

public struct FocusedSessionLiveEvidence: Equatable, Sendable {
    public var claude: [ClaudeLiveSessionSnapshot]
    public var grok: [GrokActiveSessionRef]
    public var pi: [PiLivePid]
    public var antigravityPresentPids: [Int32]

    public static let empty = FocusedSessionLiveEvidence()

    public init(
        claude: [ClaudeLiveSessionSnapshot] = [],
        grok: [GrokActiveSessionRef] = [],
        pi: [PiLivePid] = [],
        antigravityPresentPids: [Int32] = []
    ) {
        self.claude = claude
        self.grok = grok
        self.pi = pi
        self.antigravityPresentPids = antigravityPresentPids
    }
}

public enum FocusedSessionHostResolver {
    public static func resolveProcessId(
        focusedAgent: AgentKind,
        visibleSessions: [SessionSnapshot],
        hookSnapshots: [SessionSnapshot],
        paused: Bool,
        evidence: FocusedSessionLiveEvidence
    ) -> Int32? {
        guard !paused else { return nil }
        switch focusedAgent {
        case .codex:
            return nil
        case .claudeCode:
            return claudePid(
                visibleSessions: visibleSessions,
                hookSnapshots: hookSnapshots,
                live: evidence.claude
            )
        case .grok:
            return grokPid(visibleSessions: visibleSessions, live: evidence.grok)
        case .pi:
            return piPid(
                visibleSessions: visibleSessions,
                hookSnapshots: hookSnapshots,
                live: evidence.pi
            )
        case .antigravity:
            let unique = Array(Set(evidence.antigravityPresentPids.filter { $0 > 0 }))
            return unique.count == 1 ? unique[0] : nil
        }
    }

    private static func claudePid(
        visibleSessions: [SessionSnapshot],
        hookSnapshots: [SessionSnapshot],
        live: [ClaudeLiveSessionSnapshot]
    ) -> Int32? {
        if let threadId = visibleSessions.first?.threadId,
           let match = live.first(where: { $0.sessionId == threadId }),
           match.processId > 0 {
            return match.processId
        }
        guard visibleSessions.isEmpty else { return nil }
        return ClaudeLiveSessionReader.preferredStandbySession(
            sessions: live,
            hookSnapshots: hookSnapshots
        ).flatMap { $0.processId > 0 ? $0.processId : nil }
    }

    private static func grokPid(
        visibleSessions: [SessionSnapshot],
        live: [GrokActiveSessionRef]
    ) -> Int32? {
        let withPid = live.filter { ($0.processId ?? 0) > 0 }
        if let snapshot = visibleSessions.first {
            if let exact = withPid.first(where: { $0.sessionId == snapshot.threadId }) {
                return exact.processId
            }
            if snapshot.threadId == "grok", withPid.count == 1 {
                return withPid[0].processId
            }
            let directory = normalizedDirectory(snapshot.workingDirectory)
            if !directory.isEmpty {
                let matched = withPid.filter {
                    normalizedDirectory($0.cwd ?? "") == directory
                }
                if matched.count == 1 {
                    return matched[0].processId
                }
            }
            return nil
        }
        return withPid.count == 1 ? withPid[0].processId : nil
    }

    private static func piPid(
        visibleSessions: [SessionSnapshot],
        hookSnapshots: [SessionSnapshot],
        live: [PiLivePid]
    ) -> Int32? {
        let liveById = Dictionary(
            live.filter { $0.processId > 0 && !$0.sessionId.isEmpty }
                .map { ($0.sessionId, $0.processId) },
            uniquingKeysWith: { _, latest in latest }
        )
        if let threadId = visibleSessions.first?.threadId {
            return liveById[threadId]
        }
        return hookSnapshots
            .filter { $0.agent == .pi && liveById[$0.threadId] != nil }
            .max(by: { $0.lastEventAt < $1.lastEventAt })
            .flatMap { liveById[$0.threadId] }
    }

    private static func normalizedDirectory(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return URL(fileURLWithPath: trimmed).standardizedFileURL.path
    }
}
```

- [ ] **Step 4: Run checks to verify they pass**

Run:

```bash
cd src/macos && swift run AgentHaloCoreChecks
```

Expected: exit 0.

- [ ] **Step 5: Commit**

```bash
git add \
  src/macos/Sources/AgentHaloCore/FocusedSessionHostResolver.swift \
  src/macos/Sources/AgentHaloCoreChecks/FocusedSessionHostChecks.swift
git commit -m "$(cat <<'EOF'
feat(macos): resolve focused session live pid for halo activation

Map the ring's visible or preferred standby session to a Claude,
Grok, Pi, or unique Antigravity pid without changing SessionSnapshot.
EOF
)"
```

---

### Task 3: macOS activator + AppDelegate wiring

**Files:**
- Create: `src/macos/Sources/AgentHaloCore/FocusedAgentActivator.swift`
- Modify: `src/macos/Sources/AgentHaloCoreChecks/FocusedSessionHostChecks.swift`
- Modify: `src/macos/Sources/AgentHaloMac/AppDelegate.swift`
- Modify: `src/macos/Sources/AgentHaloMac/HaloInteractionChecks.swift`

**Interfaces:**
- Consumes: `FocusedSessionHostResolver.resolveProcessId`, `ProcessTreeHostWalker.resolveHost`
- Produces: `FocusedAgentActivator.activate`; AppDelegate `activateFocusedAgent()`; `sessionHostActivator` / evidence / process-table seams

- [ ] **Step 1: Write the failing activator check**

Append to `FocusedSessionHostChecks.swift`:

```swift
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
```

Call both from `runFocusedSessionHostChecks()`.

- [ ] **Step 2: Run CoreChecks to verify they fail**

Run:

```bash
cd src/macos && swift run AgentHaloCoreChecks
```

Expected: `cannot find 'FocusedAgentActivator' in scope`.

- [ ] **Step 3: Write `FocusedAgentActivator`**

Create `src/macos/Sources/AgentHaloCore/FocusedAgentActivator.swift`:

```swift
import Foundation

public enum FocusedAgentActivator {
    public static func activate(
        focusedAgent: AgentKind,
        visibleSessions: [SessionSnapshot],
        hookSnapshots: [SessionSnapshot],
        paused: Bool,
        evidence: FocusedSessionLiveEvidence,
        processes: [Int32: HostProcessRecord],
        selfProcessId: Int32,
        activateCodex: () -> Void,
        activateHost: (Int32) -> Void
    ) {
        if focusedAgent == .codex {
            activateCodex()
            return
        }
        guard let pid = FocusedSessionHostResolver.resolveProcessId(
            focusedAgent: focusedAgent,
            visibleSessions: visibleSessions,
            hookSnapshots: hookSnapshots,
            paused: paused,
            evidence: evidence
        ) else {
            return
        }
        guard let hostPid = ProcessTreeHostWalker.resolveHost(
            startingProcessId: pid,
            processes: processes,
            selfProcessId: selfProcessId
        ) else {
            return
        }
        activateHost(hostPid)
    }
}
```

- [ ] **Step 4: Confirm CoreChecks pass**

Run:

```bash
cd src/macos && swift run AgentHaloCoreChecks
```

Expected: exit 0.

- [ ] **Step 5: Wire AppDelegate**

In `AppDelegate.swift`:

1. Add stored properties next to `codexActivator`:

```swift
private let sessionHostActivator: @MainActor (Int32) -> Void
var focusedSessionEvidenceProvider: () -> FocusedSessionLiveEvidence
var hostProcessTableProvider: () -> [Int32: HostProcessRecord]
```

2. Extend `init` (keep existing `codexActivator` default):

```swift
init(
    settingsStore: SettingsStore,
    codexActivator: @escaping @MainActor () -> Void = CodexAppDetector.activateCodex,
    sessionHostActivator: @escaping @MainActor (Int32) -> Void = { pid in
        NSRunningApplication(processIdentifier: pid)?
            .activate(options: [.activateIgnoringOtherApps])
    },
    usageCoordinator: UsageMonitoringCoordinator = .live()
) {
    self.settingsStore = settingsStore
    self.codexActivator = codexActivator
    self.sessionHostActivator = sessionHostActivator
    self.focusedSessionEvidenceProvider = { .empty }
    self.hostProcessTableProvider = { [:] }
    // existing body unchanged until the two providers are replaced after monitors start
```

After activity monitors exist in `applicationDidFinishLaunching`, assign production providers. Until then, `activateFocusedAgent()` for tests sets the providers directly.

Production evidence builder (private method):

```swift
func makeFocusedSessionEvidence() -> FocusedSessionLiveEvidence {
    FocusedSessionLiveEvidence(
        claude: claudeActivitySnapshot.liveSessions,
        grok: GrokActiveSessionsReader.liveSessions(),
        pi: piActivitySnapshot.livePids,
        antigravityPresentPids: AntigravityActivityMonitor.presentProcessIds()
    )
}
```

Pi needs real pids. Do **not** invent them from `SessionSnapshot`. Add `livePids: [PiLivePid]` on `PiActivitySnapshot` in this same step, filled from `PiStatusMonitor` records / runtime monitor (`sessionId` + `processId > 0`) at the same place `liveSessionIds` is assigned. Resolver tests already use injected evidence; this field is only for production wiring.

Add `AntigravityActivityMonitor.presentProcessIds() -> [Int32]` next to `hasPresentProcess()`: same scan (`agy` / `Antigravity` via `countsAsPresentProcess`), return matching pids. Do not include `language_server` or Helper.

Add `HostProcessTable.live() -> [Int32: HostProcessRecord]` in a new private section of `AppDelegate.swift` or a small `HostProcessTable.swift` under `AgentHaloMac`:

- `proc_listallpids` + `proc_pidinfo(PROC_PIDTBSDINFO)` for pid / ppid / comm (same style as `AntigravityActivityMonitor.hasPresentProcess`)
- `isRegularApp` from `NSRunningApplication(processIdentifier:)` `activationPolicy == .regular`
- never call `/bin/ps`

Default `hostProcessTableProvider = HostProcessTable.live` after launch. Tests overwrite the provider.

Replace `bringCodexForward` with:

```swift
func activateFocusedAgent() {
    let displayed = displayAggregate()
    FocusedAgentActivator.activate(
        focusedAgent: settings.focusedAgent,
        visibleSessions: displayed.sessions,
        hookSnapshots: hookSnapshots(for: settings.focusedAgent),
        paused: settings.paused,
        evidence: focusedSessionEvidenceProvider(),
        processes: hostProcessTableProvider(),
        selfProcessId: ProcessInfo.processInfo.processIdentifier,
        activateCodex: { [codexActivator] in codexActivator() },
        activateHost: { [sessionHostActivator] pid in sessionHostActivator(pid) }
    )
}

private func hookSnapshots(for agent: AgentKind) -> [SessionSnapshot] {
    switch agent {
    case .codex: return codexActivitySnapshot.sessions
    case .claudeCode: return claudeActivitySnapshot.sessions
    case .grok: return grokActivitySnapshot.sessions
    case .pi: return piActivitySnapshot.sessions
    case .antigravity: return antigravityActivitySnapshot.sessions
    }
}
```

Change `haloView.onDoubleClick` to `{ [weak self] in self?.activateFocusedAgent() }`.

Keep `handleHaloPrimaryClick()` empty. Update its comment to say double-click activates the focused session host.

If `displayAggregate()` is private and already the ring's visible aggregate, reuse it. Do not re-aggregate on a different code path.

- [ ] **Step 6: Update HaloInteractionChecks**

In `runHaloInteractionChecks()`, keep `testSingleClickDoesNotActivateCodex` and `testSingleClickDoesNotActivateCodexWhenClaudeCodeFocused`. Add:

```swift
testDoubleClickActivatesClaudeSessionHost()
testDoubleClickActivatesCodexDesktopPath()
```

Replace the line:

```swift
expect(!appDelegateSource.contains("activateGrok"), "Grok must not gain a click-to-activate terminal path")
```

with:

```swift
expect(
    appDelegateSource.contains("activateFocusedAgent()"),
    "double-click should activate the focused session host"
)
expect(
    !appDelegateSource.contains("handleHaloPrimaryClick() {"),
    "single-click handler must remain a named empty method"
)
```

New tests (use existing `temporarySettingsURL()`):

```swift
@MainActor
private func testDoubleClickActivatesClaudeSessionHost() {
    var hostPids: [Int32] = []
    let delegate = AppDelegate(
        settingsStore: SettingsStore(settingsURL: temporarySettingsURL()),
        sessionHostActivator: { hostPids.append($0) }
    )
    delegate.setFocusedAgent(.claudeCode)
    delegate.focusedSessionEvidenceProvider = {
        FocusedSessionLiveEvidence(
            claude: [
                ClaudeLiveSessionSnapshot(
                    sessionId: "s1",
                    workingDirectory: "/tmp/proj",
                    processId: 12,
                    status: "busy",
                    updatedAt: Date()
                )
            ]
        )
    }
    delegate.hostProcessTableProvider = {
        [
            10: HostProcessRecord(processId: 10, parentProcessId: 1, name: "iTerm2", isRegularApp: true),
            12: HostProcessRecord(processId: 12, parentProcessId: 10, name: "claude", isRegularApp: false)
        ]
    }
    delegate.activateFocusedAgent()
    expect(hostPids, [10], "Claude focus double-click activates iTerm")
    delegate.handleHaloPrimaryClick()
    expect(hostPids, [10], "single click still does not activate")
}

@MainActor
private func testDoubleClickActivatesCodexDesktopPath() {
    var codex = 0
    var hosts: [Int32] = []
    let delegate = AppDelegate(
        settingsStore: SettingsStore(settingsURL: temporarySettingsURL()),
        codexActivator: { codex += 1 },
        sessionHostActivator: { hosts.append($0) }
    )
    delegate.activateFocusedAgent()
    expect(codex, 1, "Codex focus still uses desktop activator")
    expect(hosts.isEmpty, true, "Codex focus does not walk a session host")
}
```

`setFocusedAgent(.claudeCode)` requires Claude to be enabled (default list includes it).

- [ ] **Step 7: Run macOS checks**

Run:

```bash
cd src/macos && swift run AgentHaloCoreChecks
cd src/macos && swift run AgentHaloMac --self-check
```

Expected: both exit 0.

- [ ] **Step 8: Commit**

```bash
git add \
  src/macos/Sources/AgentHaloCore/FocusedAgentActivator.swift \
  src/macos/Sources/AgentHaloCoreChecks/FocusedSessionHostChecks.swift \
  src/macos/Sources/AgentHaloMac/AppDelegate.swift \
  src/macos/Sources/AgentHaloMac/PiActivityMonitor.swift \
  src/macos/Sources/AgentHaloMac/AntigravityActivityMonitor.swift \
  src/macos/Sources/AgentHaloMac/HaloInteractionChecks.swift
git status --short
git commit -m "$(cat <<'EOF'
feat(macos): activate focused session host on halo double-click

Wire Claude, Grok, Pi, and Antigravity through the resolver and
process-tree walker. Codex keeps its desktop-app scan. Single-click
stays inert.
EOF
)"
```

Only add `PiActivityMonitor.swift` / `AntigravityActivityMonitor.swift` / `HostProcessTable.swift` if this task created or modified them.

---

### Task 4: Windows walker, Claude pid, resolver

**Files:**
- Create: `src/windows/ProcessTreeHostWalker.cs`
- Create: `src/windows/FocusedSessionHostResolver.cs`
- Modify: `src/windows/ClaudeCodeMonitor.cs` (`ClaudeLiveSessionReader`)
- Modify: `src/windows/Diagnostics.cs`

**Interfaces:**
- Consumes: existing `GrokActiveSessionRef`, `SessionSnapshot`, `AgentKind`
- Produces: Windows `HostProcessRecord`, `ProcessTreeHostWalker`, `FocusedSessionHostResolver`, `ClaudeLiveSessionRef`, `ClaudeLiveSessionReader.LiveSessions`, `PreferredStandbySession`

Windows `AgentKind` is `Codex | ClaudeCode | Grok | Pi` only. No Antigravity branch.

- [ ] **Step 1: Write failing Diagnostics assertions**

In `Diagnostics.RunSelfTest`, before `File.WriteAllText(outputPath, "PASS\n...` call `TestFocusedSessionHostActivation();`.

Add `TestFocusedSessionHostActivation` in `Diagnostics.cs` with the same cases as the macOS walker + resolver tests, using `Assert(...)`.

Include these exact assertions (names are the messages):

```csharp
HostProcessRecord[] iterm = new HostProcessRecord[]
{
    Rec(10, 1, "WindowsTerminal", true),
    Rec(11, 10, "zsh", false),
    Rec(12, 11, "claude", false)
};
Assert(ProcessTreeHostWalker.ResolveHost(12, Map(iterm), 99) == 10,
    "claude → zsh → WindowsTerminal");

Assert(ProcessTreeHostWalker.ResolveHost(22, Map(new HostProcessRecord[]
{
    Rec(20, 1, "Code", true),
    Rec(21, 20, "Code Helper", false),
    Rec(22, 21, "node", false)
}), 99) == 20, "node → Code Helper → Code");

Assert(ProcessTreeHostWalker.ResolveHost(30, Map(new HostProcessRecord[]
{
    Rec(30, 1, "WindowsTerminal", true)
}), 99) == 30, "regular start pid is the host");

Assert(ProcessTreeHostWalker.ResolveHost(41, Map(new HostProcessRecord[]
{
    Rec(40, 1, "sshd", false),
    Rec(41, 40, "agy", false)
}), 99) == 0, "agy under sshd has no GUI host");

Assert(ProcessTreeHostWalker.ResolveHost(81, Map(new HostProcessRecord[]
{
    Rec(80, 1, "AgentHalo", true),
    Rec(81, 80, "claude", false)
}), 80) == 0, "must not activate Agent Halo itself");

SessionSnapshot visible = ClaudeSnap("s-visible");
FocusedSessionLiveEvidence evidence = new FocusedSessionLiveEvidence();
evidence.Claude = new List<ClaudeLiveSessionRef>
{
    new ClaudeLiveSessionRef { SessionId = "s-other", ProcessId = 111, WorkingDirectory = "C:\\o", UpdatedAtUtc = DateTime.UtcNow },
    new ClaudeLiveSessionRef { SessionId = "s-visible", ProcessId = 222, WorkingDirectory = "C:\\p", UpdatedAtUtc = DateTime.UtcNow }
};
Assert(FocusedSessionHostResolver.ResolveProcessId(
    AgentKind.ClaudeCode, List(visible), List(visible), false, evidence) == 222,
    "visible Claude session wins");

Assert(FocusedSessionHostResolver.ResolveProcessId(
    AgentKind.Codex, new List<SessionSnapshot>(), new List<SessionSnapshot>(),
    false, new FocusedSessionLiveEvidence()) == 0,
    "Codex is not resolved via session pid");

Assert(FocusedSessionHostResolver.ResolveProcessId(
    AgentKind.ClaudeCode, List(visible), List(visible), true, evidence) == 0,
    "paused does not activate");

GrokActiveSessionRef grok = new GrokActiveSessionRef
{
    SessionId = "live-id",
    WorkingDirectory = "C:\\ws",
    ProcessId = 404
};
evidence = new FocusedSessionLiveEvidence();
evidence.Grok = new List<GrokActiveSessionRef> { grok };
SessionSnapshot grokHook = new SessionSnapshot
{
    ThreadId = "hook-id",
    WorkingDirectory = "C:\\ws",
    Agent = AgentKind.Grok,
    State = HaloState.Thinking,
    Active = true,
    LastEventUtc = DateTime.UtcNow,
    ProjectName = "ws",
    Action = "Thinking"
};
Assert(FocusedSessionHostResolver.ResolveProcessId(
    AgentKind.Grok, List(grokHook), List(grokHook), false, evidence) == 404,
    "Grok workspace match supplies the live pid");

GrokActiveSessionRef noPid = new GrokActiveSessionRef
{
    SessionId = "abc",
    WorkingDirectory = "C:\\ws",
    ProcessId = 0
};
evidence.Grok = new List<GrokActiveSessionRef> { noPid };
SessionSnapshot grokExact = new SessionSnapshot
{
    ThreadId = "abc",
    WorkingDirectory = "C:\\ws",
    Agent = AgentKind.Grok,
    State = HaloState.Thinking,
    Active = true,
    LastEventUtc = DateTime.UtcNow,
    ProjectName = "ws",
    Action = "Thinking"
};
Assert(FocusedSessionHostResolver.ResolveProcessId(
    AgentKind.Grok, List(grokExact), List(grokExact), false, evidence) == 0,
    "Grok entry without pid does not activate");
```

Add Claude live reader assertions immediately after the existing live/dead session block around line 1125:

```csharp
List<ClaudeLiveSessionRef> liveRefs =
    ClaudeLiveSessionReader.LiveSessions(liveHome);
Assert(liveRefs.Count == 1 && liveRefs[0].SessionId == "live" &&
    liveRefs[0].ProcessId == Process.GetCurrentProcess().Id,
    "Claude live session reader exposes pid");
```

Keep the existing `LiveSessionIds` assertions.

Add `PreferredStandbySession` assertion with two live files (different `updatedAt`) plus two idle hook snapshots; expect the newer hook's pid.

Because this is TDD on Windows only: if you are on macOS, still write the test method so a Windows build fails until the types exist.

- [ ] **Step 2: Confirm the Windows build fails (Windows host)**

Run:

```powershell
.\scripts\build-windows.ps1
.\outputs\AgentHalo\AgentHalo.exe --self-test $env:TEMP\agent-halo-self-test.txt
```

Expected: compile errors for missing `ProcessTreeHostWalker` / `FocusedSessionHostResolver` / `LiveSessions` returning refs.

On macOS, skip this command.

- [ ] **Step 3: Implement Windows walker + Claude pid + resolver**

`ProcessTreeHostWalker.cs` — same algorithm as the Swift walker. `ResolveHost` returns `0` when none. `ShouldSkipName` uses the same skip set. Add:

```csharp
public static bool IsKnownGuiName(string name)
{
    string normalized = Normalize(name);
    return normalized == "windowsterminal"
        || normalized == "code"
        || normalized == "cursor"
        || normalized == "devenv"
        || normalized == "wezterm-gui"
        || normalized == "tabby"
        || normalized == "alacritty"
        || normalized == "hyper"
        || normalized == "fluentterminal";
}
```

`IsKnownGuiName` is for `HostProcessTable` in Task 5, not for the walker itself. The walker only trusts `IsRegularApp`.

`ClaudeLiveSessionReader`:
- Add `ClaudeLiveSessionRef`.
- Replace `TryReadLiveSessionId` with `TryReadLiveSession` that fills SessionId, ProcessId, WorkingDirectory (`cwd`), UpdatedAtUtc (`updatedAt` / `statusUpdatedAt` milliseconds like macOS).
- `LiveSessions(home)` returns live refs (pid alive via `GetProcessById`, same status filter: busy / waiting / idle).
- `LiveSessionIds` becomes a projection of `LiveSessions`.
- Add `PreferredStandbySession(List<ClaudeLiveSessionRef> sessions, IList<SessionSnapshot> hookSnapshots)` matching `ClaudeLiveSessionReader.preferredStandbySession` (newest matching hook `LastEventUtc`, then newest `UpdatedAtUtc`).

`FocusedSessionHostResolver.cs` — port the Swift resolver:
- Codex / paused → 0
- Claude visible `ThreadId` match, else preferred standby when `visibleSessions` empty
- Grok exact id, then `ThreadId == "grok"` with exactly one pid, then unique normalized workspace
- Pi visible `ThreadId`, else newest hook snapshot whose id is live
- Normalize directories with `Path.GetFullPath` / trim slashes, case-insensitive

`FocusedSessionLiveEvidence` fields must be initialized to empty lists in a constructor so tests do not hit null.

- [ ] **Step 4: Run Windows self-test (Windows host)**

```powershell
.\scripts\build-windows.ps1
.\outputs\AgentHalo\AgentHalo.exe --self-test $env:TEMP\agent-halo-self-test.txt
```

Expected: file contains `PASS`.

- [ ] **Step 5: Commit**

```bash
git add \
  src/windows/ProcessTreeHostWalker.cs \
  src/windows/FocusedSessionHostResolver.cs \
  src/windows/ClaudeCodeMonitor.cs \
  src/windows/Diagnostics.cs
git commit -m "$(cat <<'EOF'
feat(windows): resolve focused session live pid for halo activation

Add a process-tree walker and session pid resolver. Claude live
sessions now expose pid for double-click activation only.
EOF
)"
```

---

### Task 5: Windows activator + HaloWindow double-click

**Files:**
- Create: `src/windows/FocusedAgentActivator.cs`
- Modify: `src/windows/HaloWindow.cs`
- Modify: `src/windows/Diagnostics.cs`

**Interfaces:**
- Consumes: `FocusedSessionHostResolver.ResolveProcessId`, `ProcessTreeHostWalker.ResolveHost`, `BringCodexForward` window APIs
- Produces: `FocusedAgentActivator.Activate`; `HaloWindow.OnDoubleClick` calls it

- [ ] **Step 1: Write failing activator assertions**

In `TestFocusedSessionHostActivation` add:

```csharp
int host = 0;
int codex = 0;
Dictionary<int, HostProcessRecord> processes = Map(new HostProcessRecord[]
{
    Rec(10, 1, "WindowsTerminal", true),
    Rec(12, 10, "claude", false)
});
FocusedSessionLiveEvidence evidence = new FocusedSessionLiveEvidence();
evidence.Claude = new List<ClaudeLiveSessionRef>
{
    new ClaudeLiveSessionRef
    {
        SessionId = "s1",
        ProcessId = 12,
        WorkingDirectory = "C:\\p",
        UpdatedAtUtc = DateTime.UtcNow
    }
};
FocusedAgentActivator.Activate(
    AgentKind.ClaudeCode,
    List(ClaudeSnap("s1")),
    new List<SessionSnapshot>(),
    false,
    evidence,
    processes,
    99,
    delegate { codex++; },
    delegate(int pid) { host = pid; });
Assert(host == 10 && codex == 0, "Windows activator walks Claude pid to terminal");

host = 0;
FocusedAgentActivator.Activate(
    AgentKind.Codex,
    new List<SessionSnapshot>(),
    new List<SessionSnapshot>(),
    false,
    new FocusedSessionLiveEvidence(),
    processes,
    99,
    delegate { codex++; },
    delegate(int pid) { host = pid; });
Assert(codex == 1 && host == 0, "Codex focus uses desktop activator only");
```

- [ ] **Step 2: Confirm fail on Windows**

```powershell
.\scripts\build-windows.ps1
```

Expected: missing `FocusedAgentActivator`.

- [ ] **Step 3: Implement activator + window wiring**

`FocusedAgentActivator.cs`:

```csharp
public static class FocusedAgentActivator
{
    public static void Activate(
        AgentKind focusedAgent,
        IList<SessionSnapshot> visibleSessions,
        IList<SessionSnapshot> hookSnapshots,
        bool paused,
        FocusedSessionLiveEvidence evidence,
        IDictionary<int, HostProcessRecord> processes,
        int selfProcessId,
        Action activateCodex,
        Action<int> activateHost)
    {
        if (focusedAgent == AgentKind.Codex)
        {
            if (activateCodex != null)
            {
                activateCodex();
            }
            return;
        }
        int pid = FocusedSessionHostResolver.ResolveProcessId(
            focusedAgent, visibleSessions, hookSnapshots, paused, evidence);
        if (pid <= 0)
        {
            return;
        }
        int hostPid = ProcessTreeHostWalker.ResolveHost(
            pid, processes, selfProcessId);
        if (hostPid <= 0 || activateHost == null)
        {
            return;
        }
        activateHost(hostPid);
    }
}
```

In `HaloWindow.OnDoubleClick`:

```csharp
private void OnDoubleClick(object sender, MouseButtonEventArgs e)
{
    ActivateFocusedAgent();
    e.Handled = true;
}

private void ActivateFocusedAgent()
{
    AgentKind focused = settings.GetFocusedAgent();
    FocusedAgentActivator.Activate(
        focused,
        aggregate != null && aggregate.Sessions != null
            ? aggregate.Sessions
            : new List<SessionSnapshot>(),
        HookSnapshots(focused),
        settings.Paused,
        CollectLiveEvidence(focused),
        HostProcessTable.Live(),
        Process.GetCurrentProcess().Id,
        BringCodexForward,
        ActivateHostProcess);
}

private void ActivateHostProcess(int processId)
{
    try
    {
        using (Process process = Process.GetProcessById(processId))
        {
            if (process.MainWindowHandle != IntPtr.Zero)
            {
                ShowWindow(process.MainWindowHandle, 9);
                SetForegroundWindow(process.MainWindowHandle);
                return;
            }
        }
        // Known GUI with no MainWindowHandle yet: reuse title/process scan
        // only for this pid — do not fall back to unrelated windows.
    }
    catch (Exception ex)
    {
        SettingsStorage.Log("Bring session host forward failed: " + ex.Message);
    }
}
```

`CollectLiveEvidence`:
- Claude: `ClaudeLiveSessionReader.LiveSessions()`
- Grok: `GrokActiveSessionsReader.LiveSessions(home)`
- Pi: from `piMonitor` live records (`SessionId` + `ProcessId` where `ProcessId > 0`)

`HookSnapshots(focused)` returns the in-memory hook snapshots already held for that agent (same lists `RefreshState` aggregates). Do not reread JSONL on the click beyond the existing live readers.

`HostProcessTable.Live()` (put in `ProcessTreeHostWalker.cs` as a nested static class or a sibling `HostProcessTable`):
- Toolhelp32 snapshot for pid / parent / name (copy the existing `PiRuntimeMonitor` snapshot pattern)
- `IsRegularApp = has main window || ProcessTreeHostWalker.IsKnownGuiName(name)`
- Getting a main window: `Process.GetProcessById` inside try/catch; empty handle is fine
- Skip spawning other processes

`BringCodexForward` stays as-is for the Codex desktop scan.

- [ ] **Step 4: Run Windows self-test**

```powershell
.\scripts\build-windows.ps1
.\outputs\AgentHalo\AgentHalo.exe --self-test $env:TEMP\agent-halo-self-test.txt
```

Expected: `PASS`.

- [ ] **Step 5: Commit**

```bash
git add \
  src/windows/FocusedAgentActivator.cs \
  src/windows/ProcessTreeHostWalker.cs \
  src/windows/HaloWindow.cs \
  src/windows/Diagnostics.cs \
  src/windows/PiMonitor.cs
git commit -m "$(cat <<'EOF'
feat(windows): activate focused session host on halo double-click

Claude, Grok, and Pi double-click walk the live session pid to its
GUI host. Codex keeps the existing desktop window scan.
EOF
)"
```

Only add `PiMonitor.cs` if you had to expose live pid records.

---

### Task 6: Docs

**Files:**
- Modify: `README.md`
- Modify: `README.zh-CN.md`
- Modify: `docs/PRODUCT.md`
- Modify: `AGENTS.md`
- Modify: `docs/superpowers/specs/2026-07-25-macos-grok-build-usage-lifecycle-design.md`
- Modify: `docs/superpowers/specs/2026-07-29-windows-grok-build-parity-design.md`
- Modify: `docs/superpowers/specs/2026-08-14-antigravity-agent-macos-design.md`
- Modify: `docs/superpowers/specs/2026-08-18-focused-agent-host-activation-design.md`

**Interfaces:**
- Consumes: shipped behavior from Tasks 3 and 5
- Produces: user-facing copy that matches double-click host activation

- [ ] **Step 1: Update user-facing docs**

`README.md` Quick usage bullet:

```markdown
- **Double-click** the halo to bring the focused agent's session host forward (Codex app, or the terminal / desktop app hosting Claude, Grok, Pi, or Antigravity). Nothing happens if that host cannot be found.
```

`README.zh-CN.md`:

```markdown
- **双击**光环会把当前聚焦 Agent 对应会话的宿主带到前台（Codex 桌面应用，或托管 Claude / Grok / Pi / Antigravity 的终端 / 桌面应用）。找不到宿主时无操作。
```

`docs/PRODUCT.md` Focused Agent paragraph — replace the last sentence:

```markdown
Synthetic Codex failure surfacing stays scoped to Codex focus. Double-clicking the halo brings the focused agent's session host forward: Codex still uses its desktop-app scan; Claude, Grok, Pi, and Antigravity walk the live session pid to the hosting terminal or desktop app, and do nothing when no pid or host exists.
```

`AGENTS.md` UI constraint:

```markdown
- Click / double-click halo: double-click brings the focused agent's session host forward (Codex desktop app, or the GUI host of the live Claude / Grok / Pi / Antigravity session). Single-click does not activate. No tab targeting and no app launch.
```

- [ ] **Step 2: Point old specs at the new design**

In each of these non-goal bullets, keep the original sentence and append `（已被 [2026-08-18-focused-agent-host-activation-design.md](./2026-08-18-focused-agent-host-activation-design.md) 取代。）`:

- `docs/superpowers/specs/2026-07-25-macos-grok-build-usage-lifecycle-design.md` — 「点击光环 foreground Grok 终端窗口。」
- `docs/superpowers/specs/2026-07-29-windows-grok-build-parity-design.md` — 「点击光环 foreground Grok 终端窗口。」
- `docs/superpowers/specs/2026-08-14-antigravity-agent-macos-design.md` — 「点击光环唤起 Antigravity 窗口或终端。」 and the later 「点击光环：不激活任何 Antigravity 窗口（与 Claude 相同）」

In `2026-08-18-focused-agent-host-activation-design.md` header, set:

```markdown
- 状态：实施计划见 [2026-08-19-focused-agent-host-activation.md](../plans/2026-08-19-focused-agent-host-activation.md)
```

- [ ] **Step 3: Re-run macOS checks (docs-only, confirm no stray test still forbids activation)**

```bash
cd src/macos && swift run AgentHaloMac --self-check
```

Expected: exit 0. If a source-contains check still says Grok/Claude must not activate, fix it in this commit (that is a Task 3 miss).

- [ ] **Step 4: Commit**

```bash
git add \
  README.md README.zh-CN.md docs/PRODUCT.md AGENTS.md \
  docs/superpowers/specs/2026-07-25-macos-grok-build-usage-lifecycle-design.md \
  docs/superpowers/specs/2026-07-29-windows-grok-build-parity-design.md \
  docs/superpowers/specs/2026-08-14-antigravity-agent-macos-design.md \
  docs/superpowers/specs/2026-08-18-focused-agent-host-activation-design.md
git commit -m "$(cat <<'EOF'
docs: describe focused-agent host activation on double-click

User docs and older specs now match double-click activation of the
session host for every focused agent.
EOF
)"
```

---

## Self-review

**Spec coverage**

| Spec requirement | Task |
| --- | --- |
| Double-click activates focused session host | 3, 5 |
| Codex stays desktop-app scan | 2, 3, 4, 5 |
| Claude / Grok / Pi pid from existing readers | 2, 4 |
| Antigravity exactly one present process | 2, 3 |
| No PID / dead / no host → silent | 1–5 |
| Process walk, skip CLI/helpers/conhost/self, max 32, no cycles | 1, 4 |
| No `SessionSnapshot.processId` | all |
| No tick-time walk / no `ps` | 3, 5 |
| Single-click inert | 3 |
| Windows + macOS | 1–5 |
| Docs / old specs | 6 |
| Tests for session pick, STANDBY, Grok workspace, Antigravity ambiguity | 2, 4 |

**Placeholder scan:** no TBD / “handle edge cases” / “similar to Task N” without code.

**Type consistency:** `HostProcessRecord`, `ProcessTreeHostWalker.resolveHost` / `ResolveHost`, `FocusedSessionLiveEvidence`, `FocusedSessionHostResolver.resolveProcessId` / `ResolveProcessId`, `FocusedAgentActivator.activate` / `Activate`, `PiLivePid`, `ClaudeLiveSessionRef` are used with the same names in later tasks. Windows “none” sentinel is `0`.
