# macOS Codex Session Details Parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the macOS third-party Codex details panel show the Codex conversation title and current-turn input/output tokens instead of a missing title and session-cumulative token totals.

**Architecture:** Add a focused `CodexSessionTitleReader` that caches the `session_index.jsonl` mapping and let `CodexSessionMonitor` enrich reducer snapshots by thread ID. Port the Windows `SessionTracker` baseline algorithm into the existing macOS `SessionReducer`; leave the AppKit panel and usage-mode resolver unchanged.

**Tech Stack:** Swift 6, Foundation, Swift Package Manager, existing `AgentHaloCoreChecks` executable tests, existing `AgentHaloMac --self-check` UI checks.

## Global Constraints

- Only macOS Codex monitoring code and related tests may change; Windows behavior remains unchanged.
- Do not change details-panel layout, copy, fonts, colors, or dimensions.
- `session_index.jsonl.thread_name` is authoritative when present; `session_meta.title/session_title` remains the fallback.
- Missing or malformed title records must not interrupt lifecycle monitoring.
- Token values are current-turn deltas and are clamped to non-negative values.
- Do not log titles, user messages, or other session content.
- Use test-first red-green-refactor for every production behavior change.

---

### Task 1: Resolve Codex Titles From The Session Index

**Files:**
- Create: `src/macos/Sources/AgentHaloCore/CodexSessionTitleReader.swift`
- Modify: `src/macos/Sources/AgentHaloCore/SessionReducer.swift`
- Modify: `src/macos/Sources/AgentHaloCore/CodexSessionMonitor.swift`
- Test: `src/macos/Sources/AgentHaloCoreChecks/main.swift`

**Interfaces:**
- Produces: `public struct CodexSessionTitleReader`.
- Produces: `public mutating func read() -> [String: String]` returning thread ID to trimmed title.
- Produces: `public mutating func setSessionTitle(_ title: String) -> Bool` on `SessionReducer`.
- Changes: `CodexSessionMonitor.init(sessionsRoot:sessionTitleReader:fileManager:)` accepts an injectable reader with a live default.

- [ ] **Step 1: Add failing reader and monitor integration tests**

Add these checks near the existing Codex session-detail tests in `AgentHaloCoreChecks/main.swift`:

```swift
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
```

Register both throwing tests in the existing `do/catch` test runner:

```swift
do {
    try testCodexSessionTitleReaderUsesLatestValidTitle()
    try testCodexSessionMonitorPrefersIndexTitleAndKeepsMetadataFallback()
} catch {
    fatalError("Codex session title checks failed: \(error)")
}
```

- [ ] **Step 2: Run the tests and verify the title reader is missing**

Run:

```bash
cd src/macos && swift run AgentHaloCoreChecks
```

Expected: compilation fails because `CodexSessionTitleReader` and the new monitor initializer argument do not exist.

- [ ] **Step 3: Implement the cached title reader**

Create `CodexSessionTitleReader.swift`:

```swift
import Foundation

public struct CodexSessionTitleReader: Sendable {
    public var indexURL: URL
    private var cachedSize: UInt64?
    private var cachedModifiedAt: Date?
    private var cachedTitles: [String: String] = [:]

    public init(
        indexURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("session_index.jsonl")
    ) {
        self.indexURL = indexURL
    }

    public mutating func read() -> [String: String] {
        guard let metadata = FastFileMetadata.read(indexURL) else {
            cachedSize = nil
            cachedModifiedAt = nil
            cachedTitles = [:]
            return cachedTitles
        }
        if cachedSize == metadata.size, cachedModifiedAt == metadata.modifiedAt {
            return cachedTitles
        }
        guard let data = try? Data(contentsOf: indexURL),
              let text = String(data: data, encoding: .utf8) else {
            return cachedTitles
        }

        var titles: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let data = String(line).data(using: .utf8),
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = record["id"] as? String,
                  let rawTitle = record["thread_name"] as? String else {
                continue
            }
            let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if !id.isEmpty, !title.isEmpty {
                titles[id] = title
            }
        }
        cachedSize = metadata.size
        cachedModifiedAt = metadata.modifiedAt
        cachedTitles = titles
        return titles
    }
}
```

- [ ] **Step 4: Merge authoritative titles into reducer snapshots**

Add this method to `SessionReducer`:

