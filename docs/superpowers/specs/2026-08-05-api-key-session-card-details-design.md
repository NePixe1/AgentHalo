# API Key 模式会话摘要卡（方案 B）详情面板设计

## 文档状态

- 日期：2026-08-05
- 状态：已实现，待发布验证（macOS + Windows 方案 B；Windows 含 locale self-check 断言）
- 实现范围：AgentHalo **macOS + Windows** 详情面板（API Key / 非 OAuth 路径）
- 视觉预览：[`docs/API_KEY_PANEL_MOCKUPS.html`](../../API_KEY_PANEL_MOCKUPS.html)（方案 B）
- 实施计划：[API Key 会话摘要卡 Implementation Plan](../plans/2026-08-05-api-key-session-card-details-implementation.md)
- 相关产品说明：[`docs/PRODUCT.md`](../../PRODUCT.md)（Focused Agent：OAuth 显示 usage，API key 显示 session details）
- 相关既有设计：
  - [OpenUsage 风格监控 macOS](./2026-07-10-openusage-monitoring-macos-design.md)（access mode 分流）
  - [macOS Claude 详情面板精简](./2026-07-15-macos-details-panel-session-title-design.md)（现有三行 metadata）
  - [macOS Codex 第三方详情数据](./2026-07-21-macos-codex-session-details-parity-design.md)（标题 / token 数据源）

## 背景

详情面板在 `accessMode != oauth` 时走 session body（API key、自定义 / 第三方端点、以及未识别为 OAuth 的路径）。当前实现为三行键值表：

```text
Session title  ···
Model          ···
Input/Output   ···
```

Offline（`state == idle` 且 `label == OFFLINE`）时三行强制填 `--`，造成：

1. **空状态噪音**：无信息却占满三行 + 两条分隔线，观感像故障而非待命。
2. **模式身份缺失**：用户看不出当前是 API Key 路径，与 OAuth 额度条视觉落差大。
3. **高度跳动**：有会话与无会话内容高度差大；与 OAuth 的固定 quota 区对比也不稳定。

经 mock 对比（A 空状态收敛 / B 会话摘要卡 / C 本地指标 / D 统一骨架 / E 柔和文案），选定 **方案 B：会话摘要卡**，并补齐 Offline / working 外框与内层矩形同高。

## 目标

1. 为 API Key 路径建立独立视觉身份：**mode chip + 会话摘要卡**，而不是「OAuth 去掉进度条后的残表」。
2. Offline 用 **一句 empty 文案** 替代三行 `--`。
3. Online（有 session 数据）将 **标题 + 模型 + tokens** 合并为一张卡。
4. Offline 与 Working（及 Thinking / Done / Attention 等非 offline 状态）**详情面板总高度一致**，且 **内层 body 矩形同高**，状态切换时不跳变。
5. macOS / Windows 行为与布局语义对齐；数据继续来自现有 `SessionDetailsSnapshot`，不新增网络请求。
6. **详情面板外框尺寸相对现网不变**：改 body 内容与 chip，不放大 / 缩小整块面板（macOS 宽 278、拟合高 172）。

## 非目标

- 不改变 OAuth 路径的 usage / quota 渲染。
- **不改变详情面板的既定外框尺寸**（宽度、拟合高度与 OAuth/session 同高关系）。
- 不引入本地消费估算、端点 host 展示、会话时长、历史图表（方案 C 内容本期不做）。
- 不把 Offline 标题改为「离线」等情绪化文案方案 E（状态大标题仍用现有 `aggregate.label`，如 `OFFLINE` / `WORKING`）。
- 不伪造 quota 进度条。
- 不读取或上传会话聊天内容；仍只展示本地已有元数据（标题、模型、token、context）。
- 不改变 agent switch、context pill 的现有数据语义与 hold 策略（OFFLINE 立即清空 context；STANDBY soft-hold 保留）。

## 已确认决策

