# 本地 Tokens 统计与迷你热力：macOS 详细设计

## 文档状态

- 日期：2026-08-14
- 状态：设计已确认，已进入详细实施计划
- 实施计划：[本地 Tokens 统计与迷你热力 Implementation Plan](../plans/2026-08-14-macos-token-stats-heatmap-implementation.md)
- 实现范围：AgentHalo **macOS**
- 调研：[OpenUsage Tokens 统计调研](../../research/openusage-token-statistics.md)
- 参考实现：`/Users/wjs/work/ossp/openusage` 的 `CodexLogUsageScanner` / `ClaudeLogUsageScanner` / `GrokLogUsageScanner` / `IncrementalJSONLScanner` / `DailyUsageAccumulator`
- 面板契约：[API Key 会话摘要卡](./2026-08-05-api-key-session-card-details-design.md)（278×172 外框不得改）
- 额度管线：[OpenUsage 风格监控](./2026-07-10-openusage-monitoring-macos-design.md)（并行，不合并快照）

## 目标

为当前焦点 Agent 提供**跨会话、按本地日历日**的 token 合计，并在现有详情面板里用一页安静的可视化展示：

- 只扫描该 Agent 的**原生 CLI 日志**。
- 详情面板外框仍为 **278×172**。默认页仍是 OAuth 额度条或 API Key 会话卡；主体底部两颗静音点翻到 tokens 页。
- tokens 页 = **一行摘要**（Today + 30d）+ **近 5 周迷你热力**。Yesterday 不单独成行，悬停格子查看。
- 扫描失败或额度 API 失败互不影响；都不改变 Halo 生命周期色。

## 非目标

- Windows 实现（信息架构预留给对等移植，本期不改 C#）。
- 美元估价、价目表网络刷新、cost meter、ⓘ、未计价警告三角。
- 把 Pi 用量折进 Claude / Codex，或把 Claude / Codex 用量折进 Pi。
- 全年 / 12 周 GitHub 大图、Usage Trend 柱、模型 hover 面板、Total Spend 环。
- Status / Dashboard 外链按钮。
- 改变 5-Hour / Weekly 额度语义，或把 token 日合计写进 `UsageSnapshot`。
- 读取或上传会话正文、提示词、工具输出。
- 自定义 / 第三方推理端点上的网络请求（本地扫日志不受此限）。

## 已确认决策

1. 统计范围：当前焦点 Agent 的原生 CLI 日志。
2. 面板外框锁定 278×172；OAuth / API Key / tokens 页同高。
3. 用主体底部两颗静音点翻转默认页 ↔ tokens 页，不进顶栏、不加分段文案。
4. tokens 页：一行摘要 + 近 5 周迷你热力，不要三行数字。
5. 每次打开详情（面板从隐藏到显示）落在默认页；本次悬停内记住页，关掉即忘。
6. 热力浓度表示当天 token 总量；单一黄→橙；不用完成绿 / 工作蓝 / 思考琥珀。
7. 不做美元。未知模型的 token **计入**总数。
8. 新能力放进现有 `AgentHaloCore`，不新增 SwiftPM Target。
9. 扫描按 `AgentKind` 分区，不复用 `UsageProviderID`（Pi 有日志、无额度 Provider）。

## 现有架构与改造点

```text
现有
AppDelegate
  ├── UsageMonitoringCoordinator     → 5h / Weekly
  ├── 本地 Session / Claude / Grok readers → contextPill、会话卡
  └── DetailsPanel.render
        ├── quotaGroup（70pt）
        └── metadataGroup（68pt + equalizer）

改造后
AppDelegate
  ├── UsageMonitoringCoordinator     （不变）
  ├── TokenStatsCoordinator          （新增，低频、只扫焦点 Agent）
  ├── 本地 Session readers           （不变）
  └── DetailsPanel.render
        ├── quotaGroup | metadataGroup | tokenStatsGroup   （同一主体槽，互斥）
        └── pageDots（两颗，两页共用）
```

