# 隐藏详情面板 Provider 头部实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 从 macOS 详情面板移除 Provider、Plan 和用量告警图标，同时完整保留后台用量数据与解析接口。

**Architecture:** UI 边界只在 `DetailsPanel`：删除 `ProviderHeaderView` 的布局、渲染和测试专用访问入口，使状态和正文直接跟随代理切换行。`DetailsContentResolver` 及其 `DetailsPanelViewModel` 继续生成 Provider、Plan、告警数据，核心自检继续验证这些值，确保本次只改变展示层。

**Tech Stack:** Swift、AppKit、Swift Package Manager、AgentHalo macOS executable self-checks。

## Global Constraints

- 仅修改 macOS 详情面板；Windows 端和后台用量接口不得改变。
- OAuth 与 API Key 两种模型的 `providerName`、`planName`、`usageWarning` 继续由 `DetailsContentResolver` 生成。
- Provider、Plan、黄色告警图标均不得作为详情面板可见子视图存在。
- 通过 `swift run AgentHaloMac --self-check`、`swift run AgentHaloCoreChecks`、`swift build` 与 `git diff --check` 验证。

---

## 文件结构

- 修改 `src/macos/Sources/AgentHaloMac/DetailsPanel.swift`：移除仅用于 Provider/Plan/告警的 `ProviderHeaderView`、布局约束、渲染调用和测试探针；保留 `DetailsPanelViewModel` 的消费入口及正文渲染。
- 修改 `src/macos/Sources/AgentHaloMac/HaloInteractionChecks.swift`：用一个覆盖 OAuth 与 API Key 的隐藏回归替换五个旧 Provider 行展示断言。
- 不修改 `src/macos/Sources/AgentHaloCore/UsageMonitoring/DetailsContentResolver.swift`：现有 `testDetailsContentResolverWarningPriorityAndRedaction` 将继续覆盖后台告警生成。

### Task 1: 移除详情面板 Provider 头部并建立 UI 回归

**Files:**

- Modify: `src/macos/Sources/AgentHaloMac/HaloInteractionChecks.swift:47-51,829-929`
- Modify: `src/macos/Sources/AgentHaloMac/DetailsPanel.swift:4-12,22-194,455-526,619-718`
- Test: `src/macos/Sources/AgentHaloMac/HaloInteractionChecks.swift`

**Interfaces:**

- Consumes: `DetailsPanel.render(aggregate:model:)`, `DetailsPanelViewModel(providerName:planName:usageWarning:contextUsedPercent:body:)`。
- Produces: `DetailsPanel` 的顶层结构 `[.agentSwitcher, .statusTitle, .statusDetail, .usageBody, .sessionBody]`，其中没有 Provider 行或告警图标。
- Preserves: `DetailsContentResolver.resolve(...) -> DetailsPanelViewModel` 的全部字段和 `UsageMonitoringChecks.testDetailsContentResolverWarningPriorityAndRedaction()`。

- [x] **Step 1: 先写会失败的 UI 回归，并接入 self-check**

在 `runHaloInteractionChecks()` 中删除下列旧调用：

```swift
testDetailsPanelAlwaysShowsProviderRow()
testDetailsPanelShowsPlanOnlyForOAuth()
testDetailsPanelKeepsPlanNextToProvider()
testDetailsPanelKeepsWarningNextToProviderWithoutPlan()
testDetailsPanelShowsSingleAmberUsageWarning()
```

并在相同位置加入：

```swift
testDetailsPanelHidesProviderPlanAndWarning()
```

删除上述五个旧测试函数，替换为以下完整测试：

