# Windows Grok Build 完整对齐设计

## 文档状态

- 日期：2026-07-29
- 状态：设计已确认（方案 A）；待写实施计划与实现
- 实现范围：AgentHalo **Windows only**（C# / WPF，`src/windows/`）
- 产品原则：见 [PRODUCT.md](../../PRODUCT.md)
- 跨平台契约：见 [CROSS_PLATFORM_SHARED_CONTRACT.md](../../CROSS_PLATFORM_SHARED_CONTRACT.md)
- macOS 先例（功能面与行为源）：[2026-07-25-macos-grok-build-usage-lifecycle-design.md](./2026-07-25-macos-grok-build-usage-lifecycle-design.md)
- Windows 额度先例：`CodexUsageMonitor.cs`
- Windows 生命周期先例：`ClaudeCodeMonitor.cs`（hook writer / configurator / reducer / monitor）

## 目标

在现有 Windows Codex / Claude Code 之上，为 **Grok Build（Grok CLI）** 做到与 macOS **功能面完整对齐**：

1. **OAuth 周额度展示**：详情面板焦点切到 Grok 时，显示 Weekly 使用百分比与重置时间。
2. **最小生命周期光环**：thinking / working / done / needs you / error。
3. **状态隔离**：Grok hook 事件写入独立 JSONL，不得污染 Claude Code 状态日志。
4. **三段焦点 UI**：`Codex | CC | Grok`（菜单 + 详情分段切换）。
5. **Presence**：STANDBY vs OFFLINE（`active_sessions.json`，不依赖昂贵进程探测）。
6. **Context pill**：有可见 Grok 会话时显示 context 使用百分比（signals / updates.jsonl）。

用户确认的产品选择：

- 实现路径：**方案 A** — 按 macOS 模块职责 1:1 移植到 Windows 原生模式，独立 Grok 路径，不抽跨语言抽象，不把 Grok 塞进 Claude 分支。
- 分段标签：**`Grok`**（不是 `GB`）
- **Pay-as-you-go：不做、不显示**

## 非目标

- 修改 macOS 实现或共享视觉 spec（`agent-halo.v2.json` 动画参数）。
- Pay-as-you-go / on-demand cap / prepaid balance / 货币余额 / 本地消费估算。
- Grok API Key 模式的 console 额度或 credits 曲线。
- context pill 精细化、会话标题深挖、subagent 树可视化（仅对齐 macOS 已交付的最小 path）。
- 点击光环 foreground Grok 终端窗口。
- 清理历史可能已写入 `claude-code-status.jsonl` 的 Grok 旧事件（新事件停止混入即可）。
- 引入 .NET 新依赖或新构建系统（继续 `csc.exe` 编译全部 `*.cs`）。

## 背景

### 现状缺口

| 能力 | macOS | Windows（当前） |
| --- | --- | --- |
| `AgentKind.grok` | 有 | 无（仅 Codex / ClaudeCode） |
| 焦点设置 `"grok"` | 有 | Settings 只接受 codex/claudeCode |
| Hook 分流 | `GROK_*` → `grok-build-status.jsonl` | `ClaudeHookStatusWriter` 始终写 Claude JSONL |
| Grok hooks 配置 | `GrokHookConfigurator` → `~/.grok/hooks/` | 无 |
| 生命周期 monitor/reducer | 有 | 无 |
| OAuth Weekly 额度 | `GrokUsageProvider` | 无（仅有 CodexUsageMonitor 模式） |
| 详情三段切换 | Codex / CC / Grok | Codex / CC |
| Context pill | GrokSessionContextReader | 无 |
| i18n 字符串 | 有 | **已预置**（en/zh 含 standby/offline/sign_in_grok） |

### Windows 平台约束

- 单可执行文件 `AgentHalo.exe`；Claude hooks 通过 `AgentHalo.exe --claude-hook <Event>` 入口（见 `Program.cs`）。
- **不**使用独立 staged hook 二进制；Grok 与 Claude 共用同一入口，靠进程环境变量分流。
- 数据目录：用户主目录下的 `.agent-halo`、`.grok`（与 macOS 路径约定一致：`%USERPROFILE%\.agent-halo`、`%USERPROFILE%\.grok`）。
- 设置目录：`%LOCALAPPDATA%\CodexHalo\settings.json`（现有不变）。
- JSON：`System.Web.Script.Serialization.JavaScriptSerializer`（与现有代码一致）。
- HTTP：沿用 `CodexUsageMonitor` 的 `HttpWebRequest` / 同步后台线程模式，避免引入新 HTTP 栈。

