# OpenUsage 风格监控 macOS Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 AgentHalo macOS 详情面板中按 OAuth / API 密钥两种模式显示 Provider 使用窗口或四行会话详情，并实现 Codex、Claude Code 的 OAuth 凭据发现、自动刷新、使用情况请求、账户隔离缓存和安全降级。

**Architecture:** 新能力全部放入现有 `AgentHaloCore`，按 `AuthStore → UsageClient → UsageMapper → UsageProvider → UsageSnapshotCache → UsageMonitoringCoordinator → DetailsContentResolver` 分层。`AppDelegate` 只负责编排当前 Provider、本地精确会话数据和低频刷新；`DetailsPanel` 只渲染互斥的 `DetailsPanelBody`。实现参考 `/Users/wjs/work/openusage`，但缓存改为 Provider+账户维度，凭据写回保留未知 JSON 字段和原文件权限，且不引入 OpenUsage 的 Widget、余额或扩展窗口。

**Tech Stack:** Swift 6、Swift Package Manager、AppKit、Foundation/URLSession、CryptoKit、macOS `/usr/bin/security`、现有 `AgentHaloCoreChecks` 与 `AgentHaloMac --self-check`

## Global Constraints

- 只修改 macOS 与共享本地化资源，不修改 Windows 运行时代码。
- 用户可见模式只有 OAuth 和 API 密钥；OAuth 与 API Key 同时存在时 OAuth 优先。
- Provider 行始终显示；UI 不显示 `OAuth`、`API Key`、“使用情况 / 余额”或“会话详情”等标签。
- OAuth 主体固定显示 `5-Hour` / `Weekly`（中文“五小时”/“每周”）；不实现余额、Credits、Extra Usage、Rate Limit Reset Credits、Spark、Spark Weekly、Sonnet、Fable。
- API 密钥主体固定为 Project、Session title、Model、Input/output tokens 四行；项目与会话标题不得合并或互相回退。
- `contextPill` 只使用当前准确会话的本地数据，与 Usage API 成败和认证模式独立；离线或非准确会话时隐藏。
- 只向 Codex、Claude Code 的官方 OAuth/Usage 端点发送请求；自定义或第三方推理端点绝不接收 Usage 请求。
- 不记录 Token、API Key、认证头、响应正文、账户缓存键或原始凭据 JSON；日志只允许 Provider、来源类型、HTTP 分类、耗时和缓存命中。
- Token 临期阈值 5 分钟；Usage fresh 阈值 5 分钟；stale 阈值 10 分钟；429 缺省冷却 5 分钟。
- 文件写回必须原子替换、保留原权限和未知 JSON 字段；新缓存文件固定为 `0600`。
- 同 Provider 同时最多一个刷新任务；旧 Provider 请求可完成，但不得覆盖当前面板。
- 新详情链路不再读取 `RateLimitReader` 作为 OAuth 使用情况来源；旧 reader 与其既有回归检查可保留。
- 每项任务遵循 TDD：先添加失败检查并确认失败原因，再做最小实现，再运行聚焦检查与完整检查。
- 提交前只暂存本任务列出的文件，先执行 `git status --short`，不得混入用户已有改动。

---

## 目标文件与接口总览

新增 Core 文件：

```text
src/macos/Sources/AgentHaloCore/UsageMonitoring/
├── UsageModels.swift
├── UsageProvider.swift
├── UsageHTTPClient.swift
├── UsageSystemClients.swift
├── CredentialJSON.swift
├── AccessModeResolver.swift
├── UsageSnapshotCache.swift
├── UsageMonitoringCoordinator.swift
├── DetailsContentResolver.swift
├── Codex/
│   ├── CodexAuthStore.swift
│   ├── CodexUsageClient.swift
│   ├── CodexUsageMapper.swift
│   └── CodexUsageProvider.swift
└── Claude/
    ├── ClaudeAuthStore.swift
    ├── ClaudeUsageClient.swift
    ├── ClaudeUsageMapper.swift
    └── ClaudeUsageProvider.swift
```

新增检查文件：

```text
src/macos/Sources/AgentHaloCoreChecks/UsageMonitoringCheckSupport.swift
src/macos/Sources/AgentHaloCoreChecks/UsageMonitoringChecks.swift
```

修改现有文件：

```text
src/macos/Sources/AgentHaloCore/SessionReducer.swift
src/macos/Sources/AgentHaloCoreChecks/main.swift
src/macos/Sources/AgentHaloMac/DetailsPanel.swift
src/macos/Sources/AgentHaloMac/AppDelegate.swift
src/macos/Sources/AgentHaloMac/HaloInteractionChecks.swift
src/shared/locales/en.json
src/shared/locales/zh.json
src/macos/Sources/AgentHaloCore/locales/en.json
src/macos/Sources/AgentHaloCore/locales/zh.json
```

统一公开接口以以下签名为准：

```swift
public protocol UsageProvider: Sendable {
    var id: UsageProviderID { get }
    func resolveAccess() async -> ResolvedProviderAccess
    func refresh(using access: OAuthAccess) async throws -> UsageRefreshResult
}

public struct UsageRefreshResult: Sendable {
    public var snapshot: UsageSnapshot
    public var migrateCacheFrom: AccountCacheKey?
}

public actor UsageMonitoringCoordinator {
    public func prepare(_ providerID: UsageProviderID) async -> UsageMonitorState
    public func ensureFresh(_ providerID: UsageProviderID) async -> UsageMonitorState
    public func state(for providerID: UsageProviderID) -> UsageMonitorState
    public func cancelAll()
}

public enum DetailsPanelBody: Equatable, Sendable {
    case usage(UsageDetailsModel)
    case session(SessionDetailsSnapshot)
}

public struct DetailsPanelViewModel: Equatable, Sendable {
    public var providerName: String
    public var planName: String?
    public var usageWarning: String?
    public var contextUsedPercent: Double?
    public var body: DetailsPanelBody
}
```

`UsageRefreshResult.migrateCacheFrom` 是对详细设计中 Provider 协议的必要细化：它只在 AgentHalo 自己成功轮换 Token 且账户指纹随之变化时返回旧键；外部重新登录返回 `nil`，从接口层保证旧账户快照不会迁移给新登录。

由于 `AgentHaloCoreChecks` 是独立 executable target 而不是 SwiftPM test target，检查代码直接构造的模型、协议、AuthStore、Client、Provider、Cache 和 Coordinator 及其注入式初始化器必须声明为 `public`；仅文件内 JSON 辅助函数和生产实现细节保持 internal/private。所有 public struct 必须显式提供 `public init`，不能依赖模块内可见的合成 memberwise initializer。

依赖注入入口统一为：

```swift
public init(
    environment: any UsageEnvironmentReading,
    files: any UsageFileAccessing,
    keychain: any UsageKeychainAccessing,
    now: @escaping @Sendable () -> Date = Date.init
)

public init(http: any UsageHTTPClient)

public init(
    providers: [UsageProviderID: any UsageProvider],
    cache: UsageSnapshotCache,
    now: @escaping @Sendable () -> Date = Date.init
)
```

生产默认值由各类型的 convenience/default initializer 提供；检查一律注入 fake 和固定时钟，不触碰本机真实凭据或网络。

---

### Task 1: 建立统一领域模型、HTTP 与系统边界

