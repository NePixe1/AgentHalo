# i18n 国际化设计

## 目标

将 Agent Halo 从单一中文应用改造为支持多语言的应用。初期支持中文和英文，架构上预留多语言扩展能力。macOS 和 Windows 两端同步实施。

## 语言选择策略

优先级从高到低：

1. 用户手动设置的语言（持久化在 Settings 中）
2. 操作系统当前语言
3. 若系统语言不在支持列表中 → fallback 到中文（zh）

支持的语言列表在代码中硬编码为一个常量数组，扩展时只需追加。

## 文件结构

```
src/
  shared/
    locales/
      zh.json        ← 中文（默认/fallback）
      en.json        ← 英文
      ja.json        ← 将来扩展…
  macos/Sources/
    AgentHaloCore/
      L10n.swift              ← LocaleManager，语言解析 + JSON 加载 + 运行时 API
  windows/
    L10n.cs                   ← 同上（C# 实现）
```

## JSON 数据格式

每种语言一个独立 JSON 文件，扁平 key-value 结构：

```json
{
  "category.snake_case_key": "翻译文本",
  "category.key_with_params": "文本 {0} 占位 {1}"
}
```

- Key 命名：`category.snake_case_key`
- 参数占位：`{0}`, `{1}`, …
- 永不删除已有 key（向后兼容）
- 每个新语言只需复制 zh.json 并翻译

### Key 分类总览

| Category | 内容 | 参数 |
|----------|------|------|
| `menu.*` | 菜单栏和右键菜单项 | 无 |
| `status.*` | 状态详情文本 | 无 |
| `quota.*` | 额度标签和数值 | `{0}` = 百分比数值 |
| `context.*` | 上下文窗口显示 | `{0}` = 百分比（label），title 无参数 |
| `metadata.*` | 元数据行标题（项目、模型等） | 无 |
| `failure.*` | 错误分类文本 | 无 |
| `halo.*` | 光环预览子菜单项 | 无 |
| `date.*` | 日期格式化模板 | 无 |

### JSON Key 完整清单

```
menu.always_on_top
menu.launch_at_startup
menu.pause_monitor
menu.focus_target
menu.escape_offscreen
menu.preview_status
menu.quit
menu.language
menu.language.auto
menu.language.zh
menu.language.en

status.offline_codex
status.offline_claude
status.standby_codex
status.standby_claude
status.paused
status.thinking
status.working
status.done
status.attention
status.error
status.writing_answer
status.running_command
status.editing_files
status.searching
status.compressing_context
status.context_compacted
status.awaiting_permission
status.permission_denied
status.reviewing_result
status.unknown

quota.5h
quota.weekly
quota.monthly
quota.remaining
quota.no_data
quota.waiting_refresh

context.title
context.label
context.empty

metadata.project
metadata.model
metadata.tokens
metadata.separator

failure.auth_expired
failure.quota_exhausted
failure.service_unavailable
failure.connection_failed

halo.size
halo.live_status
halo.thinking_preview
halo.working_preview
halo.done_preview
halo.attention_preview
halo.error_flash_preview
halo.error_bright_preview
halo.error_dim_preview
halo.idle_preview

date.today_format
date.other_format
date.refresh_suffix
```

### 英文翻译

```json
{
  "menu.always_on_top": "Always on Top",
  "menu.launch_at_startup": "Launch at Login",
  "menu.pause_monitor": "Pause Monitoring",
  "menu.focus_target": "Monitor",
  "menu.escape_offscreen": "Reset Position (Move to Top-Right)",
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
  "status.writing_answer": "Writing Answer",
  "status.running_command": "Running Command",
  "status.editing_files": "Editing Files",
  "status.searching": "Searching",
  "status.compressing_context": "Compressing Context",
  "status.context_compacted": "Context Compacted",
  "status.awaiting_permission": "Awaiting Permission",
  "status.permission_denied": "Permission Denied",
  "status.reviewing_result": "Reviewing Result",
  "status.unknown": "Unknown Status",

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
  "metadata.separator": "  ·  ",

  "failure.auth_expired": "Authentication Expired",
  "failure.quota_exhausted": "Quota Exhausted",
  "failure.service_unavailable": "Service Unavailable",
  "failure.connection_failed": "Connection Failed",

  "halo.size": "Halo Size",
  "halo.live_status": "Live Status",
  "halo.thinking_preview": "Thinking",
  "halo.working_preview": "Working",
  "halo.done_preview": "Done",
  "halo.attention_preview": "Awaiting Authorization (Double Pulse)",
  "halo.error_flash_preview": "Error (Flashing)",
  "halo.error_bright_preview": "Error (Solid Bright)",
  "halo.error_dim_preview": "Error (Dim Red)",
  "halo.idle_preview": "Idle",

  "date.today_format": "HH:mm 'refresh'",
  "date.other_format": "MMM d, HH:mm 'refresh'",
  "date.refresh_suffix": "refresh"
}
```

