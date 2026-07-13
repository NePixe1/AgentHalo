# OpenUsage 风格监控：共享架构与 macOS 详细设计

## 文档状态

- 日期：2026-07-10
- 状态：设计已确认，等待用户审阅文档
- 实现范围：AgentHalo macOS
- 产品规格：[OpenUsage 风格余额监控产品规格书](../../openusage-balance-monitoring-product-spec.md)
- 参考实现：`/Users/wjs/work/openusage/Sources/OpenUsage/Providers/Codex`、`/Users/wjs/work/openusage/Sources/OpenUsage/Providers/Claude`、`/Users/wjs/work/openusage/Sources/OpenUsage/Stores/ProviderSnapshotCache.swift`

## 目标

在不引入 OpenUsage 通用 Widget 系统的前提下，为 AgentHalo macOS 建立轻量的 Provider 监控管线：

- OAuth 模式显示计划、Session/Weekly 使用窗口和数据状态。
- API 密钥模式显示项目、会话标题、模型和输入/输出 Token。
- 两种模式均可显示当前准确会话的上下文百分比 `contextPill`。
- OAuth Token 可以自动刷新并安全写回原始凭据来源。
- 最后成功快照按 Provider 和账户隔离，失败时采用 stale-while-revalidate。
- 使用情况请求、错误和缓存状态不得改变 Halo 会话状态。

## 非目标

- Windows 实现或跨平台运行时代码。
- 货币余额、Credits、Extra Usage、Rate Limit Reset Credits。
- Spark、Spark Weekly、Sonnet、Fable 等扩展窗口。
- 本地消费估算、历史图表、通知和通用 Widget 注册系统。
- 读取运行中 Codex/Claude Code 进程的完整环境。
- 精确识别每个会话进程实际使用的凭据；本期与 OpenUsage 一致，按当前 Agent 的有效凭据集合和可识别配置判断。

## 已确认的架构决策

1. 只实现 macOS，但 Codex 与 Claude Code 共用同一套领域模型和 Coordinator。
2. 新能力放入现有 `AgentHaloCore`，不新增 SwiftPM Target。
3. 采用 `AuthStore → UsageClient → UsageMapper → UsageProvider → UsageSnapshotCache` 分层。
4. `AppDelegate` 只负责 macOS 生命周期编排，`DetailsPanel` 只负责渲染。
5. 同时存在 OAuth 和 API Key 时，OAuth 优先。
6. OAuth Token 临近过期时自动刷新，并写回原始文件或 Keychain 来源。
7. 只后台刷新当前焦点 Provider；默认刷新周期为 5 分钟。
8. 快照按 Provider 和账户隔离，不照搬 OpenUsage 仅按 Provider ID 缓存的做法。
9. `contextPill` 与接入模式相互独立；计划名称在 OAuth 主体中作为独立行显示。
10. OAuth Usage API 失败不回退到本地 `RateLimitReader` 配额，避免账户和数据来源错配。

## 现有架构与改造点

当前 macOS 详情链路为：

```text
AppDelegate.updateDetailsPanelContent
  ├── RateLimitReader.read              // Codex 本地 JSONL 配额
  ├── ClaudeContextUsageReader.read     // Claude 当前会话上下文
  ├── detailsPresentationForDetails
  └── DetailsPanel.update
```

当前问题：

- `AppDelegate` 同时选择数据源、判断显示模式并驱动 AppKit。
- `RateLimitSnapshot` 面向 Codex 本地日志形状，无法表达 Provider、账户、计划、数据状态和缓存身份。
- Codex/Claude 没有统一的认证、HTTP、映射、缓存和刷新边界。
- `DetailsPanel` 通过 `showsQuota` 布尔值切换主体，项目与会话标题仍被合并显示。

改造后：

```text
AppDelegate
  ├── 本地会话数据（现有 Session/Claude readers）
  ├── UsageMonitoringCoordinator
  │   ├── AccessModeResolver
  │   ├── CodexUsageProvider
  │   ├── ClaudeUsageProvider
  │   └── UsageSnapshotCache
  └── DetailsContentResolver
      └── DetailsPanelViewModel
          └── DetailsPanel.render
```

## 模块与文件边界

建议在 `src/macos/Sources/AgentHaloCore/UsageMonitoring/` 下新增：