**Files:**
- Create: `src/macos/Sources/AgentHaloCore/UsageMonitoring/UsageModels.swift`
- Create: `src/macos/Sources/AgentHaloCore/UsageMonitoring/UsageProvider.swift`
- Create: `src/macos/Sources/AgentHaloCore/UsageMonitoring/UsageHTTPClient.swift`
- Create: `src/macos/Sources/AgentHaloCore/UsageMonitoring/UsageSystemClients.swift`
- Create: `src/macos/Sources/AgentHaloCore/UsageMonitoring/CredentialJSON.swift`
- Create: `src/macos/Sources/AgentHaloCore/UsageMonitoring/AccessModeResolver.swift`
- Create: `src/macos/Sources/AgentHaloCoreChecks/UsageMonitoringCheckSupport.swift`
- Create: `src/macos/Sources/AgentHaloCoreChecks/UsageMonitoringChecks.swift`
- Modify: `src/macos/Sources/AgentHaloCoreChecks/main.swift`

**Interfaces:**
- Produces all Provider-neutral value types and failures.
- Produces injectable environment/file/keychain/process/HTTP protocols.
- Produces SHA256 account/source digests without exposing raw Token.
- Consumed by every later task.

- [ ] **Step 1: Add compile-level checks for model invariants and HTTP header normalization**

In `UsageMonitoringChecks.swift`, add `runUsageModelChecks()` covering:

```swift
func runUsageModelChecks() async {
    let key = AccountCacheKey(providerID: .codex, digest: "abc")
    let snapshot = UsageSnapshot(
        providerID: .codex,
        accountKey: key,
        planName: "Pro 20x",
        windows: [UsageWindow(kind: .session, usedPercent: 4, resetsAt: nil, duration: 18_000)],
        refreshedAt: Date(timeIntervalSince1970: 100)
    )
    expect(snapshot.windows.first?.kind, .session, "usage window kind")
    expect(UsageDigest.sha256("secret").count, 64, "SHA256 must use lowercase hex")

    let response = UsageHTTPResponse(
        statusCode: 429,
        headers: ["Retry-After": "120"],
        body: Data()
    )
    expect(response.header("retry-after"), "120", "headers must be case insensitive")
}
```

Append `await runUsageModelChecks()` before the final PASS print in `main.swift`.

- [ ] **Step 2: Run the check and confirm it fails because the new types do not exist**

Run:

```bash
cd src/macos
swift run AgentHaloCoreChecks
```

Expected: compilation fails with `cannot find 'AccountCacheKey' in scope` or the first equivalent missing-type error. A failure in an existing check must be investigated before continuing.

- [ ] **Step 3: Implement the exact Provider-neutral models**

In `UsageModels.swift`, define public `Codable`, `Equatable`, `Hashable` and `Sendable` conformances where the values cross actors or enter the cache:

```swift
public enum UsageProviderID: String, Codable, Sendable { case codex, claude }
public enum AccessMode: String, Codable, Sendable { case oauth, apiKey }
public enum UsageWindowKind: String, Codable, Sendable { case session, weekly }

public struct UsageWindow: Codable, Equatable, Sendable {
    public var kind: UsageWindowKind
    public var usedPercent: Double
    public var resetsAt: Date?
    public var duration: TimeInterval
}

public struct AccountCacheKey: Codable, Hashable, Sendable {
    public var providerID: UsageProviderID
    public var digest: String
}

public struct UsageSnapshot: Codable, Equatable, Sendable {
    public var providerID: UsageProviderID
    public var accountKey: AccountCacheKey
    public var planName: String?
    public var windows: [UsageWindow]
    public var refreshedAt: Date
}

public enum UsageDataStatus: Equatable, Sendable {
    case fresh(updatedAt: Date)
    case stale(updatedAt: Date)
    case noData
    case signInAgain
}

public enum UsageFailureReason: Equatable, Sendable {
    case rateLimited(retryAt: Date?)
    case network
    case serviceUnavailable
    case invalidResponse
    case signInAgain
}

public struct UsageMonitorState: Equatable, Sendable {
    public var providerID: UsageProviderID
    public var accessMode: AccessMode
    public var snapshot: UsageSnapshot?
    public var status: UsageDataStatus?
    public var lastFailure: UsageFailureReason?
    public var isRefreshing: Bool
}
```

Also define:

```swift
public enum CredentialSource: Hashable, Sendable {
    case file(path: String)
    case keychain(service: String, account: String?)
}

public struct OAuthPlanHint: Equatable, Sendable {
    public var subscriptionType: String?
    public var rateLimitTier: String?
}

public struct OAuthAccess: Sendable {
    public var providerID: UsageProviderID
    public var accountKey: AccountCacheKey
    public var source: CredentialSource
    public var sourceVersion: String
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date?
    public var accountID: String?
    public var planHint: OAuthPlanHint?
}

public enum ResolvedProviderAccess: Sendable {
    case oauth(OAuthAccess)
    case oauthNeedsSignIn(accountKey: AccountCacheKey?)
    case apiKey
}

public enum UsageProviderFailure: Error, Equatable, Sendable {
    case rateLimited(retryAt: Date?)
    case network
    case serviceUnavailable
    case invalidResponse
    case signInAgain
}

public enum UsageDigest {
    public static func sha256(_ value: String) -> String
}
```

`OAuthAccess` must not conform to `Codable`, `CustomStringConvertible` or `CustomDebugStringConvertible`.

In `UsageProvider.swift`, implement the `UsageProvider` protocol and `UsageRefreshResult` exactly as declared in the interface overview; in `UsageHTTPClient.swift` and `UsageSystemClients.swift`, make all request/response/result types and fake-facing protocols public with explicit public initializers.

- [ ] **Step 4: Implement system adapters without credential logging**

In `UsageHTTPClient.swift`, add `UsageHTTPRequest`, `UsageHTTPResponse`, `UsageHTTPClient` and `URLSessionUsageHTTPClient`. Normalize all response-header keys to lowercase. The production client may log only method, fixed official host, status code and elapsed time; it must never log request headers, request body or response body.

In `UsageSystemClients.swift`, add:

```swift
public protocol UsageEnvironmentReading: Sendable {
    func value(for name: String) -> String?
}

public protocol UsageFileAccessing: Sendable {
    func readDataIfPresent(at path: String) throws -> Data?
    func writeAtomically(_ data: Data, to path: String, preservingModeOf existingPath: String?) throws
}

public protocol UsageKeychainAccessing: Sendable {
    func read(service: String, account: String?) throws -> String?
    func write(service: String, account: String?, value: String) throws
}

public protocol UsageProcessRunning: Sendable {
    func run(executable: String, arguments: [String], timeout: TimeInterval) throws -> UsageProcessResult
}
```

Production keychain reads must invoke `/usr/bin/security find-generic-password`; writes must invoke `add-generic-password -U` with the same service/account. Exit code 44 means “not found”; other nonzero exits are classified errors. Never include the returned password or `-w` value in logs.

Production file writes must create a private temporary file in the destination directory, use the existing target mode when present (otherwise `0600`), call `fchmod`, write all bytes, `fsync`, close and `rename`. Clean up the temporary file on every failure path. `UsageHTTPResponse` must provide an explicit public initializer that lowercases incoming header keys, so production responses and synthetic checks share identical case-insensitive lookup behavior.

In `CredentialJSON.swift`, implement raw-object helpers using `JSONSerialization`:

```swift
enum CredentialJSON {
    static func object(from data: Data) throws -> [String: Any]
    static func data(from object: [String: Any], prettyPrinted: Bool) throws -> Data
    static func string(_ object: [String: Any], path: [String]) -> String?
    static func set(_ value: Any?, path: [String], in object: inout [String: Any])
}
```

`set` must update only the requested nested path and leave every unrelated key untouched.

