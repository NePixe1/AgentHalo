# API Key 会话摘要卡（方案 B）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将非 OAuth（API Key）详情 body 从三行 `--` 键值表改为 **mode chip + 固定高度 body 槽位（Offline empty / Online session card）**，macOS 与 Windows 信息架构一致，Offline↔Working 面板与内矩形同高；**详情面板外框尺寸保持现网不变**（macOS 宽 278、拟合高 172；usage 与 session 同高）。

**Architecture:** 保持 `DetailsContentResolver` 的 `body: .session | .usage` 分流不变。仅在 UI 层重绘 session body：统一 `bodySlot`（高度常量 `H_body`），Offline 显示 empty 矩形，非 Offline 显示 session card；top row 在 session 路径显示 `API Key` chip。数据仍来自 `SessionDetailsSnapshot`。

**Tech Stack:** Swift 6 / AppKit（macOS）、C# / WPF（Windows）、共享 locale JSON、`AgentHaloMac --self-check`、`AgentHaloCoreChecks`、Windows `Diagnostics` / 构建脚本

**Spec:** [2026-08-05-api-key-session-card-details-design.md](../specs/2026-08-05-api-key-session-card-details-design.md)

**Mock:** [docs/API_KEY_PANEL_MOCKUPS.html](../../API_KEY_PANEL_MOCKUPS.html)（方案 B）

## Global Constraints

- 只改 **API Key / 非 OAuth** 的 session 详情 UI；**OAuth usage / quota 视觉与数据路径不变**。
- **详情面板外框尺寸相对现网不变（硬约束）**：
  - 宽度：macOS `panelWidth = 278`，禁止加宽。
  - 高度：macOS 拟合高锁定 **172**（`testDetailsPanelResizesHeightWithoutAnimation` 现网期望）。
  - OAuth usage 与 API Key session 切换后高度 **仍相等且均为 172**。
  - API Key Offline ↔ Online 高度均为 **172**。
  - mode chip 必须落在既有 top row 内，**不得**抬高顶栏。
  - `H_body` 取 70–72 使总高保持 172；若超高，压卡内 padding/字号，**禁止**改测试里的 `172` 迁就膨胀布局。
  - HTML mock 的 `min-height: 192` **仅示意结构**，不是产品目标高度。
  - Windows：保持现有 session/quota 区高度语义，总高不得明显膨胀。
- **不**新增网络请求、端点 host、会话时长、费用（方案 C 不做）。
- **不**改状态大标题文案为方案 E 软化文案；继续 `aggregate.label` + 现有 detail 本地化。
- Offline 判定：`state == idle && label == "OFFLINE"`（与现网一致）。
- Offline soft empty 与 STANDBY / 字段全空 **同一文案**：`session.empty.api_key`（无会话 / No session），UI 前缀 `○ `。
- 标题 **单行省略** + tooltip 全文；body 内 empty 与 card **同高常量**。
- i18n 以 `src/shared/locales/{en,zh}.json` 为源，**同步** macOS Core locales 与 Windows locales（`scripts/check_shared.py` 会比对）。
- 双端信息架构一致；允许控件实现差异。
- 每项任务：先失败测试（能测则测）→ 最小实现 → 验证 → 提交；`git add` 仅本任务文件。
- macOS 验证命令：

```bash
cd src/macos
swift run AgentHaloCoreChecks
swift run AgentHaloMac --self-check
swift build
```

- Windows 验证（有 Windows 环境时）：

```powershell
# 按 scripts/build-windows.ps1 构建后
.\outputs\AgentHalo\AgentHalo.exe --self-check
```

在仅 macOS 开发机上：完成 Windows 代码与可编译性检查；PR 注明需 Windows 构建与目视验收。

---

## 目标文件总览

```text
修改:
  src/shared/locales/en.json
  src/shared/locales/zh.json
  src/macos/Sources/AgentHaloCore/locales/en.json
  src/macos/Sources/AgentHaloCore/locales/zh.json
  src/windows/locales/en.json
  src/windows/locales/zh.json
  src/macos/Sources/AgentHaloMac/DetailsPanel.swift
  src/macos/Sources/AgentHaloMac/HaloInteractionChecks.swift
  src/windows/DetailsWindow.cs
  # 可选若需诊断断言:
  src/windows/Diagnostics.cs

不改（除非为编译所必需的最小连带）:
  AccessModeResolver / Usage*Provider / Session 采集逻辑
  OAuth quota 渲染路径语义
  agent-halo.v2.json 动画参数
```

