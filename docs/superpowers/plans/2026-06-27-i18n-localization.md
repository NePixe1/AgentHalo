# i18n 国际化 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将 Agent Halo 从纯中文应用改造为中英双语应用，架构上支持未来扩展更多语言。macOS 和 Windows 双端同步实施。

**Architecture:** 共享 JSON 翻译文件（`shared/locales/`）作为单一的翻译数据源。每端有一个 L10n 单例在运行时加载 JSON、解析系统语言、提供 `subscript(key:)` 和 `format(_:_:)` API。UI 层通过 L10n 单例取值，语言切换时重建菜单/刷新面板。

**Tech Stack:** Swift 6 (SPM), C# (.NET Framework 4.8+), JSON

## Global Constraints

- 仅中英双语，架构预留多语言扩展（`supportedLanguages` 数组）
- 语言优先级：用户手动设置 > 系统语言 > fallback 中文
- JSON key 命名：`category.snake_case_key`，永不删除已有 key
- 参数占位：`{0}`, `{1}`, …
- 光环渲染代码（HaloRenderer/HaloView）不受影响（[[ring-visuals-invariant]]）
- 代码注释保持中文，不翻译
- Codex/Claude Code 行为检测模式（压缩上下文匹配数组）不做国际化，保持中英双语检测

---
### Task 1: Create Shared Locale JSON Files

**Files:**
- Create: `src/shared/locales/zh.json`
- Create: `src/shared/locales/en.json`
- Create: `src/macos/Sources/AgentHaloCore/locales/zh.json` (symlink to shared)
- Create: `src/macos/Sources/AgentHaloCore/locales/en.json` (symlink to shared)

**Interfaces:**
- Produces: JSON files with all 60+ translation keys, consumed by L10n.swift (Task 2) and L10n.cs (Task 8)

- [ ] **Step 1: Create shared locales directory**

```bash
mkdir -p src/shared/locales
```

- [ ] **Step 2: Write zh.json — Chinese translations (canonical source)**

Write `src/shared/locales/zh.json`:

```json
{
  "menu.always_on_top": "始终置顶",
  "menu.launch_at_startup": "开机自动启动",
  "menu.pause_monitor": "暂停状态监听",
  "menu.focus_target": "监控对象",
  "menu.escape_offscreen": "脱离卡死（移到主屏右上角）",
  "menu.preview_status": "预览状态",
  "menu.quit": "退出",
  "menu.language": "语言",
  "menu.language.auto": "跟随系统",
  "menu.language.zh": "中文",
  "menu.language.en": "English",

  "status.offline_codex": "Codex 未运行",
  "status.offline_claude": "Claude Code 未运行",
  "status.standby_codex": "Codex 正在待命",
  "status.standby_claude": "Claude Code 正在待命",
  "status.paused": "状态监听已暂停",
  "status.thinking": "正在思考与规划",
  "status.working": "正在执行任务",
  "status.done": "任务已完成",
  "status.attention": "等待你的授权或输入",
  "status.error": "任务已中断",
  "status.unknown": "状态未知",
  "status.writing_answer": "正在输出答案",
  "status.running_command": "正在执行命令",
  "status.editing_files": "正在编辑文件",
  "status.searching": "正在搜索信息",
  "status.compressing_context": "正在压缩上下文",
  "status.context_compacted": "上下文压缩完成",
  "status.awaiting_permission": "等待你的授权",
  "status.permission_denied": "授权已拒绝",
  "status.reviewing_result": "正在分析结果",

  "quota.5h": "5 小时额度",
  "quota.weekly": "周额度",
  "quota.monthly": "月额度",
  "quota.remaining": "剩余 {0}%",
  "quota.no_data": "暂无数据",
  "quota.waiting_refresh": "等待 Codex 刷新",

  "context.title": "上下文",
  "context.label": "上下文 {0}%",
  "context.empty": "上下文 --",

  "metadata.project": "项目",
  "metadata.model": "模型",
  "metadata.tokens": "输入输出",

  "failure.auth_expired": "认证已失效",
  "failure.quota_exhausted": "额度已用尽",
  "failure.service_unavailable": "服务暂时不可用",
  "failure.connection_failed": "连接 Codex 失败",

  "halo.size": "光环大小",
  "halo.live_status": "实时状态",
  "halo.thinking_preview": "思考中",
  "halo.working_preview": "执行中",
  "halo.done_preview": "已完成",
  "halo.attention_preview": "等待授权（双脉冲）",
  "halo.error_flash_preview": "故障（爆闪）",
  "halo.error_bright_preview": "故障（常亮）",
  "halo.error_dim_preview": "故障（暗红）",
  "halo.idle_preview": "待机",

  "date.today_format": "HH:mm '刷新'",
  "date.other_format": "M月d日 HH:mm '刷新'",
  "date.refresh_suffix": "刷新"
}
```

- [ ] **Step 3: Write en.json — English translations**

Write `src/shared/locales/en.json`:

```json
{
  "menu.always_on_top": "Always on Top",
  "menu.launch_at_startup": "Launch at Login",
  "menu.pause_monitor": "Pause Monitoring",
  "menu.focus_target": "Monitor",
  "menu.escape_offscreen": "Reset Position",
  "menu.preview_status": "Preview Status",
  "menu.quit": "Quit",
  "menu.language": "Language",
  "menu.language.auto": "Follow System",
  "menu.language.zh": "中文",
  "menu.language.en": "English",

  "status.offline_codex": "Codex Not Running",
  "status.offline_claude": "Claude Code Not Running",
  "status.standby_codex": "Codex Standing By",
  "status.standby_claude": "Claude Code Standing By",
  "status.paused": "Monitoring Paused",
  "status.thinking": "Thinking & Planning",
  "status.working": "Executing Task",
  "status.done": "Task Completed",
  "status.attention": "Waiting for Authorization",
  "status.error": "Task Interrupted",
  "status.unknown": "Unknown Status",
  "status.writing_answer": "Writing Answer",
  "status.running_command": "Running Command",
  "status.editing_files": "Editing Files",
  "status.searching": "Searching",
  "status.compressing_context": "Compressing Context",
  "status.context_compacted": "Context Compacted",
  "status.awaiting_permission": "Awaiting Permission",
  "status.permission_denied": "Permission Denied",
  "status.reviewing_result": "Reviewing Result",

  "quota.5h": "5-Hour Quota",
  "quota.weekly": "Weekly Quota",
  "quota.monthly": "Monthly Quota",
  "quota.remaining": "{0}% Remaining",
  "quota.no_data": "No Data",
  "quota.waiting_refresh": "Waiting for Codex",

  "context.title": "Context",
  "context.label": "Context {0}%",
  "context.empty": "Context --",

  "metadata.project": "Project",
  "metadata.model": "Model",
  "metadata.tokens": "Input/Output",

  "failure.auth_expired": "Authentication Expired",
  "failure.quota_exhausted": "Quota Exhausted",
  "failure.service_unavailable": "Service Unavailable",
  "failure.connection_failed": "Connection Failed",

  "halo.size": "Halo Size",
  "halo.live_status": "Live Status",
  "halo.thinking_preview": "Thinking",
  "halo.working_preview": "Working",
  "halo.done_preview": "Done",
  "halo.attention_preview": "Awaiting Auth (Double Pulse)",
  "halo.error_flash_preview": "Error (Flashing)",
  "halo.error_bright_preview": "Error (Solid Bright)",
  "halo.error_dim_preview": "Error (Dim Red)",
  "halo.idle_preview": "Idle",

  "date.today_format": "HH:mm 'refresh'",
  "date.other_format": "MMM d, HH:mm 'refresh'",
  "date.refresh_suffix": "refresh"
}
```

