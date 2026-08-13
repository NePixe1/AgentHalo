# macOS 启用 Agent 与设置窗口 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 macOS 上增加 `enabledAgents` / `showMenuBarIcon`，用独立设置窗口管理启用 Agent、外观与通用偏好；未启用的 Agent 不显示、不轮询、启动时不写入其用户配置。

**Architecture:** `HaloSettings` 规范化启用列表；`AgentToggleView` 按 enabled 动态槽位（`144 / allCases.count`）；四个 ActivityMonitor 增加 `enabled` 并立刻清空快照；`AgentHaloRuntimeBootstrap.bootstrap(enabledAgents:)` 跳过未启用 configure；新建 `SettingsWindowController`（key `NSPanel`，level = halo + 1）；托盘 / 右键菜单精简并增加「设置…」。

**Tech Stack:** Swift 6、AppKit、SwiftPM（`AgentHaloCore` / `AgentHaloMac` / `AgentHaloCoreChecks`）、`src/shared/locales`

**Spec:** [2026-08-01-macos-enabled-agents-settings-design.md](../specs/2026-08-01-macos-enabled-agents-settings-design.md)

## Global Constraints

- **仅 macOS**。不改 `src/windows/`、Windows 测试或文档。
- Agent 全集 = `AgentKind.allCases`（当前 `codex` / `claudeCode` / `grok` / `pi`），禁止写死「三个」。
- 启用 = 显示 + 监控；至少 1 个；空 / 非法回退 `allCases`。
- 切换条：`slotWidth = 144 / CGFloat(AgentKind.allCases.count)`（当前 36）；全开总宽保持 144。
- 设置即时生效，无保存按钮。
- App 保持 `.accessory`；设置窗禁止 `.nonactivatingPanel`；`becomesKeyOnlyIfNeeded = false`；level = halo + 1。
- 未启用：立刻 empty 快照、停采、**bootstrap 与 tick 都不 configure / repair** 该 agent 用户文件；不卸载已有文件。
- Pi 的 `usageProviderID` 为 `nil`，focus 到 Pi 不请求官方额度。
- i18n **只改** `src/shared/locales/{zh,en}.json`（构建会拷到 Core）。
- TDD：先写失败检查 → 跑红 → 最小实现 → 跑绿 → 提交。
- 提交前 `git status --short`，只暂存本任务文件。
- 跑检查：
  - Core：`cd src/macos && swift run AgentHaloCoreChecks`
  - UI：`cd src/macos && swift test` 不可用；交互检查随 `AgentHaloMac` 内 `runHaloInteractionChecks()`，开发时 `swift run AgentHaloMac --packaged-verification` 或仓库惯例 `bash ./scripts/run-macos.sh --verify`（较慢，任务末尾再用）。单测优先 `swift run AgentHaloCoreChecks`，UI 检查用 `cd src/macos && swift run --skip-update AgentHaloMac` 若入口支持 checks；本仓库 UI checks 在 `HaloInteractionChecks.swift` 中由 packaged verification / debug 路径调用。实现者在改 UI 后至少编译：`cd src/macos && swift build --target AgentHaloMac`。

---

## 文件地图

| 文件 | 职责 |
|------|------|
| `src/macos/Sources/AgentHaloCore/HaloSettings.swift` | `enabledAgents` / `showMenuBarIcon` + `normalized()` / `setAgent` |
| `src/macos/Sources/AgentHaloCore/AgentHaloRuntimeBootstrap.swift` | `bootstrap(enabledAgents:)` 按启用跳过 configure |
| `src/macos/Sources/AgentHaloCoreChecks/main.swift` | Core 单测 |
| `src/macos/Sources/AgentHaloMac/DetailsPanel.swift` | 动态 `AgentToggleView` + 宽度约束 |
| `src/macos/Sources/AgentHaloMac/{Codex,Claude,Grok,Pi}ActivityMonitor.swift` | `enabled` 停采 + empty |
| `src/macos/Sources/AgentHaloMac/SettingsWindowController.swift` | **新建** 设置窗口 |
| `src/macos/Sources/AgentHaloMac/AppDelegate.swift` | tick / bootstrap / 菜单 / 设置入口 / status item 可选 |
| `src/macos/Sources/AgentHaloMac/HaloInteractionChecks.swift` | UI / 菜单 / toggle / 设置窗检查 |
| `src/shared/locales/{zh,en}.json` | 新文案（再由 build 拷到 Core locales） |

不改 Windows。不把「暂停 / 预览 / 退出」搬进设置。

---

### Task 1: HaloSettings schema 与规范化

**Files:**
- Modify: `src/macos/Sources/AgentHaloCore/HaloSettings.swift`
- Modify: `src/macos/Sources/AgentHaloCoreChecks/main.swift`
- Test: `src/macos/Sources/AgentHaloCoreChecks/main.swift`

**Interfaces:**
- Consumes: 现有 `HaloSettings` / `SettingsStore` / `AgentKind`
- Produces:
  - `HaloSettings.enabledAgents: [AgentKind]`
  - `HaloSettings.showMenuBarIcon: Bool`
  - `func isAgentEnabled(_ agent: AgentKind) -> Bool`
  - `mutating func setAgent(_ agent: AgentKind, enabled: Bool)`
  - `func normalized() -> HaloSettings`
  - `SettingsStore.load` 返回已 `normalized()` 的值

- [ ] **Step 1: 写失败的 Core 测试**

在 `main.swift` 里 `testPiFocusedAgentPersistence()` 后追加（沿用该文件的 `expect`）：

