# Superseded Session Error Display Design

## Goal

Prevent an interrupted Codex session from continuing to control the halo after a different, newer session begins meaningful work. The superseded error must disappear completely from the current display list while its raw session snapshot remains available for future multi-session history and diagnostics.

## Scope

- Apply the same current-display behavior on macOS and Windows.
- Change aggregation only; do not change session parsing, fatal-event reduction, state colors, or global state priorities.
- Preserve raw monitor snapshots and recent-session APIs for future multi-session features.
- Address stale `error` sessions only. Existing `attention`, `done`, and acknowledgement behavior remains unchanged.

## Supersession Rule

An error snapshot is superseded when all of the following are true:

1. Another snapshot belongs to the same agent.
2. The snapshots have different `threadId` values.
3. The other snapshot is meaningful: it is active, done, or error. An idle snapshot created only from session metadata is not meaningful.
4. The other snapshot has a strictly newer `lastEventAt` value.

Superseded errors are removed before visible sessions are sorted, counted, used to choose the primary state, or considered a realtime-activity blocker.

This rule produces these outcomes:

| Raw snapshots | Current display |
| --- | --- |
| Session A is interrupted and no newer meaningful session exists | A remains `INTERRUPTED`. |
| A is interrupted; newer session B is working or thinking | Only B is displayed. |
| A is interrupted; newer B is done | Only B is displayed. |
| B is later acknowledged or otherwise hidden | The display becomes `READY`; A does not reappear. |
| A is still active; newer B is interrupted | B is primary; A remains a secondary active session. |
| A is interrupted; a newer file exists but has only idle/session metadata | A remains `INTERRUPTED`. |

When several errors exist, each older error is superseded by the newest meaningful session. A genuinely latest error therefore remains visible and retains the existing highest display priority. Non-error sessions are never removed by this rule, preserving concurrent active-session information for future multi-session UI.

## Architecture and Data Flow

### macOS

`CodexSessionMonitor` continues returning every recent raw `SessionSnapshot`. `SessionAggregator.aggregate` derives the focused-agent snapshot set, removes superseded errors from the current-display candidates, and then applies the existing visibility and priority rules.

The supersession check must use the complete focused-agent snapshot set, not only sessions that would otherwise be visible. This ensures that an acknowledged newer completion still prevents an older interruption from resurfacing.

`AggregateSnapshot.sessions` contains only the filtered current-display sessions. Other consumers that read `monitor.snapshots()` retain the original data.

### Windows

`CodexMonitor.GetAggregate` applies the equivalent supersession filter to cloned tracker snapshots before its existing visibility filter, state sorting, realtime blocking check, and session count are calculated.

`GetAllRecent` remains unchanged so future multi-session UI and diagnostics can still retrieve superseded sessions.

### Shared Contract

Document the supersession rule in `docs/CROSS_PLATFORM_SHARED_CONTRACT.md`. The generated visual specification remains unchanged because error color, label, transition, and priority are still correct for a non-superseded current error.

## Persistence and Recovery

Supersession is derived from raw snapshots on every aggregate refresh. It does not write `acknowledgedErrorAt`, mutate settings, or delete monitor reducers.

This makes the behavior stable across application restarts: while the newer meaningful session remains in the monitor's recent snapshot window, the older error stays suppressed. It also avoids treating an automatic state transition as explicit user acknowledgement.

## Verification

Follow test-driven development and add matching macOS and Windows regression coverage for:

1. An old error followed by a newer active session produces only the active session.
2. An old error followed by a newer done session produces only the done session.
3. Acknowledging the newer done session produces `READY` without resurrecting the old error.
4. A newer error still outranks an older active session.
5. A metadata-only idle session does not suppress an existing error.
6. Superseded sessions remain available through raw/recent-session accessors.

For macOS, run `swift run AgentHaloCoreChecks`, `swift run AgentHaloMac --self-check`, `swift build`, `git diff --check`, and `scripts/run-macos.sh --verify`.

For Windows, add equivalent `--self-check` assertions and run the Windows build/self-check in an environment with the .NET toolchain. On macOS, verify the Windows patch structurally and record the unavailable toolchain limitation rather than claiming a Windows build result.
