# AgentHalo 本地数据目录布局设计

## 文档状态

- 日期：2026-07-29
- 状态：设计已确认；实施计划见 [2026-07-29-agent-halo-data-layout-implementation.md](../plans/2026-07-29-agent-halo-data-layout-implementation.md)（**macOS + Windows**）
- 实现范围：AgentHalo **macOS 与 Windows**；两端共用同一布局版本 2 路径约定，按平台差异实现（见下「平台差异」）
- 产品原则：见 [PRODUCT.md](../../PRODUCT.md)
- 相关先例：
  - [Claude Code Status 设计](./2026-06-16-claude-code-status-design.md)
  - [Claude Main-Session Details 设计](./2026-06-22-claude-main-session-details-design.md)
  - [OpenUsage 风格监控 macOS 设计](./2026-07-10-openusage-monitoring-macos-design.md)
  - [macOS Grok Build 额度与最小生命周期设计](./2026-07-25-macos-grok-build-usage-lifecycle-design.md)

## 目标

将用户主目录下的 `.agent-halo`（macOS `~/…`，Windows `%USERPROFILE%\…`）从扁平、Claude 中心、生命周期不完整的布局，升级为职责清晰、有界可清理、升级可迁移的标准应用数据目录：

1. **分层布局**：`bin/`、`state/`、`logs/`、`cache/` 分离（两端同构；某平台可空目录）。
2. **命名中性**：可执行文件 / 日志不再以 `claude-code-*` 根级文件名为中心；日志与缓存可按 agent 分文件。
3. **路径集中**：运行时路径只通过 `AgentHaloPaths`（或平台等价物）解析，禁止业务代码散落硬编码。
4. **启动迁移**：旧布局一次性搬到新布局，**成功后删除旧数据路径**。
5. **不做双读**：迁移后只认新路径；读路径无 legacy fallback 链。
6. **不做长期兼容 symlink / junction**。
7. **macOS 专属**：staged `bin/*` 外链回写成功后删除根级旧 binary；`cache/claude-contexts` 有界 GC。
8. **Windows 专属**：usage 从 `%LOCALAPPDATA%\CodexHalo\` 迁入 `cache/`；hooks 仍指向主程序 exe。

## 非目标

- 改变 hook 事件语义、statusline JSON 解析、halo 状态机或详情面板 UI。
- 加密存储、远程同步、用户可见的「缓存管理」设置页。
- 压缩 macOS `statusline-proxy` 体积（可另开优化）。
- 清理历史上曾混入 Claude jsonl 的 Grok 旧事件**行内容**（布局迁移只搬文件，不 scrub 行）。
- 强制用户手动迁移或交互确认。
- 把 Windows `%LOCALAPPDATA%\CodexHalo\settings.json` / `halo.log` 迁入 `.agent-halo`。
- 在 Windows 上引入独立 staged hook 二进制（保持 `AgentHalo.exe --claude-hook`）。

## 已确认的架构决策

1. **目标布局版本**记为 `2`（缺失或无法解析视为 `0` / 旧扁平布局）。
2. **迁移策略**：`rename`/`move` 优先 → 有新则丢弃旧 → **删除旧数据路径**。实现采用 **best-effort 尽量完成全部数据项，最后写 version=2**；单步 IO 失败只记 log、不抛 UI。若进程在写 version 前崩溃，下次启动重试（部分文件可能已在新路径，属幂等可恢复）。**不**因单步失败无限期卡在 version&lt;2 而拒绝写 version——避免「永远半迁移」；以「新路径为准 + version≥2 时 scrub 残留旧数据路径」收敛。
3. **无双读**：Monitor / Reader / Cache 只打开新路径；文件不存在即视为无数据（冷启动可接受）。
4. **无长期 symlink / junction**：不为旧 jsonl / contexts / binary 名保留兼容入口。
5. **macOS 二进制外链**：Configurator 将 hook/statusline 回写为 `bin/` 新路径；**仅 settings 写成功后**删除根目录旧 binary。Migrator **不**删除旧 binary。
6. **jsonl 历史可丢**：旧/新 status jsonl 仅为近期事件缓冲；不得因迁移阻塞启动。
7. **contexts 语义为 cache（macOS）**：读侧已有 5 分钟新鲜度；写侧与启动侧增加 prune。Windows 当前无 writer，仅创建目录。
8. **权限（macOS）**：根与子目录 `0700`，数据文件 `0600`，bin 可执行 `0755`。Windows 依赖用户配置文件 ACL，不强制套用 Unix mode。
9. **跨平台**：两端同一布局版本与相对路径；hook 载体与 bin 是否 stage 按「平台差异」表。

## 平台差异

| 能力 | macOS | Windows |
|------|-------|---------|
| 数据根 | `~/.agent-halo` | `%USERPROFILE%\.agent-halo` |
| Lifecycle hook | staged `bin/status-hook` | 主程序 `AgentHalo.exe --claude-hook`（**不** stage 到 bin） |
| Statusline proxy | `bin/statusline-proxy` + `state/statusline-original-command` | 无 |
| Context 热缓存 + GC | `cache/claude-contexts/` 有写端与 GC | 当前无写端；迁移仍建目录 |
| Usage 缓存最终路径 | `cache/usage-snapshots-v1.json` | 同左（从 `%LOCALAPPDATA%\CodexHalo\usage-snapshots-v1.json` 迁入） |
| 应用设置 |（系统/自有） | 仍在 `%LOCALAPPDATA%\CodexHalo\`（`settings.json` / `halo.log` **不**迁入 `.agent-halo`） |
| 旧 binary 清理 | settings 回写后删 `claude-code-status-hook` 等 | 删遗留 `AgentHaloHook.exe`；主 exe 不进 bin |

Windows 迁移必须额外处理 **AppData 中的 usage 旧文件** → `cache/usage-snapshots-v1.json`；禁止移动整个 `CodexHalo` 目录。

## 背景与问题

### 现状（布局版本 &lt; 2）

**macOS（扁平 `.agent-halo`）：**

```text
~/.agent-halo/
├── claude-code-status-hook              # staged binary（Claude/Grok 共用）
├── claude-code-statusline-proxy         # staged binary
├── claude-code-statusline-original-command
├── claude-code-status.jsonl             # Claude hook 事件（3MB 轮转）
├── grok-build-status.jsonl              # Grok hook 事件（3MB 轮转）
├── claude-code-contexts/                # per-session context（只写不删）
├── claude-code-context.json             # legacy 全局快照
└── usage-snapshots-v1.json              # 用量缓存
```

**Windows：**

```text
%USERPROFILE%\.agent-halo\
├── claude-code-status.jsonl             # Claude hook 事件
├── AgentHaloHook.exe                    # 遗留 helper（应删除；现用主 exe）
└── （通常无 staged bin / contexts / statusline）