## 已确认的架构决策

1. **仅 Windows**；新代码放在 `src/windows/`，优先新文件（如 `GrokMonitor.cs`、`GrokUsageMonitor.cs`），必要时小改现有类接线。
2. **生命周期**对齐 Claude hook 模式：hook 写 JSONL → Monitor 增量读 → Reducer → `SessionSnapshot`，`Agent = AgentKind.Grok`。
3. **额度**对齐 `CodexUsageMonitor` 风格的单例 monitor：Auth 读改写 + token 刷新 + billing 拉取 + 缓存/stale；仅 Weekly 一条。
4. **单一 hook 入口**分流：扩展现有 `ClaudeHookStatusWriter`（或抽共享 writer 私有辅助），避免第二套 CLI 参数。
5. **焦点模型**扩展为三选一：`codex` / `claudeCode` / `grok`；分段标题 `Codex` / `CC` / `Grok`。
6. **只后台刷新当前焦点 Provider**：焦点为 Grok 时才触发/优先 Grok 额度刷新（与 macOS 一致）。
7. **OAuth token 临近过期自动刷新**，原子写回 `~/.grok/auth.json` 对应 entry，不得丢弃其他账号条目。
8. **Pay-as-you-go 不实现、不渲染**。
9. **额度失败不改变 halo 生命周期状态**。
10. **Presence 只读文件系统**（`active_sessions.json`）；不在 UI 热路径上 spawn `tasklist`/`wmic` 等可能挂起的子进程（对齐 macOS「禁止 ps 挂死 activity 队列」）。

## 领域模型扩展

### AgentKind

```csharp
public enum AgentKind
{
    Codex,
    ClaudeCode,
    Grok
}
```

- 设置序列化：`FocusedAgent` 字符串 `"grok"`
- `GetFocusedAgent` / `SetFocusedAgent` 支持三值；未知值回退 `Codex`
- 菜单与分段：`Grok`

### AgentEvidenceSource

增加 `GrokHook`（与 `ClaudeHook` 对称），reducer 产出快照时填入。

### Usage 窗口

Grok OAuth 仅产出 **一个** weekly 窗口（映射到现有 `UsageMetrics`）：

| 字段 | 来源 |
| --- | --- |
| `HasWeekly` / `WeeklyUsedPercent` | `config.creditUsagePercent`（缺省 0，钳制 0…100） |
| `WeeklyResetUtc` | `config.currentPeriod.end` |
| `HasFiveHour` / `HasMonthly` | 始终 false |

非 weekly 周期：不伪造 weekly；走 noData / 空态。  
**忽略** `onDemandCap` / `onDemandUsed` / `prepaidBalance`。

额度状态枚举可复用或镜像 Codex：`NoData` / `Fresh` / `Stale` / `SignInAgain` / `ApiKey`（ApiKey 首版可不完整，无 OAuth 时 `SignInAgain`）。

## 模块设计

### 文件布局（建议）

```text
src/windows/
├── GrokMonitor.cs              # Hook writer 分流扩展点的配套：configurator、reducer、monitor、presence、context
├── GrokUsageMonitor.cs         # Auth + HTTP + mapper + 缓存刷新
├── Models.cs                   # AgentKind.Grok 等
├── Settings.cs                 # focusedAgent "grok"
├── ClaudeCodeMonitor.cs        # ClaudeHookStatusWriter 分流逻辑
├── HaloWindow.cs               # 焦点 Grok 聚合、菜单、刷新 tick
├── DetailsWindow.cs            # 三段 UI、Grok 额度与 context
├── Program.cs                  # 若需 --grok-hook 别名则可选（默认不新增，靠 env 分流）
└── Diagnostics.cs              # --self-check 用例
```

若 `GrokMonitor.cs` 过大，可再拆 `GrokUsageMonitor.cs`（已建议）与把 context reader 内聚在同一文件底部；不强制过度拆分。

### 1. Hook 分流（ClaudeHookStatusWriter）

修改 `WriteFromStandardInput`：