- [ ] **Step 4: Create symlinks for macOS SPM bundling**

```bash
mkdir -p src/macos/Sources/AgentHaloCore/locales
ln -sf "$PWD/src/shared/locales/zh.json" src/macos/Sources/AgentHaloCore/locales/zh.json
ln -sf "$PWD/src/shared/locales/en.json" src/macos/Sources/AgentHaloCore/locales/en.json
```

- [ ] **Step 5: Commit**

```bash
git add src/shared/locales/ src/macos/Sources/AgentHaloCore/locales/
git commit -m "feat: add shared locale JSON files (zh/en)"
```

---

### Task 2: Create macOS L10n.swift, Update Package.swift, Extend HaloSettings

**Files:**
- Create: `src/macos/Sources/AgentHaloCore/L10n.swift`
- Modify: `src/macos/Package.swift` (add resource directive)
- Modify: `src/macos/Sources/AgentHaloCore/HaloSettings.swift` (add language field)

**Interfaces:**
- Produces: `L10n.shared` — public singleton
  - `L10n.shared.currentLanguage: String` — "zh" / "en"
  - `L10n.shared.setLanguage(_ lang: String?)` — nil = follow system
  - `L10n.shared[key] -> String` — subscript access
  - `L10n.shared.format(_ key: String, _ args: CVarArg...) -> String`
  - `L10n.languageDidChange: Notification.Name` — posted on language switch
- Consumes: `HaloSettings.language: String?` (new field)

- [ ] **Step 1: Add `language` field to HaloSettings**

Edit `src/macos/Sources/AgentHaloCore/HaloSettings.swift`:

Add new property after `acknowledgedErrorAt`:

```swift
// In the struct body, add after `acknowledgedErrorAt`:
public var language: String?

// In CodingKeys enum, add:
case language

// In init(), add parameter after `acknowledgedErrorAt: Date? = nil`:
language: String? = nil

// In init body, add after `self.acknowledgedErrorAt = acknowledgedErrorAt`:
self.language = language

// In init(from decoder:), add after decoding `acknowledgedErrorAt`:
self.language = try container.decodeIfPresent(String.self, forKey: .language)
```

Since `HaloSettings` is `Equatable` (via `Codable`), adding `language` will automatically be included in equality checks. The `StatusMenuSignature` uses `settings: HaloSettings`, so language changes will automatically trigger menu rebuilds.

- [ ] **Step 2: Add resource declaration to Package.swift**

Edit `src/macos/Package.swift`. Change the `AgentHaloCore` target to include resources:

```swift
.target(
    name: "AgentHaloCore",
    dependencies: [],
    resources: [
        .copy("locales")
    ],
    linkerSettings: [
        .linkedLibrary("sqlite3")
    ]
),
```

- [ ] **Step 3: Write L10n.swift**

Write `src/macos/Sources/AgentHaloCore/L10n.swift`:

```swift
import Foundation

public final class L10n: @unchecked Sendable {
    public static let shared = L10n()

    public static let languageDidChange = Notification.Name("L10n.languageDidChange")

    private static let supportedLanguages = ["zh", "en"]
    private static let fallbackLanguage = "zh"

    private var translations: [String: String] = [:]
    private var _currentLanguage: String = Self.fallbackLanguage

    public var currentLanguage: String { _currentLanguage }

    private init() {}

    // MARK: - Configuration

    /// Configure language. Pass `nil` to follow the system language.
    /// Call this early in app startup, after loading settings.
    public func setLanguage(_ lang: String?) {
        let resolved = Self.resolveLanguage(lang)
        guard resolved != _currentLanguage else { return }
        _currentLanguage = resolved
        loadTranslations()
        NotificationCenter.default.post(name: Self.languageDidChange, object: self)
    }

    // MARK: - Public API

    public subscript(_ key: String) -> String {
        translations[key] ?? key
    }

    public func format(_ key: String, _ args: CVarArg...) -> String {
        let template = self[key]
        return String(format: template, arguments: args)
    }

    // MARK: - System language detection

    public static func detectSystemLanguage() -> String {
        let preferred = Locale.preferredLanguages.first ?? ""
        // Extract language code (e.g. "zh-Hans-CN" → "zh", "en-US" → "en")
        if let languageCode = preferred.split(separator: "-").first.map(String.init) {
            let normalized = languageCode.lowercased()
            if supportedLanguages.contains(normalized) {
                return normalized
            }
        }
        return fallbackLanguage
    }

    // MARK: - Private

    private static func resolveLanguage(_ explicit: String?) -> String {
        if let lang = explicit, supportedLanguages.contains(lang) {
            return lang
        }
        return detectSystemLanguage()
    }

    private func loadTranslations() {
        guard let url = Bundle.module.url(
            forResource: _currentLanguage,
            withExtension: "json",
            subdirectory: "locales"
        ) else {
            // Fallback: try loading the fallback language
            if _currentLanguage != Self.fallbackLanguage,
               let fallbackURL = Bundle.module.url(
                forResource: Self.fallbackLanguage,
                withExtension: "json",
                subdirectory: "locales"
               ) {
                translations = Self.parseJSON(at: fallbackURL)
                return
            }
            translations = [:]
            return
        }
        translations = Self.parseJSON(at: url)
    }

    private static func parseJSON(at url: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return json
    }
}
```

- [ ] **Step 4: Verify it compiles with localized JSON**

```bash
cd src/macos && swift build --target AgentHaloCore 2>&1
```

Expected: BUILD SUCCESS

- [ ] **Step 5: Commit**

```bash
git add src/macos/Sources/AgentHaloCore/L10n.swift src/macos/Sources/AgentHaloCore/HaloSettings.swift src/macos/Package.swift
git commit -m "feat: add L10n singleton and language field to HaloSettings"
```