锁定常量（实现时写入代码，双端同语义）：

```text
panelWidth = 278          // 不变
panelFittedHeight = 172   // macOS 现网；usage 与 session 均为此值；禁止修改测试期望迁就布局
H_body = 70..72 pt/dip    // session card / empty 内矩形；选值须使拟合总高仍为 172
// Offline 与 Working 的 frameHeight 必须相等且 == 172
// top row 高度与现网一致（≈24）；mode chip 不增高
```

锁定 i18n：

```text
access.mode.api_key:
  zh: "API Key"
  en: "API Key"

session.empty.api_key:
  zh: "无会话"
  en: "No session"
```

Empty 前导装饰 `○ ` 由 UI 层拼接（不进 locale），双端一致：`"○ " + L10n["session.empty.api_key"]`。

锁定测试观察面（macOS，替换旧三行 role）：

```swift
enum DetailsPanelSessionBodyRole {
    case empty      // offline empty 矩形可见
    case sessionCard
    case unknown
}

// ForTesting 建议:
// apiKeyChipHiddenForTesting: Bool
// apiKeyChipTitleForTesting: String
// sessionBodyModeForTesting: DetailsPanelSessionBodyRole  // empty | sessionCard
// sessionCardTitleForTesting / sessionCardModelForTesting / sessionCardTokensForTesting
// sessionCardTitleToolTipForTesting
// sessionBodySlotHeightForTesting: CGFloat  // == 72
// emptyBodyHeightForTesting / sessionCardHeightForTesting
```

---

### Task 1: 共享 i18n key

**Files:**
- Modify: `src/shared/locales/en.json`
- Modify: `src/shared/locales/zh.json`
- Modify: `src/macos/Sources/AgentHaloCore/locales/en.json`
- Modify: `src/macos/Sources/AgentHaloCore/locales/zh.json`
- Modify: `src/windows/locales/en.json`
- Modify: `src/windows/locales/zh.json`

**Interfaces:**
- Produces: `L10n["access.mode.api_key"]`、`L10n["session.empty.api_key"]`（macOS `L10n.shared` / Windows `L10n.Instance`）

- [ ] **Step 1: 在 shared en/zh 写入 key**

在 `metadata.separator` 段落后插入：

```json
  "access.mode.api_key": "API Key",
  "session.empty.api_key": "No session",
```

```json
  "access.mode.api_key": "API Key",
  "session.empty.api_key": "无会话",
```

- [ ] **Step 2: 原样同步到 macOS Core 与 Windows locales**

```bash
cp src/shared/locales/en.json src/macos/Sources/AgentHaloCore/locales/en.json
cp src/shared/locales/zh.json src/macos/Sources/AgentHaloCore/locales/zh.json
cp src/shared/locales/en.json src/windows/locales/en.json
cp src/shared/locales/zh.json src/windows/locales/zh.json
```

（若平台文件含额外 key：改为手工合并两 key，保持与 shared 一致。）

- [ ] **Step 3: 校验 shared 一致性**

```bash
python3 scripts/check_shared.py
```

Expected: 通过（或仅报与本改动无关的既有问题；locales 三份 en/zh 内容一致）。

- [ ] **Step 4: Commit**

```bash
git add src/shared/locales/en.json src/shared/locales/zh.json \
  src/macos/Sources/AgentHaloCore/locales/en.json \
  src/macos/Sources/AgentHaloCore/locales/zh.json \
  src/windows/locales/en.json src/windows/locales/zh.json
git commit -m "$(cat <<'EOF'
feat: add API Key session-card i18n keys

EOF
)"
```

---

### Task 2: macOS 交互契约改为 session card / empty（先失败）

**Files:**
- Modify: `src/macos/Sources/AgentHaloMac/HaloInteractionChecks.swift`
- Modify: `src/macos/Sources/AgentHaloMac/DetailsPanel.swift`（仅测试枚举/访问器签名，可先加 stub 使编译通过但断言失败）