%LOCALAPPDATA%\CodexHalo\
├── settings.json                        # 应用设置（本设计不搬）
├── halo.log
└── usage-snapshots-v1.json              # 用量缓存（需迁入 .agent-halo\cache\）
```

### 问题

| 问题 | 影响 |
|------|------|
| 职责混杂 | bin / log / cache / state 同层，难维护 |
| Claude 中心命名 | 实际已服务多 agent，扩展成本高 |
| `claude-code-contexts` 无 GC（macOS） | session 文件数单调增长 |
| legacy 单文件并存（macOS） | 读路径分叉 |
| 路径硬编码分散 | 改造易漏改 |
| Windows usage 与 settings 同目录 | 与跨平台 cache 约定不一致 |

### 明确不采用的方案

| 方案 | 原因 |
|------|------|
| 双读（新路径优先 + 旧路径 fallback） | 用户确认不需要；增加永久复杂度 |
| 长期兼容 symlink 保留旧 jsonl/contexts 名 | 用户确认无用旧路径直接删除 |
| 双写新旧两套 | 无收益，易不一致 |
| 仅改文档不改布局 | 无法解决 GC 与命名债务 |

## 目标布局（版本 2）

```text
~/.agent-halo/                                 # 0700
├── .layout-version                            # 纯文本整数，当前为 2
├── bin/                                       # 0755 文件
│   ├── status-hook                            # 统一 lifecycle hook
│   └── statusline-proxy                       # Claude statusline 代理
├── state/                                     # 0600 小状态
│   └── statusline-original-command            # 下游 statusline 命令（如 ccline）
├── logs/                                      # 0600 追加写
│   ├── claude-status.jsonl
│   └── grok-status.jsonl
└── cache/                                     # 可随时丢弃
    ├── claude-contexts/                       # {sessionId}.json
    └── usage-snapshots-v1.json                # schema 不变
