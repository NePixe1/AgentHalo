# Claude Main-Session Details Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep Claude subagent activity visible in the halo while showing project, model, tokens, and context from the associated main Claude session, without disrupting ccline.

**Architecture:** Keep hook snapshots as the lifecycle authority, then use their main `sessionId` only as a join key. Capture status-line input into atomic per-session files, resolve the same ID against non-subagent transcript snapshots for the project, and refresh the visible panel in place. Periodically reconcile `~/.claude/settings.json` so the chain remains `Claude -> AgentHalo proxy -> ccline` after external settings rewrites.

**Tech Stack:** Swift 6, Foundation/AppKit, SwiftPM executable checks, Claude Code hooks/status-line JSON, atomic filesystem writes.

---

## File Map

- Modify `src/macos/Sources/AgentHaloCore/ClaudeContextUsageConstants.swift`: define the five-minute snapshot freshness contract.
- Modify `src/macos/Sources/AgentHaloCore/ClaudeContextUsage.swift`: add path-safe per-session storage and exact-ID reads with legacy migration fallback.
- Modify `src/macos/Sources/AgentHaloCore/ClaudeStatusLineProxyRuntime.swift`: write the parsed snapshot into its session-scoped file.
- Modify `src/macos/Sources/ClaudeCodeStatusLineProxy/main.swift`: use the snapshot directory and continue forwarding the original input to ccline.
- Modify `src/macos/Sources/AgentHaloCore/ClaudeStatusLineConfigurator.swift`: expose a cheap configuration check used for reconciliation.
- Create `src/macos/Sources/AgentHaloCore/ClaudeMainSessionDetailsResolver.swift`: combine an exact main transcript snapshot with an exact usage snapshot.
- Modify `src/macos/Sources/AgentHaloMac/AppDelegate.swift`: refresh main transcripts, reconcile the proxy, resolve main-session details, and refresh visible metadata in place.
- Modify `src/macos/Sources/AgentHaloCoreChecks/main.swift`: executable regression coverage for storage, proxy, reconciliation, and resolution.
- Modify `src/macos/Sources/AgentHaloMac/HaloInteractionChecks.swift`: executable regression coverage for AppDelegate presentation and live panel refresh wiring.

No Windows or shared-spec files change.

### Task 1: Add exact per-session usage storage and freshness

**Files:**
- Modify: `src/macos/Sources/AgentHaloCore/ClaudeContextUsageConstants.swift`
- Modify: `src/macos/Sources/AgentHaloCore/ClaudeContextUsage.swift`
- Test: `src/macos/Sources/AgentHaloCoreChecks/main.swift`

- [ ] **Step 1: Register and write failing storage tests**

Add these calls beside the existing Claude context tests in the top-level check runner:

```swift
try testClaudeContextUsageStorageSeparatesSessionsAndRejectsUnsafeIds()
try testClaudeContextUsageReaderRequiresExactFreshSession()
try testClaudeContextUsageReaderMigratesMatchingLegacySnapshot()
```

Add focused tests using a temporary directory:

```swift
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

    let now = ISO8601DateFormatter().date(from: "2026-06-23T02:00:00Z")!
    let a = ClaudeContextUsageSnapshot(
        sessionId: "session-a",
        usedPercent: 26.5,
        modelName: "glm-latest",
        inputTokens: 53_100,
        outputTokens: 1_200,
        updatedAt: now
    )
    let b = ClaudeContextUsageSnapshot(
        sessionId: "session-b",
        usedPercent: 80,
        updatedAt: now
    )
    try ClaudeContextUsageStorage.write(a, directory: root)
    try ClaudeContextUsageStorage.write(b, directory: root)

    let reader = ClaudeContextUsageReader(snapshotsDirectory: root, legacySnapshotURL: nil)
    expect(reader.read(sessionId: "session-a", now: now)?.usedPercent, 26.5, "exact session usage")
    expect(reader.read(sessionId: "missing", now: now) == nil, "another session must not be substituted")
    expect(
        reader.read(sessionId: "session-a", now: now.addingTimeInterval(301)) == nil,
        "usage older than five minutes must be rejected"
    )
}

func testClaudeContextUsageReaderMigratesMatchingLegacySnapshot() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agent-halo-legacy-usage-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let legacyURL = root.appendingPathComponent("claude-code-context.json")
    let now = ISO8601DateFormatter().date(from: "2026-06-23T02:00:00Z")!
    let legacy = ClaudeContextUsageSnapshot(sessionId: "legacy-main", usedPercent: 31, updatedAt: now)
    try JSONEncoder().encode(legacy).write(to: legacyURL)

    let reader = ClaudeContextUsageReader(
        snapshotsDirectory: root.appendingPathComponent("contexts", isDirectory: true),
        legacySnapshotURL: legacyURL
    )
    expect(reader.read(sessionId: "legacy-main", now: now)?.usedPercent, 31, "matching legacy fallback")
    expect(reader.read(sessionId: "other-main", now: now) == nil, "mismatched legacy fallback")
}
```

