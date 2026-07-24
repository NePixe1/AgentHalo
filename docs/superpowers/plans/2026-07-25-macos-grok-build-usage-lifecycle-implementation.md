# macOS Grok Build 额度与最小生命周期 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 AgentHalo macOS 上把 Grok Build 接成第三个监控对象：OAuth Weekly 额度可显示，最小 hook 生命周期驱动光环，且 Grok 事件不再污染 Claude Code 状态日志。

**Architecture:** 额度沿用现有 `AuthStore → UsageClient → UsageMapper → UsageProvider → UsageSnapshotCache → Coordinator`，从 OpenUsage 的 Grok provider 移植（`cli-chat-proxy.grok.com/v1/billing?format=credits`）。生命周期沿用 Claude hook 模式：单一 `ClaudeCodeStatusHook` 二进制按 `GROK_*` 环境变量分流写 `grok-build-status.jsonl` vs `claude-code-status.jsonl`；`GrokHookConfigurator` 写入 `~/.grok/hooks/`；Monitor/Reducer 产出 `SessionSnapshot(agent: .grok)`。UI 焦点扩展为 `Codex | CC | Grok`。

**Tech Stack:** Swift 6、SwiftPM、AppKit、Foundation/URLSession、CryptoKit、现有 `AgentHaloCoreChecks` / `AgentHaloMac --self-check`

**Spec:** [2026-07-25-macos-grok-build-usage-lifecycle-design.md](../specs/2026-07-25-macos-grok-build-usage-lifecycle-design.md)

## Global Constraints

- 只修改 macOS 与共享本地化/资源；**不修改 Windows 运行时代码**。
- 分段标签文案固定为 **`Grok`**（不是 `GB`）。
- **Pay-as-you-go / onDemandCap / prepaid：不实现、不渲染、不解码到 UI 模型**。
- 额度主条使用总池 `creditUsagePercent`，不单独做 GrokBuild product 第二进度条。
- 只在 focus == Grok 时后台刷新 Grok usage；默认 fresh 阈值 5 分钟（与现有 Coordinator 一致）。
- Token 临期 5 分钟刷新；原子写回 `~/.grok/auth.json` 单 entry；保留未知字段与其他账号。
- 不记录 access/refresh token、认证头、响应正文、原始凭据 JSON。
- 额度失败不得改变 halo 生命周期状态。
- Hook 检测到 Grok 时**禁止**写入 `claude-code-status.jsonl`。
- 每项任务 TDD：先加失败检查 → 确认失败 → 最小实现 → 聚焦检查通过 → 提交。
- 提交前 `git status --short`，只暂存本任务文件。

---

## 目标文件总览

新增：

```text
src/macos/Sources/AgentHaloCore/UsageMonitoring/Grok/
├── GrokAuthStore.swift
├── GrokUsageClient.swift
├── GrokUsageMapper.swift
└── GrokUsageProvider.swift
src/macos/Sources/AgentHaloCore/GrokHookConfigurator.swift
src/macos/Sources/AgentHaloCore/GrokHookStatusMonitor.swift
src/macos/Sources/AgentHaloCore/GrokHookStatusReducer.swift
src/macos/Sources/AgentHaloMac/GrokActivityMonitor.swift
src/shared/assets/agent-switch/grok.svg
src/macos/Sources/AgentHaloCoreChecks/GrokUsageChecks.swift   # 或并入 UsageMonitoringChecks.swift
```

修改：

```text
src/macos/Sources/AgentHaloCore/HaloModels.swift          # AgentKind.grok
src/macos/Sources/AgentHaloCore/UsageMonitoring/UsageModels.swift  # UsageProviderID.grok
src/macos/Sources/AgentHaloCore/UsageMonitoring/DetailsContentResolver.swift
src/macos/Sources/AgentHaloCore/UsageMonitoring/UsageMonitoringCoordinator.swift
src/macos/Sources/AgentHaloCore/SessionAggregator.swift   # 若有 agent 特判
src/macos/Sources/AgentHaloCore/locales/{en,zh}.json
src/shared/locales/{en,zh}.json
src/macos/Sources/ClaudeCodeStatusHook/main.swift         # GROK 分流
src/macos/Sources/AgentHaloMac/AppDelegate.swift
src/macos/Sources/AgentHaloMac/DetailsPanel.swift         # 三方 AgentToggle
src/macos/Sources/AgentHaloMac/ClaudeActivityMonitor.swift  # 若需并行 polling 模式
src/macos/Sources/AgentHaloMac/HaloInteractionChecks.swift
src/macos/Sources/AgentHaloCoreChecks/main.swift
src/macos/Sources/AgentHaloCoreChecks/UsageMonitoringChecks.swift
scripts/build-macos.sh                                    # 若需拷贝 grok.svg / hook
```

公开接口（本计划锁定）：