```

### 路径对照表

| 角色 | 旧路径（删除） | 新路径（唯一真相） | 平台 |
|------|----------------|--------------------|------|
| Hook 二进制 | `claude-code-status-hook` | `bin/status-hook` | macOS |
| Statusline 代理 | `claude-code-statusline-proxy` | `bin/statusline-proxy` | macOS |
| 下游命令 | `claude-code-statusline-original-command` | `state/statusline-original-command` | macOS |
| Claude 事件日志 | `claude-code-status.jsonl` | `logs/claude-status.jsonl` | 双端 |
| Grok 事件日志 | `grok-build-status.jsonl` | `logs/grok-status.jsonl` | 双端（有写端时） |
| Context 快照目录 | `claude-code-contexts/` | `cache/claude-contexts/` | 双端（写端主要为 macOS） |
| Legacy 全局 context | `claude-code-context.json` | **无替代，直接删除** | 双端若存在 |
| 用量缓存（agent-halo 根） | `usage-snapshots-v1.json` | `cache/usage-snapshots-v1.json` | 主要为 macOS |
| 用量缓存（AppData） | `%LOCALAPPDATA%\CodexHalo\usage-snapshots-v1.json` | `cache/usage-snapshots-v1.json` | Windows |
| 遗留 hook helper | `AgentHaloHook.exe` | **删除**（改用主 exe） | Windows |

### 命名规则

- **bin**：agent-neutral（`status-hook`、`statusline-proxy`）。
- **logs / cache 内容**：可带 agent 名（`claude-status.jsonl`、`claude-contexts/`），因数据按 agent 隔离。
- **禁止**在版本 2 新增任何 `claude-code-*` 根级文件名。

## 模块设计

### 1. `AgentHaloPaths`（双端）

| 平台 | 位置 |
|------|------|
| macOS | `src/macos/Sources/AgentHaloCore/AgentHaloPaths.swift` |
| Windows | `src/windows/AgentHaloPaths.cs` |

职责：

- 以可注入的 home / userProfile 为根，暴露全部规范路径。
- 是**唯一**允许拼接 `.agent-halo` 子路径的生产代码入口（测试夹具除外）。
- 暴露 `legacy*` 路径**仅供 Migrator 删除判定**，业务读写禁止使用。

macOS 形状见 implementation plan 公开接口；Windows 为 `internal static` 方法组（同 plan）。  
`layoutVersion` 常量两端均为 `2`。

硬编码替换点（实现时以 grep 为准）：

- **macOS：** Configurators、Hook、Proxy、Monitors、ClaudeContextUsage、UsageMonitoringCoordinator
- **Windows：** `ClaudeHookStatusWriter` / Monitor、`CodexUsageSnapshotCache`、`ClaudeHookConfigurator`、Grok 写端（若有）

### 2. `AgentHaloLayoutMigrator`（双端）

| 平台 | 位置 |
|------|------|
| macOS | `AgentHaloLayoutMigrator.swift` |
| Windows | `AgentHaloLayoutMigrator.cs` |

#### 调用时机

```text
App 启动（macOS AppDelegate / Windows HaloWindow）
  → migrateIfNeeded
  → Configurator(s)          # macOS: Claude+Grok+StatusLine；Windows: ClaudeHook（+Grok 若有）
  → monitors start