```swift
func testSettingsDefaultsEnabledAgentsAndMenuBarIconWhenMissing() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agent-halo-enabled-legacy-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("settings.json")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try """
    {
      "acknowledged" : {},
      "alwaysOnTop" : true,
      "alwaysOnTopBehaviorVersion" : 1,
      "focusedAgent" : "claudeCode",
      "hasPosition" : false,
      "installedAt" : "2026-06-13T02:00:00Z",
      "left" : 0,
      "paused" : false,
      "top" : 0
    }
    """.data(using: .utf8)!.write(to: url)

    let loaded = SettingsStore(settingsURL: url).load()
    expect(loaded.enabledAgents, AgentKind.allCases, "legacy settings enable every AgentKind")
    expect(loaded.showMenuBarIcon, true, "legacy settings show the menu bar icon")
    expect(loaded.focusedAgent, .claudeCode, "legacy focused agent is preserved when still enabled")
}

func testSettingsNormalizesEmptyEnabledAgentsToAllCases() {
    var settings = HaloSettings(enabledAgents: [], focusedAgent: .codex)
    settings = settings.normalized()
    expect(settings.enabledAgents, AgentKind.allCases, "empty enabledAgents falls back to allCases")
}

func testSettingsNormalizesDuplicateAndUnknownOrder() {
    let settings = HaloSettings(
        focusedAgent: .grok,
        enabledAgents: [.grok, .codex, .grok, .pi]
    ).normalized()
    expect(
        settings.enabledAgents,
        [.codex, .grok, .pi],
        "enabledAgents is unique and ordered by allCases"
    )
    expect(settings.focusedAgent, .grok, "focused grok stays when still enabled")
}

func testSettingsMovesFocusWhenDisabled() {
    var settings = HaloSettings(
        focusedAgent: .claudeCode,
        enabledAgents: AgentKind.allCases
    )
    settings.setAgent(.claudeCode, enabled: false)
    expect(settings.isAgentEnabled(.claudeCode), false, "claude becomes disabled")
    expect(settings.focusedAgent, .codex, "focus moves to first remaining (codex)")
    expect(settings.enabledAgents.contains(.claudeCode), false, "claude removed from list")
}

func testSettingsCannotDisableTheLastAgent() {
    var settings = HaloSettings(focusedAgent: .pi, enabledAgents: [.pi])
    settings.setAgent(.pi, enabled: false)
    expect(settings.enabledAgents, [.pi], "last agent cannot be disabled")
    expect(settings.focusedAgent, .pi, "focus stays on the last agent")
}

func testSettingsPersistsEnabledAgentsAndMenuBarIcon() {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agent-halo-enabled-persist-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("settings.json")
    let store = SettingsStore(settingsURL: url)
    var settings = HaloSettings(focusedAgent: .codex, enabledAgents: [.codex, .pi], showMenuBarIcon: false)
    store.save(settings)
    let loaded = store.load()
    expect(loaded.enabledAgents, [.codex, .pi], "enabledAgents round-trips")
    expect(loaded.showMenuBarIcon, false, "showMenuBarIcon round-trips")
    expect(loaded.focusedAgent, .codex, "focused agent still round-trips")
}

func testSettingsLoadRepairsFocusOutsideEnabledAgents() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agent-halo-enabled-focus-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("settings.json")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try """
    {
      "enabledAgents" : ["pi"],
      "focusedAgent" : "grok",
      "hasPosition" : false,
      "installedAt" : "2026-06-13T02:00:00Z",
      "left" : 0,
      "top" : 0
    }
    """.data(using: .utf8)!.write(to: url)
    let loaded = SettingsStore(settingsURL: url).load()
    expect(loaded.enabledAgents, [.pi], "pi remains the only enabled agent")
    expect(loaded.focusedAgent, .pi, "load moves focus onto the enabled set")
}
```

在 `main.swift` 测试入口（`testPiFocusedAgentPersistence()` 附近）调用上述函数（`throws` 的用 `try`）。

- [ ] **Step 2: 跑 CoreChecks，确认新测试失败**

```bash
cd src/macos && swift run AgentHaloCoreChecks
```

Expected: 编译失败或 fatalError（`enabledAgents` / `showMenuBarIcon` / `normalized` 不存在）。

- [ ] **Step 3: 实现 schema**

`HaloSettings.swift`：

- CodingKeys 增加 `enabledAgents`、`showMenuBarIcon`。
- 存储属性与 init 参数（默认 `enabledAgents = AgentKind.allCases`，`showMenuBarIcon = true`）。decode：缺省同上；解码后赋 `self =` 中间值再 `self = decoded.normalized()`，或 decode 完调用规范化。
- `SettingsStore.load` 在 decode 成功后：`return settings.normalized()`（保留现有 alwaysOnTop 迁移与 `paused = false`）。
- API：

```swift
public func isAgentEnabled(_ agent: AgentKind) -> Bool {
    enabledAgents.contains(agent)
}

public mutating func setAgent(_ agent: AgentKind, enabled: Bool) {
    var next = Set(enabledAgents)
    if enabled {
        next.insert(agent)
    } else {
        next.remove(agent)
    }
    if next.isEmpty { return }
    enabledAgents = AgentKind.allCases.filter { next.contains($0) }
    if !enabledAgents.contains(focusedAgent), let first = enabledAgents.first {
        focusedAgent = first
    }
}

public func normalized() -> HaloSettings {
    var next = self
    var seen = Set<AgentKind>()
    var ordered: [AgentKind] = []
    for agent in AgentKind.allCases where next.enabledAgents.contains(agent) && seen.insert(agent).inserted {
        ordered.append(agent)
    }
    if ordered.isEmpty { ordered = AgentKind.allCases }
    next.enabledAgents = ordered
    if !ordered.contains(next.focusedAgent), let first = ordered.first {
        next.focusedAgent = first
    }
    return next
}
```

