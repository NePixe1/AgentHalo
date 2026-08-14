# macOS Antigravity Agent（额度 + 最小生命周期）设计

## 文档状态

- 日期：2026-08-14
- 状态：设计已确认，待写实施计划
- 实现范围：AgentHalo **macOS only**
- 产品原则：见 [PRODUCT.md](../../PRODUCT.md)
- 额度管线先例：[OpenUsage 风格监控 macOS 设计](./2026-07-10-openusage-monitoring-macos-design.md)
- 生命周期先例：[macOS Grok Build 额度与最小生命周期设计](./2026-07-25-macos-grok-build-usage-lifecycle-design.md)
- 启用模型先例：[macOS 启用 Agent 与设置窗口设计](./2026-08-01-macos-enabled-agents-settings-design.md)
- 参考实现：`/Users/wjs/work/ossp/openusage/Sources/OpenUsage/Providers/Antigravity/`
- 参考文档：`/Users/wjs/work/ossp/openusage/docs/providers/antigravity.md`

## 目标

在现有 Codex / Claude Code / Grok / Pi 之上，为 **Antigravity CLI（`agy`）** 增加一个完整 agent：

1. **焦点切换**：设置里可启用；详情条出现 `AG`；菜单名为 `Antigravity`。
2. **OAuth 额度**：焦点在 Antigravity 时，详情面板现有两行显示 Gemini 池的 5-Hour / Weekly。
3. **最小生命周期光环**：`agy` hooks 驱动 thinking / working / done / attention / error。
4. **状态隔离**：`agy` hook 事件只写入 Antigravity JSONL，不得进入 Claude / Grok / Pi 日志。

用户确认的产品选择：

- 方案：**按 Grok 的形状加 agent**（共用 `status-hook` 分流 + OpenUsage 同款额度探测）
- 平台：**仅 macOS**
- 额度行：**只显示 Gemini 池两行**（`gemini-5h` / `gemini-weekly`）
- 生命周期：**仅 `agy` CLI hooks**（不做 IDE 会话推断）
- 额度源：**LS 优先，否则 Keychain + Cloud Code**（完整对齐 OpenUsage 探测顺序）
- 分段标签：**`AG`**
- 默认启用：**否**（不进入 `HaloSettings.defaultEnabledAgents`）

## 非目标

- Windows 实现或共享 C# 运行时改动。
- Antigravity IDE / `language_server` 的生命周期推断。
- 非 Gemini 池（`3p-5h` / `3p-weekly`，OpenUsage 里的 Claude / Claude Weekly）。
- API Key 会话卡、context pill、会话标题深挖。
- 点击光环唤起 Antigravity 窗口或终端。
- cost meter、本地 token 日统计、历史图表。
- 修改跨平台视觉 spec（`agent-halo.v2.json` 动画参数）。
- 新 `AgentKind` 自动加入已安装用户的启用列表。
- 卸载或删除用户已有的 `~/.gemini` hook（禁用 Agent 时只停止写入/轮询）。

## 背景与调研摘要

### OpenUsage 在做什么

OpenUsage 的 Antigravity provider **只做额度**，不做光环生命周期。探测顺序：

1. 本机 `language_server`（路径含 `antigravity` / `antigravity-ide`）— 最富，含计划名。
2. 本机 `agy` language server。
3. macOS Keychain（service `gemini`，account `antigravity`）→ Google Cloud Code；过期则用 Google OAuth refresh。刷新 token **不写回** Antigravity Keychain，只写 OpenUsage 自己的短缓存。

每个源先打 `RetrieveUserQuotaSummary` / `v1internal:retrieveUserQuotaSummary`（唯一同时给出合并池 + 周窗的接口）。没有该 RPC 的旧构建回退到 per-model 接口，那些接口只有 5h 窗。

配额是剩余比例（`remainingFraction`，满额 = 1）。OpenUsage 展示四条：Gemini Session / Weekly，以及非 Gemini（Claude / GPT-OSS）Session / Weekly。

### AgentHalo 约束

- OAuth 详情面板锁死两行（5h + Weekly）和现有高度；四条表会破坏视觉契约。
- `UsageWindowKind` 只有 `.session` / `.weekly`。
- 新 `AgentKind` 必须 opt-in：`defaultEnabledAgents` 冻结为 Codex / Claude Code / Grok / Pi。
- 切换条槽宽锁死 36pt；启用第 5 个 agent 后总宽变为 `36 × enabledCount`，不得改成 `144 / allCases.count`。
- 现有 hook 二进制已在 Claude / Grok 之间分流（`GROK_SESSION_ID` / `GROK_HOOK_EVENT`）。

