# macOS Antigravity Agent Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 AgentHalo macOS 上把 Antigravity CLI（`agy`）接成可选第五个监控对象：Gemini 5h/Weekly 额度可显示，最小 hook 生命周期驱动光环，且 `agy` 事件不污染 Claude/Grok 日志。

**Architecture:** 额度沿用 `AuthStore → UsageClient → UsageMapper → UsageProvider → UsageSnapshotCache → Coordinator`，从 OpenUsage Antigravity provider 移植（LS 优先，否则 Keychain + Cloud Code；只映射 `gemini-5h` / `gemini-weekly`）。生命周期沿用 Claude/Grok hook 模式：共用 `status-hook` 按 `ANTIGRAVITY_AGENT` / `ANTIGRAVITY_TRAJECTORY_ID` 分流写 `antigravity-status.jsonl`；`AntigravityHookConfigurator` 合并写入 `~/.gemini/config/hooks.json` 的 named group `agent-halo-status`。UI 焦点增加 `AG`，默认关闭。

**Tech Stack:** Swift 6、SwiftPM、AppKit、Foundation/URLSession、CryptoKit、Security.framework、现有 `AgentHaloCoreChecks` / `AgentHaloMac --self-check`

**Spec:** [2026-08-14-antigravity-agent-macos-design.md](../specs/2026-08-14-antigravity-agent-macos-design.md)

## Global Constraints

- 只改 macOS 与共享 locales/SVG；**不改 Windows 运行时代码或 `src/windows/locales`**。
- 分段标签固定 **`AG`**；菜单名 **`Antigravity`**。
- `HaloSettings.defaultEnabledAgents` 保持 `[.codex, .claudeCode, .grok, .pi]`。
- 额度只产出 Gemini 两窗；丢掉 `3p-*`；不扩展 `UsageWindowKind`。
- 详情面板两行额度高度与文案（`quota.5h` / `quota.weekly`）不改。
- 只在 `focusedAgent == .antigravity` 时刷新额度；周期沿用 Coordinator 5 分钟。
- 刷新 token **只写** `~/.agent-halo/cache/antigravity-auth.json`，**永不写回** Keychain `gemini`/`antigravity`。
- `resolveAccess` **禁止**返回 `.apiKey`。
- 额度失败不得改变 halo 生命周期。
- Hook 判定为 Antigravity 时**禁止**写入 `claude-status.jsonl` / `grok-status.jsonl`。
- 不把 IDE `language_server` 当成 CLI presence；context pill 为空；不点击唤起窗口。
- 每项任务 TDD：先加失败检查 → 确认失败 → 最小实现 → 聚焦检查通过 → 提交。
- 提交前 `git status --short`，只暂存本任务文件。

---

## 目标文件总览

新增：

```text
src/macos/Sources/AgentHaloCore/UsageMonitoring/Antigravity/
├── AntigravityAuthStore.swift
├── AntigravityLoopbackHTTPClient.swift
├── AntigravityLanguageServerDiscovery.swift
├── AntigravityUsageClient.swift
├── AntigravityUsageMapper.swift
└── AntigravityUsageProvider.swift
src/macos/Sources/AgentHaloCore/AntigravityHookConfigurator.swift
src/macos/Sources/AgentHaloCore/AntigravityHookStatusMonitor.swift
src/macos/Sources/AgentHaloCore/AntigravityHookStatusReducer.swift
src/macos/Sources/AgentHaloMac/AntigravityActivityMonitor.swift
src/shared/assets/agent-switch/antigravity.svg
src/macos/Sources/AgentHaloCoreChecks/AntigravityUsageChecks.swift
```

修改：

```text
src/macos/Sources/AgentHaloCore/HaloModels.swift
src/macos/Sources/AgentHaloCore/HaloSettings.swift          # 只读确认，不改 defaultEnabledAgents
src/macos/Sources/AgentHaloCore/AgentHaloPaths.swift
src/macos/Sources/AgentHaloCore/AgentHaloRuntimeBootstrap.swift
src/macos/Sources/AgentHaloCore/UsageMonitoring/UsageModels.swift
src/macos/Sources/AgentHaloCore/UsageMonitoring/DetailsContentResolver.swift
src/macos/Sources/AgentHaloCore/UsageMonitoring/UsageMonitoringCoordinator.swift
src/macos/Sources/ClaudeCodeStatusHook/main.swift
src/macos/Sources/AgentHaloMac/AppDelegate.swift
src/macos/Sources/AgentHaloMac/DetailsPanel.swift
src/macos/Sources/AgentHaloMac/SettingsWindowController.swift
src/macos/Sources/AgentHaloMac/HaloInteractionChecks.swift
src/macos/Sources/AgentHaloCoreChecks/main.swift
src/macos/Sources/AgentHaloCoreChecks/UsageMonitoringChecks.swift
src/shared/locales/{en,zh}.json
src/macos/Sources/AgentHaloCore/locales/{en,zh}.json
docs/PRODUCT.md
README.md
README.zh-CN.md
AGENTS.md
```

公开接口（本计划锁定）：

```swift
public enum AgentKind { /* + case antigravity */ }
public enum UsageProviderID { /* + case antigravity */ }

extension AgentHaloPaths {
    public var antigravityStatusLog: URL {
        logsDirectory.appendingPathComponent("antigravity-status.jsonl")
    }
}

public enum AntigravityUsageMapper {
    public static let sessionDuration: TimeInterval = 18_000
    public static let weeklyDuration: TimeInterval = 604_800
    public static func mapQuotaSummary(
        response: UsageHTTPResponse,
        accountKey: AccountCacheKey,
        planName: String?,
        now: Date
    ) throws -> UsageSnapshot
    /// `nil` = not a summary envelope (caller may fall back to legacy).
    public static func windowsFromQuotaSummaryBody(_ data: Data) -> [UsageWindow]?
    /// Legacy per-model Gemini configs → at most one `.session` window. Never weekly.
    public static func sessionWindowFromLegacyGeminiConfigs(
        remainingFractions: [Double],
        resetTime: Date?
    ) -> UsageWindow?
    public static func formatPlan(_ raw: String?) -> String?
}

public struct AntigravityLanguageServerDiscovery: Sendable {
    public struct Options: Sendable {
        public var processName: String
        public var markers: [String]
        public var csrfFlag: String
        public var portFlag: String?
    }
    public struct Result: Sendable {
        public var pid: Int32
        public var csrf: String
        public var ports: [Int]
        public var extensionPort: Int?
    }
    public func discover(_ options: Options) -> Result?
}

public struct AntigravityAuthStore: Sendable {
    public static let keychainService = "gemini"
    public static let keychainAccount = "antigravity"
    public static let refreshBuffer: TimeInterval = 60
    public static let localLSAccountDigest = UsageDigest.sha256("antigravity-ls")
    public func resolveAccess(lsAvailable: Bool) -> ResolvedProviderAccess
    public func loadKeychainToken() throws -> AntigravityKeychainToken?
    public func loadCachedAccessToken(matching source: AntigravityKeychainToken) -> String?
    public func cacheAccessToken(_ token: String, expiresIn: Double, sourceRefreshToken: String) throws
}

public struct AntigravityUsageProvider: UsageProvider, Sendable {
    public let providerID: UsageProviderID = .antigravity
    public func resolveAccess(accountKey: AccountCacheKey?) async -> ResolvedProviderAccess
    public func refresh(using access: ResolvedProviderAccess) async -> UsageRefreshResult
}
```

