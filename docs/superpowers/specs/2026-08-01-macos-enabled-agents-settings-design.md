# macOS 启用 Agent 与设置窗口设计

## 文档状态

- 日期：2026-08-01
- 状态：设计已确认；待写实施计划
- 实现范围：**仅 macOS**。不改 Windows 代码、测试、文档或 UI。
- 产品原则：见 [PRODUCT.md](../../PRODUCT.md)
- 相关先例：
  - [i18n 本地化设计](./2026-06-27-i18n-localization-design.md)
  - [macOS Session Details 设计](./2026-06-21-macos-session-details-design.md)
  - [OpenUsage 风格监控 macOS 设计](./2026-07-10-openusage-monitoring-macos-design.md)
  - [macOS Grok Build 额度与最小生命周期设计](./2026-07-25-macos-grok-build-usage-lifecycle-design.md)

## 目标

1. 用户可选择**启用哪些 Agent**：启用 = 左上角切换条显示 + 后台监控/采集；未启用 = 不显示、不轮询。
2. 提供独立 **设置窗口**，从状态栏菜单与光环右键菜单的「设置…」进入。
3. 将偏好类选项集中到设置窗口：
   - 主页面显示（启用 Agent）
   - 光环大小、语言（外观）
   - 始终置顶、显示菜单栏图标、开机自动启动（通用）
   - 重置光环位置（恢复动作按钮）
   - 关于 / 版本号（页脚）
4. 默认行为与现网 macOS 一致：全部 Agent 启用、菜单栏图标显示、置顶默认不变，升级无感。

## 非目标

- 任何 Windows 改动或跨端 schema 对齐
- 新增 Agent 类型（Gemini、OpenCode、Claude Desktop 等）
- 用户自定义 Agent 显示顺序（拖拽排序）
- 将「暂停监控」「预览状态」「退出」迁入设置（仍为菜单临时/系统操作）
- 在设置中再放一份「监控对象 / focusedAgent」切换（详情条与菜单已覆盖）
- 禁用 Agent 时**卸载**已有 `~/.claude` / `~/.grok` hooks（v1 不删用户文件）
- 云同步、远程配置、账号体系
- 全局快捷键、通知/声音、用量刷新间隔、悬停延迟等未产品化能力
- 高级：打开数据目录、重装 hooks、诊断导出

## 已确认的架构决策

1. **平台**：只做 macOS。
2. **语义**：勾选 Agent = **启用 + 显示**，不是「仅控制 UI 可见性」。
3. **持久化新字段**：`enabledAgents: [AgentKind]` + `showMenuBarIcon: Bool`；`alwaysOnTop` / `haloSize` / `language` / 位置字段沿用现有路径；开机启动仍走 `StartupManager`。
4. **默认**：`enabledAgents = AgentKind.allCases`；`showMenuBarIcon = true`。
5. **至少 1 个 Agent**：不能清空；关掉当前 `focusedAgent` 时自动切到 `enabledAgents.first`。
6. **显示顺序**：v1 写入时始终按 `AgentKind.allCases` 过滤排序，不记录用户勾选先后。
7. **设置即时生效**，无「保存 / 取消」按钮。
8. **菜单栏图标关闭后**：托盘消失，仍可通过**光环右键菜单**打开设置与退出。
9. **托盘菜单与右键菜单共用**精简后的控制菜单；仅当 `showMenuBarIcon == true` 时存在 `NSStatusItem`。
10. **始终置顶**：设置与菜单**双入口**，状态双向一致。
11. **重置位置**：设置内按钮 + 菜单项并存，均调用现有 `escapeOffscreen` 等价逻辑。
12. **关于**：页脚只读版本字符串，不链到外部（v1 无需检查更新）。
13. **设置窗口**：可成为 key 的 `NSPanel`，层级高于光环；**不**为开设置改 `NSApp` 的 `.accessory` activation policy。
14. **禁用监控**：立刻停采、清空该 agent 快照；未启用期间不 repair / 写入该 agent 的用户配置。
15. **切换条宽度**：随 enabled 数量变化，不再写死 144pt / 三等分。