```swift
// HaloModels
public enum AgentKind: String, Codable, CaseIterable, Equatable, Sendable {
    case codex
    case claudeCode
    case grok
}

// UsageModels
public enum UsageProviderID: String, Codable, Sendable {
    case codex
    case claude
    case grok
}

// GrokUsageClient
public struct GrokUsageClient: Sendable {
    public static let tokenAuthHeader = "xai-grok-cli"
    public static let defaultClientID = "b1a00492-073a-47ea-816f-4c329264a828"
    public func refreshToken(_ refreshToken: String, clientID: String) async throws -> UsageHTTPResponse
    public func fetchCreditsConfig(accessToken: String) async throws -> UsageHTTPResponse
    public func fetchSettings(accessToken: String) async throws -> UsageHTTPResponse
}

// GrokAuthStore
public struct GrokAuthStore: Sendable {
    public static let refreshWindow: TimeInterval = 5 * 60
    public func resolveAccess() -> ResolvedProviderAccess
    public func reloadResolved(source: CredentialSource) -> ResolvedProviderAccess
    public func needsRefresh(_ access: OAuthAccess) -> Bool
    public func persist(rotation: GrokTokenRotation, replacing expected: OAuthAccess) throws -> OAuthAccess?
}

// Hook 输出
// ~/.agent-halo/grok-build-status.jsonl  records with source == "grok-hook"
// ~/.grok/hooks/agent-halo-status.json
```

依赖注入：`GrokAuthStore` / `GrokUsageClient` / providers 的 `public init` 接受可替换的 `UsageFileAccessing` / `UsageHTTPClient` / `now`，与 Claude/Codex 一致，便于 checks。

验证命令（全文通用）：

```bash
cd src/macos
swift run AgentHaloCoreChecks
# 交互/UI 检查（按仓库惯例）：
swift run AgentHaloMac --self-check   # 若参数名不同，以 main.swift 为准
```

---

### Task 1: AgentKind.grok + UsageProviderID.grok + i18n

**Files:**
- Modify: `src/macos/Sources/AgentHaloCore/HaloModels.swift`
- Modify: `src/macos/Sources/AgentHaloCore/UsageMonitoring/UsageModels.swift`
- Modify: `src/macos/Sources/AgentHaloCore/UsageMonitoring/DetailsContentResolver.swift`
- Modify: `src/shared/locales/en.json`, `src/shared/locales/zh.json`
- Modify: `src/macos/Sources/AgentHaloCore/locales/en.json`, `zh.json`（与 shared 同步）
- Modify: `src/macos/Sources/AgentHaloCoreChecks/main.swift`（settings 持久化用例）
- Modify: `src/macos/Sources/AgentHaloCoreChecks/UsageMonitoringChecks.swift`（provider 名）

**Interfaces:**
- Produces: `AgentKind.grok`；`UsageProviderID.grok`；`AgentKind` 的 menu/segmented/standby/offline 文案；L10n keys `status.standby_grok`、`status.offline_grok`、`usage.warning.sign_in_grok`

- [ ] **Step 1: 写失败检查 — AgentKind / settings / L10n**

在 `main.swift` 的 settings 相关检查附近追加：

```swift
func testGrokFocusedAgentPersistence() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("agent-halo-grok-settings-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    var settings = HaloSettings(focusedAgent: .grok)
    expect(settings.focusedAgent, .grok, "settings should accept grok focus")
    expect(AgentKind.grok.segmentedTitle, "Grok", "segmented label must be Grok")
    expect(AgentKind.grok.menuTitle, "Grok", "menu title must be Grok")

    // 按现有 HaloSettings 持久化 API 写读（与 codex/claude 用例同一 helper）
    // 期望 loaded.focusedAgent == .grok
}
```

在 `UsageMonitoringChecks.swift` 的 localization / DetailsContentResolver 检查中期望：

```swift
expect(
    DetailsContentResolver.resolve(
        providerID: .grok,
        monitorState: /* oauth noData empty */,
        isOffline: false,
        sessionDetails: SessionDetailsSnapshot(),
        contextUsedPercent: nil,
        now: Date()
    ).providerName,
    "Grok",
    "grok provider display name"
)
```

- [ ] **Step 2: 运行检查确认失败**

```bash
cd src/macos && swift run AgentHaloCoreChecks 2>&1 | tail -40
```

Expected: 编译失败或 expect 失败（无 `.grok` case）。

- [ ] **Step 3: 最小实现**

`HaloModels.swift`：

```swift
public enum AgentKind: String, Codable, CaseIterable, Equatable, Sendable {
    case codex
    case claudeCode
    case grok

    public var menuTitle: String {
        switch self {
        case .codex: return "Codex"
        case .claudeCode: return "Claude Code"
        case .grok: return "Grok"
        }
    }

    public var segmentedTitle: String {
        switch self {
        case .codex: return "Codex"
        case .claudeCode: return "CC"
        case .grok: return "Grok"
        }
    }

    public var localizedStandbyDetail: String {
        switch self {
        case .codex: return L10n.shared["status.standby_codex"]
        case .claudeCode: return L10n.shared["status.standby_claude"]
        case .grok: return L10n.shared["status.standby_grok"]
        }
    }

    public var localizedOfflineDetail: String {
        switch self {
        case .codex: return L10n.shared["status.offline_codex"]
        case .claudeCode: return L10n.shared["status.offline_claude"]
        case .grok: return L10n.shared["status.offline_grok"]
        }
    }
    // 同步更新 standbyDetail / offlineDetail 英文字符串
}
```

