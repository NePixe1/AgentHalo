# Agent Focus Switch Design

## Goal

Agent Halo should monitor Codex and Claude Code at the same time without letting their visible states compete. The halo and hover details should follow one focused agent at a time, with an explicit switch between `Codex` and `CC`.

## Chosen Approach

Use a focused-agent model.

- The app still refreshes every available agent monitor.
- The main halo aggregates and renders only the currently focused agent's snapshots.
- The hover details panel includes a compact `Codex / CC` switch.
- Codex remains the default focus so existing usage and quota behavior is preserved.
- Switching to `CC` shows Claude Code status and hides Codex-only quota rows.
- Non-focused agents can be summarized as secondary activity in the details panel later, but they do not change the main halo state in this pass.

This avoids the current conflict where Claude Code can drive the halo while the hover panel still shows Codex quota data.

## Agent Model

Introduce a stable agent identifier in `AgentHaloCore` ([HaloModels.swift](file:///Users/wjs/work/pyproj/AgentHalo/src/macos/Sources/AgentHaloCore/HaloModels.swift)):

```swift
public enum AgentKind: String, Codable, CaseIterable, Equatable, Sendable {
    case codex
    case claudeCode

    public var menuTitle: String {
        switch self {
        case .codex: return "Codex"
        case .claudeCode: return "Claude Code"
        }
    }

    public var segmentedTitle: String {
        switch self {
        case .codex: return "Codex"
        case .claudeCode: return "CC"
        }
    }

    public var standbyDetail: String {
        switch self {
        case .codex: return "Codex is standing by"
        case .claudeCode: return "Claude Code is standing by"
        }
    }

    public var localizedStandbyDetail: String {
        switch self {
        case .codex: return "Codex 正在待命"
        case .claudeCode: return "Claude Code 正在待命"
        }
    }
}
```

Future agents extend this enum and the source list, instead of adding more special-case aggregation paths.

`SessionSnapshot` gains an `agent: AgentKind` field so the aggregator can filter by source without depending on which monitor produced it. `CodexSessionMonitor` always stamps `.codex`; `ClaudeSessionMonitor` always stamps `.claudeCode`. Persisted snapshots are not on disk, so no migration is needed.

```swift
public struct SessionSnapshot: Equatable, Sendable {
    public var threadId: String
    public var projectName: String
    public var workingDirectory: String
    public var state: HaloState
    public var action: String
    public var lastEventAt: Date
    public var completedAt: Date?
    public var active: Bool
    public var agent: AgentKind
    
    // ... init ...
}
```

`AggregateSnapshot` gains a `focusedAgent: AgentKind` field that the aggregator stamps once:

```swift
public struct AggregateSnapshot: Equatable, Sendable {
    public var state: HaloState
    public var label: String
    public var detail: String
    public var sessions: [SessionSnapshot]
    public var focusedAgent: AgentKind
    
    // ... init ...
}
```

## Data Flow

`AppDelegate` owns two related concepts:

- all monitored snapshots, grouped by agent (each snapshot tagged with its `AgentKind`)
- the focused agent, persisted in `HaloSettings.focusedAgent` (default `.codex`)

Each tick refreshes both monitors, then calls a single aggregation entry point. The aggregator itself is the only place that branches on focus; callers do not pre-filter snapshots or selectively pass Codex extras.

### Settings persistence

`HaloSettings` adds:

```swift
public var focusedAgent: AgentKind
```

with `decodeIfPresent` defaulting to `.codex` for old settings files. The field is persisted via `SettingsStore.save` like every other setting.

### Aggregator signature

`SessionAggregator.aggregate` provides a full signature and a convenient overload:

```swift
public static func aggregate(
    snapshots: [SessionSnapshot],
    settings: HaloSettings,
    focusedAgent: AgentKind = .codex,
    now: Date = Date()
) -> AggregateSnapshot

public static func aggregate(
    snapshots: [SessionSnapshot],
    settings: HaloSettings,
    recentFailure: CodexFailure?,
    codexRunning: Bool,
    focusedAgent: AgentKind = .codex,
    now: Date = Date()
) -> AggregateSnapshot
```

Inside the aggregator:

- Filter `snapshots` to those matching `focusedAgent` before priority sorting: `let focusedSnapshots = snapshots.filter { $0.agent == focusedAgent }`.
- Filter out completed sessions based on standard thresholds (Claude Code: 8 seconds; Codex: 86,400 seconds / 24 hours).
- The Codex synthetic-failure fallback (`if codexRunning, let recentFailure …`) only runs when `focusedAgent == .codex`.
- Idle text is selected via the focused agent's `standbyDetail` (e.g. `focusedAgent.standbyDetail`).

`AppDelegate.tick()` always passes the full snapshot list and the current `recentFailure` / `codexRunning` values; the aggregator decides whether to use them. This keeps the call site agnostic of agent count.

### Idle / standby copy

All standby details are managed inside `AgentKind` to avoid hardcoding "Codex":

- `standbyDetail` (en): `"Codex is standing by"` for `.codex`, `"Claude Code is standing by"` for `.claudeCode`.
- `localizedStandbyDetail` (zh): `"Codex 正在待命"` for `.codex`, `"Claude Code 正在待命"` for `.claudeCode`.

In `DetailsPanel.localizedDetail(for:)`, the `.idle` state directly maps to:
```swift
case .idle: return aggregate.focusedAgent.localizedStandbyDetail
```

### Codex-only side-effects gated by focus

Three behaviors stay tied to `.codex` focus and become no-ops under `.claudeCode`:

1. **Synthetic failure injection** — described above, gated inside the aggregator.
2. **Halo primary click and double click** — `bringCodexForward()` only runs when `focusedAgent == .codex`. Under `.claudeCode`, the click is a no-op; the hover panel remains the primary tool.
3. **Completion acknowledgement** —
   - For Codex: `acknowledgeCompletedIfCodexIsForeground()` runs on every tick when Codex is foregrounded.
   - For Claude Code: `acknowledgeCompletedSessions(claudeSnapshots())` is called when the details hover panel is shown (`showDetails()`).

### Focus Switch Handler

`AppDelegate` exposes a central helper to switch the focused agent cleanly:

```swift
func setFocusedAgent(_ agent: AgentKind) {
    guard settings.focusedAgent != agent else {
        tick()
        refreshVisibleDetailsPanel()
        return
    }
    settings.focusedAgent = agent
    settingsStore.save(settings)
    tick()
    refreshVisibleDetailsPanel()
}
```

## Hover Panel

The top row of the hover panel (`DetailsPanel.swift`) contains:

- Brand label: `Agent Halo`
- Segmented switch: `agentSwitch` (`NSSegmentedControl`) mapped to `AgentKind.allCases.map(\.segmentedTitle)` (e.g. `"Codex"`, `"CC"`).
- Context pill: `contextPill` representing the current context usage percentage.

When `Codex` is selected:
- `showsCodexQuota` is true. `contextPill` and the `quotaGroup` (containing `primaryQuota` and `secondaryQuota` views) are shown.

When `CC` is selected:
- `showsCodexQuota` is false. `contextPill` and the entire `quotaGroup` are hidden. The height of the details panel collapses automatically using stack view spacing and auto-layout.

Switching segments on the control fires `onAgentSelected`, which triggers `AppDelegate.setFocusedAgent(_:)`.

## Menu

The status-bar and context menu expose the focused agent under the `"监控对象"` submenu:

- `监控对象`
  - `Codex` (checked when `settings.focusedAgent == .codex`)
  - `Claude Code` (checked when `settings.focusedAgent == .claudeCode`)

Selecting a menu item calls `selectFocusedAgent(_:)` which delegates to `setFocusedAgent(_:)`.

## Testing

Ensure coverage for focus switches:
- `HaloSettings` persists the selected focused agent.
- `SessionAggregator.aggregate` filters snapshots by `focusedAgent`.
- Codex synthetic failure does not occur when `.claudeCode` is focused.
- Claude Code focus hides Codex quota rows and the context pill.
- Idle copy properly switches between Codex and Claude Code locales.
- Switching focus immediately triggers redraw and settings persistence.