---

### Task 3: Migrate HaloModels.swift — use L10n for localized status strings

**Files:**
- Modify: `src/macos/Sources/AgentHaloCore/HaloModels.swift:28-47`

**Interfaces:**
- Consumes: `L10n.shared[key]` (from Task 2)
- Produces: `AgentKind.localizedStandbyDetail` and `localizedOfflineDetail` now use L10n

- [ ] **Step 1: Replace hardcoded Chinese in HaloModels.swift**

Replace lines 28-47 of `src/macos/Sources/AgentHaloCore/HaloModels.swift`:

**Old:**
```swift
    public var localizedStandbyDetail: String {
        switch self {
        case .codex: return "Codex 正在待命"
        case .claudeCode: return "Claude Code 正在待命"
        }
    }

    public var localizedOfflineDetail: String {
        switch self {
        case .codex: return "Codex 未运行"
        case .claudeCode: return "Claude Code 未运行"
        }
    }
```

**New:**
```swift
    public var localizedStandbyDetail: String {
        switch self {
        case .codex: return L10n.shared["status.standby_codex"]
        case .claudeCode: return L10n.shared["status.standby_claude"]
        }
    }

    public var localizedOfflineDetail: String {
        switch self {
        case .codex: return L10n.shared["status.offline_codex"]
        case .claudeCode: return L10n.shared["status.offline_claude"]
        }
    }
```

- [ ] **Step 2: Verify compilation**

```bash
cd src/macos && swift build --target AgentHaloCore 2>&1
```

Expected: BUILD SUCCESS

- [ ] **Step 3: Commit**

```bash
git add src/macos/Sources/AgentHaloCore/HaloModels.swift
git commit -m "refactor: use L10n for AgentKind localized status strings"
```

---

### Task 4: Migrate GeneratedHaloSpec.swift — classifyFailure returns L10n keys

**Files:**
- Modify: `src/macos/Sources/AgentHaloCore/GeneratedHaloSpec.swift:235-241`
- Modify: Callers of `classifyFailure()` (check usage in CodexFailureReader)

**Interfaces:**
- Produces: `classifyFailure()` now returns L10n keys (e.g. `"failure.auth_expired"`) instead of Chinese strings
- Consumers must translate via `L10n.shared[key]`

- [ ] **Step 1: Find all callers of classifyFailure**

```bash
grep -rn 'classifyFailure' src/macos/Sources --include="*.swift"
```

- [ ] **Step 2: Update classifyFailure to return L10n keys**

Edit `src/macos/Sources/AgentHaloCore/GeneratedHaloSpec.swift`, lines 237-240:

**Old:**
```swift
        if containsAny(value, ["authentication failed", "unauthorized", "invalid token", "sign in again"]) { return "认证已失效" }
        if containsAny(value, ["rate limit reached", "usage limit", "quota exceeded", "rate_limit_reached"]) { return "额度已用尽" }
        if containsAny(value, ["service unavailable", "server overloaded", "overloaded", "bad gateway"]) { return "服务暂时不可用" }
        if containsAny(value, ["connection failed", "network error", "connection aborted", "request timed out", "connect timeout"]) { return "连接 Codex 失败" }
```

**New:**
```swift
        if containsAny(value, ["authentication failed", "unauthorized", "invalid token", "sign in again"]) { return "failure.auth_expired" }
        if containsAny(value, ["rate limit reached", "usage limit", "quota exceeded", "rate_limit_reached"]) { return "failure.quota_exhausted" }
        if containsAny(value, ["service unavailable", "server overloaded", "overloaded", "bad gateway"]) { return "failure.service_unavailable" }
        if containsAny(value, ["connection failed", "network error", "connection aborted", "request timed out", "connect timeout"]) { return "failure.connection_failed" }
```

- [ ] **Step 3: Update callers to translate the L10n key**

For each caller of `classifyFailure()` found in Step 1, wrap the result with `L10n.shared[...]`. 

For example, in `CodexFailureReader.swift` (verify exact location via grep):

```swift
// Old pattern:
if let detail = HaloSpec.classifyFailure(text) {
    return CodexFailure(detail: detail, eventAt: now)
}

// New pattern:
if let key = HaloSpec.classifyFailure(text) {
    let detail = L10n.shared[key]
    return CodexFailure(detail: detail, eventAt: now)
}
```

- [ ] **Step 4: Verify compilation**

```bash
cd src/macos && swift build 2>&1
```

Expected: BUILD SUCCESS

- [ ] **Step 5: Commit**

```bash
git add src/macos/Sources/AgentHaloCore/GeneratedHaloSpec.swift
# Add any caller files that were modified
git commit -m "refactor: classifyFailure returns L10n keys instead of Chinese strings"
```

---

### Task 5: Migrate DetailsPanel.swift — all Chinese strings to L10n

**Files:**
- Modify: `src/macos/Sources/AgentHaloMac/DetailsPanel.swift`

**Interfaces:**
- Consumes: `L10n.shared[key]`, `L10n.shared.format(_:_:)` (from Task 2)
- No new public API produced — internal changes only

- [ ] **Step 1: Replace initializer default strings (lines 7-27)**

In `DetailsPanel.init()`:

**Old:**
```swift
private let contextValue = NSTextField(labelWithString: "上下文 --")
private let detailField = NSTextField(labelWithString: "Codex 未运行")
private let primaryQuota = QuotaRowView(title: "5 小时额度")
private let secondaryQuota = QuotaRowView(title: "周额度")
...
    title: "项目"
...
    title: "模型"
...
    title: "输入输出",
```

**New:**
```swift
private let contextValue = NSTextField(labelWithString: L10n.shared["context.empty"])
private let detailField = NSTextField(labelWithString: L10n.shared["status.offline_codex"])
private let primaryQuota = QuotaRowView(title: L10n.shared["quota.5h"])
private let secondaryQuota = QuotaRowView(title: L10n.shared["quota.weekly"])
...
    title: L10n.shared["metadata.project"]
...
    title: L10n.shared["metadata.model"]
...
    title: L10n.shared["metadata.tokens"],
```

- [ ] **Step 2: Replace context percentage strings (lines 148-150)**

**Old:**
```swift
contextValue.stringValue = contextUsedPercent.map {
    "上下文 \(Int($0.rounded()))%"
} ?? "上下文 --"
```

**New:**
```swift
contextValue.stringValue = contextUsedPercent.map {
    L10n.shared.format("context.label", Int($0.rounded()))
} ?? L10n.shared["context.empty"]
```

- [ ] **Step 3: Replace quota title strings (lines 198, 199, 218)**