验证命令（全文通用）：

```bash
cd src/macos
swift run AgentHaloCoreChecks
```

---

### Task 1: AgentKind.antigravity + locales + SVG + 穷尽 switch 能编译

**Files:**
- Modify: `src/macos/Sources/AgentHaloCore/HaloModels.swift`
- Modify: `src/macos/Sources/AgentHaloCore/UsageMonitoring/UsageModels.swift`
- Modify: `src/macos/Sources/AgentHaloCore/UsageMonitoring/DetailsContentResolver.swift`
- Modify: `src/macos/Sources/AgentHaloCore/AgentHaloPaths.swift`
- Modify: `src/macos/Sources/AgentHaloMac/AppDelegate.swift`
- Modify: `src/macos/Sources/AgentHaloMac/DetailsPanel.swift`
- Modify: `src/macos/Sources/AgentHaloMac/SettingsWindowController.swift`
- Modify: `src/macos/Sources/AgentHaloMac/HaloInteractionChecks.swift`
- Modify: `src/macos/Sources/AgentHaloCoreChecks/main.swift`
- Modify: `src/shared/locales/en.json`, `src/shared/locales/zh.json`
- Modify: `src/macos/Sources/AgentHaloCore/locales/en.json`, `zh.json`（与 shared 同步）
- Create: `src/shared/assets/agent-switch/antigravity.svg`

**Interfaces:**
- Produces: `AgentKind.antigravity`（`menuTitle = "Antigravity"`，`segmentedTitle = "AG"`）；`UsageProviderID.antigravity`；`AgentHaloPaths.antigravityStatusLog`；L10n keys `status.standby_antigravity` / `status.offline_antigravity` / `usage.warning.sign_in_antigravity`
- 本任务只让工程编译、设置默认仍四开。AppDelegate 的 AG 分支先返回空快照 / `isPresent = false`，Task 9 再接线。

- [ ] **Step 1: 写失败检查**

在 `AgentHaloCoreChecks/main.swift` 的 settings 检查附近追加：

```swift
func testAntigravityKindIsOptInAndPersistsWhenEnabled() throws {
    expect(AgentKind.antigravity.menuTitle, "Antigravity", "menu title")
    expect(AgentKind.antigravity.segmentedTitle, "AG", "segmented title")
    expect(
        HaloSettings.defaultEnabledAgents.contains(.antigravity),
        false,
        "new AgentKind must stay opt-in"
    )
    expect(
        HaloSettings.defaultEnabledAgents,
        [.codex, .claudeCode, .grok, .pi],
        "frozen default-on set"
    )

    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("agent-halo-ag-settings-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("settings.json")

    var settings = HaloSettings(focusedAgent: .antigravity, enabledAgents: [.codex, .antigravity])
    expect(settings.enabledAgents.contains(.antigravity), true, "can enable antigravity")
    expect(settings.focusedAgent, .antigravity, "focus can be antigravity when enabled")
    SettingsStore(settingsURL: url).save(settings)
    let loaded = SettingsStore(settingsURL: url).load()
    expect(loaded.focusedAgent, .antigravity, "focused antigravity persists")
    expect(loaded.enabledAgents.contains(.antigravity), true, "enabled antigravity persists")

    settings.setAgent(.antigravity, enabled: false)
    expect(settings.enabledAgents.contains(.antigravity), false, "can disable antigravity")
    expect(settings.focusedAgent, .codex, "focus leaves antigravity when disabled")
}
```

在 `UsageMonitoringChecks.swift` 的 `testDetailsContentResolver` 附近追加：

```swift
func testAntigravityDetailsResolverUsesUsageBodyAndSignInCopy() {
    let state = UsageMonitorState(
        providerID: .antigravity,
        accessMode: .oauth,
        snapshot: nil,
        status: .signInAgain,
        lastFailure: .signInAgain,
        isRefreshing: false
    )
    let model = DetailsContentResolver.resolve(
        providerID: .antigravity,
        monitorState: state,
        isOffline: false,
        sessionDetails: SessionDetailsSnapshot(),
        contextUsedPercent: 12,
        now: Date()
    )
    expect(model.providerName, "Antigravity", "AG provider name")
    expect(model.usageWarning, L10n.shared["usage.warning.sign_in_antigravity"], "AG sign-in copy")
    if case .usage = model.body {} else {
        fatalError("antigravity oauth must stay on usage body, not session card")
    }
}
```

在 `HaloInteractionChecks.swift` 的 `testAgentToggleUsesSharedSVGAssets` 增加 `antigravity.svg` 存在断言。把 `usageProviderID` 源码断言扩成同时要求 `case .antigravity:` + `return .antigravity`（保留 Pi → `nil`）。

在 `main.swift` 调用新检查。在 `runUsageModelChecks` 调用 `testAntigravityDetailsResolverUsesUsageBodyAndSignInCopy()`。

- [ ] **Step 2: 运行检查确认失败**

```bash
cd src/macos && swift run AgentHaloCoreChecks 2>&1 | tail -50
```

Expected: 编译失败（无 `.antigravity`）或 expect 失败。

- [ ] **Step 3: 最小实现**

`HaloModels.swift`：`case antigravity` 放在 `allCases` 最后。所有 `switch self` 补：

```swift
case .antigravity:
    return "Antigravity"          // menuTitle / standbyDetail 英文
// segmentedTitle:
    return "AG"
// localizedStandbyDetail:
    return L10n.shared["status.standby_antigravity"]
// localizedOfflineDetail:
    return L10n.shared["status.offline_antigravity"]
```

`UsageModels.swift`：

```swift
public enum UsageProviderID: String, Codable, Sendable {
    case codex, claude, grok, antigravity
}
```

`DetailsContentResolver.swift`：两个 `switch providerID` 补：

```swift
case .antigravity:
    return "Antigravity"
// warning:
    return L10n.shared["usage.warning.sign_in_antigravity"]
```

`AgentHaloPaths.swift`：

```swift
public var antigravityStatusLog: URL {
    logsDirectory.appendingPathComponent("antigravity-status.jsonl")
}
```

`AppDelegate.swift` 所有 `switch` / `if focusedAgent` 补 `.antigravity`：

- `usageProviderID(for:)` → `return .antigravity`
- `hasLiveSessionForFocusedAgent` → `return false`（Task 9 改）
- `updateDetailsPanelContent` → session 空、`exactContextUsedPercent = nil`
- `updatePollingContext` 暂不调用 AG monitor
- enable-on 刷新：`case .antigravity: break`

`DetailsPanel.swift` `AgentToggleView`：新增 `antigravityIcon`，`configureIcon(..., assetName: "antigravity", ...)`，`icon(for:)` / alpha 分支补上。`update` 的 `switch focusedAgent` 把 `.antigravity` 和 `.pi` 一样走空 context（或单独 case 传 `nil`）。

`SettingsWindowController.swift` 图标 switch：`case .antigravity: assetName = "antigravity"`。

Locales（en / zh，shared + Core 副本四份）：