**Interfaces:**
- Consumes: 现有 `sessionDetailsModel(...)`、`detailsAggregate(...)` helper
- Produces: 新 `DetailsPanelSessionBodyRole` 与 `*ForTesting` 访问器（实现可先返回旧行为使测试失败）

- [ ] **Step 1: 更新 role 枚举与测试期望**

将 `DetailsPanelSessionBodyRole` 从 `.separator / .sessionTitle / .model / .tokens` 改为：

```swift
enum DetailsPanelSessionBodyRole: Equatable {
    case empty
    case sessionCard
    case unknown
}
```

重写 / 替换这些测试（名称可保留或重命名，保持注册在 self-check 列表中）：

1. **`testDetailsPanelShowsThreeIndependentSessionRows`** → 改为 card 断言，例如：

```swift
@MainActor
private func testDetailsPanelShowsSessionCardForAPIKey() {
    let panel = DetailsPanel()
    panel.render(
        aggregate: detailsAggregate(),
        model: sessionDetailsModel(session: SessionDetailsSnapshot(
            projectName: "AgentHalo",
            sessionTitle: "Redesign details",
            modelName: "gpt-5.5",
            inputTokens: 38_000,
            outputTokens: 1_200
        ))
    )

    expect(!panel.apiKeyChipHiddenForTesting, "API Key body should show mode chip")
    expect(panel.apiKeyChipTitleForTesting, L10n.shared["access.mode.api_key"], "mode chip title")
    expect(panel.sessionBodyModeForTesting, .sessionCard, "online API body is session card")
    expect(panel.sessionCardTitleForTesting, "Redesign details", "card title")
    expect(panel.sessionCardModelForTesting, "gpt-5.5", "card model")
    expect(panel.sessionCardTokensForTesting, "↑ 38k  ·  ↓ 1.2k", "card tokens")
    expect(panel.sessionCardTitleToolTipForTesting, "Redesign details", "title tooltip")
    expect(panel.sessionBodySlotHeightForTesting, 72, "body slot height constant")
    expect(panel.sessionCardHeightForTesting, 72, "card matches body slot height")
}
```

2. **`testDetailsPanelLeavesMissingSessionTitleEmpty`**：missing title → card 标题 `"--"`，且 `sessionBodyMode == .sessionCard`。

3. **`testDetailsPanelClearsContextAndSessionRowsOffline`** → Offline empty：

```swift
expect(panel.contextPillHiddenForTesting, "offline should clear context")
expect(!panel.apiKeyChipHiddenForTesting, "offline API Key still shows mode chip")
expect(panel.sessionBodyModeForTesting, .empty, "offline shows empty body")
expect(
    panel.sessionEmptyTextForTesting,
    "○ " + L10n.shared["session.empty.api_key"],
    "offline empty copy"
)
// 不得再断言三行 --
expect(panel.sessionBodySlotHeightForTesting, 72, "empty slot height")
expect(panel.emptyBodyHeightForTesting, 72, "empty rect matches card height")
```

4. **`testDetailsPanelKeepsUsageAndSessionBodiesMutuallyExclusive`**：
   - usage 时 `apiKeyChipHidden == true`，session group 隐藏
   - session 时 chip 显示，usage 隐藏

5. **新增同高测试** `testDetailsPanelAPIKeyOfflineAndOnlineShareHeight`：

```swift
@MainActor
private func testDetailsPanelAPIKeyOfflineAndOnlineShareHeight() {
    let panel = DetailsPanel()
    let online = sessionDetailsModel(session: SessionDetailsSnapshot(
        sessionTitle: "Redesign details",
        modelName: "gpt-5.5",
        inputTokens: 38_000,
        outputTokens: 1_200
    ))
    panel.render(aggregate: detailsAggregate(), model: online)
    panel.contentView?.layoutSubtreeIfNeeded()
    let onlineHeight = panel.frameHeightForTesting
    let onlineSlot = panel.sessionBodySlotHeightForTesting

    panel.render(
        aggregate: detailsAggregate(state: .idle, label: "OFFLINE"),
        model: sessionDetailsModel(context: nil, session: SessionDetailsSnapshot())
    )
    panel.contentView?.layoutSubtreeIfNeeded()
    expect(panel.frameHeightForTesting, onlineHeight, "API Key offline/online panel height")
    expect(panel.frameHeightForTesting, 172, "API Key panel must keep production fitted height 172")
    expect(onlineHeight, 172, "online API Key panel height locked to 172")
    expect(panel.sessionBodySlotHeightForTesting, onlineSlot, "body slot height stable")
    expect(panel.sessionBodyModeForTesting, .empty, "offline mode")
}
```

