# AgentHalo 本地数据目录布局 Implementation Plan（macOS + Windows）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 **macOS 与 Windows** 上将用户主目录下的 `.agent-halo` 收敛为同一套布局版本 2（`bin/` / `state/` / `logs/` / `cache/`）：启动迁移后删除旧路径，读写只认新路径，无双读、无长期兼容 symlink；macOS 额外完成 staged binary 外链回写与 contexts GC。

**Architecture:** 两端各自实现同构的 `AgentHaloPaths` + `AgentHaloLayoutMigrator`（路径约定一致，语言分别为 Swift / C#）。App 启动最早阶段幂等迁移；Hook / Monitor / Cache 只读写新路径。平台差异仅体现在 **bin 是否 stage 独立二进制**、**是否存在 statusline/contexts**、**usage 缓存旧位置**。

**Tech Stack:**
- macOS: Swift 6、SwiftPM、`AgentHaloCoreChecks`
- Windows: C# / WPF 现有工程、`AgentHalo.exe --self-test`（`Diagnostics.cs`）

**Spec:** [2026-07-29-agent-halo-data-layout-design.md](../specs/2026-07-29-agent-halo-data-layout-design.md)

---

## Global Constraints

- **双端同步交付**：本计划覆盖 `src/macos/` 与 `src/windows/`；布局语义一致，实现分语言各写一份。
- **无双读**：Monitor / Reader / Cache 不得 fallback 到旧路径。
- **无长期兼容 symlink / junction**。
- **旧数据路径 migrate 后删除**；`claude-code-context.json` 直接删；Windows 同名残留一并删。
- **Migrator 不删 macOS 旧 binary**（`claude-code-status-hook` / `statusline-proxy`）；仅 Configurator 在 settings 回写成功后删除。Windows 可删 `AgentHaloHook.exe`。
- **version 写入策略**：best-effort 完成各项 move/delete 后写 `.layout-version=2`；单步失败只 log 并继续，不抛 UI。version≥2 后每次启动 scrub 残留**数据**旧路径。
- jsonl 历史可丢；迁移不得阻塞 App 启动。
- 不改变 hook 事件语义、halo 状态机、详情 UI 交互。
- **Windows 禁止**把 hook 改成 staged `bin/status-hook`；保持 `AgentHalo.exe --claude-hook`。
- **Windows 禁止**移动/删除 `LocalAppData\CodexHalo\settings.json` 与 `halo.log`；只搬 `usage-snapshots-v1.json`。
- 每项任务 TDD：先加失败检查 → 确认失败 → 最小实现 → 聚焦检查通过 → 提交。
- 提交前 `git status --short`，只暂存本任务文件。
- macOS 与 Windows 任务可并行；合并前两端 checks 均需绿。

---

## 共享目标布局（两端锁定）

用户主目录：

| 平台 | 根路径 |
|------|--------|
| macOS | `~/.agent-halo` |
| Windows | `%USERPROFILE%\.agent-halo` |

```text
.agent-halo/
├── .layout-version                 # "2"
├── bin/                            # 见平台差异
├── state/                          # 见平台差异
├── logs/
│   ├── claude-status.jsonl
│   └── grok-status.jsonl           # 有 Grok 写端时使用；无写端也允许空目录
└── cache/
    ├── claude-contexts/            # macOS statusline 快照；Windows 可仅建目录
    └── usage-snapshots-v1.json     # 用量缓存（两端最终都在此）
```

`.layout-version` 内容：纯文本 `2`（允许尾随换行；比较时 trim）。

---

## 平台差异（必须遵守）