`DetailsContentResolver` 继续只决定 `DetailsPanelBody`（`.usage` / `.session`）。翻页是 `DetailsPanel` 的瞬时 UI 状态，不进 ViewModel，不进磁盘。

## 模块与文件边界

新增：

```text
src/macos/Sources/AgentHaloCore/TokenStats/
├── TokenStatsModels.swift
├── DailyTokenAccumulator.swift
├── JSONLScanning.swift
├── IncrementalJSONLScanner.swift
├── JSONLScanCacheStore.swift          # 解析缓存的 manifest / record / writer
├── TokenStatsSnapshotStore.swift      # token-stats-v1.json
├── TokenStatsCoordinator.swift
├── CodexTokenLogScanner.swift
├── ClaudeTokenLogScanner.swift
├── GrokTokenLogScanner.swift
└── PiTokenLogScanner.swift
```

解析缓存不是可选项：冷启动可能面对数千个 JSONL，只靠内存会让每次启动都全量重读。`IncrementalJSONLScanner` 必须带版本化磁盘缓存（path+size+mtime）。Grok 单文件追加日志可以不走泛型扫描器，但仍要能按 mtime/size 跳过未变化文件。

修改：

- `AgentHaloMac/DetailsPanel.swift`：主体槽增加 tokens 页与点指示器；高度契约不变。
- `AgentHaloMac/AppDelegate.swift`：启动加载、焦点变化、打开详情时 `ensureFresh`；渲染传入 `TokenStatsSnapshot?`。
- `AgentHaloCoreChecks/`：扫描、日键、去重、取消、缓存命中。
- `AgentHaloMac/HaloInteractionChecks.swift`：278×172、翻页、切 Agent 清页、空态。
- `src/shared/locales/en.json`、`zh.json` 及 macOS 副本。

不修改：`UsageModels.swift` / `UsageSnapshot` / Windows 运行时 / `agent-halo.v2.json` 的动画合同。窗口天数与日键规则写在 Swift 常量里即可；若要进共享 spec，只允许两个数字：`tokenStatsPreviousDays = 30`、`tokenStatsWeekColumns = 5`。

## 领域模型

```swift
public struct TokenDayTotals: Equatable, Sendable {
    public var date: String          // 本地日历 yyyy-MM-dd
    public var totalTokens: Int64
}

public struct TokenStatsSnapshot: Equatable, Sendable {
    public var agent: AgentKind
    public var days: [TokenDayTotals] // 窗口内有用量的日，无序或按日皆可
    public var scannedAt: Date
}

public enum TokenStatsStatus: Equatable, Sendable {
    case ready(TokenStatsSnapshot)      // 窗口内至少有一天 totalTokens > 0
    case empty                          // 没有日志，或日志在窗口内无用量
    case scanning                       // 该 agent 尚无成功快照，扫描进行中
}

public actor TokenStatsCoordinator {
    /// 立即返回磁盘/内存里的状态，不开始扫描。无缓存则为 `empty`（不是 `scanning`）。
    public func prepare(_ agent: AgentKind) async -> TokenStatsStatus
    /// 缓存对「本进程内成功扫描」未满 5 分钟则原样返回；否则开扫。
    /// 磁盘加载的快照可以立刻 `ready`/`empty` 展示，但不算 fresh，首次 `ensureFresh` 必须扫。
    public func ensureFresh(_ agent: AgentKind) async -> TokenStatsStatus
    public func state(for agent: AgentKind) -> TokenStatsStatus
    public func cancelAll()
}
```

派生量只在展示层算，不进快照：

| 派生 | 规则 |
| --- | --- |
| `todayTokens` | `days` 中日键 == 今天；没有则为 `nil` |
| `last31DaysTokens` | 窗口内 `totalTokens` 之和；全 0 则为 `nil` |
| 热力格子 | 见下文；窗口外或无用量为空心 |

`TokenDayTotals` 只保留总量。input / output / cache / byModel 本期不建模。

