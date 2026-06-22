# Superseded Session Error Display Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove an interrupted session from the current halo display after a different, newer meaningful session supersedes it, without deleting raw history.

**Architecture:** Add a pure superseded-error filter at the aggregation boundary on macOS and Windows. Run it before existing visibility, priority, count, and realtime-blocking logic; leave raw monitor accessors unchanged.

**Tech Stack:** Swift 6/SwiftPM, C# WPF, executable self-check harnesses.

---

## File Map

- `src/macos/Sources/AgentHaloCore/SessionAggregator.swift`: macOS display filter.
- `src/macos/Sources/AgentHaloCoreChecks/main.swift`: macOS regression coverage.
- `src/windows/CodexMonitor.cs`: Windows display filter.
- `src/windows/Diagnostics.cs`: Windows self-check coverage.
- `docs/CROSS_PLATFORM_SHARED_CONTRACT.md`: shared semantics.

### Task 1: Add failing macOS regressions

**Files:**
- Test: `src/macos/Sources/AgentHaloCoreChecks/main.swift`

- [ ] **Step 1: Write the failing test**

Add `testAggregateRemovesSupersededSessionErrors()` near the aggregation tests. Use explicit timestamps and `SessionSnapshot` values to assert:

```swift
let working = SessionAggregator.aggregate(
    snapshots: [oldError, newerWorking],
    settings: settings,
    now: now
)
expect(working.state, .working, "newer working session replaces old error")
expect(working.sessions.map(\.threadId), ["new-working"], "old error removed")

let done = SessionAggregator.aggregate(
    snapshots: [oldError, newerDone],
    settings: settings,
    now: now
)
expect(done.sessions.map(\.threadId), ["new-done"], "newer done replaces old error")

let acknowledged = settings.acknowledgingCompletedSessions([newerDone])
let ready = SessionAggregator.aggregate(
    snapshots: [oldError, newerDone],
    settings: acknowledged,
    now: now
)
expect(ready.state, .idle, "acknowledged done does not resurrect old error")
expect(ready.sessions.isEmpty, "superseded error remains absent")
```

In the same function assert that a newer error remains primary while an older active session stays secondary, and that a newer metadata-only idle session does not suppress an error. Call the test from the executable test list.

- [ ] **Step 2: Run the test and verify RED**

Run: `cd src/macos && swift run AgentHaloCoreChecks`

Expected: failure at `newer working session replaces old error`, with `.error` instead of `.working`.

### Task 2: Implement the macOS filter

**Files:**
- Modify: `src/macos/Sources/AgentHaloCore/SessionAggregator.swift`
- Test: `src/macos/Sources/AgentHaloCoreChecks/main.swift`

- [ ] **Step 1: Add the minimal implementation**

Filter `focusedSnapshots` before the existing visibility chain:

```swift
let displayCandidates = focusedSnapshots.filter { snapshot in
    !isSupersededError(snapshot, among: focusedSnapshots)
}
```

Add these helpers:

```swift
private static func isSupersededError(
    _ snapshot: SessionSnapshot,
    among snapshots: [SessionSnapshot]
) -> Bool {
    guard snapshot.state == .error else { return false }
    return snapshots.contains { candidate in
        candidate.agent == snapshot.agent
            && candidate.threadId != snapshot.threadId
            && isMeaningful(candidate)
            && candidate.lastEventAt > snapshot.lastEventAt
    }
}

private static func isMeaningful(_ snapshot: SessionSnapshot) -> Bool {
    snapshot.active || snapshot.state == .done || snapshot.state == .error
}
```

- [ ] **Step 2: Run the test and verify GREEN**

Run: `cd src/macos && swift run AgentHaloCoreChecks`

Expected: output ends with `AgentHaloCoreChecks PASS`.

- [ ] **Step 3: Commit macOS changes**

Run: `git add src/macos/Sources/AgentHaloCore/SessionAggregator.swift src/macos/Sources/AgentHaloCoreChecks/main.swift && git commit -m "fix: hide superseded session errors on macOS"`

### Task 3: Add Windows parity

**Files:**
- Modify: `src/windows/CodexMonitor.cs`
- Test: `src/windows/Diagnostics.cs`

- [ ] **Step 1: Write Windows self-check assertions**

Create an `old-error` and `new-working` list in `Diagnostics.RunSelfTest`, call `CodexSessionMonitor.WithoutSupersededErrors`, and assert that only `new-working` is returned while the input list still contains both snapshots. Add equivalent newer-done, acknowledged-newer-done, latest-error, and metadata-only assertions. Model acknowledgement by applying the existing done-visibility predicate after supersession and assert that the result is empty rather than resurrecting `old-error`.

```csharp
List<SessionSnapshot> display =
    CodexSessionMonitor.WithoutSupersededErrors(input);
Assert(display.Count == 1 && display[0].ThreadId == "new-working",
    "newer Windows session removes old interrupted display state");
Assert(input.Count == 2, "Windows filter preserves raw sessions");
```

- [ ] **Step 2: Add the minimal Windows filter**

```csharp
internal static List<SessionSnapshot> WithoutSupersededErrors(
    IEnumerable<SessionSnapshot> snapshots)
{
    List<SessionSnapshot> all = snapshots.ToList();
    return all.Where(delegate(SessionSnapshot snapshot)
    {
        if (snapshot.State != HaloState.Error) return true;
        return !all.Any(delegate(SessionSnapshot candidate)
        {
            bool meaningful = candidate.Active ||
                candidate.State == HaloState.Done ||
                candidate.State == HaloState.Error;
            return candidate.Agent == snapshot.Agent &&
                !String.Equals(candidate.ThreadId, snapshot.ThreadId,
                    StringComparison.OrdinalIgnoreCase) &&
                meaningful && candidate.LastEventUtc > snapshot.LastEventUtc;
        });
    }).ToList();
}
```

Clone all tracker snapshots into `rawSessions`, pass them through the helper, and only then apply the existing visibility and ordering chain. Do not change `GetAllRecent`.

- [ ] **Step 3: Verify Windows as far as the host permits**

Run the Windows build and `--self-check` in a Windows/.NET environment and expect exit code `0` plus `PASS`. On this macOS host, probe `dotnet`, `csc`, `mcs`, and `pwsh`; if unavailable, run `git diff --check`, inspect the full C# diff, and report the compilation limitation explicitly.

- [ ] **Step 4: Commit Windows changes**

Run: `git add src/windows/CodexMonitor.cs src/windows/Diagnostics.cs && git commit -m "fix: hide superseded session errors on Windows"`

### Task 4: Document and verify the shared behavior

**Files:**
- Modify: `docs/CROSS_PLATFORM_SHARED_CONTRACT.md`

- [ ] **Step 1: Update the shared contract**

Document the four supersession predicates, filtering-before-sorting requirement, non-resurrection after acknowledgement, and unchanged raw/recent snapshot APIs.

- [ ] **Step 2: Run fresh macOS verification**

Run:

```bash
cd src/macos
swift run AgentHaloCoreChecks
swift run AgentHaloMac --self-check
swift build
cd ../..
git diff --check
scripts/run-macos.sh --verify
```

Expected: both self-checks print `PASS`, the build exits `0`, diff check is silent, and staged-app verification succeeds.

- [ ] **Step 3: Review scope**

Run: `git status --short && git diff --stat HEAD~2`

Confirm that no reducer, generated visual specification, priority, raw accessor, or unrelated UI file changed.

- [ ] **Step 4: Commit contract documentation**

Run: `git add docs/CROSS_PLATFORM_SHARED_CONTRACT.md && git commit -m "docs: define superseded session error semantics"`