6. 所有仍引用 `sessionTitleValueForTesting` / `sessionBodyOrderForTesting` 含 separator 的测试一并改到新访问器。

- [ ] **Step 2: 在 DetailsPanel 增加测试访问器 stub（若尚未实现 UI）**

最小编译通过：chip 默认 hidden 或旧三行仍在，使 Step 1 断言失败。

示例 stub：

```swift
var apiKeyChipHiddenForTesting: Bool { true }
var apiKeyChipTitleForTesting: String { "" }
var sessionBodyModeForTesting: DetailsPanelSessionBodyRole { .unknown }
var sessionCardTitleForTesting: String { sessionTitleRow.valueForTesting }
// ... 其余映射旧行或返回 0，确保测试失败信息清晰
```

- [ ] **Step 3: 跑 self-check 确认失败**

```bash
cd src/macos && swift run AgentHaloMac --self-check 2>&1 | tail -80
```

Expected: 新 API Key / empty / 同高相关 assert 失败。

- [ ] **Step 4: Commit 测试契约**

```bash
git add src/macos/Sources/AgentHaloMac/HaloInteractionChecks.swift \
  src/macos/Sources/AgentHaloMac/DetailsPanel.swift
git commit -m "$(cat <<'EOF'
test: rewrite details session body contract for API Key card

EOF
)"
```

---

### Task 3: macOS DetailsPanel 实现方案 B UI

**Files:**
- Modify: `src/macos/Sources/AgentHaloMac/DetailsPanel.swift`

**Interfaces:**
- Consumes: `DetailsPanelViewModel.body == .session`、`SessionDetailsSnapshot`、`isOffline`
- Produces: mode chip + bodySlot（empty | card）；测试访问器返回真实值

- [ ] **Step 1: Top row 增加 API Key chip**

在 `makeTopRow()` 中：

- 新增 `apiKeyChip`（`NSTextField` 或圆角 `NSView` + label），文案 `L10n.shared["access.mode.api_key"]`。
- 布局：`agentToggle` 左；右侧为 `contextPill` **左侧**再放 chip（从右到左：chip 最右，context 在 chip 左）。Mock 顺序为 `[ctx%][API Key]`，chip 在最右。
- 约束：chip 与 context 间距约 6；chip 与 toggle 不重叠。
- `render`：`.session` 时 `apiKeyChip.isHidden = false`；`.usage` 时 `true`。

参考样式（可微调以贴合现有 popover）：

```swift
// 高度 22，圆角 11，字号 10.5–11 semibold
// 背景 rgba 接近 (52,158,199,0.10)，描边 alpha 0.22
```

- [ ] **Step 2: 用 bodySlot 替换三行 metadataGroup 结构**

移除（或停用）`sessionTitleRow` / `modelRow` / `tokenRow` / separators 作为主 UI。

新增：

```swift
private static let sessionBodyHeight: CGFloat = 72  // 若拟合总高 > 172，降到 70 等直到 == 172

private let bodySlot = NSView()          // 固定高度 H_body（默认 72）
private let emptyBody = /* 虚线边框容器 + 居中 label */
private let sessionCard = /* 圆角卡片：titleLabel + modelChip + tokenLabel */
```

- `bodySlot` 高度约束 `== H_body`；**整板 `resizeToFitContent` 后高度必须仍为 172**。
- mode chip 放进既有 top row，高度 ≤ 24，不新增 arranged 间距。
- `emptyBody` 与 `sessionCard` 均 pin 到 bodySlot 四边（或同高同宽居中），互斥 `isHidden`。
- `renderSession(_:isOffline:)`：