扫描结果缓存按 `AgentKind` 隔离，必须落盘：`~/.agent-halo/cache/token-stats-v1.json`（schema 版本、每个 agent 一份 `{days, scannedAt}`）。只写日合计，不写路径、行内容、Token / API Key。权限 `0600`。`scannedAt` 超过 30 天的条目启动时丢掉。

解析缓存：`~/.agent-halo/cache/log-scan/<namespace>-<fingerprint>/`，版本化 plist，不得使用 OpenUsage 的 Application Support 目录。

## 统计窗口与日键

- `previousDays = 30`：今天 + 往前 30 个本地日历日，共 31 天。
- `sinceDate` = 窗口最早那天的 `startOfDay`。禁止 `now - 30*86400`。
- `dayKey` = `yyyy-MM-dd`，`Calendar` 可注入，生产用 `.current`。
- 热力画 **5 个周列 × 7 行**。周列对齐注入的 `Calendar`（生产用 `.current`）的 `firstWeekday`。今天所在周是最右列。
- 网格里三类空心，都不着色、不写 `0 tokens`：
  1. 早于 31 日窗口
  2. **晚于今天**（本周尚未到来的格子）
  3. 窗口内但 `totalTokens == 0` / 缺日
- 时区：事件时间戳转本地日。日志带偏移则尊重偏移。

## 各 Agent 日志

| 焦点 | 根 | 计入的事件 | 明确排除 |
| --- | --- | --- | --- |
| Codex | `$CODEX_HOME`（逗号分隔）否则 `~/.codex`；`sessions/` 与 `archived_sessions/`，同相对路径以 `sessions/` 为准；两者都没有则扫 home | `token_count` 的 `last_token_usage`，否则对 `total_token_usage` 做差；`total` 优先日志自报 | 子会话回放、累计快照重放、跨文件相同 Event、Pi 日志 |
| Claude Code | `$CLAUDE_CONFIG_DIR` 或 `~/.config/claude` + `~/.claude` 下含 `projects/` 的根；只扫 `projects/**/*.jsonl` | `message.usage` 且同时有数值 `input_tokens` / `output_tokens`；`total = input + cacheWrite5m + cacheWrite1h + cacheRead + output` | sidechain 重放（见去重）、普通 iteration 再计、Cowork 目录（本期不做）、Pi 日志 |
| Grok | `$GROK_HOME/logs/unified.jsonl` 否则 `~/.grok/logs/unified.jsonl` | `msg == "shell.turn.inference_done"`；`total = prompt + completion + reasoning`；`cached_prompt_tokens` 是 prompt 子集，不得再加 | `updates.jsonl` / `signals.json` 的上下文占用、`totalTokens` 窗口字段 |
| Pi | `$PI_CODING_AGENT_SESSION_DIR` 否则 `~/.pi/agent/sessions/**/*.jsonl` | assistant `usage`；优先 `usage.totalTokens`，否则分桶求和 | 把这些行并进 Claude / Codex 卡片 |

跟随 symlink。单个文件读失败：跳过该文件，不写解析缓存，其余文件继续计入。根目录不存在 → `empty`。根目录存在但枚举/读全部失败 → 失败（保留该 agent 上一份成功快照；没有则 `empty`）。

### Codex 去重（必须按 OpenUsage 测试语义）

1. `total_token_usage` 相对上一行完全不变 → 丢弃，即使带 `last_token_usage`。
2. 子会话（`forked_from_id` / `parent_thread_id` 非 null、`thread_source == "subagent"`、`source.subagent` 非 null；JSON `null` 当没有）在首条 live `task_started`（`started_at >= 子会话创建时间`）之前的 `token_count` 只用来打 delta baseline，不发出事件。禁止用「与 spawn 同一秒」去滤。
3. 聚合时 `(timestamp, model, input, cached, output, reasoning, total)` 相同的跨文件事件只计一次。
4. `cached = min(cached, input)`。计入 `total` 用日志 `total_tokens`，否则 `input + output + reasoning`。

### Claude 去重