`UsageModels.swift`：

```swift
public enum UsageProviderID: String, Codable, Sendable {
    case codex
    case claude
    case grok
}
```

`DetailsContentResolver.swift`：所有 `switch providerID` 补 `.grok`（providerName `"Grok"`；sign_in 用 `usage.warning.sign_in_grok`）。

本地化：

```json
"status.standby_grok": "Grok is standing by",
"status.offline_grok": "Grok is not running",
"usage.warning.sign_in_grok": "Run `grok login` again to refresh usage."
```

```json
"status.standby_grok": "Grok 正在待命",
"status.offline_grok": "Grok 未在运行",
"usage.warning.sign_in_grok": "请重新执行 grok login 以刷新使用情况。"
```

全仓库 `switch` 上对 `AgentKind` / `UsageProviderID` 的穷尽匹配一并补全（编译器会标出）。

- [ ] **Step 4: 运行检查**

```bash
cd src/macos && swift run AgentHaloCoreChecks
```

Expected: 新检查 PASS；既有检查不回归。

- [ ] **Step 5: Commit**

```bash
git add src/macos/Sources/AgentHaloCore/HaloModels.swift \
  src/macos/Sources/AgentHaloCore/UsageMonitoring/UsageModels.swift \
  src/macos/Sources/AgentHaloCore/UsageMonitoring/DetailsContentResolver.swift \
  src/shared/locales/en.json src/shared/locales/zh.json \
  src/macos/Sources/AgentHaloCore/locales/en.json src/macos/Sources/AgentHaloCore/locales/zh.json \
  src/macos/Sources/AgentHaloCoreChecks/main.swift \
  src/macos/Sources/AgentHaloCoreChecks/UsageMonitoringChecks.swift
git commit -m "feat(macos): add Grok agent kind and usage provider id"
```

---

### Task 2: GrokAuthStore

**Files:**
- Create: `src/macos/Sources/AgentHaloCore/UsageMonitoring/Grok/GrokAuthStore.swift`
- Modify: `src/macos/Sources/AgentHaloCoreChecks/UsageMonitoringChecks.swift`（或 `GrokUsageChecks.swift` + main 调用）

**Interfaces:**
- Consumes: `UsageFileAccessing`、`OAuthAccess`、`CredentialSource.file`、`UsageDigest`、`UsageProviderID.grok`
- Produces: `GrokAuthStore.resolveAccess()` / `persist(rotation:replacing:)` / `needsRefresh`

参考：OpenUsage `GrokAuthStore` + AgentHalo `ClaudeAuthStore` 的 `persist` 并发防护（`sourceVersion`）。

- [ ] **Step 1: 写失败检查**

```swift
func runGrokAuthChecks() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("grok-auth-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let grokDir = root.appendingPathComponent(".grok", isDirectory: true)
    try FileManager.default.createDirectory(at: grokDir, withIntermediateDirectories: true)
    let authURL = grokDir.appendingPathComponent("auth.json")

    // empty / missing → oauthNeedsSignIn or apiKey-equivalent needs sign-in
    let files = FilesystemUsageFiles() // 或测试用 temp home 注入
    // 构造 GrokAuthStore(home: root) —— 实现时 init 接受 homeDirectory: URL

    // 写入双账号 auth.json（第二账号 entry 必须保留）
    let authJSON = """
    {
      "https://auth.x.ai::client-a": {
        "key": "header.\(fakeJWT(exp: Date().addingTimeInterval(3600))).sig",
        "refresh_token": "refresh-a",
        "expires_at": "2099-01-01T00:00:00Z",
        "user_id": "user-a",
        "email": "a@example.com",
        "oidc_client_id": "client-a"
      },
      "https://auth.x.ai::client-b": {
        "key": "keep-me-token",
        "refresh_token": "refresh-b",
        "user_id": "user-b"
      }
    }
    """
    try authJSON.write(to: authURL, atomically: true, encoding: .utf8)

    let store = GrokAuthStore(homeDirectory: root)
    guard case .oauth(let access) = store.resolveAccess() else {
        expect(false, "expected oauth from auth.json")
        return
    }
    expect(access.providerID, .grok, "provider id")
    expect(access.accountKey.digest.count, 64, "digest hex length")
    expect(access.accountKey.digest.contains("user-a") == false, "digest must not embed raw id plaintext requirement is hash only")

    let rotated = GrokTokenRotation(
        accessToken: "new-access",
        refreshToken: "new-refresh",
        expiresAt: Date().addingTimeInterval(7200)
    )
    let persisted = try store.persist(rotation: rotated, replacing: access)
    expect(persisted?.accessToken, "new-access", "access token updated")

    let reloaded = try String(contentsOf: authURL, encoding: .utf8)
    expect(reloaded.contains("keep-me-token"), "must preserve other account entries")
    expect(reloaded.contains("new-access"), "must write rotated token")

    // corrupt file: persist should throw and not wipe
    try "{not-json".write(to: authURL, atomically: true, encoding: .utf8)
    do {
        _ = try store.persist(rotation: rotated, replacing: access)
        expect(false, "persist on corrupt file must throw")
    } catch {
        // ok
    }
}

// fakeJWT: base64url header.payload.sig with exp claim — 实现辅助函数即可
```

