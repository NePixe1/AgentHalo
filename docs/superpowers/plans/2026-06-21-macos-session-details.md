# macOS Session Details Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show project, model, and compact input/output token totals in the native macOS details panel whenever the focused agent has no Codex five-hour and weekly limits.

**Architecture:** Keep telemetry session-scoped. Codex reducers attach model, cumulative tokens, and rate-limit availability to `SessionSnapshot`; the existing Claude status-line snapshot captures the same metadata. `AppDelegate` resolves one focused `SessionDetailsSnapshot`, and the AppKit panel switches between its existing quota group and a new metadata group.

**Tech Stack:** Swift 6, SwiftPM, Foundation JSON parsing, AppKit, existing executable self-check harnesses.

---

## File Map

- Modify `src/macos/Sources/AgentHaloCore/HaloModels.swift`: define session detail values and optional telemetry on `SessionSnapshot`.
- Modify `src/macos/Sources/AgentHaloCore/SessionReducer.swift`: parse Codex model, cumulative tokens, and rate-limit presence.
- Modify `src/macos/Sources/AgentHaloCore/ClaudeContextUsage.swift`: retain Claude model and token totals in the status-line snapshot.
- Modify `src/macos/Sources/AgentHaloCoreChecks/main.swift`: verify both parsers and backward-compatible fallbacks.
- Modify `src/macos/Sources/AgentHaloMac/AppDelegate.swift`: resolve focused-agent details without cross-session quota leakage.
- Modify `src/macos/Sources/AgentHaloMac/DetailsPanel.swift`: render and format metadata rows or existing quota rows.
- Modify `src/macos/Sources/AgentHaloMac/HaloInteractionChecks.swift`: verify panel presentation and formatting.

### Task 1: Codex session telemetry

**Files:**
- Modify: `src/macos/Sources/AgentHaloCore/HaloModels.swift`
- Modify: `src/macos/Sources/AgentHaloCore/SessionReducer.swift`
- Test: `src/macos/Sources/AgentHaloCoreChecks/main.swift`

- [ ] **Step 1: Write the failing reducer check**

Add a check that consumes a `session_meta`, a `turn_context` containing `model`, and a `token_count` containing `total_token_usage` but no `rate_limits`, then asserts:

```swift
expect(reducer.snapshot.projectName, "AgentHalo", "Codex detail project")
expect(reducer.snapshot.modelName, "gpt-5.5", "Codex detail model")
expect(reducer.snapshot.inputTokens, 38_000, "Codex detail input tokens")
expect(reducer.snapshot.outputTokens, 1_200, "Codex detail output tokens")
expect(reducer.snapshot.hasRateLimits, false, "third-party Codex has no rate limits")
```

Consume a second `token_count` with a `rate_limits` dictionary and assert `hasRateLimits == true`.

- [ ] **Step 2: Run the core checks and verify RED**

Run: `cd src/macos && swift run AgentHaloCoreChecks`

Expected: compilation fails because the new `SessionSnapshot` telemetry properties do not exist.

- [ ] **Step 3: Add minimal model fields and parsing**

Add optional initializer-compatible fields:

```swift
public var modelName: String?
public var inputTokens: Int64?
public var outputTokens: Int64?
public var hasRateLimits: Bool?
```

In `SessionReducer.consume`, capture `turn_context.payload.model`. Before normal event reduction, handle `event_msg/token_count`: read `info.total_token_usage.input_tokens` and `output_tokens`, and set rate-limit availability from `payload.rate_limits` or `info.rate_limits`.

- [ ] **Step 4: Run the core checks and verify GREEN**

Run: `cd src/macos && swift run AgentHaloCoreChecks`

Expected: all AgentHaloCore checks pass.

### Task 2: Claude status-line telemetry

**Files:**
- Modify: `src/macos/Sources/AgentHaloCore/ClaudeContextUsage.swift`
- Test: `src/macos/Sources/AgentHaloCoreChecks/main.swift`

- [ ] **Step 1: Extend the existing parser check and verify RED**

Update its status-line fixture with:

```json
"model":{"id":"claude-sonnet-4","display_name":"Sonnet 4"},
"context_window":{"used_percentage":41.5,"context_window_size":200000,"total_input_tokens":38000,"total_output_tokens":1200}
```

Assert `modelName == "claude-sonnet-4"`, `inputTokens == 38_000`, and `outputTokens == 1_200`. Run `cd src/macos && swift run AgentHaloCoreChecks`; expect missing-property compilation failures.