## 背景与问题

### 现状

- `AgentKind`：`codex` / `claudeCode` / `grok`。
- 焦点由 `HaloSettings.focusedAgent` 持久化；详情面板左上角 `AgentToggleView` **固定三等分**、宽度写死 144pt。
- 监控侧（`CodexActivityMonitor` / `ClaudeActivityMonitor` / `GrokActivityMonitor`）主要按 `focusedAgent` 决定轮询节奏；未 focus 时仍以 idle 间隔采集。
- 状态栏菜单与光环右键菜单共用 `makeControlMenu()`，内含：置顶、开机启动、暂停、光环尺寸滑块、监控对象、语言、逃离屏幕外、预览状态、退出。
- App 为 `NSApp.setActivationPolicy(.accessory)`；光环 / 详情在置顶时使用 `.floating`。
- 无独立设置窗口；用户无法声明「我只用 Codex」。

### 问题

| 问题 | 影响 |
|------|------|
| 切换条永远三个 | 单 Agent 用户噪音大 |
| 无法关闭不需要的 Agent 监控 | 多余 IO / 轮询；仍可能 repair hooks |
| 偏好设置散落在深层子菜单 | 语言、尺寸、开机启动、置顶难发现 |
| 菜单栏图标无法隐藏 | 菜单栏拥挤时无退路 |
| 无版本信息入口 | 反馈问题时不便对齐构建 |

## 数据模型与持久化

### `HaloSettings` 新增字段

```swift
public var enabledAgents: [AgentKind]
public var showMenuBarIcon: Bool
```

| 字段 | 含义 | 默认 | 缺失字段迁移 |
|------|------|------|----------------|
| `enabledAgents` | 已启用 Agent 的有序列表（显示顺序） | `AgentKind.allCases` | 同默认 |
| `showMenuBarIcon` | 是否显示菜单栏 `NSStatusItem` | `true` | 同默认 |

现有字段继续使用、**不改 schema 语义**：`focusedAgent`、`haloSize`、`language`、`alwaysOnTop`、`paused`、位置相关字段等。

开机启动**不**写入 `settings.json`，继续由 `StartupManager` / LaunchAgent 表示真实状态（与现网一致）。

### 规范化规则

加载或任意写路径之后，设置必须满足：

1. `enabledAgents` 去重，仅保留合法 `AgentKind`，顺序规范为 `allCases.filter { enabledSet.contains($0) }`。
2. 若规范化后为空（含空数组、全非法）→ 回退 `allCases`。
3. 若 `focusedAgent ∉ enabledAgents` → `focusedAgent = enabledAgents.first!`。
4. `showMenuBarIcon` 为 Bool，缺省 `true`。

### 辅助 API（建议）

放在 `HaloSettings` 上（或紧邻的纯函数，便于 CoreChecks 单测）：

- `isAgentEnabled(_ agent: AgentKind) -> Bool`
- `mutating func setAgent(_ agent: AgentKind, enabled: Bool)`  
  - 关闭最后一个已启用项：no-op  
  - 关闭当前 `focusedAgent`：将 `focusedAgent` 设为规范化后的 `enabledAgents.first`
- `normalized() -> HaloSettings`：应用上述全部规则（decode / save 前可调用）

`setFocusedAgent`（AppDelegate）对未启用 agent：**no-op**（不改 focus、不刷新 usage）。

### 兼容性

- 旧 macOS `settings.json` 无新字段 → 三 Agent 全开、菜单栏图标显示。
- 本设计**不**要求、也**不**实现与其他平台配置文件互通。

## 设置窗口

### 入口

- 状态栏菜单与光环右键菜单增加 **`menu.settings`**（「设置…」/「Settings…」）。
- 已打开则前置并成为 key；全局**至多一个**设置窗口实例。