```json
"status.standby_antigravity": "Antigravity is standing by",
"status.offline_antigravity": "Antigravity is not running",
"usage.warning.sign_in_antigravity": "Start Antigravity or run `agy` and try again."
```

```json
"status.standby_antigravity": "Antigravity 待机中",
"status.offline_antigravity": "Antigravity 未在运行",
"usage.warning.sign_in_antigravity": "请打开 Antigravity 或运行 `agy` 后再试。"
```

`antigravity.svg`：24×24、`fill="#111111"`、无装饰色，单色几何标记（克制的倒三角 + 横杠，不要抄 Google 商标）。`<title>Antigravity</title>`。

编译器标出的其它穷尽 `switch` 一并补 case。不要改 `defaultEnabledAgents`。

- [ ] **Step 4: 运行检查**

```bash
cd src/macos && swift run AgentHaloCoreChecks
```

Expected: 新检查 PASS；`defaultEnabledAgents` 既有检查不回归。

- [ ] **Step 5: Commit**

```bash
git add src/macos/Sources/AgentHaloCore/HaloModels.swift \
  src/macos/Sources/AgentHaloCore/UsageMonitoring/UsageModels.swift \
  src/macos/Sources/AgentHaloCore/UsageMonitoring/DetailsContentResolver.swift \
  src/macos/Sources/AgentHaloCore/AgentHaloPaths.swift \
  src/macos/Sources/AgentHaloMac/AppDelegate.swift \
  src/macos/Sources/AgentHaloMac/DetailsPanel.swift \
  src/macos/Sources/AgentHaloMac/SettingsWindowController.swift \
  src/macos/Sources/AgentHaloMac/HaloInteractionChecks.swift \
  src/macos/Sources/AgentHaloCoreChecks/main.swift \
  src/macos/Sources/AgentHaloCoreChecks/UsageMonitoringChecks.swift \
  src/shared/locales/en.json src/shared/locales/zh.json \
  src/macos/Sources/AgentHaloCore/locales/en.json \
  src/macos/Sources/AgentHaloCore/locales/zh.json \
  src/shared/assets/agent-switch/antigravity.svg
git commit -m "feat(macos): add opt-in Antigravity agent kind"
```

---

### Task 2: AntigravityUsageMapper（只映射 Gemini 两窗）

**Files:**
- Create: `src/macos/Sources/AgentHaloCore/UsageMonitoring/Antigravity/AntigravityUsageMapper.swift`
- Create: `src/macos/Sources/AgentHaloCoreChecks/AntigravityUsageChecks.swift`
- Modify: `src/macos/Sources/AgentHaloCoreChecks/UsageMonitoringChecks.swift`（`await runAntigravityUsageChecks()`）

**Interfaces:**
- Consumes: `UsageSnapshot` / `UsageWindow` / `AccountCacheKey` / `UsageHTTPResponse`
- Produces: `AntigravityUsageMapper.mapQuotaSummary`、`windowsFromQuotaSummaryBody`、`formatPlan`

- [ ] **Step 1: 写失败检查**

`AntigravityUsageChecks.swift`：

```swift
import Foundation
import AgentHaloCore

func runAntigravityUsageChecks() async {
    try! testAntigravityMapperKeepsOnlyGeminiWindows()
    testAntigravityMapperLegacyGeminiIsSessionOnly()
    testAntigravityMapperDropsMissingFraction()
    testAntigravityMapperIgnoresUnknownAnd3PBuckets()
    testAntigravityMapperRejectsNonSummary()
    testAntigravityMapperHTTPErrors()
    testAntigravityFormatPlan()
}

func testAntigravityMapperKeepsOnlyGeminiWindows() throws {
    let json = """
    {"groups":[
      {"buckets":[
        {"bucketId":"3p-weekly","remainingFraction":1,"resetTime":"2026-07-06T07:00:00Z"},
        {"bucketId":"3p-5h","remainingFraction":0.4,"resetTime":"2026-07-02T15:30:00Z"},
        {"bucketId":"gemini-5h","remainingFraction":0.75,"resetTime":"2026-07-02T16:00:00Z"},
        {"bucketId":"gemini-weekly","remainingFraction":0.9,"resetTime":"2026-07-06T07:00:00Z"}
      ]}
    ]}
    """
    let key = AccountCacheKey(providerID: .antigravity, digest: "d")
    let snap = try AntigravityUsageMapper.mapQuotaSummary(
        response: UsageHTTPResponse(statusCode: 200, headers: [:], body: Data(json.utf8)),
        accountKey: key,
        planName: "Pro",
        now: Date(timeIntervalSince1970: 1)
    )
    expect(snap.windows.count, 2, "only gemini windows")
    expect(snap.windows[0].kind, .session, "gemini-5h → session, always first")
    expect(snap.windows[0].usedPercent, 25, "1-0.75")
    expect(snap.windows[0].duration, 18_000, "5h duration")
    expect(snap.windows[1].kind, .weekly, "gemini-weekly → weekly")
    expect(snap.windows[1].usedPercent, 10, "1-0.9")
    expect(snap.windows[1].duration, 604_800, "weekly duration")
    expect(snap.planName, "Pro", "plan passthrough")

    let wrapped = AntigravityUsageMapper.windowsFromQuotaSummaryBody(
        Data("{\"response\":\(json)}".utf8)
    )
    expect(wrapped?.count, 2, "wrapped response.groups is a summary")
}

func testAntigravityMapperLegacyGeminiIsSessionOnly() {
    let window = AntigravityUsageMapper.sessionWindowFromLegacyGeminiConfigs(
        remainingFractions: [0.8, 0.5],
        resetTime: Date(timeIntervalSince1970: 9)
    )
    expect(window?.kind, .session, "legacy is 5h only")
    expect(window?.usedPercent, 50, "worst remaining fraction")
    expect(
        AntigravityUsageMapper.sessionWindowFromLegacyGeminiConfigs(
            remainingFractions: [],
            resetTime: nil
        ) == nil,
        true,
        "no gemini configs → no window"
    )
}

func testAntigravityMapperDropsMissingFraction() {
    let json = """
    {"groups":[{"buckets":[
      {"bucketId":"gemini-5h","resetTime":"2026-07-02T16:00:00Z"},
      {"bucketId":"gemini-weekly","remainingFraction":0.5,"resetTime":"2026-07-06T07:00:00Z"}
    ]}]}
    """
    let windows = AntigravityUsageMapper.windowsFromQuotaSummaryBody(Data(json.utf8))
    expect(windows?.count, 1, "drop bucket without fraction")
    expect(windows?.first?.kind, .weekly, "weekly survives")
    expect(windows?.first?.usedPercent, 50, "used percent")
}

func testAntigravityMapperIgnoresUnknownAnd3PBuckets() {
    let json = #"{"groups":[{"buckets":[{"bucketId":"gemini-image-5h","remainingFraction":0.1}]}]}"#
    let windows = AntigravityUsageMapper.windowsFromQuotaSummaryBody(Data(json.utf8))
    expect(windows?.isEmpty, true, "unknown bucket dropped")
}

func testAntigravityMapperRejectsNonSummary() {
    expect(
        AntigravityUsageMapper.windowsFromQuotaSummaryBody(Data(#"{"foo":1}"#.utf8)) == nil,
        true,
        "no groups → not a summary"
    )
}

func testAntigravityMapperHTTPErrors() {
    let key = AccountCacheKey(providerID: .antigravity, digest: "d")
    let cases: [(Int, UsageProviderFailure)] = [
        (401, .signInAgain),
        (503, .serviceUnavailable),
        (418, .invalidResponse),
    ]
    for (code, expected) in cases {
        do {
            _ = try AntigravityUsageMapper.mapQuotaSummary(
                response: UsageHTTPResponse(statusCode: code, headers: [:], body: Data()),
                accountKey: key,
                planName: nil,
                now: Date()
            )
            fatalError("expected throw for \(code)")
        } catch let error as UsageProviderFailure {
            expect(error, expected, "status \(code)")
        } catch {
            fatalError("wrong error type \(error)")
        }
    }
}

func testAntigravityFormatPlan() {
    expect(AntigravityUsageMapper.formatPlan("Google AI Pro"), "Pro", "strip Google AI prefix")
    expect(AntigravityUsageMapper.formatPlan("Gemini Code Assist in Google One AI Ultra"), "Ultra", "keyword")
    expect(AntigravityUsageMapper.formatPlan("   "), nil, "blank")
}
```