```text
UsageMonitoring/
├── UsageModels.swift
├── UsageProvider.swift
├── UsageMonitoringCoordinator.swift
├── UsageSnapshotCache.swift
├── UsageHTTPClient.swift
├── AccessModeResolver.swift
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

修改现有文件：

- `AgentHaloCore/HaloModels.swift`：保留会话模型；不继续扩张 `RateLimitSnapshot`。
- `AgentHaloMac/AppDelegate.swift`：接入 Coordinator 和新的纯展示解析器。
- `AgentHaloMac/DetailsPanel.swift`：增加主体标题、计划行、数据状态行和独立会话标题行。
- `AgentHaloCoreChecks/main.swift`：增加认证、映射、缓存和 Coordinator 检查。
- `AgentHaloMac/HaloInteractionChecks.swift`：增加面板互斥、上下文、切换和布局检查。
- 本地化源文件：增加使用情况、计划、状态和会话标题相关键；不修改 Windows 运行时代码。

## 领域模型

```swift
public enum UsageProviderID: String, Codable, Sendable {
    case codex
    case claude
}

public enum AccessMode: String, Codable, Sendable {
    case oauth
    case apiKey
}

public enum UsageWindowKind: String, Codable, Sendable {
    case session
    case weekly
}

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

public struct UsageMonitorState: Equatable, Sendable {
    public var providerID: UsageProviderID
    public var accessMode: AccessMode
    public var snapshot: UsageSnapshot?
    public var status: UsageDataStatus?
    public var isRefreshing: Bool
}
```

成功快照不包含错误。429、网络错误、认证失败和解析失败只改变 `UsageMonitorState`，不能覆盖最后成功快照。

面板模型使用枚举保证主体互斥：

```swift
public struct UsageDetailsModel: Equatable, Sendable {
    public var planName: String?
    public var windows: [UsageWindow]
    public var status: UsageDataStatus
}

public enum DetailsPanelBody: Equatable, Sendable {
    case usage(UsageDetailsModel)
    case session(SessionDetailsSnapshot)
}

public struct DetailsPanelViewModel: Equatable, Sendable {
    public var contextUsedPercent: Double?
    public var modeBadge: String?
    public var body: DetailsPanelBody
}
```

`contextUsedPercent` 不属于 OAuth 快照；它始终来自当前准确会话的本地数据。

`OAuthAccess` 只存在于内存，不实现 `Codable`，也不写入缓存：

```swift
public struct OAuthAccess: Sendable {
    public var providerID: UsageProviderID
    public var accountKey: AccountCacheKey
    public var source: CredentialSource
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date?
}
```

`CredentialSource` 只保存文件路径或 Keychain Service/Account 标识，不保存凭据内容。包含 Token 的类型不实现自定义日志描述，任何诊断输出只能使用脱敏的来源标签。

## 统一接口

```swift
public protocol UsageProvider: Sendable {
    var id: UsageProviderID { get }
    func resolveAccess() async -> ResolvedProviderAccess
    func refresh(using access: OAuthAccess) async throws -> UsageSnapshot
}

public enum ResolvedProviderAccess: Sendable {
    case oauth(OAuthAccess)
    case oauthNeedsSignIn(accountKey: AccountCacheKey?)
    case apiKey
}
```

Provider 负责一次完整刷新；AuthStore、Client 和 Mapper 保持可单独测试。

## 接入模式解析

模式解析参考 OpenUsage 的 Provider 级凭据发现方式，不绑定 Session ID。

### Codex

候选来源：

1. `$CODEX_HOME/auth.json`（设置了 `CODEX_HOME` 时）。
2. 默认认证文件路径。
3. macOS Keychain 的 Codex 认证条目。

规则：

- 任一候选存在非空 OAuth Access Token时，选择 OAuth。
- 同时存在 OAuth 和 `OPENAI_API_KEY` 时，OAuth 优先。
- 没有 OAuth、只有 API Key 时，选择 API 密钥模式。
- 没有可识别凭据时，安全降级为 API 密钥模式，不显示 Provider 错误。
- 保留凭据来源标识，供刷新前重读和同源写回使用；不得记录凭据内容。

### Claude Code

候选来源：

1. macOS Keychain。
2. `~/.claude/.credentials.json` 或 `CLAUDE_CONFIG_DIR` 对应文件。
3. `CLAUDE_CODE_OAUTH_TOKEN`。

规则：

- Keychain 中可访问 Usage API 的存储型 OAuth 优先。
- Keychain 不可用时尝试凭据文件。
- 存储型 OAuth 缺少 `user:profile` 时仍是 OAuth 模式，但返回 `oauthNeedsSignIn`。
- 只有 `CLAUDE_CODE_OAUTH_TOKEN` 时视为仅推理 Token，选择 API 密钥模式。
- 存储型 OAuth 与仅推理 Token 同时存在时，OAuth 优先。

## OAuth Token 刷新与写回

### 通用规则

1. Access Token 距过期不超过 5 分钟时触发主动刷新。
2. 刷新前重新读取同一凭据来源；CLI 已轮换 Token 时直接采用新值。
3. 每次 Usage 请求最多允许一次“401 → 刷新 → 重试”。
4. 刷新成功后写回同一来源；不能从文件读出后写入 Keychain，反之亦然。
5. 文件写回使用原子替换并保留原权限。
6. 解码和编码必须保留本期不认识的 JSON 字段：认证文件以原始 JSON Object 为写回载体，只合并已轮换字段，不能直接用只声明已知字段的 `Codable` 结构覆盖整个文件。
7. Keychain 写回使用原 Service/Account 组合。
8. 写回失败不阻断本次内存 Token 使用，但必须记录脱敏错误；下次启动重新读取原始来源。

### Codex

参考 OpenUsage：

- Usage：`GET https://chatgpt.com/backend-api/wham/usage`
- Token refresh：`POST https://auth.openai.com/oauth/token`
- 请求包含 `Authorization: Bearer`；有 `accountID` 时包含 `ChatGPT-Account-Id`。
- `refresh_token_expired`、`refresh_token_reused`、`refresh_token_invalidated` 分别归类为需要重新登录、Token 冲突或已撤销。
- Mapper 只读取 `plan_type`、`rate_limit.primary_window` 和 `rate_limit.secondary_window`。