- [ ] **Step 2: Run the core checks and verify RED**

Run:

```bash
cd src/macos
swift run AgentHaloCoreChecks
```

Expected: compilation fails because `ClaudeContextUsageStorage`, the directory-based reader initializer, and `read(sessionId:now:)` do not exist.

- [ ] **Step 3: Implement path-safe storage and exact reads**

Add to `ClaudeContextUsageConstants`:

```swift
public static let snapshotMaxAge: TimeInterval = 300
```

Add this storage boundary to `ClaudeContextUsage.swift`:

```swift
public enum ClaudeContextUsageStorage {
    public static func snapshotURL(directory: URL, sessionId: String) -> URL? {
        guard !sessionId.isEmpty,
              sessionId.count <= 128,
              sessionId.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.")).contains($0)
              }) else {
            return nil
        }
        return directory.appendingPathComponent("\(sessionId).json")
    }

    public static func write(_ snapshot: ClaudeContextUsageSnapshot, directory: URL) throws {
        guard let url = snapshotURL(directory: directory, sessionId: snapshot.sessionId) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try JSONEncoder().encode(snapshot).write(to: url, options: [.atomic])
    }
}
```

Refactor `ClaudeContextUsageReader` to hold `snapshotsDirectory` plus an optional `legacySnapshotURL`, and implement an exact read:

```swift
public func read(sessionId: String, now: Date = Date()) -> ClaudeContextUsageSnapshot? {
    guard let sessionURL = ClaudeContextUsageStorage.snapshotURL(
        directory: snapshotsDirectory,
        sessionId: sessionId
    ) else {
        return nil
    }

    let snapshot = readSnapshot(at: sessionURL) ?? legacySnapshot(matching: sessionId)
    guard let snapshot, snapshot.sessionId == sessionId else { return nil }
    let age = now.timeIntervalSince(snapshot.updatedAt)
    guard age >= -ClaudeContextUsageConstants.clockSkewTolerance,
          age <= ClaudeContextUsageConstants.snapshotMaxAge else {
        return nil
    }
    return snapshot
}
```

Keep the existing file URL in the default initializer only as the migration fallback:

```swift
public init(
    snapshotsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".agent-halo/claude-code-contexts", isDirectory: true),
    legacySnapshotURL: URL? = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".agent-halo/claude-code-context.json")
) {
    self.snapshotsDirectory = snapshotsDirectory
    self.legacySnapshotURL = legacySnapshotURL
}
```

Cache entries by standardized file URL, not as one shared snapshot. Update or replace the old `read(sessionIds:)` tests so they assert the exact-ID and five-minute behavior above. Keep this compilation-only overload until Task 5 updates all AppDelegate call sites:

```swift
public func read(sessionIds: [String], now: Date = Date()) -> ClaudeContextUsageSnapshot? {
    guard sessionIds.count == 1, let sessionId = sessionIds.first else {
        return nil
    }
    return read(sessionId: sessionId, now: now)
}
```

Delete that overload in Task 5 after `AppDelegate` and its interaction checks use `read(sessionId:now:)`. Empty or multi-ID requests must never select an arbitrary snapshot.