In `AccessModeResolver.swift`, implement one shared rule:

```swift
enum AccessModeResolver {
    static func resolve(
        oauth: OAuthAccess?,
        oauthNeedsSignIn: AccountCacheKey?,
        hasAPIKeyLikeAccess: Bool
    ) -> ResolvedProviderAccess
}
```

Return OAuth first, then `oauthNeedsSignIn`, otherwise API key; `hasAPIKeyLikeAccess` documents detection but never creates a third UI mode.

- [ ] **Step 5: Add deterministic fakes for later checks**

In `UsageMonitoringCheckSupport.swift`, add:

- `LockedBox<Value>` using `NSLock`, marked `@unchecked Sendable` only around the lock-protected value.
- `FakeUsageEnvironment`.
- `FakeUsageFiles`, including stored mode values and captured writes.
- `FakeUsageKeychain`, keyed by service plus optional account.
- `RecordingUsageHTTPClient` actor with queued responses/errors and captured requests.
- `FakeUsageProvider` actor with a controllable access result, refresh result/error, call count and optional continuation gate.

No fake may print credential values when a check fails.

- [ ] **Step 6: Run the focused and full checks**

Run:

```bash
cd src/macos
swift run AgentHaloCoreChecks
swift build
```

Expected: both pass; output ends with `PASS AgentHaloCore checks`.

- [ ] **Step 7: Commit Task 1**

```bash
git status --short
git add src/macos/Sources/AgentHaloCore/UsageMonitoring \
        src/macos/Sources/AgentHaloCoreChecks/UsageMonitoringCheckSupport.swift \
        src/macos/Sources/AgentHaloCoreChecks/UsageMonitoringChecks.swift \
        src/macos/Sources/AgentHaloCoreChecks/main.swift
git commit -m "feat: add usage monitoring foundations"
```

---

### Task 2: 实现 Codex 凭据发现、模式解析和安全写回

**Files:**
- Create: `src/macos/Sources/AgentHaloCore/UsageMonitoring/Codex/CodexAuthStore.swift`
- Modify: `src/macos/Sources/AgentHaloCoreChecks/UsageMonitoringChecks.swift`

**Interfaces:**
- `CodexAuthStore.resolveAccess()` returns OAuth/API mode using OpenUsage source order.
- `reload(source:)` rereads exactly one source.
- `persist(rotation:replacing:)` compare-checks the source version and merges rotated fields only.

- [ ] **Step 1: Add failing Codex auth checks**

Add checks for all of these cases:

1. `CODEX_HOME/auth.json` wins over default paths.
2. Without `CODEX_HOME`, `~/.config/codex/auth.json`, then `~/.codex/auth.json`, then Keychain service `Codex Auth` are searched.
3. Any nonempty `tokens.access_token` returns OAuth even when `OPENAI_API_KEY` is also present.
4. API-key-only and no-recognized-credential cases both return API key mode.
5. `account_id` produces `SHA256(accountID)`; without it, source identity plus refresh/access-token digest is used.
6. JWT `exp` within 5 minutes requires refresh; unreadable JWT falls back to `last_refresh > 8 days`; a new login without either does not refresh.
7. File rotation preserves a custom top-level key, a custom nested token key and the original mode.
8. Keychain rotation writes to service `Codex Auth` with the same account form.
9. If the source version changes before writeback, `persist` refuses to overwrite it.

Use synthetic token strings and JSON; never use the developer machine’s real auth file.

- [ ] **Step 2: Confirm the new checks fail**

```bash
cd src/macos
swift run AgentHaloCoreChecks
```

Expected: compilation fails because `CodexAuthStore` is absent.

- [ ] **Step 3: Implement Codex auth data and source discovery**

Implement the exact external surface:

```swift
public struct CodexTokenRotation: Sendable {
    var accessToken: String
    var refreshToken: String?
    var idToken: String?
    var refreshedAt: Date
}

public struct CodexAuthStore: Sendable {
    static let keychainService = "Codex Auth"
    static let refreshWindow: TimeInterval = 5 * 60

    func resolveAccess() -> ResolvedProviderAccess
    func reload(source: CredentialSource) -> OAuthAccess?
    func needsRefresh(_ access: OAuthAccess, lastRefresh: Date?) -> Bool
    func persist(rotation: CodexTokenRotation, replacing expected: OAuthAccess) throws -> OAuthAccess?
}
```

Read the OpenUsage-compatible JSON paths:

```text
tokens.access_token
tokens.refresh_token
tokens.id_token
tokens.account_id
last_refresh
OPENAI_API_KEY
```

When `CODEX_HOME` is nonempty, inspect only `$CODEX_HOME/auth.json` before Keychain. Otherwise inspect `~/.config/codex/auth.json`, `~/.codex/auth.json`, then Keychain. Scan every candidate for OAuth before deciding API mode so an earlier API-key-only file cannot shadow a later OAuth login.

- [ ] **Step 4: Implement merge-only writeback**

Before writing, reread the exact `CredentialSource` and recompute `sourceVersion`. If it differs from `expected.sourceVersion`, return `nil` and do not write. Otherwise update only:

```text
tokens.access_token
tokens.refresh_token  (only when refresh response contains one)
tokens.id_token       (only when refresh response contains one)
last_refresh
```

Serialize the full raw object and write it through `UsageFileAccessing` or the same Keychain service/account. Return a rebuilt `OAuthAccess` with the rotated source version and account key.

- [ ] **Step 5: Run checks and commit**

```bash
cd src/macos
swift run AgentHaloCoreChecks
cd ../..
git status --short
git add src/macos/Sources/AgentHaloCore/UsageMonitoring/Codex/CodexAuthStore.swift \
        src/macos/Sources/AgentHaloCoreChecks/UsageMonitoringChecks.swift
git commit -m "feat: resolve Codex OAuth credentials"
```

---

### Task 3: 实现 Codex Usage Client、Mapper 和 Provider

**Files:**
- Create: `src/macos/Sources/AgentHaloCore/UsageMonitoring/Codex/CodexUsageClient.swift`
- Create: `src/macos/Sources/AgentHaloCore/UsageMonitoring/Codex/CodexUsageMapper.swift`
- Create: `src/macos/Sources/AgentHaloCore/UsageMonitoring/Codex/CodexUsageProvider.swift`
- Modify: `src/macos/Sources/AgentHaloCoreChecks/UsageMonitoringChecks.swift`

**Interfaces:**
- Calls only Codex official refresh and usage endpoints.
- Maps plan and exactly two supported windows.
- Performs proactive refresh and at most one 401 refresh retry.

- [ ] **Step 1: Add failing Codex client/mapper/provider checks**

Cover:

- Usage GET URL `https://chatgpt.com/backend-api/wham/usage`, 10-second timeout, Bearer header, optional `ChatGPT-Account-Id`.
- Refresh POST URL `https://auth.openai.com/oauth/token`, 15-second timeout, form fields `grant_type`, client ID `app_EMoamEEZ73f0CkXaXp7hrann`, refresh token.
- No request to reset-credit, balance, spend or custom endpoint paths.
- Plan mapping: `prolite → Pro 5x`, `pro → Pro 20x`, `free → Free`, `plus → Plus`, blank → nil.
- `primary_window` and `secondary_window` mapping; explicit `limit_window_seconds`/duration reclassifies a sole 7-day primary window as Weekly, matching OpenUsage.
- Clamp used percent to `0...100`; keep a missing window absent; parse reset seconds and ISO-8601 safely.
- Empty JSON, non-2xx and a body without plan/windows classify correctly.
- Proactive refresh rereads the exact source before rotating.
- First 401 refreshes once and retries; second 401 returns `signInAgain` with exactly two usage requests.
- Refresh codes `refresh_token_expired`, `refresh_token_reused`, `refresh_token_invalidated` map to `signInAgain`.
- Internal rotation returns `migrateCacheFrom`; adopting an externally changed source returns no migration key.
- A writeback failure still allows the in-memory rotated token to serve the current request.