```

macOS 独立进程 `bin/status-hook` / `bin/statusline-proxy` **不**跑完整迁移；只写新路径，目录不存在则创建。收敛依赖 **App 启动迁移 + Configurator 回写**。

Windows hook 入口是主程序 `--claude-hook`：短路径写 jsonl，同样不跑迁移；UI 进程启动时迁移。

#### 算法（幂等，双端共用语义）

```text
migrateIfNeeded:
  ensure root + bin + state + logs + cache

  if readVersion() >= 2:
    scrubLegacyDataPaths()      # 只删数据类旧路径；不删 macOS 旧 binary
    // Windows: 另可删 AgentHaloHook.exe；另 scrub AppData usage 残留
    return

  moveOrReplace(legacyClaudeStatusLog → claudeStatusLog)
  moveOrReplace(legacyGrokStatusLog → grokStatusLog)
  moveDirectoryContents(legacyContexts → claudeContextsDirectory)
  moveOrReplace(legacyUsageInAgentHaloRoot → usageSnapshots)
  // Windows only:
  moveOrReplace(legacyUsageInAppData → usageSnapshots)
  // macOS only:
  moveOrReplace(legacyStatuslineOriginalCommand → statuslineOriginalCommand)

  removeIfExists(legacyClaudeContextFile)
  remove residual empty legacy data paths / dirs
  // Windows: removeIfExists(AgentHaloHook.exe)
  // macOS: DO NOT remove legacy binaries here

  writeLayoutVersion(2)
  // macOS: pruneClaudeContexts (force)