- [ ] **Step 4: Run the core checks and verify GREEN**

Run:

```bash
cd src/macos
swift run AgentHaloCoreChecks
```

Expected: `PASS AgentHaloCore checks`.

- [ ] **Step 5: Commit the storage boundary**

```bash
git add src/macos/Sources/AgentHaloCore/ClaudeContextUsageConstants.swift \
  src/macos/Sources/AgentHaloCore/ClaudeContextUsage.swift \
  src/macos/Sources/AgentHaloCoreChecks/main.swift
git commit -m "fix: isolate Claude usage by session"
```

### Task 2: Capture each status-line session without changing ccline output

**Files:**
- Modify: `src/macos/Sources/AgentHaloCore/ClaudeStatusLineProxyRuntime.swift`
- Modify: `src/macos/Sources/ClaudeCodeStatusLineProxy/main.swift`
- Test: `src/macos/Sources/AgentHaloCoreChecks/main.swift`

- [ ] **Step 1: Replace the proxy test with a failing two-session forwarding test**

```swift
func testClaudeStatusLineProxyRuntimeSeparatesSessionsAndForwardsInput() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agent-halo-statusline-runtime-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let now = ISO8601DateFormatter().date(from: "2026-06-23T02:00:00Z")!
    let firstInput = Data(#"{"session_id":"main-a","context_window":{"used_percentage":26.5,"context_window_size":200000}}"#.utf8)
    let secondInput = Data(#"{"session_id":"main-b","context_window":{"used_percentage":61.5,"context_window_size":200000}}"#.utf8)

    _ = try ClaudeStatusLineProxyRuntime.capture(input: firstInput, snapshotsDirectory: root, updatedAt: now)
    _ = try ClaudeStatusLineProxyRuntime.capture(input: secondInput, snapshotsDirectory: root, updatedAt: now)
    let forwarded = try ClaudeStatusLineProxyRuntime.runOriginalCommand(command: "cat", input: firstInput)
    let reader = ClaudeContextUsageReader(snapshotsDirectory: root, legacySnapshotURL: nil)

    expect(reader.read(sessionId: "main-a", now: now)?.usedPercent, 26.5, "first proxy session")
    expect(reader.read(sessionId: "main-b", now: now)?.usedPercent, 61.5, "second proxy session")
    expect(forwarded.standardOutput, firstInput, "ccline input must be forwarded unchanged")
    expect(forwarded.terminationStatus, 0, "downstream command status")
}
```

- [ ] **Step 2: Run the new test and verify RED**

Run `cd src/macos && swift run AgentHaloCoreChecks`.

Expected: compilation fails because `capture` still accepts `snapshotURL`.

- [ ] **Step 3: Change capture and the executable entry point**

Replace the write target in `ClaudeStatusLineProxyRuntime.capture`:

```swift
@discardableResult
public static func capture(
    input: Data,
    snapshotsDirectory: URL,
    updatedAt: Date = Date()
) throws -> ClaudeContextUsageSnapshot? {
    guard let snapshot = ClaudeStatusLineUsageParser.parse(data: input, updatedAt: updatedAt) else {
        return nil
    }
    try ClaudeContextUsageStorage.write(snapshot, directory: snapshotsDirectory)
    return snapshot
}
```

In `ClaudeCodeStatusLineProxy/main.swift`, replace the single snapshot path with:

```swift
let snapshotsDirectory = agentHaloDirectory
    .appendingPathComponent("claude-code-contexts", isDirectory: true)

_ = try? ClaudeStatusLineProxyRuntime.capture(
    input: input,
    snapshotsDirectory: snapshotsDirectory
)
```

Keep `runOriginalCommand(command:input:)` and standard-output forwarding unchanged so ccline renders the same content.

- [ ] **Step 4: Run core checks and verify GREEN**

Run `cd src/macos && swift run AgentHaloCoreChecks`.

Expected: `PASS AgentHaloCore checks`.

- [ ] **Step 5: Commit proxy isolation**