| 能力 | macOS | Windows |
|------|-------|---------|
| Lifecycle hook 载体 | 独立 staged `bin/status-hook` | **主程序** `AgentHalo.exe --claude-hook <Event>`（不 stage 到 bin） |
| Statusline proxy | `bin/statusline-proxy` + `state/statusline-original-command` | **无** statusline proxy 功能 |
| Context 热缓存 | `cache/claude-contexts/{sessionId}.json` + GC | 当前无 writer；迁移器仍创建目录；GC 可选实现（预留） |
| Grok 状态日志 | `logs/grok-status.jsonl`（已有写端） | 若已有/即将有 Grok hook 写端则用同路径；仅 Claude 时也创建 `logs/` |
| 旧 binary 删除 | 回写 Claude/Grok settings 后删 `claude-code-status-hook` 等 | 继续删遗留 `AgentHaloHook.exe`（已有 `RemoveLegacyHookHelper`）；**不**把主 exe 拷进 bin |
| Usage 缓存旧位置 | `~/.agent-halo/usage-snapshots-v1.json` | **`%LOCALAPPDATA%\CodexHalo\usage-snapshots-v1.json`**（`SettingsStorage.AppDirectory`） |
| Usage 缓存新位置 | `~/.agent-halo/cache/usage-snapshots-v1.json` | **同样** `%USERPROFILE%\.agent-halo\cache\usage-snapshots-v1.json`（对齐跨平台） |
| 配置 settings 路径 | 用户 settings 指向 staged bin | 用户 settings 指向 **AgentHalo.exe 绝对路径**（现有行为保留） |
| 自动化测试 | `swift run AgentHaloCoreChecks` | `AgentHalo.exe --self-test <out>` / 工程现有 Diagnostics 断言 |

**Windows `bin/` / `state/`：** 迁移时仍创建空目录以保持布局版本一致；不强制放入可执行文件。未来若 Windows 引入独立 helper，再使用 `bin/`。

**macOS App bundle 资源名：** `scripts/build-macos.sh` 可继续拷贝为 bundle 内 `claude-code-status-hook` / `claude-code-statusline-proxy`（打包细节）；**用户目录 staged 路径必须是 `bin/` 新名**。

---

## 旧 → 新路径对照（双端）

| 角色 | 旧路径 | 新路径 |
|------|--------|--------|
| Claude 事件日志 | `.agent-halo/claude-code-status.jsonl` | `.agent-halo/logs/claude-status.jsonl` |
| Grok 事件日志 | `.agent-halo/grok-build-status.jsonl` | `.agent-halo/logs/grok-status.jsonl` |
| Context 目录 | `.agent-halo/claude-code-contexts/` | `.agent-halo/cache/claude-contexts/` |
| Legacy 全局 context | `.agent-halo/claude-code-context.json` | **删除** |
| Usage（macOS 根） | `.agent-halo/usage-snapshots-v1.json` | `.agent-halo/cache/usage-snapshots-v1.json` |
| Usage（Windows AppData） | `%LOCALAPPDATA%\CodexHalo\usage-snapshots-v1.json` | `.agent-halo/cache/usage-snapshots-v1.json` |
| Statusline original（仅 macOS） | `.agent-halo/claude-code-statusline-original-command` | `.agent-halo/state/statusline-original-command` |
| Hook binary（仅 macOS） | `.agent-halo/claude-code-status-hook` | `.agent-halo/bin/status-hook`（settings 回写后删旧） |
| Proxy binary（仅 macOS） | `.agent-halo/claude-code-statusline-proxy` | `.agent-halo/bin/statusline-proxy` |
| 遗留 helper（仅 Windows） | `.agent-halo/AgentHaloHook.exe` | **删除**（配置改用主 exe，现有逻辑） |

---

## 目标文件总览

### macOS 新增

```text
src/macos/Sources/AgentHaloCore/AgentHaloPaths.swift
src/macos/Sources/AgentHaloCore/AgentHaloLayoutMigrator.swift
```

### macOS 修改