```swift
@discardableResult
public mutating func setSessionTitle(_ title: String) -> Bool {
    let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty, snapshot.sessionTitle != normalized else {
        return false
    }
    snapshot.sessionTitle = normalized
    return true
}
```

Add a stored reader and initializer argument to `CodexSessionMonitor`:

```swift
private var sessionTitleReader: CodexSessionTitleReader

public init(
    sessionsRoot: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex", isDirectory: true)
        .appendingPathComponent("sessions", isDirectory: true),
    sessionTitleReader: CodexSessionTitleReader = CodexSessionTitleReader(),
    fileManager: FileManager = .default
) {
    self.sessionsRoot = sessionsRoot
    self.sessionTitleReader = sessionTitleReader
    self.fileManager = fileManager
}
```

At the end of `CodexSessionMonitor.refresh(now:)`, before returning, merge titles after all JSONL reads:

```swift
let titles = sessionTitleReader.read()
for url in reducers.keys {
    guard let threadID = reducers[url]?.snapshot.threadId,
          let title = titles[threadID] else {
        continue
    }
    changed = reducers[url]?.setSessionTitle(title) == true || changed
}
return changed
```

- [ ] **Step 5: Run the focused checks and verify green**

Run:

```bash
cd src/macos && swift run AgentHaloCoreChecks
```

Expected: exits 0 and prints `PASS AgentHaloCore checks`.

- [ ] **Step 6: Commit the title implementation**

```bash
git add src/macos/Sources/AgentHaloCore/CodexSessionTitleReader.swift \
  src/macos/Sources/AgentHaloCore/SessionReducer.swift \
  src/macos/Sources/AgentHaloCore/CodexSessionMonitor.swift \
  src/macos/Sources/AgentHaloCoreChecks/main.swift
git commit -m "fix: show Codex session titles on macOS"
```

### Task 2: Port Windows Current-Turn Token Accounting

**Files:**
- Modify: `src/macos/Sources/AgentHaloCore/SessionReducer.swift`
- Test: `src/macos/Sources/AgentHaloCoreChecks/main.swift`

**Interfaces:**
- Consumes: existing `SessionSnapshot.inputTokens` and `outputTokens` panel contract.
- Produces: current-turn values from `SessionReducer`; no UI or model signature changes.
- Internal state: last cumulative input/output values, turn baselines, and baseline-known flags.

- [ ] **Step 1: Replace cumulative-token expectations with failing turn-token checks**

Replace `testSessionReducerCapturesCodexSessionDetailsAndRateLimitAvailability` with:

```swift
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

    reducer.consume(jsonLine: #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":40000,"output_tokens":1500},"last_token_usage":{"input_tokens":4000,"output_tokens":500}},"rate_limits":{"primary":{},"secondary":{}}}"#)
    expect(reducer.snapshot.inputTokens, 4_000, "current turn input should grow from its inferred baseline")
    expect(reducer.snapshot.outputTokens, 500, "current turn output should grow from its inferred baseline")
    expect(reducer.snapshot.hasRateLimits, true, "subscription Codex should report rate limits")

    reducer.consume(jsonLine: #"{"type":"event_msg","payload":{"type":"task_complete"}}"#)
    reducer.consume(jsonLine: #"{"type":"event_msg","payload":{"type":"task_started"}}"#)
    expect(reducer.snapshot.inputTokens, 0, "new turn should reset displayed input tokens")
    expect(reducer.snapshot.outputTokens, 0, "new turn should reset displayed output tokens")
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
```

Update the runner calls:

```swift
testSessionReducerCapturesCurrentCodexTurnDetailsAndRateLimitAvailability()
testSessionReducerFallsBackToLastTokenUsageWithoutTotals()
```

- [ ] **Step 2: Run the tests and verify cumulative accounting fails**

Run:

```bash
cd src/macos && swift run AgentHaloCoreChecks
```

Expected: the first current-turn assertion fails because the reducer returns `38000` instead of `2000`.

- [ ] **Step 3: Add Windows-parity baseline state and reset it at task start**

Add private state beside the existing reducer flags:

```swift
private var hasTotalUsage = false
private var turnUsageBaselineKnown = false
private var totalInputTokens: Int64 = 0
private var totalOutputTokens: Int64 = 0
private var turnBaselineInputTokens: Int64 = 0
private var turnBaselineOutputTokens: Int64 = 0
```

