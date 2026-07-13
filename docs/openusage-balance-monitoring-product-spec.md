# OpenUsage 风格余额监控产品规格书

## 产品目标

AgentHalo 参考 [OpenUsage 余额监控调研](./openusage_balance_monitoring_research.md)，为 Codex 和 Claude Code 提供按接入模式切换的详情面板：

- 官方 OAuth 模式显示“使用情况 / 余额”。
- API 密钥模式显示“会话详情”。无可用 OAuth 凭据时，自定义 Base URL 和第三方推理配置统一归入 API 密钥模式。
- 两种主体内容互斥，不会同时出现。
- 两种模式都可以显示当前会话的上下文百分比；OAuth 模式还显示独立的计划名称行。
- 实时使用情况不可用不得改变 Halo 的会话状态，也不得让整个服务商（Provider）进入错误状态。

“使用情况 / 余额”是订阅模式的主体区域名称。本期只实现使用情况；余额、Credits、额外使用额（Extra Usage）和速率限制重置额度（Rate Limit Reset Credits）属于后续能力，本期不获取、不展示，也不占位。

## 本期范围

### 本期包含

- 参考 OpenUsage，根据当前焦点 Agent 的有效凭据集合和可识别配置判断接入模式。
- OAuth 模式下显示计划、使用窗口、已使用百分比和重置时间。
- API 密钥模式下显示项目、会话标题、模型和输入/输出 Token。
- 两种模式均保留当前会话上下文百分比（`contextPill`）。
- OAuth 实时数据的刷新、缓存、过期和重新登录状态。
- Codex 与 Claude Code 使用相同的主体切换规则。

### 后续能力

- 货币余额和 Credits 数量。
- 额外使用额（Extra Usage）。
- 速率限制重置额度及其过期时间。
- 本地消费估算和历史消费图块。

## 接入模式判定

接入模式参考 OpenUsage 的 Provider 级凭据发现方式，由当前焦点 Agent 的有效凭据集合和可识别配置决定。AgentHalo 本期不读取运行中 Codex/Claude Code 进程的完整环境，也不宣称能够识别任意会话进程实际使用的凭据；使用情况 API 是否调用成功只影响数据状态，不影响接入模式。

对用户和 UI 只暴露 OAuth 模式与 API 密钥模式。按以下优先级判断：

1. 存在可用于对应服务商使用情况 API 的 OAuth 凭据时，判定为 OAuth 模式。
2. 同时存在 OAuth 和 API Key 时，OAuth 优先。
3. 无可用 OAuth 凭据，只有 API Key、仅推理 Token、自定义 Base URL 或第三方推理配置时，判定为 API 密钥模式。
4. 无法确认凭据类型时，安全降级为 API 密钥模式并显示会话详情，不显示服务商错误。

模式一旦确定，网络故障、429、空响应或令牌刷新失败只改变数据状态，不得自动切换到另一种接入模式。

## 共享面板布局

详情面板对 Codex 和 Claude Code 使用相同的信息层级。

### 头部

- Agent 切换：`Codex` / `CC`。
- 上下文百分比：存在当前准确会话的上下文数据时显示 `contextPill`；`OFFLINE`、数据缺失或数据不属于当前会话时隐藏。
- 当前状态：`THINKING`（思考中）、`WORKING`（工作中）、`NEEDS YOU`（需要您）、`DONE`（已完成）、`OFFLINE`（离线）或等效的本地化文案。
- 当前任务详情：当前操作。
- 模式标签：API 密钥模式统一显示 `API Key mode`（API 密钥模式）。

### 使用情况 / 余额

仅在 OAuth 模式下显示，包含：

- 独立的计划名称行；有计划名称时显示映射后的名称，无计划名称时隐藏整行。
- 本期定义的使用窗口。
- 每个窗口的进度条、已使用百分比和重置时间。
- 数据状态文案。

OAuth 模式不显示“会话详情”。本期不显示货币余额、Credits、Extra Usage 或 Rate Limit Reset Credits。

OAuth 使用情况与会话级 `contextPill` 相互独立：Usage API 失败不得清除仍然有效的本地上下文百分比；当前 Agent 离线时隐藏 `contextPill`，但仍可显示当前账户的使用情况快照。