- [ ] **Step 2: Confirm failure**

```bash
cd src/macos
swift run AgentHaloCoreChecks
```

Expected: missing Codex client/mapper/provider symbols.

- [ ] **Step 3: Implement client and error classification**

`CodexUsageClient` must expose:

```swift
public struct CodexRefreshResponse: Sendable {
    var accessToken: String
    var refreshToken: String?
    var idToken: String?
}

public struct CodexUsageClient: Sendable {
    func refreshToken(_ refreshToken: String) async throws -> CodexRefreshResponse
    func fetchUsage(accessToken: String, accountID: String?) async throws -> UsageHTTPResponse
}
```

Transport errors map to `.network`; 500...599 to `.serviceUnavailable`; malformed successful bodies to `.invalidResponse`; 429 parses `Retry-After` as seconds or HTTP date and throws `.rateLimited(retryAt:)`.

- [ ] **Step 4: Implement the restricted mapper**

`CodexUsageMapper.map(response:accountKey:now:)` must read only:

```text
plan_type
rate_limit.primary_window
rate_limit.secondary_window
```

Use 18,000 seconds for a 5-hour default and 604,800 seconds for a weekly default. Ignore `additional_rate_limits`, credits, reset credits and every balance/spend field even when present in the fixture.

- [ ] **Step 5: Implement Provider refresh flow**

`CodexUsageProvider` conforms to `UsageProvider` and uses this order:

```text
resolveAccess
→ reread exact source
→ if external source changed, adopt it without cache migration
→ proactive refresh when needed
→ usage request
→ on first 401, refresh and retry once
→ map snapshot
→ return snapshot plus internal-rotation migration key
```

Run synchronous file/Keychain discovery and writeback in `Task.detached` so AppKit’s main actor is never blocked by `/usr/bin/security` or filesystem work.

- [ ] **Step 6: Run checks and commit**

```bash
cd src/macos
swift run AgentHaloCoreChecks
swift build
cd ../..
git status --short
git add src/macos/Sources/AgentHaloCore/UsageMonitoring/Codex \
        src/macos/Sources/AgentHaloCoreChecks/UsageMonitoringChecks.swift
git commit -m "feat: fetch Codex OAuth usage"
```

---

### Task 4: 实现 Claude Code 凭据发现、Scope 判定和安全写回

**Files:**
- Create: `src/macos/Sources/AgentHaloCore/UsageMonitoring/Claude/ClaudeAuthStore.swift`
- Modify: `src/macos/Sources/AgentHaloCoreChecks/UsageMonitoringChecks.swift`

**Interfaces:**
- Stored OAuth uses Keychain-first order.
- Inference-only environment token remains API key mode.
- Missing `user:profile` remains OAuth mode with sign-in-again state.

- [ ] **Step 1: Add failing Claude auth checks**

Cover:

1. Keychain service `Claude Code-credentials`, current-user account first, legacy service-only second, credential file last.
2. `CLAUDE_CONFIG_DIR` changes the file path and adds the OpenUsage-compatible 8-character SHA256 service suffix before the base service.
3. Stored OAuth plus `CLAUDE_CODE_OAUTH_TOKEN` chooses stored OAuth.
4. Only `CLAUDE_CODE_OAUTH_TOKEN` returns API key mode.
5. Stored OAuth with absent/empty scopes is allowed; explicit scopes missing `user:profile` return `oauthNeedsSignIn` with the same account key.
6. `expiresAt` is epoch milliseconds and refreshes within 5 minutes.
7. Plan hints preserve `subscriptionType` and `rateLimitTier` in memory.
8. File and Keychain rotation preserve unknown fields and exact source.
9. Credential-generation mismatch refuses writeback, proving external re-login cannot be overwritten.

- [ ] **Step 2: Confirm failure**

```bash
cd src/macos
swift run AgentHaloCoreChecks
```

Expected: missing `ClaudeAuthStore`.

- [ ] **Step 3: Implement stored credential parsing and mode rules**

Read this shape from Keychain/file raw JSON:

```text
claudeAiOauth.accessToken
claudeAiOauth.refreshToken
claudeAiOauth.expiresAt
claudeAiOauth.subscriptionType
claudeAiOauth.rateLimitTier
claudeAiOauth.scopes
```

Implement:

```swift
public struct ClaudeTokenRotation: Sendable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
}

public struct ClaudeAuthStore: Sendable {
    func resolveAccess() -> ResolvedProviderAccess
    func reload(source: CredentialSource) -> OAuthAccess?
    func needsRefresh(_ access: OAuthAccess) -> Bool
    func persist(rotation: ClaudeTokenRotation, replacing expected: OAuthAccess) throws -> OAuthAccess?
}
```

Account keys use source identity plus refresh-token digest, or access-token digest when no refresh token exists. Source version includes the effective stored OAuth fields but remains a SHA256 digest.

- [ ] **Step 4: Restrict endpoints to official production OAuth**

Do not copy OpenUsage’s custom/staging OAuth endpoint support. AgentHalo must never send stored credentials to `CLAUDE_CODE_CUSTOM_OAUTH_URL`, a local OAuth base or an inference Base URL. If `CLAUDE_CODE_CUSTOM_OAUTH_URL`, `CLAUDE_LOCAL_OAUTH_API_BASE` or an equivalent recognized non-production OAuth override is nonempty, `resolveAccess()` must not treat that stored credential as official OAuth and must return the API-key fallback for this feature. Add this case to the Task 4 auth checks. The Usage Client itself keeps hard-coded production URLs and never accepts a caller-provided URL.

- [ ] **Step 5: Run checks and commit**

```bash
cd src/macos
swift run AgentHaloCoreChecks
cd ../..
git status --short
git add src/macos/Sources/AgentHaloCore/UsageMonitoring/Claude/ClaudeAuthStore.swift \
        src/macos/Sources/AgentHaloCoreChecks/UsageMonitoringChecks.swift
git commit -m "feat: resolve Claude OAuth credentials"
```

---

### Task 5: 实现 Claude Usage Client、Mapper 和 Provider

**Files:**
- Create: `src/macos/Sources/AgentHaloCore/UsageMonitoring/Claude/ClaudeUsageClient.swift`
- Create: `src/macos/Sources/AgentHaloCore/UsageMonitoring/Claude/ClaudeUsageMapper.swift`
- Create: `src/macos/Sources/AgentHaloCore/UsageMonitoring/Claude/ClaudeUsageProvider.swift`
- Modify: `src/macos/Sources/AgentHaloCoreChecks/UsageMonitoringChecks.swift`

**Interfaces:**
- Calls official Anthropic usage/refresh endpoints only.
- Reads only `five_hour` and `seven_day` usage windows.
- Uses credential plan hints for display mapping.

- [ ] **Step 1: Add failing Claude client/mapper/provider checks**

Cover:

