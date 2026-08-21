# macOS Grok Build 额度与最小生命周期设计

## 文档状态

- 日期：2026-07-25
- 状态：实现与自动化回归完成（Task 1–11）；人工 live E2E（`grok login` 额度 UI / 真实会话 hooks）待补；实施计划见 [2026-07-25-macos-grok-build-usage-lifecycle-implementation.md](../plans/2026-07-25-macos-grok-build-usage-lifecycle-implementation.md)
- 实现范围：AgentHalo **macOS only**
- 产品原则：见 [PRODUCT.md](../../PRODUCT.md)
- 额度管线先例：[OpenUsage 风格监控 macOS 设计](./2026-07-10-openusage-monitoring-macos-design.md)
- 生命周期先例：[Claude Code Status 设计](./2026-06-16-claude-code-status-design.md)
- 参考实现：`/Users/wjs/work/openusage/Sources/OpenUsage/Providers/Grok/`
- 官方 hooks 文档：https://docs.x.ai/build/features/hooks

## 目标

在现有 Codex / Claude Code 之上，为 **Grok Build（Grok CLI）** 增加：

1. **OAuth 周额度展示**：详情面板焦点切到 Grok 时，显示 Weekly 使用百分比与重置时间（对齐 Codex/Claude OAuth 额度体验）。
2. **最小生命周期光环**：thinking / working / done / needs you / error，使焦点在 Grok 时 halo 能反映真实活动。
3. **状态隔离**：Grok hook 事件不得再污染 Claude Code 状态日志。

用户确认的产品选择：

- 方案：**OpenUsage 额度 + Claude 同构 hooks 分流**
- 分段标签：**`Grok`**（不是 `GB`）
- **Pay-as-you-go：不做、不显示**

## 非目标

- Windows 实现或共享 C# 运行时改动。
- Pay-as-you-go / on-demand cap / prepaid balance / 货币余额 / 本地消费估算。
- Grok API Key 模式的 console 额度或 credits 曲线。
- context pill 精细化、会话标题深挖、subagent 树可视化。
- 点击光环 foreground Grok 终端窗口。（已被 [2026-08-18-focused-agent-host-activation-design.md](./2026-08-18-focused-agent-host-activation-design.md) 取代。）
- 修改跨平台视觉 spec（`agent-halo.v2.json` 动画参数）。
- 清理历史已写入 `claude-code-status.jsonl` 的 Grok 旧事件（新事件停止混入即可）。

## 背景与调研摘要

### 现状问题

Grok Build 默认会加载 `~/.claude/settings.json` 中的 hooks（Claude 兼容）。Agent Halo 已配置的 `claude-code-status-hook` 因此在 Grok 会话中也会执行，事件写入 `~/.agent-halo/claude-code-status.jsonl` 且 `source: "claude-hook"`。焦点在 Claude Code 时，会把 Grok 活动误显示为 Claude。

### 额度数据源（已 live 验证）

| 项 | 内容 |
| --- | --- |
| 凭据 | `~/.grok/auth.json`（OIDC，`auth_mode: oidc`） |
| Token 刷新 | `POST https://auth.x.ai/oauth2/token`（`grant_type=refresh_token` + `client_id` + `refresh_token`） |
| 额度 API | `GET https://cli-chat-proxy.grok.com/v1/billing?format=credits` |
| 鉴权头 | `Authorization: Bearer <access_token>`、`X-XAI-Token-Auth: xai-grok-cli` |
| Plan 可选 | `GET https://cli-chat-proxy.grok.com/v1/settings`（取 `subscription_tier_display`） |

本机实测响应要点：

- `config.currentPeriod.type == "USAGE_PERIOD_TYPE_WEEKLY"`
- `config.creditUsagePercent` 为总池使用百分比（proto-JSON：缺省表示 0）
- `config.productUsage[]` 可含 `GrokBuild` 分项；**主条使用总池百分比**，与 OpenUsage / CLI 一致，避免双口径
- `onDemandCap` 存在但首版忽略

该 API 非公开稳定契约，与 OpenUsage/Grok CLI 同源；解码失败映射为 `invalidResponse` / stale，不得崩溃或影响 halo 状态机。

### 生命周期数据源

- 全局 hooks：`~/.grok/hooks/*.json`（始终信任）
- 事件：`SessionStart`、`UserPromptSubmit`、`PreToolUse`、`PostToolUse`、`PostToolUseFailure`、`Notification`、`Stop`、`StopFailure`、`SessionEnd` 等
- 进程环境：`GROK_SESSION_ID`、`GROK_HOOK_EVENT`、`GROK_WORKSPACE_ROOT`（可用于与 Claude 分流）
- 辅助 presence：`~/.grok/active_sessions.json` 或进程名含 `grok`

