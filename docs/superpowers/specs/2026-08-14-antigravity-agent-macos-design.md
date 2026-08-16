# macOS Antigravity Agent（额度 + 最小生命周期）设计

## 文档状态

- 日期：2026-08-14
- 状态：设计已确认；实施计划见 [2026-08-14-macos-antigravity-agent-implementation.md](../plans/2026-08-14-macos-antigravity-agent-implementation.md)
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
3. **最小生命周期光环**：`agy` 与 Antigravity 2.0 桌面 hook 驱动 thinking / working / done / attention / error。
4. **状态隔离**：`agy` hook 事件只写入 Antigravity JSONL，不得进入 Claude / Grok / Pi 日志。

用户确认的产品选择：

- 方案：**按 Grok 的形状加 agent**（共用 `status-hook` 分流 + OpenUsage 同款额度探测）
- 平台：**仅 macOS**
- 额度行：**只显示 Gemini 池两行**（`gemini-5h` / `gemini-weekly`）
- 生命周期：**`agy` CLI + Antigravity 2.0 桌面 hook**（不做 IDE 会话文件推断）
- 额度源：**LS 优先，否则 Keychain + Cloud Code**（完整对齐 OpenUsage 探测顺序）
- 分段标签：**`AG`**
- 默认启用：**否**（不进入 `HaloSettings.defaultEnabledAgents`）

## 非目标

- Windows 实现或共享 C# 运行时改动。
- 从会话文件（`conversations/` / `.pb`）推断 thinking / working / done。桌面应用走与 CLI 同一套 `~/.gemini/config/hooks.json`；IDE（`/antigravity-ide/`）仍排除。
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

### `agy` 生命周期（本机核对，2026-08-14）

`agy` 二进制会从 **多个** `hooks.json` 加载 **named hook group**（日志：`loaded %d named hooks from %d hooks.json file(s)`）。本机实际文件是：

```json
// ~/.gemini/config/hooks.json
{
  "orca-status": {
    "PreInvocation": [ { "type": "command", "command": "…", "timeout": 10 } ],
    "PostInvocation": [ { "type": "command", "command": "…", "timeout": 10 } ],
    "Stop": [ { "type": "command", "command": "…", "timeout": 10 } ],
    "PostToolUse": [ { "matcher": "*", "hooks": [ { "type": "command", "command": "…" } ] } ]
  }
}
```

同一文件里两种 entry 形状并存：`PreInvocation` / `PostInvocation` / `Stop` 是扁平 `type+command`；`PostToolUse` 带 `matcher` + 嵌套 `hooks`。

`~/.gemini/antigravity-cli/hooks.json` **不存在**。`~/.gemini/antigravity-cli/settings.json` 和 `~/.gemini/settings.json` 里另有 Gemini/插件风格的 `hooks.SessionStart` / `BeforeTool`——那是另一套管线，**Halo 不写**，以免污染 Gemini CLI。

工作区 `.agents/hooks.json` 是 per-project，Halo **不写**。

`agy` 二进制里确认的生命周期相关事件：`PreInvocation`（文案 "Before each LLM invocation"）、`PreToolUse`、`PostToolUse`、`Stop`。本机 `hooks.json` 另外登记了 `PostInvocation`。第三方文章里的 `SessionStart` / `BeforeAgent` / `PermissionRequest` **未**作为 `agy` hooks.json 事件写入白名单。

进程环境（二进制字符串，非臆造）：`ANTIGRAVITY_AGENT`、`ANTIGRAVITY_TRAJECTORY_ID`。没有发现 `AGY_SESSION_ID` / `AGY_HOOK_EVENT`。

## 已确认的架构决策

1. **仅 macOS**；新代码放在现有 `AgentHaloCore` / `AgentHaloMac`，不新增 SwiftPM target。
2. **额度**沿用 `AuthStore → UsageClient → UsageMapper → UsageProvider → UsageSnapshotCache`，新增 `UsageMonitoring/Antigravity/`。
3. **生命周期**沿用 Claude/Grok hook 模式：hook 写 JSONL → Monitor 增量读 → Reducer → `SessionSnapshot`。
4. **单一 hook 二进制**三分流：Grok 环境仍归 Grok；其余先判 Antigravity，再回落 Claude。
5. **只后台刷新当前焦点 Provider**；OAuth 刷新周期与现有 5 分钟策略一致。
6. **刷新后的 access token 只写入** `~/.agent-halo/cache/antigravity-auth.json`，用 refresh token 的 SHA-256 指纹绑定；**永不写回** Keychain `gemini`/`antigravity`。
7. **额度失败不改变 halo 生命周期状态**。
8. **无 Keychain 且无 LS 时**走 `oauthNeedsSignIn`；有 LS 无 Keychain 仍按 OAuth UI 刷额度。不做 API Key 会话卡，`resolveAccess` 禁止返回 `.apiKey`。
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
- Keychain 读失败（未解锁 / 权限）→ `credentialStoreUnreadable`。若此时 LS 也发现不了，UI `signInAgain`。
- **`resolveAccess` 永远不要返回 `.apiKey`**（否则详情面板会走会话卡，与「不做 API Key 卡」冲突）。
- Coordinator 只在 `.oauth` 时调用 `refresh()`。因此：
  - Keychain 有可用 token → `.oauth`（真实 access/refresh）。
  - Keychain 没有，但 `language_server` / `agy` LS 可发现 → 仍返回 `.oauth`，`accessToken` 为空字符串，`source = .file(path: cacheDirectory/antigravity-ls)`，`accountKey.digest` 用固定本地身份 `"antigravity-ls"` 的 SHA-256。`refresh()` 走 LS，不打 Cloud Code。
  - 两者都没有 → `.oauthNeedsSignIn`。

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

