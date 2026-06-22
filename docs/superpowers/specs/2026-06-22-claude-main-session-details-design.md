# Claude Main-Session Details Design

## Goal

When Claude Code is focused, the halo may reflect work performed by a Claude subagent, but the hover details panel must always show metadata for that subagent's main Claude session: project, model, input/output tokens, and context usage.

The existing ccline status line must continue to render unchanged.

## Confirmed Product Semantics

- Claude lifecycle hooks remain the authority for visible activity state. A subagent may therefore drive `THINKING`, `EXECUTING`, or another halo state.
- Claude details are main-session details, not subagent details.
- A subagent worktree name such as `agent-a47ee146bdd2ba852` must not appear as the project. The panel shows the main session's project, such as `text-extract`.
- Model, token, and context values must belong to the same main session as the displayed project.
- If exact main-session metadata is unavailable, render `--`; never substitute values from another Claude session.

This design narrows the earlier macOS session-details rule for Claude Code: "focused session" means the main Claude session associated with the current hook activity, even when that activity originated in a child worktree.

## Root Cause

The current implementation has three independent failure points:

1. Hook events derive `projectName` from the last component of `cwd`. Subagent hooks use a path under `.claude/worktrees/agent-*`, exposing the internal worktree name.
2. The status-line proxy writes one global `claude-code-context.json`. Concurrent Claude sessions overwrite one another, while the details panel correctly rejects a snapshot whose session ID does not match.
3. AgentHalo installs its proxy only at launch. If ccline or another settings writer later restores its own command directly in `~/.claude/settings.json`, ccline continues to receive status-line input but AgentHalo stops receiving it.

## Architecture

### 1. Preserve the status-line chain

The configured flow remains:

```text
Claude Code -> AgentHalo status-line proxy -> user's status-line command (ccline)
```

The proxy receives Claude's original JSON on standard input, captures structured metadata, then invokes the preserved command with exactly the same input and forwards its output. AgentHalo must not parse ccline's rendered text.

`ClaudeStatusLineConfigurator` gains reconciliation after startup. When `~/.claude/settings.json` changes and `statusLine.command` no longer points to the installed proxy, it:

1. preserves the new non-proxy command as the downstream command;
2. restores the AgentHalo proxy as `statusLine.command`;
3. preserves unrelated settings and status-line options; and
4. avoids rewriting when the configuration is already correct.

Reconciliation is debounced and serialized so atomic settings replacements do not create write loops. Failures are logged and retried on a later reconciliation; they do not interrupt halo monitoring.

### 2. Store usage per main session

Replace the single global context snapshot with session-scoped snapshots under an AgentHalo-owned directory, keyed by Claude's `session_id`. Each proxy invocation atomically replaces only that session's file, so different Claude windows cannot overwrite each other's metadata.

Each snapshot retains:

- session ID;
- model ID/display name;
- cumulative input and output tokens;
- context-window size and used percentage; and
- capture time.

The reader accepts one exact main-session ID and returns only a fresh snapshot for that ID. It never falls back to the newest arbitrary snapshot. Session IDs used as filenames must be validated or encoded before constructing a path.

Existing single-file data may be read only as a migration fallback when its embedded session ID matches. New writes use the session-scoped layout.

### 3. Resolve activity to main-session details

Introduce a small main-session details resolver with no UI responsibilities.

For Claude hook activity, the hook `sessionId` is the main-session identity even when the hook `cwd` points at a subagent worktree. The resolver uses that ID to combine:

- main-session project information from the non-subagent Claude transcript snapshot; and
- model, token, and context values from the matching session-scoped status-line snapshot.

The hook worktree path remains useful for activity tracking but is not used as the details project name. Subagent transcripts remain excluded from metadata parsing in this change.

If the hook lacks a usable main-session ID, or no main transcript/usage snapshot matches it, only the safely resolved fields are displayed and the rest remain unavailable.

### 4. Refresh visible details metadata

The normal tick continues to update halo activity. While the details panel is visible, a new status-line snapshot or a change in the resolved main session also refreshes project, model, tokens, and context—not only the status heading.

Metadata refresh must update the existing panel in place. It must not repeatedly reorder or reposition the window, restart hover timers, or disturb screenshot-overlay behavior.

## Data Flow

```text
subagent hook event
  -> hook snapshot (main session ID + child activity)
  -> halo state

main Claude status-line input
  -> AgentHalo proxy
  -> per-session usage snapshot
  -> ccline (unchanged visible output)

main transcript snapshot + matching usage snapshot
  -> main-session details resolver
  -> DetailsPanel project/model/token/context rows
```

## Freshness and Failure Rules

- A usage snapshot is accepted only when its embedded session ID matches the requested main session and its capture time is no more than five minutes old.
- A stale or malformed snapshot is treated as unavailable.
- Another active Claude session's newer snapshot is never used as a fallback.
- Missing project metadata does not permit deriving a project from `.claude/worktrees/agent-*`; show `--` instead.
- A broken or absent downstream ccline command must not prevent the proxy from capturing metadata. The proxy logs the chaining failure and exits without crashing Claude Code.
- The settings reconciler must never wrap the AgentHalo proxy as its own downstream command.

## Scope

Included:

- native macOS AgentHalo;
- ccline-compatible status-line chaining and self-healing;
- per-session Claude usage snapshots;
- main-session project and usage resolution; and
- live metadata refresh in the visible details panel.

Excluded:

- displaying subagent-specific model or token usage;
- changing the halo's subagent activity behavior;
- parsing ccline's formatted output;
- new user-facing controls;
- Windows changes; and
- unrelated Claude hook-state changes.

## Verification

Use test-driven development and cover these behaviors:

1. The configurator preserves ccline, installs the proxy, and restores the chain after an external settings rewrite without changing unrelated settings.
2. The proxy forwards the original JSON to ccline and writes separate atomic snapshots for two session IDs.
3. The reader returns only the requested fresh session and rejects stale, malformed, mismatched, and path-unsafe identities.
4. A subagent hook whose `cwd` ends in `agent-*` resolves details from its main session ID and displays the main project.
5. Main-session model, tokens, and context remain isolated when multiple Claude sessions are active.
6. Missing matching metadata produces `--` rather than another session's values.
7. A visible details panel refreshes metadata in place when the matching snapshot changes.
8. Existing Claude lifecycle, hover, screenshot, and ccline-preservation checks continue to pass.

Run `swift run AgentHaloCoreChecks`, `swift run AgentHaloMac --self-check`, `swift build`, and `git diff --check`, then rebuild and verify the staged app with `scripts/run-macos.sh --verify`.