```text
src/macos/Package.swift
src/macos/Sources/AgentHaloCore/ClaudeHookConfigurator.swift
src/macos/Sources/AgentHaloCore/GrokHookConfigurator.swift
src/macos/Sources/AgentHaloCore/ClaudeStatusLineConfigurator.swift
src/macos/Sources/AgentHaloCore/ClaudeHookStatusMonitor.swift
src/macos/Sources/AgentHaloCore/GrokHookStatusMonitor.swift
src/macos/Sources/AgentHaloCore/ClaudeContextUsage.swift
src/macos/Sources/AgentHaloCore/ClaudeContextUsageConstants.swift
src/macos/Sources/AgentHaloCore/UsageMonitoring/UsageMonitoringCoordinator.swift
src/macos/Sources/ClaudeCodeStatusHook/main.swift
src/macos/Sources/ClaudeCodeStatusLineProxy/main.swift
src/macos/Sources/AgentHaloMac/AppDelegate.swift
src/macos/Sources/AgentHaloCoreChecks/main.swift
src/macos/Sources/AgentHaloCoreChecks/UsageMonitoringChecks.swift
```

### Windows 新增

```text
src/windows/AgentHaloPaths.cs
src/windows/AgentHaloLayoutMigrator.cs
```

### Windows 修改

```text
src/windows/ClaudeCodeMonitor.cs
  # ClaudeHookStatusWriter 写 logs/claude-status.jsonl（及 Grok 分流若存在）
  # ClaudeHookStatusMonitor 读新路径
  # ClaudeHookConfigurator：启动前依赖 migrator；RemoveLegacyHookHelper 保留/并入 scrub
src/windows/CodexUsageMonitor.cs
  # CodexUsageSnapshotCache 路径 → AgentHaloPaths.UsageSnapshots
src/windows/HaloWindow.cs
  # 启动：Migrate → ClaudeHookConfigurator.Configure
src/windows/Diagnostics.cs
  # 路径/迁移/写读回归
src/windows/Program.cs          # 若需；通常不必改 CLI
# 若存在 GrokMonitor / Grok hook 写路径：一并改到 logs/grok-status.jsonl
```

### 文档

```text
README.md
README.zh-CN.md
docs/superpowers/specs/2026-07-29-agent-halo-data-layout-design.md  # 范围改为双端
```

---

## 公开接口（锁定）

### macOS（Swift）

```swift
public struct AgentHaloPaths: Sendable, Equatable {
    public static let layoutVersion: Int = 2
    public let root: URL
    // bin/state/logs/cache + statusHook, statuslineProxy, logs, contexts, usageSnapshots
    // legacy* 属性仅供 Migrator 删除判定
    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser)
}

public enum AgentHaloLayoutMigrator {
    public static func migrateIfNeeded(
        paths: AgentHaloPaths = AgentHaloPaths(),
        fileManager: FileManager = .default
    )
}
```

### Windows（C#）

```csharp
internal static class AgentHaloPaths
{
    public const int LayoutVersion = 2;

    // 可注入 userProfile 便于测试
    public static string Root(string userProfile = null);
    public static string LayoutVersionFile(string userProfile = null);
    public static string BinDirectory(string userProfile = null);
    public static string StateDirectory(string userProfile = null);
    public static string LogsDirectory(string userProfile = null);
    public static string CacheDirectory(string userProfile = null);
    public static string ClaudeStatusLog(string userProfile = null);   // logs\claude-status.jsonl
    public static string GrokStatusLog(string userProfile = null);     // logs\grok-status.jsonl
    public static string ClaudeContextsDirectory(string userProfile = null);
    public static string UsageSnapshots(string userProfile = null);    // cache\usage-snapshots-v1.json

    // Legacy（仅迁移/清理）
    public static string LegacyClaudeStatusLog(string userProfile = null);
    public static string LegacyGrokStatusLog(string userProfile = null);
    public static string LegacyClaudeContextsDirectory(string userProfile = null);
    public static string LegacyClaudeContextFile(string userProfile = null);
    public static string LegacyUsageSnapshotsInAgentHalo(string userProfile = null);
    public static string LegacyUsageSnapshotsInAppData(); // %LOCALAPPDATA%\CodexHalo\usage-snapshots-v1.json
    public static string LegacyAgentHaloHookExe(string userProfile = null);
}

internal static class AgentHaloLayoutMigrator
{
    /// 幂等。失败只记 SettingsStorage.Log，不抛。
    public static void MigrateIfNeeded(string userProfile = null);
}
```