- [ ] **Step 2: 运行确认失败**

```bash
cd src/macos && swift run AgentHaloCoreChecks 2>&1 | tail -30
```

- [ ] **Step 3: 实现 GrokAuthStore**

要点：

- 路径：`homeDirectory/.grok/auth.json`
- 解析为 `[String: [String: Any]]` 或 Codable entry map
- 选第一个含非空 `key` 的 entry（与 OpenUsage candidates 顺序一致即可；文档不要求多账号切换 UI）
- `accountKey = AccountCacheKey(providerID: .grok, digest: UsageDigest.sha256(user_id ?? email ?? entryKey))`
- `source = .file(path: authPath)`
- `sourceVersion`：文件 mtime+size 或内容 hash（对齐 Claude 的 sourceVersion 语义）
- `clientID`：entry `oidc_client_id` → entryKey 中 `::` 后缀 → `GrokUsageClient.defaultClientID`
- `needsRefresh`：`expires_at` 或 JWT `exp` 距 now ≤ 300s
- `persist`：读盘 JSON object → 只改当前 entryKey 的 key/refresh_token/expires_at → atomic write 0600
- 无凭据：`.oauthNeedsSignIn(accountKey: nil)`（不要误判为有 API key 除非未来显式检测）

- [ ] **Step 4: 运行检查 PASS + Commit**

```bash
git add src/macos/Sources/AgentHaloCore/UsageMonitoring/Grok/GrokAuthStore.swift \
  src/macos/Sources/AgentHaloCoreChecks/
git commit -m "feat(macos): add GrokAuthStore for ~/.grok/auth.json"
```

---

### Task 3: GrokUsageClient + GrokUsageMapper

**Files:**
- Create: `src/macos/Sources/AgentHaloCore/UsageMonitoring/Grok/GrokUsageClient.swift`
- Create: `src/macos/Sources/AgentHaloCore/UsageMonitoring/Grok/GrokUsageMapper.swift`
- Modify: checks

**Interfaces:**
- Consumes: `UsageHTTPClient` / `UsageHTTPRequest`（host+path 模式，与 Codex/Claude 一致）
- Produces: `mapCredits(response:accountKey:planName:now:) throws -> UsageSnapshot`

- [ ] **Step 1: 写 Mapper 失败检查（纯数据，无网络）**

```swift
func testGrokUsageMapperWeeklyCredits() throws {
    let body = """
    {"config":{
      "creditUsagePercent": 12.5,
      "currentPeriod":{
        "type":"USAGE_PERIOD_TYPE_WEEKLY",
        "start":"2026-07-24T08:44:29.522745+00:00",
        "end":"2026-07-31T08:44:29.522745+00:00"
      },
      "onDemandCap":{"val":2500},
      "productUsage":[{"product":"GrokBuild","usagePercent":12.5}]
    }}
    """.data(using: .utf8)!

    let response = UsageHTTPResponse(statusCode: 200, headers: [:], body: body)
    let key = AccountCacheKey(providerID: .grok, digest: String(repeating: "a", count: 64))
    let snapshot = try GrokUsageMapper.mapCredits(
        response: response,
        accountKey: key,
        planName: "SuperGrok",
        now: Date(timeIntervalSince1970: 1_000_000)
    )
    expect(snapshot.providerID, .grok, "provider")
    expect(snapshot.planName, "SuperGrok", "plan")
    expect(snapshot.windows.count, 1, "only weekly window")
    expect(snapshot.windows[0].kind, .weekly, "weekly kind")
    expect(snapshot.windows[0].usedPercent, 12.5, "percent from total pool")
    expect(snapshot.windows[0].resetsAt != nil, "resetsAt set")
    // onDemand 不得进入 windows
}

func testGrokUsageMapperOmitsPercentAsZero() throws {
    let body = """
    {"config":{"currentPeriod":{
      "type":"USAGE_PERIOD_TYPE_WEEKLY",
      "start":"2026-07-24T00:00:00Z",
      "end":"2026-07-31T00:00:00Z"
    }}}
    """.data(using: .utf8)!
    let snapshot = try GrokUsageMapper.mapCredits(
        response: UsageHTTPResponse(statusCode: 200, headers: [:], body: body),
        accountKey: AccountCacheKey(providerID: .grok, digest: String(repeating: "b", count: 64)),
        planName: nil,
        now: Date()
    )
    expect(snapshot.windows[0].usedPercent, 0, "absent percent is 0")
}

func testGrokUsageMapperRejectsNonWeekly() {
    let body = """
    {"config":{"creditUsagePercent":1,"currentPeriod":{
      "type":"USAGE_PERIOD_TYPE_MONTHLY",
      "start":"2026-07-01T00:00:00Z",
      "end":"2026-08-01T00:00:00Z"
    }}}
    """.data(using: .utf8)!
    do {
        let snap = try GrokUsageMapper.mapCredits(
            response: UsageHTTPResponse(statusCode: 200, headers: [:], body: body),
            accountKey: AccountCacheKey(providerID: .grok, digest: String(repeating: "c", count: 64)),
            planName: nil,
            now: Date()
        )
        expect(snap.windows.isEmpty, "non-weekly must not invent weekly bars")
    } catch {
        // invalidResponse 也可接受
    }
}

func testGrokUsageMapperHTTPErrors() {
    // 401 → signInAgain, 429 → rateLimited, 503 → serviceUnavailable
}
```