## 运行时架构

### L10n 单例（两端统一模式）

**macOS (Swift)** — `L10n.swift` 放在 `AgentHaloCore` target：

```swift
public final class L10n: @unchecked Sendable {
    public static let shared = L10n()

    public var currentLanguage: String { ... }  // "zh" / "en"

    public func setLanguage(_ lang: String?)    // nil = 跟随系统
    public subscript(_ key: String) -> String { get }
    public func format(_ key: String, _ args: CVarArg...) -> String

    // 通知
    public static let languageDidChange = Notification.Name("L10n.languageDidChange")
}
```

**Windows (C#)** — `L10n.cs`：

```csharp
public sealed class L10n
{
    public static L10n Instance { get; }

    public string CurrentLanguage { get; }

    public void SetLanguage(string lang);  // null = follow system
    public string this[string key] { get; }
    public string Format(string key, params object[] args);

    public event EventHandler LanguageChanged;
}
```

### 语言解析流程

1. 检查 `Settings.language`（用户手动设置）
2. 若非 nil → 使用该语言
3. 若 nil → 检测系统语言（macOS: `Locale.preferredLanguages`, Windows: `CultureInfo.CurrentUICulture`）
4. 若系统语言不在 `supportedLanguages` 列表中 → fallback 到 `"zh"`
5. 加载对应 JSON 文件到内存字典

### 日期格式化适配

- `DetailsPanel.formatResetTime`（macOS）/ `DetailsWindow`（Windows）中的硬编码 `Locale("zh_CN")` 和 `"M月d日 HH:mm '刷新'"` 格式串 → 改为从 L10n 取 `date.today_format` / `date.other_format` 模板，locale 由当前语言决定
- 格式串中的 `'刷新'` 部分变为 `date.refresh_suffix` 占位替换

### UI 刷新机制

- **菜单栏**：语言切换时重建 NSMenu / ContextMenuStrip
- **详情面板**：各处调用 `L10n.shared[key]` 动态取文本，语言切换后下次 `update()` 自动反映新语言
- **光环**：纯视觉元素，无文本，不受影响

## Settings 扩展

### macOS

`HaloSettings` 增加字段：

```swift
public var language: String? = nil  // nil = 跟随系统
```

`settingsStore.save(settings)` 序列化时自动持久化。

### Windows

`Settings` 类增加对应属性，`SettingsStore` 自动序列化。

## 迁移文件清单

### macOS (Swift)

| 文件 | 改动 |
|------|------|
| `AgentHaloCore/HaloModels.swift` | `localizedStandbyDetail`/`localizedOfflineDetail` 改用 L10n |
| `AgentHaloCore/GeneratedHaloSpec.swift` | `classifyFailure()` 返回值从硬编码中文 → L10n key |
| `AgentHaloCore/CodexRealtimeActivityReader.swift` | 中文压缩匹配数组保持不变，这些是**检测模式**非显示文本，需同时匹配中英文 |
| `AgentHaloMac/AppDelegate.swift` | 所有菜单项文字改用 L10n |
| `AgentHaloMac/DetailsPanel.swift` | 所有硬编码中文 → L10n；日期格式适配 |
| `AgentHaloMac/HaloInteractionChecks.swift` | 测试断言中的中文字符串 → L10n |

### Windows (C#)

| 文件 | 改动 |
|------|------|
| `HaloWindow.cs` | 所有菜单项文字 → L10n |
| `DetailsWindow.cs` | 所有硬编码中文 → L10n；日期格式适配 |
| `GeneratedHaloSpec.cs` | `classifyFailure()` → L10n |
| `CodexMonitor.cs` | 中文压缩匹配数组保持不变（检测模式，非显示文本） |
| `Diagnostics.cs` | 如有中文文本 |

### 不需要国际化的内容

- 代码注释（保持中文）
- 日志输出（面向开发者）
- 调试/诊断输出
- `AgentKind.menuTitle` / `segmentedTitle`（已有英文值，无需翻译）

## 不需要国际化的视觉元素

根据 [[ring-visuals-invariant]]，光环渲染相关的视觉代码（HaloRenderer/HaloView 等）不受影响，因为光环是纯视觉元素，不含文字。

## 测试策略

- `HaloInteractionChecks.swift` 中的测试断言改为使用 L10n 取值，确保开关语言后测试仍然通过
- 各 L10n 实现需要覆盖：
  - 系统语言检测正确
  - 手动设置语言正确
  - Fallback 到中文正确
  - 参数格式化正确
  - 未知语言 fallback

## 将来扩展

添加新语言只需三步：

1. 复制 `zh.json` → 新语言文件（如 `ja.json`）
2. 翻译所有 value
3. 在 `supportedLanguages` 数组中追加语言代码

无需修改任何业务逻辑代码。