`UsageMonitoringChecks.swift` 的 `runUsageModelChecks` 末尾加 `await runAntigravityUsageChecks()`。

- [ ] **Step 2: 运行确认失败**

```bash
cd src/macos && swift run AgentHaloCoreChecks 2>&1 | tail -30
```

Expected: `AntigravityUsageMapper` 找不到。

- [ ] **Step 3: 最小实现**

移植 OpenUsage `AntigravityUsageMapper.parseQuotaSummary` 的解码形状（`groups[].buckets[]` 的 `bucketId` / `remainingFraction` / `resetTime`；接受 `{"groups":…}` 与 `{"response":{"groups":…}}`）。只认 `gemini-5h`、`gemini-weekly`。

```swift
public enum AntigravityUsageMapper {
    public static let sessionDuration: TimeInterval = 18_000
    public static let weeklyDuration: TimeInterval = 604_800

    public static func windowsFromQuotaSummaryBody(_ data: Data) -> [UsageWindow]? { /* nil = not a summary */ }

    public static func mapQuotaSummary(
        response: UsageHTTPResponse,
        accountKey: AccountCacheKey,
        planName: String?,
        now: Date
    ) throws -> UsageSnapshot {
        switch response.statusCode {
        case 200..<300: break
        case 401, 403: throw UsageProviderFailure.signInAgain
        case 429: throw UsageProviderFailure.rateLimited(retryAt: nil)
        case 500...599: throw UsageProviderFailure.serviceUnavailable
        default: throw UsageProviderFailure.invalidResponse
        }
        guard let windows = windowsFromQuotaSummaryBody(response.body) else {
            throw UsageProviderFailure.invalidResponse
        }
        return UsageSnapshot(
            providerID: .antigravity,
            accountKey: accountKey,
            planName: planName,
            windows: windows,
            refreshedAt: now
        )
    }

    public static func formatPlan(_ raw: String?) -> String? {
        // 对齐 OpenUsage：去 "Google AI " 前缀；否则命中 Ultra/Pro/Free
    }
}
```

`usedPercent = min(100, max(0, (1 - remainingFraction) * 100))`。缺 fraction 的 bucket 丢掉该行，不编造。未识别 `bucketId` 跳过。无 `groups` → `windowsFromQuotaSummaryBody` 返回 `nil`。窗顺序固定：先 `.session` 再 `.weekly`（JSON 乱序也一样）。

`sessionWindowFromLegacyGeminiConfigs`：取最小 `remainingFraction`（最差剩余），产出一个 `.session`；空数组返回 `nil`。不产出 weekly。Task 5 的 legacy LS/Cloud Code 路径只准走这个函数。

- [ ] **Step 4: 运行检查**

```bash
cd src/macos && swift run AgentHaloCoreChecks
```

Expected: mapper 检查 PASS。

- [ ] **Step 5: Commit**

```bash
git add src/macos/Sources/AgentHaloCore/UsageMonitoring/Antigravity/AntigravityUsageMapper.swift \
  src/macos/Sources/AgentHaloCoreChecks/AntigravityUsageChecks.swift \
  src/macos/Sources/AgentHaloCoreChecks/UsageMonitoringChecks.swift
git commit -m "feat(macos): map Antigravity Gemini quota windows"
```

---

### Task 3: AntigravityAuthStore（Keychain + 指纹缓存）

**Files:**
- Create: `src/macos/Sources/AgentHaloCore/UsageMonitoring/Antigravity/AntigravityAuthStore.swift`
- Modify: `src/macos/Sources/AgentHaloCoreChecks/AntigravityUsageChecks.swift`

**Interfaces:**
- Consumes: `UsageKeychainAccessing`、`UsageFileAccessing`、`AgentHaloPaths.cacheDirectory`
- Produces: `AntigravityKeychainToken`、`AntigravityAuthStore.resolveAccess(lsAvailable:)`、缓存读写

- [ ] **Step 1: 写失败检查**

用现有 `FakeUsageFiles` / in-memory keychain（看 `runGrokAuthChecks` / Claude auth fakes，复用同一套）。覆盖：

1. 无 Keychain 且 `lsAvailable == false` → `.oauthNeedsSignIn`，不是 `.apiKey`。
2. 无 Keychain 且 `lsAvailable == true` → `.oauth`，`accessToken == ""`，`accountKey.digest == AntigravityAuthStore.localLSAccountDigest`。
3. Keychain JSON（可带 `go-keyring-base64:` 前缀）→ `.oauth` 且带 access/refresh。
4. 缓存指纹不匹配 → `loadCachedAccessToken` 为 nil。`UsageFileAccessing` **没有** `remove`；丢弃方式是下次当 miss（可再 `writeAtomically` 空 `{}` 覆盖，不要扩展协议）。
5. 过期缓存（`expiresAtMs` 距今不足 60s）→ miss。
6. `extractToken` 纯函数：嵌套 `token.access_token`、Bearer 前缀、坏 JSON 返回 nil。

```swift
func testAntigravityResolveAccessNeverReturnsAPIKey() {
    let store = AntigravityAuthStore(
        homeDirectory: tmpHome,
        keychain: emptyKeychain,
        files: FakeUsageFiles()
    )
    if case .apiKey = store.resolveAccess(lsAvailable: false) {
        fatalError("must not be apiKey")
    }
    if case .oauthNeedsSignIn = store.resolveAccess(lsAvailable: false) {} else {
        fatalError("expected sign-in")
    }
    if case .oauth(let access) = store.resolveAccess(lsAvailable: true) {
        expect(access.accessToken.isEmpty, true, "LS-only token empty")
        expect(access.accountKey.digest, AntigravityAuthStore.localLSAccountDigest, "fixed LS digest")
    } else {
        fatalError("LS-only must be oauth")
    }
}
```

把这些函数挂进 `runAntigravityUsageChecks()`。

- [ ] **Step 2: 运行确认失败**

```bash
cd src/macos && swift run AgentHaloCoreChecks 2>&1 | tail -20
```

Expected: `AntigravityAuthStore` 找不到。

- [ ] **Step 3: 最小实现**