Client 检查用 fake `UsageHTTPClient` 记录 host/path/headers：

```swift
// fetchCreditsConfig 必须：
// host == "cli-chat-proxy.grok.com"
// path == "/v1/billing?format=credits"  或 path+"/billing" + query —— 与 UsageHTTPClient 约定一致
// headers 含 authorization Bearer 与 x-xai-token-auth == xai-grok-cli
// refresh: host auth.x.ai path /oauth2/token
```

注意：若现有 `UsageHTTPRequest.path` 不含 query，则 path 用 `/v1/billing` 并扩展 client 支持 query，或 path 设为 `/v1/billing?format=credits`（若 URL 构造支持）。**实现前读 `URLSessionUsageHTTPClient` 如何拼 URL，与之一致。**

- [ ] **Step 2: 失败确认 → Step 3: 实现**

`GrokUsageClient` 关键头：

```swift
[
  "Authorization": "Bearer \(token)",
  "X-XAI-Token-Auth": "xai-grok-cli",
  "Accept": "application/json",
  "User-Agent": "AgentHalo"
]
```

`GrokUsageMapper.mapCredits`：对齐 OpenUsage `GrokCreditsConfigDecoder`（忽略 onDemand）。  
`planName(from settings response)`：读 `subscription_tier_display`。

- [ ] **Step 4: PASS + Commit**

```bash
git commit -m "feat(macos): add Grok usage client and credits mapper"
```

---

### Task 4: GrokUsageProvider + Coordinator 注册

**Files:**
- Create: `src/macos/Sources/AgentHaloCore/UsageMonitoring/Grok/GrokUsageProvider.swift`
- Modify: `UsageMonitoringCoordinator.swift` `live(...)` 注册 grok provider
- Modify: checks（provider refresh 成功/401 重试路径可简化，对齐 ClaudeUsageProvider 结构）

**Interfaces:**
- Produces: `GrokUsageProvider: UsageProvider`（`providerID == .grok`）
- Consumes: Task 2–3

- [ ] **Step 1: 写 Provider 检查**

使用 stub HTTP：

1. resolveAccess oauth → refresh 200 credits → `UsageRefreshResult` snapshot weekly  
2. credits 401 → 尝试 refresh token → 再试 credits  
3. 无 auth → failure signInAgain  

- [ ] **Step 2–3: 实现 Provider**

结构照抄 `ClaudeUsageProvider`：

- `resolveAccess` → authStore  
- `needsRefresh` → rotate via `usageClient.refreshToken` + `authStore.persist`  
- `fetchCreditsConfig` + 可选 `fetchSettings`（settings 失败仍可返回无 plan 的 snapshot）  
- `generationChecked` / `externalAccessChanged` 语义与 Claude 相同  

`UsageMonitoringCoordinator.live`：

```swift
let grokAuthStore = GrokAuthStore(files: files /* + home */)
let grokProvider = GrokUsageProvider(
    authStore: grokAuthStore,
    usageClient: GrokUsageClient(http: http)
)
return UsageMonitoringCoordinator(
    providers: [codexProvider, claudeProvider, grokProvider],
    cache: cache
)
```

- [ ] **Step 4: PASS + Commit**

```bash
git commit -m "feat(macos): register GrokUsageProvider in usage coordinator"
```

---

### Task 5: App 层额度接线（focus → provider）

**Files:**
- Modify: `src/macos/Sources/AgentHaloMac/AppDelegate.swift`（`usageProviderID(for:)`）
- Modify: 任何仍穷尽 `AgentKind`→`UsageProviderID` 的映射
- Modify: interaction checks 如需要

- [ ] **Step 1: 检查**

```swift
expect(AppDelegate.usageProviderID(for: .grok), .grok, "grok focus maps to grok usage")
```

（若 `usageProviderID` 为 private，改为 `internal`/`package` 或通过 details 路径间接测。）

- [ ] **Step 2–3: 实现**

```swift
static func usageProviderID(for agent: AgentKind) -> UsageProviderID {
    switch agent {
    case .codex: return .codex
    case .claudeCode: return .claude
    case .grok: return .grok
    }
}
```

确保 `setFocusedAgent(.grok)` 会 `requestUsageRefresh(for: .grok)`。

- [ ] **Step 4: Commit**