### `agy` 生命周期

Antigravity CLI 支持 hooks。全局配置出现过两个路径：

| 路径 | 角色 |
| --- | --- |
| `~/.gemini/config/hooks.json` | 文档中的全局 hooks |
| `~/.gemini/antigravity-cli/hooks.json` | 部分 CLI 构建实际读写的路径 |

工作区 `.agents/hooks.json` 是 per-project，Halo **不写**（启动时不知道用户工作区）。

事件名因构建而异，文档与第三方对照后的并集为：`SessionStart` / `BeforeAgent` / `UserPromptSubmit` / `PreInvocation` / `PreToolUse` / `BeforeTool` / `PostToolUse` / `AfterTool` / `Notification` / `PermissionRequest` / `Stop` / `AfterAgent` / `PostInvocation` / `StopFailure` / `SessionEnd`。配置器按「文件里已有的 key + 本机构造器白名单」合并；reducer 认官方名和别名。

## 已确认的架构决策

1. **仅 macOS**；新代码放在现有 `AgentHaloCore` / `AgentHaloMac`，不新增 SwiftPM target。
2. **额度**沿用 `AuthStore → UsageClient → UsageMapper → UsageProvider → UsageSnapshotCache`，新增 `UsageMonitoring/Antigravity/`。
3. **生命周期**沿用 Claude/Grok hook 模式：hook 写 JSONL → Monitor 增量读 → Reducer → `SessionSnapshot`。
4. **单一 hook 二进制**三分流：Grok 环境仍归 Grok；其余先判 Antigravity，再回落 Claude。
5. **只后台刷新当前焦点 Provider**；OAuth 刷新周期与现有 5 分钟策略一致。
6. **刷新后的 access token 只写入** `~/.agent-halo/cache/antigravity-auth.json`，用 refresh token 的 SHA-256 指纹绑定；**永不写回** Keychain `gemini`/`antigravity`。
7. **额度失败不改变 halo 生命周期状态**。
8. **无 OAuth 时**走 `oauthNeedsSignIn`，不做 API Key 会话卡。
9. **context pill 对 Antigravity 为空**。
10. 禁用 Agent 时立刻停采、清空该 agent 快照；未启用期间不 configure / 不 repair `agy` hooks。

## 领域模型扩展

### AgentKind

```swift
public enum AgentKind: String, Codable, CaseIterable, Equatable, Sendable {
    case codex
    case claudeCode
    case grok
    case pi
    case antigravity
}
```

| 字段 | 值 |
| --- | --- |
| `menuTitle` | `Antigravity` |
| `segmentedTitle` | `AG` |
| `standbyDetail` / `localizedStandbyDetail` | `status.standby_antigravity` |
| `offlineDetail` / `localizedOfflineDetail` | `status.offline_antigravity` |

`CaseIterable` 顺序把 `antigravity` 放在最后。设置胶囊、切换条、菜单「当前显示」都跟 `allCases` 走，无需写死五个。

`HaloSettings.defaultEnabledAgents` **保持**：

```swift
[.codex, .claudeCode, .grok, .pi]
```

升级用户不会自动启用 Antigravity。设置里勾选后进入 `enabledAgents` 并持久化。规范化规则沿用 2026-08-01：去重、按 `allCases` 排序、至少保留一个、焦点必须落在启用集内。

### UsageProviderID

```swift
public enum UsageProviderID: String, Codable, Sendable {
    case codex
    case claude
    case grok
    case antigravity
}
```

`AppDelegate.usageProviderID(for:)`：`.antigravity → .antigravity`。Pi 仍为 `nil`。

设置持久化：`focusedAgent` 字符串值 `"antigravity"`；未知值回退逻辑不变。

### Usage 窗口

Antigravity OAuth 只产出 **两个** `UsageWindow`：

| `kind` | 来源 bucket | `usedPercent` | `resetsAt` | `duration` |
| --- | --- | --- | --- | --- |
| `.session` | `gemini-5h` | `(1 - remainingFraction) * 100`，钳制 0…100 | bucket `resetTime` | 5 小时 = 18_000s |
| `.weekly` | `gemini-weekly` | 同上 | 同上 | 7 天 = 604_800s |

`3p-5h` / `3p-weekly` 以及未识别 `bucketId` **丢弃**，不得并入 Gemini 窗，也不得扩展 `UsageWindowKind`。