**不要**复用现有 `URLSessionUsageHTTPClient` 打 LS：它把 URL 拼成 `https://{host}{path}`，没有 loopback、没有自签、也接不了 `127.0.0.1:port`。LS 单独做一个允许 insecure loopback 的 client（对齐 OpenUsage `URLSessionHTTPClient(allowsInsecureLoopback:)`），Cloud Code / Google OAuth 继续用校验证书的 client。

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
   - `ANTIGRAVITY_AGENT` 非空（`agy` / 桌面 agent 会设 `ANTIGRAVITY_AGENT=1`）。
   - `ANTIGRAVITY_TRAJECTORY_ID` 或 `ANTIGRAVITY_CONVERSATION_ID` 非空。
   - payload / 环境中的 `transcriptPath` / `transcript_path` 含 `/antigravity-cli/`（CLI）或 `/antigravity/`（Antigravity 2.0 桌面）。**不要**把 `/antigravity-ide/` 当 AG。
3. 否则保持 Claude。

实现时用本机 `agy` 打一轮，确认事件名是 argv、stdin JSON，还是二者皆空。若 `agy` 调 `status-hook` 时既无 argv 也无 event 字段，配置器改为 `status-hook PreInvocation` 这种带事件名的 command（与旧 Claude 写法相同），不得静默 `exit 0`。

Antigravity 记录：

- 路径：`AgentHaloPaths.antigravityStatusLog` = `~/.agent-halo/logs/antigravity-status.jsonl`
- `source: "antigravity-hook"`
- 字段同 Claude/Grok：`timestamp`、`event`、`sessionId`、`cwd`、`toolName`、`errorText`
- `sessionId` 优先 `ANTIGRAVITY_TRAJECTORY_ID` / `ANTIGRAVITY_CONVERSATION_ID`，否则 payload 的 `session_id` / `sessionId` / `conversation_id` / `conversationId`，再否则 `"antigravity"`
- 事件名写盘时规范为 PascalCase。`agy` 白名单：

```text
pre_invocation / PreInvocation     → PreInvocation
post_invocation / PostInvocation   → PostInvocation
pre_tool_use / PreToolUse          → PreToolUse
post_tool_use / PostToolUse        → PostToolUse
stop / Stop                        → Stop
```

stdin 若出现其它 Claude/Grok 别名，normalize 后交给 reducer；未知事件只更新 `lastEventAt`。

JSONL 滚动策略与 Claude/Grok 相同（同一体积上限与截断常量）。

### AntigravityHookConfigurator

仅当 `enabledAgents.contains(.antigravity)` 时由 `AgentHaloRuntimeBootstrap` 调用。

1. 确认 `~/.agent-halo/bin/status-hook` 已 stage（与 Claude/Grok 共用）。
2. **只写** `~/.gemini/config/hooks.json`（`agy` 的 named-group 文件）。不存在则创建 `{}` 再合并。不写 `~/.gemini/settings.json`、不写 `~/.gemini/antigravity-cli/settings.json`、不写工作区 `.agents/hooks.json`。
3. 以 named group `agent-halo-status` 合并，**不得改动**同文件里其它 group（例如本机的 `orca-status`）。group 已指向 preferred `status-hook` 且五件事件齐全 → 不改 mtime。
4. 只注册本机 / 二进制已证实的事件，并按该事件在现有文件里的形状写：

   | 事件 | entry 形状 |
   | --- | --- |
   | `PreInvocation` | `[{ "type": "command", "command": "<status-hook> PreInvocation", "timeout": 10 }]` |
   | `PostInvocation` | 同上 |
   | `Stop` | 同上 |
   | `PreToolUse` | `[{ "matcher": "*", "hooks": [{ "type": "command", "command": "<status-hook> PreToolUse", "timeout": 10 }] }]` |
   | `PostToolUse` | 同上 |

   不注册 `SessionStart` / `BeforeAgent` / `PermissionRequest` / `SessionEnd` 等未证实 key。
5. 失败只打日志，不挡启动。禁用 Agent 时不删该 group（与「不删用户 `~/.gemini`」一致）；只是不再 repair。

### AntigravityHookStatusReducer

对齐 Claude hook reducer **最小集**，不搬 Grok 的 `permissionMode` / Auto 等待特例。**不要**把 `PostInvocation` 当成回合结束——`agy` 文案是每次 LLM 调用前后。