### 会话详情

仅在 API 密钥模式下显示。以下四项必须是独立的四行，不得合并：

- 项目 (Project)
- 会话标题 (Session title)
- 模型 (Model)
- 输入/输出 Token (Input/output tokens)

字段显示规则：

- 项目与会话标题分别取值；会话标题缺失时不得回退为项目名称。
- 单个字段缺失时，该行显示 `--`，其他字段继续显示。
- 输入或输出 Token 仅有一项时，缺失的一侧显示 `--`。
- 当前 Agent 为 `OFFLINE` 时，四行均显示 `--`。
- API 密钥模式不显示“使用情况 / 余额”及其不可用占位行。
- 有当前准确会话的上下文数据时仍显示 `contextPill`；该指标不属于“会话详情”四行字段。

## 计划名称映射

计划名称遵循 OpenUsage 当前的映射规则。

### Codex

从使用情况 API 的 `plan_type` 读取：

| 原始值 | 显示名称 |
| --- | --- |
| `prolite` | `Pro 5x` |
| `pro` | `Pro 20x` |
| 其他非空值 | 去除首尾空白，以 `_` 分词后转为标题格式，例如 `free` → `Free`、`plus` → `Plus` |
| 空值 | 隐藏计划行 |

### Claude Code

- 读取 OAuth 凭据中的 `subscriptionType`，去除首尾空白并转为标题格式，例如 `max` → `Max`、`pro` → `Pro`。
- 如果 `rateLimitTier` 包含 `数字+x`，将该片段追加到计划名称，例如 `max` 与包含 `5x` 的层级显示为 `Max 5x`。
- `rateLimitTier` 不包含倍率时，仅显示格式化后的 `subscriptionType`。
- `subscriptionType` 为空时隐藏计划行。

## 数据状态与缓存

数据状态仅显示在 OAuth 模式的“使用情况 / 余额”区域底部。刷新间隔由实现配置，默认 5 分钟。

状态优先级从高到低如下：

1. OAuth 凭据失效、缺少实时使用情况所需的 Scope 或 Token 刷新失败：保留当前账户最后一次成功快照（如果存在），并显示 `Sign in again for live usage`（重新登录以查看使用情况）。
2. 本次刷新失败但存在当前账户的成功快照：继续显示快照，并显示 `Live usage may be stale`（使用情况可能已过期）。
3. 当前账户从未获得成功快照：显示 `No live data`（暂无使用情况数据）。
4. 最近一次成功更新距今不超过两个刷新周期：显示 `Live usage updated Xm ago`（使用情况更新于 X 分钟前）。
5. 最近一次成功更新超过两个刷新周期：继续显示快照，并显示 `Live usage may be stale`。

缓存规则：

- 快照必须按服务商和账户隔离，不能跨账户复用。
- 应用启动时可以立即显示磁盘中的最后成功快照，但在本次运行首次刷新成功前，该快照按过期状态显示且不能阻止网络刷新。
- 切换接入模式或 OAuth 账户后，旧账户快照不得继续显示。
- API 返回 429、网络超时或空响应时，保留当前账户最后一次成功快照。
- 不同时显示多条数据状态文案；按上述优先级只显示一条。
- 数据状态使用中性样式，不使用红色错误配色，也不改变 Halo 状态。

## Codex：OAuth 登录模式

### 触发条件

- 当前焦点 Agent 为 Codex，且认证存储中存在可用 Codex OAuth 访问令牌；同时存在 API Key 时仍优先 OAuth。
- 访问令牌是否过期、能否刷新以及使用情况 API 是否成功，只影响数据状态。

### 面板内容

- 计划 (Plan)：按“计划名称映射”显示。
- 会话 (Session)：5 小时主要窗口，显示进度条、已使用百分比和重置时间。
- 每周 (Weekly)：7 天次要窗口，显示进度条、已使用百分比和重置时间。
- 数据状态：按“数据状态与缓存”显示。
- 不显示会话详情、货币余额、Credits、Extra Usage 或 Rate Limit Reset Credits。