```bash
git add src/macos/Sources/AgentHaloCore/ClaudeStatusLineProxyRuntime.swift \
  src/macos/Sources/ClaudeCodeStatusLineProxy/main.swift \
  src/macos/Sources/AgentHaloCoreChecks/main.swift
git commit -m "fix: capture Claude statusline per session"
```

### Task 3: Reconcile the AgentHalo-to-ccline chain after settings rewrites

**Files:**
- Modify: `src/macos/Sources/AgentHaloCore/ClaudeStatusLineConfigurator.swift`
- Modify: `src/macos/Sources/AgentHaloMac/AppDelegate.swift`
- Test: `src/macos/Sources/AgentHaloCoreChecks/main.swift`
- Test: `src/macos/Sources/AgentHaloMac/HaloInteractionChecks.swift`

- [ ] **Step 1: Add failing configuration drift tests**

Extend the existing configurator test after its first successful configuration:

```swift
expect(
    ClaudeStatusLineConfigurator.isConfigured(homeDirectory: home),
    "fresh AgentHalo proxy configuration should be recognized"
)

var externallyRewritten = configured
externallyRewritten["statusLine"] = [
    "type": "command",
    "command": "~/.claude/ccline/ccline",
    "padding": 0
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
```

Add a source-wiring assertion in `HaloInteractionChecks`:

```swift
private func testStatusLineConfigurationReconciliationIsWiredToTick() {
    let sourceDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let appDelegateURL = sourceDirectory.appendingPathComponent("AppDelegate.swift")
    let source = try! String(contentsOf: appDelegateURL, encoding: .utf8)
    let tickStart = source.range(of: "    private func tick() {")!.lowerBound
    let tickEnd = source.range(
        of: "    private func createStatusItem()",
        range: tickStart..<source.endIndex
    )!.lowerBound
    let tickSource = source[tickStart..<tickEnd]
    expect(
        tickSource.contains("reconcileClaudeStatusLineConfiguration(now:"),
        "AppDelegate tick should reconcile status-line drift"
    )
}
```

Register `testStatusLineConfigurationReconciliationIsWiredToTick()` in `runHaloInteractionChecks()`.

- [ ] **Step 2: Run both check suites and verify RED**

Run:

```bash
cd src/macos
swift run AgentHaloCoreChecks
swift run AgentHaloMac --self-check
```

Expected: compilation or assertion failure because `isConfigured` and the tick reconciliation method do not exist.

- [ ] **Step 3: Implement a cheap exact configuration check**

Add overloads to `ClaudeStatusLineConfigurator`:

```swift
public static func isConfigured(
    homeDirectory home: URL = FileManager.default.homeDirectoryForCurrentUser
) -> Bool {
    let settingsURL = home.appendingPathComponent(".claude/settings.json")
    let installedProxy = home.appendingPathComponent(".agent-halo/claude-code-statusline-proxy")
    guard let data = try? Data(contentsOf: settingsURL),
          let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let statusLine = settings["statusLine"] as? [String: Any],
          let command = statusLine["command"] as? String else {
        return false
    }
    return URL(fileURLWithPath: command).standardizedFileURL == installedProxy.standardizedFileURL
}
```

Do not weaken the existing configure merge: when the current command is a non-proxy command, preserve it as the downstream command before restoring the proxy. Keep `NSFileCoordinator` and atomic writes.

- [ ] **Step 4: Add throttled reconciliation to AppDelegate**

Add state:

```swift
private var nextStatusLineReconciliationAt = Date.distantPast
private let statusLineReconciliationInterval: TimeInterval = 2
```

Call this near the beginning of `tick()`:

```swift
reconcileClaudeStatusLineConfiguration(now: Date())
```

Implement:

```swift
private func reconcileClaudeStatusLineConfiguration(now: Date) {
    guard now >= nextStatusLineReconciliationAt else { return }
    nextStatusLineReconciliationAt = now.addingTimeInterval(statusLineReconciliationInterval)
    guard !ClaudeStatusLineConfigurator.isConfigured() else { return }
    ClaudeStatusLineConfigurator.configure()
}
```