1. 检测环境：`GROK_SESSION_ID` 或 `GROK_HOOK_EVENT` 任一非空 → Grok 路径。
2. Grok 路径：
   - 状态文件：`%USERPROFILE%\.agent-halo\grok-build-status.jsonl`
   - `source`: `"grok-hook"`
   - 默认 sessionId 回退：`grok`（非 `claude-code`）
   - **不得**追加到 `claude-code-status.jsonl`
3. Claude 路径保持现有行为。
4. 事件名规范化：stdin/argv 中的 `pre_tool_use` 等 → 写盘 `PreToolUse`（PascalCase），便于复用 reducer。
5. 日志滚动：与 Claude 相同 `RotateTriggerBytes` / `RotateKeepBytes`。
6. 互斥锁：Grok 使用独立 mutex 名（例如 `Local\\AgentHalo-GrokBuildStatusLog-...`），避免与 Claude 争用。

字段提取继续兼容 snake_case / camelCase。

### 2. GrokHookConfigurator

启动时（`HaloWindow.OnLoaded`，与 `ClaudeHookConfigurator.Configure()` 并列）：

1. 取当前进程 `MainModule.FileName` 作为 command 可执行文件。
2. 写入或合并 `%USERPROFILE%\.grok\hooks\agent-halo-status.json`，为最小事件集注册 command hook：

   | 事件 | matcher |
   | --- | --- |
   | SessionStart, UserPromptSubmit | 无 |
   | PreToolUse, PostToolUse, PostToolUseFailure | `.*` |
   | Notification, Stop, StopFailure, SessionEnd | 无 |
   | PreCompact, PostCompact | `""`（空字符串，与 macOS 一致） |

3. command 形如：`"<exe>" --claude-hook <Event>`（引号规则对齐 `ClaudeHookConfigurator.Quote`）。
4. 幂等：已全部配置则不改 mtime。
5. 失败只打日志，不得阻止启动。

说明：即使 Grok 仍因 Claude-compat 触发 Claude settings 中的同一 hook，env 分流也会落到 grok JSONL；原生 `~/.grok/hooks` 保证关闭 compat 后仍可用。

### 3. GrokHookStatusReducer / Monitor

事件映射（与 macOS 一致）：

| Hook 事件 | 状态 | action 示意 |
| --- | --- | --- |
| SessionStart | idle | Ready |
| UserPromptSubmit | thinking | Thinking |
| PreToolUse | working | friendly tool action |
| PostToolUse / PostToolUseFailure | working → 短时后 thinking | Reviewing result / Tool failed |
| Notification + permission_prompt | attention | Awaiting permission |
| Stop | done | Complete |
| StopFailure | error | Grok stopped with an error |
| SessionEnd | idle | Ready |
| PreCompact / PostCompact | working / thinking | 与 Claude 一致 |

安全网：

- Post-tool ~1.8s auto-fade（与 Claude 同量级）
- PreToolUse stuck 超时回 thinking（与 Claude / macOS 同量级，约 180s）
- `permission_prompt` 不自动 fade

工具名归一：至少 `run_terminal_command` → `shell_command`；其余 `GeneratedHaloSpec.friendlyAction`。

`SessionSnapshot.Agent = AgentKind.Grok`；默认项目名 `"Grok"`。

Monitor：增量读 `grok-build-status.jsonl`，按 sessionId 维护 reducer；对外提供 `Refresh()` / 快照列表（对齐 `ClaudeHookStatusMonitor` API 风格，便于 `HaloWindow` 接线）。

### 4. Presence 与聚合

- `GrokActiveSessionsReader`：解析 `%USERPROFILE%\.grok\active_sessions.json`（数组 entries；兼容 macOS 已测形状）。
- `HasLiveSession` / `isPresent`：用于 idle 时 STANDBY vs OFFLINE。
- `HaloWindow.RefreshState`：`focusedAgent == Grok` 时：
  - 聚合仅 `Agent == Grok` 的 hook 快照
  - idle + present → STANDBY + `status.standby_grok`
  - idle + !present → OFFLINE + `status.offline_grok`
  - done 结算策略对齐 Claude（短 done 窗口后回 ready；**不做** Codex 式 click-to-activate）