1. 主键 `(message.id, requestId)`；第二索引仅 `message.id` 抓 sidechain 换 requestId 重放。
2. 冲突保留：非 sidechain > token 总数更大 > 带 `speed`。
3. 没有 `message.id` 的行全留。
4. `usage.iterations` 里只有 `advisor_message` 另计；普通 iteration 已在父 usage 中。
5. `speed` 若存在且不是 `fast` / `standard` → 整行丢。
6. 含 Claude 从不会写成 `null` 的字段（与 OpenUsage `unsupportedNullableFields` 对齐）→ 丢。
7. 有 `costUSD` 只忽略该字段，token 仍按分桶加。

### Grok

1. 不解析、不保留模型名。有 `prompt_tokens`（或等价字段）的 `inference_done` 就计入。
2. 用量行必须 `timestamp >= since`。

### Pi

1. 按消息 `id` keep-first。
2. 只在焦点为 Pi 时扫描；扫描结果不得写入 Claude / Codex 快照。

## Coordinator

`TokenStatsCoordinator` 为 `actor`，调度对齐额度协调器，但不共享状态：

- 同 `AgentKind` 同时最多一个扫描。
- 只扫当前焦点 Agent。
- 打开详情、切换 Agent 时 `ensureFresh`；本进程内同一 agent 的成功快照未满 5 分钟则不重扫。
- 周期 5 分钟，不挂高频 `tick()`。
- 旧 Agent 的异步结果只能写自己的状态。
- 取消：不发布新状态。调用方继续看到取消前的 `state(for:)`。禁止把取消映射成 `empty`（那会被当成「今天没用量」）。
- 失败：保留该 agent 上一份成功快照（`ready` 或权威 `empty`）；从未成功过则保持 `empty`。不显示额度那种黄色三角。
- `settings.paused == true`：不新开扫描；已在飞的扫描可跑完但结果仍只写自己的 agent。面板仍可展示上一份快照。
- 应用退出 `cancelAll()`。

`scanning` 只在「该 agent 从未有过成功结果、扫描尚未完成」时出现。有磁盘/内存快照时，扫描期间继续展示旧快照。首次进入 tokens 页若是 `scanning`：热力全空心，摘要隐藏。不得转圈、不得骨架屏闪光。

## 详情面板

### 外框（硬约束）

| 项 | 规格 |
| --- | --- |
| 宽 | 278pt，禁止撑宽 |
| 高 | 拟合 172pt；默认页 ↔ tokens 页、OAuth ↔ API Key、Offline ↔ Online **全部同高** |
| 圆角 / 材质 / 边框 / 顶栏 / 状态大标题 | 不改 |
| 主体槽 | quota 仍 70pt（两行 × 33pt + spacing 4）；session 仍 68pt + 7pt equalizer。**点指示器不进这个槽。** |
| 点指示器位置 | 画在 stack **底边 inset** 里，两页同一位置。为保持 172：`edgeInsets.top` 从 14 收到 6，`edgeInsets.bottom` 从 4 收到 12。净值不变。禁止叠在 Weekly 条或会话卡脚行上。 |

验收金标准沿用 2026-08-05：改前改后同一 fixture 高度仍为 **172** 且为偶像素（`evenPanelHeight`）；切页不得改 `frame.width`。顶栏、额度行 33pt、会话卡 68pt 的数字不得为了点指示器再改。

### 点指示器

- 两颗点，水平居中，落在 12pt 底边 inset 内。
- 直径 4pt，间距 8pt，颜色：当前页 ≈ 墨色 45% 不透明；另一页 ≈ 12%。
- 无文案、无「用量/额度」tooltip。VoiceOver 用 `tokens.page.show_stats` / `tokens.page.show_default`。
- 命中：点本身 + 底边 inset 那条水平带（约 12pt 高）。不得把 70pt 额度/会话卡做成热区。
- 左点 = 默认页，右点 = tokens 页。
- 切换无高度动画、无淡入；先藏当前主体再显示目标。
- 切 Agent：立刻回到默认页，并清空上一 Agent 的热力/摘要。
- 面板因 `onMouseExited` 隐藏时重置为默认页。

### tokens 页结构（自上而下，总高吃进主体槽）