```bash
git commit -m "feat(macos): wire Grok focus to usage refresh"
```

---

### Task 6: Hook 二进制分流（停止污染 Claude）

**Files:**
- Modify: `src/macos/Sources/ClaudeCodeStatusHook/main.swift`
- Modify: `AgentHaloCoreChecks` 或独立 hook 检查（可用 `swift run ClaudeCodeStatusHook` + 临时 HOME）

**Interfaces:**
- Produces: Grok → `~/.agent-halo/grok-build-status.jsonl`，`source: "grok-hook"`；Claude 行为不变

- [ ] **Step 1: 写检查脚本（shell 或 Swift）**

```bash
TMP=$(mktemp -d)
export HOME="$TMP"
mkdir -p "$TMP/.agent-halo"
# Simulate Grok env
export GROK_SESSION_ID=test-grok-session
export GROK_HOOK_EVENT=pre_tool_use
echo '{"sessionId":"test-grok-session","cwd":"/tmp/proj","toolName":"run_terminal_command","timestamp":"2026-07-25T00:00:00Z"}' \
  | swift run ClaudeCodeStatusHook PreToolUse
test -f "$TMP/.agent-halo/grok-build-status.jsonl"
! test -f "$TMP/.agent-halo/claude-code-status.jsonl" || ! grep -q test-grok-session "$TMP/.agent-halo/claude-code-status.jsonl"
grep -q 'grok-hook' "$TMP/.agent-halo/grok-build-status.jsonl"
grep -q 'PreToolUse' "$TMP/.agent-halo/grok-build-status.jsonl"

unset GROK_SESSION_ID GROK_HOOK_EVENT
echo '{"session_id":"claude-1","cwd":"/tmp/c","tool_name":"Bash"}' \
  | swift run ClaudeCodeStatusHook PreToolUse
grep -q 'claude-hook' "$TMP/.agent-halo/claude-code-status.jsonl"
! grep -q 'claude-1' "$TMP/.agent-halo/grok-build-status.jsonl" 2>/dev/null || true
```

- [ ] **Step 2: 确认当前会污染（或检查失败）→ Step 3: 改 main.swift**

逻辑：

```swift
let env = ProcessInfo.processInfo.environment
let isGrok = !(env["GROK_SESSION_ID"] ?? "").isEmpty
    || !(env["GROK_HOOK_EVENT"] ?? "").isEmpty

// event name: prefer CLI arg; also map snake_case hookEventName → PascalCase
// e.g. pre_tool_use → PreToolUse via simple mapping table

let source = isGrok ? "grok-hook" : "claude-hook"
let statusFileName = isGrok ? "grok-build-status.jsonl" : "claude-code-status.jsonl"
```

事件名规范化表至少包含：

```text
session_start→SessionStart, user_prompt_submit→UserPromptSubmit,
pre_tool_use→PreToolUse, post_tool_use→PostToolUse,
post_tool_use_failure→PostToolUseFailure, notification→Notification,
stop→Stop, stop_failure→StopFailure, session_end→SessionEnd,
pre_compact→PreCompact, post_compact→PostCompact
```

若 CLI 已是 PascalCase，保持不变。

写路径、flock、rotation 逻辑复用现有代码，仅 `statusFilePath` 与 `source` 分叉。

- [ ] **Step 4: 脚本 PASS + Commit**

```bash
git commit -m "fix(macos): route Grok hooks to separate status jsonl"
```

---

### Task 7: GrokHookConfigurator

**Files:**
- Create: `src/macos/Sources/AgentHaloCore/GrokHookConfigurator.swift`
- Modify: `AppDelegate.swift` 启动调用 `GrokHookConfigurator.configure()`
- Modify: CoreChecks 幂等测试（temp home）

**Interfaces:**
- Produces: `~/.grok/hooks/agent-halo-status.json`；stage 同一 hook 二进制（路径可与 Claude 共用 `~/.agent-halo/claude-code-status-hook`）

- [ ] **Step 1: 检查**

```swift
func testGrokHookConfiguratorWritesHooksJSON() {
    // temp home + bundled binary fake executable
    GrokHookConfigurator.configure(homeDirectory: home, bundledHookBinary: fakeBin)
    let hooks = home.appendingPathComponent(".grok/hooks/agent-halo-status.json")
    expect(FileManager.default.fileExists(atPath: hooks.path), "hooks json exists")
    let text = try! String(contentsOf: hooks)
    expect(text.contains("PreToolUse"), "pre tool registered")
    expect(text.contains("claude-code-status-hook") || text.contains("agent-halo"), "command points to staged binary")
    // second call idempotent: mtime or content stable when already configured
}
```

- [ ] **Step 2–3: 实现**

JSON 形状：

