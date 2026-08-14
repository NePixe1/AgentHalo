# OpenUsage Tokens 统计调研

日期：2026-08-14  
参考仓库：`/Users/wjs/work/ossp/openusage`（当前 `main`）  
已确认规格：[本地 Tokens 统计与迷你热力](../superpowers/specs/2026-08-14-macos-token-stats-heatmap-design.md)  
目的：弄清 OpenUsage 如何从本地日志统计 tokens，并给出 AgentHalo 后续落地的边界与复用建议。

本文只做调研，不改变产品或代码。AgentHalo 现有的 OAuth「五小时 / 每周」额度监控已经实现过一轮 OpenUsage 风格管线，见 [2026-07-10 设计](../superpowers/specs/2026-07-10-openusage-monitoring-macos-design.md)。那一轮**明确排除**了本地消费估算、历史图表和通用 Widget。本文覆盖的正是被排除的那一层。

---

## 1. 先分清两套「用量」

OpenUsage 和 AgentHalo 都谈 usage，但其实是两套互不替代的数据。

| 维度 | A. 订阅额度（quota） | B. 本地 tokens 统计（本文） |
| --- | --- | --- |
| 问题 | 这个计费窗口还剩多少 | 今天 / 昨天 / 近 30 天实际烧了多少 token（以及估多少钱） |
| 来源 | 官方 Usage API（OAuth） | 本机 CLI 会话日志 / CSV / SQLite |
| 单位 | 百分比、重置时间 | token 计数 + 可选美元估算 |
| 是否需要登录 | 要（读官方额度） | 不要；有日志就能扫 |
| AgentHalo 现状 | 已做：Codex / Claude / Grok 的 5h + Weekly | 未做。详情面板只有**当前会话/当前轮**的 input/output |

OpenUsage 把 B 做成三块磁贴（Today / Yesterday / Last 30 Days）加一条 30 天趋势图，并在磁贴上挂模型拆分 hover。美元是按公开 API 价估算的「等值」，不是账单；订阅套餐本身不按 token 收费。

**对 AgentHalo 的含义：** 产品承诺写明「No … cost meter」（见 `docs/PRODUCT.md`）。因此后续实现应默认做 **token 计数**，不要照搬美元磁贴、Total Spend 环、计价刷新网络。额度条和 token 统计可以并存，但不要混成一个数。

---

## 2. 核心结论

1. Tokens 统计是一条独立管线：`发现日志 → 增量解析 → 去重 → 按本地日历日聚合 → 展示`。它和 `AuthStore → UsageClient → Mapper` 的额度管线并行，失败互不影响。
2. 共享层很薄、很值得借：`DailyUsageSeries` / `DailyUsageAccumulator` / `IncrementalJSONLScanner` / `SpendTileMapper`。难的是各 CLI 日志语义，不是 UI。
3. Codex / Claude 的正确性几乎全在去重。子代理回放、sidechain 复用、累计快照重放，任何一处漏掉都会把数字放大一个数量级（OpenUsage 自己修过约 20 倍虚高）。
4. OpenUsage 有一条 AgentHalo **不能照搬**的规则：无法计价的模型，其 token **也不计入任何总数**。这是为了让「$4.08 · 1.2M tokens」自洽。AgentHalo 若只显示 token、不做估价，必须改成「有日志就计数」。
5. Grok 在两边读的不是同一份文件。OpenUsage 读 `~/.grok/logs/unified.jsonl` 的 `shell.turn.inference_done`；AgentHalo 读会话目录里的 `updates.jsonl` / `signals.json` 做上下文占用。不能复用现有 Grok context reader 当日统计。
6. 已确认：只扫当前焦点 Agent 的原生 CLI 日志（不把 Pi 用量折回）；详情面板按 Today / Yesterday / Last 30 Days 三行展示。像素级排版、是否带美元、空态文案仍待讨论。

---

## 3. 端到端数据流

```text
Provider.refresh()
  ├── Usage API  →  Session / Weekly / Extra / Credits     （额度，已在 Halo）
  └── 本地扫描   →  LogUsageScan                            （tokens，未在 Halo）
        ├── CodexLogUsageScanner  ~/.codex/sessions/**/*.jsonl
        ├── ClaudeLogUsageScanner ~/.claude/projects/**/*.jsonl
        ├── GrokLogUsageScanner   ~/.grok/logs/unified.jsonl
        ├── PiUsageScanner        ~/.pi/agent/sessions/**/*.jsonl
        ├── OpenCodeUsageScanner  ~/.local/share/opencode/*.db
        └── Cursor CSV            账户级 export-usage-events-csv
              │
              ▼
        IncrementalJSONLScanner<Item>     （path + size + mtime 缓存）
              │  每文件解析成 Entry / Event
              ▼
        去重（provider 各自规则）
              │
              ▼
        DailyUsageAccumulator
              │  dayKey = 本地日历 yyyy-MM-dd
              ▼
        LogUsageScan
              ├── series:          [DailyUsageEntry]     日 tokens + cost
              ├── modelUsage:      [day → [model → tokens, cost]]
              └── unknownModelsByDay
              │
              ├── SpendTileMapper.appendTokenUsage   Today / Yesterday / 30d
              └── SpendTileMapper.appendUsageTrend   30 根 token 柱
              │
              ▼
        ProviderSnapshot.usageHistory   （可选：iCloud 多机合并）
```