Windows 默认 `userProfile = Environment.GetFolderPath(UserProfile)`。  
`LegacyUsageSnapshotsInAppData` 使用现有 `SettingsStorage.AppDirectory`，与 settings.json **分离**：只搬 usage 缓存，不搬 `settings.json` / `halo.log`。

GC 常量（macOS 必须；Windows 若无 contexts writer 可只在 Paths 旁注释预留）：

```text
diskMaxAge = 24h, maxFiles = 40, minRetainAge = 10min, pruneThrottle = 60s
```

---

## 验证命令

```bash
# macOS
cd src/macos && swift run AgentHaloCoreChecks

# Windows（在 Windows 构建环境或 CI）
# Program.Main 入口为 --self-test <outputPath>（见 src/windows/Program.cs）
AgentHalo.exe --self-test %TEMP%\agent-halo-self-test-out
```

---

# 轨道 A — macOS

### Task A1: `AgentHaloPaths`（macOS）

**Files:**
- Create: `src/macos/Sources/AgentHaloCore/AgentHaloPaths.swift`
- Modify: `src/macos/Sources/AgentHaloCoreChecks/main.swift`

- [ ] **Step 1: 写失败检查** `testAgentHaloPathsLayoutV2`（断言 bin/state/logs/cache 与 legacy 文件名）
- [ ] **Step 2: 运行确认失败**
- [ ] **Step 3: 实现 Paths**
- [ ] **Step 4: checks 通过**
- [ ] **Step 5: 提交**

```bash
git commit -m "$(cat <<'EOF'
Add macOS AgentHaloPaths for layout v2 directory contract.

Centralize ~/.agent-halo bin/state/logs/cache URLs as the single path source
of truth for migration and call sites.
EOF
)"
```

---

### Task A2: `AgentHaloLayoutMigrator`（macOS）

**Files:**
- Create: `src/macos/Sources/AgentHaloCore/AgentHaloLayoutMigrator.swift`
- Modify: `src/macos/Sources/AgentHaloCoreChecks/main.swift`

**行为：** move 数据旧路径 → 新路径 → 删除旧数据路径；best-effort 后写 version=2；**不**删旧 binary；version≥2 时 scrub **仅数据**残留路径。

- [ ] 测试：完整旧扁平 → 新布局且旧 jsonl/contexts/usage/original-command/context.json 删除；**旧 binary 文件仍在**
- [ ] 测试：新已存在则保留新、删旧
- [ ] 测试：version=2 仍 scrub 残留 jsonl
- [ ] 实现 + 提交

```bash
git commit -m "$(cat <<'EOF'
Add macOS layout migrator that moves data to v2 and deletes legacy paths.

Relocate status logs, contexts, usage cache, and statusline original-command
into state/logs/cache; drop the global context file; leave legacy binaries
for configurators to remove after settings rewrite.
EOF
)"
```

---

### Task A3: App 启动接入 Migrator（macOS）

**Files:** `src/macos/Sources/AgentHaloMac/AppDelegate.swift`

```swift
AgentHaloLayoutMigrator.migrateIfNeeded()
ClaudeHookConfigurator.configure()
GrokHookConfigurator.configure()
ClaudeStatusLineConfigurator.configure()
```

- [ ] 实现 + 编译 + 提交

---

### Task A4: Configurator → `bin/*` + 回写后删旧 binary（macOS）

**Files:** Claude/Grok/StatusLine Configurator + checks

- staged：`bin/status-hook`、`bin/statusline-proxy`
- original command：`state/statusline-original-command`
- legacy 路径的 settings **必须回写**为新路径（不能 short-circuit 跳过）
- settings 成功后删除根目录旧 binary

- [ ] 更新现有 hook/statusline 测试期望路径
- [ ] 新增 rewrite legacy + 删除旧 binary 测试
- [ ] bundled 缺失时不删 legacy binary
- [ ] 实现 + 提交

---

### Task A5: Hook / Proxy / Monitor / Reader / Usage 只认新路径（macOS）

**Files:** Package.swift（Hook 依赖 Core）、Hook、Proxy、Monitors、ClaudeContextUsage、UsageMonitoringCoordinator、checks