```json
{
  "hooks": {
    "SessionStart": [{ "hooks": [{ "type": "command", "command": "/Users/.../.agent-halo/claude-code-status-hook SessionStart" }] }],
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "... UserPromptSubmit" }] }],
    "PreToolUse": [{ "matcher": ".*", "hooks": [{ "type": "command", "command": "... PreToolUse" }] }],
    "PostToolUse": [{ "matcher": ".*", "hooks": [{ "type": "command", "command": "... PostToolUse" }] }],
    "PostToolUseFailure": [{ "matcher": ".*", "hooks": [{ "type": "command", "command": "... PostToolUseFailure" }] }],
    "Notification": [{ "hooks": [{ "type": "command", "command": "... Notification" }] }],
    "Stop": [{ "hooks": [{ "type": "command", "command": "... Stop" }] }],
    "StopFailure": [{ "hooks": [{ "type": "command", "command": "... StopFailure" }] }],
    "SessionEnd": [{ "hooks": [{ "type": "command", "command": "... SessionEnd" }] }],
    "PreCompact": [{ "matcher": "", "hooks": [{ "type": "command", "command": "... PreCompact" }] }],
    "PostCompact": [{ "matcher": "", "hooks": [{ "type": "command", "command": "... PostCompact" }] }]
  }
}
```

幂等：若文件已含本 command 与事件集，跳过写盘。  
`AppDelegate` 在 `ClaudeHookConfigurator.configure()` 旁调用 `GrokHookConfigurator.configure()`。

- [ ] **Step 4: Commit**

```bash
git commit -m "feat(macos): auto-configure Grok Build lifecycle hooks"
```

---

### Task 8: GrokHookStatusReducer + Monitor

**Files:**
- Create: `GrokHookStatusReducer.swift`
- Create: `GrokHookStatusMonitor.swift`
- Modify: CoreChecks

**Interfaces:**
- Produces: `SessionSnapshot` with `agent: .grok`
- 可复制 `ClaudeHookStatusReducer` 后改 agent/默认项目名，或共享内部状态机；**不要**在 Claude reducer 里 hardcode 双 agent 混用同一日志。

- [ ] **Step 1: Reducer 检查**

```swift
func testGrokHookReducerLifecycle() {
    var r = GrokHookStatusReducer(threadId: "s1", now: Date(timeIntervalSince1970: 0))
    r.consume(jsonLine: #"{"timestamp":"2026-07-25T00:00:01Z","event":"UserPromptSubmit","sessionId":"s1","cwd":"/p/AgentHalo","source":"grok-hook"}"#, now: Date(timeIntervalSince1970: 1))
    expect(r.snapshot.state, .thinking, "prompt → thinking")
    expect(r.snapshot.agent, .grok, "agent kind")
    expect(r.snapshot.projectName, "AgentHalo", "cwd basename")

    r.consume(jsonLine: #"{"timestamp":"2026-07-25T00:00:02Z","event":"PreToolUse","sessionId":"s1","cwd":"/p/AgentHalo","toolName":"run_terminal_command","source":"grok-hook"}"#, now: Date(timeIntervalSince1970: 2))
    expect(r.snapshot.state, .working, "tool → working")

    r.consume(jsonLine: #"{"timestamp":"2026-07-25T00:00:03Z","event":"Notification","sessionId":"s1","notificationType":"permission_prompt","source":"grok-hook"}"#, now: Date(timeIntervalSince1970: 3))
    expect(r.snapshot.state, .attention, "permission")

    r.consume(jsonLine: #"{"timestamp":"2026-07-25T00:00:04Z","event":"Stop","sessionId":"s1","source":"grok-hook"}"#, now: Date(timeIntervalSince1970: 4))
    expect(r.snapshot.state, .done, "stop → done")
}
```

工具名：`run_terminal_command` 应映射为 shell 类 friendly action（在 reducer 的 `normalizedToolName` 中处理）。

- [ ] **Step 2–3: 实现 Monitor**

几乎拷贝 `ClaudeHookStatusMonitor`，默认 URL 改为 `grok-build-status.jsonl`，reducer 类型改为 Grok。

- [ ] **Step 4: Commit**

```bash
git commit -m "feat(macos): add Grok hook status monitor and reducer"
```

---

### Task 9: GrokActivityMonitor + 聚合 / Presence

**Files:**
- Create: `src/macos/Sources/AgentHaloMac/GrokActivityMonitor.swift`
- Modify: `AppDelegate.swift`（并行 tick、聚合 snapshots）
- Modify: `SessionAggregator.swift`（若 focus 过滤已通用则可能无需改）
- Modify: CoreChecks / interaction checks

**Interfaces:**
- 镜像 `ClaudeActivityMonitor`：`updatePollingContext(focusedAgent:detailsPanelVisible:)`；`snapshots()` / `poll()`

- [ ] **Step 1: 聚合检查**

```swift
// 两个 snapshot：claude + grok working；focus grok → aggregate.state == working 且仅 grok sessions
// focus claude → 不受 grok working 影响
```

- [ ] **Step 2–3: 实现**

`GrokActivityMonitor`：

- 内部 `GrokHookStatusMonitor`
- presence：读 `~/.grok/active_sessions.json` 非空 **或** 进程列表含 `grok`（实现选一种可靠方式；优先 active_sessions）
- focus != grok 且面板不可见时可降频（对齐 Claude）

`AppDelegate`：