### Claude Code

参考 OpenUsage：

- Usage：`GET https://api.anthropic.com/api/oauth/usage`
- Token refresh：`POST https://platform.claude.com/v1/oauth/token`
- Usage 请求包含 `Authorization: Bearer`、`anthropic-beta: oauth-2025-04-20` 和兼容 Claude Code 的 `User-Agent`。
- Mapper 只读取 `five_hour` 和 `seven_day`。
- `seven_day_sonnet`、`limits`、`extra_usage` 本期忽略。

## Usage Mapper

### 通用映射规则

- 百分比限制到 `0...100`；缺失值不伪造为 `0%`。
- 缺失窗口保持缺失；一个窗口缺失不影响另一个窗口。
- 重置时间接受 Provider 实际返回的时间格式，无法解析时保持 `nil`。
- 响应不是 2xx、正文不是合法 JSON 或没有任何可用字段时抛出分类错误。

### Codex 计划名称

| 原始 `plan_type` | 显示名称 |
| --- | --- |
| `prolite` | `Pro 5x` |
| `pro` | `Pro 20x` |
| 其他非空值 | 按 `_` 分词后转标题格式 |
| 空值 | `nil`，UI 隐藏计划行 |

### Claude Code 计划名称

- `subscriptionType` 转为标题格式。
- `rateLimitTier` 中存在 `数字+x` 时追加到名称，例如 `Max 5x`。
- `subscriptionType` 为空时返回 `nil`，UI 隐藏计划行。

## 账户缓存键

缓存键不能包含原始 Token：

- Codex 优先使用 `SHA256(accountID)`。
- Codex 缺少 `accountID` 时，使用凭据来源标识和 Refresh Token 指纹。
- Claude Code 使用 Keychain Service/凭据文件路径与 Refresh Token 指纹；没有 Refresh Token 时使用 Access Token 指纹。
- 指纹只保存哈希值，不记录、不展示、不写入日志。

AgentHalo 自己轮换 Token 时，如果 Provider、凭据来源和刷新链一致，将现有快照绑定迁移到新指纹。外部重新登录导致凭据变化时不迁移，避免向新账户显示旧账户快照。

## 持久化缓存

路径：`~/.agent-halo/usage-snapshots-v1.json`

缓存内容：

- Schema 版本。
- Provider ID 和账户缓存键。
- 计划名称、Session/Weekly 窗口和最后成功时间。

规则：

- 原子写入，权限仅当前用户可读写。
- 不保存 Token、API Key、认证头、原始响应和会话内容。
- 错误响应不写入缓存。
- 每个 Provider 最多保留最近三个账户。
- 超过 30 天的条目清理。
- 启动时加载磁盘快照用于立即展示，但磁盘快照不阻止首次网络刷新。
- 磁盘加载的快照在本次运行首次成功刷新前按 stale 显示，即使其时间戳未超过 5 分钟。
- 当前运行期间成功写入的快照在 5 分钟内视为 fresh。
- 最后成功更新超过 10 分钟视为 stale。

## Coordinator 状态机

`UsageMonitoringCoordinator` 为 `actor`，负责串行保护 Provider 状态和刷新任务。