**Old (applyPlusQuota):**
```swift
primaryQuota.setTitle("5 小时额度")
secondaryQuota.setTitle("周额度")
```

**New:**
```swift
primaryQuota.setTitle(L10n.shared["quota.5h"])
secondaryQuota.setTitle(L10n.shared["quota.weekly"])
```

**Old (applyMonthlyQuota):**
```swift
primaryQuota.setTitle("月额度")
```

**New:**
```swift
primaryQuota.setTitle(L10n.shared["quota.monthly"])
```

- [ ] **Step 4: Replace formatResetTime date format strings (line 244)**

**Old:**
```swift
formatter.locale = Locale(identifier: "zh_CN")
formatter.dateFormat = calendar.isDateInToday(date) ? "HH:mm '刷新'" : "M月d日 HH:mm '刷新'"
```

**New:**
```swift
formatter.locale = Locale(identifier: L10n.shared.currentLanguage == "zh" ? "zh_CN" : "en_US")
if calendar.isDateInToday(date) {
    formatter.dateFormat = L10n.shared["date.today_format"]
} else {
    formatter.dateFormat = L10n.shared["date.other_format"]
}
```

- [ ] **Step 5: Replace QuotaRowView Chinese strings (lines 555, 572, 579, 587, 597)**

In `QuotaRowView`:

**Old (line 555 — initializer default):**
```swift
private let valueField = NSTextField(labelWithString: "暂无数据")
```

**New:**
```swift
private let valueField = NSTextField(labelWithString: L10n.shared["quota.no_data"])
```

**Old (line 572 — update reset expired):**
```swift
valueField.stringValue = "等待 Codex 刷新"
```

**New:**
```swift
valueField.stringValue = L10n.shared["quota.waiting_refresh"]
```

**Old (line 579 — update with value):**
```swift
valueField.stringValue = "剩余 \(Int(remaining.rounded()))%"
```

**New:**
```swift
valueField.stringValue = L10n.shared.format("quota.remaining", Int(remaining.rounded()))
```

**Old (line 587 — updateUnavailable):**
```swift
valueField.stringValue = "暂无数据"
```

**New:**
```swift
valueField.stringValue = L10n.shared["quota.no_data"]
```

**Old (line 597 — updatePending):**
```swift
valueField.stringValue = "等待 Codex 刷新"
```

**New:**
```swift
valueField.stringValue = L10n.shared["quota.waiting_refresh"]
```

- [ ] **Step 6: Replace localizedDetail() Chinese strings (lines 301-331)**

In `localizedDetail(for:)`:

**Old:**
```swift
    if aggregate.state == .idle {
        if aggregate.label == "PAUSED" {
            return "状态监听已暂停"
        }
        return aggregate.focusedAgent.localizedOfflineDetail
    }
    ...
    if action.localizedCaseInsensitiveContains("Writing answer") {
        return "正在输出答案"
    }
    if action.localizedCaseInsensitiveContains("command") { return "正在执行命令" }
    if action.localizedCaseInsensitiveContains("Editing") { return "正在编辑文件" }
    if action.localizedCaseInsensitiveContains("Search") { return "正在搜索信息" }
    if action.localizedCaseInsensitiveContains("Compressing context") { return "正在压缩上下文" }
    if action.localizedCaseInsensitiveContains("Context compacted") { return "上下文压缩完成" }
    if action.localizedCaseInsensitiveContains("Awaiting permission") { return "等待你的授权" }
    if action.localizedCaseInsensitiveContains("Permission denied") { return "授权已拒绝" }
    if action.localizedCaseInsensitiveContains("Reviewing result") { return "正在分析结果" }
    switch aggregate.state {
    case .thinking: return "正在思考与规划"
    case .working: return "正在执行任务"
    case .done: return "任务已完成"
    case .attention: return "等待你的授权或输入"
    case .error: return aggregate.detail.isEmpty ? "任务已中断" : aggregate.detail
    case .idle: return aggregate.focusedAgent.localizedOfflineDetail
    }
```

**New:**
```swift
    if aggregate.state == .idle {
        if aggregate.label == "PAUSED" {
            return L10n.shared["status.paused"]
        }
        return aggregate.focusedAgent.localizedOfflineDetail
    }
    ...
    if action.localizedCaseInsensitiveContains("Writing answer") {
        return L10n.shared["status.writing_answer"]
    }
    if action.localizedCaseInsensitiveContains("command") { return L10n.shared["status.running_command"] }
    if action.localizedCaseInsensitiveContains("Editing") { return L10n.shared["status.editing_files"] }
    if action.localizedCaseInsensitiveContains("Search") { return L10n.shared["status.searching"] }
    if action.localizedCaseInsensitiveContains("Compressing context") { return L10n.shared["status.compressing_context"] }
    if action.localizedCaseInsensitiveContains("Context compacted") { return L10n.shared["status.context_compacted"] }
    if action.localizedCaseInsensitiveContains("Awaiting permission") { return L10n.shared["status.awaiting_permission"] }
    if action.localizedCaseInsensitiveContains("Permission denied") { return L10n.shared["status.permission_denied"] }
    if action.localizedCaseInsensitiveContains("Reviewing result") { return L10n.shared["status.reviewing_result"] }
    switch aggregate.state {
    case .thinking: return L10n.shared["status.thinking"]
    case .working: return L10n.shared["status.working"]
    case .done: return L10n.shared["status.done"]
    case .attention: return L10n.shared["status.attention"]
    case .error: return aggregate.detail.isEmpty ? L10n.shared["status.error"] : aggregate.detail
    case .idle: return aggregate.focusedAgent.localizedOfflineDetail
    }
```

- [ ] **Step 7: Verify compilation**

```bash
cd src/macos && swift build 2>&1
```

Expected: BUILD SUCCESS

- [ ] **Step 8: Commit**

```bash
git add src/macos/Sources/AgentHaloMac/DetailsPanel.swift
git commit -m "refactor: migrate DetailsPanel Chinese strings to L10n"
```

---

### Task 6: Migrate AppDelegate.swift — menu items + language submenu

**Files:**
- Modify: `src/macos/Sources/AgentHaloMac/AppDelegate.swift`

**Interfaces:**
- Consumes: `L10n.shared[key]` (from Task 2), `L10n.languageDidChange` notification
- Produces: Language submenu in the context menu

- [ ] **Step 1: Add language property and observer to AppDelegate**

In the class body, add near other properties (around line 100-120):

```swift
private var currentLanguage: String = "zh"
private var languageObserver: NSObjectProtocol?
```

In `applicationDidFinishLaunching` or setup method, add:

```swift
// Initialize L10n with user's saved preference
L10n.shared.setLanguage(settings.language)
currentLanguage = L10n.shared.currentLanguage

// Observe language changes
languageObserver = NotificationCenter.default.addObserver(
    forName: L10n.languageDidChange,
    object: nil,
    queue: .main
) { [weak self] _ in
    self?.currentLanguage = L10n.shared.currentLanguage
    // Persist preference
    self?.settings.language = L10n.shared.currentLanguage == L10n.detectSystemLanguage() ? nil : L10n.shared.currentLanguage
    self?.settingsStore.save(self!.settings)
    // Rebuild menu so all items show new language
    self?.lastStatusMenuSignature = nil
    self?.tick()
}
```

- [ ] **Step 2: Replace all menu item Chinese strings in makeControlMenu() (lines 449-477)**

**Old:**
```swift
    addCheckItem("始终置顶", checked: settings.alwaysOnTop, action: #selector(toggleAlwaysOnTop), to: menu)
    addCheckItem("开机自动启动", checked: currentStartupEnabled(), action: #selector(toggleStartup), to: menu)
    addCheckItem("暂停状态监听", checked: settings.paused, action: #selector(togglePause), to: menu)
    addHaloSizeItem(to: menu)
    let focus = NSMenuItem(title: "监控对象", action: nil, keyEquivalent: "")
    ...
    addMenuItem("脱离卡死（移到主屏右上角）", #selector(escapeOffscreen), enabled: true, to: menu)
    let preview = NSMenuItem(title: "预览状态", action: nil, keyEquivalent: "")
    ...
    addPreviewItem("实时状态", state: nil, presentation: nil, to: submenu)
    addPreviewItem("思考中", state: .thinking, presentation: nil, to: submenu)
    addPreviewItem("执行中", state: .working, presentation: nil, to: submenu)
    addPreviewItem("已完成", state: .done, presentation: nil, to: submenu)
    addPreviewItem("等待授权（双脉冲）", state: .attention, presentation: nil, to: submenu)
    addPreviewItem("故障（爆闪）", state: .error, presentation: .flashing, to: submenu)
    addPreviewItem("故障（常亮）", state: .error, presentation: .bright, to: submenu)
    addPreviewItem("故障（暗红）", state: .error, presentation: .dim, to: submenu)
    addPreviewItem("待机", state: .idle, presentation: nil, to: submenu)
    ...
    addMenuItem("退出", #selector(quit), enabled: true, to: menu)
```

**New:**
```swift
    addCheckItem(L10n.shared["menu.always_on_top"], checked: settings.alwaysOnTop, action: #selector(toggleAlwaysOnTop), to: menu)
    addCheckItem(L10n.shared["menu.launch_at_startup"], checked: currentStartupEnabled(), action: #selector(toggleStartup), to: menu)
    addCheckItem(L10n.shared["menu.pause_monitor"], checked: settings.paused, action: #selector(togglePause), to: menu)
    addHaloSizeItem(to: menu)  // updated separately in Step 4
    let focus = NSMenuItem(title: L10n.shared["menu.focus_target"], action: nil, keyEquivalent: "")
    ...
    addMenuItem(L10n.shared["menu.escape_offscreen"], #selector(escapeOffscreen), enabled: true, to: menu)
    let preview = NSMenuItem(title: L10n.shared["menu.preview_status"], action: nil, keyEquivalent: "")
    ...
    addPreviewItem(L10n.shared["halo.live_status"], state: nil, presentation: nil, to: submenu)
    addPreviewItem(L10n.shared["halo.thinking_preview"], state: .thinking, presentation: nil, to: submenu)
    addPreviewItem(L10n.shared["halo.working_preview"], state: .working, presentation: nil, to: submenu)
    addPreviewItem(L10n.shared["halo.done_preview"], state: .done, presentation: nil, to: submenu)
    addPreviewItem(L10n.shared["halo.attention_preview"], state: .attention, presentation: nil, to: submenu)
    addPreviewItem(L10n.shared["halo.error_flash_preview"], state: .error, presentation: .flashing, to: submenu)
    addPreviewItem(L10n.shared["halo.error_bright_preview"], state: .error, presentation: .bright, to: submenu)
    addPreviewItem(L10n.shared["halo.error_dim_preview"], state: .error, presentation: .dim, to: submenu)
    addPreviewItem(L10n.shared["halo.idle_preview"], state: .idle, presentation: nil, to: submenu)
    ...
    addMenuItem(L10n.shared["menu.quit"], #selector(quit), enabled: true, to: menu)
```

- [ ] **Step 3: Add language submenu after focus/agent submenu**

After the `menu.addItem(focus)` line and `addHaloSizeItem(to: menu)` line, insert the language submenu between them. Specifically, after the focus submenu section:

```swift
        // Language submenu
        let languageItem = NSMenuItem(title: L10n.shared["menu.language"], action: nil, keyEquivalent: "")
        let languageMenu = NSMenu()
        addLanguageItem(nil, to: languageMenu)           // Follow System
        addLanguageItem("zh", to: languageMenu)           // 中文
        addLanguageItem("en", to: languageMenu)           // English
        languageItem.submenu = languageMenu
        menu.addItem(languageItem)
```

- [ ] **Step 4: Update addHaloSizeItem() to use L10n**

**Old (line 947):**
```swift
let item = NSMenuItem(title: "圆环大小", action: nil, keyEquivalent: "")
```

**New:**
```swift
let item = NSMenuItem(title: L10n.shared["halo.size"], action: nil, keyEquivalent: "")
```

And line 949:

**Old:**
```swift
let label = NSTextField(labelWithString: "圆环大小")
```

**New:**
```swift
let label = NSTextField(labelWithString: L10n.shared["halo.size"])
```

- [ ] **Step 5: Add addLanguageItem helper method**

Add this method near `addFocusedAgentItem`:

```swift
    private func addLanguageItem(_ lang: String?, to menu: NSMenu) {
        let title: String
        if let lang {
            // lang is a language code like "zh" or "en"
            title = L10n.shared["menu.language.\(lang)"]
        } else {
            title = L10n.shared["menu.language.auto"]
        }
        let item = NSMenuItem(title: title, action: #selector(selectLanguage(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = lang as NSString?
        // Checkmark: nil = follow system
        let effectiveLanguage = settings.language ?? L10n.detectSystemLanguage()
        item.state = (lang == effectiveLanguage) ? .on : .off
        menu.addItem(item)
    }
```

- [ ] **Step 6: Add selectLanguage action handler**

```swift
    @objc private func selectLanguage(_ sender: NSMenuItem) {
        let lang = sender.representedObject as? String  // nil = follow system
        settings.language = lang
        settingsStore.save(settings)
        L10n.shared.setLanguage(lang)
    }
```

- [ ] **Step 7: Verify compilation**

```bash
cd src/macos && swift build 2>&1
```

