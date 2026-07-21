# macOS Codex 第三方详情数据修复设计

## 背景

macOS 在 Codex 使用第三方或自定义 API 时展示会话详情。目前存在两个数据问题：

- `Input/Output` 直接展示 `total_token_usage`，导致数值成为整个会话的累计量；
- 当前 Codex 生成的 `session_meta` 不包含标题，面板只能显示 `--`。

Windows 已按轮次计算 Codex token，但其第三方详情第一行仍显示项目名，并未实现 Codex 会话标题。macOS 需要沿用 Windows 的 token 口径，同时补充与 Codex 会话列表一致的标题来源。

## 范围

- 仅修改 macOS Codex 会话监控与相关测试。
- 不修改 Windows 行为。
- 不修改详情面板的布局、文案、字体、颜色或尺寸。
- OAuth 额度面板与 Claude Code 详情不受影响。

## 会话标题

新增轻量的 Codex 会话标题读取器，读取 `~/.codex/session_index.jsonl` 中的 `id` 和 `thread_name`。`thread_name` 是 Codex 会话列表使用的标题，因此它是详情面板的权威标题来源。

读取器按文件修改时间和大小缓存解析结果，仅在索引变化时重新读取。相同 thread ID 出现多条记录时，后出现的有效标题覆盖前一条，以支持标题更新。缺失、空白或无法解析的记录被忽略，不影响会话状态更新。

`CodexSessionMonitor` 在刷新会话后按 thread ID 合并索引标题：

1. 索引中存在非空 `thread_name` 时，写入对应 `SessionSnapshot.sessionTitle`；
2. 索引中没有该 thread ID 时，保留 `session_meta.title/session_title` 的兼容结果；
3. 两处均无标题时，继续显示 `--`，不回退到项目名或 thread ID。

## Token 口径

将 Windows `SessionTracker` 的轮次用量算法移植到 macOS `SessionReducer`。

Reducer 保存最近一次累计 input/output，以及当前轮次开始时的累计基线。收到任务开始事件时，将已有累计值记为本轮基线并把本轮显示值清零。收到 `token_count` 时：

1. 有 `total_token_usage` 且已知基线：显示 `total - baseline`，结果不小于零；
2. 首次接入正在进行的轮次且基线未知：使用 `total - last_token_usage` 反推出轮次开始基线，再计算本轮值；
3. 只有 `last_token_usage`：直接把 last input/output 作为当前轮次值；
4. `last_token_usage.input_tokens` 仍只用于计算 context 百分比，不改现有 context 口径。

此行为与 Windows 第三方 Codex 详情一致，避免把长会话累计量误认为当前一轮消耗。

## 数据流

```text
session JSONL ──> SessionReducer ──> 当前轮次 token
       │
       └────────> thread ID

session_index.jsonl ──> 标题读取器 ──> id -> thread_name
                                      │
                                      v
CodexSessionMonitor ─────────> SessionSnapshot ──> DetailsPanel
```

## 错误处理

- 标题索引不存在、读取失败或包含损坏行时，继续使用现有 session JSONL 数据。
- 单条损坏记录不会阻止其他标题被解析。
- token 字段缺失时保留已知值；差值始终钳制为非负数。
- 不记录会话标题、用户消息或其他会话内容到 Agent Halo 日志。

## 测试与验收

先添加失败测试，再实现最小修复：

1. 标题读取器解析 `id -> thread_name`，忽略空标题和损坏行；
2. 同一 thread ID 的较新标题覆盖旧标题；
3. 索引标题覆盖 session JSONL 的旧标题，索引缺失时保留兼容标题；
4. 首次接入已有累计 token 时，通过 `last_token_usage` 得到当前轮次值；
5. 后续任务按任务开始基线显示当前轮次增量；
6. 仅有 `last_token_usage` 时仍能显示 input/output；
7. 现有 context、rate-limit 和面板格式测试保持通过。

实现完成后运行：

```bash
cd src/macos
swift run AgentHaloCoreChecks
swift run AgentHaloMac --self-check
swift build
```

同时运行 `git diff --check`，确认没有空白错误，且改动仅覆盖本设计范围。