## 已确认的架构决策

1. **仅 macOS**；新代码放在现有 `AgentHaloCore` / `AgentHaloMac`，不新增 SwiftPM target。
2. **额度**沿用 `AuthStore → UsageClient → UsageMapper → UsageProvider → UsageSnapshotCache`，新增 `UsageMonitoring/Grok/`。
3. **生命周期**沿用 Claude hook 模式：hook 写 JSONL → Monitor 增量读 → Reducer → `SessionSnapshot`。
4. **单一 hook 二进制**分流 Claude / Grok（改现有 `claude-code-status-hook` 或等价 staged 二进制），避免两套维护。
5. **焦点模型**扩展为三选一：`codex` / `claudeCode` / `grok`；分段标题分别为 `Codex` / `CC` / `Grok`。
6. **只后台刷新当前焦点 Provider**；Grok OAuth 刷新周期与现有 5 分钟策略一致。
7. **OAuth token 临近过期自动刷新**，原子写回 `~/.grok/auth.json` 对应 entry，不得丢弃其他账号条目。
8. **Pay-as-you-go 首版不实现、不渲染**。
9. **额度失败不改变 halo 生命周期状态**（与 OpenUsage 设计一致）。

## 领域模型扩展

### AgentKind

```swift
public enum AgentKind: String, Codable, CaseIterable, Equatable, Sendable {
    case codex
    case claudeCode
    case grok
}
```

- `menuTitle`: `"Grok"`
- `segmentedTitle`: `"Grok"`
- standby / offline 文案增加 `status.standby_grok` / `status.offline_grok`（en + zh）

### UsageProviderID

```swift
public enum UsageProviderID: String, Codable, Sendable {
    case codex
    case claude
    case grok
}
```

设置持久化：`focusedAgent` 字符串值 `"grok"`；未知值回退 `codex`。

### Usage 窗口

Grok OAuth 仅产出 **一个** `UsageWindow`：

| 字段 | 来源 |
| --- | --- |
| `kind` | `.weekly`（仅当 period type 为 weekly） |
| `usedPercent` | `config.creditUsagePercent`（缺省 0，钳制到 0…100） |
| `resetsAt` | `config.currentPeriod.end` |
| `duration` | `end - start`（秒） |

非 weekly 周期：不伪造 weekly 条；`windows` 可为空，UI 走 noData / 现有空态，**不得**把 monthly 标成 weekly。

`planName`：优先 settings 的 `subscription_tier_display`；不可用时可为 `nil`（面板仍显示 Provider 名 `Grok`）。

## 额度模块

路径建议：

```text
src/macos/Sources/AgentHaloCore/UsageMonitoring/Grok/
├── GrokAuthStore.swift
├── GrokUsageClient.swift
├── GrokUsageMapper.swift
└── GrokUsageProvider.swift
```

### GrokAuthStore

- 读取 `~/.grok/auth.json`：顶层为 `issuer::client_id` → entry 字典。
- Entry 关键字段：`key`（access token）、`refresh_token`、`expires_at`、`oidc_client_id`、`user_id` / `email`（仅用于 account digest，不落日志）。
- `client_id` 默认 `b1a00492-073a-47ea-816f-4c329264a828`（与 Grok CLI / OpenUsage 一致）；优先 entry 或 entry key 中的 id。
- `needsRefresh`：在过期前 5 分钟刷新。
- `AccountCacheKey.digest`：对稳定账户标识（如 `user_id` 或 email）做 SHA256 hex，**永不**用 raw token。
- `save`：读-改-写同一 entry；文件已存在但不可解析时拒绝覆盖（防抹掉其他账号）。

### GrokUsageClient

- `refreshToken` → `auth.x.ai` `/oauth2/token`
- `fetchCreditsConfig` → `cli-chat-proxy.grok.com` `/v1/billing?format=credits`
- `fetchSettings`（可选，失败不导致整体失败）→ `/v1/settings`
- User-Agent：`AgentHalo`（或与现有 provider 一致）
- HTTP 错误分类对齐 Codex/Claude：`401 → signInAgain`，`429 → rateLimited`，`5xx → serviceUnavailable`，其余 invalid / network

### GrokUsageMapper

- 解码 proto-JSON 形状（与 OpenUsage `GrokCreditsConfigDecoder` 对齐）。
- 仅 weekly → 一个 weekly window。
- **忽略** `onDemandCap` / `onDemandUsed` / `prepaidBalance`。
- `providerID: .grok`