`init(from:)` 对 `enabledAgents` 用 `decodeIfPresent`，nil → `allCases`；`showMenuBarIcon` nil → `true`。

- [ ] **Step 4: 再跑 CoreChecks**

```bash
cd src/macos && swift run AgentHaloCoreChecks
```

Expected: PASS（无 fatalError）。

- [ ] **Step 5: Commit**

```bash
git add src/macos/Sources/AgentHaloCore/HaloSettings.swift \
        src/macos/Sources/AgentHaloCoreChecks/main.swift
git commit -m "$(cat <<'EOF'
feat(macos): persist enabledAgents and menu bar icon

Add HaloSettings fields with allCases defaults, normalization, and
load-time focus repair so a later settings UI can toggle agents.
EOF
)"
```

---

### Task 2: AgentToggleView 按 enabled 动态槽位

**Files:**
- Modify: `src/macos/Sources/AgentHaloMac/DetailsPanel.swift`（`AgentToggleView` + 顶栏宽度约束）
- Modify: `src/macos/Sources/AgentHaloMac/HaloInteractionChecks.swift`
- Test: 同上

**Interfaces:**
- Consumes: `AgentKind.allCases`、`HaloSettings.enabledAgents`（本任务只改 view API）
- Produces:
  - `AgentToggleView.slotWidth` = `144 / CGFloat(AgentKind.allCases.count)`（36）
  - `func setEnabledAgents(_ agents: [AgentKind], focused: AgentKind)`
  - `var enabledAgentsForTesting: [AgentKind]`
  - `var toggleWidthForTesting: CGFloat`（或读 `widthAnchor` / `bounds.width` 在 layout 后）
  - `DetailsPanel.setEnabledAgents(_:focused:)` 更新 toggle 并改宽度约束
  - 点击按 `enabledAgents[i]` 映射；禁止 `/ 3`、`/ 4`、永远 144

- [ ] **Step 1: 写失败的 UI 检查**

在 `HaloInteractionChecks.swift` 增加并挂到 `runHaloInteractionChecks()`：

```swift
@MainActor
private func testAgentToggleWidthScalesWithEnabledCount() {
    let toggle = AgentToggleView(frame: .zero)
    toggle.setEnabledAgents([.codex], focused: .codex)
    toggle.layoutSubtreeIfNeeded()
    expect(toggle.bounds.width, 36, "one enabled agent is one 36pt slot")

    toggle.setEnabledAgents([.codex, .pi], focused: .pi)
    toggle.layoutSubtreeIfNeeded()
    expect(toggle.bounds.width, 72, "two enabled agents are two slots")
    expect(toggle.selectedAgent, .pi, "focused agent stays selected")

    toggle.setEnabledAgents(AgentKind.allCases, focused: .codex)
    toggle.layoutSubtreeIfNeeded()
    expect(toggle.bounds.width, 144, "all agents keep the current 144pt control")
}

@MainActor
private func testAgentToggleClickMapsEnabledSlotsOnly() {
    let toggle = AgentToggleView(frame: .zero)
    toggle.setEnabledAgents([.codex, .pi], focused: .codex)
    toggle.layoutSubtreeIfNeeded()
    var selected: AgentKind?
    toggle.onAgentSelected = { selected = $0 }
    toggle.selectAgentAtXForTesting(54) // second of two 36pt slots
    expect(toggle.selectedAgent, .pi, "second visible slot is Pi, not Claude")
    expect(selected, .pi, "click emits Pi")
}
```

把现有 `testAgentToggleSupportsThreeAgentsIncludingGrok` 在默认全开（144、四槽 0–36 / 36–72 / 72–108 / 108–144）下保留，但改为先 `setEnabledAgents(AgentKind.allCases, focused: .codex)`，避免依赖「未调用 set 的隐式四槽」。

把 `testAgentToggleUsesSharedSVGAssets` 里「必须存在 `equalToConstant: 144`」改成：全开时宽度 144，或断言 `slotWidth` 公式 / `setEnabledAgents` 存在。不要再要求源码写死 144 作为唯一宽度。

- [ ] **Step 2: 编译 / 跑 packaged checks 确认失败**

```bash
cd src/macos && swift build --target AgentHaloMac
```

若 verification 会跑 interaction checks，先编译即可。Expected: `setEnabledAgents` 不存在。

- [ ] **Step 3: 实现动态 toggle**

`AgentToggleView`：

- 删除写死 `agentCount = 4` 与四套永久约束作为唯一布局。
- 保留四个 icon view（或按 `allCases` 建字典），`setEnabledAgents`：
  - 规范化顺序为 `allCases.filter { requested.contains }`，空则 `allCases`。
  - 隐藏未启用 icon（`isHidden = true`）。
  - 重建 leading 链：只把可见 icon 按顺序排，每个宽 `slotWidth`。
  - 更新自身宽度约束为 `slotWidth * CGFloat(visible.count)`。
  - 若 `focused` 不在列表，选 `visible.first!`。
- `selectAgent(atX:)`：`index = clamp(Int(x / slotWidth), 0, visible.count-1)`。
- `DetailsPanel`：把 `agentToggle.widthAnchor = 144` 存成可变约束，`setEnabledAgents` 改 `constant`。
- `render` / 初始化时用当前 settings 之前可先默认 `allCases`；AppDelegate 接线在 Task 5。本任务先给 DetailsPanel 加：