- 无双读；删除 legacy 单文件 context 读取
- Hook isolation 期望 `logs/*.jsonl`

- [ ] 实现 + 全量 CoreChecks + 提交

---

### Task A6: Contexts GC（macOS）

**Files:** ClaudeContextUsageConstants、ClaudeContextUsage、Migrator/App 启动 force prune、checks

- 24h / 40 files / 10min protect / 60s throttle
- write 后 opportunistic prune；启动 force prune

- [ ] 实现 + 提交

---

### Task A7: macOS 回归 grep + 文档片段

```bash
rg -n "claude-code-status\.jsonl|claude-code-contexts|claude-code-context\.json|claude-code-status-hook|claude-code-statusline-proxy|grok-build-status\.jsonl" \
  src/macos --glob '!**/AgentHaloPaths.swift' --glob '!**/AgentHaloLayoutMigrator.swift'
```

允许：Paths/Migrator legacy、测试夹具、bundle 资源名、`build-macos.sh`。

- [ ] 修违规默认值 + CoreChecks 绿 + 提交（README 可与 Task C1 合并）

---

# 轨道 B — Windows

### Task B1: `AgentHaloPaths`（Windows）

**Files:**
- Create: `src/windows/AgentHaloPaths.cs`
- Modify: `src/windows/Diagnostics.cs`

- [ ] **Step 1: Diagnostics 断言**

```csharp
// 伪代码：使用临时 userProfile 目录
string home = Path.Combine(Path.GetTempPath(), "agent-halo-paths-" + Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(home);
string root = AgentHaloPaths.Root(home);
Assert(AgentHaloPaths.ClaudeStatusLog(home) ==
    Path.Combine(root, "logs", "claude-status.jsonl"), "claude log path");
Assert(AgentHaloPaths.GrokStatusLog(home) ==
    Path.Combine(root, "logs", "grok-status.jsonl"), "grok log path");
Assert(AgentHaloPaths.UsageSnapshots(home) ==
    Path.Combine(root, "cache", "usage-snapshots-v1.json"), "usage cache path");
Assert(AgentHaloPaths.LegacyClaudeStatusLog(home) ==
    Path.Combine(root, "claude-code-status.jsonl"), "legacy claude log");
Assert(AgentHaloPaths.LayoutVersion == 2, "layout version");
// LegacyUsageSnapshotsInAppData 以 SettingsStorage.AppDirectory 为根
Assert(AgentHaloPaths.LegacyUsageSnapshotsInAppData().EndsWith(
    "usage-snapshots-v1.json"), "appdata legacy usage name");
```

- [ ] **Step 2: 实现 `AgentHaloPaths`**
- [ ] **Step 3: self-test 通过**
- [ ] **Step 4: 提交**

```bash
git commit -m "$(cat <<'EOF'
Add Windows AgentHaloPaths matching layout v2 contract.

Expose USERPROFILE\.agent-halo logs/cache paths and legacy locations
including the AppData usage-snapshots file for migration.
EOF
)"
```

---

### Task B2: `AgentHaloLayoutMigrator`（Windows）

**Files:**
- Create: `src/windows/AgentHaloLayoutMigrator.cs`
- Modify: `src/windows/Diagnostics.cs`

**算法（与 macOS 同语义）：**

1. 确保 `Root`、`bin`、`state`、`logs`、`cache` 目录存在。
2. 若 version ≥ 2：scrub 数据类 legacy（含 AppData usage 若仍在旧处且新处已有/已处理）→ return。
3. MoveOrReplace：
   - `LegacyClaudeStatusLog` → `ClaudeStatusLog`
   - `LegacyGrokStatusLog` → `GrokStatusLog`（若旧文件存在）
   - `LegacyClaudeContextsDirectory` 内容 → `ClaudeContextsDirectory`（若存在）
   - `LegacyUsageSnapshotsInAgentHalo` → `UsageSnapshots`
   - **`LegacyUsageSnapshotsInAppData` → `UsageSnapshots`**（若目标尚不存在；若目标已存在则删 AppData 旧文件）
