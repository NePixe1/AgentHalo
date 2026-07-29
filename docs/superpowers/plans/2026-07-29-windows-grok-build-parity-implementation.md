# Windows Grok Build Full Parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 AgentHalo Windows 上把 Grok Build 接成第三个监控对象：OAuth Weekly 额度、最小 hook 生命周期光环、三段焦点 UI、presence/standby、最小 context pill，且 Grok 事件不污染 Claude Code 状态日志。

**Architecture:** 方案 A。生命周期对齐 `ClaudeCodeMonitor.cs`（hook writer → JSONL → monitor/reducer → `SessionSnapshot`），但 `Agent = Grok` 且独立 `grok-build-status.jsonl`。额度对齐 `CodexUsageMonitor.cs` 单例风格（auth 读改写 + token 刷新 + billing 映射 + 缓存/stale），仅 Weekly。Hook 入口仍是 `AgentHalo.exe --claude-hook <Event>`，靠 `GROK_SESSION_ID` / `GROK_HOOK_EVENT` 分流。UI 在 `DetailsWindow` / 托盘菜单扩展为 `Codex | CC | Grok`。

**Tech Stack:** C# / .NET Framework 4.x、WPF、`csc.exe`、`System.Web.Script.Serialization`、`HttpWebRequest`、现有 `Diagnostics --self-check` / `--self-test`

**Spec:** [2026-07-29-windows-grok-build-parity-design.md](../specs/2026-07-29-windows-grok-build-parity-design.md)

## Global Constraints

- **只改 Windows 运行时**（`src/windows/`）与必要的文档/README；**不改** macOS 行为与 `agent-halo.v2.json` 动画参数。
- 分段标签固定为 **`Grok`**（不是 `GB`）。
- **Pay-as-you-go / onDemandCap / prepaid：不实现、不渲染。**
- 额度主条使用总池 `creditUsagePercent`；仅 weekly 周期产出 `HasWeekly`。
- 焦点为 Grok 时才优先刷新 Grok 额度；默认 5 分钟周期、10 分钟 stale。
- Token 临期 5 分钟刷新；原子写回 `%USERPROFILE%\.grok\auth.json` 单 entry；解析失败拒绝覆盖。
- 日志禁止 access/refresh token、认证头、原始凭据 JSON。
- 额度失败不得改变 halo 生命周期状态。
- Hook 检测到 Grok 时**禁止**写入 `claude-code-status.jsonl`。
- Presence **不得** spawn `tasklist`/`wmic`；仅读 `active_sessions.json`（可选 `OpenProcess` 做 PID 存活，不得起子进程）。
- 保持 .NET 4.x 兼容语法（无 C# 8+ 仅有语法若 CI 用老 csc；优先与现有文件一致的 `delegate`/`out` 风格）。
- 每项任务 TDD：先加失败 self-check → 确认失败 → 最小实现 → 聚焦检查通过 → 提交。
- 提交前 `git status --short`，只暂存本任务文件。
- 验证（在 Windows 上）：

```powershell
# 从仓库根目录，按 scripts/build-windows.ps1 构建后：
.\outputs\AgentHalo\AgentHalo.exe --self-check
# 若仓库入口是 --self-test <path>，以 Program.cs / Diagnostics 现有签名为准；
# 计划中统一写 Diagnostics.RunSelfCheck 扩展，与现有 Assert 块同一路径。
```

在 macOS 开发机上无法运行 `csc` 时：仍完成代码与 self-check 源码；在 PR 描述中注明需 Windows 构建验证。

---

## 目标文件总览

新增：

```text
src/windows/GrokMonitor.cs          # Configurator, Writer helpers if needed, Reducer, Monitor, ActiveSessions, ContextReader
src/windows/GrokUsageMonitor.cs     # Auth + HTTP + Mapper + cache/timer
```

修改：

```text
src/windows/Models.cs                 # AgentKind.Grok, AgentEvidenceSource.GrokHook
src/windows/Settings.cs               # focusedAgent "grok"
src/windows/ClaudeCodeMonitor.cs      # ClaudeHookStatusWriter 分流 + 事件名规范化
src/windows/HaloWindow.cs             # Grok 焦点聚合、菜单、tick、Configure
src/windows/DetailsWindow.cs          # 三段开关、Grok 额度/context
src/windows/Diagnostics.cs            # self-check 用例
src/windows/Program.cs                # 仅当需要可测入口时小改（默认不必新增 CLI）
README.md / README.zh-CN.md / docs/PRODUCT.md  # Windows 现支持 Grok 的表述（最后任务）
```

公开接口（本计划锁定）：