- Usage GET `https://api.anthropic.com/api/oauth/usage`, headers `Authorization`, `Accept`, `Content-Type`, `anthropic-beta: oauth-2025-04-20`, `User-Agent: claude-code/2.1.69`.
- Refresh POST `https://platform.claude.com/v1/oauth/token`, client ID `9d1c250a-e61b-44d9-88ed-5944d1962f5e`, full OpenUsage scope string and 15-second timeout.
- Map `five_hour.utilization` and `seven_day.utilization`; reset accepts ISO-8601, seconds or milliseconds.
- Explicitly ignore `seven_day_sonnet`, `limits` and `extra_usage` even when populated.
- Plan `max + tier containing 5x → Max 5x`, `pro + no multiplier → Pro`, blank subscription → nil.
- Proactive refresh, exact-source reread, generation compare, one 401 retry and writeback-failure continuation.
- Retry-After seconds and HTTP-date parsing.
- Internal rotation migrates cache binding; external login change does not.

- [ ] **Step 2: Confirm failure**

```bash
cd src/macos
swift run AgentHaloCoreChecks
```

- [ ] **Step 3: Implement the official client**

Use the exact scope string:

```text
user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload
```

`ClaudeUsageClient` returns raw `UsageHTTPResponse`; provider/mapper owns HTTP classification so the same 429 and 401 rules are exercised in tests.

- [ ] **Step 4: Implement the restricted mapper and Provider**

`ClaudeUsageMapper` exposes:

```swift
static func map(
    response: UsageHTTPResponse,
    accountKey: AccountCacheKey,
    planHint: OAuthPlanHint?,
    now: Date
) throws -> UsageSnapshot

static func formatPlan(subscriptionType: String?, rateLimitTier: String?) -> String?
static func retryAfterDate(_ response: UsageHTTPResponse, now: Date) -> Date?
```

The Provider uses the same refresh order and error taxonomy as Codex. A stored OAuth missing `user:profile` never reaches the HTTP client because the AuthStore returns `oauthNeedsSignIn`.

- [ ] **Step 5: Run checks and commit**

```bash
cd src/macos
swift run AgentHaloCoreChecks
swift build
cd ../..
git status --short
git add src/macos/Sources/AgentHaloCore/UsageMonitoring/Claude \
        src/macos/Sources/AgentHaloCoreChecks/UsageMonitoringChecks.swift
git commit -m "feat: fetch Claude OAuth usage"
```

---

### Task 6: 实现 Provider+账户持久化快照缓存

**Files:**
- Create: `src/macos/Sources/AgentHaloCore/UsageMonitoring/UsageSnapshotCache.swift`
- Modify: `src/macos/Sources/AgentHaloCoreChecks/UsageMonitoringChecks.swift`

**Interfaces:**
- Persists only last successful snapshots.
- Distinguishes disk-loaded and current-run snapshots.
- Supports safe internal Token-rotation migration.

- [ ] **Step 1: Add failing cache checks**

Cover:

- Round-trip `~/.agent-halo/usage-snapshots-v1.json` schema version 1.
- JSON contains no synthetic access token, refresh token, Authorization header, account ID, project or session title supplied to the test harness.
- Same Provider with two account keys stays isolated; Codex and Claude keys stay isolated.
- Disk-loaded entries have `isFromCurrentRun == false`.
- A successful store has `isFromCurrentRun == true`.
- `migrate(from:to:)` moves only the exact old key and rewrites the snapshot’s account key.
- More than three accounts per Provider prunes least recently used/refreshed entries.
- Entries older than 30 days are removed.
- Error states are never accepted by the cache API.
- Atomic write uses `0600` for a new cache file.

- [ ] **Step 2: Confirm failure**

```bash
cd src/macos
swift run AgentHaloCoreChecks
```

- [ ] **Step 3: Implement the cache actor and schema**

Use:

```swift
public struct CachedUsageSnapshot: Equatable, Sendable {
    public var snapshot: UsageSnapshot
    public var isFromCurrentRun: Bool
}

public actor UsageSnapshotCache {
    public init(
        cacheURL: URL,
        files: any UsageFileAccessing,
        now: @escaping @Sendable () -> Date = Date.init
    )
    public func loadIfNeeded() throws
    public func snapshot(for key: AccountCacheKey) throws -> CachedUsageSnapshot?
    public func store(_ snapshot: UsageSnapshot) throws
    public func migrate(from oldKey: AccountCacheKey, to newKey: AccountCacheKey) throws
}
```

Disk payload:

```swift
private struct CachePayload: Codable {
    var version: Int
    var entries: [CacheEntry]
}

private struct CacheEntry: Codable {
    var snapshot: UsageSnapshot
    var lastAccessedAt: Date
}
```

Keep current-run membership in memory only. Persist after store, migration or pruning via the atomic file adapter.

- [ ] **Step 4: Run checks and commit**

```bash
cd src/macos
swift run AgentHaloCoreChecks
cd ../..
git status --short
git add src/macos/Sources/AgentHaloCore/UsageMonitoring/UsageSnapshotCache.swift \
        src/macos/Sources/AgentHaloCoreChecks/UsageMonitoringChecks.swift
git commit -m "feat: cache usage snapshots per account"
```

---

### Task 7: 实现 Coordinator 状态机、去重和 429 冷却

**Files:**
- Create: `src/macos/Sources/AgentHaloCore/UsageMonitoring/UsageMonitoringCoordinator.swift`
- Modify: `src/macos/Sources/AgentHaloCoreChecks/UsageMonitoringChecks.swift`

**Interfaces:**
- `prepare` resolves mode and publishes disk/current cache without network.
- `ensureFresh` performs deduplicated refresh only when required.
- `live()` constructs both real Providers and the default cache.

- [ ] **Step 1: Add failing state-machine checks**

Cover:

1. API mode never calls `UsageProvider.refresh` and has `status == nil`.
2. OAuth `prepare` loads the exact account snapshot; disk snapshot is stale and cannot suppress the first request.
3. Current-run snapshot younger than 5 minutes is fresh and suppresses duplicate requests.
4. Snapshot older than 10 minutes becomes stale even without a new error.
5. Two concurrent `ensureFresh(.codex)` calls share one Provider refresh.
6. Codex and Claude refresh independently.
7. Successful refresh stores the snapshot, clears `lastFailure` and reports fresh.
8. Network/5xx/invalid response with a snapshot retains it and reports stale; without one reports noData.
9. `signInAgain` has highest status priority and retains only the same account’s snapshot.
10. 429 stores per-account cooldown; repeated calls before retry time make no request; missing Retry-After uses 5 minutes.
11. Internal rotation migrates the cache before storing; external account change never reads the old key.
12. `cancelAll()` cancels in-flight tasks.

- [ ] **Step 2: Confirm failure**

```bash
cd src/macos
swift run AgentHaloCoreChecks
```

- [ ] **Step 3: Implement state and freshness rules**

Coordinator internal state must be keyed by Provider, while cooldown is keyed by `AccountCacheKey`:

```swift
private var states: [UsageProviderID: UsageMonitorState]
private var inFlight: [UsageProviderID: Task<UsageMonitorState, Never>]
private var cooldownUntil: [AccountCacheKey: Date]
```

`prepare` sequence:

```text
cache.loadIfNeeded()
→ resolveAccess
├── apiKey → clear OAuth snapshot/status/failure and return API mode
├── oauthNeedsSignIn(accountKey) → load only that key, return signInAgain
└── oauth(access) → load only access.accountKey, mark disk cache stale
```

`ensureFresh` calls `prepare`, then:

```text
fresh current-run cache < 5m → return without HTTP
active account cooldown       → return retained state
otherwise                     → join/create one Provider refresh task
```

On errors, map `UsageProviderFailure` one-to-one into `UsageFailureReason`. A successful result clears cooldown and failure, performs any internal key migration, stores the snapshot and returns `.fresh`.