从 OpenUsage `AntigravityAuthStore` 移植 `extractToken` / `tokenFromObject` / `unwrapGoKeyring`（若 Core 没有 unwrap helper，把 unwrap 做成 `AntigravityAuthStore` 私有：去掉前缀 `go-keyring-base64:` 再 base64 解码；失败则当原文 JSON）。

缓存文件：`AgentHaloPaths(homeDirectory:).cacheDirectory.appendingPathComponent("antigravity-auth.json")`。Codable：`accessToken`、`expiresAtMs`、`credentialFingerprint`（refresh token 的 SHA-256 **hex 字符串**）。匹配失败或过期视为 miss；不要调用不存在的 `files.remove`。`init` 签名锁定为：

```swift
public init(
    homeDirectory: URL,
    keychain: any UsageKeychainAccessing,
    files: any UsageFileAccessing,
    now: @escaping @Sendable () -> Date = Date.init
)
```

`resolveAccess(lsAvailable:)` 按 spec 三分支。Keychain 读抛错且 `!lsAvailable` → `.oauthNeedsSignIn`。OAuth `source`：有 Keychain 用 `.keychain(service: "gemini", account: "antigravity")`；LS-only 用 `.file(path: cacheDirectory.appendingPathComponent("antigravity-ls").path)`。

**禁止**任何 Keychain `write`。

- [ ] **Step 4: 运行检查**

```bash
cd src/macos && swift run AgentHaloCoreChecks
```

Expected: auth 检查 PASS。

- [ ] **Step 5: Commit**

```bash
git add src/macos/Sources/AgentHaloCore/UsageMonitoring/Antigravity/AntigravityAuthStore.swift \
  src/macos/Sources/AgentHaloCoreChecks/AntigravityUsageChecks.swift
git commit -m "feat(macos): add Antigravity auth store and token cache"
```

---

### Task 4: Loopback HTTP + LS 发现 + UsageClient 组请求

**Files:**
- Create: `src/macos/Sources/AgentHaloCore/UsageMonitoring/Antigravity/AntigravityLoopbackHTTPClient.swift`
- Create: `src/macos/Sources/AgentHaloCore/UsageMonitoring/Antigravity/AntigravityLanguageServerDiscovery.swift`
- Create: `src/macos/Sources/AgentHaloCore/UsageMonitoring/Antigravity/AntigravityUsageClient.swift`
- Modify: `src/macos/Sources/AgentHaloCoreChecks/AntigravityUsageChecks.swift`

**Interfaces:**
- Produces: `AntigravityLoopbackHTTPClienting.send(url:method:headers:body:timeout:)`；`AntigravityLanguageServerDiscovery.discover(_ options:)`（不要另造 `discoverLanguageServer()` / `discoverAgy()`）；`AntigravityUsageClient.callLS` / `cloudCode` / `refreshGoogleToken`

- [ ] **Step 1: 写失败检查**

1. `AntigravityUsageClient` 用 recording fake：`cloudCode` 必须打 `daily-cloudcode-pa.googleapis.com` 的 `/v1internal:retrieveUserQuotaSummary`，User-Agent `antigravity`，`Authorization: Bearer <token>`。401 不再打第二个 base。
2. `refreshGoogleToken` POST `oauth2.googleapis.com` `/token`，body 含 `grant_type=refresh_token` 与 OpenUsage 那对 installed-app `client_id`（从 `/Users/wjs/work/ossp/openusage/Sources/OpenUsage/Providers/Antigravity/AntigravityUsageClient.swift` 原样拷贝常量，不要另造）。
3. `callLS` 使用传入的 scheme/port/csrf：URL 为 `https://127.0.0.1:{port}/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary`，头含 `x-codeium-csrf-token`、`Connect-Protocol-Version: 1`。
4. Discovery 纯函数：给一段伪造的 `ps` 输出，含 `--csrf_token abc --extension_server_port 1234` 且路径带 `/antigravity/`，解析出 csrf 与 extension port。无标记的 `language_server` 丢弃。

- [ ] **Step 2: 运行确认失败**

```bash
cd src/macos && swift run AgentHaloCoreChecks 2>&1 | tail -20
```

Expected: 新类型不存在。

- [ ] **Step 3: 最小实现**

`AntigravityLoopbackHTTPClient.swift`：协议 + `URLSession` 实现。`URLSessionDelegate` 仅当 host 是 `127.0.0.1` / `localhost` 时接受自签；其它 host 走系统校验。Checks 用 recording fake，不碰真网络。

**不要**改 `URLSessionUsageHTTPClient`。Cloud Code / OAuth 用现有 `UsageHTTPClient`（https + host + path）。

`AntigravityLanguageServerDiscovery.swift`：从 OpenUsage `LanguageServerDiscovery` 精简移植。生产跑 `/bin/ps` + `lsof`；`init` 注入已有的 `UsageProcessRunning`（生产用 `ProcessUsageRunner`）。`Options` 对齐 OpenUsage。

`AntigravityUsageClient.swift`：常量与 OpenUsage 相同（`lsService`、`cloudCodeURLs`、`quotaSummaryPath`、`googleOAuthURL`、`googleClientID`、`googleClientSecret`、`lsMetadata`）。

- [ ] **Step 4: 运行检查**

```bash
cd src/macos && swift run AgentHaloCoreChecks
```

Expected: client / discovery 检查 PASS。

- [ ] **Step 5: Commit**

```bash
git add src/macos/Sources/AgentHaloCore/UsageMonitoring/Antigravity/AntigravityLoopbackHTTPClient.swift \
  src/macos/Sources/AgentHaloCore/UsageMonitoring/Antigravity/AntigravityLanguageServerDiscovery.swift \
  src/macos/Sources/AgentHaloCore/UsageMonitoring/Antigravity/AntigravityUsageClient.swift \
  src/macos/Sources/AgentHaloCoreChecks/AntigravityUsageChecks.swift
git commit -m "feat(macos): add Antigravity LS discovery and usage client"
```

---

### Task 5: AntigravityUsageProvider + Coordinator 注册

**Files:**
- Create: `src/macos/Sources/AgentHaloCore/UsageMonitoring/Antigravity/AntigravityUsageProvider.swift`
- Modify: `src/macos/Sources/AgentHaloCore/UsageMonitoring/UsageMonitoringCoordinator.swift`（`live()` 注册）
- Modify: `src/macos/Sources/AgentHaloCoreChecks/AntigravityUsageChecks.swift`

**Interfaces:**
- Consumes: Task 2–4 的类型
- Produces: `AntigravityUsageProvider` 实现 `UsageProvider`

- [ ] **Step 1: 写失败检查**

1. LS `RetrieveUserQuotaSummary` 2xx 且可解析（哪怕零 bucket）→ 不再打 legacy LS 方法，也不打 Cloud Code。
2. LS 不可发现 + Keychain token → Cloud Code summary。
3. LS 不可发现 + 无 Keychain → `resolveAccess` 为 `.oauthNeedsSignIn`；`refresh(using: .oauthNeedsSignIn)` 返回 `.failure(.signInAgain)`，不发 HTTP。
4. 探测顺序：先 `language_server`（antigravity 标记），再 `agy`。

用 fake discovery / fake HTTP 注入 provider。

- [ ] **Step 2: 运行确认失败**

```bash
cd src/macos && swift run AgentHaloCoreChecks 2>&1 | tail -20
```