```swift
func setEnabledAgents(_ agents: [AgentKind], focused: AgentKind) {
    agentToggle.setEnabledAgents(agents, focused: focused)
    agentToggleWidthConstraint.constant = AgentToggleView.slotWidth * CGFloat(max(agents.count, 1))
}
```

（`setEnabledAgents` 内部自己算 visible count，以它为准。）

- [ ] **Step 4: 再编译；能跑 interaction checks 则跑**

```bash
cd src/macos && swift build --target AgentHaloMac
```

Expected: 编译通过。若本地有跑 `runHaloInteractionChecks` 的入口，确认新检查通过。

- [ ] **Step 5: Commit**

```bash
git add src/macos/Sources/AgentHaloMac/DetailsPanel.swift \
        src/macos/Sources/AgentHaloMac/HaloInteractionChecks.swift
git commit -m "$(cat <<'EOF'
feat(macos): size the agent toggle by enabled count

Render only enabled agents and keep a 36pt slot so four agents still
occupy the existing 144pt control.
EOF
)"
```

---

### Task 3: Monitor 启停、清空快照、bootstrap 跳过 configure

**Files:**
- Modify: `src/macos/Sources/AgentHaloMac/CodexActivityMonitor.swift`
- Modify: `src/macos/Sources/AgentHaloMac/ClaudeActivityMonitor.swift`
- Modify: `src/macos/Sources/AgentHaloMac/GrokActivityMonitor.swift`
- Modify: `src/macos/Sources/AgentHaloMac/PiActivityMonitor.swift`
- Modify: `src/macos/Sources/AgentHaloMac/AppDelegate.swift`（`tick` / `setFocusedAgent` / `bootstrap` 调用）
- Modify: `src/macos/Sources/AgentHaloCore/AgentHaloRuntimeBootstrap.swift`
- Modify: `src/macos/Sources/AgentHaloCoreChecks/main.swift`
- Modify: `src/macos/Sources/AgentHaloMac/HaloInteractionChecks.swift`（源码断言 tick 传 `enabled`）
- Test: CoreChecks bootstrap；HaloInteractionChecks 源码/行为

**Interfaces:**
- Consumes: `HaloSettings.isAgentEnabled`
- Produces:
  - `updatePollingContext(..., enabled: Bool)`（各 monitor；其余参数保持现有）
  - `enabled == false` → 停 timer、快照 = `.empty`、回调一次 empty、不再 `refresh` reader
  - `false → true` → 恢复 timer + `requestRefresh()`
  - `AgentHaloRuntimeBootstrap.bootstrap(..., enabledAgents: [AgentKind] = AgentKind.allCases)`
  - 未启用 Claude：不调 `ClaudeHookConfigurator` / `ClaudeStatusLineConfigurator`
  - 未启用 Grok：不调 `GrokHookConfigurator`
  - 未启用 Pi：不调 `PiExtensionConfigurator`
  - 二进制 stage 仍全部执行
  - `setFocusedAgent`：`!settings.isAgentEnabled(agent)` → **no-op**
  - `reconcileClaudeStatusLineConfiguration`：Claude 未启用则 return
  - Usage：仅当 `usageProviderID(for: focused) != nil`

- [ ] **Step 1: 写失败测试**

Core（bootstrap 跳过写入）——仿 `testRuntimeBootstrapUpgradesLayoutV1WithoutStrandingHookPaths`，但传入 `enabledAgents: [.codex]`：

```swift
func testRuntimeBootstrapSkipsDisabledAgentUserConfig() throws {
    let fm = FileManager.default
    let home = fm.temporaryDirectory.appendingPathComponent(
        "agent-halo-bootstrap-skip-\(UUID().uuidString)", isDirectory: true
    )
    defer { try? fm.removeItem(at: home) }

    let claudeSettings = home.appendingPathComponent(".claude/settings.json")
    try fm.createDirectory(at: claudeSettings.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: claudeSettings)
    let beforeClaude = try Data(contentsOf: claudeSettings)

    let grokFile = home.appendingPathComponent(".grok/hooks/agent-halo-status.json")
    try fm.createDirectory(at: grokFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{\"hooks\":{}}".utf8).write(to: grokFile)
    let beforeGrok = try Data(contentsOf: grokFile)

    let piFile = home.appendingPathComponent(".pi/agent/extensions/agent-halo-status.ts")
    try fm.createDirectory(at: piFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("// keep-me\n".utf8).write(to: piFile)
    let beforePi = try Data(contentsOf: piFile)

    let bundledHook = home.appendingPathComponent("bundled-hook")
    let bundledProxy = home.appendingPathComponent("bundled-proxy")
    try Data("hook".utf8).write(to: bundledHook)
    try Data("proxy".utf8).write(to: bundledProxy)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundledHook.path)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundledProxy.path)

    AgentHaloRuntimeBootstrap.bootstrap(
        homeDirectory: home,
        bundledHookBinary: bundledHook,
        bundledStatuslineProxy: bundledProxy,
        fileManager: fm,
        enabledAgents: [.codex]
    )

    expect(try Data(contentsOf: claudeSettings), beforeClaude, "disabled Claude config is not rewritten")
    expect(try Data(contentsOf: grokFile), beforeGrok, "disabled Grok hooks are not rewritten")
    expect(try Data(contentsOf: piFile), beforePi, "disabled Pi extension is not rewritten")
}
```

现有 `testRuntimeBootstrapUpgradesLayoutV1WithoutStrandingHookPaths` **不要**传 `enabledAgents`，默认 `allCases`，行为与现在一致。