| # | 决策 |
|---|------|
| 1 | 采用方案 B 会话摘要卡布局，仅作用于 **非 OAuth**（`DetailsPanelBody.session`）路径。 |
| 2 | 顶栏右侧增加 **API Key mode chip**；OAuth 路径不显示该 chip。 |
| 3 | Offline：隐藏三行 metadata，在 body 槽位显示 empty 矩形 + 文案。 |
| 4 | 非 Offline：body 槽位显示 session card（标题一行、脚行 model chip + in/out tokens）。 |
| 5 | 面板与 body 内矩形 **固定同高**：以「有 session card 的 working 态」为基准，offline empty 对齐该高度。 |
| 6 | 标题单行省略；完整标题仍可通过 tooltip（或等效悬停）展示。 |
| 7 | 字段缺失时：标题 / 模型显示占位（`--` 或本地化 empty）；tokens 无数据时显示 `--`，不隐藏整张卡（只要非 offline）。 |
| 8 | STANDBY / 在线但无有效 session 字段：仍走 session body 槽位；有任意可展示字段则填卡；**字段全空 soft empty 用 `session.empty.api_key`（无会话 / No session）**；Offline 同矩形、**同一文案**（`○ 无会话` / `○ No session`），禁止全 `--` 卡。 |
| 9 | 双端（macOS + Windows）同一规格；允许平台控件差异，禁止信息架构差异。 |
| 10 | 视觉以 mock 为准；实现数值可像素对齐平台习惯，但结构与层次不得偏离。 |
| 11 | **面板外框尺寸锁定现网**：宽度与拟合高度不得因方案 B 变大或变小；OAuth ↔ session 切换后高度关系保持现有契约（macOS 均为 **172**）。 |

## 信息架构

### 整体骨架（API Key）

```text
┌─────────────────────────────────────────────┐
│  [Agent switch]          [ctx%] [API Key]   │  ← top row
│  STATUS_LABEL                               │  ← 现有 titleField / headline
│  localized detail                           │  ← 现有 detailField
│  ┌───────────────────────────────────────┐  │
│  │  body slot（固定高度）                  │  │
│  │  Offline → empty 矩形                  │  │
│  │  else    → session card                │  │
│  └───────────────────────────────────────┘  │
└─────────────────────────────────────────────┘
```

### OAuth（对照，本期不改）

```text
top: [Agent switch]  [ctx%]     ← 无 API Key chip
status + detail
quota rows（5h / weekly 等，按 provider）
```

### Top row 元素优先级（从右到左占位）

1. `API Key` mode chip（仅 session / 非 OAuth body）
2. `contextPill`（有可展示百分比时显示；offline 隐藏，逻辑不变）
3. 左侧 `agentToggle` 不变

窄宽度下：mode chip 与 context pill 可紧挨排列（mock：`gap ≈ 6pt`），不得换行到第二行。

## 视觉规格

参考 mock：`docs/API_KEY_PANEL_MOCKUPS.html` 中 `.panel.scheme-b`。

### 面板（外框硬约束 — 不得改变现网尺寸）

| 项 | 规格 |
|----|------|
| 宽度 | **锁定现网**：macOS `panelWidth = 278`；Windows 与现网一致。**禁止**为 chip / card 加宽面板。 |
| 高度（macOS） | **锁定现网拟合高度 `172`**（见 `testDetailsPanelResizesHeightWithoutAnimation`）。OAuth usage 与 API Key session 切换后 **仍同为 172**；API Key Offline ↔ Online 也 **同为 172**。 |
| 高度（Windows） | 保持现有 session / quota 区高度语义（如 `dataLayer` 等既有常量）；改 body 内容后 **总高度不得明显膨胀**；与 macOS 同信息架构，外框观感不变。 |
| 圆角 / 材质 / 边框 | 沿用现有 popover 材质与边框，不新开皮肤 |
| 内边距 | 与现有 stack 边距一致（约 top 14 / horizontal 17 / bottom 4–12）；**禁止**为腾出 card 而加大 edgeInsets 导致总高变化 |
| Mock 说明 | HTML mock 外框 `min-height: 192` **仅作结构示意**，**不是**产品面板目标高度。实现与验收以现网 **278×172（macOS）** 及 Windows 等价尺寸为准。 |