关键文件：

| 角色 | 路径 |
| --- | --- |
| 日序列与扫描结果 | `Sources/OpenUsage/Models/DailyUsageSeries.swift` |
| 日累加 / 多源合并 | `Sources/OpenUsage/Providers/DailyUsageAccumulator.swift` |
| 增量 JSONL 扫描 | `Sources/OpenUsage/Providers/IncrementalJSONLScanner.swift` |
| 磁盘解析缓存 | `Sources/OpenUsage/Providers/JSONLScanCacheStore.swift` |
| 并发许可 | `Sources/OpenUsage/Providers/JSONLScanCacheCoordination.swift` |
| 磁贴 / 趋势 / 模型折叠 | `Sources/OpenUsage/Providers/SpendTileMapper.swift` |
| 计价快照 | `Sources/OpenUsage/Pricing/ModelPricing.swift` |
| 费率与分桶 | `Sources/OpenUsage/Pricing/ModelRates.swift` |
| 价目刷新 | `Sources/OpenUsage/Pricing/ModelPricingStore.swift` |
| 行为说明 | `docs/pricing.md`、`docs/dashboard.md`、`docs/providers/{codex,claude,grok}.md` |

刷新周期与额度共用：约 5 分钟一次。扫描永远用「手头已有」的价目，不等网络。取消发生在 native 扫描和 pi 扫描之间时，两趟结果整组丢弃，避免半成品覆盖上一份完整历史。

---

## 4. 共享层：值得直接借的形状

### 4.1 日序列

```swift
struct DailyUsageEntry {
    var date: String          // yyyy-MM-dd，本地日历
    var totalTokens: Int
    var costUSD: Double?      // Halo 一期可去掉
}

struct LogUsageScan {
    var series: DailyUsageSeries
    var modelUsage: ModelUsageSeries?
    var unknownModelsByDay: [String: Set<String>]
}
```

窗口约定写在 `UsageHistoryWindow`：`previousDays = 30`，含义是 **今天 + 往前 30 个日历日**（共 31 天）。`sinceDate` 取那天的 `startOfDay`，不能写成 `now - 30*86400`，否则最早那天上午的行会被切掉（OpenCode 扫描器注释里专门强调了这一点）。

日键只有一个函数：`DailyUsageAccumulator.dayKey(from:calendar:)`。OpenUsage 把它当成契约——当年 ccusage 有过「时区不一致导致当天显示 $0」的事故。

空日语义：`totalTokens == 0 && cost == 0` 的日子**不生成磁贴**，显示 “No data”，而不是 `$0.00 · 0 tokens`。理由是「源还没扫到」和「真的零消耗」无法区分，假零会和旁边还在涨的 Session 条打架。

### 4.2 累加器

`DailyUsageAccumulator` 只做三件事：

1. `add(day, tokens, cost, model)` —— 只收已经决定计入的行
2. `addUnknownModel(day, model)` —— 只给警告三角用
3. `merged([LogUsageScan?])` —— 把 native 扫描和 pi 切片按「模型 × 日」重放一遍，保证 series / modelUsage / unknown 一致

扫描器各自负责解析和计价，累加器不认日志格式。Halo 若去掉 cost，这个类型可以再瘦一圈，但 `dayKey` + `merged` 仍该留下。

### 4.3 增量 JSONL 扫描

`IncrementalJSONLScanner<Item>` 是整条管线里最值得整段移植的部分。