```

`moveOrReplace`：

1. `to` 已存在 → 删除 `from`（新为准）。
2. `to` 不存在且 `from` 存在 → rename；失败则 copy + 校验 + 删 `from`。
3. 两者都不存在 → no-op。
4. 单步 IO 错误 → log，继续其他项；**不抛 UI**。

#### 清扫残留（version ≥ 2）

- **删除数据类旧路径**：扁平 jsonl、contexts 目录、legacy context 单文件、根 usage、根 original-command、Windows AppData usage 残留。
- **macOS 旧 binary**：Migrator / scrub **不删**；仅 Configurator 在 settings 回写成功后删除。
- **Windows `AgentHaloHook.exe`**：Migrator scrub 可删（与现有 `RemoveLegacyHookHelper` 合并，避免重复即可）。
- 不得删除 `bin/`、`state/`、`logs/`、`cache/` 下的新文件；不得删除 `CodexHalo\settings.json` / `halo.log`。

### 3. 外链回写与旧二进制删除（**仅 macOS**）

#### Claude

`ClaudeHookConfigurator` / `ClaudeStatusLineConfigurator`：

1. Stage bundle → `paths.statusHook` / `paths.statuslineProxy`（`0755`）。
2. 更新 `~/.claude/settings.json`：hooks / statusLine 指向新路径；用户原 statusline 写入 `state/statusline-original-command`。
3. **「已配置」判定必须要求新路径**；仍指向 legacy 时必须回写，禁止 short-circuit 跳过。
4. 原子写 settings **成功后**再删根级旧 binary。

#### Grok

`GrokHookConfigurator`：stage 同一 hook → `bin/status-hook`；回写 `~/.grok/hooks/agent-halo-status.json`；成功后可删根级旧 hook binary。

#### Windows

`ClaudeHookConfigurator` 继续配置 `Quote(AgentHalo.exe) --claude-hook <Event>`。  
**禁止**改为 `bin/status-hook`。仅清理 `AgentHaloHook.exe` 遗留。

### 4. Hook / Proxy 写路径

#### macOS `ClaudeCodeStatusHook` / Windows `ClaudeHookStatusWriter`

- 写 `logs/claude-status.jsonl` 或 `logs/grok-status.jsonl`（按 Grok 分流；无 Grok 则仅 Claude）。
- 轮转保持约 3 MiB 触发 / 保留约 2 MiB；macOS `flock`，Windows 现有 Mutex。
- 确保 `logs/` 存在。

#### macOS Statusline proxy

- 快照只写 `cache/claude-contexts/{sessionId}.json`。
- 读 `state/statusline-original-command`。
- write 后 opportunistic prune。

### 5. 读路径（无 fallback）

| 组件 | 唯一路径 | 平台 |
|------|----------|------|
| Claude hook monitor | `logs/claude-status.jsonl` | 双端 |
| Grok hook monitor | `logs/grok-status.jsonl` | 有 Grok 时 |
| Claude context reader | `cache/claude-contexts/` | macOS |
| Usage snapshot cache | `cache/usage-snapshots-v1.json` | 双端 |
| Statusline original | `state/statusline-original-command` | macOS |

文件缺失 → 空状态 / `--`。  
**删除** macOS 对 `claude-code-context.json` 与旧 `claude-code-contexts` 的兼容读取。

### 6. Contexts GC（**macOS 必须**）

挂载：`write` 后（节流）、迁移成功末尾、App 启动 force 一次。

| 参数 | 值 |
|------|-----|
| `maxAge` | 24h（优先 snapshot `updatedAt`，否则 mtime） |
| `maxFiles` | 40 |
| `minRetainAge` | 10min（数量上限不删） |
| `pruneThrottle` | 60s/进程 |

读侧 `snapshotMaxAge = 300` 不变。Windows 无 writer 时可不实现 prune 逻辑。

### 7. 用量缓存

- 最终路径：`cache/usage-snapshots-v1.json`（双端）。
- macOS：从 `.agent-halo` 根迁入；schema / LRU / 30 天策略不变。
- Windows：从 `LocalAppData\CodexHalo\usage-snapshots-v1.json` 迁入；**平台内** schema 不变（不必与 macOS 字节级兼容）。

## 权限与安全

**macOS：**

| 对象 | 权限 |
|------|------|
| `~/.agent-halo/` 及子目录 | `0700` |
| `bin/*` | `0755` |
| `logs/*`、`state/*`、`cache/**` 文件 | `0600` |
| `.layout-version` | `0600` |

**Windows：** 依赖用户配置文件默认 ACL；不强制模拟 Unix mode。

- 不在 `.agent-halo` 写入 OAuth token / API key。
- context 快照仅含 sessionId、model、tokens、使用率、时间戳。
- logs 含 cwd / sessionId：依赖主目录私有性。

## 失败与边界行为

| 场景 | 行为 |
|------|------|
| 迁移中途崩溃 | 下次启动重试；已在新路径的文件保留；version 可能仍 &lt;2 或已写 2 后靠 scrub 清残留 |
| 旧 jsonl 被 hook 并发写入 | best-effort；最坏丢近期事件 |
| macOS settings 回写失败 | 保留旧 binary；下次重试 |
| macOS stage 失败 | 不删旧 binary；不改坏 settings |
| cache 被用户删除 | 自动重建；冷启动 |
| 只跑 hook 未开 App（macOS 旧 binary） | 可能写旧路径；用户打开 App 一次后迁移+回写收敛 |
| Windows 仅 hook CLI 路径 | 写新路径 `logs/*`（UI 迁移创建目录）；usage 待 UI 启动迁移 |

## 实施阶段

与 [implementation plan](../plans/2026-07-29-agent-halo-data-layout-implementation.md) 轨道对齐，**A（macOS）与 B（Windows）并行**：

| 阶段 | 内容 |
|------|------|
| A1–A3 / B1–B3 | Paths + Migrator + 启动接入 + 日志读写新路径 |
| A4–A5 / B4 | macOS bin 外链与全链路切路径；Windows usage 路径 |
| A6 | macOS contexts GC |
| A7 / B5 | 回归 grep + self-check |
| C1 | README + spec 状态收口 |

## 测试计划

### macOS（CoreChecks）

| 用例 | 期望 |
|------|------|
| 空 home → migrate | `bin/state/logs/cache` + version=2 |
| 旧扁平完整数据 | 新路径有内容；数据旧路径删除；旧 binary 仍在（A2） |
| 新路径已存在 | 保留新，删旧 |
| 幂等 / scrub | version=2 清残留 jsonl |
| contexts GC | ≤40；24h 删；10min 保护 |
| 无 legacy context 读 | 单文件不再可读 |
| Configurator | 指向 `bin/*`；成功后删旧 binary；失败保留 |

### Windows（Diagnostics / `--self-test`）

| 用例 | 期望 |
|------|------|
| Paths 契约 | logs/cache 相对路径正确；legacy 名正确 |
| migrate 旧 jsonl | → `logs\claude-status.jsonl`；旧文件删除 |
| migrate AppData usage | → `cache\usage-snapshots-v1.json`；不碰 settings.json |
| 幂等 | 第二次无破坏 |
| Hook 写入 | 只写 `logs\claude-status.jsonl` |
| Usage cache 默认 | `AgentHaloPaths.UsageSnapshots` |
| Configurator | 仍为 `AgentHalo.exe --claude-hook` |

### 手工验收

**macOS：** 启动后 layout=2；无扁平数据残留；settings→`bin/*`；Claude/Grok/ccline/context 正常。

**Windows：** 启动后 layout=2；hook 写 `logs\claude-status.jsonl`；usage 在 `cache\`；`LocalAppData\CodexHalo\settings.json` 仍在；hooks 仍指向主 exe。

## 成功标准

1. 两端新安装即为 layout v2。
2. 两端旧安装启动一次自动迁移，用户无感。
3. 生产默认路径不再写入扁平 `claude-code-status.jsonl` / `grok-build-status.jsonl`。
4. Usage 最终均在 `.agent-halo/cache/usage-snapshots-v1.json`。
5. macOS：contexts 有界；staged bin 外链正确。
6. Windows：主 exe hook 模型不变；LocalAppData 设置不被破坏。
7. `AgentHaloCoreChecks` 与 Windows `--self-test` 全绿；生产路径拼接收敛到 Paths。

## 文档与用户说明（C1）

> AgentHalo 在用户主目录 `.agent-halo` 存储运行时数据：
>
> - `bin/` — macOS：staged hook / statusline proxy；Windows：可为空
> - `state/` — macOS：statusline 链式命令等
> - `logs/` — 近期 lifecycle 事件（自动轮转）
> - `cache/` — 可安全删除（context / usage）；删后会重建
>
> Windows 应用设置仍在 `%LOCALAPPDATA%\CodexHalo\`。

## 风险摘要

| 风险 | 等级 | 缓解 |
|------|------|------|
| macOS 回写前删旧 binary | 高 | 仅 settings 成功后删除；Migrator 不删 binary |
| jsonl 迁移丢事件 | 低 | 可接受 |
| hook 在 App 迁移前写盘 | 中 | 启动迁移 + 只写新路径收敛 |
| Windows 误搬整个 CodexHalo | 高 | 只搬 usage-snapshots 单文件 |
| Windows 误改为 staged bin hook | 高 | 明确禁止 |
| 用户脚本依赖旧 jsonl | 低 | 文档说明新路径 |

## 一句话总结

> 双端共用 `.agent-halo` 布局 v2（`bin/state/logs/cache`）与 `AgentHaloPaths` + 启动迁移（删旧数据、无双读）；macOS 另做 staged `bin/*` 外链回写与 contexts GC；Windows 另把 AppData usage 迁入 `cache/` 并保持 `AgentHalo.exe --claude-hook`。