```text
ensureFresh(provider)
  → resolveAccess()
  ├── apiKey
  │   └── 发布 API 密钥模式，不调用 Usage API
  ├── oauthNeedsSignIn
  │   └── 保留同账户快照，发布 signInAgain
  └── oauth
      → 读取 Provider + Account 缓存
      ├── 当前运行内且未超过 5 分钟：返回缓存
      └── 缓存过期或不存在
          → 刷新 Token（如需要）
          → 请求 Usage API
          → Mapper
          → 写入成功快照
          → 发布 fresh
```

约束：

- 同一个 Provider 同时最多一个刷新任务。
- 当前焦点 Provider 每 5 分钟刷新一次。
- 打开详情面板和切换 Agent 时调用 `ensureFresh`；缓存仍 fresh 时不重复请求。
- 切换 Agent 不必取消旧 Provider 已在执行的安全请求，但旧结果只能写入自己的状态和缓存。
- UI 接收结果时再次校验当前焦点 Provider。
- 周期调度不挂接现有高频 `AppDelegate.tick()`。
- 应用退出时取消周期任务和未完成网络请求。

## 错误与降级

| 情况 | 有当前账户快照 | 无当前账户快照 | UI 状态 |
| --- | --- | --- | --- |
| 成功 | 更新快照 | 创建快照 | `fresh` |
| 429 | 保留快照 | 无窗口 | `stale` / `noData` |
| 网络错误、5xx | 保留快照 | 无窗口 | `stale` / `noData` |
| 空响应、解析失败 | 保留快照 | 无窗口 | `stale` / `noData` |
| 401 且刷新失败 | 保留快照 | 无窗口 | `signInAgain` |
| 缺少 Claude `user:profile` | 保留同账户快照 | 无窗口 | `signInAgain` |
| 账户变化 | 不使用旧账户快照 | 新账户无窗口 | `noData` |

429 遵守 `Retry-After`；缺失或无法解析时进入 5 分钟冷却。冷却期内不发起 Usage 请求。

UI 状态优先级：

1. `signInAgain`
2. `stale`
3. `noData`
4. `fresh`

同一时刻只显示一条状态文案。所有状态使用中性样式，不改变 Halo 状态。

## macOS 生命周期接入

`AppDelegate` 新增：

```swift
private let usageCoordinator: UsageMonitoringCoordinator
private var usageRefreshLoopTask: Task<Void, Never>?
```

行为：

- 启动：加载持久化快照，启动低频刷新循环，并对当前焦点 Provider 调用 `ensureFresh`。
- 打开详情：立即以当前缓存/本地会话数据渲染，再异步调用 `ensureFresh`。
- 切换 Agent：立即显示目标 Provider 的当前模型，再按需刷新。
- Usage 状态变化：仅当详情面板可见且 Provider 仍为当前焦点时重绘。
- 退出：取消刷新循环和网络任务。

`AppDelegate.updateDetailsPanelContent()` 不再调用 `RateLimitReader.read()` 作为 OAuth 配额来源。`RateLimitReader` 可在迁移阶段保留给现有检查，但新面板路径不依赖它。

## 详情面板展示

### 共同顶部

```text
顶部行
├── Agent 切换器
└── contextPill：当前准确会话的上下文占用百分比

状态标题
当前操作
```

`contextPill`：

- Codex 使用当前焦点 `SessionSnapshot.contextUsedPercent`。
- Claude Code 使用准确 Session ID 对应的 `ClaudeContextUsageSnapshot.usedPercent`。
- OAuth 和 API 密钥模式均可显示。
- `OFFLINE`、缺少数据或数据不属于当前会话时隐藏。
- Agent/Session 切换时先清除旧值，禁止跨会话复用。
- Usage API 失败不影响仍有效的本地上下文百分比。

### OAuth 主体

```text
使用情况 / 余额
├── 计划：Pro 5x / Pro 20x / Max 5x 等
├── Session：进度条、已使用百分比、重置时间
├── Weekly：进度条、已使用百分比、重置时间
└── 数据状态
```

- 计划名称是独立行，不与 `contextPill` 或标题合并。
- 计划名为空时隐藏整行，不显示 `--`。
- Agent 离线时隐藏会话级 `contextPill`，但可以继续显示当前账户使用情况快照。
- 不显示会话详情和本期排除的余额类字段。

### API 密钥主体

```text
会话详情                     API Key mode
├── 项目
├── 会话标题
├── 模型
└── 输入/输出 Token
```