Monitor empty：在 `HaloInteractionChecks` 用源码约束 + 可测 API。给 monitor 增加测试可见的 `isPollingForTesting` 或检查 `snapshot() == .empty`：

```swift
@MainActor
private func testDisabledCodexMonitorPublishesEmptySnapshot() {
    let monitor = CodexActivityMonitor()
    monitor.start { _ in }
    monitor.updatePollingContext(focusedAgent: .codex, codexRunning: true, enabled: false)
    // allow the monitor queue to apply context
    let snapshot = monitor.snapshot()
    expect(snapshot, .empty, "disabled Codex monitor must not keep a stale snapshot")
    monitor.stop()
}
```

（实现时用 `queue.sync` 读 snapshot，现有 `snapshot()` 已 sync。）

`setFocusedAgent`：

```swift
@MainActor
private func testSetFocusedAgentIgnoresDisabledAgent() {
    let delegate = AppDelegate()
    delegate.settings.setAgent(.claudeCode, enabled: false)
    let before = delegate.settings.focusedAgent
    delegate.setFocusedAgent(.claudeCode)
    expect(delegate.settings.focusedAgent, before, "disabled agent cannot become focused")
}
```

注意：`AppDelegate.settings` 若是 `private`，加 `internal` 测试用 setter，或加 `setEnabledAgentsForTesting`。优先最小暴露：`func applyEnabledAgentsForTesting(_ agents: [AgentKind])`。

Tick 接线源码检查（仿 `testStatusLineConfigurationReconciliationIsWiredToTick`）：`tick` 源码含 `enabled:` / `isAgentEnabled`。

- [ ] **Step 2: 跑测试确认失败**

```bash
cd src/macos && swift run AgentHaloCoreChecks
```

Expected: `bootstrap(..., enabledAgents:)` 无此参数 → 编译失败。

- [ ] **Step 3: 实现**

`AgentHaloRuntimeBootstrap.bootstrap` 增加 `enabledAgents: [AgentKind] = AgentKind.allCases`。stage 二进制不变。configure 包在：

```swift
if enabledAgents.contains(.claudeCode) {
    ClaudeHookConfigurator.configure(...)
    ClaudeStatusLineConfigurator.configure(...)
}
if enabledAgents.contains(.grok) {
    GrokHookConfigurator.configure(...)
}
if enabledAgents.contains(.pi) {
    PiExtensionConfigurator.configure(...)
}
```

各 monitor `PollingContext` 加 `enabled: Bool = true`。`updatePollingContext` 增加参数 `enabled: Bool`。`enabled == false`：`timer?.cancel(); timer = nil`；`latestSnapshot = .empty`；dispatch empty `onChange`；`poll` 入口 `guard context.enabled else { return }`。`enabled` 从 false 变 true：`scheduleTimer` + `poll(force:)`。

`AppDelegate.applicationDidFinishLaunching`：

```swift
AgentHaloRuntimeBootstrap.bootstrap(enabledAgents: settings.enabledAgents)
```

`tick()`：把 `enabled: settings.isAgentEnabled(.codex)` 等传入四个 monitor；Claude 未启用则不要 `reconcileClaudeStatusLineConfiguration`。

`setFocusedAgent` 开头：

```swift
guard settings.isAgentEnabled(agent) else { return }
```

- [ ] **Step 4: 再跑 CoreChecks + 编译 Mac**

```bash
cd src/macos && swift run AgentHaloCoreChecks && swift build --target AgentHaloMac
```

Expected: PASS。

- [ ] **Step 5: Commit**

```bash
git add src/macos/Sources/AgentHaloCore/AgentHaloRuntimeBootstrap.swift \
        src/macos/Sources/AgentHaloCoreChecks/main.swift \
        src/macos/Sources/AgentHaloMac/CodexActivityMonitor.swift \
        src/macos/Sources/AgentHaloMac/ClaudeActivityMonitor.swift \
        src/macos/Sources/AgentHaloMac/GrokActivityMonitor.swift \
        src/macos/Sources/AgentHaloMac/PiActivityMonitor.swift \
        src/macos/Sources/AgentHaloMac/AppDelegate.swift \
        src/macos/Sources/AgentHaloMac/HaloInteractionChecks.swift
git commit -m "$(cat <<'EOF'
feat(macos): stop disabled-agent polling and config writes

Honor enabledAgents in activity monitors and skip Claude/Grok/Pi
user-config repair during bootstrap when those agents are off.
EOF
)"
```

---

### Task 4: Settings 窗口 UI

**Files:**
- Create: `src/macos/Sources/AgentHaloMac/SettingsWindowController.swift`
- Modify: `src/shared/locales/zh.json`
- Modify: `src/shared/locales/en.json`
- Modify: `src/macos/Sources/AgentHaloCore/locales/zh.json`（本地跑 checks 前执行 `bash scripts/build-macos.sh` 的 locale copy，或手动与 shared 保持一致；**源文件是 shared**）
- Modify: `src/macos/Sources/AgentHaloMac/HaloInteractionChecks.swift`
- Modify: `src/macos/Sources/AgentHaloMac/AppDelegate.swift`（先加 `showSettings()` 骨架，完整菜单入口在 Task 5）