4. 删除 `LegacyClaudeContextFile`、空旧目录、`AgentHaloHook.exe`。
5. 写 `.layout-version` = `2`。
6. 全部 best-effort；异常 `SettingsStorage.Log`，不抛。

**注意：** 不要移动或删除 `settings.json`、`halo.log` 或整个 `CodexHalo` 目录。

- [ ] **Step 1: Diagnostics 测试**

```csharp
// 布置 userProfile\.agent-halo\claude-code-status.jsonl 与
// 可选假 AppData usage 文件（可注入临时 AppDirectory 若现有 API 支持；
// 若不支持注入，则只测 agent-halo 根下旧 jsonl/contexts，AppData 路径用
// 文档化手动/集成步骤，或给 SettingsStorage 增加测试用 AppDirectory override）。
AgentHaloLayoutMigrator.MigrateIfNeeded(home);
Assert(File.Exists(AgentHaloPaths.ClaudeStatusLog(home)));
Assert(!File.Exists(AgentHaloPaths.LegacyClaudeStatusLog(home)));
Assert(File.ReadAllText(AgentHaloPaths.LayoutVersionFile(home)).Trim() == "2");
// 幂等第二次
AgentHaloLayoutMigrator.MigrateIfNeeded(home);
```

若 `SettingsStorage.AppDirectory` 不可注入：在 `AgentHaloLayoutMigrator` 增加可选参数：

```csharp
public static void MigrateIfNeeded(
    string userProfile = null,
    string legacyAppDataUsagePath = null) // null → AgentHaloPaths.LegacyUsageSnapshotsInAppData()
```

Diagnostics 传入临时文件路径验证 AppData → cache 迁移。

- [ ] **Step 2: 实现 Migrator**
- [ ] **Step 3: self-test 通过 + 提交**

```bash
git commit -m "$(cat <<'EOF'
Add Windows layout migrator for .agent-halo v2 and AppData usage cache.

Move claude/grok status logs into logs/, relocate usage-snapshots into
cache/, delete legacy flat files and AgentHaloHook.exe leftovers.
EOF
)"
```

---

### Task B3: 启动接入 + Hook 写/读新路径（Windows）

**Files:**
- Modify: `src/windows/HaloWindow.cs`（或 `Program.cs` 主 UI 启动路径）
- Modify: `src/windows/ClaudeCodeMonitor.cs`
- Modify: `src/windows/Diagnostics.cs`

**启动顺序：**

```csharp
AgentHaloLayoutMigrator.MigrateIfNeeded();
ClaudeHookConfigurator.Configure();
// … existing monitors …
```

**ClaudeHookStatusWriter：**

```csharp
// 旧：Path.Combine(root, "claude-code-status.jsonl")
// 新：
string path = AgentHaloPaths.ClaudeStatusLog(); // 或带 userProfile
Directory.CreateDirectory(AgentHaloPaths.LogsDirectory());
```

若 writer 内已有 Grok 分流（或后续 Grok PR 合并）：Grok → `AgentHaloPaths.GrokStatusLog()`，**禁止**再写 `claude-code-status.jsonl` 或 `claude-status` 以外的 Claude 文件。

**ClaudeHookStatusMonitor 默认构造：**

```csharp
// 旧：... "claude-code-status.jsonl"
// 新：AgentHaloPaths.ClaudeStatusLog()
```

将 `AgentHaloDataDirectory()` 逐步替换为 `AgentHaloPaths.Root()`（可保留一层包装转发以免大范围改名，但默认文件名必须新）。

- [ ] **Step 1: 更新 Diagnostics hook configure / isolation 类测试**
  - 写 hook 后文件出现在 `logs\claude-status.jsonl`
  - 旧路径不出现新写入
- [ ] **Step 2: 实现**
- [ ] **Step 3: self-test + 提交**

```bash
git commit -m "$(cat <<'EOF'
Write and read Windows Claude hook status under logs/claude-status.jsonl.

Run layout migration before hook configuration on startup and drop the
flat claude-code-status.jsonl default path.
EOF
)"
```