```swift
if isOffline {
    emptyBody.isHidden = false
    sessionCard.isHidden = true
    emptyLabel.stringValue = "○ " + L10n.shared["session.empty.api_key"]
    return
}
emptyBody.isHidden = true
sessionCard.isHidden = false
titleLabel.stringValue = displayValue(session.sessionTitle)  // "--" if nil
titleLabel.toolTip = session.sessionTitle
titleLabel.lineBreakMode = .byTruncatingTail
// 单行：usesSingleLineMode / maximumNumberOfLines = 1
modelLabel.stringValue = displayValue(session.modelName)
if session.inputTokens != nil || session.outputTokens != nil {
    tokenLabel.attributedStringValue = formatTokenAttributedString(...)
} else {
    tokenLabel.stringValue = "↑ --  ·  ↓ --" // 或与 formatToken 统一
}
```

- `contentOrderForTesting`：session body 仍映射到承载 `bodySlot` 的 arranged 视图（可继续叫 `metadataGroup` 包装 bodySlot，或改名为 `sessionBodyGroup` 并更新 `DetailsPanelContentRole.sessionBody` 判定）。

- [ ] **Step 3: 接通测试访问器**

使 Task 2 中断言读取真实 chip / mode / 高度 / 文案。

- [ ] **Step 4: 跑 self-check**

```bash
cd src/macos && swift run AgentHaloMac --self-check
```

Expected: Task 2 新增/改写的 session card 测试通过；OAuth usage 测试不回归。

- [ ] **Step 5: Commit**

```bash
git add src/macos/Sources/AgentHaloMac/DetailsPanel.swift \
  src/macos/Sources/AgentHaloMac/HaloInteractionChecks.swift
git commit -m "$(cat <<'EOF'
feat(macos): API Key details use session card and empty body

EOF
)"
```

---

### Task 4: macOS 高度与 OAuth 回归加固

**Files:**
- Modify: `src/macos/Sources/AgentHaloMac/HaloInteractionChecks.swift`（若 Task 2 同高测试仍需微调期望值）
- Modify: `src/macos/Sources/AgentHaloMac/DetailsPanel.swift`（仅当高度仍跳变）

**Interfaces:**
- 同 Task 3

- [ ] **Step 1: 确认 resize 测试仍成立**

检查 `testDetailsPanelResizesHeightWithoutAnimation`：

- **必须保留** `usageCall.frame.height == 172` 与 `sessionCall.frame.height == usageHeight`（同为 172）。
- **禁止**把 `172` 改成更大值来迁就 session card；若失败，回到 Task 3 减小 `H_body` / 边距 / 字号直到拟合 172。
- 仍须保留：`animate == false`、`display == false`、top edge 不变、usage ↔ session 切换仍 resize。

- [ ] **Step 2: 全量 macOS 检查**

```bash
cd src/macos
swift run AgentHaloCoreChecks
swift run AgentHaloMac --self-check
swift build
```

Expected: 全部 exit 0。

- [ ] **Step 3: Commit（若有期望值修正）**

```bash
git add src/macos/Sources/AgentHaloMac/DetailsPanel.swift \
  src/macos/Sources/AgentHaloMac/HaloInteractionChecks.swift
git commit -m "$(cat <<'EOF'
test(macos): lock API Key panel height and resize expectations

EOF
)"
```

---

### Task 5: Windows DetailsWindow 方案 B

**Files:**
- Modify: `src/windows/DetailsWindow.cs`

**Interfaces:**
- Consumes: 现有 `IsOfflineAggregate`、`ClaudeCodeMetrics` / Codex custom API metrics、Grok api-key 分支（若有）
- Produces: 与 macOS 同构的 API Key chrome（chip + empty/card + 固定 body 高）

- [ ] **Step 1: 增加控件字段**

在详情窗口构造中增加：

```csharp
// Mode chip
private Border apiKeyChip;
private TextBlock apiKeyChipText;

// Body slot
private Grid sessionBodySlot;          // Height = 72
private Border emptyBody;
private TextBlock emptyBodyText;
private Border sessionCard;
private TextBlock sessionCardTitle;
private TextBlock sessionCardModel;
private TextBlock sessionCardTokens;
```

将原 `claudeGroup` 内三行 Project/Model/Token（及 Codex custom 复用的行）**替换或隐藏**，改为上述 body slot。