**尺寸验收金标准（实现必须满足）：**

1. 改前 / 改后：同一 fixture 下 OAuth usage 面板高度仍为 **172**（macOS）。
2. 改前 / 改后：API Key session 面板高度仍为 **172**，且与 usage **相等**（现网契约：`switching bodies should keep the same panel height`）。
3. API Key Offline empty 与 Working card：`frame.height` 相等，且等于 **172**。
4. 顶栏加入 mode chip **不得**抬高 `topRow`（chip 落在既有 24pt 顶栏内，或与 context pill 同行不增加 arranged 高度）。

### Mode chip（`API Key`）

| 项 | 规格 |
|----|------|
| 文案 | i18n key，中文 / 英文见下文 |
| 高度 | ≤ 顶栏高度（macOS top row ≈ 24pt）；**不得**单独增加面板总高 |
| 样式 | 小 pill：浅青底 + 描边 + 左侧 6pt 圆点；字重偏粗、字号约 10.5–11 |
| 位置 | top row 最右侧（与现有 context pill 同一行） |
| 可见性 | `body == .session`（非 OAuth）时显示；OAuth 隐藏 |

### Session card（非 offline）

| 项 | 规格 |
|----|------|
| 容器 | 圆角约 12；浅底 + 轻边框；与 empty 矩形 **同宽同高** |
| **固定高度 `H_body`** | 默认目标 **70–72pt**（与现网三行 metadata ≈ 3×24 + 分隔线 同量级），**必须**使整板拟合高仍为 **172**。若测得超高，优先缩小卡内 padding / 字号，**禁止**放宽面板总高。mock 的 `72` 为内容区参考，受外框 172 约束。 |
| 标题 | 单行、尾省略；font 约 13 medium/bold；颜色接近主文案 |
| 脚行 | 左：model chip（小 pill）；右：`↑ in  ·  ↓ out`（沿用现有 tokens 配色：输入偏蓝灰、输出偏绿灰） |
| 垂直 | 卡内内容垂直居中 |
| 数据 | `sessionTitle`、`modelName`、`inputTokens` / `outputTokens`（既有 snapshot） |

### Empty 矩形（offline）

| 项 | 规格 |
|----|------|
| 尺寸 | 与 session card **同宽同高** |
| 样式 | 虚线边框 + 浅底（可略淡于 session card） |
| 文案 | 单行居中；前缀可用轻量圆点 `○`（可选，双端一致即可） |
| 文案内容 | Offline 与 STANDBY 全空一致：`○ ` + `session.empty.api_key`（无会话 / No session）；不展示 `--` 三行表 |

### 状态大标题 / 副文案

- 继续使用现有 `updateStatus` / aggregate 映射：`OFFLINE`、`WORKING`、`THINKING`、`DONE`、`ATTENTION` 等及本地化 detail。
- 本期 **不** 改为方案 E 的「离线 / 执行中」软文案。

## 状态矩阵

| 条件 | mode chip | context pill | body |
|------|-----------|--------------|------|
| API Key + OFFLINE | 显示 | 隐藏 | soft empty（虚线框 + `○ 无会话` / `○ No session`） |
| API Key + STANDBY / 活跃态 + 有 session 字段 | 显示 | 按现有规则 | session card |
| API Key + 活跃/STANDBY + 字段全空 | 显示 | 按现有规则 | soft empty（`session.empty.api_key` = 无会话 / No session） |
| OAuth（任意状态） | 隐藏 | 按现有规则 | usage / quota（不变） |

**Offline 判定**（与现网一致）：

```text
isOffline = (aggregate.state == .idle && aggregate.label == "OFFLINE")
```

Offline 时 session 数据清空展示（现有 `SessionDetailsSnapshot()` 或等价空值），不展示上一会话残留标题。

## 数据与解析

### 继续使用