**Interfaces:**
- Consumes: `HaloSettings`、`StartupManager`、`L10n`、`AgentKind.menuTitle`、`AgentIconAssets`（可复用 DetailsPanel 同文件的 `AgentIconAssets`，或抽成 `internal enum`；若跨文件访问受限，把 `AgentIconAssets` 改为 `enum` 非 private，或在 Settings 内复制 `url(named:)` 逻辑到同一 `AgentIconAssets` 改成 file-internal → 提升为 `enum AgentIconAssets` without `private`）
- Produces:
  - `final class SettingsWindowController: NSWindowController`
  - `var onSettingsChanged: ((HaloSettings) -> Void)?`
  - `var onLaunchAtLoginChanged: ((Bool) -> Void)?`
  - `var onResetPosition: (() -> Void)?`
  - `func present(settings: HaloSettings, launchAtLogin: Bool)`
  - `func refresh(settings: HaloSettings, launchAtLogin: Bool)`
  - Panel：`.titled + .closable`，无 `.nonactivatingPanel`，`becomesKeyOnlyIfNeeded = false`，`level = haloLevel + 1`
  - Esc / ⌘W 关闭
  - 胶囊：`allCases`，可换行；只剩一个已选不可点灭
  - 页脚：`L10n.shared.format("settings.about.version", version)`，version = `CFBundleShortVersionString` ?? `CFBundleVersion`

Locale keys（写入 **shared** 再 copy）：

| Key | zh | en |
|-----|----|----|
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

- [ ] **Step 1: 写失败检查**

```swift
@MainActor
private func testSettingsWindowRejectsClearingLastAgent() {
    let controller = SettingsWindowController()
    var settings = HaloSettings(focusedAgent: .codex, enabledAgents: [.codex])
    var emitted: HaloSettings?
    controller.onSettingsChanged = { emitted = $0 }
    controller.present(settings: settings, launchAtLogin: false)
    controller.toggleAgentForTesting(.codex)
    expect(emitted == nil, "the last enabled agent cannot be turned off")
    expect(
        controller.enabledAgentsForTesting,
        [.codex],
        "UI still shows Codex enabled"
    )
}

@MainActor
private func testSettingsWindowUsesKeyPanelAboveHalo() {
    let controller = SettingsWindowController()
    controller.present(settings: HaloSettings(), launchAtLogin: false)
    guard let panel = controller.window else {
        fatalError("settings window should exist")
    }
    expect(panel.styleMask.contains(.titled), "settings is a titled panel")
    expect(panel.styleMask.contains(.closable), "settings can close")
    expect(!panel.styleMask.contains(.nonactivatingPanel), "settings must be able to become key")
    expect(panel.level.rawValue > NSWindow.Level.floating.rawValue, "settings sits above the halo")
}
```

给 controller 加 testing hooks：`toggleAgentForTesting`、`enabledAgentsForTesting`。

- [ ] **Step 2: 编译确认失败**

```bash
cd src/macos && swift build --target AgentHaloMac
```

Expected: `SettingsWindowController` 不存在。

- [ ] **Step 3: 实现窗口**

布局按 spec 线框图。实现要点：

- `NSPanel(contentRect:styleMask:[.titled, .closable], backing:.buffered, defer:false)`
- `isFloatingPanel = true` 可选；**level 必须** `NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)`
- `becomesKeyOnlyIfNeeded = false`
- 胶囊：`NSButton` checkbox 或自定义 click view；`allCases` 放进 `NSStackView` `.leading` + `.width` 约束，`stack.detachesHiddenViews` + 换行用第二个 stack 或 `NSGrid`；最简单：垂直换行用两个水平 stack，或单 `NSStackView` 设为满宽自动换行（AppKit 无内置 wrap — 用手动：一个 `NSView` + 逐个胶囊 `origin` 按剩余宽度折行）。
- 改 enabled：`settings.setAgent(agent, enabled:)`；若 `isAgentEnabled` 未变（关最后一个）则不回调。
- 置顶 / 菜单栏图标 / 尺寸 / 语言改 `HaloSettings` 后 `onSettingsChanged`。
- 开机启动只调 `onLaunchAtLoginChanged`。
- 重置只调 `onResetPosition`。
- 关闭：`windowShouldClose`；`keyDown` / `performKeyEquivalent` 处理 Esc 与 ⌘W。
- `present`：若 window 已在则 `refresh` + `makeKeyAndOrderFront`；居中 `NSScreen.main?.visibleFrame`。
- 版本：

```swift
let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    ?? ""
```

AppDelegate 先加：

```swift
private var settingsWindowController: SettingsWindowController?

func showSettings() {
    if settingsWindowController == nil {
        let controller = SettingsWindowController()
        controller.onSettingsChanged = { [weak self] next in self?.applySettingsFromWindow(next) }
        controller.onLaunchAtLoginChanged = { enabled in
            StartupManager.setEnabled(enabled, appBundleURL: Bundle.main.bundleURL)
        }
        controller.onResetPosition = { [weak self] in self?.escapeOffscreen() }
        settingsWindowController = controller
    }
    settingsWindowController?.present(
        settings: settings,
        launchAtLogin: StartupManager.isEnabled()
    )
}

private func applySettingsFromWindow(_ next: HaloSettings) {
    let normalized = next.normalized()
    let previous = settings
    settings = normalized
    settingsStore.save(settings)
    // 完整副作用（toggle 宽度、monitors、status item、levels）在 Task 5 收口；
    // 本任务至少：applyHaloSize、applyWindowLevels、语言、DetailsPanel.setEnabledAgents
    if previous.haloSize != settings.haloSize {
        applyHaloSize(CGFloat(settings.haloSize))
    }
    if previous.language != settings.language {
        L10n.shared.setLanguage(settings.language)
    }
    if previous.alwaysOnTop != settings.alwaysOnTop {
        applyWindowLevels()
    }
    detailsPanel.setEnabledAgents(settings.enabledAgents, focused: settings.focusedAgent)
}
```

`applyWindowLevels` 现只设 halo/details：本任务补上 `settingsWindowController?.window?.level = Self.haloWindowLevel(...) + 1`。