This checks cheaply every two seconds, rewrites only on drift, and naturally retries a failed repair later.

- [ ] **Step 5: Run both check suites and verify GREEN**

Run:

```bash
cd src/macos
swift run AgentHaloCoreChecks
swift run AgentHaloMac --self-check
```

Expected: both suites print `PASS`.

- [ ] **Step 6: Commit settings self-healing**

```bash
git add src/macos/Sources/AgentHaloCore/ClaudeStatusLineConfigurator.swift \
  src/macos/Sources/AgentHaloMac/AppDelegate.swift \
  src/macos/Sources/AgentHaloCoreChecks/main.swift \
  src/macos/Sources/AgentHaloMac/HaloInteractionChecks.swift
git commit -m "fix: reconcile Claude statusline chaining"
```

### Task 4: Resolve subagent activity to exact main-session details

**Files:**
- Create: `src/macos/Sources/AgentHaloCore/ClaudeMainSessionDetailsResolver.swift`
- Test: `src/macos/Sources/AgentHaloCoreChecks/main.swift`

- [ ] **Step 1: Add failing resolver tests**

Register `testClaudeMainSessionDetailsResolverUsesMainProjectAndExactUsage()` and add:

```swift
func testClaudeMainSessionDetailsResolverUsesMainProjectAndExactUsage() {
    let now = ISO8601DateFormatter().date(from: "2026-06-23T02:00:00Z")!
    let main = SessionSnapshot(
        threadId: "main-session",
        projectName: "text-extract",
        workingDirectory: "/Users/wjs/work/xisoft/text-extract",
        state: .thinking,
        action: "Thinking",
        lastEventAt: now,
        completedAt: nil,
        active: true,
        agent: .claudeCode
    )
    let exactUsage = ClaudeContextUsageSnapshot(
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
        usage: exactUsage
    )

    expect(resolved.sessionDetails.projectName, "text-extract", "main project")
    expect(resolved.sessionDetails.modelName, "glm-latest", "main model")
    expect(resolved.sessionDetails.inputTokens, 53_100, "main input tokens")
    expect(resolved.contextUsedPercent, 26.5, "main context")

    let mismatched = ClaudeMainSessionDetailsResolver.resolve(
        mainSessionId: "main-session",
        mainSessions: [main],
        usage: ClaudeContextUsageSnapshot(
            sessionId: "other-session",
            usedPercent: 90,
            modelName: "wrong-model",
            updatedAt: now
        )
    )
    expect(mismatched.sessionDetails.projectName, "text-extract", "safe project may remain")
    expect(mismatched.sessionDetails.modelName == nil, "other session model must be rejected")
    expect(mismatched.contextUsedPercent == nil, "other session context must be rejected")

    let missingMain = ClaudeMainSessionDetailsResolver.resolve(
        mainSessionId: "missing-session",
        mainSessions: [main],
        usage: exactUsage
    )
    expect(missingMain.sessionDetails.projectName == nil, "subagent worktree must not become project fallback")
}
```

- [ ] **Step 2: Run core checks and verify RED**

Run `cd src/macos && swift run AgentHaloCoreChecks`.

Expected: compilation fails because the resolver does not exist.

- [ ] **Step 3: Implement the pure resolver**

Create `ClaudeMainSessionDetailsResolver.swift`:

```swift
import Foundation

public struct ClaudeMainSessionDetails: Equatable, Sendable {
    public var sessionDetails: SessionDetailsSnapshot
    public var contextUsedPercent: Double?

    public init(sessionDetails: SessionDetailsSnapshot, contextUsedPercent: Double?) {
        self.sessionDetails = sessionDetails
        self.contextUsedPercent = contextUsedPercent
    }
}

public enum ClaudeMainSessionDetailsResolver {
    public static func resolve(
        mainSessionId: String?,
        mainSessions: [SessionSnapshot],
        usage: ClaudeContextUsageSnapshot?
    ) -> ClaudeMainSessionDetails {
        guard let mainSessionId,
              !mainSessionId.isEmpty,
              mainSessionId != "claude-code" else {
            return ClaudeMainSessionDetails(
                sessionDetails: SessionDetailsSnapshot(),
                contextUsedPercent: nil
            )
        }

        let main = mainSessions.first { $0.threadId == mainSessionId }
        let exactUsage = usage?.sessionId == mainSessionId ? usage : nil
        return ClaudeMainSessionDetails(
            sessionDetails: SessionDetailsSnapshot(
                projectName: main?.projectName,
                modelName: exactUsage?.modelName,
                inputTokens: exactUsage?.inputTokens,
                outputTokens: exactUsage?.outputTokens
            ),
            contextUsedPercent: exactUsage?.usedPercent
        )
    }
}
```

The resolver intentionally receives no hook `cwd`, so it cannot expose `.claude/worktrees/agent-*` as the project.

- [ ] **Step 4: Run core checks and verify GREEN**

Run `cd src/macos && swift run AgentHaloCoreChecks`.

Expected: `PASS AgentHaloCore checks`.

- [ ] **Step 5: Commit the resolver**

```bash
git add src/macos/Sources/AgentHaloCore/ClaudeMainSessionDetailsResolver.swift \
  src/macos/Sources/AgentHaloCoreChecks/main.swift
git commit -m "feat: resolve Claude main-session details"
```

### Task 5: Wire main transcripts and refresh visible metadata in place

**Files:**
- Modify: `src/macos/Sources/AgentHaloMac/AppDelegate.swift`
- Modify: `src/macos/Sources/AgentHaloMac/HaloInteractionChecks.swift`

- [ ] **Step 1: Add failing AppDelegate presentation tests**

Replace the Claude portion of `testDetailsPresentationUsesFocusedSessionAndRejectsStaleQuota` with main-session semantics:

```swift
let hookActivity = SessionSnapshot(
    threadId: "main-session",
    projectName: "agent-a47ee146bdd2ba852",
    workingDirectory: "/Users/wjs/work/xisoft/text-extract/.claude/worktrees/agent-a47ee146bdd2ba852",
    state: .working,
    action: "Running command",
    lastEventAt: now,
    completedAt: nil,
    active: true,
    agent: .claudeCode
)
let mainTranscript = SessionSnapshot(
    threadId: "main-session",
    projectName: "text-extract",
    workingDirectory: "/Users/wjs/work/xisoft/text-extract",
    state: .thinking,
    action: "Thinking",
    lastEventAt: now,
    completedAt: nil,
    active: true,
    agent: .claudeCode
)
let usage = ClaudeContextUsageSnapshot(
    sessionId: "main-session",
    usedPercent: 26.5,
    modelName: "glm-latest",
    inputTokens: 53_100,
    outputTokens: 1_200,
    updatedAt: now
)
let aggregate = AggregateSnapshot(
    state: .working,
    label: "EXECUTING",
    detail: "agent-a47ee146bdd2ba852 - Running command",
    sessions: [hookActivity],
    focusedAgent: .claudeCode
)

let presentation = AppDelegate.detailsPresentationForDetails(
    focusedAgent: .claudeCode,
    displayedAggregate: aggregate,
    claudeMainSessionId: "main-session",
    mainClaudeSessions: [mainTranscript],
    quota: nil,
    claudeUsage: usage
)
expect(presentation.sessionDetails.projectName, "text-extract", "details should show main project")
expect(presentation.sessionDetails.modelName, "glm-latest", "details should show main model")
expect(presentation.sessionDetails.inputTokens, 53_100, "details should show main tokens")
expect(presentation.contextUsedPercent, 26.5, "details should show main context")
```

Update the visible-panel source check to require the full in-place refresh:

```swift
expect(
    tickSource.contains("refreshVisibleDetailsPanel()"),
    "tick should refresh visible status and metadata"
)
expect(
    tickSource.contains("refreshVisibleDetailsStatus()") == false,
    "status-only refresh must not leave metadata stale"
)
```

- [ ] **Step 2: Run the macOS checks and verify RED**

