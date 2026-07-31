# macOS 启用 Agent 与设置窗口设计

## 文档状态

- 日期：2026-08-01
- 状态：设计已确认；待写实施计划
- 实现范围：**仅 macOS**（Windows 本阶段不读不写新增字段，不改 UI）
- 产品原则：见 [PRODUCT.md](../../PRODUCT.md)
- 相关先例：
  - [i18n 本地化设计](./2026-06-27-i18n-localization-design.md)
  - [macOS Session Details 设计](./2026-06-21-macos-session-details-design.md)
  - [OpenUsage 风格监控 macOS 设计](./2026-07-10-openusage-monitoring-macos-design.md)
  - [macOS Grok Build 额度与最小生命周期设计](./2026-07-25-macos-grok-build-usage-lifecycle-design.md)

## 目标

1. 用户可选择**启用哪些 Agent**：启用 = 左上角切换条显示 + 后台监控/采集；未启用 = 不显示、不轮询。
2. 提供独立 **设置窗口**，从状态栏菜单与光环右键菜单的「设置…」进入。
3. 将原先散落在菜单中的 **语言、光环大小、开机启动** 迁入设置窗口；并新增 **显示菜单栏图标** 开关。
4. 默认行为与现网一致：全部 Agent 启用、菜单栏图标显示，升级无感。

## 非目标

- Windows 设置 UI 与 `enabledAgents` / `showMenuBarIcon` 同步（后续另开）
- 新增 Agent 类型（Gemini、OpenCode、Claude Desktop 等）
- 用户自定义 Agent 显示顺序（拖拽排序）
- 将「始终置顶」「暂停监控」「预览状态」迁入设置窗口（仍留菜单快捷操作）
- 禁用 Claude 时卸载或改写 `~/.claude` hooks / statusline 配置
- 云同步、远程配置、账号体系
- 设置窗口内搬迁「逃离屏幕外」等恢复操作

## 已确认的架构决策

1. **平台**：仅 macOS。
2. **语义**：勾选 Agent = **启用 + 显示**（方案 B），不是「仅控制 UI 可见性」。
3. **持久化字段**：`enabledAgents: [AgentKind]` + `showMenuBarIcon: Bool`；语言/尺寸/开机启动沿用现有路径。
4. **默认**：`enabledAgents = AgentKind.allCases`；`showMenuBarIcon = true`。
5. **至少 1 个 Agent**：不能清空；关掉当前 `focusedAgent` 时自动切到 `enabledAgents.first`。
6. **显示顺序**：v1 写入时始终按 `AgentKind.allCases` 过滤排序，不记录用户勾选先后。
7. **设置即时生效**，无「保存 / 取消」按钮。
8. **菜单栏图标关闭后**：托盘消失，仍可通过**光环右键菜单**打开设置与退出。
9. **托盘菜单与右键菜单共用**精简后的控制菜单；仅当 `showMenuBarIcon == true` 时存在 `NSStatusItem`。

## 背景与问题

### 现状

- `AgentKind`：`codex` / `claudeCode` / `grok`。
- 焦点由 `HaloSettings.focusedAgent` 持久化；详情面板左上角 `AgentToggleView` **固定三等分**展示三个图标。
- 监控侧（`CodexActivityMonitor` / `ClaudeActivityMonitor` / `GrokActivityMonitor`）主要按 `focusedAgent` 决定是否深采；聚合与 usage 也围绕 focused。
- 状态栏菜单与光环右键菜单共用 `makeControlMenu()`，内含：置顶、开机启动、暂停、光环尺寸滑块、监控对象、语言、逃离屏幕外、预览状态、退出。
- 无独立设置窗口；用户无法声明「我只用 Codex」。

### 问题

| 问题 | 影响 |
|------|------|
| 切换条永远三个 | 单 Agent 用户噪音大 |
| 无法关闭不需要的 Agent 监控 | 多余 IO / 轮询 |
| 偏好设置散落在深层子菜单 | 语言、尺寸、开机启动难发现 |
| 菜单栏图标无法隐藏 | 菜单栏拥挤时无退路 |

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

现有字段不变：`focusedAgent`、`haloSize`、`language`、`alwaysOnTop`、`paused`、位置相关字段等。

开机启动**不**写入 `settings.json`，继续由 `StartupManager` / LaunchAgent 表示真实状态（与现网一致）。

### 规范化规则

加载或任意写路径之后，设置必须满足：

1. `enabledAgents` 去重，仅保留合法 `AgentKind`，顺序规范为 `allCases.filter { enabledSet.contains($0) }`。
2. 若规范化后为空 → 回退 `allCases`。
3. 若 `focusedAgent ∉ enabledAgents` → `focusedAgent = enabledAgents.first!`。
4. `showMenuBarIcon` 为 Bool，缺省 `true`。

### 辅助 API（建议）

放在 `HaloSettings` 上（或紧邻的纯函数，便于 CoreChecks 单测）：