- 泛型 `Item` 由扫描器提供（Codex `Event`、Claude `Entry`、Pi `Entry`），必须 `Codable & Sendable`
- 缓存键：`path + size + mtime`。三者都没变就复用解析结果，每次刷新只对改过的文件跑 parser
- 窗口外（`mtime < since`）的文件直接跳过，十年历史树也能秒扫
- 同 identity 串行：actor 在 `await parseFiles` 处可重入，不加闸的话多账户卡会同时冷解析同一 home 再互相覆盖缓存
- 不同 identity 并行；全扫描器共享一个最多 8 路的 `JSONLParsePermitPool`，避免启动时几十路同时读盘
- 读失败的文件不写缓存，避免一次瞬时 IO 错误把空结果钉死
- 取消返回 `nil`；扫完但没行返回 `[]`。调用方不得把取消当成「今天没用量」
- 磁盘：`~/Library/Application Support/OpenUsage/log-scan-cache/<namespace>-<fnv1a(identity)>/`
  - `manifest.plist` + `files/<fnv1a(path)>.plist`
  - 只重写变更记录，不是整份 30 天历史
  - 写前 `flock`，记录先落盘再改 manifest，崩了最多留孤儿记录
  - `schemaVersion` 变了整仓作废重扫
  - 身份目录 35 天不用就删
- Grok 是单文件追加日志，没用这套 actor，只复用了 `JSONLScanning.sinceDate`

Halo 若移植，缓存应落到 `~/.agent-halo/cache/`，不要去碰 OpenUsage 的 Application Support。`namespace` + `schemaVersion` 按 parser 语义 bump。

### 4.4 Token 分桶

所有扫描器最终都归一成：

```swift
struct TokenBreakdown {
    var input: Int            // 非缓存输入
    var cacheWrite5m: Int
    var cacheWrite1h: Int     // 按 2× input 计价
    var cacheRead: Int
    var output: Int
    var isFast: Bool
    var promptTokens: Int { input + cacheWrite5m + cacheWrite1h + cacheRead }
    var totalTokens: Int { promptTokens + output }
}
```

计价公式（`ModelRates.costDollars`）：

```
cost = input×Rin + output×Rout + cacheWrite5m×Rw5 + cacheWrite1h×(Rin×2) + cacheRead×Rr
     × (isFast ? fastMultiplier : 1)
```

prompt 超过 long-context 阈值（多数 200k，Codex 部分模型 272k）时，**整次请求**走高档费率，不是只给超出部分加价。

### 4.5 展示层（Halo 不必整段搬）

`SpendTileMapper` 做四件事：

1. 抽出 Today / Yesterday / 窗口合计，拼成 `$4.08 · 1.2M tokens`
2. 美元标 ⓘ（本地估算）；token 永远标「实测」
3. 30 天柱状趋势：空日补 0，避免不相邻的天被挤到一起
4. 模型 hover：按 cost（全都能计价）或 tokens 排序；不足 5% 或超出前 5 名折进 Other；Grok 无法归因的行叫 `Unattributed` 并一律进 Other

Halo 详情面板宽度 268pt、审美是 ambient-first，不该引入三块磁贴 + 趋势 + hover 面板。共享层停在 `LogUsageScan` 即可。

---

## 5. 各 Provider 怎么从日志抠 token

### 5.1 Codex —— 最难，也必须先做对

源码：`Sources/OpenUsage/Providers/Codex/CodexLogUsageScanner.swift`  
测试：`Tests/OpenUsageTests/CodexLogUsageScannerTests.swift`（约 970 行，覆盖了几乎所有坑）

**文件发现**

- Home：`$CODEX_HOME`（逗号分隔）否则 `~/.codex`
- 每个 home 扫 `sessions/` 和 `archived_sessions/`；同一相对路径以 `sessions/` 为准
- 两个目录都没有则退回扫整个 home（ccusage 兼容）
- 跟随 symlink，所以 home 链到 Dropbox 也能扫

**一行怎么变成一次用量**

只关心这些 type：

| 行 | 作用 |
| --- | --- |
| `turn_context` | 更新当前 model |
| `thread_settings_applied` | 更新 service tier（`fast` / `priority` → 该 session 后续 turn 按快档计价） |
| `session_meta` | 判断是不是子会话（fork / subagent） |
| `task_started` | 子会话回放结束闸门 |
| `event_msg` / `token_count` | 真正的用量 |

`token_count` 优先取 `info.last_token_usage`；没有则对 `info.total_token_usage` 做与上一行的差。字段名兼容旧拼写：`prompt_tokens` / `completion_tokens` / `cache_read_input_tokens`。

`cached` 截断为 `min(cached, input)`，避免缓存大于输入。  
`cached` 是 input 的子集：计价用 `(input - cached) × Rin + cached × Rcache`。  
`reasoning_output_tokens` 计入 output 计价，但 `total` 优先用日志自报的 `total_tokens`。

**必须做对的去重（三层）**

