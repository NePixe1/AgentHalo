# Agent Halo cross-platform shared contract

Version 0.13.0 keeps two native applications and one generated behavior contract:

```text
src/shared/spec/agent-halo.v2.json
        |
        +--> src/windows/GeneratedHaloSpec.cs
        +--> src/macos/Sources/AgentHaloCore/GeneratedHaloSpec.swift
```

The JSON contract is the only editable source for shared state metadata, lifecycle
matching, action and failure rules, rate-limit paths, animation parameters, transition
timing, gap motion, and shared settings metadata. The native applications compile
generated source and do not load the JSON file at runtime.

## Ownership boundary

Shared:

- state names, labels, priority, colors, brightness, and motion parameters
- Codex lifecycle event matching
- tool action labels and blocking failure classification
- rate-limit JSON paths and scan limits
- deterministic animation and lifecycle test vectors

Windows-only:

- WPF window, tray menu, hit testing, multi-display recovery, and startup integration
- Windows foreground detection and tray-specific menu hosting

macOS-only:

- AppKit panels, menu bar integration, launch agent, and application activation
- macOS display-link rendering and native menu bar hosting

## Change workflow

1. Edit `src/shared/spec/agent-halo.v2.json`.
2. Run `python scripts/generate_shared.py`.
3. Run `python scripts/validate_schema.py` and `python scripts/check_shared.py`.
4. Run the Windows self-test and macOS `swift run AgentHaloCoreChecks`.
5. Commit the spec and both generated outputs together.

CI rejects stale generated files or fixture drift. Generated files must never be
edited manually.

## Compatibility

`contractVersion` changes only for incompatible schema or semantic changes.
`releaseVersion` follows the application release. Platform extension data may evolve
without requiring pixel-identical rendering across operating systems.

## Plan Mode lifecycle (cross-platform)

Codex 的 Plan Mode（计划模式）只有在真正产出 proposed plan 时，才需要两端在轮次
结束时把光环停在「等待用户确认」的紫色 attention 状态，而不是直接进入绿色 done。
判定逻辑只依赖 `~/.codex/sessions` JSONL 流里的下列字段，两端实现必须保持一致：

| 字段 | 出现位置 | 含义 |
| --- | --- | --- |
| `payload.collaboration_mode_kind == "plan"` | `event_msg.task_started` payload | 本轮以 Plan Mode 启动。 |
| `payload.collaboration_mode.mode == "plan"` | 顶层 `turn_context` 事件 payload | 本轮 turn 上下文声明为 Plan Mode；可能早于或晚于 `task_started` 到达。 |
| `payload.phase == "final_answer"` 且 payload 任意文本包含 `<proposed_plan` | `event_msg.agent_message` 与 `response_item.message` payload | 本轮最终答案中给出了 proposed plan。 |
| `payload.item.type == "Plan"` | `event_msg.item_completed` payload | Codex 明确完成了一个 Plan item。 |

减速器在每轮内维护两个布尔标志：

- `currentTurnIsPlanMode` — 由上述任一 plan 字段置位（取并集，兼容两种事件顺序）。
- `planProposalSeen` — 当 `currentTurnIsPlanMode` 为真且观测到 proposed plan 内容或完成的 Plan item 时置位。

`task_complete` 时，如果两个标志都为真，光环置为：

- `state = attention`
- `action = "Waiting for your choice"`
- `active = true`
- `completedAt` 仍按事件时间戳记录

否则按既有逻辑进入 `state = done`。无论分支如何，两个标志在 `task_complete`
末尾都会清零；fatal / cancelled / interrupted 结束也会清零，避免跨轮次残留。

最终答案产出过程（`agent_message` / `message` 携带 `phase == "final_answer"` 期间）
两端**当前不强制锁蓝**，仅在内容包含 `<proposed_plan` 时置位 `planProposalSeen`，
视觉上仍按既有 `.thinking` / `.working` 流程显示。如需调整为「最终答案期间锁蓝」，
必须两端同步改、并在 `releaseVersion` 中记录。

## Superseded session errors (cross-platform)

当一个 Codex session 进入 `error` 后，另一个更新的 session 已经开始有效工作时，旧错误
不得继续控制当前光环，也不得继续出现在当前展示 session 列表中。错误快照仅在同时满足
以下条件时视为已被取代：

1. 候选快照与错误快照属于同一 agent；
2. 两者的 `threadId` 不同；
3. 候选快照是有效 session，即 `active == true`、`state == done` 或 `state == error`；
4. 候选快照的 `lastEventAt` / `LastEventUtc` 严格晚于错误快照。

仅有 `session_meta` 的 idle 快照不能取代错误。过滤必须基于聚焦 agent 的完整原始快照集，
并发生在可见性过滤、状态优先级排序、session 计数和 realtime blocking 判定之前。因此，更新
session 完成并被确认后，旧错误也不能重新出现。

该规则只影响当前聚合展示：不得删除 monitor/reducer 中的原始快照，也不得修改 macOS
`CodexSessionMonitor.snapshots()`、Windows `GetAllRecent()` 或错误确认设置。真正最新的错误
仍保留既有最高优先级；其他仍活跃的非错误 session 继续作为次要 session 保留。

参考实现位置：

- Windows: `src/windows/CodexMonitor.cs` 中 `ReduceEvent` / `ReduceResponse` /
  `UpdatePlanModeFromTurnContext` / `IsPlanModePayload` / `IsFinalAnswerPayload`。
- macOS: `src/macos/Sources/AgentHaloCore/SessionReducer.swift` 中同名函数与标志位。
- 测试：macOS 见 `AgentHaloCoreChecks/main.swift` 的 `testPlanMode*` 用例；
  Windows 见 `src/windows/Diagnostics.cs` 的 `--self-check` 断言。

## Platform implementation differences

- macOS and Windows both use the dark/lit tube material, bright white core,
  dim/blend/power-up transitions, and completion double flash behavior.
- macOS uses `CVDisplayLink`; Windows uses WPF composition callbacks. Both
  advance animation from display timing and clamp frame delta to avoid jumps.
- macOS exposes the same control menu from the menu bar and halo right click.
  Windows exposes the same controls from its tray menu and halo right click.
- Platform-specific window, menu, startup, hit-testing, and display behavior
  remain native and intentionally separate.