- 前台 tick：焦点 Grok 时刷新 Grok monitor；可与 Claude 共用 timer，按焦点分支。

### 5. GrokUsageMonitor

路径与端点（与 macOS / OpenUsage 同源）：

| 项 | 内容 |
| --- | --- |
| 凭据 | `%USERPROFILE%\.grok\auth.json`（OIDC entry 字典） |
| Token 刷新 | `POST https://auth.x.ai/oauth2/token` |
| 额度 | `GET https://cli-chat-proxy.grok.com/v1/billing?format=credits` |
| 鉴权头 | `Authorization: Bearer …`、`X-XAI-Token-Auth: xai-grok-cli` |
| Plan 可选 | `GET .../v1/settings` → `subscription_tier_display`（失败不整体失败） |

Auth 行为：

- 默认 client_id：`b1a00492-073a-47ea-816f-4c329264a828`（与 CLI / macOS 一致）
- `needsRefresh`：过期前 5 分钟
- account digest：对稳定身份字段 SHA256 hex，**永不**日志 raw token
- save：读-改-写同一 entry；文件已存在但不可解析时**拒绝覆盖**
- 刷新周期：5 分钟；stale：10 分钟（对齐 CodexUsageMonitor）

HTTP 错误：`401 → SignInAgain`，`429` cooldown，`5xx` 可 stale/retry；解码失败 → invalid/stale，不得崩溃。

对外 API 建议：

- `TryRead(out UsageMetrics metrics)` / `Status` / `RequestRefresh()` / `Updated` 事件  
- 与 `DetailsWindow` 现有 Codex 额度渲染路径对接；Grok 仅填 weekly 字段。

登录提示：复用 i18n `usage.warning.sign_in_grok`。

### 6. Context pill

`GrokSessionContextReader`（Windows 版）：

- 根：`%USERPROFILE%\.grok\sessions\`（或 macOS 已用结构；实现时以 macOS `GrokSessionContextReader` 为准做路径/编码对齐）
- 优先 live `updates.jsonl` 的 `totalTokens`；否则 `signals.json` 的 `contextWindowUsage` / token 比
- 会话标题：`generated_title` / summary 回退（若 macOS 已有且 Details 需要则接；否则最小只做 percent）
- **仅当**焦点 Grok 且展示列表中存在真实 Grok session（非占位 `threadId == "grok"`）时显示；STANDBY/OFFLINE 不粘滞（对齐 macOS soft-hold 策略：若 Windows Details 已有 Claude soft-hold，Grok 复用同一 hold 参数）

### 7. UI

1. `DetailsWindow` 分段：三栏图标/点击区 `Codex | CC | Grok`；选中态 alpha 对齐现有两段逻辑。
2. Grok 图标：优先嵌入 `src/shared/assets/agent-switch/grok.svg` 几何，或与 macOS 官方 logo path 一致的精简 path；避免商业品牌复杂造型。
3. 托盘/右键菜单「监控对象」增加 Grok，勾选与 `settings.FocusedAgent` 同步。
4. OAuth + focus Grok：body 渲染 weekly 进度条；无 Pay-as-you-go badge。
5. Provider 行名称：`Grok`；plan 有则显示（若 UI 已有 plan 槽）。

### 8. 构建与打包

- `build-windows.ps1` 已 `Get-ChildItem *.cs`，新文件自动编入，无需改列表。
- 若嵌入 grok 图标资源：同步 resource 参数；若纯 Geometry path 则无需资源文件。
- 不新增独立 `AgentHaloHook.exe`。

## 数据流

```text
                    %USERPROFILE%\.grok\auth.json
                            │
                            v
                   GrokUsageMonitor ──> UsageMetrics (weekly)
                            │
HaloWindow / Details ───────┤
                            │
            focus == Grok ──+──> DetailsWindow (quota + context)
                            │
Grok / Claude hooks ──> AgentHalo.exe --claude-hook
           │                      │
           │              env 分流 │
           │                      +──> grok-build-status.jsonl
           │                      +──> claude-code-status.jsonl (仅 Claude)
           v
   GrokHookStatusMonitor ──> Reducer ──> SessionSnapshot(Grok)
           │
           v
   HaloWindow aggregate(focusedAgent) ──> Halo 状态