```csharp
public enum AgentKind { Codex, ClaudeCode, Grok }

// Settings
// FocusedAgent string: "codex" | "claudeCode" | "grok"
// GetFocusedAgent() / SetFocusedAgent(AgentKind)

// Hook output
// %USERPROFILE%\.agent-halo\grok-build-status.jsonl  source == "grok-hook"
// %USERPROFILE%\.grok\hooks\agent-halo-status.json

// GrokHookStatusReducer
//   ctor(string threadId)
//   void Consume(string jsonLine, DateTime nowUtc)
//   void ApplyWorkingVisibility(DateTime nowUtc)
//   SessionSnapshot Snapshot { get; }

// GrokHookStatusMonitor
//   bool Refresh()
//   List<SessionSnapshot> Snapshots()

// GrokHookConfigurator.Configure() / Configure(string home, string executablePath)

// GrokActiveSessionsReader.HasLiveSession(string home)
// GrokSessionContextReader.Read(string sessionId, string cwd) -> GrokSessionContextSnapshot?

// GrokUsageMonitor.Instance
//   bool TryRead(out UsageMetrics metrics)
//   GrokUsageDataStatus Status { get; }  // NoData|Fresh|Stale|SignInAgain|ApiKey
//   void RequestRefresh()
//   event Action Updated
```

本地化：`src/shared/locales` 与 `src/windows/locales` 已含 `status.standby_grok` / `status.offline_grok` / `usage.warning.sign_in_grok`，Task 1 只接线不新增文案（除非缺失）。

---

### Task 1: AgentKind.Grok + Settings 持久化

**Files:**
- Modify: `src/windows/Models.cs`
- Modify: `src/windows/Settings.cs`
- Modify: `src/windows/Diagnostics.cs`（settings 持久化 Assert）

**Interfaces:**
- Produces: `AgentKind.Grok`；`AgentEvidenceSource.GrokHook`；`HaloSettings` 读写 `"grok"`

- [ ] **Step 1: 写失败检查**

在 `Diagnostics.cs` 的 settings / focus 相关 Assert 附近追加（或新建临时目录 round-trip）：

```csharp
// Focused agent grok persistence
string settingsDir = Path.Combine(Path.GetTempPath(),
    "agent-halo-grok-settings-" + Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(settingsDir);
// 若 SettingsStorage 写死 AppDirectory，则：
// 直接测 HaloSettings 序列化 API，或反射/临时替换路径。
// 最小：构造 HaloSettings，SetFocusedAgent(Grok)，GetFocusedAgent() == Grok；
// Deserialize 含 "focusedAgent":"grok" 的 JSON 后 GetFocusedAgent() == Grok；
// 非法 "focusedAgent":"nope" 加载后回退 Codex。
HaloSettings grokSettings = new HaloSettings();
grokSettings.SetFocusedAgent(AgentKind.Grok);
Assert(grokSettings.GetFocusedAgent() == AgentKind.Grok,
    "settings should accept grok focus");
Assert(String.Equals(grokSettings.FocusedAgent, "grok",
    StringComparison.OrdinalIgnoreCase), "serialized focusedAgent is grok");
```

若现有 self-check 对 `AgentKind` 穷尽 switch 会编译失败，先把检查写在 Task 1 实现后能编译的位置——但 TDD 仍要求：**先改 Models 到能加测试，再实现 Settings 行为**。推荐顺序：先扩 enum（编译）→ 加失败的 Settings 测试（Get/Set 仍不认 grok）→ 实现 Settings。

- [ ] **Step 2: 运行检查确认失败**

```powershell
# Windows 构建后
.\outputs\AgentHalo\AgentHalo.exe --self-check
```

Expected: `GetFocusedAgent` 仍把 `"grok"` 当 Codex，或 Save/Load 校验把 grok 重置为 codex → Assert 失败。

- [ ] **Step 3: 最小实现**

`Models.cs`：

```csharp
public enum AgentKind
{
    Codex,
    ClaudeCode,
    Grok
}

// AgentEvidenceSource 增加：
// GrokHook
```

`Settings.cs`：

```csharp
public AgentKind GetFocusedAgent()
{
    if (String.Equals(FocusedAgent, "claudeCode", StringComparison.OrdinalIgnoreCase))
    {
        return AgentKind.ClaudeCode;
    }
    if (String.Equals(FocusedAgent, "grok", StringComparison.OrdinalIgnoreCase))
    {
        return AgentKind.Grok;
    }
    return AgentKind.Codex;
}

public void SetFocusedAgent(AgentKind agent)
{
    if (agent == AgentKind.ClaudeCode)
    {
        FocusedAgent = "claudeCode";
    }
    else if (agent == AgentKind.Grok)
    {
        FocusedAgent = "grok";
    }
    else
    {
        FocusedAgent = "codex";
    }
}
```

Load 校验：接受 `codex` / `claudeCode` / `grok`，否则重置 `"codex"`。

全仓库 `switch (AgentKind)` / `== ClaudeCode` 二分逻辑：**本任务只保证编译**——暂时在缺省分支保持原行为或 `default`；HaloWindow/Details 完整接线在后续任务。若编译因未穷尽 switch 失败，对每个 switch 加 `case AgentKind.Grok:` 先 `break` 或走 Claude 旁路占位，并在注释标明 Task 2/5 完善。

- [ ] **Step 4: 运行检查**

Expected: grok settings Assert PASS；既有 Codex/Claude Assert 不回归。

- [ ] **Step 5: Commit**

```bash
git add src/windows/Models.cs src/windows/Settings.cs src/windows/Diagnostics.cs
# 若为编译占位改了 HaloWindow/Details，一并暂存
git commit -m "feat(windows): add AgentKind.Grok and focusedAgent persistence"
```