1. **累计快照重放。** Codex 会重复吐出 `total_token_usage` 没变的 `token_count`。即使带着 `last_token_usage` 也要丢。漏掉这一步会按 turn 重复计数。
2. **子代理 / fork 回放。** 子会话文件开头会把父会话整段 `token_count` 再写一遍，时间戳被改写。识别条件（`isChildSessionMeta`）：
   - `forked_from_id` 非 null
   - `parent_thread_id` 非 null
   - `thread_source == "subagent"`
   - `source.subagent` 非 null
   - JSON `null` 必须当「没有」，根会话常写 `forked_from_id: null`
   - 回放段只用来给 delta 打 baseline，不发出 Event
   - 闸门清掉的条件：第一条 `task_started.started_at >= 子会话创建时间`。父会话回放的 `task_started` 带着更老的 `started_at`
   - **不要**用「和 spawn 同一秒」去滤 `token_count`。大段父历史回放要好几秒，这个启发式曾导致约 20 倍虚高
3. **跨文件相同 Event。** 聚合时用 `(timestamp, model, pricingModel, input, cached, output, reasoning, total)` 做 set，复制出来的 session 日志只计一次。

**模型和计价特例**

- 没有任何 model 元数据时 fallback `gpt-5`
- `codex-auto-review` 在拆分里保留原名，估价按发布日映射到当时的 dated Codex 模型
- 快档乘数来自**该 session 自己的日志**，不读当前 `config.toml`（改配置不得回溯改写历史）
- 硬编码：GPT-5.5 快档 2.5×，GPT-5.4 / 5.6-sol/terra/luna 2×；Pro 模型无 cache 折扣；5.4/5.5/5.6 在 272k prompt 以上整单走长上下文价
- 无法计价的模型：token 不进总数，名字进 `unknownModelsByDay`

**和 Halo 现有 SessionReducer 的关系**

`SessionReducer.updateSessionDetails` 已经在读同一份 `total_token_usage` / `last_token_usage`，但用途完全不同：它算的是**当前会话当前轮**的 input/output，给 API Key 卡片用。日统计要扫全部 rollout、做 delta、丢掉回放。两套解析不要揉进一个 reducer。

### 5.2 Claude

源码：`Sources/OpenUsage/Providers/Claude/ClaudeLogUsageScanner.swift`

**文件发现**

- `$CLAUDE_CONFIG_DIR`（逗号分隔；也可以直接指向 `projects/`）
- 否则 `$XDG_CONFIG_HOME/claude` 和 `~/.claude`，且该目录下必须有 `projects/`
- 额外追加 Cowork：`~/Library/Application Support/Claude/local-agent-mode-sessions/.../.claude`
- 只扫每个 root 下的 `projects/**/*.jsonl`
- `--no-session-persistence` 的运行没有日志，统计不到；持久化的 `claude -p` 可以

**解析**

先字节级预过滤 `"usage":{`。含 Claude 从不会写成 `null` 的字段（`id` / `cwd` / `model` / `speed` / `costUSD` / `sessionId` / `requestId` / cache token 字段等）直接丢，对齐 ccusage。

有效行：`message.usage` 里同时有数值 `input_tokens` 和 `output_tokens`；`version` 若存在必须是 semver 前缀；id/model 若存在不能是空串。

分桶：

- `cache_creation.ephemeral_5m_input_tokens` / `ephemeral_1h_input_tokens`
- 否则退回聚合字段 `cache_creation_input_tokens`（整段当 5m）
- `cache_read_input_tokens`
- `speed` ∈ {`fast`, `standard`}；其他值整行丢弃

`usage.iterations` 里只有 `type == "advisor_message"` 另开一条、用 advisor 自己的 model。普通 iteration 已经含在父 usage 里，再计会双计。Advisor 没有自带 `costUSD`，单独按 advisor 模型估价。

父行若带 `costUSD` 则原样使用（cost mode auto），否则走 `ModelPricing`。

**去重**

- 主键 `(message.id, requestId)`
- 第二索引：仅 `message.id`，用来抓 sidechain 把父消息再用新 requestId 重放的情况
- 冲突保留：非 sidechain > token 总数更大 > 带 `speed` 字段
- 没有 `message.id` 的行全部保留

无法计价且没有自带 cost 的模型：token 不进总数。

### 5.3 Grok

源码：`Sources/OpenUsage/Providers/Grok/GrokLogUsageScanner.swift`

和 Codex/Claude 不同：

- 单文件：`$GROK_HOME/logs/unified.jsonl` 或 `~/.grok/logs/unified.jsonl`
- 整文件读入，不用增量 actor
- 用量行：`msg == "shell.turn.inference_done"`
- 字段：`ctx.prompt_tokens`、`completion_tokens`、`reasoning_tokens`、`cached_prompt_tokens`
- `cached` 是 prompt 子集；`output = completion + reasoning`；`total = prompt + output`
- **用量行没有 model id。** 靠同一 `pid` 上更早的模型事件归因：
  - `model changed` → `ctx.model`
  - `model catalog: notifying clients` → `ctx.current_model_id`
  - `backend_search: model switch`
  - `subagent model resolved`