```text
Today 89.1M          30d 1.1B     ← 一行，11–12pt（在 70pt 槽内）
                         5×7 格     ← 水平居中（在 70pt 槽内）
──────────────────────────────────
              ○      ●             ← 12pt 底边 inset，不在 70pt 内
```

70pt 槽预算：摘要 14 + 间隙 4 + 热力 47 = 65，余 5pt 容差。热力用 **5pt 格 + 2pt 间隙**：`7×(5+2)-2 = 47`。禁止用 6pt 格（会变成 54，加上摘要就超过 70）。自检仍超高则先减间隙到 1.5pt，**禁止**加高面板。

**摘要行**

- 左：`tokens.summary.today` + 紧凑数字；右：`tokens.summary.period` + 紧凑数字。
- `todayTokens == nil` 时左侧整段隐藏，右侧仍可显示。
- `last31DaysTokens == nil` 时右侧隐藏。
- 两侧都 `nil`：整行隐藏（热力仍画全空心）。禁止写 `0`、`--`、`$0.00`。
- 紧凑格式扩展现有 `compactTokenCount`：

  | 范围 | 格式 |
  | --- | --- |
  | `< 1000` | 整数 |
  | `< 1_000_000` | `12k` / `1.2k` |
  | `< 1_000_000_000` | `89.1M` / `1M` |
  | 更大 | `1.1B` / `2B` |

  小数一位，能整除则不写小数；locale 用 `en_US_POSIX` 的小数点，与现网 `k` 一致。`< 1_000_000` 的现网行为保持不变。会话卡上 **≥ 1M** 的当前轮数字会从 `1500k` 变成 `1.5M`，这是可接受的顺带变化，须加一条自检。

**热力**

- 5 列（旧→新从左到右）× 7 行（`firstWeekday` 在上）。
- 不画周一/周日文字、不画月份。
- 单元格 **5pt**，间隙 2pt（见上节预算）。悬停命中为格+间隙（7pt），不要按 5pt 严格点中。
- 热力是**一个**可访问分组，不要生成 35 个 VoiceOver 格子。
- 空心 / 实心见「统计窗口」。填充：窗口内且 `date <= today` 且 `totalTokens > 0`。
- 浓度相对**本窗口内最大日用量**分 4 档（加空心共 5 态）。最大为 0 则全空心。

  | 档 | 相对 `max` | 填充（浅色面板） |
  | --- | --- | --- |
  | 0 | 0 或窗外 | `rgba(111,132,148,0.10)` 空心方 |
  | 1 | `(0, 0.25]` | `#F3E3A4` |
  | 2 | `(0.25, 0.50]` | `#E4B85A` |
  | 3 | `(0.50, 0.75]` | `#D47A32` |
  | 4 | `(0.75, 1]` | `#C45A1C` |

- 不用 Halo 状态色。深色桌面上面板仍是浅 popover，热力按上表，不必做暗色变体。
- 悬停格子：原生 tooltip。窗口内有用量：`tokens.cell.tooltip` = `{0} · {1} tokens`，`{0}` 为 `tokens.cell.date`（**禁止**复用 `date.other_format`，中文那项带「刷新」）。空心格无 tooltip，不写 `0 tokens`。
- 格子不可点。单击格子不切日、不弹层。

### 与默认页的关系

| 模式 | 默认页 | tokens 页数据 |
| --- | --- | --- |
| OAuth | 5-Hour / Weekly | 该焦点 Agent 的原生日志 |
| API Key | 会话卡 / empty 矩形 | 同上 |
| OFFLINE | 同上（会话卡 empty；额度仍可显示旧窗口） | 仍可显示历史合计；扫描不依赖进程 live |
| PAUSED | 现有暂停文案 | 仍可显示上一份快照；暂停期间不新开扫描 |

API Key 会话卡上的 ↑in · ↓out 仍是**当前会话当前轮**。tokens 页是**跨会话日历合计**。两者同时存在于不同页，文案不得互相回退。

Pi 焦点：默认页按现网（无 OAuth 额度则走会话卡）。tokens 页扫 Pi 日志。