### Coordinator 接入

- `UsageMonitoringCoordinator` 注册 `GrokUsageProvider`。
- `AppDelegate` / `DetailsContentResolver`：`focusedAgent == .grok` 时使用 `.grok` provider。
- 登录提示文案：`usage.warning.sign_in_grok`（例如引导 `grok login`）。

### API Key 模式

若未检测到 OAuth entry 但未来可检测 API key：首版可走现有 `apiKey` 分支显示 **会话详情空态/最小信息**，**不**调用 billing。检测规则与 Claude/Codex 一致：无 OAuth 则 `oauthNeedsSignIn` 或 apiKey（以实现时 `AccessModeResolver` 能表达的最小行为为准）。优先保证 OAuth 主路径。

## 生命周期模块

### Hook 分流（关键）

修改 staged hook 可执行文件（现 `claude-code-status-hook`）：

1. 若环境存在 `GROK_SESSION_ID` 或 `GROK_HOOK_EVENT`（任一非空），视为 Grok 调用：
   - 写入 `~/.agent-halo/grok-build-status.jsonl`
   - `source: "grok-hook"`
   - **不得**写入 `claude-code-status.jsonl`
2. 否则保持现有 Claude 行为与路径。
3. 字段提取继续兼容 snake_case / camelCase（`sessionId` / `session_id`，`toolName` / `tool_name`，以及 CLI 参数中的 PascalCase 事件名）。
4. 事件名规范化：stdin 中 `pre_tool_use` 等若落到记录层，统一为现有 reducer 使用的 PascalCase（`PreToolUse`），或在 reducer 双侧接受；推荐 **写盘时统一为 PascalCase** 以复用 Claude reducer 逻辑。

日志滚动策略对齐 Claude JSONL（体积上限与截断），可复用同一 rotate 常量。

### GrokHookConfigurator

启动时：

1. 确保 hook 二进制已 stage 到 `~/.agent-halo/`（可与 Claude 共用同一二进制路径，或显式 `grok-build-status-hook` 硬链/拷贝；**行为必须相同**）。
2. 写入或合并 `~/.grok/hooks/agent-halo-status.json`，为最小事件集注册 command hook，例如：

   - `SessionStart`、`UserPromptSubmit`
   - `PreToolUse` / `PostToolUse` / `PostToolUseFailure`（matcher `.*`）
   - `Notification`、`Stop`、`StopFailure`、`SessionEnd`
   - 可选：`PreCompact` / `PostCompact`（与 Claude 一致则加上，便于 compaction 显示）

3. 幂等：已配置则不反复改 mtime。
4. 失败只打日志，不得阻止 App 启动。

即使 Grok 仍从 Claude settings 触发同一二进制，分流逻辑也能正确落盘；原生 `~/.grok/hooks` 保证用户关闭 Claude compat 后仍可用。

### Monitor / Reducer

新增（命名可微调，职责固定）：

- `GrokHookStatusMonitor`：增量读 `grok-build-status.jsonl`
- `GrokHookStatusReducer`：可 **复用或薄包装** `ClaudeHookStatusReducer` 的状态机，但 `SessionSnapshot.agent = .grok`，默认项目名 `"Grok"`

事件映射（最小集）：

| Hook 事件 | 状态 | action 示意 |
| --- | --- | --- |
| `SessionStart` | idle | Ready |
| `UserPromptSubmit` | thinking | Thinking |
| `PreToolUse` | working | friendly tool action |
| `PostToolUse` / `PostToolUseFailure` | working → 短时后 thinking | Reviewing result / Tool failed |
| `Notification` + `permission_prompt` | attention | Awaiting permission |
| `Stop` | done | Complete |
| `StopFailure` | error | Grok stopped with an error |
| `SessionEnd` | idle | Ready |
| `PreCompact` / `PostCompact` | working / thinking | 与 Claude 一致（若订阅） |

工具名归一：至少 `run_terminal_command` → `shell_command`；其余交给 `GeneratedHaloSpec.friendlyAction`。

安全网：

- Post-tool 1.8s auto-fade（与 Claude 同）
- PreToolUse stuck 超时回 thinking（与 Claude 同量级）
- `permission_prompt` 不自动 fade

### Presence 与聚合

- `SessionAggregator` / App 层：焦点 `.grok` 时只聚合 `agent == .grok` 快照。
- standby：存在近期 active session 或 grok 进程；否则 offline。
- 完成确认：可复用 Claude 的完成可见策略；**不**做 Codex 式 click-to-activate。

## UI 改动