---

### Task B4: Usage 缓存切到 `cache/usage-snapshots-v1.json`（Windows）

**Files:**
- Modify: `src/windows/CodexUsageMonitor.cs`（`CodexUsageSnapshotCache.CachePath`）
- Modify: `src/windows/Diagnostics.cs`（若有 usage cache 路径断言）

```csharp
// 旧：Path.Combine(SettingsStorage.AppDirectory, "usage-snapshots-v1.json")
// 新：AgentHaloPaths.UsageSnapshots()
```

确保写前 `Directory.CreateDirectory(AgentHaloPaths.CacheDirectory())`。

迁移由 Task B2 负责把 AppData 旧文件搬过来；本任务只改读写默认路径。

- [ ] 实现 + self-test（load/store 仍 round-trip）+ 提交

```bash
git commit -m "$(cat <<'EOF'
Store Windows usage snapshots under .agent-halo/cache.

Align CodexUsageSnapshotCache with the cross-platform layout v2 cache
path instead of LocalAppData\\CodexHalo.
EOF
)"
```

---

### Task B5: Windows 回归与遗留清理

**Files:** `src/windows/*`、Diagnostics

```bash
rg -n "claude-code-status\.jsonl|grok-build-status\.jsonl|claude-code-contexts|claude-code-context\.json" \
  src/windows --glob '!**/AgentHaloPaths.cs' --glob '!**/AgentHaloLayoutMigrator.cs'
```

允许：Paths/Migrator legacy 常量、测试夹具、注释。

额外确认：

- [ ] `RemoveLegacyHookHelper` 仍删除 `AgentHaloHook.exe`（可并入 Migrator scrub，避免重复即可）
- [ ] 无生产代码再写扁平 jsonl 文件名
- [ ] `ClaudeHookConfigurator` 仍配置 `AgentHalo.exe --claude-hook`（**不要**改成 bin/status-hook）
- [ ] self-test 全绿
- [ ] 提交

```bash
git commit -m "$(cat <<'EOF'
Finish Windows layout v2 path cleanup and self-test coverage.

Ensure hook logs and usage cache defaults only use logs/ and cache/ under
USERPROFILE\.agent-halo.
EOF
)"
```

---

### Task B6（可选，与 Grok Windows 并行时必做）: Grok 日志路径

若仓库已存在或合并中的 Windows Grok hook 写端：

- 写 `AgentHaloPaths.GrokStatusLog()`
- Monitor 读同路径
- 迁移 `grok-build-status.jsonl` → `logs/grok-status.jsonl`（B2 已含）
- Diagnostics：Grok 事件不得写入 `logs/claude-status.jsonl`

若 Grok 尚未合入：B2 仍迁移旧文件名；B3 只保证 Claude 路径正确即可。

---

# 轨道 C — 文档与双端收口

### Task C1: README 收口

**Files:**
- `README.md` / `README.zh-CN.md`

说明要点：

> AgentHalo 在用户主目录 `.agent-halo` 使用统一布局：
> - `bin/` — macOS staged hook/proxy；Windows 可为空
> - `state/` — macOS statusline 链式命令等
> - `logs/` — 近期 lifecycle 事件（自动轮转）
> - `cache/` — 可安全删除的缓存（context / usage）
>
> Windows 应用设置仍在 `%LOCALAPPDATA%\CodexHalo\`；**用量快照**迁至 `.agent-halo\cache\`。

注：design spec 的双端范围与平台差异表已在计划审核时写好；本任务只补用户可见 README（若 spec 状态字段需标「已实现」则在全部 A/B 任务完成后改）。

- [ ] 提交

```bash
git commit -m "$(cat <<'EOF'
Document cross-platform .agent-halo layout v2 for macOS and Windows.