## 隐私与日志

- 只读本机日志。不上传会话、不把日志发到价目或 Usage API。
- 诊断只允许：agent、文件数、缓存命中/未命中、读失败次数、扫描耗时。禁止行内容、路径里的项目名可保留目录根类型（`codex-home` / `claude-projects`），不要打完整用户路径。
- 磁盘快照与解析缓存权限 `0600`。

## 本地化

| key | en | zh |
| --- | --- | --- |
| `tokens.summary.today` | `Today` | `今日` |
| `tokens.summary.period` | `30d` | `30天` |
| `tokens.cell.date` | `MMM d` | `M月d日` |
| `tokens.cell.tooltip` | `{0} · {1} tokens` | `{0} · {1} tokens` |
| `tokens.page.show_stats` | `Show token stats` | `显示 Token 统计` |
| `tokens.page.show_default` | `Show status details` | `显示状态详情` |

点指示器视觉上无文字；后两个 key 仅供 VoiceOver（默认页可能是额度或会话卡，不要写死 “usage”）。

## 测试

### AgentHaloCoreChecks

- 日键用注入日历；夏令时跨日不裂。
- `sinceDate` 含最早那天 00:00 的事件，排除再早 1 秒。
- Codex：`last_token_usage` 优先；累计不变丢弃；子会话回放不计；`forked_from_id: null` 不是子会话；`sessions/` 压过 archive；symlink home；跨文件 EventKey 去重。
- Claude：`(message.id, requestId)`；sidechain 让位父；advisor 另计；非法 `speed` 丢；null 字段丢。
- Grok：只认 `inference_done`；cache 不重复加；读 `GROK_HOME`；不读 `updates.jsonl`。
- Pi：只写入 `agent == .pi`；id 去重。
- 取消 ≠ empty。
- 解析缓存：path+size+mtime 相同不重读；mtime 变则重读。
- 切 agent 的快照不得互相覆盖。

### HaloInteractionChecks

- 任意页 `frame.width == 278` 且 `frame.height == 172`。
- 默认打开是额度或会话卡；点右点到 tokens；点左点回去。
- 切 Agent 回到默认页且热力数字更换。
- 关面板再开回到默认页。
- 两侧摘要为 nil 时不出现 `0` / `--`。
- 热力 5×7；窗外、未来日、零用量格子空心。
- 点条带点击不改变 Halo 状态色；点不得挡住 Weekly 条或会话卡脚行。
- 长数字不撑宽。
- `compactTokenCount(1_500_000) == "1.5M"`；`compactTokenCount(38_000)` 仍为现网 `k` 形式。
- 顶 inset / 底 inset 对调后拟合高仍为偶像素 172。

### 验证命令

```bash
cd src/macos
swift run AgentHaloCoreChecks
swift run AgentHaloMac --self-check
swift build
cd ../..
bash scripts/build-macos.sh
bash scripts/run-macos.sh --verify
```

用户验收对象是 `outputs/AgentHalo-macOS/AgentHalo.app`。

## 实施顺序

1. 模型、日键、累加器、取消语义的失败检查。
2. 增量 JSONL 扫描器 + 磁盘解析缓存。
3. Codex / Claude / Grok / Pi 扫描器（各带 OpenUsage 对齐夹具）。
4. Coordinator：焦点、5 分钟、失败保留。
5. 紧凑数字 M/B；tokens 页 + 点指示器；高度 172 自检。
6. AppDelegate 接入；切 Agent / 开关面板。
7. 本地化与打包验证。

每步先失败检查，再最小实现。

## 完成标准

- 焦点 Codex / Claude / Grok / Pi 各自只反映自己的原生日志。
- 详情外框 278×172 在所有页与模式下成立。
- tokens 页为摘要 + 5×7 黄橙热力；Yesterday 只在格子 tooltip。
- 无美元、无价目网络、无 Pi 折算、无全年图。
- 扫描成败不改 Halo 色；额度 API 成败不清 tokens 快照。
- CoreChecks、Mac 自检、已打包 App 验证通过。