- 模型状态**不受 `since` 窗口限制**，这样跨午夜的 session 仍能归因
- 归因失败的行直接丢（连 Unattributed 都不进——因为没有名字可警告）；能归因但价目没有的模型进 `unknownModelsByDay`，token 同样不进总数

**和 Halo 现有 Grok 读取器不要混用**

| | OpenUsage 日统计 | AgentHalo 上下文 |
| --- | --- | --- |
| 文件 | `~/.grok/logs/unified.jsonl` | `~/.grok/sessions/<cwd>/<id>/updates.jsonl` + `signals.json` |
| 事件 | `shell.turn.inference_done` | `params._meta.totalTokens` / `contextWindowUsage` |
| 粒度 | 每次推理一行，可按日加总 | 当前会话占用 |

`updates.jsonl` 的 `totalTokens` 是上下文窗口占用（含历史），不是「这一天新产生的 token」。拿它做日统计会严重高估。

### 5.4 Pi —— 并入 Codex / Claude，不是第三张卡

源码：`Sources/OpenUsage/Providers/Pi/PiUsageScanner.swift`

- 扫 `$PI_CODING_AGENT_SESSION_DIR` 或 `~/.pi/agent/sessions/**/*.jsonl`
- 全 provider 共用一个 actor，按 `cardID` 过滤后分别并进 Claude / Codex
- 只收 `type == message && role == assistant` 且 `provider` 能映射到已跟踪卡片的行
- 分桶字段名不同：`usage.input` / `output` / `cacheWrite` / `cacheWrite1h` / `cacheRead`
- token 显示用 pi 自报的 `usage.totalTokens`（对齐 pi footer）
- `usage.cost.total > 0` 用自带成本；`$0`（订阅用量 pi 不估价）再走共享计价
- 去重：按消息 `id` keep-first（fork/clone 会复制）

Halo 已有 Pi 生命周期和当前会话 input/output。日统计若要「Claude 经 Pi 打的也算进 Claude」，就移植这个扫描器；若第一期只认各 CLI 原生日志，可以后置。

### 5.5 其余（Halo 当前不需要）

| Provider | 源 | 要点 |
| --- | --- | --- |
| OpenCode | `~/.local/share/opencode/opencode*.db` | 用自带 `cost`，不走价目；只计 hosted provider（`opencode-go` / `opencode`），BYO key 的 `cost: 0` 忽略 |
| Cursor | 账户 CSV export | 已是账户级，禁止再和本机日志做 iCloud 加总；一行里挤了多次请求，不用长上下文阈值 |
| OpenRouter | API 直接给美元 | 与本地 token 扫描无关 |

---

## 6. 计价层（Halo 第一期建议整层跳过）

三层覆盖，后者被前者盖住：

1. 仓库维护的 `pricing_supplement.json`（Cursor 自有模型、fast 倍率、别名）
2. LiteLLM `model_prices_and_context_window.json`
3. models.dev `api.json`（只做 exact id，不做 fuzzy，避免经销商同 id 不同价）

运行时每小时带 ETag 拉一次，缓存在 `~/Library/Application Support/OpenUsage/pricing/`。扫描从不堵在网络上。应用内打包了三份快照，离线也能估价。

模型名解析顺序：supplement 别名 → supplement 精确 → LiteLLM 精确 → `-fast` 后缀（基价 × 倍率；没有倍率则保持未计价，禁止悄悄用标准价）→ LiteLLM fuzzy → models.dev exact。

拉价目的域名：`raw.githubusercontent.com`、`models.dev`、OpenUsage GitHub Pages。请求里**不含**任何用量或日志。

即便以后 Halo 要估价，也不该在运行时依赖 OpenUsage 的 gh-pages supplement，除非明确接受这条供应链。更稳的是：只显示 token，或者只信日志里自带的 `costUSD`（Claude / Pi / OpenCode）。

---

## 7. 隐私、性能、失败语义

和 Halo 现有约束一致、可以直接沿用：

- 日志内容不出本机。扫描是纯本地 IO
- 缓存里是规范化后的 Entry（时间戳、分桶、model slug），不是提示词或工具输出
- 诊断日志只记文件数、缓存命中、读失败路径类别，不记行内容
- 「扫不到」和「扫到但当天为 0」都渲染成 No data，不编造 0
- 扫描失败不影响额度快照；额度 API 失败也不清本地 token 序列
- 读失败用 edge-trigger 记者，同一坏文件不会每 5 分钟刷一次 warn