- 四项使用四个独立 `MetadataRowView`。
- 会话标题缺失时显示 `--`，不得回退为项目。
- 输入或输出 Token 仅一侧缺失时，只将缺失侧显示为 `--`。
- `OFFLINE` 时四行均显示 `--`，同时隐藏 `contextPill`。
- 不显示计划、使用窗口和 OAuth 数据状态。

会话详情数据继续来自现有 `SessionSnapshot` 和 Claude 精确会话解析器。Codex 的 `SessionReducer` 需要在 `session_meta` 或后续受支持的会话元数据包含标题时写入现有 `SessionSnapshot.sessionTitle`；上游没有标题字段时保持 `nil`，UI 显示 `--`，不得用项目名称补位。

主体切换时先隐藏两个 Group，再显示目标 Group，避免同一帧短暂共存和面板高度跳变。

## 隐私与日志

- Usage 请求只包含 Provider 所需认证头和账户头。
- 不发送项目、会话标题、模型、Token 数量、提示词、工具输出或项目路径。
- 自定义/第三方推理端点不接收 AgentHalo Usage 请求。
- 不记录 Token、API Key、认证头、响应正文和账户缓存键。
- 日志只允许记录 Provider、凭据来源类型、HTTP 状态分类、刷新耗时、缓存命中和脱敏错误。
- 不修改 Claude StatusLine Proxy 来采集认证模式。

## 测试设计

### AgentHaloCoreChecks

- Codex 文件、默认路径和 Keychain 凭据优先级。
- Claude Keychain、凭据文件和 inference-only Token 优先级。
- OAuth 与 API Key 同时存在时 OAuth 优先。
- Token 临期刷新、刷新前重读、同源写回、未知字段和文件权限保留。
- 401 单次刷新重试；连续 401 不再重试。
- 429 `Retry-After` 和默认冷却。
- Codex/Claude 成功、缺失窗口、空响应和错误 Fixture。
- Codex 会话元数据包含标题时独立写入 `sessionTitle`；缺失时保持 `nil`。
- 计划名称映射。
- Provider + 账户缓存隔离。
- AgentHalo 内部 Token 轮换缓存迁移。
- 外部重新登录不复用旧账户快照。
- fresh/stale/noData/signInAgain 优先级。
- 重复刷新合并和焦点 Provider 调度。
- `DetailsPanelBody` 主体互斥。

### AgentHaloMac 自检

- OAuth 显示独立计划行、Session、Weekly 和唯一状态文案。
- API 密钥显示四行独立会话字段。
- 会话标题不回退为项目。
- OAuth/API 密钥模式均能显示有效 `contextPill`。
- Usage API 失败不清除有效上下文百分比。
- Agent/Session 切换不残留旧上下文。
- `OFFLINE` 隐藏 `contextPill`；API 密钥四行显示 `--`；OAuth 快照仍可显示。
- 两个主体不会同时出现。
- 旧 Provider 异步请求不会覆盖当前面板。
- 长计划名、项目名、会话标题和本地化文案不撑宽面板。

### 最终验证命令

```bash
cd src/macos
swift run AgentHaloCoreChecks
swift run AgentHaloMac --self-check
swift build

cd ../..
git diff --check
bash scripts/build-macos.sh
bash scripts/run-macos.sh --verify
```

用户实际运行的验证目标是 `outputs/AgentHalo-macOS/AgentHalo.app`，不能只验证 SwiftPM `.build` 产物。

## 实施顺序

1. 增加统一模型、协议和失败测试。
2. 实现 Codex AuthStore、Client、Mapper、Provider。
3. 实现 Claude AuthStore、Client、Mapper、Provider。
4. 实现账户缓存和 Coordinator 状态机。
5. 实现纯 `DetailsContentResolver`。
6. 更新 DetailsPanel：主体标题、计划行、状态行和独立会话标题行。
7. 将 AppDelegate 切换到新管线并增加低频调度。
8. 移除新详情路径对 RateLimitReader 的依赖。
9. 完成本地化、CoreChecks、Mac 自检和打包验证。

每一步先增加对应失败检查，再实现最小代码使其通过。

## 完成标准

- 产品规格中的 OAuth/API 密钥模式矩阵在 macOS 全部通过。
- Codex 和 Claude Code 使用同一领域模型和 Coordinator，不在 AppDelegate 重复实现 Provider 逻辑。
- `contextPill`、计划名称和主体内容按本设计同时、互斥或隐藏。
- Token 刷新不会覆盖错误来源，不会丢失未知认证字段。
- 快照不会跨 Provider 或账户复用。
- 失败时保留最后成功快照且不改变 Halo 状态。
- 所有核心检查、自检、构建和已打包 App 验证通过。