- [ ] **Step 4: Implement the live factory**

Add:

```swift
public static func live(
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
) -> UsageMonitoringCoordinator
```

Construct one `URLSessionUsageHTTPClient`, production system adapters, both AuthStores/Providers, and a cache at `homeDirectory/.agent-halo/usage-snapshots-v1.json`. Do not create a new SwiftPM target or third-party dependency.

- [ ] **Step 5: Run checks and commit**

```bash
cd src/macos
swift run AgentHaloCoreChecks
swift build
cd ../..
git status --short
git add src/macos/Sources/AgentHaloCore/UsageMonitoring/UsageMonitoringCoordinator.swift \
        src/macos/Sources/AgentHaloCoreChecks/UsageMonitoringChecks.swift
git commit -m "feat: coordinate usage refresh state"
```

---

### Task 8: 实现纯展示解析并补齐 Codex 会话标题

**Files:**
- Create: `src/macos/Sources/AgentHaloCore/UsageMonitoring/DetailsContentResolver.swift`
- Modify: `src/macos/Sources/AgentHaloCore/SessionReducer.swift`
- Modify: `src/macos/Sources/AgentHaloCoreChecks/UsageMonitoringChecks.swift`
- Modify: `src/macos/Sources/AgentHaloCoreChecks/main.swift`

**Interfaces:**
- Produces one mutually exclusive `DetailsPanelBody`.
- Produces one localized, redacted Usage warning.
- Keeps project/title and context/usage independent.

- [ ] **Step 1: Add failing resolver and session-title checks**

Cover:

- OAuth returns `.usage` for Codex and Claude, even with no snapshot.
- API mode returns `.session` and preserves project/title as separate fields.
- `providerName` is `Codex` or `Claude Code` in OAuth, API and offline states.
- API mode always has `planName == nil` and `usageWarning == nil`.
- Offline clears context and all four session values, but OAuth retains the same-account Usage snapshot.
- A Usage failure never clears a non-offline exact `contextUsedPercent`.
- Warning priority is signInAgain, rate limited, stale, failed noData; fresh and initial noData/no failure return nil.
- Warning strings contain none of the supplied synthetic token, response body or account digest.
- `session_meta.payload.title` and `session_meta.payload.session_title` populate `SessionSnapshot.sessionTitle`; blank/missing fields leave it nil.

- [ ] **Step 2: Confirm failure**

```bash
cd src/macos
swift run AgentHaloCoreChecks
```

- [ ] **Step 3: Implement display models and resolver**

Define:

```swift
public struct UsageDetailsModel: Equatable, Sendable {
    public var windows: [UsageWindow]
    public var status: UsageDataStatus
}

public enum DetailsPanelBody: Equatable, Sendable {
    case usage(UsageDetailsModel)
    case session(SessionDetailsSnapshot)
}

public struct DetailsPanelViewModel: Equatable, Sendable {
    public var providerName: String
    public var planName: String?
    public var usageWarning: String?
    public var contextUsedPercent: Double?
    public var body: DetailsPanelBody
}
```

`DetailsContentResolver.resolve(...)` accepts Provider ID, monitor state, aggregate offline flag, exact session details, exact context percent and `now`. It must never inspect raw credentials or HTTP responses. Use `L10n.shared` only to convert safe status/failure enums into strings.

- [ ] **Step 4: Update Codex `SessionReducer` without fallback**

Inside the existing `session_meta` branch, after reading `id`, trim `payload.title`; if empty, trim `payload.session_title`; assign the first nonempty value to `snapshot.sessionTitle`. Do not derive a title from `cwd`, project name, first prompt or thread ID.

Update the existing `testSessionReducerCapturesCodexSessionDetailsAndRateLimitAvailability` to assert an explicit title, and add a separate missing-title assertion.

- [ ] **Step 5: Run checks and commit**

```bash
cd src/macos
swift run AgentHaloCoreChecks
cd ../..
git status --short
git add src/macos/Sources/AgentHaloCore/UsageMonitoring/DetailsContentResolver.swift \
        src/macos/Sources/AgentHaloCore/SessionReducer.swift \
        src/macos/Sources/AgentHaloCoreChecks/UsageMonitoringChecks.swift \
        src/macos/Sources/AgentHaloCoreChecks/main.swift
git commit -m "feat: resolve usage detail content"
```

---

### Task 9: 更新中英文文案并锁定窗口名称

**Files:**
- Modify: `src/shared/locales/en.json`
- Modify: `src/shared/locales/zh.json`
- Modify: `src/macos/Sources/AgentHaloCore/locales/en.json`
- Modify: `src/macos/Sources/AgentHaloCore/locales/zh.json`
- Modify: `src/macos/Sources/AgentHaloCoreChecks/UsageMonitoringChecks.swift`

**Interfaces:**
- Supplies exact UI labels and redacted warning templates.
- Shared locale files remain canonical; macOS copies remain byte-for-byte synchronized.

- [ ] **Step 1: Add failing localization checks**

For both languages assert:

```text
en: quota.5h = 5-Hour
en: quota.weekly = Weekly
zh: quota.5h = 五小时
zh: quota.weekly = 每周
```

Also assert `metadata.session_title`, generic `quota.waiting_refresh`, and every Usage warning key resolve to translated text rather than returning the key.

- [ ] **Step 2: Confirm failure**

```bash
cd src/macos
swift run AgentHaloCoreChecks
```

Expected: current strings still contain `Quota` / `额度` and the new keys are missing.

- [ ] **Step 3: Update both locale sources**

Add or update these keys in both shared and bundled copies:

```json
{
  "quota.5h": "5-Hour",
  "quota.weekly": "Weekly",
  "quota.waiting_refresh": "Waiting for Refresh",
  "metadata.session_title": "Session title",
  "usage.warning.sign_in_codex": "Sign in to Codex again to refresh usage.",
  "usage.warning.sign_in_claude": "Sign in to Claude Code again to refresh usage.",
  "usage.warning.rate_limited": "Usage requests are limited. AgentHalo will retry later.",
  "usage.warning.stale": "Usage may be outdated. Last updated {0}.",
  "usage.warning.network": "Usage could not be refreshed because of a network error.",
  "usage.warning.service": "The usage service is temporarily unavailable.",
  "usage.warning.invalid": "The usage service returned unavailable data."
}
```

Chinese values:

```json
{
  "quota.5h": "五小时",
  "quota.weekly": "每周",
  "quota.waiting_refresh": "等待刷新",
  "metadata.session_title": "会话标题",
  "usage.warning.sign_in_codex": "请重新登录 Codex 以刷新使用情况。",
  "usage.warning.sign_in_claude": "请重新登录 Claude Code 以刷新使用情况。",
  "usage.warning.rate_limited": "使用情况请求过于频繁，AgentHalo 将稍后重试。",
  "usage.warning.stale": "使用情况可能已过期，上次更新于 {0}。",
  "usage.warning.network": "网络异常，暂时无法刷新使用情况。",
  "usage.warning.service": "使用情况服务暂时不可用。",
  "usage.warning.invalid": "使用情况服务暂未返回可用数据。"
}
```

- [ ] **Step 4: Verify synchronization and commit**