性能要点：

- 热路径是「mtime 没变 → 内存/磁盘缓存命中 → 只对 Entry 做去重和按日加总」
- 冷启动代价是第一次扫 31 天 JSONL；之后应接近增量
- Codex/Claude 的 `projects/` 和 `sessions/` 可能有数千文件，必须保留 mtime 窗口和并发上限
- Grok 单文件会一直长大；第一期整文件扫描可接受，文件到几百 MB 再考虑 offset 增量

---

## 8. AgentHalo 现状对照

### 已经有的

| 能力 | 位置 | 粒度 |
| --- | --- | --- |
| OAuth 5h / Weekly | `UsageMonitoring/` | 账户窗口百分比 |
| Codex 当前轮 input/output | `SessionReducer.updateSessionDetails` | 单个 live session |
| Claude 当前会话 input/output | `ClaudeContextUsage` / statusline proxy | 精确 session |
| Grok 上下文占用 | `GrokSessionContextReader`（`updates.jsonl` / `signals.json`） | 当前 session 窗口 |
| Pi 当前会话 input/output | `PiStatusMonitor` / `PiRuntimeMonitor` | 当前 session |
| API Key 卡片四行（含 Token） | `DetailsContentResolver` + `DetailsPanel` | 仅 API Key 模式 |
| Windows 同类当前轮 Token | `DetailsWindow.FormatTokenPair` | 当前 session |

### 没有的

- 跨会话、按本地日历日的 token 加总
- 今日 / 昨日 / 近 30 天
- 按模型拆分
- 增量 JSONL 历史扫描
- 把 Pi 用量折回 Claude / Codex
- 任何 cost / 价目表

### 产品约束（实现时不要踩）

- `PRODUCT.md`：无 cost meter、无 cloud、无会话上传
- 2026-07-10 设计：不引入 Widget 系统、历史图表、本地消费估算
- UI：极简、低噪、详情面板约 268pt
- 监控暂停是运行时状态，不持久
- 自定义 / 第三方推理端点不接收 Halo 的网络请求（本地扫日志不受此限）

因此「tokens 统计」在 Halo 里不是再做一个 OpenUsage 仪表盘，而是：在现有详情面板里，为当前焦点 Agent 增加三行本地日志合计（Today / Yesterday / Last 30 Days）。OAuth 模式现在完全不展示跨会话 token，这是最大的产品缺口。像素级排版另议；参考截图像 OpenUsage 那样同时写 `$65.58 · 89.1M tokens`，这与 `PRODUCT.md` 的「无 cost meter」冲突，展示讨论时必须单独拍板。

---

## 9. 建议的落地切面

不要把 OpenUsage 整条 spend 管线搬过来。建议按层切开。

### 建议做

1. **共享扫描内核**（macOS `AgentHaloCore`，后续 Windows 可对等移植）
   - `JSONLScanning`（发现 `*.jsonl`、跟随 symlink、`sinceDate`）
   - `IncrementalJSONLScanner` + 落在 `~/.agent-halo/cache/log-scan/` 的版本化缓存
   - `DailyUsageAccumulator` 的 token-only 变体
2. **三个原生扫描器**，语义对齐 OpenUsage 测试，而不是对齐其 UI
   - Codex：delta + 子代理闸门 + 累计快照去重 + 跨文件 EventKey
   - Claude：null 预过滤 + `(message.id, requestId)` / sidechain 去重 + advisor 分行
   - Grok：`unified.jsonl` + 按 pid 归因（不要用 `updates.jsonl`）
3. **领域模型**（与现有 `UsageSnapshot` 并列，不要塞进额度快照）

   ```swift
   struct TokenDayTotals {
       var date: String            // yyyy-MM-dd 本地
       var totalTokens: Int
       var inputTokens: Int        // 可选
       var outputTokens: Int
       var cacheReadTokens: Int
       var byModel: [TokenModelTotal]
   }

   struct TokenStatsSnapshot {
       var providerID: UsageProviderID
       var today: TokenDayTotals?
       var yesterday: TokenDayTotals?
       var last31DaysTotal: Int
       var scannedAt: Date
   }
   ```

4. **UI（信息架构已定，视觉未定）**
   - 三行：Today / Yesterday / Last 30 Days，参考 OpenUsage 磁贴的信息密度
   - 只反映当前焦点 Agent 的原生 CLI 日志；切 Agent 立即换源，禁止串数
   - 与当前轮 input/output（API Key 卡片）分开：那是本会话，这是跨会话日历合计
   - 不抄 Status / Dashboard 外链按钮、不抄 Usage Trend、不抄 Total Spend 环
   - 是否显示美元、空态是隐藏还是 “No data”、数字缩写与中英文标签，展示讨论再定