## Codex：API 密钥模式

### 触发条件

- 当前焦点 Agent 为 Codex，无可用 OAuth 凭据，只有 `OPENAI_API_KEY`、第三方服务商密钥、`auth.json.apiKey`、自定义 Base URL 或第三方推理配置；或
- 无法确认 Codex 凭据类型，需要安全降级为会话详情。

### 面板内容

主体区域仅显示四行独立的“会话详情”：项目、会话标题、模型、输入/输出 Token。

### 要求行为

- 不显示计划、会话/每周使用窗口或任何“使用情况 / 余额”的不可用占位行。
- 实时使用情况不可用不得改变 Halo 状态或显示红色服务商错误。
- 单个会话字段缺失时仅将该行显示为 `--`。

## Claude Code：OAuth 登录模式

### 触发条件

- 当前焦点 Agent 为 Claude Code，且 Keychain 或 `~/.claude/.credentials.json` 中存在存储型 OAuth 凭据；同时存在仅推理 Token 时仍优先 OAuth。
- 凭据作用域、令牌刷新状态以及使用情况 API 结果只影响数据状态。

### 面板内容

- 计划 (Plan)：按“计划名称映射”显示。
- 会话 (Session)：5 小时使用窗口，显示进度条、已使用百分比和重置时间。
- 每周 (Weekly)：7 天使用窗口，显示进度条、已使用百分比和重置时间。
- 数据状态：按“数据状态与缓存”显示。
- 不显示会话详情或 Extra Usage。

## Claude Code：API 密钥模式

### 触发条件

- 当前焦点 Agent 为 Claude Code，无可用存储型 OAuth 凭据，只有 API Key、自定义 Base URL、第三方推理配置或用于推理的 `CLAUDE_CODE_OAUTH_TOKEN`；或
- 无法确认 Claude Code 凭据类型，需要安全降级为会话详情。

### 面板内容

主体区域仅显示四行独立的“会话详情”：项目、会话标题、模型、输入/输出 Token。

### 要求行为

- 不显示计划、会话/每周使用窗口或任何“使用情况 / 余额”的不可用占位行。
- 不因缺少实时使用情况权限要求用户登录，也不显示红色服务商错误。
- 单个会话字段缺失时仅将该行显示为 `--`。

## 数据源职责

### 接入模式解析器 (Access Mode Resolver)

- 参考 OpenUsage，从当前焦点 Agent 的认证存储和可识别配置解析有效凭据类型。
- 按“接入模式判定”的优先级输出 OAuth 或 API 密钥模式。
- 不读取运行中 Agent 进程的完整环境，不修改 Claude StatusLine Proxy 来采集认证模式。
- 可以在内部保留 OAuth、API Key、自定义 Base URL 和第三方端点等来源类型用于诊断和请求路由，但不得记录凭据内容，也不得形成第三种 UI 模式。
- 无法识别时返回安全降级结果，不把未知状态当作服务商错误。

### 认证存储 (Auth Store)

- Codex：读取 `$CODEX_HOME/auth.json` 和 Keychain，并区分 OAuth 与 API Key。
- Claude Code：读取 Keychain、`~/.claude/.credentials.json` 和 `CLAUDE_CODE_OAUTH_TOKEN`，并判断作用域与仅推理（inference-only）状态。
- 不记录或展示访问令牌、刷新令牌、API Key、OAuth Scope 或内部认证细节。

### 使用情况客户端 (Usage Client)

- 仅在 OAuth 模式下调用服务商官方使用情况端点。
- Codex：获取计划、5 小时窗口和每周窗口。
- Claude Code：获取计划、5 小时窗口和每周窗口。
- 请求不得包含本地会话内容、项目名称、会话标题、模型或 Token 明细。

### 使用情况映射器 (Usage Mapper)

- 按 OpenUsage 规则映射计划名称。
- 将服务商响应映射为使用窗口、已使用百分比、重置时间、可用性状态和最后成功更新时间。
- 对缺失的可选窗口保持缺失，不伪造 `0%`。

### 本地日志扫描器 (Local Log Scanner)