### 窗口行为（accessory 约束）

应用保持 `.accessory`（无 Dock 图标）。设置窗必须满足：

| 项 | 约定 |
|----|------|
| 类型 | 可成为 key 的 `NSPanel`（`NSWindow.StyleMask` 含 `.titled` / `.closable`） |
| 层级 | **高于光环与详情面板**，避免被 `.floating` 光环挡住。建议 `haloLevel + 1`（置顶时约为 `NSWindow.Level.floating.rawValue + 1`） |
| activation | **禁止**为开设置把 app 改成 `.regular` |
| 位置 | 不记忆；每次打开相对主屏可见区域居中 |
| 关闭 | 红点、`Esc`、`⌘W` 均可关闭 |
| 尺寸 | 内容自适应，不可缩放 |

打开时用当前 `settings` + `StartupManager.isEnabled()` **刷新全部控件**（含置顶、尺寸、语言、启动项、菜单栏图标、启用胶囊），避免与菜单分叉。

### 布局（v1）

```text
┌─ 设置 ────────────────────────────────────┐
│  主页面显示                                │
│  选择要显示并启用的 Agent                   │
│  [● Codex] [● Claude Code] [○ Grok]       │
│                                           │
│  外观                                      │
│  光环大小                      112        │
│  ━━━━━●━━━━━━━━  (72…180)                 │
│  语言                                      │
│  ( 跟随系统  |  中文  |  English )          │
│                                           │
│  通用                                      │
│  始终置顶                          [toggle]│
│  显示菜单栏图标                    [toggle]│
│  开机自动启动                      [toggle]│
│  [ 重置光环位置 ]                          │
│                                           │
│  Agent Halo x.y.z                          │
└───────────────────────────────────────────┘
```

### 各区块行为

| 区块 | 行为 |
|------|------|
| 主页面显示 | 胶囊多选；选中 = 实心强调色 + 图标/标题；未选中 = 浅底。点击切换启用。只剩 1 个已选时不可点灭（忽略点击或视觉 dim）。即时写盘并通知 `AppDelegate`。 |
| 光环大小 | 滑块 + 数值；范围与现有菜单滑块一致（`HaloSettings.minimumHaloSize`…`maximumHaloSize`）。调用现有 `applyHaloSize`（clamp、面板 resize、防抖写盘、详情面板重定位）。 |
| 语言 | 三段：跟随系统 (`nil`) / `zh` / `en`。改后 `L10n.shared.setLanguage`、写 `settings.language`、刷新菜单与设置窗文案。 |
| 始终置顶 | Toggle ↔ `settings.alwaysOnTop` + `applyWindowLevels()` + 写盘；与菜单勾选同步。设置窗自身层级仍保持「高于光环」，不随该开关掉到光环下面。 |
| 显示菜单栏图标 | 见下文「菜单栏图标」。设置开着时关掉托盘，本窗仍可把开关再打开。 |
| 开机自动启动 | Toggle ↔ `StartupManager.setEnabled`；打开设置时读 `StartupManager.isEnabled()` 反映真实状态。 |
| 重置光环位置 | 按钮；调用与菜单「脱离卡死」相同的逻辑（主屏右上角 + 提交首选位置）。不关设置窗。 |
| 关于 | 页脚只读：`Agent Halo {version}`。版本优先 `Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")`，为空再用 `CFBundleVersion`；再空则省略号段。不可点击或仅可选中复制。 |

### 变更传播

```text
Settings UI 变更
  → 更新 HaloSettings（+ 规范化）或调用命令回调
  → SettingsStore.save（尺寸可走既有防抖）
  → AppDelegate 应用：
       · self.settings = normalized
       · 刷新 AgentToggleView 宽度与槽位
       · 重建控制菜单（若 status item 存在）
       · applyMenuBarIconVisibility()
       · applyWindowLevels()（置顶变更时；设置窗 level 仍高于光环）
       · 立刻清空刚禁用 agent 的 activity 快照
       · 若 focused 变化 → requestUsageRefresh
       · 刚重新启用的 agent → requestRefresh()
       · tick() 立即应用监控启停
```

