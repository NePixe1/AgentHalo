# macOS Details Panel Session Title Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the Project row from the macOS Claude Code details body while preserving Session title, Model, and Input/Output rows and existing dynamic resize behavior.

**Architecture:** Keep `SessionDetailsSnapshot.projectName` and all resolver/data contracts unchanged. Change only `DetailsPanel`'s metadata stack and its macOS interaction-check observability so the visible session body contains three metadata rows and two separators.

**Tech Stack:** Swift 6, AppKit, Swift Package Manager, `AgentHaloMac --self-check`.

## Global Constraints

- Only modify `src/macos`; Windows remains unchanged.
- Project data remains available to the underlying session model but is not rendered in the details panel.
- Preserve 28pt metadata row heights, tooltips, offline clearing, top-edge-preserving resize, and pixel-aligned dynamic heights.

---

### Task 1: Update the macOS interaction contract to remove Project

**Files:**
- Modify: `src/macos/Sources/AgentHaloMac/HaloInteractionChecks.swift` (session-row checks around lines 980-1080)
- Modify: `src/macos/Sources/AgentHaloMac/DetailsPanel.swift` (test-only row-role/value accessors around lines 14-21 and 530-602)

**Interfaces:**
- The test-only `DetailsPanelSessionBodyRole` must expose `.separator`, `.sessionTitle`, `.model`, `.tokens`, and `.unknown`, with no `.project` case.
- `DetailsPanel.sessionBodyOrderForTesting` must report `[.sessionTitle, .separator, .model, .separator, .tokens]` after implementation.
- `DetailsPanel.sessionRowHeightsForTesting` must return the three visible metadata row heights.

- [ ] **Step 1: Write the failing regression assertions**

  In `testDetailsPanelShowsFourIndependentSessionRows`, change the expected body contract to:

  ```swift
  expect(panel.sessionTitleValueForTesting, "Redesign details", "session title row")
  expect(panel.modelValueForTesting, "gpt-5.5", "model row")
  expect(panel.tokenValueForTesting, "↑ 38k  ·  ↓ 1.2k", "token row")
  expect(panel.sessionTitleToolTipForTesting, "Redesign details", "session title tooltip")
  expect(panel.modelToolTipForTesting, "gpt-5.5", "model tooltip")
  expect(
      panel.sessionBodyOrderForTesting,
      [.sessionTitle, .separator, .model, .separator, .tokens],
      "API rows should omit the project row"
  )
  expect(panel.sessionBodyOrderForTesting.count, 5, "API body should contain exactly five arranged subviews")
  expect(!panel.sessionBodyOrderForTesting.contains(.unknown), "API body should reject unknown rows or titles")
  expect(
      panel.sessionBodyOrderForTesting.filter { $0 == .separator }.count,
      2,
      "API rows should contain two separators"
  )
  expect(panel.sessionRowHeightsForTesting, [28, 28, 28], "all API metadata rows should use the same 28pt height")
  ```

  In the offline and missing-title checks, stop asserting `projectValueForTesting`; continue asserting Session title, Model, and token clearing. Remove the old project-only fallback assertion because Project is no longer a rendered field.

- [ ] **Step 2: Run the self-check to verify the contract fails**

  Run from `src/macos`:

  ```bash
  swift run AgentHaloMac --self-check
  ```

  Expected: failure in the details-panel interaction checks because the current arranged-subview order still includes `.project`, the row count is 7, and the row-height list has four entries.

### Task 2: Remove the Project row from `DetailsPanel`

**Files:**
- Modify: `src/macos/Sources/AgentHaloMac/DetailsPanel.swift` (stored views, metadata stack setup, `renderSession`, and test-only accessors)

**Interfaces:**
- `renderSession(_:isOffline:)` continues to update Session title, Model, and tokens and must not read or display `session.projectName`.
- `metadataGroup` arranged subviews become `[sessionTitleRow, titleModelSeparator, modelRow, modelTokenSeparator, tokenRow]`.

- [ ] **Step 1: Write the minimal layout implementation**

  Remove the `project` enum case, `projectRow`, and `projectTitleSeparator`. Build the metadata group as:

  ```swift
  metadataGroup.addArrangedSubview(sessionTitleRow)
  metadataGroup.addArrangedSubview(titleModelSeparator)
  metadataGroup.addArrangedSubview(modelRow)
  metadataGroup.addArrangedSubview(modelTokenSeparator)
  metadataGroup.addArrangedSubview(tokenRow)
  ```

  In `renderSession`, retain title setup and offline clearing only for `sessionTitleRow`, `modelRow`, and `tokenRow`; remove all Project title/value assignments. Update test-only helpers to map only the three visible rows, return three row heights, and remove Project value/tooltip properties.

- [ ] **Step 2: Run the focused macOS self-check to verify it passes**

  ```bash
  cd src/macos && swift run AgentHaloMac --self-check
  ```

  Expected: all interaction checks pass, including the five-subview session body order, three equal row heights, offline clearing, and resize checks.

### Task 3: Run full verification and review the diff

**Files:**
- Verify only: `src/macos/Sources/AgentHaloMac/DetailsPanel.swift`
- Verify only: `src/macos/Sources/AgentHaloMac/HaloInteractionChecks.swift`

- [ ] **Step 1: Run the macOS core checks and build**

  ```bash
  cd src/macos
  swift run AgentHaloCoreChecks
  swift run AgentHaloMac --self-check
  swift build
  ```

  Expected: each command exits with status 0 and the self-check reports no failed expectations.

- [ ] **Step 2: Check formatting and scope**

  ```bash
  git diff --check
  git status --short
  git diff -- src/macos/Sources/AgentHaloMac/DetailsPanel.swift src/macos/Sources/AgentHaloMac/HaloInteractionChecks.swift
  ```

  Expected: no whitespace errors; only the two macOS source files contain implementation changes (the already committed design and plan docs are the only documentation changes); no Windows files or resolver/model files are modified.

- [ ] **Step 3: Commit the implementation**

  ```bash
  git add src/macos/Sources/AgentHaloMac/DetailsPanel.swift src/macos/Sources/AgentHaloMac/HaloInteractionChecks.swift
  git commit -m "fix: remove project row from macOS session details"
  ```