---

### Task 2: Hook 分流 + 事件名规范化

**Files:**
- Modify: `src/windows/ClaudeCodeMonitor.cs`（`ClaudeHookStatusWriter`）
- Modify: `src/windows/Diagnostics.cs`

**Interfaces:**
- Produces: Grok 路径写 `%USERPROFILE%\.agent-halo\grok-build-status.jsonl`，`source=grok-hook`；Claude 路径不变；事件名写盘 PascalCase

- [ ] **Step 1: 写失败检查**

```csharp
// Isolation: Grok env must not write claude-code-status.jsonl
string home = Path.Combine(Path.GetTempPath(),
    "agent-halo-hook-iso-" + Guid.NewGuid().ToString("N"));
string agentHalo = Path.Combine(home, ".agent-halo");
Directory.CreateDirectory(agentHalo);
// 将 Writer 改为可注入 home 的重载（推荐）：
// WriteFromStandardInput(eventName, home, envGrokSessionId, envGrokHookEvent, stdinBody)
// 生产路径：从 Environment 读 GROK_*，home = UserProfile。

int code = ClaudeHookStatusWriter.WriteForTest(
    eventName: "pre_tool_use",
    home: home,
    grokSessionId: "test-grok-session",
    grokHookEvent: "PreToolUse",
    stdinJson: "{\"sessionId\":\"test-grok-session\",\"cwd\":\"/tmp/proj\",\"toolName\":\"run_terminal_command\"}");
Assert(code == 0, "grok hook writer exit 0");
string grokPath = Path.Combine(agentHalo, "grok-build-status.jsonl");
string claudePath = Path.Combine(agentHalo, "claude-code-status.jsonl");
Assert(File.Exists(grokPath), "Grok path writes grok-build-status.jsonl");
string grokText = File.ReadAllText(grokPath);
Assert(grokText.IndexOf("grok-hook", StringComparison.Ordinal) >= 0, "source grok-hook");
Assert(grokText.IndexOf("\"PreToolUse\"", StringComparison.Ordinal) >= 0,
    "snake_case event normalizes to PreToolUse");
Assert(!File.Exists(claudePath) ||
    File.ReadAllText(claudePath).IndexOf("test-grok-session", StringComparison.Ordinal) < 0,
    "Grok session must not appear in claude jsonl");

// Claude path without GROK env
ClaudeHookStatusWriter.WriteForTest("PreToolUse", home, null, null,
    "{\"sessionId\":\"claude-1\",\"cwd\":\"/tmp/c\",\"toolName\":\"Bash\"}");
string claudeText = File.ReadAllText(claudePath);
Assert(claudeText.IndexOf("claude-hook", StringComparison.Ordinal) >= 0, "claude source");
Assert(File.ReadAllText(grokPath).IndexOf("claude-1", StringComparison.Ordinal) < 0,
    "Claude session must not appear in grok jsonl");
```

- [ ] **Step 2: 运行确认失败**

Expected: 始终写 claude JSONL / 无规范化 → Assert 失败。

- [ ] **Step 3: 最小实现**

在 `ClaudeHookStatusWriter`：

1. 增加内部重载，接受 `home` 与 Grok env 字符串（生产 `WriteFromStandardInput` 读 `Environment.GetEnvironmentVariable`）。
2. `bool isGrok = !String.IsNullOrEmpty(grokSessionId) || !String.IsNullOrEmpty(grokHookEvent);`
3. `record["source"] = isGrok ? "grok-hook" : "claude-hook";`
4. 文件名：`isGrok ? "grok-build-status.jsonl" : "claude-code-status.jsonl"`
5. sessionId 默认：Grok 用 `"grok"`，Claude 用 `"claude-code"`
6. `NormalizeEventName(resolvedEvent)`：下划线转 PascalCase（`pre_tool_use` → `PreToolUse`）；已是 PascalCase 则保留
7. Mutex：Grok 使用新名 `Local\\AgentHalo-GrokBuildStatusLog-7A0CE36F`（或新 GUID），Claude 保持原名
8. 数据目录：`Path.Combine(home, ".agent-halo")`（可注入 home）

```csharp
internal static string NormalizeEventName(string eventName)
{
    if (String.IsNullOrWhiteSpace(eventName))
    {
        return eventName;
    }
    if (eventName.IndexOf('_') < 0)
    {
        return eventName;
    }
    string[] parts = eventName.Split(new[] { '_' }, StringSplitOptions.RemoveEmptyEntries);
    StringBuilder sb = new StringBuilder();
    foreach (string part in parts)
    {
        if (part.Length == 0) continue;
        sb.Append(Char.ToUpperInvariant(part[0]));
        if (part.Length > 1)
        {
            sb.Append(part.Substring(1).ToLowerInvariant());
        }
    }
    return sb.ToString();
}
```

- [ ] **Step 4: 运行检查**

Expected: 隔离 + 规范化 Assert PASS。

- [ ] **Step 5: Commit**

```bash
git add src/windows/ClaudeCodeMonitor.cs src/windows/Diagnostics.cs
git commit -m "feat(windows): route Grok hooks to grok-build-status.jsonl"
```

---