- `isAgentEnabled(_ agent: AgentKind) -> Bool`
- `mutating func setAgent(_ agent: AgentKind, enabled: Bool)`  
  - 关闭最后一个已启用项：no-op  
  - 关闭当前 `focusedAgent`：将 `focusedAgent` 设为规范化后的 `enabledAgents.first`
- `normalized() -> HaloSettings`：应用上述全部规则（decode / save 前可调用）

### 兼容性

- 旧 `settings.json` 无新字段 → 行为与现网一致（三 Agent 全开、菜单栏图标显示）。
- Windows 忽略这些字段；日后 Windows 实现时再对齐 schema。

## 设置窗口

### 入口

- 状态栏菜单与光环右键菜单增加 **`menu.settings`**（「设置…」/「Settings…」）。
- 已打开则前置窗口；全局**至多一个**设置窗口实例。
- 非 modal `NSPanel` / `NSWindow` 即可。

### 布局（v1）

```text
┌─ 设置 ────────────────────────────────────┐
│  主页面显示                                │
│  选择要显示并启用的 Agent                   │
│  [● Codex] [● Claude Code] [○ Grok]       │
│                                           │
│  光环大小                      112        │
│  ━━━━━●━━━━━━━━  (72…180)                 │
│                                           │
│  语言                                      │
│  ( 跟随系统  |  中文  |  English )          │
│                                           │
│  通用                                      │
│  显示菜单栏图标                    [toggle]│
│  开机自动启动                      [toggle]│
└───────────────────────────────────────────┘
```

### 各区块行为

| 区块 | 行为 |
|------|------|
| 主页面显示 | 胶囊多选；选中 = 实心强调色 + 图标/标题；未选中 = 浅底。点击切换启用。只剩 1 个已选时不可点灭（忽略点击或视觉 dim）。即时写盘并通知 `AppDelegate`。 |
| 光环大小 | 滑块 + 数值；范围与步进与现有菜单滑块一致（`HaloSettings.minimumHaloSize`…`maximumHaloSize`）。调用现有 `applyHaloSize` 路径（clamp、面板 resize、防抖写盘、详情面板重定位）。 |
| 语言 | 三段：跟随系统 (`nil`) / `zh` / `en`。改后 `L10n.shared.setLanguage`、写 `settings.language`、刷新菜单与设置窗文案。 |
| 显示菜单栏图标 | 见下文「菜单栏图标」。 |
| 开机自动启动 | Toggle ↔ `StartupManager.setEnabled`；打开设置时读 `StartupManager.isEnabled()` 反映真实状态。 |

### 变更传播

```text
Settings UI 变更
  → 更新 HaloSettings（+ 规范化）
  → SettingsStore.save（尺寸可走既有防抖）
  → AppDelegate.onSettingsChanged：
       · self.settings = normalized
       · 刷新 AgentToggleView
       · 重建控制菜单（若 status item 存在）
       · applyMenuBarIconVisibility()
       · 若 focused 变化 → requestUsageRefresh
       · tick() 立即应用监控启停
```

建议：`SettingsWindowController`（或等价类型）持有 `onSettingsChanged: (HaloSettings) -> Void` 与必要的命令回调（尺寸、启动项、语言），由 `AppDelegate` 注入，避免设置窗直接操作 monitor。

## 菜单精简

托盘与右键仍共用一份菜单构造函数。

### 从菜单移除（改由设置窗口）

- 开机自动启动  
- 光环大小滑块  
- 语言子菜单  

### 菜单保留

- 始终置顶  
- 暂停监控  
- 监控对象（**仅列出 `enabledAgents`**；勾选表示当前 `focusedAgent`）  
- 逃离屏幕外  
- 预览状态  
- **设置…**（新）  
- 退出  

建议顺序：置顶 → 暂停 → 监控对象 → 逃离 → 预览 → 分隔线 → 设置… → 退出。

## 左上角 Agent 切换条

`AgentToggleView` 改为按 `enabledAgents` **动态渲染**：

| 已启用数量 | 行为 |
|-----------|------|
| 1 | 单图标；保持选中样式；点击不切换 |
| 2+ | 按 `enabledAgents` 顺序均分宽度；高亮 `focusedAgent` |
| 列表变更 | `setEnabledAgents(_:focused:)` 更新子视图与约束；选中滑块对齐 focused |

点击命中：按可见槽位索引映射到 `enabledAgents[i]`，再 `onAgentSelected`。  
**禁止**再使用写死的 `width / 3` 与固定三图标布局。

详情面板在 settings 变更后立即刷新切换条，无需关闭重开。

## 监控与 Usage 联动

### 语义

`agent ∈ enabledAgents` 才对该 agent：

- 运行 activity monitor 轮询 / 合并快照  
- 将非空快照送入 `SessionAggregator`  
- 在 focused 时请求 usage  

`agent ∉ enabledAgents`：

- 跳过采集；对外视为空快照  
- 不发起该 provider 的 usage 刷新  