注意：Windows 历史代码里 Claude/Codex-custom 共用 `claudeGroup` 行——统一改为 session card，**不再单独展示 Project 行**（与 macOS 已去掉 Project 行一致；卡片标题用 session title）。

- [ ] **Step 2: 布局**

Top 区域：agent switch 左；右 `StackPanel` Orientation=Horizontal：`contextMeter` + `apiKeyChip`（chip 最右）。

Body：

```csharp
sessionBodySlot.Height = 72; // 与 macOS H_body 同语义；总窗高不得明显膨胀
// emptyBody: dashed border, centered text
// sessionCard: filled border, title + footer (model chip + tokens)
// 保持既有 dataLayer / 内容区高度语义，禁止为 card 整体加高窗口
```

- [ ] **Step 3: 渲染分支**

```csharp
private void ShowSessionBody(bool showAPIKeyChip, bool offline,
    string title, string model, string tokens)
{
    quotaGroup.Visibility = Visibility.Hidden;
    // hide old row group if still present
    apiKeyChip.Visibility = showAPIKeyChip
        ? Visibility.Visible : Visibility.Collapsed;
    sessionBodySlot.Visibility = Visibility.Visible;

    if (offline)
    {
        emptyBody.Visibility = Visibility.Visible;
        sessionCard.Visibility = Visibility.Collapsed;
        emptyBodyText.Text = "○ " + L10n.Instance["session.empty.api_key"];
        return;
    }
    emptyBody.Visibility = Visibility.Collapsed;
    sessionCard.Visibility = Visibility.Visible;
    sessionCardTitle.Text = string.IsNullOrEmpty(title) ? "--" : title;
    sessionCardTitle.ToolTip = title;
    sessionCardModel.Text = string.IsNullOrEmpty(model) ? "--" : model;
    sessionCardTokens.Text = string.IsNullOrEmpty(tokens) ? "↑ --  ·  ↓ --" : tokens;
}
```

接线：

- `ApplyOfflinePlaceholders`：Claude 根据 `ClaudeCodeMetrics.IsCustomApi` 决定 chip；Codex-custom / 任何 API-key session 路径传 `showAPIKeyChip: true`；**禁止**再写三行 `"--"`。
- `RefreshClaudeDetails`：根据 `ClaudeCodeMetrics.IsCustomApi` 决定 chip；`ApplyCodexCustomMetrics` 传 `showAPIKeyChip: true`。
- OAuth `RefreshQuota` / Grok OAuth：`apiKeyChip.Visibility = Collapsed`，`sessionBodySlot` 隐藏，quota 显示（保持现状）。

Grok 若为 API Key 且无 usage：按 spec 走 session body；若当前 Windows 仅 OAuth weekly，保持既有 Grok OAuth 分支，**不要**给 Grok OAuth 加 chip。

- [ ] **Step 4: Token 格式**

复用现有 `FormatCompactNumber` 与 `↑ … · ↓ …` 字符串拼法，与 macOS `formatTokenAttributedString` 文本一致（Windows 可用单色 TextBlock 或两个 Run 上色，可选）。

- [ ] **Step 5: 本地构建或语法检查**

```powershell
# Windows
.\scripts\build-windows.ps1
.\outputs\AgentHalo\AgentHalo.exe --self-check
```

macOS 机上至少：

```bash
# 确保未破坏共享 locales
python3 scripts/check_shared.py
```

- [ ] **Step 6: Commit**

```bash
git add src/windows/DetailsWindow.cs
git commit -m "$(cat <<'EOF'
feat(windows): API Key details use session card and empty body

EOF
)"
```

---

### Task 6: Windows 可自动化断言（最小）+ 文档状态

**Files:**
- Modify: `src/windows/Diagnostics.cs`（仅当已有 Details 相关 Assert 或易加纯函数时）
- Modify: `docs/superpowers/specs/2026-08-05-api-key-session-card-details-design.md`（状态改为「实施中/已实现」可选）
- 可选：`docs/PRODUCT.md` 一句「API key 模式展示会话摘要卡」

**Interfaces:**
- 若抽出纯格式化/文案函数可测则测；**不**强制上 UI automation。

- [ ] **Step 1: 可选 Assert 文案 key 存在**

在 Diagnostics self-check 中：