旧接口只有 5h 时：只填 `.session`，`.weekly` 缺席，UI 走现有 `quota.no_data`，不伪造周窗。

`planName`：优先 LS `userTier`（格式化规则对齐 OpenUsage `formatPlan`）；没有则为 `nil`。面板仍显示 Provider 名 `Antigravity`。

## 模块与文件边界

```text
src/macos/Sources/AgentHaloCore/
├── HaloModels.swift                         # AgentKind.antigravity
├── HaloSettings.swift                       # 不改 defaultEnabledAgents
├── AgentHaloPaths.swift                     # antigravityStatusLog
├── AgentHaloRuntimeBootstrap.swift          # 启用时 configure AG hooks
├── AntigravityHookConfigurator.swift
├── AntigravityHookStatusMonitor.swift
├── AntigravityHookStatusReducer.swift
└── UsageMonitoring/
    ├── UsageModels.swift                    # UsageProviderID.antigravity
    └── Antigravity/
        ├── AntigravityAuthStore.swift
        ├── AntigravityUsageClient.swift
        ├── AntigravityLanguageServerDiscovery.swift
        ├── AntigravityUsageMapper.swift
        └── AntigravityUsageProvider.swift

src/macos/Sources/AgentHaloMac/
├── AntigravityActivityMonitor.swift
├── AppDelegate.swift                        # 编排、usageProviderID、聚合
└── DetailsPanel.swift                       # 资源名 antigravity.svg；额度区不改高度

src/macos/Sources/ClaudeCodeStatusHook/main.swift   # 第三路分流

src/shared/assets/agent-switch/antigravity.svg
src/shared/locales/{en,zh}.json
```

Windows 的 `AgentKind`、locale 副本、C# 监视器 **不改**。macOS 打包脚本已拷贝整个 `agent-switch/` 目录时，新 SVG 会跟过去；若有按文件名枚举的检查，补上 `antigravity.svg`。

## 额度模块

### AntigravityAuthStore

- 读 Keychain generic password：service `gemini`，account `antigravity`。
- 解码对齐 OpenUsage：`go-keyring-base64` 包裹的 JSON（`access_token` / `refresh_token` / `expiry`）。旧 SQLite `oauthToken` **不读**。
- `isUsable`：过期前 60s 视为不可用（与 OpenUsage `refreshBuffer` 一致）。
- 刷新缓存路径：`AgentHaloPaths.cacheDirectory/antigravity-auth.json`（`~/.../.agent-halo/cache/antigravity-auth.json`）。
- 缓存条目：`accessToken`、`expiresAtMs`、`credentialFingerprint`（refresh token 的 SHA-256）。指纹不符、过期、文件损坏 → 丢弃后重刷。
- `AccountCacheKey.digest`：对稳定账户标识（若 payload 无稳定 id，则对 refresh token 指纹本身）做 SHA-256 hex。**永不**把 raw token 写入日志或 usage 缓存键。
- Keychain 读失败（未解锁 / 权限）→ `credentialStoreUnreadable`，UI `signInAgain`。
- Keychain 无条目 → 无 OAuth，`oauthNeedsSignIn`。

### AntigravityUsageClient

从 OpenUsage 精简移植，行为对齐：

| 调用 | 细节 |
| --- | --- |
| LS RPC | `POST {http\|https}://127.0.0.1:{port}/exa.language_server_pb.LanguageServerService/{method}`，头 `x-codeium-csrf-token`、`Connect-Protocol-Version: 1` |
| LS 方法 | 先 `RetrieveUserQuotaSummary`，再 `GetUserStatus`（计划名 + 旧 5h）；404 视为构建无该 RPC |
| Cloud Code | `https://daily-cloudcode-pa.googleapis.com` 然后 `https://cloudcode-pa.googleapis.com` |
| Cloud Code 路径 | `/v1internal:retrieveUserQuotaSummary`，回退 `/v1internal:fetchAvailableModels` / `/v1internal:retrieveUserQuota` |
| OAuth refresh | `POST https://oauth2.googleapis.com/token`（`grant_type=refresh_token`） |
| LS TLS | 仅 loopback 允许自签；Cloud Code 全校验 |
| User-Agent | Cloud Code 使用 `antigravity`（与 OpenUsage / 官方客户端一致，避免端点拒识） |

Google OAuth installed-app `client_id` / `client_secret` 与 OpenUsage / Antigravity 应用包内公开值相同。这是 installed-app 客户端的既有取舍，不是私密密钥；实现时从 OpenUsage `AntigravityUsageClient` 原样拷贝，不另造一套。