```swift
@MainActor
private func testDetailsPanelHidesProviderPlanAndWarning() {
    let panel = DetailsPanel()
    let warning = L10n.shared["usage.warning.network"]
    let expectedOrder: [DetailsPanelContentRole] = [
        .agentSwitcher, .statusTitle, .statusDetail, .usageBody, .sessionBody
    ]

    panel.render(
        aggregate: detailsAggregate(),
        model: usageDetailsModel(provider: "Codex", plan: "Plus", warning: warning)
    )

    expect(panel.contentOrderForTesting, expectedOrder, "details panel should omit the provider header")
    expect(!panel.usageGroupHiddenForTesting, "OAuth usage body should remain visible")
    let usageLabels = allDescendants(of: panel.contentView!).compactMap { ($0 as? NSTextField)?.stringValue }
    expect(!usageLabels.contains("Codex"), "details panel should not display the provider name")
    expect(!usageLabels.contains("Plus"), "details panel should not display the plan name")
    let usageWarningImages = allDescendants(of: panel.contentView!).compactMap { $0 as? NSImageView }
        .filter { $0.image?.accessibilityDescription == "exclamationmark.triangle.fill" }
    expect(usageWarningImages.isEmpty, "details panel should not display a usage warning icon")

    panel.render(
        aggregate: detailsAggregate(state: .idle, label: "OFFLINE"),
        model: sessionDetailsModel(provider: "Claude Code", plan: nil)
    )

    expect(panel.contentOrderForTesting, expectedOrder, "API details should also omit the provider header")
    expect(!panel.sessionGroupHiddenForTesting, "API session body should remain visible")
}
```

- [x] **Step 2: 运行 self-check，确认新测试因旧 UI 而失败**

Run:

```bash
swift run AgentHaloMac --self-check
```

Expected: 非零退出；`testDetailsPanelHidesProviderPlanAndWarning` 的 `details panel should omit the provider header` 断言失败，因为旧布局仍包含 `.provider`。

- [x] **Step 3: 做最小展示层实现**

在 `DetailsPanel.swift` 中完成以下精确删除，不触碰 `DetailsContentResolver.swift` 或 `DetailsPanelViewModel`：

```swift
// DetailsPanelContentRole：删除这一项。
case provider

// DetailsPanel 属性：删除这一项。
private let providerHeader = ProviderHeaderView()

// init()：删除这两行。
stack.addArrangedSubview(providerHeader)
stack.setCustomSpacing(3, after: providerHeader)

// init() 的 NSLayoutConstraint.activate([...])：删除这一行。
providerHeader.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -17),

// render(aggregate:model:)：删除整个 Provider 头部更新调用。
providerHeader.update(
    providerName: model.providerName,
    planName: model.planName,
    warning: model.usageWarning
)

// contentOrderForTesting：删除这一项映射。
if view === providerHeader { return .provider }
```

同时删除 `providerRowHeightForTesting`、`providerTextForTesting`、`planTextForTesting`、`providerPlanVisibleSpacingForTesting`、`providerWarningVisibleSpacingForTesting`、`planHiddenForTesting`、`warningHiddenForTesting`、`warningToolTipForTesting`、`warningAccessibilityLabelForTesting`、`warningColorForTesting`，并完整删除未再被使用的 `ProviderHeaderView` 类型。

- [x] **Step 4: 重新运行 self-check，确认 UI 回归通过**

Run:

```bash
swift run AgentHaloMac --self-check
```

Expected: 退出码 `0`；输出包含 `Halo interaction checks passed`，且新的隐藏回归与其余 macOS 交互检查全部通过。

- [x] **Step 5: 验证后台接口、编译和补丁完整性**

Run:

```bash
swift run AgentHaloCoreChecks
swift build
git diff --check
```

Expected: 三条命令均退出码 `0`；`AgentHaloCoreChecks` 覆盖 `DetailsContentResolver` 的计划与告警生成，`swift build` 成功编译 macOS 包，`git diff --check` 无空白错误。

- [x] **Step 6: 提交实现**

```bash
git add src/macos/Sources/AgentHaloMac/DetailsPanel.swift src/macos/Sources/AgentHaloMac/HaloInteractionChecks.swift
git commit -m "fix: hide provider header in details panel"
```