```csharp
Assert(L10n.Instance["access.mode.api_key"] == "API Key"
    || !string.IsNullOrEmpty(L10n.Instance["access.mode.api_key"]),
    "access.mode.api_key locale");
Assert(!string.IsNullOrEmpty(L10n.Instance["session.empty.api_key"]),
    "session.empty.api_key locale");
```

- [ ] **Step 2: 目视清单（写入 PR 描述，不必代码化）**

```text
[ ] Claude API Key Offline：chip + empty，无三行 --
[ ] Claude API Key Working：card 标题/模型/tokens，高度与 Offline 一致
[ ] Codex custom API：同上
[ ] OAuth Codex/Claude/Grok：无 chip，quota 正常
[ ] 对照 docs/API_KEY_PANEL_MOCKUPS.html 方案 B
```

- [ ] **Step 3: Commit**

```bash
git add src/windows/Diagnostics.cs docs/PRODUCT.md \
  docs/superpowers/specs/2026-08-05-api-key-session-card-details-design.md
git commit -m "$(cat <<'EOF'
test(windows): assert API Key session-card locale keys

EOF
)"
```

（无文件变更则跳过 commit。）

---

### Task 7: 全量验收与 diff 审查

**Files:**
- Verify only（本功能相关路径）

- [ ] **Step 1: macOS**

```bash
cd src/macos
swift run AgentHaloCoreChecks
swift run AgentHaloMac --self-check
swift build
git diff --check
```

Expected: 全绿。

- [ ] **Step 2: shared**

```bash
python3 scripts/check_shared.py
```

- [ ] **Step 3: 范围审查**

```bash
git log --oneline -10
git diff main...HEAD --stat   # 或相对开发分支
```

Expected：无 usage provider / access mode 算法大改；无方案 C 字段；locales 六文件 + DetailsPanel + HaloInteractionChecks + DetailsWindow（+ 可选 Diagnostics/PRODUCT）。

- [ ] **Step 4: Spec 状态更新**

将设计文档状态改为「已实现，待发布验证」或等价表述。

```bash
git add docs/superpowers/specs/2026-08-05-api-key-session-card-details-design.md
git commit -m "$(cat <<'EOF'
docs: mark API Key session-card design as implemented

EOF
)"
```

---

## Spec 覆盖自检

| Spec 要求 | Task |
|-----------|------|
| mode chip 仅非 OAuth | 3, 5 |
| Offline empty 替代三行 `--` | 2, 3, 5 |
| Online session card（标题/模型/tokens） | 2, 3, 5 |
| 外框 + 内矩形同高（H_body≈70–72，总高 172） | 2, 3, 4, 5 |
| 面板尺寸锁定现网 278×172 | Global, 2, 3, 4 |
| 标题单行 + tooltip | 3, 5 |
| 字段缺失占位、empty 仅 offline | 2, 3, 5 |
| OAuth 不变 | 2 互斥测试, 5 OAuth 分支 |
| i18n 双 key | 1 |
| macOS checks | 2, 3, 4, 7 |
| Windows 对等 | 5, 6 |
| 不改采集/网络 | 全局约束 |

## 风险与注意

1. **Windows `claudeGroup` 复用 Codex custom**：改 body 时两处 Refresh 都要切到 card，避免漏网三行表。
2. **硬编码面板高度 172**：现网契约，**不得**随新布局改大；失败时压布局而非改期望。不要删掉 top-edge 与 usage==session 同高断言。
3. **context pill + chip 抢宽度**：顶栏 278 宽；chip 文案短（API Key），优先保证 toggle 108 + pill 42 + chip ≈ 可容纳。
4. **STANDBY 字段全空**：soft empty + blank 文案；Offline 用 empty 文案；禁止全 `--` 卡。
5. **Grok**：OAuth weekly 保持 quota；勿错误显示 API Key chip。

---

## 执行交接

Plan 已保存到 `docs/superpowers/plans/2026-08-05-api-key-session-card-details-implementation.md`。

两种执行方式：

1. **Subagent-Driven（推荐）** — 每任务新开 subagent，任务间审查
2. **Inline Execution** — 本会话按 executing-plans 连续做，设检查点

需要我按哪种方式开始实现？