- `DetailsContentResolver.resolve`：`accessMode != .oauth` → `body: .session(...)`。
- `SessionDetailsSnapshot`：`sessionTitle`、`modelName`、`inputTokens`、`outputTokens`。
- Context：`contextUsedPercent` + 现有 hold 逻辑。
- Token 紧凑格式：沿用 `compactTokenCount` / 双端等价实现与 `↑` / `↓` 着色。

### 可选小扩展（若实现需要）

若 ViewModel 需要显式区分渲染模式，可在 `DetailsPanelViewModel` 增加只读派生，例如：

```text
var showsAPIKeyChrome: Bool { /* body is session */ }
```

**不** 新增第三种 `DetailsPanelBody` case；empty 与 card 是 session body 的两种 **视图状态**，由 `isOffline`（及字段是否展示）决定。

### 不改

- `AccessModeResolver` 优先级（OAuth > needs sign-in > API key）。
- Provider usage HTTP、缓存、刷新周期。
- Claude / Codex / Grok 会话标题与 token 的采集逻辑（沿用既有监控与 parity 设计）。

## 布局与高度稳定

### 结构要求

```text
VStack
  topRow              ← 高度与现网一致（含 mode chip 不增高）
  statusTitle
  statusDetail
  bodySlot            ← 固定高度 H_body（≈ 现网 metadata 区高度）
    emptyView  XOR  sessionCardView
```

- `bodySlot` 高度常量 `H_body`（双端同语义；在「总高 = 现网 172」约束下锁定，不可随意改大）。
- Offline / 非 Offline 切换时：
  - `H_body` 不变；
  - **面板总高度不变且等于现网目标高度**（macOS：**172**）。
- 从 OAuth ↔ API Key 切换时：现网契约为 **高度相同（均为 172）** + `resizeToFitContent` **顶边不动**。方案 B **必须延续**该契约，**不允许**「换 body 后总高变了再更新测试期望」的做法（除非证明现网本身已变且与本功能无关）。

### 禁止

- Offline 仍渲染三行 metadata 再设 `--`。
- 用透明占位三行「伪装」同高（应使用统一 body 槽位组件）。
- session card 多行标题导致 working 高于 offline（标题必须单行约束）。
- **为放得下 card / chip 而增大 panel 宽度、stack 边距或 body 高度，导致外框相对现网变大。**
- **修改 self-check 中的 `172` 期望以迁就膨胀后的布局**（应先压回布局）。

## 文案 / i18n

新增（建议 key；中英写入 `src/shared/locales` 并同步平台 locales）：

| Key | zh | en |
|-----|----|----|
| `access.mode.api_key` | API Key | API Key |
| `session.empty.api_key` | 无会话 | No session |

说明：

- mode chip 使用 `access.mode.api_key`。
- STANDBY / 字段全空：`session.empty.api_key`（前导 `○` 由 UI 层拼接）；Offline empty **不写文案**。
- 现有 `metadata.*`、`status.*`、`context.*` 保持；三行表文案在 API Key 路径不再作为主 UI 展示（实现可删除 session 三行视图或仅保留测试/调试路径，以最小 diff 为准）。

## 平台落点

### macOS

- `DetailsPanel.swift`：用 session card / empty 替换（或重写）`metadataGroup` 的三行 + 分隔线结构；top row 增加 mode chip。
- 高度：`resizeToFitContent` 在 API Key 路径应对 body 固定高度，使 offline/online 拟合高度一致。
- 交互自检：`HaloInteractionChecks` / 现有 details 测试枚举若依赖 `sessionTitle` / `model` / `tokens` 行 role，需改为 card / empty 语义。

### Windows

- `DetailsWindow.cs`：API key / 非 OAuth session 详情区改为同结构（switch + ctx + chip + status + body slot）。
- 与 macOS 同一状态矩阵与 i18n key。

### 共享

- `DetailsContentResolver` 可保持 body 枚举不变；若测试需断言 chrome，再补最小字段。
- `src/shared/locales/{en,zh}.json` 为文案源；平台 locales 同步生成或手改策略与现有 i18n 流程一致。