HTTP 错误分类对齐现有 provider：`401/403 → signInAgain`，`429 → rateLimited`，`5xx → serviceUnavailable`，解码失败 → `invalidResponse`，传输失败 → `network`。

### AntigravityLanguageServerDiscovery

从 OpenUsage `LanguageServerDiscovery` 精简移植到 Core，**只服务 Antigravity**：

- 进程名 `language_server`，路径标记 `antigravity` / `antigravity-ide`；读 `--csrf_token`、`--extension_server_port` 及监听端口。
- 进程名 `agy`：无路径标记；同样提取 CSRF / 端口。
- 探测顺序：每个端口先 https 再 http，最后 extension HTTP 端口。
- 发现失败返回 `nil`，provider 进入下一策略，不抛。

### AntigravityUsageMapper

- `parseQuotaSummary`：只认精确 `bucketId` `gemini-5h` / `gemini-weekly`。
- `remainingFraction` 缺失或非有限数 → 丢掉该行（UI no data），不编造 0% 或 100%。
- 未识别 bucket 打日志后跳过。
- 旧 per-model 路径：按 OpenUsage 规则把 Gemini 模型收成一个 5h 池（池内取最差剩余比例）；**不**从旧接口合成 weekly，**不**输出非 Gemini 池。
- `usedPercent = (1 - remainingFraction) * 100`。

### AntigravityUsageProvider

```text
refresh()
  1. probeLS(language_server + antigravity 标记)
  2. probeLS(agy)
  3. probeCloudCode(Keychain ± 刷新缓存)
```

`RetrieveUserQuotaSummary` 一旦解析成功（含零可用 bucket 的空 lines）即结束该源，**不得**再掉进会把缺失配额当成「用尽」的旧接口。

`UsageMonitoringCoordinator` 注册该 provider。只在 `focusedAgent == .antigravity` 时刷新。

登录文案：`usage.warning.sign_in_antigravity`（en: 引导打开 Antigravity 或运行 `agy`；zh 对应）。

## 生命周期模块

### Hook 分流（共用 `status-hook`）

修改 `ClaudeCodeStatusHook/main.swift`：

1. **Grok 优先**（现有）：`GROK_SESSION_ID` 或 `GROK_HOOK_EVENT` 非空 → `grok-status.jsonl`，`source: grok-hook`。
2. **否则 Antigravity**，以下任一成立（hook 进程内不扫进程表）：
   - 环境变量非空：`AGY_SESSION_ID`、`AGY_HOOK_EVENT`、`ANTIGRAVITY_SESSION_ID`、`ANTIGRAVITY_HOOK_EVENT`。本机 `agy` 核对后，注释标明哪些名字真实存在；判定函数仍必须覆盖整份候选，避免漏分流。
   - payload / 环境中的 `transcriptPath` / `transcript_path` 落在 `~/.gemini/antigravity-cli/`，或路径含 `/antigravity-cli/`。
3. 否则保持 Claude。

Antigravity 记录：

- 路径：`AgentHaloPaths.antigravityStatusLog` = `~/.agent-halo/logs/antigravity-status.jsonl`
- `source: "antigravity-hook"`
- 字段同 Claude/Grok：`timestamp`、`event`、`sessionId`、`cwd`、`toolName`、`errorText`、可选 `notificationType` / `permissionMode`
- 事件名写盘时规范为 PascalCase；额外映射：

```text
before_agent / BeforeAgent           → BeforeAgent
after_agent / AfterAgent             → AfterAgent
before_tool / BeforeTool             → BeforeTool
after_tool / AfterTool               → AfterTool
pre_invocation / PreInvocation       → PreInvocation
post_invocation / PostInvocation     → PostInvocation
```

以及现有 Claude/Grok 那组 `session_start` → `SessionStart` 等。

JSONL 滚动策略与 Claude/Grok 相同（同一体积上限与截断常量）。

### AntigravityHookConfigurator

仅当 `enabledAgents.contains(.antigravity)` 时由 `AgentHaloRuntimeBootstrap` 调用。

1. 确认 `~/.agent-halo/bin/status-hook` 已 stage（与 Claude/Grok 共用）。
2. 选择全局 hooks 文件（只选一个写，避免双份事件）：
   1. 若 `~/.gemini/antigravity-cli/hooks.json` 存在 → 合并写入该文件。
   2. 否则若 `~/.gemini/config/hooks.json` 存在 → 合并写入该文件。
   3. 否则创建 `~/.gemini/config/hooks.json`。