5. **调度**
   - 挂在现有 `UsageMonitoringCoordinator` 的 5 分钟低频循环上，或并列一个 `TokenStatsCoordinator`
   - 只扫当前焦点 Provider
   - 打开详情 / 切 Agent 时 `ensureFresh`；缓存仍新鲜则不重扫
   - 扫描失败保留上一份成功快照，不改 Halo 生命周期色

### 建议明确不做（至少第一期）

| OpenUsage 能力 | 原因 |
| --- | --- |
| 美元估价、ⓘ、未计价警告三角 | 产品禁止 cost meter；也会逼你排除未计价 token |
| Usage Trend 柱状图 | 对 268pt 面板过吵 |
| 模型 hover / Other 折叠 | 同上；数据层可先留下 `byModel` |
| Total Spend 多 Provider 环 | Halo 一次只聚焦一个 Agent |
| iCloud 多机加总 | 产品无 cloud |
| LiteLLM / models.dev 定时拉取 | 无估价则无必要；也引入新网络面 |
| Cursor / OpenCode / OpenRouter / Copilot | Halo 不监控这些 |
| 认领 Codex reset credit | 与统计无关 |

### 可后置

- Pi 切片并入 Claude / Codex（已确认第一期不做）
- Cowork 目录（Claude 桌面 agent）
- Windows 对等扫描（日志布局相同，parser 可按共享夹具对齐）
- 按模型拆分 / hover
- 美元估价（若展示讨论决定要钱，再打开第 6 节计价层）

---

## 10. 移植时必须对着写测试的行为

OpenUsage 的测试就是规格。Halo 应先把这些夹具搬过来（或用同一份 JSONL fixture），再写扫描器。

**Codex**

- `last_token_usage` 优先于 `total_token_usage` 差分
- 累计 totals 不变 → 整行丢弃
- 子会话回放在首个 live `task_started` 之前不计
- `forked_from_id: null` 不是子会话
- `sessions/` 压过 `archived_sessions/` 同相对路径
- 跟随 symlink home
- 不读 `config.toml` 的 service tier
- 跨文件相同 Event 只计一次

**Claude**

- 跨文件 `(message.id, requestId)` 去重
- sidechain 复用父 message.id 时留父、丢 sidechain（除非父更瘦）
- advisor_message 单独计，普通 iteration 不计
- 带 `costUSD` 不影响 token 加法（Halo 不显示钱，但不要因为有 cost 就换一套计数）
- `speed` 非法值丢行
- 跟随 symlink `projects/`
- Cowork 根目录可后置，但默认 root 发现顺序要测

**Grok**

- 只认 `shell.turn.inference_done`
- `cached_prompt_tokens` 不重复加进 prompt
- 按 pid 归因；窗口前的模型事件仍生效
- 读 `$GROK_HOME`
- 无 model 的行不进总数

**共享**

- `dayKey` 用本地日历，可注入 `Calendar`
- `since` = 31 天窗口的 `startOfDay`
- 取消 ≠ 空扫描
- 缓存命中：同样 path/size/mtime 不重读
- schemaVersion bump 后强制重扫

---

## 11. 和现有 Halo 架构怎么接

推荐放在已有 `UsageMonitoring/` 旁边，而不是扩 `UsageSnapshot`：

```text
AgentHaloCore/
  UsageMonitoring/          # 已有：额度 API
  TokenStats/               # 新增：本地日志
    TokenStatsModels.swift
    DailyTokenAccumulator.swift
    IncrementalJSONLScanner.swift
    TokenStatsCoordinator.swift
    Codex/CodexTokenLogScanner.swift
    Claude/ClaudeTokenLogScanner.swift
    Grok/GrokTokenLogScanner.swift
```

`DetailsContentResolver` 增加可选的 `tokenStats: TokenStatsSnapshot?`。OAuth 和 API Key 都能显示今日行；它和 `contextPill` 一样，与额度 API 成败无关。

Coordinator 约束对齐现有额度状态机：

- 同 Provider 同时最多一个扫描
- 旧 Provider 的异步结果只能写自己的缓存
- 面板只在焦点仍匹配时重绘
- 不挂高频 `tick()`

Windows：parser 是纯函数，夹具可以共享。C# 侧对等实现扫描器即可，不必先做跨平台运行时。若要把日键、窗口天数放进 `agent-halo.v2.json`，只放这两个数字，不要把日志 schema 塞进行为合同。

---

## 12. 决策

### 已确认（2026-08-14）