### Task 3: GrokHookConfigurator + Reducer + Monitor + ActiveSessions

**Files:**
- Create: `src/windows/GrokMonitor.cs`
- Modify: `src/windows/Diagnostics.cs`

**Interfaces:**
- Produces: 见文件总览中的 Configurator / Reducer / Monitor / ActiveSessionsReader API

- [ ] **Step 1: 写失败检查**

```csharp
// Configurator
string home = Path.Combine(Path.GetTempPath(),
    "agent-halo-grok-cfg-" + Guid.NewGuid().ToString("N"));
string fakeExe = Path.Combine(home, "AgentHalo.exe");
File.WriteAllText(fakeExe, "x");
GrokHookConfigurator.Configure(home, fakeExe);
string hooksPath = Path.Combine(home, ".grok", "hooks", "agent-halo-status.json");
Assert(File.Exists(hooksPath), "writes agent-halo-status.json");
string hooksJson = File.ReadAllText(hooksPath);
Assert(hooksJson.IndexOf("--claude-hook", StringComparison.Ordinal) >= 0,
    "command uses --claude-hook");
Assert(hooksJson.IndexOf("UserPromptSubmit", StringComparison.Ordinal) >= 0,
    "registers UserPromptSubmit");
// Idempotent: second call does not throw; content still valid
DateTime mtime1 = File.GetLastWriteTimeUtc(hooksPath);
Thread.Sleep(20);
GrokHookConfigurator.Configure(home, fakeExe);
// 允许 mtime 不变（理想）或内容语义不变

// Reducer lifecycle
GrokHookStatusReducer r = new GrokHookStatusReducer("s1");
DateTime t0 = new DateTime(2026, 7, 25, 0, 0, 0, DateTimeKind.Utc);
r.Consume(
    "{\"timestamp\":\"2026-07-25T00:00:01Z\",\"event\":\"UserPromptSubmit\",\"sessionId\":\"s1\",\"cwd\":\"/p/AgentHalo\",\"source\":\"grok-hook\"}",
    t0.AddSeconds(1));
Assert(r.Snapshot.Agent == AgentKind.Grok, "agent kind Grok");
Assert(r.Snapshot.State == HaloState.Thinking, "prompt -> thinking");
r.Consume(
    "{\"timestamp\":\"2026-07-25T00:00:02Z\",\"event\":\"PreToolUse\",\"sessionId\":\"s1\",\"cwd\":\"/p/AgentHalo\",\"toolName\":\"run_terminal_command\",\"source\":\"grok-hook\"}",
    t0.AddSeconds(2));
r.ApplyWorkingVisibility(t0.AddSeconds(3));
Assert(r.Snapshot.State == HaloState.Working, "tool -> working");
r.Consume(
    "{\"timestamp\":\"2026-07-25T00:00:04Z\",\"event\":\"Notification\",\"sessionId\":\"s1\",\"notificationType\":\"permission_prompt\",\"source\":\"grok-hook\"}",
    t0.AddSeconds(4));
Assert(r.Snapshot.State == HaloState.Attention, "permission -> attention");
r.Consume(
    "{\"timestamp\":\"2026-07-25T00:00:05Z\",\"event\":\"Stop\",\"sessionId\":\"s1\",\"source\":\"grok-hook\"}",
    t0.AddSeconds(5));
Assert(r.Snapshot.State == HaloState.Done, "stop -> done");

// Active sessions
string grokDir = Path.Combine(home, ".grok");
Directory.CreateDirectory(grokDir);
File.WriteAllText(Path.Combine(grokDir, "active_sessions.json"),
    "[{\"session_id\":\"abc\",\"cwd\":\"/tmp/x\"}]");
Assert(GrokActiveSessionsReader.HasLiveSession(home),
    "array entry without pid counts as present");
```

- [ ] **Step 2: 运行确认失败**

Expected: 类型不存在 / 文件未创建。

- [ ] **Step 3: 实现 GrokMonitor.cs**

**GrokHookConfigurator**（对齐 macOS 事件集；command 为 Windows 引号规则，复用 `ClaudeHookConfigurator.Quote` 若为 public/internal，否则复制 Quote 逻辑）：

```csharp
public static class GrokHookConfigurator
{
    public static void Configure()
    {
        try
        {
            string exe = Process.GetCurrentProcess().MainModule.FileName;
            Configure(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), exe);
        }
        catch (Exception ex)
        {
            SettingsStorage.Log("Grok hook configure failed: " + ex.Message);
        }
    }

    public static void Configure(string home, string executablePath)
    {
        // Write %home%\.grok\hooks\agent-halo-status.json
        // hooks[event] = [ { matcher?, hooks: [ { type: "command", command: "\"exe\" --claude-hook Event" } ] } ]
        // Idempotent if already fully configured for same command marker
    }
}
```

**GrokHookStatusReducer**：以 `ClaudeHookStatusReducer` 为模板复制，改动：

- 默认 `ThreadId = "grok"`，`ProjectName = "Grok"`，`Agent = AgentKind.Grok`
- `EvidenceSource = AgentEvidenceSource.GrokHook`（若字段在 Snapshot 上使用）
- StopFailure action：`"Grok stopped with an error"`
- `NormalizeToolName`：`run_terminal_command` / `bash` → `shell_command`
- 保留 Post-tool fade、thinking 0.7s、stuck 180s、permission 不 fade

