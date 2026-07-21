# OpenUsage：Claude 与 Codex 余额监控机制调研

> 调研项目：[OpenUsage](https://github.com/openusage/openusage) — 一个 macOS 菜单栏 SwiftUI 应用，监控多个 AI 提供商的用量与余额。
> 代码版本：`main` 分支，Swift 6 + SwiftPM。

---

## 目录

1. [整体架构](#整体架构)
2. [Claude 余额监控](#claude-余额监控)
3. [Codex 余额监控](#codex-余额监控)
4. [Codex Plus vs Pro 订阅等级判断](#codex-plus-vs-pro-订阅等级判断)
5. [定价与花费估算](#定价与花费估算)

---

## 整体架构

每个 Provider 遵循 `ProviderRuntime` 协议，由三部分组成：

| 组件 | 职责 |
|------|------|
| **AuthStore** | 从本地读取凭证（Keychain / 文件 / 环境变量） |
| **UsageClient** | 调用 Provider API 拉取实时用量 |
| **UsageMapper** | 将 API 响应标准化为 `MetricLine` 供 UI 渲染 |

刷新流程：`refresh()` → 加载凭证 → 调用 API → 映射为标准指标行 → 扫描本地日志追加 spend tiles → 输出 `ProviderSnapshot`。

### ProviderRuntime 协议

**文件：** `Sources/OpenUsage/Providers/ProviderRuntime.swift`

```swift
@MainActor
protocol ProviderRuntime: AnyObject {
    var provider: Provider { get }
    var widgetDescriptors: [WidgetDescriptor] { get }
    func refresh() async -> ProviderSnapshot
    func hasLocalCredentials() async -> Bool
}
```

协议本身**不规定认证方式**——每个 provider 自由实现。另有一个子协议 `APIKeyManaging` 给需要用户手动输入 API key 的 provider：

**文件：** `Sources/OpenUsage/Providers/APIKeyManagement.swift`
```swift
protocol APIKeyManaging: ProviderRuntime {
    var apiKeyStatus: APIKeyStatus { get }
    func currentAPIKey() -> String?
    func saveAPIKey(_ key: String) throws
    func deleteAPIKey() throws
    var apiKeyStorageDescription: String { get }
    var apiKeyEnvironmentName: String { get }
}
```

`APIKeyManaging` 目前仅被 **OpenRouter**（以及可能的 Z.ai）使用。Claude 和 Codex **不使用此协议**——它们走「从 CLI 工具自动发现 OAuth 凭据」的路径。

---

## 订阅模式 vs API Key 模式的认证处理

Claude Code 和 Codex 都支持两种使用方式：通过官网订阅账号登录（OAuth），或使用第三方 API key（如通过自定义 endpoint 接入）。两种模式下的凭证来源、用量获取能力和面板显示有本质区别。

### Claude 的凭证来源与可用性判断

**文件：** `Sources/OpenUsage/Providers/Claude/ClaudeAuthStore.swift`

Claude 的 AuthStore 定义了 `LiveUsageAvailability` 枚举来区分三种认证状态：

```swift
enum LiveUsageAvailability {
    case available               // 有 user:profile scope — 可读实时订阅用量
    case inferenceOnlyToken      // 仅有 CLAUDE_CODE_OAUTH_TOKEN — 纯 API key，无实时用量
    case missingProfileScope     // 有登录态但缺少 user:profile scope（如 setup-token 写入的 token）
}
```

判断逻辑通过 `liveUsageAvailability(_:)` 方法：

```swift
func liveUsageAvailability(_ state: ClaudeCredentialState) -> LiveUsageAvailability {
    if state.inferenceOnly { return .inferenceOnlyToken }
    guard let scopes = state.oauth.scopes, !scopes.isEmpty else { return .available }
    return scopes.contains("user:profile") ? .available : .missingProfileScope
}
```

API key 的检测依据：
- `CLAUDE_CODE_OAUTH_TOKEN` 环境变量被标记为 `inferenceOnly: true`
- 该 token 只能用于推理（调用模型），不具备 `user:profile` scope，因此**无法调用用量 API**

凭证加载优先级（取第一个可用、scope 最完整的）：
1. macOS Keychain → OAuth 登录态，通常有完整 scope
2. `~/.claude/.credentials.json` → 文件回退，同上
3. `CLAUDE_CODE_OAUTH_TOKEN` → API key 模式，inference-only

### Codex 的凭证来源与可用性判断

**文件：** `Sources/OpenUsage/Providers/Codex/CodexAuthStore.swift`

Codex 的 `CodexAuth` 结构同时容纳 OAuth token 和 API key：

```swift
struct CodexAuth: Codable, Hashable, Sendable {
    var tokens: CodexTokens?      // accessToken, refreshToken, idToken, accountID
    var lastRefresh: String?
    var apiKey: String?           // OPENAI_API_KEY（可推理但无法读用量）
}
```

`hasTokenLikeAuth()` 同时检查两种凭据：

```swift
static func hasTokenLikeAuth(_ auth: CodexAuth) -> Bool {
    if auth.tokens?.accessToken?.isEmpty == false { return true }
    if auth.apiKey?.isEmpty == false { return true }
    return false
}
```

但在 `CodexProvider.probe()` 中，API key 被**硬拒绝**：

```swift
guard var accessToken = authState.auth.tokens?.accessToken, !accessToken.isEmpty else {
    if authState.auth.apiKey?.isEmpty == false {
        throw CodexAuthError.usageAPIKey   // "Usage not available for API key."
    }
    throw CodexAuthError.notLoggedIn
}
```

`usageAPIKey` 错误设置了 `allowsAuthFallback: false`，意味着 refresh 立刻失败，不会尝试其他来源。

### 两种模式的面板显示对比

#### Claude：优雅降级

| 面板区域 | 订阅模式（OAuth 登录） | API Key 模式（`CLAUDE_CODE_OAUTH_TOKEN`） |
|----------|----------------------|------------------------------------------|
| **Session (5h) 进度条** | ✅ 实时百分比 + 用量数 | ❌ 显示 "No data" |
| **Weekly (7d) 进度条** | ✅ 实时百分比 + 用量数 | ❌ 显示 "No data" |
| **Sonnet 进度条** | ✅ 实时百分比 + 用量数 | ❌ 显示 "No data" |
| **Fable 进度条** | ✅ 实时百分比 + 用量数 | ❌ 显示 "No data" |
| **Extra Usage** | ✅ 美元金额（超额用量） | ❌ 显示 "No data" |
| **Plan 标签** | ✅ 如 "Max 4x" | ❌ 不显示 |
| **Today / Yesterday / Last 30 Days 花费** | ✅ 本地日志扫描 | ✅ 本地日志扫描（不受影响） |
| **Usage Trend 趋势** | ✅ 趋势指标 | ✅ 趋势指标（不受影响） |
| **错误状态** | 无 | **无**（静默降级，不显示错误） |

**API Key 模式下的完整行为：**
1. 跳过 `GET api.anthropic.com/api/oauth/usage` 调用（API key 无 `user:profile` scope）
2. **不显示任何错误**——不打扰用户
3. Spend 卡片正常加载（从 `~/.claude/projects/**/*.jsonl` 扫描本地日志）
4. 实时限额相关的进度条区域显示 "No data"
5. 用户感知：菜单栏能看到 Claude 的今日花费，但看不到 Session/Weekly 限额

**缺失 scope 模式下的行为：**
- 显示琥珀色警告 "Re-login for live usage"
- Spend 卡片不受影响
- 引导用户重新登录以获取完整 scope 的 token

#### Codex：硬错误

| 面板区域 | 订阅模式（OAuth 登录） | API Key 模式（`OPENAI_API_KEY`） |
|----------|----------------------|--------------------------------|
| **Session (5h) 进度条** | ✅ 实时百分比 | ❌ 整个 Provider 报错，不渲染 |
| **Weekly (7d) 进度条** | ✅ 实时百分比 | ❌ 同上 |
| **Spark 进度条** | ✅ 实时百分比 | ❌ 同上 |
| **Spark Weekly 进度条** | ✅ 实时百分比 | ❌ 同上 |
| **Rate Limit Resets** | ✅ 数量 + 到期时间 | ❌ 同上 |
| **Extra Usage (Credits)** | ✅ 美元 + 积分 | ❌ 同上 |
| **Plan 标签** | ✅ 如 "Pro 20x" | ❌ 同上 |
| **Today / Yesterday / Last 30 Days 花费** | ✅ 本地日志扫描 | ❌ **无法到达**——错误在 log 扫描之前就抛出了 |
| **错误状态** | 无 | ⚠️ **可见错误行**："Usage not available for API key." |

**API Key 模式下的完整行为：**
1. `probe()` 中检测到仅有 API key 无 OAuth token，直接抛 `CodexAuthError.usageAPIKey`
2. 错误设置了 `allowsAuthFallback: false`，refresh 立刻终止
3. 本地日志扫描代码（`CodexLogUsageScanner`）**永远不会被执行**
4. 用户看到可见的错误行，提示需要登录 ChatGPT 账号

### 两种处理方式的差异分析

| 维度 | Claude | Codex |
|------|--------|-------|
| **API Key 检测时机** | AuthStore 加载时，通过 `inferenceOnly` 标记 | Provider.probe() 中，检查 OAuth accessToken 是否为空 |
| **API Key 用户是否看到错误** | ❌ 静默处理，不报错 | ✅ 显示硬错误 |
| **本地 Spend 卡片在 API Key 下可用吗** | ✅ 可用 | ❌ 不可用（代码路径被阻断） |
| **设计理念** | 部分数据优于零数据——能展示什么就展示什么 | 全有或全无——没有订阅就无法使用该 Provider |
| **用户体验** | 损失实时限额但保留花费估算，无干扰 | 明确告知无法使用，引导用户登录 |

### 订阅/API Key 模式判断流程图

```
CLAUDE_CODE_OAUTH_TOKEN 存在？
├── 否 → 检查 Keychain / .credentials.json
│   ├── 有 OAuth token 且 scopes 含 "user:profile"？ → .available（订阅模式，完整功能）
│   ├── 有 OAuth token 但 scopes 不含 "user:profile"？ → .missingProfileScope（警告 + 无实时用量）
│   └── 无任何凭证 → 无 Provider
└── 是 → 同时有 OAuth 登录态？
    ├── 是 → OAuth 登录态优先用于实时用量，env token 做兜底（fallback）
    └── 否 → .inferenceOnlyToken（API Key 模式，仅本地 Spend 卡片）

Codex auth.json 中有 OAuth accessToken？
├── 是 → 订阅模式（完整功能）
└── 否 → 有 apiKey 字段？
    ├── 是 → 抛 CodexAuthError.usageAPIKey（硬错误，整个 Provider 不可用）
    └── 否 → 无 Provider
```

---

## Claude 余额监控

### 1. 凭证来源

**文件：** `/Users/wjs/work/openusage/Sources/OpenUsage/Providers/Claude/ClaudeAuthStore.swift`

按优先级从三个来源加载 OAuth 凭证（keychain 优先）：

| 优先级 | 来源 | 说明 |
|--------|------|------|
| 1 | macOS Keychain | Claude Code 在 macOS 上的主要存储（`Claude Code-credentials` 服务） |
| 2 | `~/.claude/.credentials.json` | 文件回退（旧版/Linux 风格），路径可通过 `CLAUDE_CONFIG_DIR` 覆盖 |
| 3 | `CLAUDE_CODE_OAUTH_TOKEN` 环境变量 | 推理专用 token（如 `claude setup-token`），**无法读取用量 API**（详见[订阅模式 vs API Key 模式](#订阅模式-vs-api-key-模式的认证处理)） |

关键数据结构 `ClaudeOAuth`（第 4-11 行）：
```swift
struct ClaudeOAuth: Codable, Hashable, Sendable {
    var accessToken: String?
    var refreshToken: String?
    var expiresAt: Double?
    var subscriptionType: String?   // 订阅类型
    var rateLimitTier: String?      // 速率限制等级
    var scopes: [String]?           // OAuth 权限范围
}
```

**自动 Token 刷新**：当 `expiresAt` 距当前时间 ≤ 5 分钟时，使用 `refreshToken` 调用 OAuth refresh endpoint。刷新后写回原存储位置。

**凭证回退机制**：若首选凭证因 token 过期/吊销失败（`allowsAuthFallback`），自动尝试下一个来源，无需重启应用。

### 2. 实时用量 API 调用

**文件：** `/Users/wjs/work/openusage/Sources/OpenUsage/Providers/Claude/ClaudeUsageClient.swift`

| 端点 | 用途 |
|------|------|
| `GET https://api.anthropic.com/api/oauth/usage` | 获取用量窗口数据 |
| `POST https://platform.claude.com/v1/oauth/token` | 刷新 OAuth token |

请求头包含：
- `Authorization: Bearer <access_token>`
- `anthropic-beta: oauth-2025-04-20`
- `User-Agent: claude-code/2.1.69`

请求所需 OAuth scope（第 33 行）：
```
user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload
```

**速率限制处理**：收到 429 时，解析 `Retry-After` 头，进入 5 分钟冷却期。冷却期内返回上次成功数据 + "数据可能过期"标记，不会空白 Dashboard。

### 3. 解析的余额数据

**文件：** `/Users/wjs/work/openusage/Sources/OpenUsage/Providers/Claude/ClaudeUsageMapper.swift`

从 API 响应 JSON 中提取以下指标：

| 指标 | JSON 路径 | 展示形式 |
|------|-----------|----------|
| **Session** | `five_hour.utilization` | 百分比进度条（5 小时滚动窗口） |
| **Weekly** | `seven_day.utilization` | 百分比进度条（7 天窗口） |
| **Sonnet** | `seven_day_sonnet.utilization` | 百分比进度条（Sonnet 专属周限额） |
| **Fable** | `limits[]` 中 `kind=weekly_scoped` 且 `scope.model.display_name=Fable` | 百分比进度条（Fable 专属周限额） |
| **Extra Usage** | `extra_usage.used_credits` vs `monthly_limit` | 美元金额（cents → dollars 转换） |
| **Plan** | `credentials.subscriptionType` + `rateLimitTier` | 文本标签（如 "Max 4x"） |

Plan 格式化逻辑（`formatPlan` 方法，第 94-108 行）：
- 取 `subscriptionType` 做 title-case
- 若 `rateLimitTier` 匹配 `\d+x` 正则，追加到 plan 名称后
- 例如：`subscriptionType="max"` + `rateLimitTier="4x"` → `"Max 4x"`

### 4. 本地花费估算（Spend Tiles）

**文件：** `/Users/wjs/work/openusage/Sources/OpenUsage/Providers/Claude/ClaudeLogUsageScanner.swift`

扫描 Claude Code 的本地 session 日志来估算 **Today / Yesterday / Last 30 Days** 花费：

**扫描路径：**
- `~/.claude/projects/**/*.jsonl`（或 `$CLAUDE_CONFIG_DIR`）
- Cowork 桌面应用的 agent 会话：`~/Library/Application Support/Claude/local-agent-mode-sessions/*/local_*/.claude/projects/**/*.jsonl`

**解析逻辑：**
1. 扫描包含 `"usage":{` 标记的 JSONL 行
2. 提取 `input_tokens`、`output_tokens`、`cache_read_input_tokens`、`cache_creation`（含 5m/1h 拆分）
3. 通过 `(message.id, requestId)` 去重（处理 sidechain 日志的场景）
4. 按本地时区聚合到天
5. 费用计算：
   - 若行携带 `costUSD` 字段 → 直接使用
   - 否则 → 通过 `ModelPricing` 按 token 数量和模型定价估算

**有效性校验：**
- `version` 必须是 semver 格式（过滤非 Claude 日志）
- 关键字段不能为 `null`
- `speed` 只能是 `"fast"` 或 `"standard"`

---

## Codex 余额监控

### 1. 凭证来源

**文件：** `/Users/wjs/work/openusage/Sources/OpenUsage/Providers/Codex/CodexAuthStore.swift`

| 优先级 | 来源 | 说明 |
|--------|------|------|
| 1 | `$CODEX_HOME/auth.json` | Codex CLI 的认证文件，默认 `~/.config/codex/auth.json` 或 `~/.codex/auth.json` |
| 2 | macOS Keychain | `Codex Auth` 服务 |

关键数据结构 `CodexAuth`（第 17-27 行）：
```swift
struct CodexAuth: Codable, Hashable, Sendable {
    var tokens: CodexTokens?      // accessToken, refreshToken, idToken, accountID
    var lastRefresh: String?      // 上次刷新时间
    var apiKey: String?           // OPENAI_API_KEY（用于推理但无法读用量，详见[订阅模式 vs API Key 模式](#订阅模式-vs-api-key-模式的认证处理)）
}
```

**Token 刷新策略**（`needsRefresh` 方法）：
- 优先从 access token 的 JWT `exp` 声明判断（5 分钟窗口内刷新）
- 回退：距 `lastRefresh` 超过 8 天时刷新
- 避免 `refresh_token_reused` 错误

**刷新前重读凭证**：在刷新前会重新读取磁盘上的凭证，以防外部 `codex` CLI 已轮换 token。

### 2. 实时用量 API 调用

**文件：** `/Users/wjs/work/openusage/Sources/OpenUsage/Providers/Codex/CodexUsageClient.swift`

| 端点 | 用途 |
|------|------|
| `GET https://chatgpt.com/backend-api/wham/usage` | 获取用量窗口数据 |
| `POST https://auth.openai.com/oauth/token` | 刷新 OAuth token |
| `GET https://chatgpt.com/backend-api/wham/rate-limit-reset-credits` | 获取重置积分的到期时间（best-effort） |

请求头包含：
- `Authorization: Bearer <access_token>`
- `ChatGPT-Account-Id: <account_id>`（当可用时）
- `OpenAI-Beta: codex-1`（reset-credits 端点专用）
- `originator: Codex Desktop`（reset-credits 端点专用）

### 3. 解析的余额数据

**文件：** `/Users/wjs/work/openusage/Sources/OpenUsage/Providers/Codex/CodexUsageMapper.swift`

从 API 响应 JSON 中提取：

| 指标 | JSON 路径 | 展示形式 |
|------|-----------|----------|
| **Session** | `rate_limit.primary_window.used_percent` | 百分比进度条（5 小时窗口） |
| **Weekly** | `rate_limit.secondary_window.used_percent` | 百分比进度条（7 天窗口） |
| **Spark** | `additional_rate_limits[]` 中 `limit_name`/`metered_feature` 包含 "spark" | 百分比进度条（模型专属 5 小时窗口） |
| **Spark Weekly** | 同上条目的 `secondary_window` | 百分比进度条（模型专属 7 天窗口） |
| **Rate Limit Resets** | `rate_limit_reset_credits.available_count` + 专用 API 的 `credits[].expires_at` | 数量 + 到期倒计时 tooltip |
| **Extra Usage (Credits)** | `credits.balance` 或 `x-codex-credits-balance` 响应头 | 美元 + 积分（如 `$31.84 · 796 credits`） |
| **Plan** | `plan_type` 字段 | 文本标签（见下节） |

**Credits 计算**：`credits.balance` 向下取整，每个 credit = $0.04（`creditUSDRate = 0.04`）。

**Session/Weekly 回退**：若 body 中没有窗口数据，会尝试从响应头 `x-codex-primary-used-percent` / `x-codex-secondary-used-percent` 读取。

### 4. 本地花费估算（Spend Tiles）

**文件：** `/Users/wjs/work/openusage/Sources/OpenUsage/Providers/Codex/CodexLogUsageScanner.swift`

扫描 Codex CLI 的 session rollout 日志来估算 **Today / Yesterday / Last 30 Days** 花费：

**扫描路径：**
- `$CODEX_HOME/sessions/**/*.jsonl`（支持逗号分隔的多个 home）
- `$CODEX_HOME/archived_sessions/**/*.jsonl`
- 默认 `~/.codex/sessions/` + `~/.codex/archived_sessions/`
- 当 `sessions/` 和 `archived_sessions/` 中有相同相对路径时，`sessions/` 版本优先

**解析逻辑：**
1. 逐行解析 JSONL，识别 `turn_context`（更新当前模型）和 `token_count`（实际用量）
2. Token 计算：
   - 优先使用 `last_token_usage`
   - 回退到 `total_token_usage` 的增量（delta）
3. **子代理重放检测**：通过 `thread_spawn` 标记和同一秒内的重复 `token_count` 行来跳过重放的计数
4. 模型解析：支持多种字段名（`model`、`model_name`、`metadata.model`），回退模型为 `gpt-5`
5. 退役的 `codex-auto-review` 按时间线映射到对应 codex 模型
6. 按天去重聚合，相同 `(timestamp, model, tokens)` 的事件只计一次

**Fast Tier 检测**（`usesFastServiceTier`，第 113-130 行）：
- 读取每个 Codex home 下的 `config.toml`
- 查找 `service_tier = "fast"` 或 `"priority"` 配置
- 若启用 → 花费 × fast multiplier（默认 2x）

**费用公式**（`cost` 方法，第 398-404 行）：
```
cost = ((input - cached) × input_rate + cached × cache_read_rate + output × output_rate) / 1,000,000 × fast_multiplier
```

---

## Codex Plus vs Pro 订阅等级判断

### 核心逻辑

**文件：** `/Users/wjs/work/openusage/Sources/OpenUsage/Providers/Codex/CodexUsageMapper.swift`
**方法：** `formatCodexPlan`（第 266-279 行）

```swift
static func formatCodexPlan(_ value: Any?) -> String? {
    guard let raw = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !raw.isEmpty
    else {
        return nil
    }
    switch raw.lowercased() {
    case "prolite":
        return "Pro 5x"
    case "pro":
        return "Pro 20x"
    default:
        return raw.titleCased(separator: { $0 == "_" })
    }
}
```

### 判断依据

`plan_type` 的值直接来自 **Codex 用量 API 的响应 body**（`CodexUsageMapper.mapUsageResponse` 第 79 行）：

```swift
return CodexMappedUsage(plan: formatCodexPlan(body["plan_type"]), lines: lines)
```

API 端点：`GET https://chatgpt.com/backend-api/wham/usage`

### 映射关系

| API 返回的 `plan_type` | OpenUsage 显示 | 实际含义 |
|------------------------|---------------|---------|
| `"prolite"` | **Pro 5x** | Codex **Plus** 订阅（5 倍速率限制） |
| `"pro"` | **Pro 20x** | Codex **Pro** 订阅（20 倍速率限制） |
| 其他任意值 | title-case 格式化 | 未知/未来订阅类型 |

### 关键点

1. **完全是服务端判断**：OpenUsage 不做任何本地推断，直接从 Codex API 的 `plan_type` 字段读取
2. **大小写不敏感**：匹配前做了 `lowercased()` 处理
3. **"Pro 5x" 和 "Pro 20x" 是显示名称**，内部不做 plus/pro 的布尔分类，而是直接展示给用户
4. `rateLimitTier`（速率限制倍数）已隐含在 plan 名称中（5x = Plus，20x = Pro）

### 对比：Claude 的 Plan 判断

Claude 的 plan 判断方式不同（`ClaudeUsageMapper.formatPlan`）：

- 从 **OAuth 凭证**（而非 API 响应）中读取 `subscriptionType` 和 `rateLimitTier`
- 例如 `subscriptionType="max"` + `rateLimitTier="4x"` → 显示 `"Max 4x"`
- 这两个值来自本地存储的 `ClaudeOAuth` 对象，在登录时由 Claude 的 OAuth 流程写入

---

## 定价与花费估算

### 定价数据源

**文件：** `/Users/wjs/work/openusage/Sources/OpenUsage/Pricing/ModelPricing.swift`

三层定价源，上层优先：

| 优先级 | 数据源 | 说明 |
|--------|--------|------|
| 1 | OpenUsage 定价补充 (`pricing_supplement.json`) | Cursor 原生模型、fast 倍数、别名规则 |
| 2 | LiteLLM (`model_prices_and_context_window.json`) | 社区维护的主流模型定价 |
| 3 | models.dev (`api.json`) | LiteLLM 缺失模型的补充 |

定价每日自动刷新（ETag 条件请求），缓存于 `~/Library/Application Support/OpenUsage/pricing/`。

### 模型名解析流程

1. 补充别名规则重写 slug
2. 精确匹配
3. `-fast` 后缀处理（解析 base 模型 + fast multiplier）
4. LiteLLM 模糊匹配（provider 前缀、日期后缀、分隔符差异）
5. models.dev 精确匹配（仅补充，不做模糊匹配）

### 无法定价模型

完全排除在花费数据之外，并在对应 tile 上显示黄色警告三角，列出无法定价的模型名。

---

## 总结

| 维度 | Claude | Codex |
|------|--------|-------|
| **API 端点** | `api.anthropic.com/api/oauth/usage` | `chatgpt.com/backend-api/wham/usage` |
| **凭证存储** | Keychain + `~/.claude/.credentials.json` + env | `$CODEX_HOME/auth.json` + Keychain |
| **限额指标** | Session(5h) / Weekly(7d) / Sonnet / Fable / Extra Usage | Session(5h) / Weekly(7d) / Spark / Spark Weekly / Credits / Rate Limit Resets |
| **Plan 来源** | OAuth 凭证中的 `subscriptionType` + `rateLimitTier` | API 响应 body 的 `plan_type` |
| **Plus/Pro 区分** | 不直接区分 Plus/Pro；显示 plan 名 + 速率倍数 | `prolite` → "Pro 5x"(Plus)；`pro` → "Pro 20x"(Pro) |
| **本地日志扫描** | `~/.claude/projects/**/*.jsonl` | `$CODEX_HOME/sessions/**/*.jsonl` |
| **花费模式** | costUSD 优先，token 估算回退 | 纯 token 估算（× pricing rate × fast multiplier） |
| **Token 刷新** | OAuth refresh token（5 分钟窗口） | OAuth refresh token（JWT exp 或 8 天回退） |
| **API Key 检测** | `CLAUDE_CODE_OAUTH_TOKEN` env → `inferenceOnly: true` | `auth.json` 中有 `apiKey` 字段但无 OAuth accessToken |
| **API Key 模式行为** | 优雅降级：跳过实时用量，仍展示本地 Spend 卡片 | 硬错误：抛 `usageAPIKey` 阻断整个 refresh（连本地日志都不扫描） |
| **API Key 面板显示** | 实时限额区域显示 "No data"，Spend 卡片正常工作 | 整个 Provider 报错，显示 "Usage not available for API key." |
| **Scope 不足行为** | 琥珀色警告 "Re-login for live usage" + Spend 卡片正常 | N/A（API key 直接阻断，不走 scope 检查） |
| **设计理念** | 部分数据优于零数据 | 全有或全无 |