1. **统计范围**：只计当前焦点 Agent 的原生 CLI 日志。不把 Pi 里打到 Claude/Codex 的用量折回来。
2. **行结构**：详情面板用三行，信息架构对齐参考图——Today / Yesterday / Last 30 Days。
3. **展示细节另议**：字号、对齐、是否带美元、空态、缩写、中英文文案、放在额度条上方还是下方，都不在本轮拍板。参考图里的 Status / Dashboard 按钮不是 Halo 的一部分。
4. **热度图意向**：希望有一张类似 GitHub contribution 的日历热力（参考截图：周一/三/五行标、按月分列、黄→橙浓度）。尚未决定时间窗、是否挤进现有 278×172 详情面板、以及它和三行数字的主次。

### 仍待讨论

1. **美元**：参考图是 `$65.58 · 89.1M tokens`。`PRODUCT.md` 写明无 cost meter。若只要 token，数据层不必引价目表，未知模型的 token 应全部计入。若要钱，必须另开计价层，并决定无法计价的模型是剔除 token 还是只警告。
2. **OAuth 面板位置**：三行挂在 5h / Weekly 下面，还是单独成一块。
3. **与 API Key 当前轮 token 的关系**：两套数字并存时如何避免被读成同一个数。
4. **平台**：先 macOS 还是 macOS + Windows 一起。
5. **目录覆盖**：`CODEX_HOME` + 默认 home + archived 去重建议第一期就做；Cowork 可后置。
6. **空日**：该行隐藏，还是写 “No data”（OpenUsage 的做法）。
7. **热度图 vs 面板契约**：现网详情面板锁定宽 278、拟合高 172（OAuth 与 API Key 同高）。全年 GitHub 热力约 53 列，244pt 内容宽里每格不到 5pt，不可读。**已选：守住 172，翻转主体**——默认仍是额度 / 会话卡；主体底部两颗静音点翻到 tokens 页。**tokens 页：一行摘要 + 近 5 周迷你热力**（31 个本地日历日）。Yesterday 不单独成行，悬停格子看。

---

## 14. 热度图如何兼容现有详情面板

参考图是约 11 个月、53 列 × 7 行的 contribution 图。Halo 详情面板不是那种画布。

| 约束 | 数值 | 含义 |
| --- | --- | --- |
| 面板宽 | 278pt，禁止撑宽 | 左右 inset 17，内容宽约 244pt |
| 拟合高 | 172pt，OAuth / API Key 同高 | 额度槽 70pt，会话卡槽 68pt |
| 最近一次面板设计 | 2026-08-05 方案 B | 明确「不放大外框、本期不做历史图表」 |
| 已定统计窗 | Today / Yesterday / Last 30 Days | 扫描器默认 31 个本地日历日 |

全年热力放不进去：`244 / 53 ≈ 4.6pt/格`。要看起来像参考图，至少需要约 10–11pt 格子 + 间隙，大约只能放下 **12–16 周**；若坚持全年，必须另开更宽的表面，不能留在这张悬停卡里。

颜色也不该复用 Halo 状态色。完成绿 / 工作蓝 / 思考琥珀一旦拿来表示「用量高」，会和光环语义打架。参考图那种单一黄→橙浓度，或同一墨色的透明度阶，更合适。

三行数字 + 迷你热力一起塞进现有 70pt 额度槽也不够。兼容只能三选一：

1. **守住 172，翻转主体**：额度 / 会话卡仍是默认；点一下切到「tokens 页」（三行 *或* 5 周迷你热力，不能两个都在 70pt 里）。外框不变，发现成本是多一次点击。
2. **允许面板变高，叠在额度下面**：278 宽不变，高度 recast（大约再加 80–120pt）。三行 + 近 5 周（或近 12 周）热力都看得见。破坏「OAuth 与 API Key 同高 172」契约，要新写一版高度规格。
3. **热力不进悬停卡**：卡上只留三行数字；热力放到更宽的次级面（或以后再做）。最安静，但和「想在详情里看到图」有距离。

数据上：5 周热力可以继续用 31 日扫描窗；12 周或全年必须加大 `daysBack`，冷启动扫描会明显变重。

---

## 13. 一句话

OpenUsage 的 tokens 统计 = **用一份增量 JSONL 缓存，把各 CLI 日志规范成「本地日历日 × 模型 × token 分桶」**，再可选地乘上公开价目变成估算美元。AgentHalo 应借扫描器、去重和日聚合，不借仪表盘、价目表和「无法计价就不计 token」这条规则。最大的工程风险不在 UI，而在 Codex 子代理回放和 Claude sidechain 去重——这两处必须以 OpenUsage 测试为规格，而不是凭日志样例猜测。