`SettingsWindowController`（或等价类型）由 `AppDelegate` 注入回调，避免设置窗直接操作 monitor / status item。

约定（避免回调爆炸）：

- **状态类**：`onSettingsChanged: (HaloSettings) -> Void`（启用列表、置顶、菜单栏图标、语言、尺寸）。尺寸仍可在 AppDelegate 内走现有 `applyHaloSize`。
- **外部副作用命令**（不在 `HaloSettings` 内）：`onLaunchAtLoginChanged: (Bool) -> Void`、`onResetPosition: () -> Void`。

## 菜单精简

托盘与右键仍共用一份菜单构造函数。

### 从菜单移除（改由设置窗口）

- 开机自动启动  
- 光环大小滑块  
- 语言子菜单  

### 菜单保留（快捷 / 操作）

- **始终置顶**（与设置双入口）  
- 暂停监控  
- 监控对象（**仅列出 `enabledAgents`**；勾选表示当前 `focusedAgent`）  
- **逃离屏幕外 / 重置位置**（与设置按钮双入口）  
- 预览状态  
- **设置…**（新）  
- 退出  

建议顺序：置顶 → 暂停 → 监控对象 → 重置位置 → 预览 → 分隔线 → 设置… → 退出。

## 左上角 Agent 切换条

`AgentToggleView` 改为按 `enabledAgents` **动态渲染**。

**宽度**：`slotWidth × enabledAgents.count`。`slotWidth = 48`（现 144 / 3）。`DetailsPanel` 去掉写死的 `widthAnchor = 144`，改为随 `setEnabledAgents` 更新。

| 已启用数量 | 行为 |
|-----------|------|
| 1 | 单图标、宽 48；保持选中样式；点击不切换 |
| 2+ | 按 `enabledAgents` 顺序均分；高亮 `focusedAgent` |
| 列表变更 | `setEnabledAgents(_:focused:)` 更新子视图、宽度约束与选中滑块 |

点击命中：按可见槽位索引映射到 `enabledAgents[i]`，再 `onAgentSelected`。  
**禁止**再使用写死的 `width / 3`、固定三图标或固定 144pt。Testing hook（`selectAgentAtXForTesting`）按当前槽位数计算。

详情面板在 settings 变更后立即刷新切换条，无需关闭重开。

## 监控与 Usage 联动

### 语义

`agent ∈ enabledAgents` 才对该 agent：

- 运行 activity monitor 的 timer / poll  
- 将非空快照送入 `SessionAggregator`  
- 在 focused 时请求 usage  

`agent ∉ enabledAgents`：

- **立刻**将该 monitor 的对外快照置为 empty（禁止残留上一轮 working/error）  
- **停止**该 monitor 的 timer，或 poll 空操作且**不再**调用 hook / transcript / failure / realtime `refresh`  
- 不发起该 provider 的 usage 刷新  
- **不** repair / 写入该 agent 的用户侧配置  

### 实现要点

- `updatePollingContext` 增加 `enabled: Bool`。`enabled == false` 时：取消 timer（或等价停采）、跳过所有 reader、缓存快照改 empty，并回调一次 empty 以便 UI 收敛。  
- 从 false → true：恢复 timer，并 `requestRefresh()`。  
- `tick()` 按 `settings.isAgentEnabled` 传入各 monitor。  
- `setFocusedAgent`：目标未启用则 no-op。  
- Usage：只刷新当前 focused（focused 已是 enabled 子集）。

### 用户配置（hooks / statusline）