- 仅为 API 密钥模式提供会话详情。
- Codex：扫描 `$CODEX_HOME/sessions/**/*.jsonl` 和 `$CODEX_HOME/archived_sessions/**/*.jsonl`。
- Claude Code：扫描 `~/.claude/projects/**/*.jsonl`。
- 分别提取项目、会话标题、模型、输入 Token 和输出 Token；项目与会话标题不得在数据层合并。

### 会话上下文读取器 (Session Context Reader)

- OAuth 与 API 密钥模式均可读取当前会话的上下文百分比。
- Codex 从当前焦点 `SessionSnapshot` 读取；Claude Code 必须按准确 Session ID 读取对应的上下文快照。
- `OFFLINE`、数据缺失或数据不属于当前会话时不返回上下文百分比。
- 上下文百分比不进入 OAuth 账户快照，不受 Usage API 数据状态影响。

## 隐私边界

- OAuth 模式仅向对应服务商的官方使用情况端点发送认证请求。
- AgentHalo 不上传本地会话内容、提示词、工具输出、项目路径或会话元数据。
- API 密钥模式不为获取余额而调用官方使用情况端点。
- 日志和诊断信息不得包含访问令牌、刷新令牌或 API Key。

## 验收标准

### 模式与主体内容

| 当前 Agent 的有效凭据/配置 | 预期模式 | 主体内容 |
| --- | --- | --- |
| OAuth + API Key | OAuth | 使用情况 / 余额 |
| 仅 OAuth | OAuth | 使用情况 / 余额 |
| 仅 API Key、仅推理 Token 或第三方推理配置 | API 密钥 | 会话详情 |
| 无法确认凭据类型 | API 密钥 | 会话详情 |

- Codex 与 Claude Code 均满足上述模式矩阵。
- “使用情况 / 余额”和“会话详情”不会同时出现，切换 Agent 或模式时也不得短暂共存。
- OAuth API 调用失败不会改变已判定的接入模式。

### OAuth 模式

- Codex 显示映射后的计划名称、5 小时窗口、每周窗口和一条数据状态文案。
- Claude Code 显示映射后的计划名称、5 小时窗口、每周窗口和一条数据状态文案。
- 计划名称作为独立的“计划”行显示；原始值为空时隐藏整行。
- 存在当前准确会话的上下文数据时，同时显示 `contextPill`；Usage API 失败不清除该值。
- 每个使用窗口显示进度条、已使用百分比和重置时间。
- 不显示会话详情、货币余额、Credits、Extra Usage 或 Rate Limit Reset Credits。
- 429、网络超时或空响应保留当前账户最后一次成功快照，并显示过期状态。
- OAuth 凭据失效时显示统一的重新登录文案，不改变 Halo 状态。
- 不存在成功快照时显示 `No live data`，但面板头部仍保持可用。

### API 密钥模式

- 主体区域显示项目、会话标题、模型和输入/输出 Token 四行独立字段。
- 存在当前准确会话的上下文数据时，同时显示 `contextPill`。
- 会话标题缺失时显示 `--`，不得使用项目名称代替。
- 任一字段缺失不会隐藏其他字段或整个会话详情。
- `OFFLINE` 时四行均显示 `--`。
- `OFFLINE` 时隐藏 `contextPill`。
- 不显示使用窗口、余额占位、数据状态或红色服务商错误。

### 计划名称

- Codex：`prolite` 显示 `Pro 5x`，`pro` 显示 `Pro 20x`，`free` 显示 `Free`，`plus` 显示 `Plus`。
- Claude Code：`subscriptionType=max` 且 `rateLimitTier` 含 `5x` 时显示 `Max 5x`；无倍率时仅显示标题格式的订阅名称。
- 计划原始值为空时不显示空标签或占位标签。

### 缓存、切换与隐私

- 快照不会跨服务商或 OAuth 账户复用。
- 切换到 API 密钥模式后立即隐藏 OAuth 使用情况，不保留不可用占位行。
- Codex / CC 切换后，头部、主体内容和数据状态均对应当前焦点 Agent。
- 官方使用情况请求不包含任何本地会话内容或会话元数据。