| 输入（写盘后的 PascalCase） | 结果 |
| --- | --- |
| `PreInvocation` | `thinking` |
| `PostInvocation` | 仍在回合内 → `thinking`（若正在 working hold 内则保持 working） |
| `PreToolUse` | 立刻 `working`；`toolName` 走现有 `actionRules`。桌面/CLI 在授权弹窗**之前**就打出此事件，**单独不算** attention |
| 会话库 `steps.status == 9`（`CORTEX_STEP_STATUS_WAITING`） | 对齐 Grok `events.jsonl` 的 `permission_requested`：先 arm，`pendingPermissionAttentionDelay`（0.25s）后 `attention` / Awaiting permission |
| 同一 step 离开 WAITING → RUNNING/DONE/PENDING | `permission_resolved` allow：恢复 PreToolUse 的 working |
| 同一 step 离开 WAITING → CANCELED/ERROR/CLEARED | deny → `attention` / Permission denied |
| `Notification` + `permission_prompt` / `PermissionRequest` | 只 arm，不立刻画紫（与 Grok Strategy A 相同） |
| `PermissionDenied` | `attention` / Permission denied |
| `PostToolUse` | 与 `ClaudeHookStatusReducer` 相同：先 `working` / Reviewing result，再按现有 fade（hook 侧 0.65s review，live 可见性 `ClaudeContextUsageConstants.workingVisibilityExtension` = 1.8s）回到 `thinking` |
| `PostToolUse` 带 error | 工具失败回到 `thinking`；**整轮**失败才 `error` |
| `Stop` | `done` |
| 明确 fatal（若 payload 带失败） | `error` |

`attention` 不自动 fade。未知事件：更新 `lastEventAt`，不改状态。坏 JSON 行跳过。仍不把 `PermissionRequest` 写入 `hooks.json`（agy 白名单未证实该 key）。会话库路径：`~/.gemini/antigravity/conversations/<sessionId>.db` 与 `~/.gemini/antigravity-cli/conversations/<sessionId>.db`。

`SessionSnapshot.agent` 必须是 `.antigravity`。`projectName` 默认 `Antigravity`，可用 cwd 末段覆盖。`sessionTitle` / `modelName` 仅当 payload 有值时填写。

### AntigravityActivityMonitor

镜像 `GrokActivityMonitor` / `PiActivityMonitor`：

- utility 队列轮询；主线程只读缓存。
- 焦点是 Antigravity **或** 详情面板可见 → 300ms；否则 2000ms。
- 未启用 → 停表、空快照。
- Presence：近期 hook（与 Grok 相同的 freshness 窗口）、进程名 `agy`，或 Antigravity 2.0 桌面应用进程名恰好为 `Antigravity`（`/Applications/Antigravity.app`，不是 IDE）。不把 `language_server` / `Antigravity Helper` 当成独立在线信号。打开该桌面应用为 standby；thinking / working / done 来自 `agy` 与桌面应用共用的 hooks。

### 聚合与 UI

`AppDelegate` 在 `focusedAgent == .antigravity` 时把 AG 快照送进 `SessionAggregator`，其它 agent 快照不混入。优先级沿用现有：attention > error > working > thinking > done > idle。

- 无会话且无 `agy` / `Antigravity` presence → offline（`status.offline_antigravity`）
- 有 presence 或近期 hook 但无活动 → standby
- 详情面板额度两行不改高度、不改标题文案（仍用 `quota.5h` / `quota.weekly`）
- context pill 不显示数值（空 / `--`，与「无 context 源」一致）。`DetailsPanel.update` 里 `switch focusedAgent` 必须加 `.antigravity`，不得误入 Claude/Grok context 分支。
- `DetailsContentResolver.providerName` / `warning` 的 `UsageProviderID` switch 补 `.antigravity`（编译器也会逼改）。
- 点击光环：不激活任何 Antigravity 窗口（与 Claude 相同）
- 其它写死 `switch AgentKind` 的地方（`AppDelegate`、`SettingsWindowController` 图标、`HaloInteractionChecks` 源码断言）一并补 case；能改成 `allCases` 的检查不要再写死四个。

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

- `ANTIGRAVITY_AGENT=1` / `ANTIGRAVITY_TRAJECTORY_ID` / `ANTIGRAVITY_CONVERSATION_ID`，或 transcript 含 `/antigravity-cli/` / `/antigravity/` → 只追加 `antigravity-status.jsonl`。
- 路径含 `/antigravity-ide/` → **不**当作 AG（回归：不得误分流）。
- `GROK_*` 仍只写 Grok 日志。
- 无上述信号 → Claude 日志。
- 事件名 snake_case 写盘为 PascalCase。
- configurator 写出的 `hooks.json` 含 named group `agent-halo-status`，且不改现有其它 group。

**Reducer**

- 事件表每一行至少一条用例。
- `PostInvocation` 不得变成 `done`。
- `PostToolUse` fade 与 Claude hook reducer 一致。
- 坏行不崩溃、不改前一状态。

**额度 access**

- 无 Keychain 但 LS 可发现 → `resolveAccess` 为 `.oauth`，refresh 走 LS。
- 两者都无 → `.oauthNeedsSignIn`，**不是** `.apiKey`。

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