**GrokHookStatusMonitor**：镜像 `ClaudeHookStatusMonitor`，路径 `grok-build-status.jsonl`，按 sessionId 维护 `GrokHookStatusReducer`。

**GrokActiveSessionsReader**：

```csharp
public static class GrokActiveSessionsReader
{
    public static bool HasLiveSession(string home)
    {
        // parse active_sessions.json array or {sessions|active_sessions}
        // if any entry has pid>0, use OpenProcess/GetExitCodeProcess for liveness
        // if no pids, any entry => true
        // never Process.Start
    }
}
```

- [ ] **Step 4: 运行检查**

Expected: configurator / reducer / active sessions Assert PASS。

- [ ] **Step 5: Commit**

```bash
git add src/windows/GrokMonitor.cs src/windows/Diagnostics.cs
git commit -m "feat(windows): add Grok hook configurator, reducer, and monitor"
```

---

### Task 4: HaloWindow 接线 — 焦点 Grok 聚合 + 菜单 + 启动配置

**Files:**
- Modify: `src/windows/HaloWindow.cs`
- Modify: `src/windows/Diagnostics.cs`（聚合过滤 Assert，若可纯函数测则放 reducers；否则测 helper）

**Interfaces:**
- Consumes: `GrokHookStatusMonitor`、`GrokHookConfigurator`、`GrokActiveSessionsReader`
- Produces: 焦点 Grok 时 halo/tray/details 只反映 Grok

- [ ] **Step 1: 写失败检查**

若聚合逻辑可抽为 `static AggregateSnapshot BuildGrokAggregate(...)` 便于测：

```csharp
List<SessionSnapshot> mixed = new List<SessionSnapshot>
{
    new SessionSnapshot { ThreadId = "c1", Agent = AgentKind.ClaudeCode,
        State = HaloState.Working, Active = true, LastEventUtc = DateTime.UtcNow,
        ProjectName = "C", Action = "Edit" },
    new SessionSnapshot { ThreadId = "g1", Agent = AgentKind.Grok,
        State = HaloState.Working, Active = true, LastEventUtc = DateTime.UtcNow,
        ProjectName = "GrokProject", Action = "Running command" }
};
AggregateSnapshot grokAgg = HaloWindow.BuildGrokAggregateForTest(
    mixed, paused: false, present: true, now: DateTime.UtcNow);
Assert(grokAgg.FocusedAgent == AgentKind.Grok, "focus stamp");
Assert(grokAgg.State == HaloState.Working, "uses grok session");
Assert(grokAgg.Sessions.Count == 1 && grokAgg.Sessions[0].ThreadId == "g1",
    "filters out Claude");

AggregateSnapshot idlePresent = HaloWindow.BuildGrokAggregateForTest(
    new List<SessionSnapshot>(), false, true, DateTime.UtcNow);
// 期望 STANDBY 或 Idle+后续 visual 路径使用 status.standby_grok ——
// 与 GetClaudeAggregate 一致：sessions 空时 Idle；standby 由 RefreshState 的
// HasLiveSession 分支 set SteadyDone。二选一，与 Claude 对称即可。
```

- [ ] **Step 2: 运行确认失败**

- [ ] **Step 3: 实现 HaloWindow**

1. 字段：`GrokHookStatusMonitor grokMonitor = new GrokHookStatusMonitor();`
2. `OnLoaded`：`GrokHookConfigurator.Configure();`（在 Claude 配置后）
3. `OnForegroundTick`：若 focus == Grok，`grokMonitor.Refresh()` 后 `RefreshState()`
4. `RefreshState` 增加 Grok 分支（镜像 Claude 分支）：

```csharp
if (settings.GetFocusedAgent() == AgentKind.Grok)
{
    grokMonitor.Refresh();
    aggregate = GetGrokAggregate();
    // demoState 预览同 Claude
    bool showGrokStandby = !demoState.HasValue &&
        aggregate.State == HaloState.Idle &&
        GrokActiveSessionsReader.HasLiveSession(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile));
    visual.SetSteadyDone(showGrokStandby);
    // ... SetState STANDBY vs aggregate
    // displayAggregate Detail = L10n status.standby_grok / offline_grok
    details.UpdateContent(...);
    UpdateAgentMenuChecks();
    return;
}
```

5. `GetGrokAggregate()`：过滤 `Agent == Grok`，Done 可见窗口约 8s（同 Claude），错误 1h；空 sessions → Idle + offline 文案占位（standby 在外层）
6. 托盘菜单：`grokAgentItem = new ToolStripMenuItem("Grok")`；`UpdateAgentMenuChecks` 三选一勾选
7. 任何 `GetFocusedAgent() == ClaudeCode` 二分处补 Grok 分支

- [ ] **Step 4: 运行检查**

Expected: 聚合过滤 Assert PASS；应用启动不抛（手动或 smoke）。

- [ ] **Step 5: Commit**

```bash
git add src/windows/HaloWindow.cs src/windows/Diagnostics.cs
git commit -m "feat(windows): wire Grok focus aggregate and tray menu"
```