Expected: `AntigravityUsageProvider` 找不到。

- [ ] **Step 3: 最小实现**

```swift
public struct AntigravityUsageProvider: UsageProvider, Sendable {
    public let providerID = UsageProviderID.antigravity
    static let languageServerOptions = AntigravityLanguageServerDiscovery.Options(
        processName: "language_server",
        markers: ["antigravity", "antigravity-ide"],
        csrfFlag: "--csrf_token",
        portFlag: "--extension_server_port"
    )
    static let agyOptions = AntigravityLanguageServerDiscovery.Options(
        processName: "agy",
        markers: [],
        csrfFlag: "",
        portFlag: nil
    )
    public func resolveAccess(accountKey: AccountCacheKey?) async -> ResolvedProviderAccess {
        let lsAvailable =
            discovery.discover(Self.languageServerOptions) != nil
            || discovery.discover(Self.agyOptions) != nil
        return authStore.resolveAccess(lsAvailable: lsAvailable)
    }
    public func refresh(using access: ResolvedProviderAccess) async -> UsageRefreshResult {
        guard case .oauth(let oauth) = access else {
            return UsageRefreshResult(providerID: .antigravity, outcome: .failure(.signInAgain))
        }
        if let snapshot = await probeLS(Self.languageServerOptions, accountKey: oauth.accountKey) {
            return UsageRefreshResult(providerID: .antigravity, snapshot: snapshot, failure: nil)
        }
        if let snapshot = await probeLS(Self.agyOptions, accountKey: oauth.accountKey) {
            return UsageRefreshResult(providerID: .antigravity, snapshot: snapshot, failure: nil)
        }
        guard !oauth.accessToken.isEmpty else {
            return UsageRefreshResult(providerID: .antigravity, outcome: .failure(.signInAgain))
        }
        return await probeCloudCode(oauth)
    }
}
```

`UsageMonitoringCoordinator.live()` 增加 `AntigravityAuthStore` + `AntigravityUsageProvider`，放进 `providers:` 数组。LS HTTP 用 loopback client；Cloud Code 仍用现有 `http`。

Token 临期：`authStore` 若有 refresh token 且 access 不可用，先 `refreshGoogleToken`，成功则 `cacheAccessToken`（经 `focusController.performCredentialWrite`），**不写 Keychain**。

- [ ] **Step 4: 运行检查**

```bash
cd src/macos && swift run AgentHaloCoreChecks
```

Expected: provider 检查 PASS；既有 coordinator 检查不回归。

- [ ] **Step 5: Commit**

```bash
git add src/macos/Sources/AgentHaloCore/UsageMonitoring/Antigravity/AntigravityUsageProvider.swift \
  src/macos/Sources/AgentHaloCore/UsageMonitoring/UsageMonitoringCoordinator.swift \
  src/macos/Sources/AgentHaloCoreChecks/AntigravityUsageChecks.swift
git commit -m "feat(macos): register Antigravity usage provider"
```

---

### Task 6: 共用 status-hook 三分流

**Files:**
- Modify: `src/macos/Sources/ClaudeCodeStatusHook/main.swift`
- Modify: `src/macos/Sources/AgentHaloCoreChecks/main.swift`（扩展 `runClaudeCodeStatusHook` 与隔离测试）

**Interfaces:**
- Produces: Antigravity 记录写入 `AgentHaloPaths.antigravityStatusLog`，`source: "antigravity-hook"`

- [ ] **Step 1: 写失败检查**

扩展 `runClaudeCodeStatusHook`：若调用方没设 `ANTIGRAVITY_AGENT` / `ANTIGRAVITY_TRAJECTORY_ID`，从继承环境里删掉它们（与现有 `GROK_*` 清理相同）。

新增 `testClaudeCodeStatusHookIsolatesAntigravityStatusFiles()`：

1. `ANTIGRAVITY_AGENT=1`，argv `pre_invocation`，stdin 带 cwd → 只写 `antigravity-status.jsonl`，`source` 为 `antigravity-hook`，事件为 `PreInvocation`，`sessionId` 来自 `ANTIGRAVITY_TRAJECTORY_ID`（若设置）。
2. `GROK_SESSION_ID` 同时存在 → 仍只写 Grok（Grok 优先）。
3. stdin `transcript_path` 为 `/Users/x/.gemini/antigravity-cli/brain/c1/transcript.jsonl`、无 AG env → AG 日志。
4. stdin `transcript_path` 为 `/Users/x/.gemini/antigravity/brain/c1/transcript.jsonl`（IDE，无 `antigravity-cli`）→ **不是** AG，走 Claude。
5. 无信号 → Claude。
6. Claude / Grok 文件不得出现 AG session id。

- [ ] **Step 2: 运行确认失败**

```bash
cd src/macos && swift run AgentHaloCoreChecks 2>&1 | tail -30
```

Expected: AG 日志不存在或事件未规范化。

- [ ] **Step 3: 最小实现**

`main.swift` 在 `isGrok` 之后：

```swift
let isAntigravity = !isGrok && antigravityHookMatch(env: env, payload: payload)

func antigravityHookMatch(env: [String: String], payload: [String: Any]) -> Bool {
    if !(env["ANTIGRAVITY_AGENT"] ?? "").isEmpty { return true }
    if !(env["ANTIGRAVITY_TRAJECTORY_ID"] ?? "").isEmpty { return true }
    let transcript = firstString(
        payload["transcript_path"], payload["transcriptPath"],
        env["ANTIGRAVITY_TRANSCRIPT_PATH"]
    )
    return transcript.contains("/antigravity-cli/")
}
```

`normalizeEventName` 增加：

```swift
"pre_invocation": "PreInvocation",
"post_invocation": "PostInvocation",
```

`sessionId`：`ANTIGRAVITY_TRAJECTORY_ID` → payload `session_id` / `sessionId` / `conversation_id` → `"antigravity"`。

写盘路径：`isGrok ? grokStatusLog : isAntigravity ? antigravityStatusLog : claudeStatusLog`。`source` 对应 `grok-hook` / `antigravity-hook` / `claude-hook`。

JSONL 滚动复用现有 Claude/Grok 常量与函数。

- [ ] **Step 4: 运行检查**

```bash
cd src/macos && swift run AgentHaloCoreChecks
```

Expected: 三分流检查 PASS；原 Grok/Claude 隔离不回归。

- [ ] **Step 5: Commit**

```bash
git add src/macos/Sources/ClaudeCodeStatusHook/main.swift \
  src/macos/Sources/AgentHaloCoreChecks/main.swift
git commit -m "feat(macos): route agy hooks to antigravity-status.jsonl"
```

---

### Task 7: AntigravityHookConfigurator（named group）

**Files:**
- Create: `src/macos/Sources/AgentHaloCore/AntigravityHookConfigurator.swift`
- Modify: `src/macos/Sources/AgentHaloCore/AgentHaloRuntimeBootstrap.swift`
- Modify: `src/macos/Sources/AgentHaloCoreChecks/main.swift`

**Interfaces:**
- Produces: `AntigravityHookConfigurator.configure(homeDirectory:bundledHookBinary:)`
- 只写 `$HOME/.gemini/config/hooks.json`

- [ ] **Step 1: 写失败检查**

临时 HOME：