At the beginning of the `GeneratedHaloSpec.isTaskStartEvent(type)` branch call:

```swift
startTurnUsage()
```

Add the baseline initializer:

```swift
private mutating func startTurnUsage() {
    turnUsageBaselineKnown = hasTotalUsage
    turnBaselineInputTokens = totalInputTokens
    turnBaselineOutputTokens = totalOutputTokens
    snapshot.inputTokens = 0
    snapshot.outputTokens = 0
}
```

- [ ] **Step 4: Replace cumulative assignment with current-turn calculation**

Replace `updateSessionDetails(from:)` token assignment with this Windows-equivalent calculation while preserving the existing context and rate-limit code:

```swift
private mutating func updateSessionDetails(from payload: [String: Any]) {
    let info = payload.dictionary("info")
    let totalUsage = info?.dictionary("total_token_usage")
    let lastUsage = info?.dictionary("last_token_usage")
    let nextInput = Self.int64(totalUsage?["input_tokens"]) ?? totalInputTokens
    let nextOutput = Self.int64(totalUsage?["output_tokens"]) ?? totalOutputTokens
    let lastInput = Self.int64(lastUsage?["input_tokens"]) ?? 0
    let lastOutput = Self.int64(lastUsage?["output_tokens"]) ?? 0

    if totalUsage != nil {
        if !turnUsageBaselineKnown {
            turnBaselineInputTokens = max(0, nextInput - lastInput)
            turnBaselineOutputTokens = max(0, nextOutput - lastOutput)
            turnUsageBaselineKnown = true
        }
        totalInputTokens = nextInput
        totalOutputTokens = nextOutput
        hasTotalUsage = true
        snapshot.inputTokens = max(0, totalInputTokens - turnBaselineInputTokens)
        snapshot.outputTokens = max(0, totalOutputTokens - turnBaselineOutputTokens)
    } else if lastUsage != nil {
        snapshot.inputTokens = max(0, lastInput)
        snapshot.outputTokens = max(0, lastOutput)
    }

    if let contextWindow = Self.int64(info?["model_context_window"]), contextWindow > 0 {
        snapshot.contextUsedPercent = min(
            100,
            max(0, Double(lastInput) * 100 / Double(contextWindow))
        )
    }
    snapshot.hasRateLimits = payload.dictionary("rate_limits") != nil
        || info?.dictionary("rate_limits") != nil
}
```

- [ ] **Step 5: Run the focused checks and verify green**

Run:

```bash
cd src/macos && swift run AgentHaloCoreChecks
```

Expected: exits 0 and prints `PASS AgentHaloCore checks`.

- [ ] **Step 6: Commit current-turn token accounting**

```bash
git add src/macos/Sources/AgentHaloCore/SessionReducer.swift \
  src/macos/Sources/AgentHaloCoreChecks/main.swift
git commit -m "fix: show current Codex turn tokens on macOS"
```

### Task 3: Full macOS Verification

**Files:**
- Verify: `src/macos/Sources/AgentHaloCore/CodexSessionTitleReader.swift`
- Verify: `src/macos/Sources/AgentHaloCore/CodexSessionMonitor.swift`
- Verify: `src/macos/Sources/AgentHaloCore/SessionReducer.swift`
- Verify: `src/macos/Sources/AgentHaloCoreChecks/main.swift`

**Interfaces:**
- Consumes: completed title enrichment and current-turn token behavior.
- Produces: verified macOS build with no panel-layout regression.

- [ ] **Step 1: Run all macOS checks**

Run each command from `src/macos`:

```bash
swift run AgentHaloCoreChecks
swift run AgentHaloMac --self-check
swift build
```

Expected: all three commands exit 0; core checks print `PASS AgentHaloCore checks`, interaction checks report no failed expectation, and the package builds successfully.

- [ ] **Step 2: Check formatting and change scope**

Run from the repository root:

```bash
git diff --check
git status --short
git diff HEAD~2 -- src/macos
```

Expected: no whitespace errors; only the title reader, Codex monitor/reducer, and core-check files changed in the two implementation commits; no Windows or AppKit panel file changed.

- [ ] **Step 3: Record verification status**

No production change is required in this step. Report the three command results and the implementation commit hashes in the final handoff.