---

### Task 5: DetailsWindow 三段开关 UI

**Files:**
- Modify: `src/windows/DetailsWindow.cs`
- Modify: `src/windows/Diagnostics.cs`（可选 UI self-check：AgentSelected 事件）

**Interfaces:**
- Produces: 三栏 `Codex | CC | Grok` 切换；`AgentSelected(Grok)`

- [ ] **Step 1: 写失败检查**

若现有 Diagnostics 已创建 `DetailsWindow` 并切换 agent（见 `claudePanel` 用例），扩展：

```csharp
// 在无显示环境下可能需 STA 线程 —— 沿用现有 Details 测试模式
// 期望：选择 Grok 后 currentAgent / 开关样式 / AgentSelected 触发 Grok
```

若 UI 难测，本任务以代码审查 + 编译为准，Assert 至少覆盖 `FriendlyStatusDetail` offline 分支对 Grok 返回 `status.offline_grok`：

```csharp
AggregateSnapshot offlineGrok = new AggregateSnapshot
{
    State = HaloState.Idle,
    Label = "OFFLINE",
    FocusedAgent = AgentKind.Grok,
    Sessions = new List<SessionSnapshot>()
};
// 若 FriendlyStatusDetail 为 private，改为 internal static 供测
string detail = DetailsWindow.FriendlyStatusDetailForTest(offlineGrok, offlineGrok.Sessions);
Assert(detail.IndexOf("Grok", StringComparison.OrdinalIgnoreCase) >= 0 ||
    detail == L10n.Instance["status.offline_grok"],
    "offline grok detail");
```

- [ ] **Step 2: 运行确认失败**

- [ ] **Step 3: 实现 UI**

1. `CreateAgentSwitch`：宽度从 ~98 调到 ~132–148；**三列**；thumb 宽约 40–44，位置按 index 0/1/2 动画（0, ~48, ~96 需实测）。
2. 增加 `grokBorder` + Grok path 图标（来自 `grok.svg` 的 path `d`，fill `#111111`；或简化单 path）。
3. `UpdateAgentSwitch` / `MoveSwitchThumb`：按 `AgentKind` 三态，不用 `bool codex`。
4. `FriendlyStatusDetail` idle offline：`Grok` → `status.offline_grok`。
5. `RefreshSupplementalData`：`Grok` 走额度组（Task 6）占位——本任务可先 `RefreshGrokDetails()` 显示 quota 空态或复用 `RefreshQuota` 但 metrics 为空。
6. 选中/未选中 opacity：与 Codex/Claude 一致。

Grok icon path（来自 shared svg，可直接作常量）：

```csharp
private const string GrokIconPath =
    "M9.27 15.29l7.978-5.897c.391-.29.95-.177 1.137.272..."; // 完整 d 从 grok.svg 拷贝
```

- [ ] **Step 4: 运行检查**

- [ ] **Step 5: Commit**

```bash
git add src/windows/DetailsWindow.cs src/windows/Diagnostics.cs
git commit -m "feat(windows): three-way Codex/CC/Grok agent switch"
```

---

### Task 6: GrokUsageMonitor（Weekly OAuth 额度）

**Files:**
- Create: `src/windows/GrokUsageMonitor.cs`
- Modify: `src/windows/DetailsWindow.cs`
- Modify: `src/windows/HaloWindow.cs`（焦点 Grok 时 `RequestRefresh`）
- Modify: `src/windows/Diagnostics.cs`

**Interfaces:**
- Produces: `GrokUsageMonitor`；`TryMapCredits` 纯函数便于测；Details 显示 weekly 条 + sign-in 文案

- [ ] **Step 1: 写失败检查（纯映射 + Auth）**