```bash
cmp src/shared/locales/en.json src/macos/Sources/AgentHaloCore/locales/en.json
cmp src/shared/locales/zh.json src/macos/Sources/AgentHaloCore/locales/zh.json
cd src/macos
swift run AgentHaloCoreChecks
cd ../..
git status --short
git add src/shared/locales/en.json src/shared/locales/zh.json \
        src/macos/Sources/AgentHaloCore/locales/en.json \
        src/macos/Sources/AgentHaloCore/locales/zh.json \
        src/macos/Sources/AgentHaloCoreChecks/UsageMonitoringChecks.swift
git commit -m "feat: localize usage monitoring details"
```

---

### Task 10: 将 DetailsPanel 改为 Provider 行与互斥双主体

**Files:**
- Modify: `src/macos/Sources/AgentHaloMac/DetailsPanel.swift`
- Modify: `src/macos/Sources/AgentHaloMac/HaloInteractionChecks.swift`

**Interfaces:**
- Replaces the old `quota/showsQuota` update signature with `render(aggregate:model:)`.
- Renders Provider/Plan/warning between Agent switcher and Halo status.
- Renders two fixed OAuth rows or four independent API rows.

- [ ] **Step 1: Replace old quota-oriented self-checks with failing new UI checks**

Remove or rewrite checks that assert monthly quota, `showsQuota`, project/title fallback or the old three-row metadata layout. Add checks named:

```swift
testDetailsPanelAlwaysShowsProviderRow()
testDetailsPanelShowsPlanOnlyForOAuth()
testDetailsPanelShowsSingleAmberUsageWarning()
testDetailsPanelShowsFiveHourAndWeeklyRemainingUsage()
testDetailsPanelShowsMissingAndExpiredUsageWindows()
testDetailsPanelShowsFourIndependentSessionRows()
testDetailsPanelDoesNotFallbackSessionTitleToProject()
testDetailsPanelKeepsUsageAndSessionBodiesMutuallyExclusive()
testDetailsPanelKeepsContextIndependentFromUsageFailure()
testDetailsPanelClearsContextAndSessionRowsOffline()
testDetailsPanelKeepsFixedWidthForLongProviderContent()
testDetailsPanelResizesHeightWithoutAnimation()
```

Append them to `runHaloInteractionChecks()` and preserve still-valid context, token-format, localization, capture-sharing and Agent-toggle checks.

- [ ] **Step 2: Confirm self-check failure**

```bash
cd src/macos
swift run AgentHaloMac --self-check
```

Expected: compilation fails because `DetailsPanel.render(aggregate:model:)` and new test accessors do not exist.

- [ ] **Step 3: Add the Provider row**

Create a private `ProviderHeaderView` with:

- Provider field: 12pt semibold, primary label color.
- Plan field: 11pt regular, secondary label color, truncating tail, full value in native Tooltip.
- Warning image: SF Symbol `exclamationmark.triangle.fill`, about 10pt, `.systemYellow`, hidden when warning is nil, native Tooltip plus accessibility label, no click handler.
- One fixed row height shared by OAuth/API/offline layouts.

Insert it immediately after `makeTopRow()` and before `titleField`. Do not add a mode label or section title.

- [ ] **Step 4: Replace `update` with model-based rendering**

Use:

```swift
func render(aggregate: AggregateSnapshot, model: DetailsPanelViewModel) {
    updateStatus(aggregate: aggregate)
    providerHeader.update(
        providerName: model.providerName,
        planName: model.planName,
        warning: model.usageWarning
    )
    updateContext(model.contextUsedPercent, isOffline: aggregate.isOfflineForDetails)

    quotaGroup.isHidden = true
    metadataGroup.isHidden = true
    switch model.body {
    case .usage(let usage):
        renderUsage(usage)
        quotaGroup.isHidden = false
    case .session(let session):
        renderSession(session, isOffline: aggregate.isOfflineForDetails)
        metadataGroup.isHidden = false
    }
    resizeToFitContent()
}
```

The implementation may use a private local offline helper instead of adding a public `AggregateSnapshot` property, but the visible behavior must match the snippet.

- [ ] **Step 5: Render OAuth rows with remaining semantics**

Keep exactly two `QuotaRowView`s:

- `.session` title `L10n["quota.5h"]`.
- `.weekly` title `L10n["quota.weekly"]`.
- `remaining = clamp(100 - usedPercent)` drives both text and meter fill.
- Missing window: `quota.no_data`, hidden reset, empty meter.
- Reset in the past: `quota.waiting_refresh`, hidden reset, empty meter.
- Nil reset: hide reset text, do not show `--`.

Delete monthly-plan branches from the panel; do not delete `RateLimitReader.swift` or its independent Core checks in this task.

- [ ] **Step 6: Render four API rows**

Add `sessionTitleRow` and a third separator. Order:

```text
projectRow
separator
sessionTitleRow
separator
modelRow
separator
tokenRow
```

Set project only from `projectName` and title only from `sessionTitle`. Each missing string displays `--`. `formatTokenAttributedString` already handles one-sided missing values; use it whenever either token count exists. Set native Tooltips on truncated project, title and model values.

- [ ] **Step 7: Preserve width and resize height synchronously**

Keep `panelWidth = 268`. `resizeToFitContent()` must lay out the content, compute the stack fitting height, ceil to the backing scale, update the window frame with `display: false, animate: false`, and preserve the prior top edge so switching bodies does not drift. Hide both groups before revealing one; do not animate alpha or size.

- [ ] **Step 8: Add test accessors and run self-checks**

Expose internal read-only accessors for Provider text, plan text, warning visibility/Tooltip/color, group visibility, four row values, two window titles/values/meter fills and frame width/height. Do not expose AppKit subviews outside the macOS target.

Run:

```bash
cd src/macos
swift run AgentHaloMac --self-check
swift run AgentHaloCoreChecks
swift build
```

- [ ] **Step 9: Commit Task 10**

```bash
cd ../..
git status --short
git add src/macos/Sources/AgentHaloMac/DetailsPanel.swift \
        src/macos/Sources/AgentHaloMac/HaloInteractionChecks.swift
git commit -m "feat: redesign macOS usage details panel"
```

---

### Task 11: 接入 AppDelegate 生命周期与低频刷新

**Files:**
- Modify: `src/macos/Sources/AgentHaloMac/AppDelegate.swift`
- Modify: `src/macos/Sources/AgentHaloMac/HaloInteractionChecks.swift`

**Interfaces:**
- Starts/prepares current Provider at launch.
- Refreshes on open, Agent switch and every 5 minutes.
- Revalidates focus before applying async results.
- Removes new detail path dependency on `RateLimitReader`.

- [ ] **Step 1: Add failing integration self-checks**

Add source/wiring checks proving:

- `AppDelegate` owns `UsageMonitoringCoordinator.live()`.
- A dedicated low-frequency Task exists; no Usage request is wired into `tick()` or the 0.3-second timer.
- `showDetails` renders current state immediately and then requests prepare/refresh.
- Agent selection triggers the target Provider prepare/refresh.
- Async completion compares the requested Provider to the currently focused Provider before redrawing.
- termination cancels loop, wrapper tasks and coordinator work.
- `updateDetailsPanelContent` contains no `rateLimitReader.read()` and calls `DetailsContentResolver` plus `detailsPanel.render`.

- [ ] **Step 2: Confirm integration checks fail**

```bash
cd src/macos
swift run AgentHaloMac --self-check
```

- [ ] **Step 3: Add state and task ownership**

Add:

```swift
private let usageCoordinator = UsageMonitoringCoordinator.live()
private var usageStates: [UsageProviderID: UsageMonitorState] = [:]
private var usageRefreshLoopTask: Task<Void, Never>?
private var usageRequestTasks: [UsageProviderID: Task<Void, Never>] = [:]
private let usageRefreshInterval: TimeInterval = 5 * 60
```