### 实现要点

- `updatePollingContext` 增加 `enabled: Bool`（或 `isMonitored`），内部 `guard enabled` 早退。  
- `tick()` 按 `settings.isAgentEnabled` 传入各 monitor。  
- Claude statusline / hook **配置**：v1 **不因禁用而卸载** 已有 `~/.claude` 配置，仅本 app 不读结果，降低副作用。  
- `focusedAgent` 始终是 `enabledAgents` 子集，usage 路径可保持「只刷新 focused」。

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

- 光环右键菜单仍可用，且含「设置…」「退出」等  
- 用户可再次打开设置，打开「显示菜单栏图标」恢复托盘  

实现注意：

- v1 采用 **remove + 再 create**，不用长期 `isVisible = false` 占位，避免泄漏多个 status item。  
- `statusItem` 类型改为可选；`updateStatusIcon` / `updateStatusMenu` 在 item 为 `nil` 时 no-op。

## i18n

在 macOS / shared 语言包增加（中英文）：

| Key | 中文 | English |
|-----|------|---------|
| `menu.settings` | 设置… | Settings… |
| `settings.title` | 设置 | Settings |
| `settings.home_display.title` | 主页面显示 | Home Display |
| `settings.home_display.subtitle` | 选择要显示并启用的 Agent | Choose which agents to show and enable |
| `settings.halo_size` | 光环大小 | Halo Size |
| `settings.language` | 语言 | Language |
| `settings.general` | 通用 | General |
| `settings.general.show_menu_bar_icon` | 显示菜单栏图标 | Show Menu Bar Icon |
| `settings.general.launch_at_startup` | 开机自动启动 | Launch at Login |

Agent 显示名继续使用 `AgentKind.menuTitle`（产品名不翻译）。  
语言选项文案复用现有 `menu.language.*` 即可。

## 测试计划

### Core（`AgentHaloCoreChecks`）

- 缺省 / 旧 JSON 无 `enabledAgents` → `allCases`  
- 缺省 / 旧 JSON 无 `showMenuBarIcon` → `true`  
- 空数组、非法值 → 规范化回退  
- 去重 + `allCases` 稳定顺序  
- `focusedAgent ∉ enabledAgents` → 改为 `first`  
- `setAgent(enabled: false)` 不能关掉最后一个  
- 关掉 focused → focused 变为剩余 first  
- round-trip 持久化：`enabledAgents` + `showMenuBarIcon` + `focusedAgent`

### App / UI（现有 testing hooks 风格）

- `AgentToggleView`：1/2/3 个 enabled 时槽位与点击映射正确  
- 设置胶囊：唯一已选项不可取消  
- `showMenuBarIcon` false → 无 status item；true → 恢复  
- 控制菜单不再包含语言 / 尺寸 / 开机启动，且含「设置…」  
- 监控对象子菜单仅含 enabled agents  

### 手动验收

1. 只勾 Codex → 切换条仅 Codex；Claude/Grok 无轮询副作用（日志/CPU 可观察）  
2. 再勾 Claude → 两项可切换，Claude 恢复监控  
3. 关菜单栏图标 → 托盘消失；右键可开设置并重新打开  
4. 设置内改尺寸 / 语言 / 开机启动，效果与旧菜单一致  
5. 升级老用户：三 Agent 全开、菜单栏图标仍在  

## 成功标准

1. 用户可通过设置选择任意非空 Agent 子集；切换条与监控一致。  
2. 语言、光环大小、开机启动、菜单栏图标均在设置中可改且即时生效。  
3. 菜单精简后仍可通过托盘（若显示）与光环右键完成置顶、暂停、切换 focus、设置、退出。  
4. 旧配置升级零回归。  
5. 中英文文案完整。  

## 风险与缓解

| 风险 | 缓解 |
|------|------|
| 关掉菜单栏后用户找不到设置 | 右键菜单保留「设置…」；默认 `showMenuBarIcon = true` |
| 禁用 Claude 后 hook 仍写盘 | v1 接受；文档标明非目标；日后再做卸载策略 |
| 设置窗与 AppDelegate 状态分叉 | 单向回调 + 唯一 `settings` 源；打开设置时用当前 settings 刷新控件 |
| `AgentToggleView` 动态布局回归 | 保留/扩展 testing hooks，覆盖 1–3 槽 |

## 实施切片建议（供 plan 使用）

1. **Settings schema + 规范化 + Core 测试**  
2. **AgentToggleView 动态 enabled 列表**  
3. **Monitor 启停联动 + focus 菜单过滤**  
4. **Settings 窗口 UI（Agent + 尺寸 + 语言 + 通用 toggles）**  
5. **菜单精简 + 设置入口 + 菜单栏图标显隐**  
6. **i18n + 手动验收清单**  

切片可并行处：1∥2 起步；3 依赖 1；4–5 依赖 1 与 AppDelegate 回调约定。