```csharp
// Credits mapper
string weeklyBody =
    "{\"config\":{\"creditUsagePercent\":42.5,\"currentPeriod\":{\"type\":\"USAGE_PERIOD_TYPE_WEEKLY\",\"start\":\"2026-07-20T00:00:00Z\",\"end\":\"2026-07-27T00:00:00Z\"}}}";
UsageMetrics mapped;
Assert(GrokUsageResponseMapper.TryMap(weeklyBody, out mapped), "map weekly");
Assert(mapped.HasWeekly && !mapped.HasFiveHour && !mapped.HasMonthly, "only weekly");
Assert(Math.Abs(mapped.WeeklyUsedPercent - 42.5) < 0.01, "percent");
Assert(mapped.WeeklyResetUtc.Year == 2026, "reset");

// Absent percent => 0
string zeroBody =
    "{\"config\":{\"currentPeriod\":{\"type\":\"USAGE_PERIOD_TYPE_WEEKLY\",\"start\":\"2026-07-20T00:00:00Z\",\"end\":\"2026-07-27T00:00:00Z\"}}}";
Assert(GrokUsageResponseMapper.TryMap(zeroBody, out mapped) &&
    mapped.WeeklyUsedPercent == 0, "absent percent is 0");

// Non-weekly => no weekly window
string monthlyBody =
    "{\"config\":{\"creditUsagePercent\":10,\"currentPeriod\":{\"type\":\"USAGE_PERIOD_TYPE_MONTHLY\",\"start\":\"2026-07-01T00:00:00Z\",\"end\":\"2026-08-01T00:00:00Z\"}}}";
Assert(GrokUsageResponseMapper.TryMap(monthlyBody, out mapped) && !mapped.HasWeekly,
    "non-weekly does not fake weekly");

// Auth store multi-entry persist (temp auth.json)
string home = Path.Combine(Path.GetTempPath(),
    "agent-halo-grok-auth-" + Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(Path.Combine(home, ".grok"));
string authPath = Path.Combine(home, ".grok", "auth.json");
File.WriteAllText(authPath,
    "{\n  \"iss::client-a\": {\"key\":\"tok-a\",\"refresh_token\":\"ra\",\"expires_at\":\"2099-01-01T00:00:00Z\",\"user_id\":\"u1\"},\n  \"iss::client-b\": {\"key\":\"tok-b\",\"refresh_token\":\"rb\",\"expires_at\":\"2099-01-01T00:00:00Z\",\"user_id\":\"u2\"}\n}\n");
// Persist rotation for entry matching tok-a only
GrokAuthStore.PersistForTest(home, oldAccessToken: "tok-a",
    newAccess: "tok-a2", newRefresh: "ra2", expiresAt: DateTime.UtcNow.AddHours(1));
string after = File.ReadAllText(authPath);
Assert(after.IndexOf("tok-a2", StringComparison.Ordinal) >= 0, "updated access");
Assert(after.IndexOf("tok-b", StringComparison.Ordinal) >= 0, "other entry preserved");
// Corrupt file must refuse overwrite
File.WriteAllText(authPath, "NOT-JSON");
bool threw = false;
try { GrokAuthStore.PersistForTest(...); }
catch { threw = true; }
Assert(threw || /* returns false */, "corrupt auth not overwritten");
```

- [ ] **Step 2: 运行确认失败**

- [ ] **Step 3: 实现 GrokUsageMonitor.cs**

结构建议（同一文件多类型）：

| 类型 | 职责 |
| --- | --- |
| `GrokUsageDataStatus` | NoData, Fresh, Stale, SignInAgain, ApiKey |
| `GrokAuthStore` | 读 `%home%\.grok\auth.json`；`Resolve`；`NeedsRefresh`；`Persist` |
| `GrokUsageHttp` | POST token；GET billing；GET settings；headers 见下 |
| `GrokUsageResponseMapper` | `TryMap(body, out UsageMetrics)` |
| `GrokUsageMonitor` | 单例、Timer 5min、TryRead、Updated 事件 |

HTTP 常量：

```csharp
const string DefaultClientId = "b1a00492-073a-47ea-816f-4c329264a828";
const string TokenAuthHeader = "xai-grok-cli";
// POST https://auth.x.ai/oauth2/token
// GET  https://cli-chat-proxy.grok.com/v1/billing?format=credits
// GET  https://cli-chat-proxy.grok.com/v1/settings
// Headers: Authorization: Bearer <token>, X-XAI-Token-Auth: xai-grok-cli,
//          Accept: application/json, User-Agent: AgentHalo
```

`UsageMetrics` 映射：仅设 `HasWeekly`、`WeeklyUsedPercent`（clamp 0–100）、`WeeklyResetUtc`。

刷新 worker：对齐 CodexUsageMonitor 错误分类（401 SignInAgain、429 cooldown、其它 Stale）。

**DetailsWindow：**

```csharp
private void RefreshSupplementalData()
{
    if (IsOfflineAggregate(currentAggregate)) { ApplyOfflinePlaceholders(); return; }
    if (currentAgent == AgentKind.ClaudeCode) { RefreshClaudeDetails(); return; }
    if (currentAgent == AgentKind.Grok) { RefreshGrokDetails(); return; }
    RefreshCodexDetails();
}

private void RefreshGrokDetails()
{
    // 显示 quotaGroup；隐藏 fiveHourRow；只显示 weekRow
    // GrokUsageMonitor.Instance.TryRead / Status
    // SignInAgain -> 使用 L10n usage.warning.sign_in_grok（与 Codex 警告槽一致）
    // 无 context 时 pill 由 Task 7 处理；本任务 context 可 collapsed
}
```

订阅 `GrokUsageMonitor.Instance.Updated`（与 Codex 对称）；dispose/unload 时取消。

**HaloWindow：** `SetFocusedAgent(Grok)` 或 RefreshState Grok 分支调用 `GrokUsageMonitor.Instance.RequestRefresh()`。

- [ ] **Step 4: 运行检查**

Expected: mapper/auth Assert PASS；网络失败不崩溃。

- [ ] **Step 5: Commit**

```bash
git add src/windows/GrokUsageMonitor.cs src/windows/DetailsWindow.cs \
  src/windows/HaloWindow.cs src/windows/Diagnostics.cs
git commit -m "feat(windows): add Grok OAuth weekly usage monitor"
```

---

### Task 7: GrokSessionContextReader + context pill

**Files:**
- Modify: `src/windows/GrokMonitor.cs`（追加 reader 类型）
- Modify: `src/windows/DetailsWindow.cs` / `HaloWindow.cs`（identity + percent）
- Modify: `src/windows/Diagnostics.cs`