3. **按目标文件已有 schema 合并**，不把 Claude/Grok 的 `{"hooks": {Event: [...]}}` 强行套上去。目标文件若已是顶层事件 key（官方 `hooks.json` 常见写法），就在那些 key 下追加 Halo command；若已是带 `hooks` 包装的对象，就沿用该包装。不删除用户其它 hook。Halo 命令已是 preferred `status-hook` 且白名单事件都在 → 不改 mtime。
4. 注册白名单事件（目标 schema 支持 matcher 时，工具类事件 matcher 为 `.*`）：

   `SessionStart`、`BeforeAgent`、`UserPromptSubmit`、`PreInvocation`、`PreToolUse`、`BeforeTool`、`PostToolUse`、`AfterTool`、`Notification`、`PermissionRequest`、`Stop`、`AfterAgent`、`PostInvocation`、`StopFailure`、`SessionEnd`

   若写入后 `agy` 因未知 key 拒载整文件：下一启动只保留该文件里已经存在的事件 key 加上探测到的、该构建已使用的 key。不得覆盖非 Halo 条目。
5. 失败只打日志，不挡启动。不写工作区 `.agents/hooks.json`。

### AntigravityHookStatusReducer

对齐 Claude **最小集**，不搬 Grok 的 `permissionMode` / Auto 等待特例。

| 输入（写盘后的 PascalCase） | 结果 |
| --- | --- |
| `SessionStart`、`BeforeAgent`、`UserPromptSubmit`、`PreInvocation` | `thinking` |
| `PreToolUse`、`BeforeTool` | `working`；`toolName` 走现有 `actionRules` |
| `PostToolUse`、`AfterTool`（无 error） | 回到 `thinking`；短工具保持 `working` **1.8s**（与现有蓝环可读契约一致） |
| `PostToolUseFailure`、带 error 的 `AfterTool` | 工具失败回到 `thinking`；**整轮**失败才 `error` |
| `Notification`（permission / needs input）或 `PermissionRequest` | `attention` |
| `Stop`、`AfterAgent`、`PostInvocation`（成功） | `done` |
| `StopFailure` 或明确 fatal | `error` |
| `SessionEnd` | `idle` |

未知事件：更新 `lastEventAt`，不改状态。坏 JSON 行跳过。

`SessionSnapshot.agent` 必须是 `.antigravity`。`projectName` 默认 `Antigravity`，可用 cwd 末段覆盖。`sessionTitle` / `modelName` 仅当 payload 有值时填写。

### AntigravityActivityMonitor

镜像 `GrokActivityMonitor` / `PiActivityMonitor`：

- utility 队列轮询；主线程只读缓存。
- 焦点是 Antigravity **或** 详情面板可见 → 300ms；否则 2000ms。
- 未启用 → 停表、空快照。
- Presence：近期 hook（与 Grok 相同的 freshness 窗口）或进程名 `agy`。不把 IDE `language_server` 当成 CLI 在线（避免 IDE-only 用户看到虚假 standby）。

### 聚合与 UI

`AppDelegate` 在 `focusedAgent == .antigravity` 时把 AG 快照送进 `SessionAggregator`，其它 agent 快照不混入。优先级沿用现有：attention > error > working > thinking > done > idle。

- 无会话且无 `agy` presence → offline（`status.offline_antigravity`）
- 有 presence 或近期 hook 但无活动 → standby
- 详情面板额度两行不改高度、不改标题文案（仍用 `quota.5h` / `quota.weekly`）
- context pill 不显示数值（空 / `--`，与「无 context 源」一致）
- 点击光环：不激活任何 Antigravity 窗口（与 Claude 相同）

切换条：启用后多一个 36pt 槽；图标 `antigravity.svg`。视觉保持克制，单色标记，与现有 `codex.svg` / `grok.svg` 密度一致。

## 错误处理

| 情况 | 行为 |
| --- | --- |
| Hook 配置失败 | 打日志，App 继续启动 |
| Agent 未启用 | 不写 hooks、不轮询、清空快照 |
| JSONL 单行损坏 | 跳过 |
| Keychain 不可读 / 无条目 | `signInAgain`；不改 halo |
| Refresh 失败且无可用 access token | `signInAgain` |
| 网络 / 5xx | 保留旧快照（stale-while-revalidate） |
| Halo 缓存损坏 | 删除后重刷 |
| LS 端口不是活的 | 试下一端口 / 下一策略 |
| Quota summary 2xx 但不是 summary | 该源回退旧接口；旧接口无 weekly |
| 额度异常 | 警告图标 + 文案；halo 状态机不动 |

