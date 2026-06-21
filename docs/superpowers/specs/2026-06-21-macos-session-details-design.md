# macOS Session Details Design

## Goal

When a focused agent does not expose Codex five-hour and weekly limits, use the lower section of the macOS hover details panel to show the current session's project, model, and token usage.

## Scope

- Implement only the native macOS app.
- Support both Codex and Claude Code.
- Preserve the existing agent switch, status heading, localized activity copy, and context-usage pill.
- Do not change the Windows app or the shared visual specification.

## Display Rules

The details panel chooses one lower-section presentation for the focused agent:

1. A Codex session with current five-hour and weekly limits keeps the existing two quota rows.
2. A Codex session whose current usage event has no rate-limit payload shows three metadata rows.
3. Claude Code shows the same three metadata rows because it does not expose Codex five-hour and weekly limits.

The metadata rows are:

- `项目`: the focused session's project name.
- `模型`: the focused session's model display value.
- `Token`: `输入 {value} · 输出 {value}`, using compact counts such as `38k` and `1.2k`.

An unavailable value is rendered as `--`. Token input and output are unavailable independently.

## Data Model and Flow

Add optional session-detail fields to the existing macOS session snapshot instead of scanning session files when the panel appears. This keeps the values associated with the same session that drives the visible halo state.

For Codex:

- `session_meta` continues to provide the working directory and project name.
- `turn_context.payload.model` updates the model.
- The latest `token_count.payload.info.total_token_usage` provides cumulative input and output tokens.
- The same `token_count` event records whether rate limits are present for that session. A current rate-limit payload selects the existing quota UI; its absence selects metadata.

For Claude Code:

- The existing status-line proxy snapshot is extended to retain the model and cumulative input/output values supplied by Claude Code.
- The snapshot remains keyed by session ID so data from another Claude session is not shown.
- The focused Claude session's project name continues to come from its session snapshot.

`AppDelegate` resolves the focused session details and passes them to `DetailsPanel`. `DetailsPanel` owns only presentation selection and formatting.

## Layout

Reuse the current panel surface, spacing, typography, and semantic colors. The metadata group replaces the quota group in the same lower-section slot and contains three full-width label/value rows separated by subtle dividers, matching the supplied reference image.

Long project and model values truncate at the tail. The right-aligned value column receives the remaining width so labels stay stable.

## Freshness and Fallbacks

- Values update as the existing Codex and Claude monitors consume new events.
- A session without a model or token event still shows its project and uses `--` for missing values.
- Older snapshots constructed by existing call sites remain source-compatible through optional initializer defaults.
- A stale quota found in another Codex session must not force the focused third-party session into quota mode.

## Verification

Follow test-driven development:

1. Add failing core checks for Codex model, token totals, and session-scoped rate-limit availability.
2. Add failing parser checks for Claude model and token totals from status-line input.
3. Add failing macOS interaction checks for quota-versus-metadata selection and compact token formatting.
4. Implement the smallest model, parser, wiring, and panel changes that satisfy those checks.
5. Run `swift run AgentHaloCoreChecks`, `swift run AgentHaloMac --self-check`, `swift build`, and `git diff --check`.
6. Rebuild and verify the staged app with `scripts/run-macos.sh --verify`.
