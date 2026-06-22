# Claude Code Status Design

## Goal

Agent Halo should display Claude Code activity in addition to the existing Codex activity on macOS.

## Scope

To guarantee reliable and real-time state tracking, Agent Halo introduces a **Hook-based** architecture for Claude Code. It automatically configures lifecycle hooks for Claude Code, monitors hook status events, reduces them into a unified `SessionSnapshot` model, and merges them with other agents' activities. 

## Architecture

Instead of relying solely on chat transcript files (which are chat records rather than lifecycle logs and can leave sessions falsely marked as active), Agent Halo uses Claude Code's native hook system as the **sole UI authority** for Claude Code status.

The system is structured as follows:
1. **ClaudeHookConfigurator** ([ClaudeHookConfigurator.swift](file:///Users/wjs/work/pyproj/AgentHalo/src/macos/Sources/AgentHaloCore/ClaudeHookConfigurator.swift)): Automatically deploys a custom hook binary (`claude-code-status-hook`) and configures it in `~/.claude/settings.json`.
2. **claude-code-status-hook**: An executable hook that writes structured event logs to `~/.agent-halo/claude-code-status.jsonl` on lifecycle events.
3. **ClaudeHookStatusMonitor** ([ClaudeHookStatusMonitor.swift](file:///Users/wjs/work/pyproj/AgentHalo/src/macos/Sources/AgentHaloCore/ClaudeHookStatusMonitor.swift)): Reads the Hook status JSONL file incrementally and uses `ClaudeHookStatusReducer` to produce state snapshots.
4. **ClaudeStatusSourceMerger** ([ClaudeStatusSourceMerger.swift](file:///Users/wjs/work/pyproj/AgentHalo/src/macos/Sources/AgentHaloCore/ClaudeStatusSourceMerger.swift)): Merges and deduplicates snapshots. It enforces source precedence, treating Hook status snapshots as the sole authority and filtering out raw transcript snapshots to prevent ghost sessions.

### Context Usage Monitoring

In addition to lifecycle status, Agent Halo captures Claude Code's **context window usage** via a Status Line Proxy architecture:

1. **ClaudeStatusLineConfigurator** ([ClaudeStatusLineConfigurator.swift](file:///Users/wjs/work/pyproj/AgentHalo/src/macos/Sources/AgentHaloCore/ClaudeStatusLineConfigurator.swift)): Automatically deploys the `claude-code-statusline-proxy` binary to `~/.agent-halo/` and configures `~/.claude/settings.json` to use it as the `statusLine.command`. The user's original status line command (if any) is preserved to `~/.agent-halo/claude-code-statusline-original-command` for chaining.
2. **claude-code-statusline-proxy** ([ClaudeCodeStatusLineProxy/main.swift](file:///Users/wjs/work/pyproj/AgentHalo/src/macos/Sources/ClaudeCodeStatusLineProxy/main.swift)): A proxy executable that intercepts Claude Code's status line JSON input (containing `session_id` and `context_window.used_percentage`), writes a snapshot to `~/.agent-halo/claude-code-context.json`, and then chains to the original command if one was configured.
3. **ClaudeContextUsageReader** ([ClaudeContextUsage.swift](file:///Users/wjs/work/pyproj/AgentHalo/src/macos/Sources/AgentHaloCore/ClaudeContextUsage.swift)): Reads the context snapshot file, validates the session ID against active Claude sessions, and enforces a 5-minute staleness threshold (`maxAge: 300s`).
4. **DetailsPanel integration**: When `focusedAgent == .claudeCode`, `AppDelegate.contextUsedPercentForDetails` retrieves the context usage snapshot for the currently displayed session(s) and passes it to `DetailsPanel.update(contextUsedPercent:)` to render the context pill.

```
+---------------------+        +-------------------------+
|     Claude Code     | ---->  | ~/.claude/settings.json |
+---------------------+        +-------------------------+
           | (native hooks)          | (statusLine.command)
           v                         v
+-----------------------------+   +------------------------------+
|  claude-code-status-hook    |   | claude-code-statusline-proxy |
+-----------------------------+   +------------------------------+
           | (writes to status log)  | (intercepts status line JSON)
           v                         v
+------------------------------------------+  +---------------------------------------+
| ~/.agent-halo/claude-code-status.jsonl   |  | ~/.agent-halo/claude-code-context.json |
+------------------------------------------+  +---------------------------------------+
           | (incremental file read)            | (read on demand)
           v                                    v
+-----------------------------+   +---------------------------+
|   ClaudeHookStatusMonitor   |   | ClaudeContextUsageReader  |
+-----------------------------+   +---------------------------+
           | (produces snapshots)    | (validates & reads)
           v                         v
+-----------------------------+   +---------------------------+
|  ClaudeStatusSourceMerger   |   | AppDelegate.contextUsed…  |
+-----------------------------+   +---------------------------+
           | (merges hook status, discards transcripts)
           v                         v
   [SessionSnapshot]        [contextUsedPercent for DetailsPanel]
```

## Hook Configuration

`ClaudeHookConfigurator` runs automatically on application startup:
1. Stages the compiled `claude-code-status-hook` binary into `~/.agent-halo/claude-code-status-hook` with `0o755` permissions.
2. Reads the user-level settings file `~/.claude/settings.json`.
3. Declares lifecycle hooks for the following events:
   - `SessionStart`, `UserPromptSubmit`, `PreToolUse` (matcher: `.*`), `PostToolUse` (matcher: `.*`), `PostToolUseFailure` (matcher: `.*`), `Notification`, `Stop`, `StopFailure`, `SessionEnd`, `PreCompact` (matcher: `""`), `PostCompact` (matcher: `""`).
4. Merges our binary executable command cleanly and saves the JSON settings file.

## Status Line Proxy Configuration

`ClaudeStatusLineConfigurator` runs automatically on application startup:
1. Stages the compiled `claude-code-statusline-proxy` binary into `~/.agent-halo/claude-code-statusline-proxy` with `0o755` permissions.
2. Reads the user-level settings file `~/.claude/settings.json`.
3. Preserves any existing `statusLine.command` to `~/.agent-halo/claude-code-statusline-original-command` (unless it already points to our proxy).
4. Sets `statusLine.type = "command"` and `statusLine.command` to the proxy binary path.
5. Saves the updated settings file atomically.

The proxy is idempotent: if the settings already point to our proxy, no changes are made. If the user later configures a different status line command, it will be chained automatically on the next app restart.

## Claude Hook Event Mapping

`ClaudeHookStatusReducer` ([ClaudeHookStatusReducer.swift](file:///Users/wjs/work/pyproj/AgentHalo/src/macos/Sources/AgentHaloCore/ClaudeHookStatusReducer.swift)) consumes the hook events and maps them to halo states:

| Hook Event | State | Action String | Description / Behavior |
| :--- | :--- | :--- | :--- |
| `SessionStart` | `.idle` | `"Ready"` | Reset state to idle, deactivate session. |
| `UserPromptSubmit` | `.thinking` | `"Thinking"` | The user submitted a prompt; Claude starts planning. |
| `PreToolUse` | `.working` | *Friendly tool action* | Runs a tool (e.g., shell_command for bash). No auto-fade. |
| `PostToolUse` | `.working` | `"Reviewing result"` | Tool finished; remains working briefly for 1.8s, then fades to thinking. |
| `PostToolUseFailure`| `.working` | `"Tool failed"` | Tool failed; remains working briefly for 1.8s, then fades to thinking. |
| `Notification` | `.attention` or `.idle` | `"Awaiting permission"` or `"Ready"` | Maps `permission_prompt` to `.attention` (needs user approval) without auto-fade; maps `idle_prompt` to `.idle`. |
| `Stop` | `.done` | `"Complete"` | Processing finished normally; marks session deactivated. |
| `StopFailure` | `.error` | `"Claude Code stopped with an error"` | Application crashed or stopped with error. |
| `PreCompact` | `.working` | `"Compressing context"` | Background compaction is running. |
| `PostCompact` | `.thinking` | `"Thinking"` | Compaction finished. |
| `SessionEnd` | `.idle` | `"Ready"` | Session clean exit. |

## Data Rules & Safety Mechanisms

- **Identity Resolution**: The reducer extracts `sessionId` for `threadId`, and `cwd` for `workingDirectory`. Project name is derived from the last component of `cwd`, defaulting to `"Claude Code"`.
- **Auto-Fade Duration**: Post-tool results use an event-time-anchored 1.8s timeout (`workingVisibleUntil = eventAt + 1.8s`). Using the event timestamp ensures correct fade state resolution even if the agent ticks are delayed or replayed.
- **Stuck-Tool Safety Net**: If a tool is executing (`.working`) but a crash or data truncation prevents `PostToolUse` from arriving, `applyWorkingVisibility` will force-fade the state back to `.thinking` after 180 seconds of inactivity.
- **Permission prompt holds**: `permission_prompt` notifications (.attention state) are exempt from the 180s timeout. They hold their state indefinitely until resolved by a subsequent event.

## Source Merger

`ClaudeStatusSourceMerger` consolidates all incoming Claude snapshots:
- Filters out raw transcript snapshots.
- Collapses duplicate `threadId` entries (e.g., in multi-window or resume scenarios) using a "last write wins" policy, comparing the `lastEventAt` timestamps, to avoid crashing the event loop.

## Testing

Ensure tests exist under `AgentHaloCoreChecks` (and related integration tests):
- Claude hook configurator idempotency and staging logic.
- Hook reducer maps prompt submits, tool execution (with normalized name mapping like bash -> shell_command), notification alerts (permission holds), compaction, and errors.
- Hook reducer auto-fade timeout and stuck-tool 180s safety recovery.
- `ClaudeStatusSourceMerger` deduplication and source precedence rules.
- Status line configurator idempotency and proxy staging logic.
- Status line configurator preserves and chains original commands.
- `ClaudeStatusLineUsageParser` correctly parses Claude Code status line JSON format.
- `ClaudeContextUsageReader` validates session IDs and enforces staleness thresholds.
- `AppDelegate.contextUsedPercentForDetails` selects the correct data source based on focused agent.
- DetailsPanel renders context pill for both Codex (via quota) and Claude Code (via status line proxy).