```

## 隐私与安全

- 不上传会话内容；额度仅请求 `auth.x.ai` 与 `cli-chat-proxy.grok.com`。
- 日志与缓存不得写入 access/refresh token；account 标识仅哈希。
- Token 写回仅更新必要字段，原子写。
- Hook JSONL 仅生命周期元数据（timestamp、event、sessionId、cwd、toolName、notificationType、errorText、source），不含 prompt/补全正文。

## 测试与验收

### 自动化（`Diagnostics --self-check`）

1. **Settings**：`focusedAgent` 持久化 `"grok"`；非法值回退 codex。
2. **Hook 分流**：带 `GROK_SESSION_ID` 的写入只进 grok JSONL；无 GROK env 只进 claude JSONL；互不泄漏 session id。
3. **事件名规范化**：`pre_tool_use` → 盘上 `PreToolUse`。
4. **Configurator**：临时 home 下写出 hooks JSON；幂等二次调用不破坏。
5. **Reducer**：prompt → thinking；PreToolUse → working；permission 保持；Stop → done；StopFailure → error。
6. **Credits 解码**：含 percent、缺省 0%、非 weekly 不产出 weekly、忽略 onDemand。
7. **Auth store**：多 entry 只改当前；损坏文件不覆盖；digest 无 token 明文。
8. **聚合**：焦点 Grok 时忽略 Claude/Codex working；Grok done 结算后回 ready。
9. **回归**：既有 Codex/Claude self-check 全部通过。

### 手动验收（Windows 真机）

1. 已 `grok login`：焦点 Grok 显示 Weekly % 与重置时间。
2. Grok 会话中 prompt / tool：光环 thinking / working；结束 done 或 idle。
3. 焦点切到 CC：不显示正在进行的 Grok 活动。
4. 暂停监听 / 离线行为与其他 agent 一致。
5. 无 Pay-as-you-go UI。

## 实施顺序建议

1. 领域模型：`AgentKind.Grok`、Settings、i18n 接线（字符串已在 locales）。
2. Hook 分流 + Configurator + Monitor/Reducer + HaloWindow 聚合与菜单。
3. Details 三段 UI + 图标。
4. GrokUsageMonitor + Details 额度接线。
5. Context reader + pill 策略。
6. Diagnostics self-check + README/PRODUCT 文档同步（Windows 现为 Codex/CC only 的表述）。

## 风险

| 风险 | 缓解 |
| --- | --- |
| billing API 变更 | 严格解码；失败 stale；跟随 macOS/OpenUsage |
| Token 写回多账号损坏 | 读全文件、只改当前 entry、原子写；解析失败 abort |
| 三段 UI 拥挤 | 短标签与现有两段同高度缩放 |
| Claude settings 与 grok hooks 双触发 | 分流幂等写同一 grok JSONL；reducer 按 session+时间去重 |
| Windows 无独立 hook 二进制升级路径 | 主程序升级即升级 hook 行为；command 始终指向当前 exe |
| 本机无 Windows 编译器时无法本地编过 | 实现时保持 .NET 4.x 兼容语法；CI/用户 Windows 构建验证 |

## 成功标准

- 用户在 Windows 上可将监控对象切到 **Grok**，并看到与 CLI 大致一致的 **Weekly 额度**。
- Grok 工作中光环状态可读；完成与错误可区分。
- Claude 焦点下不被 Grok 活动干扰。
- 不出现 Pay-as-you-go UI；不影响 Codex/Claude 主路径。
- macOS 功能面（额度 + 生命周期 + 三段 UI + presence + 最小 context）在 Windows 上齐备。

## 与 macOS 的有意差异

| 点 | macOS | Windows |
| --- | --- | --- |
| Hook 载体 | staged `claude-code-status-hook` 二进制 | 主程序 `--claude-hook` |
| 设置路径 | App 侧 HaloSettings 文件 | `%LOCALAPPDATA%\CodexHalo\settings.json` |
| 额度架构 | AuthStore/Client/Mapper/Provider 四件套 | 单文件 `GrokUsageMonitor`（对齐 CodexUsageMonitor） |
| Activity 线程模型 | GrokActivityMonitor 后台队列 | 复用 HaloWindow foreground timer + monitor.Refresh |

行为与数据契约以本节与 macOS 设计的共享语义为准；上述差异仅为平台实现形态，不降低产品能力。