- [ ] **Step 2: Capture optional Claude detail fields**

Extend `ClaudeContextUsageSnapshot` with optional `modelName`, `inputTokens`, and `outputTokens`, preserving decode compatibility with existing snapshot files. Parse the model ID with display-name fallback and integer totals from `context_window`.

- [ ] **Step 3: Run the core checks and verify GREEN**

Run: `cd src/macos && swift run AgentHaloCoreChecks`

Expected: all AgentHaloCore checks pass, including proxy forwarding.

### Task 3: Details panel metadata presentation

**Files:**
- Modify: `src/macos/Sources/AgentHaloMac/DetailsPanel.swift`
- Test: `src/macos/Sources/AgentHaloMac/HaloInteractionChecks.swift`

- [ ] **Step 1: Write failing panel checks**

Add a third-party Codex check that calls:

```swift
panel.update(
    aggregate: aggregate,
    quota: nil,
    contextUsedPercent: 42,
    sessionDetails: SessionDetailsSnapshot(
        projectName: "AgentHalo",
        modelName: "gpt-5.5",
        inputTokens: 38_000,
        outputTokens: 1_200
    ),
    showsQuota: false
)
```

Assert quota rows are hidden, metadata is visible, and values are `AgentHalo`, `gpt-5.5`, and `输入 38k · 输出 1.2k`. Add a Claude case and assert the same group is shown. Preserve the existing Codex quota check with `showsQuota: true`.

- [ ] **Step 2: Run the macOS self-check and verify RED**

Run: `cd src/macos && swift run AgentHaloMac --self-check`

Expected: compilation fails because `SessionDetailsSnapshot`, the new update arguments, and metadata test accessors do not exist.

- [ ] **Step 3: Implement the AppKit metadata group**

Add `SessionDetailsSnapshot` to the core model. Add three reusable label/value rows to `DetailsPanel`, separated by subtle one-pixel dividers. Update the panel method to choose exactly one lower group. Format counts with a static helper using whole `k` values or one decimal place when needed; format absent values as `--`.

- [ ] **Step 4: Run the macOS self-check and verify GREEN**

Run: `cd src/macos && swift run AgentHaloMac --self-check`

Expected: all AgentHaloMac checks pass.

### Task 4: Focused-session wiring

**Files:**
- Modify: `src/macos/Sources/AgentHaloMac/AppDelegate.swift`
- Test: `src/macos/Sources/AgentHaloMac/HaloInteractionChecks.swift`

- [ ] **Step 1: Write failing resolution checks**

Add checks for a helper that resolves:

- Codex with `hasRateLimits == true` to quota mode.
- Codex with `hasRateLimits == false` to metadata mode even when a stale global quota exists.
- Claude to metadata mode using a matching status-line session ID.
- Claude with a nonmatching snapshot to `--` telemetry rather than another session's values.

- [ ] **Step 2: Run the macOS self-check and verify RED**

Run: `cd src/macos && swift run AgentHaloMac --self-check`

Expected: failure because the focused-detail resolver does not exist.

- [ ] **Step 3: Implement focused-detail resolution**

In `showDetails`, select the displayed aggregate's first focused session. For Codex, build details from that session and set quota mode only when its latest token event explicitly reports rate limits. For Claude, read the existing status-line snapshot with the focused session ID, build details from the matching snapshot, and always select metadata mode. Pass the resolved values to `DetailsPanel.update`.

- [ ] **Step 4: Run both focused suites**

Run:

```bash
cd src/macos
swift run AgentHaloCoreChecks
swift run AgentHaloMac --self-check
```

Expected: both suites pass.

### Task 5: Full verification and staged app

**Files:**
- Verify: all modified macOS files

- [ ] **Step 1: Run source verification**

Run:

```bash
cd src/macos
swift build
swift run AgentHaloCoreChecks
swift run AgentHaloMac --self-check
cd ../..
git diff --check
```

Expected: all commands exit successfully with no compiler errors or diff whitespace errors.

- [ ] **Step 2: Rebuild and verify the actual app bundle**

Run: `bash scripts/run-macos.sh --verify`

Expected: the staged `outputs/AgentHalo-macOS/AgentHalo.app` is rebuilt, launched, and its running process path is verified.

- [ ] **Step 3: Review final scope**

Run: `git status --short && git diff --stat && git diff -- src/macos`

Expected: only the plan and scoped macOS/core changes are present; no Windows source changed.