Run `cd src/macos && swift run AgentHaloMac --self-check`.

Expected: compile/assertion failure because the presentation API and tick wiring still use hook snapshots and status-only refresh.

- [ ] **Step 3: Add a transcript monitor used only for metadata**

Add to `AppDelegate`:

```swift
private let claudeSessionMonitor = ClaudeSessionMonitor()
```

Refresh it in `tick()`:

```swift
_ = claudeSessionMonitor.refresh()
```

Do not pass transcript snapshots into `ClaudeStatusSourceMerger` or `allSnapshots()`. Add a separate accessor:

```swift
private func mainClaudeSessions() -> [SessionSnapshot] {
    claudeSessionMonitor.snapshots()
}
```

This preserves hook-only lifecycle authority while making non-subagent project metadata available.

- [ ] **Step 4: Resolve one exact main-session usage snapshot**

In the Claude details path, derive the ID from the displayed hook activity:

```swift
let mainSessionId = displayedAggregate.sessions.first?.threadId
    ?? rawClaudeSnapshots.first?.threadId
let claudeUsage = mainSessionId.flatMap { sessionId in
    contextReaderQueue.sync {
        claudeContextUsageReader.read(sessionId: sessionId)
    }
}
```

Change `detailsPresentationForDetails` to accept the already selected `claudeMainSessionId` and `mainClaudeSessions` instead of using hook sessions as metadata:

```swift
static func detailsPresentationForDetails(
    focusedAgent: AgentKind,
    displayedAggregate: AggregateSnapshot,
    claudeMainSessionId: String?,
    mainClaudeSessions: [SessionSnapshot],
    quota: RateLimitSnapshot?,
    claudeUsage: ClaudeContextUsageSnapshot?
) -> DetailsPresentation
```

Pass `claudeMainSessionId: nil` and `mainClaudeSessions: []` from the existing Codex-only tests. Implement the Claude branch as:

```swift
case .claudeCode:
    let resolved = ClaudeMainSessionDetailsResolver.resolve(
        mainSessionId: claudeMainSessionId,
        mainSessions: mainClaudeSessions,
        usage: claudeUsage
    )
    return DetailsPresentation(
        sessionDetails: resolved.sessionDetails,
        showsQuota: false,
        contextUsedPercent: resolved.contextUsedPercent
    )
```

Pass the computed `mainSessionId` into `detailsPresentationForDetails`. The raw hook fallback is only an identity fallback after an acknowledged completion; its project name is never details metadata. Remove `contextUsedPercentForDetails` after its tests move to the exact-session resolver so there is only one Claude context selection path.

- [ ] **Step 5: Refactor show versus refresh behavior**

Extract the data/presentation work from `showDetails()` into an in-place updater:

```swift
private func updateDetailsPanelContent() {
    let rawClaudeSnapshots = settings.focusedAgent == .claudeCode ? claudeSnapshots() : []
    let displayedAggregate = displayAggregate()
    let quota = settings.focusedAgent == .codex ? rateLimitReader.read() : nil
    let mainSessionId = settings.focusedAgent == .claudeCode
        ? displayedAggregate.sessions.first?.threadId ?? rawClaudeSnapshots.first?.threadId
        : nil
    let claudeUsage = mainSessionId.flatMap { sessionId in
        contextReaderQueue.sync {
            claudeContextUsageReader.read(sessionId: sessionId)
        }
    }
    let presentation = Self.detailsPresentationForDetails(
        focusedAgent: settings.focusedAgent,
        displayedAggregate: displayedAggregate,
        claudeMainSessionId: mainSessionId,
        mainClaudeSessions: mainClaudeSessions(),
        quota: quota,
        claudeUsage: claudeUsage
    )
    detailsPanel.update(
        aggregate: displayedAggregate,
        quota: quota,
        contextUsedPercent: presentation.contextUsedPercent,
        sessionDetails: presentation.sessionDetails,
        showsQuota: presentation.showsQuota
    )
}

private func showDetails() {
    guard !systemOverlaySuspended else { return }
    hoverHideTimer?.invalidate()
    if settings.focusedAgent == .claudeCode {
        acknowledgeCompletedSessions(claudeSnapshots())
    }
    updateDetailsPanelContent()
    detailsPanel.onMouseEntered = { [weak self] in self?.hoverHideTimer?.invalidate() }
    detailsPanel.onMouseExited = { [weak self] in self?.scheduleHideDetails() }
    detailsPanel.onAgentSelected = { [weak self] agent in self?.setFocusedAgent(agent) }
    positionDetailsPanel()
    detailsPanel.orderFrontRegardless()
}

private func refreshVisibleDetailsPanel() {
    guard detailsPanel.isVisible else { return }
    updateDetailsPanelContent()
}
```