语言 observer 里若 settings 窗开着，调用 `refresh`。

- [ ] **Step 4: 编译通过**

```bash
cd src/macos && swift build --target AgentHaloMac
```

Expected: PASS。

- [ ] **Step 5: Commit**

```bash
git add src/macos/Sources/AgentHaloMac/SettingsWindowController.swift \
        src/macos/Sources/AgentHaloMac/AppDelegate.swift \
        src/macos/Sources/AgentHaloMac/HaloInteractionChecks.swift \
        src/shared/locales/zh.json src/shared/locales/en.json \
        src/macos/Sources/AgentHaloCore/locales/zh.json \
        src/macos/Sources/AgentHaloCore/locales/en.json
git commit -m "$(cat <<'EOF'
feat(macos): add settings window for agents and preferences

Introduce a key NSPanel above the halo for enabled agents, halo size,
language, always-on-top, menu bar icon, launch at login, and reset.
EOF
)"
```

locale 副本：改 shared 后运行 `cp src/shared/locales/*.json src/macos/Sources/AgentHaloCore/locales/` 再 add，避免 verify 失败。

---

### Task 5: 菜单精简、设置入口、菜单栏图标显隐

**Files:**
- Modify: `src/macos/Sources/AgentHaloMac/AppDelegate.swift`
- Modify: `src/macos/Sources/AgentHaloMac/HaloInteractionChecks.swift`

**Interfaces:**
- Consumes: `showSettings()`、`settings.showMenuBarIcon`、`SettingsWindowController`
- Produces:
  - `statusItem: NSStatusItem?`
  - `applyMenuBarIconVisibility()`：true → create；false → `removeStatusItem` + nil；再 create 时 `lastStatusMenuSignature = nil`
  - `makeControlMenu()`：移除启动 / 尺寸 / 语言；保留置顶、暂停、监控对象（仅 enabled）、重置、预览、**设置…**、退出
  - 监控对象只 `addFocusedAgentItem` enabled 项
  - 启动时按 `showMenuBarIcon` 决定是否 `createStatusItem()`
  - `applySettingsFromWindow` 收口：禁用立刻 empty（已由 tick+monitor）、`applyMenuBarIconVisibility`、focus 变化 usage、重新启用 `requestRefresh`

- [ ] **Step 1: 改失败的菜单检查**

更新 `testHaloContextMenuContainsCurrentControls`：

- **删除**对 `halo.size` 滑块、启动项、语言子菜单的断言。
- **增加**：含 `L10n.shared["menu.settings"]`；含 `menu.always_on_top`、`menu.escape_offscreen`、`menu.pause_monitor`、`menu.preview_status`、`menu.quit`。
- **增加**：不含 `menu.launch_at_startup`、`menu.language`、`halo.size`。

新增：

```swift
@MainActor
private func testFocusSubmenuListsOnlyEnabledAgents() {
    let delegate = AppDelegate()
    delegate.applyEnabledAgentsForTesting([.codex, .pi])
    let menu = delegate.makeHaloContextMenu()
    let focus = menu.items.first { $0.title == L10n.shared["menu.focus_target"] }
    let titles = focus?.submenu?.items.map(\.title) ?? []
    expect(titles, ["Codex", "Pi"], "focus submenu follows enabledAgents")
}

@MainActor
private func testSettingsMenuItemOpensSettingsWindow() {
    let delegate = AppDelegate()
    let menu = delegate.makeHaloContextMenu()
    expect(
        menu.items.contains { $0.title == L10n.shared["menu.settings"] },
        "control menu includes Settings…"
    )
}
```

`testFocusSubmenuIncludesGrok` / `testFocusSubmenuMarksCodexInitially`：默认 `allCases` 仍含 Grok/Pi，保持四项；若有写死三项则改为四项。

- [ ] **Step 2: 编译/跑检查确认旧菜单断言失败**

```bash
cd src/macos && swift build --target AgentHaloMac
```

先改测试再改菜单，使「仍含 halo.size」在实现后变绿、实现前旧测试若仍存在会红。

- [ ] **Step 3: 改菜单与 status item**

`statusItem` 改为 `NSStatusItem?`。所有 `updateStatusIcon` / `updateStatusMenu` `guard let statusItem else { return }`。

```swift
private func applyMenuBarIconVisibility() {
    if settings.showMenuBarIcon {
        if statusItem == nil {
            lastStatusMenuSignature = nil
            createStatusItem()
        }
        updateStatusMenu()
        updateStatusIcon()
    } else if let item = statusItem {
        NSStatusBar.system.removeStatusItem(item)
        statusItem = nil
        lastStatusMenuSignature = nil
    }
}
```

`applicationDidFinishLaunching`：不要无条件 `createStatusItem()`，改调 `applyMenuBarIconVisibility()`。

`makeControlMenu` 顺序：置顶 → 暂停 → 监控对象（循环 `settings.enabledAgents`）→ 逃离 → 预览 → separator → 设置…（`#selector(openSettings)`）→ 退出。

`@objc private func openSettings() { showSettings() }`

`applySettingsFromWindow` 补全：