| 情况 | 行为 |
|------|------|
| Agent 启用 | 保持现有启动 / tick 侧 configure / reconcile（如 `ClaudeStatusLineConfigurator`、`GrokHookConfigurator`） |
| Agent 未启用 | **跳过**对该 agent 的 configure / reconcile / repair；**不删除**已有文件 |
| 从禁用再启用 | 允许下一次正常 configure / reconcile 路径跑起来 |

v1 **不卸载**已写入的 `~/.claude` / `~/.grok` hooks。默认全开时首次启动行为与现网相同。

### 其他边界

- 全局 `paused` 仍优先于 enabled 调度。  
- 预览状态（demo thinking/working 等）与 focused 预览行为不变。  
- 只剩 1 个 enabled 时，监控对象子菜单可仅一项且已勾选。

## 菜单栏图标

| `showMenuBarIcon` | 行为 |
|-------------------|------|
| `true` | 若尚无 item 则 `createStatusItem()`；图标随聚合状态变色（现有 `updateStatusIcon`） |
| `false` | `NSStatusBar.system.removeStatusItem` 并清空引用，停止 menu/icon 更新；**不**占菜单栏 |

关闭菜单栏图标后：

- 光环右键菜单仍可用，且含「设置…」「退出」「重置位置」等  
- 用户可在**仍打开的设置窗**或稍后经右键再打开设置，打开「显示菜单栏图标」恢复托盘  

实现注意：

- v1 采用 **remove + 再 create**，不用长期 `isVisible = false` 占位，避免泄漏多个 status item。  
- `statusItem` 类型改为可选；`updateStatusIcon` / `updateStatusMenu` 在 item 为 `nil` 时 no-op。

## i18n

**唯一源文件**：`src/shared/locales/zh.json` 与 `src/shared/locales/en.json`。  
构建脚本（`scripts/build-macos.sh` / `run-macos.sh`）会拷到 `src/macos/Sources/AgentHaloCore/locales`。  
**不要**只改 macOS 副本，否则 `--verify` 会失败。

新增 key：

| Key | 中文 | English |
|-----|------|---------|
| `menu.settings` | 设置… | Settings… |
| `settings.title` | 设置 | Settings |
| `settings.home_display.title` | 主页面显示 | Home Display |
| `settings.home_display.subtitle` | 选择要显示并启用的 Agent | Choose which agents to show and enable |
| `settings.appearance` | 外观 | Appearance |
| `settings.halo_size` | 光环大小 | Halo Size |
| `settings.language` | 语言 | Language |
| `settings.general` | 通用 | General |
| `settings.general.always_on_top` | 始终置顶 | Always on Top |
| `settings.general.show_menu_bar_icon` | 显示菜单栏图标 | Show Menu Bar Icon |
| `settings.general.launch_at_startup` | 开机自动启动 | Launch at Login |
| `settings.general.reset_position` | 重置光环位置 | Reset Halo Position |
| `settings.about.version` | Agent Halo {0} | Agent Halo {0} |

说明：

- Agent 显示名继续使用 `AgentKind.menuTitle`（产品名不翻译）。  
- 语言选项文案复用现有 `menu.language.*`。  
- 菜单「始终置顶 / 逃离屏幕外」继续用 `menu.always_on_top` / `menu.escape_offscreen`；设置按钮用更短的 `settings.general.reset_position`。

## 测试计划

### Core（`AgentHaloCoreChecks`）

- 缺省 / 旧 JSON 无 `enabledAgents` → `allCases`  
- 缺省 / 旧 JSON 无 `showMenuBarIcon` → `true`  
- 空数组、非法值 → 规范化回退 `allCases`  
- 去重 + `allCases` 稳定顺序  
- `focusedAgent ∉ enabledAgents` → 改为 `first`  
- `setAgent(enabled: false)` 不能关掉最后一个  
- 关掉 focused → focused 变为剩余 first  
- round-trip 持久化：`enabledAgents` + `showMenuBarIcon` + `focusedAgent` + 既有 `alwaysOnTop`

### App / UI（现有 testing hooks 风格）