## 错误与边界

| 情况 | 行为 |
|------|------|
| Offline | empty 文案；无上一会话标题残留 |
| 标题缺失 | card 标题显示 `--`（或 `quota.no_data` 风格占位，双端统一一种） |
| 模型缺失 | model chip 显示 `--` |
| tokens 皆无 | `↑ --  ·  ↓ --` 或单侧 `--`，与现有 `formatTokenAttributedString` 行为对齐后收敛为一种 |
| 超长标题 | 单行省略 + tooltip 全文 |
| OAuth 失败 warning | 仍只出现在 usage body；不影响 session card 布局 |
| 焦点 agent 切换 | 立即按新 agent 的 access mode 重绘；高度按该 mode 规则计算 |

## 测试与验收

### 视觉 / 交互

1. API Key + Offline：无三行 `--`；有 mode chip；empty 矩形文案正确；无 context pill。
2. API Key + Working（有数据）：session card 显示标题、模型、tokens；context pill 在有值时出现；mode chip 仍在。
3. **同高 + 尺寸锁定**：同一 agent、API Key 下 Offline ↔ Working 面板高度一致（macOS 均为 **172**）；empty 与 session card 外接矩形高度一致（`H_body`）。
4. **相对现网不变**：OAuth usage 高度仍为 **172**；usage ↔ session 切换高度仍相等；宽度仍 **278**。
5. Thinking / Done / Attention：仅状态色与 detail 变化，body 结构与 Working 相同。
6. 切到 OAuth：mode chip 消失，quota 恢复；切回 API Key：card/empty 恢复；高度仍不跳变。
7. 标题 tooltip（或 Windows 等效）在截断时仍可看全文。

### 自动化

1. `DetailsContentResolver`：非 OAuth 仍为 `.session`；Offline 时空 snapshot。
2. 面板 / 窗口渲染测试（或 interaction checks）：
   - Offline 不暴露三行 metadata 值；
   - Online 暴露 card 标题 / model / tokens；
   - API Key chrome 可见性；
   - body 槽位高度常量 offline/online 相等；
   - **`testDetailsPanelResizesHeightWithoutAnimation` 中 usage / session 高度仍为 172 且相等**（不得改期望值迁就布局）。
3. 现有 OAuth usage、context hold、agent switch 测试不回归。
4. 构建：`swift run AgentHaloCoreChecks`（macOS）及 Windows 现有详情相关测试 / 编译。

### 人工对照

- 打开 `docs/API_KEY_PANEL_MOCKUPS.html` 方案 B 左右栏，与真机截图并排：层次、chip、empty/card 同高、tokens 着色一致。
- 对照改前截图：详情面板外框宽高观感一致（mock 192 仅示意结构，不以 mock 外框为准）。

## 实施建议顺序

1. 共享 i18n key +（如需）ViewModel 派生标志。
2. macOS `DetailsPanel` session body 重构（card + empty + mode chip + 固定 body 高）。
3. 更新 macOS checks。
4. Windows `DetailsWindow` 对等实现。
5. 双端人工对照 mock 与高度验收。

## 明确不做的后续项（可另开设计）

- 方案 C：context 大条、会话时长、端点 host。
- 方案 D：OAuth / API Key 完全统一 empty 组件与固定总骨架高度跨 mode。
- 方案 E：Offline 软文案与装饰空环。
- Pay-as-you-go / 费用展示。

## 附录：与现状 diff 摘要

| 区域 | 现状 | 方案 B |
|------|------|--------|
| API Key Offline body | 三行 `--` | empty 矩形 + 一句文案 |
| API Key Online body | 三行键值表 | session card |
| Mode 指示 | 无 | `API Key` chip |
| Offline/Online 高度 | 随内容变 | 同高（外框 + 内矩形） |
| 面板外框尺寸 | 宽 278 / 高 172（macOS） | **不变**（仍 278×172；usage 与 session 同高） |
| OAuth body | quota | 不变 |
| 数据源 | `SessionDetailsSnapshot` | 不变 |