Expected: BUILD SUCCESS

- [ ] **Step 8: Commit**

```bash
git add src/macos/Sources/AgentHaloMac/AppDelegate.swift
git commit -m "feat: add language submenu and migrate menu items to L10n"
```

---

### Task 7: Migrate HaloInteractionChecks.swift — test assertions to use L10n

**Files:**
- Modify: `src/macos/Sources/AgentHaloMac/HaloInteractionChecks.swift`

**Interfaces:**
- Consumes: `L10n.shared[key]` (from Task 2)
- No new API — test-only changes

- [ ] **Step 1: Configure L10n to Chinese at test start**

Find the test setup method (`setUp()` or similar) and add:

```swift
L10n.shared.setLanguage("zh")
```

- [ ] **Step 2: Replace all Chinese string assertions**

Replace each hardcoded Chinese string in `expect()` calls with `L10n.shared[...]`:

**Old → New mapping:**

```
"确认已完成任务" → L10n.shared["status.done"]  (line 265)
"确认当前错误" → L10n.shared["status.error"]  (line 266)
"始终置顶" → L10n.shared["menu.always_on_top"]  (line 267)
"暂停状态监听" → L10n.shared["menu.pause_monitor"]  (line 268)
"圆环大小" → L10n.shared["halo.size"]  (line 269, 270, 279)
"预览状态" → L10n.shared["menu.preview_status"]  (line 283)
"切换到 Codex" → "Switch to Codex" (this was English already, keep or use L10n ? — verify)
"退出 Agent Halo" → "Quit Agent Halo" (was English, keep)
"退出" → L10n.shared["menu.quit"]  (line 286)
"实时状态" → L10n.shared["halo.live_status"]  (line 466)
"执行中" → L10n.shared["halo.working_preview"]  (line 473, 480)
"预览状态" → L10n.shared["menu.preview_status"]  (line 758)
"监控对象" → L10n.shared["menu.focus_target"]  (line 765)
"Codex 未运行" → L10n.shared["status.offline_codex"]  (line 802)
"Codex 正在待命" → L10n.shared["status.standby_codex"]  (line 823)
"项目" → L10n.shared["metadata.project"]  (line 894, 895)
"模型" → L10n.shared["metadata.model"]  (line 894)
"输入输出" → L10n.shared["metadata.tokens"]  (line 894)
```

- [ ] **Step 3: Verify compilation**

```bash
cd src/macos && swift build 2>&1
```

Expected: BUILD SUCCESS

- [ ] **Step 4: Run tests to verify**

```bash
cd src/macos && swift test --filter HaloInteractionChecks 2>&1
```

Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
git add src/macos/Sources/AgentHaloMac/HaloInteractionChecks.swift
git commit -m "test: migrate test assertions from hardcoded Chinese to L10n"
```

---

### Task 8: Create Windows L10n.cs + Extend Settings

**Files:**
- Create: `src/windows/L10n.cs`
- Modify: `src/windows/Settings.cs` (add Language property)
- Create: `src/windows/locales/zh.json` (symlink to shared)
- Create: `src/windows/locales/en.json` (symlink to shared)

**Interfaces:**
- Produces: `L10n.Instance` — singleton
  - `L10n.Instance.CurrentLanguage: string`
  - `L10n.Instance.SetLanguage(string lang)` — null = follow system
  - `L10n.Instance[string key] -> string`
  - `L10n.Instance.Format(string key, params object[] args) -> string`
  - `L10n.Instance.LanguageChanged: event EventHandler`

- [ ] **Step 1: Create symlinks for Windows locale files**

```bash
mkdir -p src/windows/locales
ln -sf "$PWD/src/shared/locales/zh.json" src/windows/locales/zh.json
ln -sf "$PWD/src/shared/locales/en.json" src/windows/locales/en.json
```

- [ ] **Step 2: Add Language property to HaloSettings**

Edit `src/windows/Settings.cs`, add property to `HaloSettings` class:

```csharp
        public string Language { get; set; }  // null = follow system
```

And update the constructor:

```csharp
        public HaloSettings()
        {
            AlwaysOnTop = true;
            HaloScalePercent = 100;
            FocusedAgent = "codex";
            InstalledAt = DateTime.UtcNow.ToString("o");
            Acknowledged = new Dictionary<string, string>();
            Language = null;  // follow system by default
        }
```

- [ ] **Step 3: Write L10n.cs**

Write `src/windows/L10n.cs`:

```csharp
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Web.Script.Serialization;

namespace CodexHalo
{
    public sealed class L10n
    {
        private static readonly L10n _instance = new L10n();
        public static L10n Instance => _instance;

        private static readonly string[] SupportedLanguages = { "zh", "en" };
        private const string FallbackLanguage = "zh";

        private Dictionary<string, string> _translations = new Dictionary<string, string>();
        private string _currentLanguage = FallbackLanguage;

        public string CurrentLanguage => _currentLanguage;

        public event EventHandler LanguageChanged;

        private L10n() { }

        /// <summary>
        /// Configure language. Pass null to follow the system language.
        /// </summary>
        public void SetLanguage(string lang)
        {
            string resolved = ResolveLanguage(lang);
            if (resolved == _currentLanguage) return;
            _currentLanguage = resolved;
            LoadTranslations();
            LanguageChanged?.Invoke(this, EventArgs.Empty);
        }

        public string this[string key]
        {
            get
            {
                string value;
                return _translations.TryGetValue(key, out value) ? value : key;
            }
        }

        public string Format(string key, params object[] args)
        {
            string template = this[key];
            return string.Format(template, args);
        }

        public static string DetectSystemLanguage()
        {
            try
            {
                string culture = CultureInfo.CurrentUICulture.Name; // e.g. "zh-CN", "en-US"
                string code = culture.Split('-')[0].ToLowerInvariant();
                if (SupportedLanguages.Contains(code)) return code;
            }
            catch { }
            return FallbackLanguage;
        }

        private static string ResolveLanguage(string explicitLang)
        {
            if (explicitLang != null && SupportedLanguages.Contains(explicitLang))
                return explicitLang;
            return DetectSystemLanguage();
        }