1. 详情面板分段控件：`Codex | CC | Grok`（三选一）。
2. 菜单「监控对象」增加 Grok，勾选态与设置同步。
3. `src/shared/assets/agent-switch/grok.svg`（及打包路径）；视觉简洁，不复制商业品牌复杂造型。
4. OAuth + focus Grok：body 为 usage（仅 weekly 一条进度时，沿用现有单/双条布局的兼容渲染——只渲染有数据的 window）。
5. Provider 行名称：`Grok`；plan 有则显示。
6. **不**增加 Pay-as-you-go badge 或第二类额度文案。

## 数据流总览

```text
                    ~/.grok/auth.json
                            │
                            v
                   GrokUsageProvider ──> UsageSnapshotCache
                            │
AppDelegate / Coordinator ──┤
                            │
            focus == .grok ──+──> DetailsContentResolver ──> DetailsPanel
                            │
Grok / Claude hooks ──> status-hook (env 分流)
           │                      │
           │                      +──> grok-build-status.jsonl
           │                      +──> claude-code-status.jsonl (仅 Claude)
           v
   GrokHookStatusMonitor ──> Reducer ──> SessionSnapshot(.grok)
           │
           v
   SessionAggregator(focusedAgent) ──> Halo 状态
```

## 隐私与安全

- 不上传会话内容；额度请求仅命中 `auth.x.ai` 与 `cli-chat-proxy.grok.com` 的官方/CLI 同源端点。
- 缓存与日志不得写入 access/refresh token；account digest 仅哈希稳定身份字段。
- Token 刷新写回仅更新必要字段（`key`、`refresh_token`、`expires_at` 等），原子写。
- Hook JSONL 仅生命周期元数据（timestamp、event、sessionId、cwd、toolName、notificationType、errorText、source），不含 prompt/补全正文。

## 测试与验收

在 `AgentHaloCoreChecks`（及必要的 interaction checks）中覆盖：

1. **Auth**：解析多 entry；refresh 后写回单 entry；损坏文件不覆盖；digest 稳定且不含 token 明文。
2. **Credits 解码**：含 `creditUsagePercent`、缺省 0%、非有限值失败、非 weekly 不产出 weekly window。
3. **Mapper**：weekly window 字段；忽略 onDemand；plan 可选。
4. **Hook 分流**：带 `GROK_SESSION_ID` 的 stdin 只追加 grok JSONL；无 GROK env 只写 claude JSONL。
5. **Reducer**：prompt → thinking；PreToolUse → working；permission 保持；Stop → done；StopFailure → error。
6. **Coordinator**：focus `.grok` 时只刷新 Grok provider；失败不改 halo state。
7. **Settings / UI**：`focusedAgent` 持久化 `"grok"`；分段三选项；sign-in warning 文案。
8. **回归**：Claude / Codex 现有 checks 全部通过；Grok 运行时不再向 claude JSONL 追加新行。

手动验收：

1. 已 `grok login` 时，焦点 Grok 显示 Weekly 百分比与重置时间。
2. 在 Grok 中提交 prompt / 跑工具，光环进入 thinking / working；结束后 done 或 idle。
3. 焦点切到 CC 时，不出现正在进行的 Grok session 作为 Claude 活动。
4. 暂停监听 / 离线时行为与其他 agent 一致。

## 实施顺序建议

1. 领域模型：`AgentKind.grok`、`UsageProviderID.grok`、设置与 i18n。
2. Grok 额度四件套 + Coordinator / Details 接线（可先独立验收额度）。
3. Hook 分流 + `GrokHookConfigurator` + Monitor/Reducer + 聚合。
4. UI 三段切换与图标。
5. 测试与手动验收。

## 风险

| 风险 | 缓解 |
| --- | --- |
| billing API 变更 | 严格解码；失败 stale/invalid；跟随 OpenUsage 更新 |
| Token 写回多账号损坏 | 读全文件、只改当前 entry、原子写；解析失败 abort |
| 三段 UI 拥挤 | 短标签 `Codex \| CC \| Grok` |
| Claude settings 与 grok hooks 双触发 | 分流幂等写同一 grok JSONL；reducer 按 session+时间去重 |
| 历史污染数据 | 仅保证新事件隔离；用户可忽略旧 claude JSONL 中的 Grok session id |

## 成功标准

- 用户在 macOS 上可将监控对象切到 **Grok**，并看到与 CLI 大致一致的 **Weekly 额度**。
- Grok 工作中光环状态可读；完成与错误可区分。
- Claude 焦点下不再被 Grok 活动干扰。
- 不出现 Pay-as-you-go UI；不影响 Windows 与现有 Codex/Claude 主路径。