- 持有 `grokActivityMonitor`
- 在现有 poll 循环合并 `codex + claude + grok` snapshots，再 `SessionAggregator.aggregate(..., focusedAgent:)`
- standby/offline 文案走 `AgentKind.grok`

- [ ] **Step 4: Commit**

```bash
git commit -m "feat(macos): poll Grok lifecycle into session aggregate"
```

---

### Task 10: 三方 Agent Toggle UI + 菜单 + 图标

**Files:**
- Create: `src/shared/assets/agent-switch/grok.svg`
- Modify: `DetailsPanel.swift` `AgentToggleView`（宽度、三等分点击、三图标）
- Modify: `AppDelegate` / 菜单构建（监控对象）
- Modify: `scripts/build-macos.sh`（确保 `agent-switch` 含 grok.svg 打进 bundle）
- Modify: `HaloInteractionChecks.swift`

**Interfaces:**
- 分段视觉：`Codex | CC | Grok`（图标顺序一致）
- 点击左/中/右三等分切换

- [ ] **Step 1: Interaction 检查**

- toggle 宽度足以容三图标（例如 108pt，原 76）  
- `setAgent(.grok)` 后 `selectedAgent == .grok`  
- 模拟点击右段选中 grok  

- [ ] **Step 2–3: 实现**

`AgentToggleView` 重写布局：

```swift
// 三个 NSImageView: codex, claude, grok
// width multiplier 1/3
// mouseDown: let third = bounds.width / 3
//   x < third → .codex
//   x < 2*third → .claudeCode
//   else → .grok
// activeBg 贴在选中 icon 上
// alpha: selected 1.0 else 0.40
```

`grok.svg`：简洁几何标记（圆环/抽象 G），避免复制商业 logo 复杂图形。可参考现有 `codex.svg` 风格的单色 SVG。

菜单：

```swift
// 在 codex/claude 菜单项旁增加 grokAgentItem
// SetFocusedAgent(.grok)
```

- [ ] **Step 4: Commit**

```bash
git commit -m "feat(macos): three-way Codex/CC/Grok agent switch"
```

---

### Task 11: 端到端验收与回归收尾

**Files:**
- Modify: design spec 状态行（可选）→「已进入实施」
- Modify: 任何遗漏的 exhaustive switch
- Docs：如 README.zh-CN 一小节「支持 Grok Build（macOS）」——仅当仓库 README 已列 Claude/Codex 时对称补充一句

- [ ] **Step 1: 全量检查**

```bash
cd src/macos
swift run AgentHaloCoreChecks
# 按项目脚本
bash ../../scripts/run-macos.sh --verify   # 若存在
```

- [ ] **Step 2: 手动清单**

1. 已 `grok login`：Halo 焦点 Grok → 显示 Weekly % 与重置时间。  
2. Grok 会话里跑工具 → 光环 working；Stop 后 done。  
3. 焦点 CC → 不应显示正在进行的 Grok 会话。  
4. `~/.agent-halo/claude-code-status.jsonl` 在新 Grok 操作下不再追加 Grok session id。  
5. `~/.agent-halo/grok-build-status.jsonl` 有新行。  
6. 无 Pay-as-you-go UI。  
7. Codex/Claude 原路径无回归。

- [ ] **Step 3: 最终 commit（若有文档/修补）**

```bash
git commit -m "docs: note macOS Grok Build monitoring support"
```

---

## Spec 覆盖自检

| Spec 要求 | Task |
| --- | --- |
| AgentKind / 标签 Grok | 1, 10 |
| UsageProviderID.grok + Weekly only | 1, 3, 4 |
| 忽略 Pay-as-you-go | 3（不映射）+ 10（无 UI） |
| Auth 刷新写回多账号安全 | 2 |
| billing + settings plan | 3, 4 |
| Coordinator 注册 / focus 刷新 | 4, 5 |
| Hook 分流防污染 | 6 |
| `~/.grok/hooks` 配置 | 7 |
| 最小生命周期状态机 | 8, 9 |
| 三方 UI | 10 |
| 测试与手动验收 | 每任务 + 11 |
| macOS only / 不改 Windows | Global Constraints |
| 不改视觉 spec JSON | 未列入文件 |

## Placeholder 扫描

计划中无 TBD/TODO；Client URL 拼装依赖读现有 `URLSessionUsageHTTPClient` 的一步已写明「实现前读」。若 path 不支持 query，在 Task 3 内扩展最小 query 支持并补检查。

## 类型一致性

- `AgentKind.grok` ↔ `UsageProviderID.grok` 仅通过 `usageProviderID(for:)` 映射  
- Hook `source: "grok-hook"` 与 monitor 路径 `grok-build-status.jsonl` 全文一致  
- `SessionSnapshot.agent == .grok` 用于聚合过滤  

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-07-25-macos-grok-build-usage-lifecycle-implementation.md`.

**两种执行方式：**

1. **Subagent-Driven（推荐）** — 每任务新开 subagent，任务间 review，迭代快  
2. **Inline Execution** — 本会话按 `executing-plans` 连续执行并设检查点  

你更想用哪一种？