        private void LoadTranslations()
        {
            string localesDir = Path.Combine(
                AppDomain.CurrentDomain.BaseDirectory, "locales");
            string filePath = Path.Combine(localesDir, _currentLanguage + ".json");

            if (!File.Exists(filePath) && _currentLanguage != FallbackLanguage)
            {
                filePath = Path.Combine(localesDir, FallbackLanguage + ".json");
            }

            if (File.Exists(filePath))
            {
                try
                {
                    string json = File.ReadAllText(filePath, System.Text.Encoding.UTF8);
                    var serializer = new JavaScriptSerializer();
                    _translations = serializer.Deserialize<Dictionary<string, string>>(json)
                        ?? new Dictionary<string, string>();
                    return;
                }
                catch { }
            }
            _translations = new Dictionary<string, string>();
        }
    }
}
```

- [ ] **Step 4: Update Windows .csproj to copy locale files to output**

Find the `.csproj` file for the Windows project:

```bash
ls src/windows/*.csproj
```

Add to the `.csproj`:

```xml
  <ItemGroup>
    <Content Include="locales\**\*.json">
      <CopyToOutputDirectory>PreserveNewest</CopyToOutputDirectory>
      <Link>locales\%(Filename)%(Extension)</Link>
    </Content>
  </ItemGroup>
```

- [ ] **Step 5: Verify compilation (Windows)**

Build the Windows project in Visual Studio or via MSBuild.

Expected: BUILD SUCCESS

- [ ] **Step 6: Commit**

```bash
git add src/windows/L10n.cs src/windows/Settings.cs src/windows/locales/
git commit -m "feat: add Windows L10n singleton and language setting"
```

---

### Task 9: Migrate Windows DetailsWindow.cs — all Chinese strings to L10n

**Files:**
- Modify: `src/windows/DetailsWindow.cs`

**Interfaces:**
- Consumes: `L10n.Instance[key]`, `L10n.Instance.Format(key, args)` (from Task 8)

- [ ] **Step 1: Initialize L10n and subscribe to LanguageChanged**

In the `DetailsWindow` constructor or initialization, add:

```csharp
L10n.Instance.LanguageChanged += (s, e) =>
{
    Application.Current.Dispatcher.Invoke(() => RefreshAllText());
};
```

- [ ] **Step 2: Replace all Chinese string literals**

Replace each hardcoded Chinese string with `L10n.Instance["key"]`:

| Line | Old Chinese String | New L10n Call |
|------|-------------------|---------------|
| 182 | `"上下文"` | `L10n.Instance["context.title"]` |
| 201 | `"Codex 未运行"` | `L10n.Instance["status.offline_codex"]` |
| 207 | `"5 小时额度"` | `L10n.Instance["quota.5h"]` |
| 210 | `"周额度"` | `L10n.Instance["quota.weekly"]` |
| 216 | `"项目"` | `L10n.Instance["metadata.project"]` |
| 220 | `"模型"` | `L10n.Instance["metadata.model"]` |
| 224 | `"输入输出"` | `L10n.Instance["metadata.tokens"]` |
| 285 | `"状态监听已暂停"` | `L10n.Instance["status.paused"]` |
| 288 | `"Claude Code 未运行"`/`"Codex 未运行"` | `L10n.Instance["status.offline_claude"]` / `L10n.Instance["status.offline_codex"]` |
| 303 | `"正在输出答案"` | `L10n.Instance["status.writing_answer"]` |
| 307 | `"正在执行命令"` | `L10n.Instance["status.running_command"]` |
| 311 | `"正在编辑文件"` | `L10n.Instance["status.editing_files"]` |
| 315 | `"正在搜索信息"` | `L10n.Instance["status.searching"]` |
| 319 | `"正在自动压缩上下文"` | `L10n.Instance["status.compressing_context"]` |
| 323 | `"上下文压缩完成"` | `L10n.Instance["status.context_compacted"]` |
| 327 | `"等待你的授权"` | `L10n.Instance["status.awaiting_permission"]` |
| 331 | `"正在分析结果"` | `L10n.Instance["status.reviewing_result"]` |
| 335 | `"正在思考与规划"` | `L10n.Instance["status.thinking"]` |
| 336 | `"正在执行任务"` | `L10n.Instance["status.working"]` |
| 337 | `"任务已完成"` | `L10n.Instance["status.done"]` |
| 338 | `"等待你的授权或输入"` | `L10n.Instance["status.attention"]` |
| 341 | `"任务已中断"` | `L10n.Instance["status.error"]` |
| 344 | `"状态未知"` | `L10n.Instance["status.unknown"]` |
| 374 | `"暂无数据"` | `L10n.Instance["quota.no_data"]` |
| 378 | `"暂无数据"` | `L10n.Instance["quota.no_data"]` |
| 605 | `"5 小时额度"` | `L10n.Instance["quota.5h"]` |
| 606 | `"周额度"` | `L10n.Instance["quota.weekly"]` |
| 620 | `"月额度"` | `L10n.Instance["quota.monthly"]` |
| 640 | `"暂无数据"` | `L10n.Instance["quota.no_data"]` |
| 648 | `"等待 Codex 刷新"` | `L10n.Instance["quota.waiting_refresh"]` |
| 656 | `"剩余 {0:0}%"` | `L10n.Instance.Format("quota.remaining", remaining)` |
| 666 | `"等待 Codex 刷新"` | `L10n.Instance["quota.waiting_refresh"]` |
| 709 | `"暂无数据"` | `L10n.Instance["quota.no_data"]` |
| 743 | `"暂无数据"` | `L10n.Instance["quota.no_data"]` |

- [ ] **Step 3: Replace date format strings (lines 685-686)**

**Old:**
```csharp
? local.ToString("HH:mm '刷新'", CultureInfo.CurrentCulture)
: local.ToString("M月d日 HH:mm '刷新'", CultureInfo.CurrentCulture);
```

**New:**
```csharp
var culture = L10n.Instance.CurrentLanguage == "zh"
    ? new CultureInfo("zh-CN") : new CultureInfo("en-US");
var format = isToday
    ? L10n.Instance["date.today_format"]
    : L10n.Instance["date.other_format"];
return local.ToString(format, culture);
```

- [ ] **Step 4: Add RefreshAllText method to DetailsWindow**

```csharp
private void RefreshAllText()
{
    if (contextLabel != null)
        contextLabel.Text = L10n.Instance["context.title"];
    if (fiveHourLabel != null)
        fiveHourLabel.Text = showsMonthly
            ? L10n.Instance["quota.monthly"]
            : L10n.Instance["quota.5h"];
    if (weekLabel != null)
        weekLabel.Text = L10n.Instance["quota.weekly"];
    // Force a full update pass
    Update(currentAggregate, currentQuota, currentContextPercent, currentSessionDetails);
}
```

- [ ] **Step 5: Verify compilation (Windows)**

Expected: BUILD SUCCESS

- [ ] **Step 6: Commit**

```bash
git add src/windows/DetailsWindow.cs
git commit -m "refactor: migrate Windows DetailsWindow Chinese strings to L10n"
```

---

### Task 10: Migrate Windows HaloWindow.cs — menu items + language submenu

**Files:**
- Modify: `src/windows/HaloWindow.cs`

**Interfaces:**
- Consumes: `L10n.Instance[key]`, `L10n.Instance.LanguageChanged` (from Task 8)

- [ ] **Step 1: Replace all menu item Chinese strings**

Replace each hardcoded Chinese string in `HaloWindow.cs` with `L10n.Instance["key"]`:

| Line | Old Chinese | New L10n Call |
|------|------------|---------------|
| 327 | `"Claude Code 正在待命"` | `L10n.Instance["status.standby_claude"]` |
| 423 | `"Codex 正在待命"` | `L10n.Instance["status.standby_codex"]` |
| 805 | `"始终置顶"` | `L10n.Instance["menu.always_on_top"]` |
| 820 | `"开机自动启动"` | `L10n.Instance["menu.launch_at_startup"]` |
| 832 | `"暂停状态监听"` | `L10n.Instance["menu.pause_monitor"]` |
| 846 | `"监控对象"` | `L10n.Instance["menu.focus_target"]` |
| 867 | `"脱离卡死（移到主屏右上角）"` | `L10n.Instance["menu.escape_offscreen"]` |
| 873 | `"光环大小"` | `L10n.Instance["halo.size"]` |
| 900 | `"预览状态"` | `L10n.Instance["menu.preview_status"]` |
| 901 | `"实时状态"` | `L10n.Instance["halo.live_status"]` |
| 902 | `"思考中"` | `L10n.Instance["halo.thinking_preview"]` |
| 903 | `"执行中"` | `L10n.Instance["halo.working_preview"]` |
| 904 | `"已完成"` | `L10n.Instance["halo.done_preview"]` |
| 905 | `"等待授权（双脉冲）"` | `L10n.Instance["halo.attention_preview"]` |
| 906/908 | `"故障（爆闪）"` | `L10n.Instance["halo.error_flash_preview"]` |
| 906/908 | `"故障（常亮）"` | `L10n.Instance["halo.error_bright_preview"]` |
| 906/910 | `"故障（暗红）"` | `L10n.Instance["halo.error_dim_preview"]` |
| 912 | `"待机"` | `L10n.Instance["halo.idle_preview"]` |
| 916 | `"退出"` | `L10n.Instance["menu.quit"]` |

- [ ] **Step 2: Add language submenu to tray menu**

After the "监控对象" (focus) submenu section, add:

```csharp
            // Language submenu
            var languageItem = new Forms.ToolStripMenuItem(L10n.Instance["menu.language"]);
            languageItem.DropDownItems.Add(CreateLanguageItem(null));  // Follow System
            languageItem.DropDownItems.Add(CreateLanguageItem("zh"));   // 中文
            languageItem.DropDownItems.Add(CreateLanguageItem("en"));   // English
            menu.Items.Add(languageItem);
```

- [ ] **Step 3: Add CreateLanguageItem helper and language change handler**

```csharp
    private Forms.ToolStripMenuItem CreateLanguageItem(string lang)
    {
        string title = lang != null
            ? L10n.Instance["menu.language." + lang]
            : L10n.Instance["menu.language.auto"];
        var item = new Forms.ToolStripMenuItem(title, null, OnLanguageSelected);
        item.Tag = lang;
        string effective = settings.Language ?? L10n.DetectSystemLanguage();
        item.Checked = (lang == effective);
        return item;
    }

    private void OnLanguageSelected(object sender, EventArgs e)
    {
        var item = sender as Forms.ToolStripMenuItem;
        string lang = item?.Tag as string;
        settings.Language = lang;
        SettingsStorage.Save(settings);
        L10n.Instance.SetLanguage(lang);
    }
```

- [ ] **Step 4: Subscribe to LanguageChanged to refresh the menu**

In the HaloWindow initialization, add:

```csharp
L10n.Instance.LanguageChanged += (s, ev) =>
{
    this.Invoke((Action)(() =>
    {
        RebuildTrayMenu();
    }));
};
```

- [ ] **Step 5: Verify compilation (Windows)**

Expected: BUILD SUCCESS

- [ ] **Step 6: Commit**

```bash
git add src/windows/HaloWindow.cs
git commit -m "feat: add language submenu and migrate Windows HaloWindow to L10n"
```

---

### Task 11: Migrate Windows GeneratedHaloSpec.cs — classifyFailure to L10n keys

**Files:**
- Modify: `src/windows/GeneratedHaloSpec.cs`
- Modify: Callers of `classifyFailure()` in Windows code

**Interfaces:**
- Consumes: `L10n.Instance[key]` (from Task 8)
- Produces: `classifyFailure()` returns L10n keys instead of Chinese strings

- [ ] **Step 1: Update classifyFailure to return L10n keys**

Edit `src/windows/GeneratedHaloSpec.cs`, lines 243-246:

**Old:**
```csharp
            if (ContainsAny(value, new string[] { "authentication failed", "unauthorized", "invalid token", "sign in again" })) return "认证已失效";
            if (ContainsAny(value, new string[] { "rate limit reached", "usage limit", "quota exceeded", "rate_limit_reached" })) return "额度已用尽";
            if (ContainsAny(value, new string[] { "service unavailable", "server overloaded", "overloaded", "bad gateway" })) return "服务暂时不可用";
            if (ContainsAny(value, new string[] { "connection failed", "network error", "connection aborted", "request timed out", "connect timeout" })) return "连接 Codex 失败";
```

**New:**
```csharp
            if (ContainsAny(value, new string[] { "authentication failed", "unauthorized", "invalid token", "sign in again" })) return "failure.auth_expired";
            if (ContainsAny(value, new string[] { "rate limit reached", "usage limit", "quota exceeded", "rate_limit_reached" })) return "failure.quota_exhausted";
            if (ContainsAny(value, new string[] { "service unavailable", "server overloaded", "overloaded", "bad gateway" })) return "failure.service_unavailable";
            if (ContainsAny(value, new string[] { "connection failed", "network error", "connection aborted", "request timed out", "connect timeout" })) return "failure.connection_failed";
```

- [ ] **Step 2: Find and update all callers**

```bash
grep -rn 'classifyFailure\|ClassifyFailure' src/windows --include="*.cs"
```

For each caller, wrap the returned key with `L10n.Instance[...]` to get the display string. Example:

```csharp
// Old:
var detail = HaloSpec.ClassifyFailure(text);
// New:
var key = HaloSpec.ClassifyFailure(text);
var detail = key != null ? L10n.Instance[key] : null;
```

- [ ] **Step 3: Verify compilation (Windows)**

Expected: BUILD SUCCESS

- [ ] **Step 4: Commit**

```bash
git add src/windows/GeneratedHaloSpec.cs
# Add any caller files that were modified
git commit -m "refactor: Windows classifyFailure returns L10n keys instead of Chinese"
```

---