In `tick()`, call `refreshVisibleDetailsPanel()` instead of `refreshVisibleDetailsStatus()`. Delete the status-only helper once no call sites remain.

- [ ] **Step 6: Run focused checks and verify GREEN**

Run:

```bash
cd src/macos
swift run AgentHaloCoreChecks
swift run AgentHaloMac --self-check
swift build
```

Expected: core checks and macOS self-check print `PASS`; build completes successfully.

- [ ] **Step 7: Commit application wiring**

```bash
git add src/macos/Sources/AgentHaloMac/AppDelegate.swift \
  src/macos/Sources/AgentHaloMac/HaloInteractionChecks.swift
git commit -m "fix: show Claude main-session details"
```

### Task 6: Verify the packaged application and live configuration contract

**Files:**
- Verify only; modify earlier files only if a failing check reveals a scoped regression.

- [ ] **Step 1: Run the complete repository verification set**

```bash
cd src/macos
swift run AgentHaloCoreChecks
swift run AgentHaloMac --self-check
swift build
cd ../..
git diff --check
```

Expected: both executable suites print `PASS`, SwiftPM builds successfully, and `git diff --check` prints nothing.

- [ ] **Step 2: Rebuild and launch the staged app**

```bash
scripts/run-macos.sh --verify
```

Expected: `outputs/AgentHalo-macOS/AgentHalo.app` is rebuilt, verification succeeds, and the staged binary is relaunched.

- [ ] **Step 3: Verify the live ccline chain**

```bash
jq '.statusLine' ~/.claude/settings.json
sed -n '1p' ~/.agent-halo/claude-code-statusline-original-command
```

Expected:

- `statusLine.command` points to `~/.agent-halo/claude-code-statusline-proxy` using its absolute path.
- the preserved downstream command is `~/.claude/ccline/ccline`.
- ccline still renders its normal terminal status line after the next Claude refresh.

- [ ] **Step 4: Verify session isolation and main-project display**

With two Claude sessions active, confirm that `~/.agent-halo/claude-code-contexts/` contains separate files. When a subagent worktree is active, hover AgentHalo and confirm:

- activity still follows the subagent;
- project shows the main repository name rather than `agent-*`;
- model, tokens, and context match that main session's ccline values; and
- another Claude window cannot replace those values.

- [ ] **Step 5: Record any verification-only fix as a focused commit**

If Step 1-4 required a scoped correction, rerun the failed check plus the complete set, then commit only that correction:

```bash
git add src/macos/Sources/AgentHaloCore/ClaudeContextUsageConstants.swift \
  src/macos/Sources/AgentHaloCore/ClaudeContextUsage.swift \
  src/macos/Sources/AgentHaloCore/ClaudeStatusLineProxyRuntime.swift \
  src/macos/Sources/AgentHaloCore/ClaudeStatusLineConfigurator.swift \
  src/macos/Sources/AgentHaloCore/ClaudeMainSessionDetailsResolver.swift \
  src/macos/Sources/ClaudeCodeStatusLineProxy/main.swift \
  src/macos/Sources/AgentHaloMac/AppDelegate.swift \
  src/macos/Sources/AgentHaloCoreChecks/main.swift \
  src/macos/Sources/AgentHaloMac/HaloInteractionChecks.swift
git commit -m "fix: complete Claude main-session verification"
```

If no correction was required, do not create an empty commit.