日志禁止出现 access token、refresh token、会话正文。

## 测试

自动化放在 `AgentHaloCoreChecks`（及现有 hook 隔离测试），不挡收口的人工项单独列出。

**Mapper**

- OpenUsage 风格 quota-summary fixture → 恰好两条窗：session = gemini-5h，weekly = gemini-weekly。
- `3p-5h` / `3p-weekly` 被丢弃。
- 未识别 `bucketId` 不影响已识别窗。
- 缺 `remainingFraction` 的 bucket 不产出该行。
- 旧 per-model Gemini 响应 → 仅 session；无 weekly。

**Auth 缓存**

- 指纹不匹配 → miss 且丢弃文件。
- 过期 token → miss。
- 不把 raw token 写入 `AccountCacheKey`。

**Hook 分流**

- `agy` 候选环境 / `antigravity-cli` transcript 路径 → 只追加 `antigravity-status.jsonl`。
- `GROK_*` 仍只写 Grok 日志。
- 无上述信号 → Claude 日志。
- 事件名 snake_case / 别名写盘为 PascalCase。

**Reducer**

- 事件表每一行至少一条用例。
- 短工具：PostToolUse 后 1.8s 内保持 working。
- 坏行不崩溃、不改前一状态。

**Settings / 聚合**

- `defaultEnabledAgents` 仍是四个，不含 `.antigravity`。
- `.antigravity` 可启用、可持久化；关闭后焦点离开它。
- 焦点在 AG 时聚合只含 AG 快照。
- `usageProviderID(.antigravity) == .antigravity`。

**资源**

- `agent-switch/antigravity.svg` 存在；打包检查覆盖它。
- `en.json` / `zh.json` 含 standby / offline / sign-in 键。

**人工 live E2E（不挡自动化）**

- 本机启用 Agent 后 `agy` 一轮：thinking → working → done。
- 焦点在 AG 时 Gemini 5h / Weekly 有数或明确 no data / 登录提示。
- 焦点在 Claude 时跑 `agy` 不污染 Claude 光环。

## 用户可见文案

| key | en | zh |
| --- | --- | --- |
| `status.standby_antigravity` | Antigravity is standing by | Antigravity 待机中 |
| `status.offline_antigravity` | Antigravity is not running | Antigravity 未在运行 |
| `usage.warning.sign_in_antigravity` | Start Antigravity or run `agy` and try again. | 请打开 Antigravity 或运行 `agy` 后再试。 |

菜单名 / 切换条用 `AgentKind` 的 `menuTitle` / `segmentedTitle`，不另做 locale key（与 Grok/Pi 一致）。

## 文档更新（实现时一并改）

用户可见：

- `docs/PRODUCT.md`：当前发行说明里的 agent 列表加上 Antigravity（macOS）；写明默认关闭。
- `README.md` / `README.zh-CN.md`：支持列表与颜色/状态含义不改；补充 Antigravity 为可选监控对象。

贡献者：

- `AGENTS.md`：runtime 数据布局补 `antigravity-status.jsonl`；macOS Antigravity hooks 路径。

不把 OpenUsage 内部端点细节写进用户 README。

## 实现顺序建议

1. 领域类型 + locales + SVG + settings 回归（默认仍四开）。
2. 额度四件套 + coordinator 注册 + mapper fixture。
3. Hook 分流 + configurator + JSONL 路径。
4. Reducer + ActivityMonitor + AppDelegate 编排。
5. 详情面板接线（两行额度、空 context、登录文案）。
6. 文档 + 诊断自检里的 agent 枚举（若有写死四项的地方改成 `allCases`）。

## 验收

1. 新安装 / 升级：设置里能看见 Antigravity，默认未勾选；切换条仍是四个槽。
2. 勾选后：切换条出现 `AG`；焦点切到 AG 时 halo 只反映 `agy` hooks。
3. 未登录：额度区登录提示，halo 仍可 idle/offline。
4. 已登录：两行仅为 Gemini 5h / Weekly；不会出现第三条 Claude 池。
5. `agy` 事件不进入 `claude-status.jsonl` / `grok-status.jsonl`。
6. 取消勾选：停止 hook 修复与轮询；不删用户 `~/.gemini` 文件。
7. Windows 树无行为变化。