1. 无文件 → 创建，顶层 key `agent-halo-status`，含 `PreInvocation` / `PostInvocation` / `Stop` / `PreToolUse` / `PostToolUse`。扁平事件的 command 以 `status-hook PreInvocation` 这种带事件名结尾。`PreToolUse`/`PostToolUse` 带 `matcher: "*"` 与嵌套 `hooks`。
2. 已有 `orca-status` group → 合并后 `orca-status` 字节级语义不变（至少 command 字符串仍在）。
3. 已指向 preferred path 且五件齐全 → 不改 mtime。
4. `AgentHaloRuntimeBootstrap.bootstrap(enabledAgents: [.codex])` **不**创建该文件。
5. `bootstrap(enabledAgents: [.antigravity], bundledHookBinary:)` **会**创建。

- [ ] **Step 2: 运行确认失败**

```bash
cd src/macos && swift run AgentHaloCoreChecks 2>&1 | tail -20
```

Expected: configurator 不存在或 bootstrap 未调用。

- [ ] **Step 3: 最小实现**

```swift
public enum AntigravityHookConfigurator {
    public static let groupName = "agent-halo-status"
    public static func hooksFile(homeDirectory: URL) -> URL {
        homeDirectory.appendingPathComponent(".gemini/config/hooks.json")
    }
    public static func configure(homeDirectory: URL, bundledHookBinary: URL?)
}
```

先 `AgentHaloBinaryStaging.stageStatusHook`。读现有 JSON 为 `[String: Any]`；若根不是字典则放弃并打日志。写入 `groupName` 五件事件。不碰其它 key。不写 `settings.json`。失败只 log。

`AgentHaloRuntimeBootstrap`：

```swift
if enabledAgents.contains(.antigravity) {
    AntigravityHookConfigurator.configure(
        homeDirectory: homeDirectory,
        bundledHookBinary: hook
    )
}
```

- [ ] **Step 4: 运行检查**

```bash
cd src/macos && swift run AgentHaloCoreChecks
```

Expected: configurator / bootstrap 检查 PASS。

- [ ] **Step 5: Commit**

```bash
git add src/macos/Sources/AgentHaloCore/AntigravityHookConfigurator.swift \
  src/macos/Sources/AgentHaloCore/AgentHaloRuntimeBootstrap.swift \
  src/macos/Sources/AgentHaloCoreChecks/main.swift
git commit -m "feat(macos): configure agy named-group hooks"
```

---

### Task 8: AntigravityHookStatusReducer

**Files:**
- Create: `src/macos/Sources/AgentHaloCore/AntigravityHookStatusReducer.swift`
- Modify: `src/macos/Sources/AgentHaloCoreChecks/main.swift`

**Interfaces:**
- Produces: `AntigravityHookStatusReducer.consume` / `applyWorkingVisibility`；`SessionSnapshot.agent == .antigravity`

- [ ] **Step 1: 写失败检查**

对齐 `ClaudeHookStatusReducer` 的可见性数字：PostToolUse 后 `workingVisibleUntil = eventAt + 0.65`。

```swift
func testAntigravityReducerLifecycle() {
    var reducer = AntigravityHookStatusReducer(threadId: "t1", now: now)
    reducer.consume(jsonLine: line(event: "PreInvocation", ts: now), now: now)
    expect(reducer.snapshot.state, .thinking, "pre invocation")
    reducer.consume(jsonLine: line(event: "PostInvocation", ts: now.addingTimeInterval(1)), now: now.addingTimeInterval(1))
    expect(reducer.snapshot.state, .thinking, "post invocation is not done")
    reducer.consume(jsonLine: line(event: "PreToolUse", tool: "run_command", ts: now.addingTimeInterval(2)), now: now.addingTimeInterval(2))
    expect(reducer.snapshot.state, .working, "pre tool")
    reducer.consume(jsonLine: line(event: "PostToolUse", ts: now.addingTimeInterval(3)), now: now.addingTimeInterval(3))
    expect(reducer.snapshot.state, .working, "reviewing")
    reducer.applyWorkingVisibility(now: now.addingTimeInterval(3.7))
    expect(reducer.snapshot.state, .thinking, "fade after 0.65s")
    reducer.consume(jsonLine: line(event: "Stop", ts: now.addingTimeInterval(5)), now: now.addingTimeInterval(5))
    expect(reducer.snapshot.state, .done, "stop")
    expect(reducer.snapshot.agent, .antigravity, "agent stamp")
}

func testAntigravityReducerIgnoresBadLineAndUnknownEvent() {
    let now = Date(timeIntervalSince1970: 1_000)
    var reducer = AntigravityHookStatusReducer(threadId: "t1", now: now)
    reducer.consume(jsonLine: #"{"event":"PreInvocation","timestamp":"1970-01-01T00:16:40Z","sessionId":"t1"}"#, now: now)
    let before = reducer.snapshot
    reducer.consume(jsonLine: "not-json", now: now.addingTimeInterval(1))
    expect(reducer.snapshot.state, before.state, "bad line keeps state")
    reducer.consume(
        jsonLine: #"{"event":"TotallyUnknown","timestamp":"1970-01-01T00:16:42Z","sessionId":"t1"}"#,
        now: now.addingTimeInterval(2)
    )
    expect(reducer.snapshot.state, .thinking, "unknown event does not change state")
    expect(reducer.snapshot.lastEventAt != before.lastEventAt, true, "unknown event updates lastEventAt")
}
```

- [ ] **Step 2: 运行确认失败**

```bash
cd src/macos && swift run AgentHaloCoreChecks 2>&1 | tail -20
```

Expected: reducer 类型不存在。

- [ ] **Step 3: 最小实现**

复制 `ClaudeHookStatusReducer` 的骨架，删掉 Notification / permission / compact 特例。事件表按 spec：

| 事件 | 状态 |
| --- | --- |
| PreInvocation | thinking |
| PostInvocation | thinking（若 `now < workingVisibleUntil` 保持 working） |
| PreToolUse | working + `GeneratedHaloSpec.friendlyAction` |
| PostToolUse | working / Reviewing result，`workingVisibleUntil = eventAt + 0.65` |
| PostToolUse 带 errorText | 同上，action `Tool failed` |
| Stop | done，`completedAt = eventAt`，`active = false` |

`applyWorkingVisibility` 与 Claude hook 相同（0.65s fade + 180s stuck-tool safety net）。不画 attention。

- [ ] **Step 4: 运行检查**

```bash
cd src/macos && swift run AgentHaloCoreChecks
```

Expected: reducer 检查 PASS。

- [ ] **Step 5: Commit**

```bash
git add src/macos/Sources/AgentHaloCore/AntigravityHookStatusReducer.swift \
  src/macos/Sources/AgentHaloCoreChecks/main.swift
git commit -m "feat(macos): reduce agy hook events to halo states"
```

---

### Task 9: Monitor + ActivityMonitor + AppDelegate 编排

**Files:**
- Create: `src/macos/Sources/AgentHaloCore/AntigravityHookStatusMonitor.swift`
- Create: `src/macos/Sources/AgentHaloMac/AntigravityActivityMonitor.swift`
- Modify: `src/macos/Sources/AgentHaloMac/AppDelegate.swift`
- Modify: `src/macos/Sources/AgentHaloCoreChecks/main.swift`