**Interfaces:**
- Produces: `GrokSessionContextReader.Read(sessionId, cwd)`；Details 在可见 Grok session 时显示 percent

- [ ] **Step 1: 写失败检查**

对齐 macOS fixture 形状：

```csharp
string root = Path.Combine(Path.GetTempPath(),
    "agent-halo-grok-ctx-" + Guid.NewGuid().ToString("N"));
string cwd = Path.Combine(root, "proj");
string sessionId = "sess-1";
string enc = GrokSessionContextReader.EncodeWorkspaceDirectory(cwd);
string sessionDir = Path.Combine(root, ".grok", "sessions", enc, sessionId);
Directory.CreateDirectory(sessionDir);
File.WriteAllText(Path.Combine(sessionDir, "signals.json"),
    "{\"contextWindowUsage\":26,\"contextTokensUsed\":130000,\"contextWindowTokens\":500000,\"primaryModelId\":\"grok-4.5\"}");
// summary 可选
var snap = new GrokSessionContextReader(Path.Combine(root, ".grok", "sessions"))
    .Read(sessionId, cwd);
Assert(snap != null && Math.Abs(snap.ContextUsedPercent - 26) < 0.1, "signals percent");
Assert(snap.ModelName == "grok-4.5", "model");
```

追加：仅 token 比无 usage 字段；`updates.jsonl` 中 live `totalTokens` 优先（实现时按 macOS reader 解析 `_meta.totalTokens` / 等价字段）。

- [ ] **Step 2: 运行确认失败**

- [ ] **Step 3: 实现**

- `EncodeWorkspaceDirectory`：与 macOS 相同 percent-encoding 规则（读 `GrokSessionContextReader.encodeWorkspaceDirectory` 移植）。
- 路径：`%USERPROFILE%\.grok\sessions\<encoded-cwd>\<sessionId>\`
- `RefreshGrokDetails`：若 `currentSessions` 含真实 Grok thread（非 `"grok"` 占位），读 context 并 `SetContextPercent`；STANDBY 用现有 soft-hold；OFFLINE 立即清。
- 可选：project/title 行——若 Grok 详情复用 claudeGroup 行显示 title/model，最小实现：quota + context 即可；title 有则显示在 subtitle 旁或 claude 样式 project 行。

- [ ] **Step 4: 运行检查**

- [ ] **Step 5: Commit**

```bash
git add src/windows/GrokMonitor.cs src/windows/DetailsWindow.cs \
  src/windows/HaloWindow.cs src/windows/Diagnostics.cs
git commit -m "feat(windows): Grok session context pill from signals/updates"
```

---

### Task 8: 文档同步 + 全量回归 + 收尾

**Files:**
- Modify: `README.md`、`README.zh-CN.md`、`docs/PRODUCT.md`
- Modify: `docs/superpowers/specs/2026-07-29-windows-grok-build-parity-design.md`（状态改为实现完成）
- 必要时：`docs/WINDOWS_VISUAL_BEHAVIOR.md` 一句提及三段开关

- [ ] **Step 1: 更新文档表述**

将 “Windows only Codex/CC” / “Grok on macOS only” 改为 Windows 同样支持 Grok Build（Weekly + 最小生命周期，无 Pay-as-you-go）。

- [ ] **Step 2: 全量 self-check**

```powershell
.\scripts\build-windows.ps1
.\outputs\AgentHalo\AgentHalo.exe --self-check
```

Expected: 全部 Assert PASS；无未处理异常。

- [ ] **Step 3: 手动验收清单（记录在 PR / commit body）**

1. `grok login` 后焦点 Grok 见 Weekly %
2. Grok 会话 prompt/tool → thinking/working → done
3. 焦点 CC 时不显示 Grok 活动
4. 无 Pay-as-you-go UI
5. Claude/Codex 路径无回归

- [ ] **Step 4: Commit**

```bash
git add README.md README.zh-CN.md docs/PRODUCT.md \
  docs/superpowers/specs/2026-07-29-windows-grok-build-parity-design.md
git commit -m "docs: note Windows Grok Build monitoring parity"
```

---

## Spec 覆盖自检

| Spec 要求 | Task |
| --- | --- |
| AgentKind.Grok + settings | 1 |
| Hook 分流 + PascalCase | 2 |
| Configurator + Reducer + Monitor + presence | 3 |
| Halo 聚合 + 菜单 | 4 |
| 三段 UI | 5 |
| Weekly OAuth 额度 | 6 |
| Context pill | 7 |
| 文档 + 回归 | 8 |
| 无 Pay-as-you-go | 全局约束 + Task 6 映射忽略 |
| 不改视觉 spec / macOS | 全局约束 |

## 类型一致性备忘

- 设置字符串：`"grok"`（camel 小写 g）
- JSONL source：`"grok-hook"`
- 状态文件：`grok-build-status.jsonl`
- 默认 threadId：`"grok"`
- Client ID：`b1a00492-073a-47ea-816f-4c329264a828`
- Token auth header：`xai-grok-cli`
- Weekly period type：`USAGE_PERIOD_TYPE_WEEKLY`