Describe bin/state/logs/cache roles and note Windows keeps app settings in
LocalAppData while runtime agent data uses the shared layout.
EOF
)"
```

---

## 任务依赖图

```text
轨道 A (macOS)                         轨道 B (Windows)
A1 Paths                               B1 Paths
 └─ A2 Migrator                         └─ B2 Migrator
      └─ A3 App 启动                          └─ B3 Hook 写/读 + 启动
           ├─ A4 Configurator bin                  └─ B4 Usage cache 路径
           └─ A5 读写切新路径                            └─ B5 回归
                └─ A6 Contexts GC
                     └─ A7 回归
                              ↘
                               C1 文档收口（A7+B5 之后或穿插）
```

- **A 与 B 可完全并行**（不同树）。
- 功能合并建议：A1–A3 与 B1–B3 作为「布局可迁移」里程碑；A4–A6 与 B4–B5 作为「只认新路径」里程碑；最后 C1。

---

## 手工验收

### macOS

1. 启动 App → `.layout-version == 2`，存在 `bin/state/logs/cache`。
2. 根目录无 `claude-code-status.jsonl`、`claude-code-contexts`、`claude-code-context.json`。
3. settings 指向 `bin/status-hook` / `bin/statusline-proxy`；根级旧 binary 消失。
4. Claude/Grok 活动与 context 详情正常；ccline 仍工作。

### Windows

1. 启动 App → `%USERPROFILE%\.agent-halo\.layout-version == 2`。
2. 存在 `logs\claude-status.jsonl`（有 Claude 活动后）；无新的根级 `claude-code-status.jsonl` 写入。
3. `%LOCALAPPDATA%\CodexHalo\usage-snapshots-v1.json` 在迁移后不再作为读写目标（可已删除）；`cache\usage-snapshots-v1.json` 在有用量数据后出现。
4. `settings.json` / `halo.log` 仍在 `LocalAppData\CodexHalo`。
5. Claude hooks 仍调用 `AgentHalo.exe --claude-hook …`。
6. 光环 / 详情 Claude 生命周期正常。

---

## 风险与实现注意

| 风险 | 平台 | 处理 |
|------|------|------|
| settings 回写前删 binary | macOS | 仅成功后删除；Migrator/scrub 不删 binary |
| Hook 进程在迁移前写盘 | 双端 | 启动 migrate + 只写新路径；短窗口可丢 jsonl |
| Windows usage 与 settings 同目录 | Windows | **只搬 usage-snapshots 文件**，不碰 settings/halo.log |
| AppDirectory 测试不可注入 | Windows | `MigrateIfNeeded(..., legacyAppDataUsagePath:)` 可选参数 |
| 误改 Windows 为 staged bin hook | Windows | 禁止；保持 `AgentHalo.exe --claude-hook` |
| 两端路径字符串漂移 | 双端 | 对照路径表；实现后 grep 门禁 |
| Hook 链上 AgentHaloCore 体积 | macOS | 接受；勿复制路径字符串 |
| usage schema 双端不同 | 双端 | 只迁路径，不要求跨平台字节兼容 |
| Grok Windows 尚未合入 | Windows | B2 仍迁移 `grok-build-status.jsonl`；B6 在有写端时接 `logs/grok-status.jsonl` |

---

## 成功标准

1. 两端新安装均为 layout v2 目录结构。
2. 两端旧安装启动一次后自动迁移，用户无感。
3. 生产默认路径无扁平 `claude-code-status.jsonl` / `grok-build-status.jsonl` 写入。
4. Usage 缓存两端均在 `.agent-halo/cache/usage-snapshots-v1.json`。
5. macOS：contexts 有界 GC；staged bin 外链正确。
6. Windows：hooks 仍走主 exe；LocalAppData 设置区不被破坏。
7. `AgentHaloCoreChecks` 与 Windows `--self-test` 全绿。

---

## 一句话

> macOS 与 Windows 共用 `.agent-halo` 布局 v2 契约；各自实现 Paths + Migrator，启动迁移并删除旧数据路径，读写只认 `logs/` 与 `cache/`；macOS 另处理 staged `bin/` 与 contexts GC，Windows 另把 AppData 中的 usage 缓存迁入 `cache/` 并保持 `AgentHalo.exe --claude-hook` 模型。