Add a total mapping from `AgentKind.codex/.claudeCode` to `UsageProviderID.codex/.claude`.

- [ ] **Step 4: Implement two-phase prepare/refresh publication**

For a requested Provider:

```text
await coordinator.prepare(provider)
→ store state
→ redraw only if panel visible and focus still matches
await coordinator.ensureFresh(provider)
→ store state
→ redraw only if panel visible and focus still matches
```

Keep one wrapper task per Provider and rely on Coordinator deduplication. Switching focus does not cancel the previous Provider’s safe request; its result remains confined to its Provider state/cache.

- [ ] **Step 5: Replace detail-content assembly**

Retain the existing exact-session logic:

- Codex uses the displayed focused `SessionSnapshot`, including its independent `sessionTitle`.
- Claude uses `ClaudeMainSessionDetailsResolver` and exact Session ID context usage.

Build `DetailsPanelViewModel` through `DetailsContentResolver`, then call:

```swift
detailsPanel.render(aggregate: displayedAggregate, model: model)
```

Delete the AppDelegate-local `DetailsPresentation`, `detailsPresentationForDetails`, `showsQuota`, `quota` and `rateLimitReader` property from the new path. Preserve standalone `RateLimitReader` code/tests until a separate cleanup is requested.

- [ ] **Step 6: Wire lifecycle points**

- Launch: after L10n initialization, start the 5-minute loop and prepare/refresh the current Provider.
- Open details: render current `usageStates` plus local session data synchronously, then start two-phase refresh.
- Agent switch: clear old context/session-derived presentation immediately, render target state, then prepare/refresh target Provider.
- Language change: redraw visible details so Provider warning and window labels update.
- Termination: cancel loop and wrapper tasks; `Task { await usageCoordinator.cancelAll() }` before teardown.

- [ ] **Step 7: Run all Swift checks and commit**

```bash
cd src/macos
swift run AgentHaloCoreChecks
swift run AgentHaloMac --self-check
swift build
cd ../..
git status --short
git add src/macos/Sources/AgentHaloMac/AppDelegate.swift \
        src/macos/Sources/AgentHaloMac/HaloInteractionChecks.swift
git commit -m "feat: integrate macOS usage monitoring"
```

---

### Task 12: 完整回归、隐私审计与打包验证

**Files:**
- Modify only if a verification failure identifies a concrete defect in files already listed by this plan.

**Interfaces:**
- Verifies product-spec coverage and the packaged `.app`, not only SwiftPM output.

- [ ] **Step 1: Run targeted privacy and scope scans**

```bash
rg -n "Spark|Spark Weekly|Sonnet|Fable|Extra Usage|Rate Limit Resets|reset-credit|credits" \
  src/macos/Sources/AgentHaloCore/UsageMonitoring \
  src/macos/Sources/AgentHaloMac

rg -n "response\.body|Authorization|accessToken|refreshToken|apiKey" \
  src/macos/Sources/AgentHaloCore/UsageMonitoring

rg -n "rateLimitReader\.read|showsQuota|DetailsPresentation" \
  src/macos/Sources/AgentHaloMac/AppDelegate.swift \
  src/macos/Sources/AgentHaloMac/DetailsPanel.swift
```

Expected:

- First scan has no runtime implementation hit for excluded features.
- Second scan only finds request construction/parsing and token-bearing in-memory fields, never log interpolation or cache coding.
- Third scan has no hit.

- [ ] **Step 2: Run complete source checks**

```bash
cd src/macos
swift run AgentHaloCoreChecks
swift run AgentHaloMac --self-check
swift build
```

Expected: Core ends with `PASS AgentHaloCore checks`; Mac self-check exits 0; build exits 0.

- [ ] **Step 3: Run repository consistency checks**

```bash
cd ../..
cmp src/shared/locales/en.json src/macos/Sources/AgentHaloCore/locales/en.json
cmp src/shared/locales/zh.json src/macos/Sources/AgentHaloCore/locales/zh.json
git diff --check
git status --short
```

Review the exact diff against both:

- `docs/openusage-balance-monitoring-product-spec.md`
- `docs/superpowers/specs/2026-07-10-openusage-monitoring-macos-design.md`

Confirm every acceptance row has a Core check or Mac self-check and no Windows file appears in the diff.

- [ ] **Step 4: Build and verify the packaged app**

```bash
bash scripts/build-macos.sh
bash scripts/run-macos.sh --verify
```

Expected: `outputs/AgentHalo-macOS/AgentHalo.app` is rebuilt and verification exits 0. Inspect the packaged bundle timestamp and embedded locale JSON rather than relying on `.build` artifacts.

- [ ] **Step 5: Manual macOS smoke matrix**

Using synthetic/test accounts where possible, check:

| Provider | Mode/state | Expected panel |
| --- | --- | --- |
| Codex | OAuth fresh | Provider + mapped plan + 5-Hour/Weekly, no triangle |
| Codex | OAuth stale/429 | Same account snapshot + one amber triangle/Tooltip |
| Codex | API key | Provider + four session rows, no plan/window/triangle |
| Claude Code | OAuth fresh | Provider + plan + 5-Hour/Weekly |
| Claude Code | missing profile scope | OAuth body + sign-in triangle, no API fallback |
| Claude Code | inference-only env token | API body, no plan/window/triangle |
| Either | offline | Provider retained, context hidden; API rows `--`; OAuth snapshot retained |
| Either | switch during request | Current Provider never overwritten by old result |

- [ ] **Step 6: Final focused commit only if verification required fixes**

If and only if Steps 1–5 required code changes:

```bash
git status --short
git add src/macos/Sources/AgentHaloCore/UsageMonitoring \
        src/macos/Sources/AgentHaloCore/SessionReducer.swift \
        src/macos/Sources/AgentHaloCoreChecks \
        src/macos/Sources/AgentHaloMac/AppDelegate.swift \
        src/macos/Sources/AgentHaloMac/DetailsPanel.swift \
        src/macos/Sources/AgentHaloMac/HaloInteractionChecks.swift \
        src/shared/locales/en.json src/shared/locales/zh.json \
        src/macos/Sources/AgentHaloCore/locales/en.json \
        src/macos/Sources/AgentHaloCore/locales/zh.json
git commit -m "fix: complete macOS usage monitoring verification"
```

If no code changes were required, do not create an empty commit.

---

## Completion Checklist

- [ ] OAuth/API 密钥两种模式在 Codex 与 Claude Code 上均通过。
- [ ] Provider 行始终存在；计划和黄色三角形只在 OAuth 条件满足时出现。
- [ ] 计划名称与 OpenUsage 当前映射一致。
- [ ] 5-Hour/Weekly 文案、剩余百分比、重置时间与进度条语义正确。
- [ ] Project、Session title、Model、Input/output tokens 为四行独立字段。
- [ ] `contextPill` 在两种模式下均可显示，且不会跨会话或被 Usage 失败清除。
- [ ] Token 自动刷新、同源重读、一次 401 重试、未知字段和权限保留均有回归检查。
- [ ] 快照按 Provider+账户隔离，内部轮换可迁移，外部重新登录不迁移。
- [ ] 429 冷却、fresh/stale/noData/signInAgain 优先级均有回归检查。
- [ ] 缓存、日志和 Tooltip 不包含敏感数据或响应正文。
- [ ] 新详情路径不依赖 `RateLimitReader`。
- [ ] `AgentHaloCoreChecks`、Mac self-check、Swift build、`git diff --check`、打包和 `--verify` 全部通过。