**Interfaces:**
- Produces: `AntigravityHookStatusMonitor.refresh` → `[SessionSnapshot]`；`AntigravityActivityMonitor` 与 Grok 相同的 polling API

- [ ] **Step 1: 写失败检查**

Monitor：向临时 `antigravity-status.jsonl` 追加 PreInvocation + Stop，`refresh` 后快照 `agent == .antigravity` 且最终 `done`。坏行跳过。

Aggregator：焦点 `.antigravity` 时只出现 AG 快照（复用现有 `SessionAggregator.aggregate` 检查风格）。

- [ ] **Step 2: 运行确认失败**

```bash
cd src/macos && swift run AgentHaloCoreChecks 2>&1 | tail -20
```

Expected: monitor 不存在。

- [ ] **Step 3: 最小实现**

`AntigravityHookStatusMonitor`：镜像 **`ClaudeHookStatusMonitor`**（只增量读 JSONL + 每会话一个 reducer + `applyWorkingVisibility`）。**不要**抄 `GrokHookStatusMonitor`——后者还会读 `~/.grok/sessions` 的 turn events。默认 URL `AgentHaloPaths().antigravityStatusLog`。`refresh(now:) -> Bool`，`snapshots() -> [SessionSnapshot]`。

`AntigravityActivityMonitor`：复制 `GrokActivityMonitor` 的队列 / 300ms / 2000ms / `updatePollingContext` 形状，改成 `AgentKind.antigravity`。Presence：

```swift
static func isPresent(
    sessions: [SessionSnapshot],
    now: Date,
    processPresenceProbe: () -> Bool
) -> Bool
```

近期 hook：沿用 `ClaudeHookStatusMonitor.shouldRetainSnapshot` 的窗口（active 600s / idle 300s）内还有快照，**或** `processPresenceProbe() == true`。生产 probe 查进程名恰好为 `agy`（可注入，测试不要依赖本机真有 `agy`）。不要把 `language_server` 算成在线。

`AppDelegate`：

- 持有 `antigravityActivityMonitor` / `antigravityActivitySnapshot`
- `applicationDidFinishLaunching` 里 `start`
- `tick` 里 `updatePollingContext(focusedAgent:detailsPanelVisible:enabled:)`
- `hasLiveSessionForFocusedAgent`：`.antigravity → snapshot.isPresent`
- 新增 `antigravitySnapshots()`，`allSnapshots()` 改成 `+ antigravitySnapshots()`。Aggregator 自己按 `focusedAgent` 过滤，不要在 AppDelegate 里先丢掉其它 agent。
- `applyEnabledAgents`：刚打开 AG 时立刻 `AntigravityHookConfigurator.configure` + `requestRefresh()`；关掉时停 monitor、清空 snapshot，**不删** `hooks.json` 里的 group。

- [ ] **Step 4: 运行检查**

```bash
cd src/macos && swift run AgentHaloCoreChecks
```

Expected: monitor / aggregator 检查 PASS。

- [ ] **Step 5: Commit**

```bash
git add src/macos/Sources/AgentHaloCore/AntigravityHookStatusMonitor.swift \
  src/macos/Sources/AgentHaloMac/AntigravityActivityMonitor.swift \
  src/macos/Sources/AgentHaloMac/AppDelegate.swift \
  src/macos/Sources/AgentHaloCoreChecks/main.swift
git commit -m "feat(macos): poll Antigravity hook lifecycle"
```

---

### Task 10: 文档 + 自检断言收口

**Files:**
- Modify: `docs/PRODUCT.md`
- Modify: `README.md`、`README.zh-CN.md`
- Modify: `AGENTS.md`
- Modify: `src/macos/Sources/AgentHaloMac/HaloInteractionChecks.swift`
- Modify: `src/macos/Sources/AgentHaloCoreChecks/main.swift`（`usageProviderID` 源码断言若写死四项则补 AG）

**Interfaces:**
- 无新类型。用户可见文案不写端点细节。

- [ ] **Step 1: 写失败检查**

`HaloInteractionChecks`：

```swift
expect(detailsSource?.contains("assetName: \"antigravity\"") == true, "details panel loads AG icon")
expect(appDelegateSource.contains("case .antigravity"), "AppDelegate handles AG focus")
expect(
    appDelegateSource.contains("usageProviderID") &&
    appDelegateSource.contains("case .antigravity:") &&
    appDelegateSource.contains("return .antigravity"),
    "usageProviderID maps antigravity"
)
```

- [ ] **Step 2: 运行确认失败（若断言尚未满足）**

```bash
cd src/macos && swift run AgentHaloMac --self-check 2>&1 | tail -40
```

Core checks：

```bash
cd src/macos && swift run AgentHaloCoreChecks
```

- [ ] **Step 3: 文档**

`docs/PRODUCT.md`：当前发行支持列表改为 Codex / Claude Code / Grok Build / Pi，以及 **macOS 可选** Antigravity。写明默认关闭、仅 `agy` CLI 生命周期、额度仅 Gemini 5h/Weekly。

`README.md` / `README.zh-CN.md`：支持列表同样补一句可选 Antigravity（macOS）。不要贴 Cloud Code URL。

`AGENTS.md` runtime 表：`logs/antigravity-status.jsonl`；macOS hooks：`~/.gemini/config/hooks.json` named group `agent-halo-status`。

- [ ] **Step 4: 全量检查**

```bash
cd src/macos && swift run AgentHaloCoreChecks
```

Expected: 全部 PASS。

- [ ] **Step 5: Commit**

```bash
git add docs/PRODUCT.md README.md README.zh-CN.md AGENTS.md \
  src/macos/Sources/AgentHaloMac/HaloInteractionChecks.swift \
  src/macos/Sources/AgentHaloCoreChecks/main.swift
git commit -m "docs: document optional macOS Antigravity agent"
```

---

## 人工 live E2E（不挡自动化收口）

1. 设置里勾选 Antigravity，切换条出现 `AG`，默认未勾选时仍是四槽 144pt。
2. 焦点切到 AG，跑一轮 `agy`：thinking → working → done。
3. 焦点在 Claude 时跑 `agy`，Claude 光环不变；`~/.agent-halo/logs/claude-status.jsonl` 无新 AG 行。
4. 已登录或 LS 在跑：两行仅为 5h / Weekly。
5. 取消勾选：停止轮询；`~/.gemini/config/hooks.json` 里 `orca-status` 仍在，`agent-halo-status` 可保留。

---

## Spec coverage（自检）

| Spec 要求 | 任务 |
| --- | --- |
| AgentKind / AG 标签 / 默认四开 | 1 |
| Gemini 两窗 mapper + 旧接口仅 session | 2 |
| Keychain + 指纹缓存，不写回 | 3 |
| LS 优先 + Cloud Code + loopback HTTP | 4–5 |
| `resolveAccess` 禁止 apiKey；LS-only oauth | 3、5 |
| Coordinator 只刷新焦点 | 5（沿用现有） |
| Hook 三分流 + 真实 env | 6 |
| named-group configurator | 7 |
| Reducer 映射（PostInvocation ≠ done） | 8 |
| Monitor / presence / AppDelegate | 9 |
| 空 context pill、文档、验收文案 | 10 |
| 不改 Windows | 全局约束 |