```swift
private func applySettingsFromWindow(_ next: HaloSettings) {
    let previous = settings
    settings = next.normalized()
    settingsStore.save(settings)
    if previous.haloSize != settings.haloSize {
        applyHaloSize(CGFloat(settings.haloSize))
    } else {
        settingsStore.save(settings) // applyHaloSize 已防抖保存时可省略重复
    }
    if previous.language != settings.language {
        L10n.shared.setLanguage(settings.language)
    }
    applyWindowLevels()
    applyMenuBarIconVisibility()
    detailsPanel.setEnabledAgents(settings.enabledAgents, focused: settings.focusedAgent)
    if previous.focusedAgent != settings.focusedAgent {
        setFocusedAgent(settings.focusedAgent)
    }
    for agent in AgentKind.allCases {
        let nowOn = settings.isAgentEnabled(agent)
        let wasOn = previous.isAgentEnabled(agent)
        if nowOn && !wasOn {
            switch agent {
            case .claudeCode: claudeActivityMonitor.requestRefresh()
            case .grok: grokActivityMonitor.requestRefresh()
            case .pi: piActivityMonitor.requestRefresh()
            case .codex: break
            }
        }
    }
    lastStatusMenuSignature = nil
    tick()
    settingsWindowController?.refresh(settings: settings, launchAtLogin: StartupManager.isEnabled())
}
```

注意避免 `setFocusedAgent` 与 `applySettingsFromWindow` 互相重入：`setFocusedAgent` 在 focus 未变时应只 refresh，不要再调 `applySettingsFromWindow`。

- [ ] **Step 4: 编译**

```bash
cd src/macos && swift build --target AgentHaloMac
```

Expected: PASS。

- [ ] **Step 5: Commit**

```bash
git add src/macos/Sources/AgentHaloMac/AppDelegate.swift \
        src/macos/Sources/AgentHaloMac/HaloInteractionChecks.swift
git commit -m "$(cat <<'EOF'
feat(macos): open settings from a slimmer control menu

Move size, language, and launch-at-login into Settings, add a Settings
item, and allow hiding the status item without losing right-click access.
EOF
)"
```

---

### Task 6: 验收收口与 verify

**Files:**
- Modify: 仅修正 Task 1–5 遗漏（locales 同步、spec 状态行、漏测）
- Modify: `docs/superpowers/specs/2026-08-01-macos-enabled-agents-settings-design.md` 文档状态改为「实施计划见 …」

**Interfaces:**
- Consumes: 前五任务全部 API
- Produces: `scripts/run-macos.sh --verify` 通过（locales 一致 + packaged checks）

- [ ] **Step 1: 对照 spec 清单自检（不要新功能）**

逐项确认已有任务覆盖：

| Spec | Task |
|------|------|
| enabledAgents + showMenuBarIcon + 规范化 | 1 |
| 切换条 36×n / 全开 144 | 2 |
| 停采 + empty + bootstrap 跳过 configure | 3 |
| setFocusedAgent no-op / Pi 无 usage | 3 |
| 设置窗 UI + key/level/Esc/⌘W + 换行胶囊 | 4 |
| 置顶双入口、重置双入口、关于版本 | 4–5 |
| 菜单精简 + 设置… + 关托盘 | 5 |
| shared locales | 4 |
| applyWindowLevels 含设置窗 | 4 |
| lastStatusMenuSignature 重置 | 5 |
| 语言变更刷新设置窗 | 4 |

缺什么补最小测试，不要扩 scope。

- [ ] **Step 2: 同步 locales 并跑 verify**

```bash
cp src/shared/locales/zh.json src/macos/Sources/AgentHaloCore/locales/zh.json
cp src/shared/locales/en.json src/macos/Sources/AgentHaloCore/locales/en.json
cd src/macos && swift run AgentHaloCoreChecks
bash ./scripts/run-macos.sh --verify
```

Expected: CoreChecks 无 fatalError；verify 的 locale `cmp` 通过且 packaged verification 退出 0。

- [ ] **Step 3: 更新 spec 文档状态**

`docs/superpowers/specs/2026-08-01-macos-enabled-agents-settings-design.md`：

```markdown
- 状态：设计已确认；实施计划见 [2026-08-01-macos-enabled-agents-settings-implementation.md](../plans/2026-08-01-macos-enabled-agents-settings-implementation.md)（**仅 macOS**）
```

- [ ] **Step 4: 手动清单（实现者在真机点一遍）**

1. 只勾 Codex → 切换条约 36pt；Claude/Grok/Pi 不轮询。  
2. 再勾 Claude、Pi → 可切换。  
3. 默认四开、条宽 144。  
4. 关菜单栏图标 → 托盘消失；设置或右键可再打开。  
5. 设置不被光环挡住；Esc / ⌘W / 红点可关。  
6. 尺寸 / 语言 / 开机 / 置顶与旧菜单一致。  
7. 重置位置双入口。  
8. 页脚版本号。

- [ ] **Step 5: Commit**

```bash
git add docs/superpowers/specs/2026-08-01-macos-enabled-agents-settings-design.md \
        src/macos/Sources/AgentHaloCore/locales/zh.json \
        src/macos/Sources/AgentHaloCore/locales/en.json
# 加上本任务实际改动的漏测文件
git commit -m "$(cat <<'EOF'
docs: point settings spec at the macOS implementation plan

Record the plan link and keep packaged locales in sync after verify.
EOF
)"
```

---

## Spec 覆盖自检

- 数据模型 / 迁移 / 至少 1 个 / allCases 顺序 → Task 1  
- 动态切换条与 144 全开 → Task 2  
- 监控、usage、hooks/bootstrap、Pi nil usage、focus no-op → Task 3  
- 设置窗区块、层级、accessory、关于、i18n keys → Task 4  
- 菜单精简、双入口、status item remove+create → Task 5  
- verify / 手动成功标准 → Task 6  

无 TBD /「类似 Task N」实现依赖；后续任务用的类型名与 Task 1–4 的 `normalized` / `setEnabledAgents` / `showSettings` / `applyMenuBarIconVisibility` 一致。