- `AgentToggleView`：1/2/3 个 enabled 时宽度为 `48 × n`，点击按槽位映射  
- 设置胶囊：唯一已选项不可取消  
- 禁用 agent：对应 monitor 快照立刻 empty，且不再 refresh hook/reader  
- 再启用：触发 refresh，可出现新快照  
- 未启用 Claude 时 tick **不**调用 `ClaudeStatusLineConfigurator.configure` / reconcile 写入  
- `showMenuBarIcon` false → 无 status item；true → 恢复  
- 设置改置顶 ↔ 菜单勾选一致；设置窗 level 仍高于光环  
- 设置「重置位置」与菜单逃离逻辑等价  
- 页脚版本来自 short version（或 fallback）  
- 控制菜单不再包含语言 / 尺寸 / 开机启动，且含「设置…」  
- 监控对象子菜单仅含 enabled agents  
- `setFocusedAgent` 对未启用 agent no-op  

### 手动验收

1. 只勾 Codex → 切换条宽约 48、仅 Codex；Claude/Grok 无轮询、不 repair 其 hooks  
2. 再勾 Claude → 两项可切换，Claude 恢复监控  
3. 关菜单栏图标 → 托盘消失；设置窗仍在且可重新打开图标；或右键再开设置  
4. 设置窗不被光环挡住；Esc / ⌘W / 红点可关  
5. 设置内改尺寸 / 语言 / 开机启动 / 置顶，效果与旧菜单一致  
6. 设置与菜单均可重置位置到主屏右上角  
7. 页脚显示正确版本  
8. 升级老用户：三 Agent 全开、菜单栏图标仍在  

## 成功标准

1. 用户可通过设置选择任意非空 Agent 子集；切换条、监控、hooks repair 与之一致。  
2. 外观与通用偏好（尺寸、语言、置顶、菜单栏图标、开机启动）均可在设置中改且即时生效。  
3. 设置窗在 accessory + 置顶光环下可点、可关、不被挡住。  
4. 重置位置在设置与菜单双入口可用。  
5. 菜单精简后仍可通过托盘（若显示）与光环右键完成置顶、暂停、切换 focus、重置位置、设置、退出。  
6. 旧 macOS 配置升级零回归；关于信息可见。  
7. 中英文走 shared locales，verify 通过。  

## 风险与缓解

| 风险 | 缓解 |
|------|------|
| 关掉菜单栏后用户找不到设置 | 右键菜单保留「设置…」；默认 `showMenuBarIcon = true`；设置开着时可直接再打开图标 |
| 设置窗被 floating 光环挡住 | 设置窗 level = halo + 1；不为开设置改 activation policy |
| 禁用后仍 idle 轮询 / 残留快照 | 停 timer + 立刻 empty + 再启用 refresh |
| 禁用后仍写入 `~/.claude` | 未启用跳过 reconcile / configure |
| 设置窗与菜单状态分叉 | 打开时全量刷新；状态走单一 `onSettingsChanged` |
| 置顶双入口不同步 | 共用同一 `applyWindowLevels` 路径 |
| `AgentToggleView` 动态布局回归 | testing hooks 覆盖 1–3 槽与 48×n 宽度 |

## 实施切片建议（供 plan 使用）

1. **Settings schema + 规范化 + Core 测试**  
2. **AgentToggleView 动态列表与 48×n 宽度**  
3. **Monitor 启停 + 立刻清空快照 + 未启用跳过 hook repair + focus 菜单过滤**  
4. **Settings 窗口 UI**（层级 / Esc / ⌘W / Agent + 外观 + 通用 + 重置 + 关于）  
5. **菜单精简 + 设置入口 + 菜单栏图标显隐 + 置顶/重置双入口接线**  
6. **shared locales + 手动验收清单**  

切片可并行处：1∥2 起步；3 依赖 1；4–5 依赖 1 与 AppDelegate 回调约定。
