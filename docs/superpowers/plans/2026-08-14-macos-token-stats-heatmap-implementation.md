# 本地 Tokens 统计与迷你热力 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 AgentHalo macOS 详情面板里，为当前焦点 Agent 提供跨会话、按本地日历日的 token 合计，并用 278×172 面板上的静音点翻到「一行摘要 + 近 5 周迷你热力」页。

**Architecture:** 新能力全部放进现有 `AgentHaloCore` 的 `TokenStats/`，与额度管线并行、不共享快照。扫描器按 `AgentKind` 读原生 CLI 日志（Codex / Claude / Grok / Pi），经增量 JSONL 缓存与日累加器得到 `TokenStatsSnapshot`；`TokenStatsCoordinator` 只扫焦点 Agent。`DetailsPanel` 用瞬时翻页状态渲染 tokens 页，`DetailsContentResolver` / `UsageSnapshot` 不动。

**Tech Stack:** Swift 6、SwiftPM、AppKit、Foundation、现有 `AgentHaloCoreChecks` 与 `AgentHaloMac --self-check`

## Global Constraints

- 只改 macOS 与共享 locale；不改 Windows 运行时、`UsageSnapshot`、`agent-halo.v2.json` 动画合同。
- 面板外框锁定宽 278、拟合高 172（偶像素）；OAuth / API Key / tokens 页 / Offline / Online 全部同高。
- 只扫当前焦点 Agent 的原生 CLI 日志；不把 Pi 折进 Claude/Codex，反之亦然。
- 不做美元、价目网络、全年热力、趋势柱、模型 hover、Status/Dashboard。
- 未知模型的 token 计入总数。
- 扫描成败不改 Halo 生命周期色；额度 API 成败不清 tokens 快照。
- 新缓存 `0600`；诊断不打完整用户路径、不打行内容。
- `AgentHaloCoreChecks` 是 executable，不是 XCTest：检查里用到的类型、init、方法必须 `public`；所有 public struct 必须显式 `public init`。
- 每项任务 TDD：先写失败检查并确认失败原因，再最小实现，再跑聚焦检查与 `swift run AgentHaloCoreChecks`（UI 任务再跑 `swift run AgentHaloMac --self-check`）。
- 提交前 `git status --short`，只暂存本任务列出的文件。

---

## 目标文件与接口总览

新增：

```text
src/macos/Sources/AgentHaloCore/TokenStats/
├── TokenStatsModels.swift
├── TokenCountFormatter.swift
├── TokenHeatmapLayout.swift
├── DailyTokenAccumulator.swift
├── JSONLScanning.swift
├── IncrementalJSONLScanner.swift
├── JSONLScanCacheStore.swift
├── TokenStatsSnapshotStore.swift
├── TokenStatsCoordinator.swift
├── CodexTokenLogScanner.swift
├── ClaudeTokenLogScanner.swift
├── GrokTokenLogScanner.swift
└── PiTokenLogScanner.swift

src/macos/Sources/AgentHaloCoreChecks/TokenStatsChecks.swift
src/macos/Sources/AgentHaloCoreChecks/TokenStatsCheckSupport.swift
```

修改：

```text
src/macos/Sources/AgentHaloCore/AgentHaloPaths.swift
src/macos/Sources/AgentHaloCoreChecks/main.swift
src/macos/Sources/AgentHaloMac/DetailsPanel.swift
src/macos/Sources/AgentHaloMac/AppDelegate.swift
src/macos/Sources/AgentHaloMac/HaloInteractionChecks.swift
src/shared/locales/en.json
src/shared/locales/zh.json
src/macos/Sources/AgentHaloCore/locales/en.json
src/macos/Sources/AgentHaloCore/locales/zh.json
docs/superpowers/specs/2026-08-14-macos-token-stats-heatmap-design.md
```

统一公开接口：

```swift
public enum TokenStatsWindow {
    public static let previousDays = 30
    public static let weekColumns = 5
    public static func dayKey(from date: Date, calendar: Calendar = .current) -> String
    public static func sinceDate(now: Date, calendar: Calendar = .current) -> Date
}

public struct TokenDayTotals: Equatable, Sendable {
    public var date: String
    public var totalTokens: Int64
    public init(date: String, totalTokens: Int64)
}

public struct TokenStatsSnapshot: Equatable, Sendable {
    public var agent: AgentKind
    public var days: [TokenDayTotals]
    public var scannedAt: Date
    public init(agent: AgentKind, days: [TokenDayTotals], scannedAt: Date)
}

public enum TokenStatsStatus: Equatable, Sendable {
    case ready(TokenStatsSnapshot)
    case empty
    case scanning
}

public enum TokenLogScanResult: Equatable, Sendable {
    case scanned([TokenDayTotals])
    case missingRoot
    case failed
    case cancelled
}

public protocol TokenLogScanning: Sendable {
    var agent: AgentKind { get }
    func scan(now: Date) async -> TokenLogScanResult
}

public enum TokenCountFormatter {
    public static func compact(_ count: Int64) -> String
}

public struct TokenHeatmapCell: Equatable, Sendable {
    public var dayKey: String
    public var tokens: Int64
    public var level: Int          // 0...4
    public var isFuture: Bool
    public var isInWindow: Bool
    public init(dayKey: String, tokens: Int64, level: Int, isFuture: Bool, isInWindow: Bool)
}

public enum TokenHeatmapLayout {
    public static func cells(
        days: [TokenDayTotals],
        now: Date,
        calendar: Calendar
    ) -> [TokenHeatmapCell] // 35 个，index = col * 7 + row；col 0 最旧
}

public enum TokenStatsPresentation {
    public static func todayTokens(days: [TokenDayTotals], now: Date, calendar: Calendar) -> Int64?
    public static func last31DaysTokens(days: [TokenDayTotals]) -> Int64?
}

public actor TokenStatsCoordinator {
    public init(
        scanners: [any TokenLogScanning],
        store: TokenStatsSnapshotStore,
        now: @escaping @Sendable () -> Date = Date.init,
        isPaused: @escaping @Sendable () -> Bool = { false }
    )
    public func prepare(_ agent: AgentKind) async -> TokenStatsStatus
    public func ensureFresh(_ agent: AgentKind) async -> TokenStatsStatus
    public func state(for agent: AgentKind) -> TokenStatsStatus
    public func cancelAll() async
}
```

语义对照以规格为准。Codex / Claude 去重必须对齐 `/Users/wjs/work/ossp/openusage` 对应 scanner，不要凭感觉简化。

### 作者自检（已写入下方任务，勿再踩）

1. `TokenStatsSnapshotStore` 必须注入 `now`。`scannedAt = 1000` 是 1970 年，按 30 天淘汰会把「新鲜」Codex 条目一并丢掉。
2. 2026-08-14 是周五、周起始周一：5 周网格从 **2026-07-13** 起，不是 today-34。窗外空心格用 07-13 / 07-14 断言。
3. 取消检查不得写成 `nil || ["x"]`（恒真）。parse 里等到 `Task.isCancelled` 再返回，断言结果是 `nil`。
4. `PageDotsView` **不能**作为 `NSStackView` arrangedSubview：inset 对调净值是 0，再加一个 arranged 视图会把 172 撑高。点必须叠在容器底边，不计入 stack fitting height。
5. `render` 里两处 `edgeInsets.bottom = 4` 必须删；只改 init 不够。
6. 扫描器检查复用 `FakeUsageEnvironment`（已在 `UsageMonitoringCheckSupport.swift`），不要再写一套。
7. `TokenStatsCoordinator.live()` 在 Task 7 就定义，Task 10 只接线。
8. Grok 的 size/mtime 跳过必须落盘，不能只放进程内存。
9. 退出路径要在现有 `await usageCoordinator.cancelAll()` 同一 `Task` 里再 `await tokenStatsCoordinator.cancelAll()`。`cancelAll()` 必须是 `async` 并等待 in-flight（与额度协调器相同）。改 `testUsageTerminationWaitsForCoordinatorCancellation`，要求这段源码同时包含两次 `cancelAll`。
10. `FakeTokenLogScanner` 必须是 `final class … @unchecked Sendable`（照 `FakeUsageEnvironment`），**禁止** `actor FakeTokenLogScanner: TokenLogScanning`：`var agent` 是非隔离协议要求，actor 存贮属性见证不过 Swift 6。
11. `IncrementalJSONLScanner.items` 的 `parse` 必须是 `async`。Task 3 取消检查在 parse 里 `await gate.waitUntilCancelled()`；同步 `(Data) -> [Item]` 编不过。扫描器本身是 actor。
12. `.scanning` / 「扫描中 cancelAll」检查必须用会挂起的 scanner。立即返回的 fake 在 `await ensureFresh` 回来时扫描已结束，断言恒真或永远看不到 `.scanning`。
13. `updateDetailsPanelContent` 是同步方法。禁止 `tokenStatsCoordinator.state(for:)` 直接传入 `render`（跨 actor 要 `await`，编不过）。照额度的 `usageStates`：MainActor 上缓存 `[AgentKind: TokenStatsStatus]`，`prepare`/`ensureFresh` 完成后再 publish。
14. 改 `render` 调用后必须同步改 `testUsageMonitoringLifecycleWiring` 里这行字面量：`detailsPanel.render(aggregate: displayedAggregate, model: model)`，否则现网源码断言会红。
15. 5 分钟循环 / `showDetails` / `setFocusedAgent` 里的 token 刷新**不得**写在 `if let providerID = usageProviderID` 里面，否则 Pi 永远不扫。
16. tokens 页必须 `tokenStatsGroup.heightAnchor = 70`，并 `setCustomSpacing(16, after: detailField)`。65pt 内容不钉高度、或从会话页切过来仍用 spacing 11，拟合高会掉到 172 以下。
17. Task 3 的 `@Sendable` parse 不得 mutate 局部 `var`，也不得捕获嵌套 `func`（Swift 6 `SendableClosureCaptures`）。计数用现网 `LockedBox`；行过滤用文件级 `tokenStatsKeepLines`。`String(data:)?.split.map.filter` 是 `[String]?`，必须解成 `[String]`。
18. Task 7 在第一次 `ensureFresh` 已 `ready` 后再测取消：必须先把注入的 `now` 推过 5 分钟，否则按「本进程成功扫完 5 分钟内不扫」根本不会进 `scan`，`waitUntilEntered` 会挂死。

---

### Task 1: 窗口、累加器、热力网格、紧凑数字

**Files:**
- Create: `src/macos/Sources/AgentHaloCore/TokenStats/TokenStatsModels.swift`
- Create: `src/macos/Sources/AgentHaloCore/TokenStats/DailyTokenAccumulator.swift`
- Create: `src/macos/Sources/AgentHaloCore/TokenStats/TokenCountFormatter.swift`
- Create: `src/macos/Sources/AgentHaloCore/TokenStats/TokenHeatmapLayout.swift`
- Create: `src/macos/Sources/AgentHaloCoreChecks/TokenStatsCheckSupport.swift`
- Create: `src/macos/Sources/AgentHaloCoreChecks/TokenStatsChecks.swift`
- Modify: `src/macos/Sources/AgentHaloCoreChecks/main.swift`（在 `await runUsageModelChecks()` 后加 `await runTokenStatsChecks()`）

**Interfaces:**
- Consumes: `AgentKind`
- Produces: `TokenStatsWindow`、`TokenDayTotals`、`TokenStatsSnapshot`、`TokenStatsStatus`、`TokenLogScanResult`、`TokenLogScanning`、`DailyTokenAccumulator`、`TokenCountFormatter`、`TokenHeatmapLayout`、`TokenStatsPresentation`

- [ ] **Step 1: Write the failing checks**

`TokenStatsCheckSupport.swift`：

```swift
import Foundation
import AgentHaloCore

func tokenStatsUTCCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    calendar.firstWeekday = 2 // Monday
    return calendar
}

func tokenStatsDate(_ value: String, calendar: Calendar) -> Date {
    let parts = value.split(separator: "-").compactMap { Int($0) }
    var components = DateComponents()
    components.year = parts[0]
    components.month = parts[1]
    components.day = parts[2]
    components.hour = 12
    return calendar.date(from: components)!
}

/// File-level on purpose: a nested `func keepLines` captured by `@Sendable`
/// parse is a Swift 6 `SendableClosureCaptures` error.
func tokenStatsKeepLines(_ data: Data) -> [String] {
    guard let text = String(data: data, encoding: .utf8) else { return [] }
    return text.split(separator: "\n").map(String.init).filter { $0 == "keep" }
}
```

`TokenStatsChecks.swift` 先放本任务检查，并以 `func runTokenStatsChecks() async { runTokenStatsModelChecks() }` 为入口（后续任务往里加）：

```swift
import Foundation
import AgentHaloCore

func runTokenStatsModelChecks() {
    let calendar = tokenStatsUTCCalendar()
    let now = tokenStatsDate("2026-08-14", calendar: calendar)

    expect(TokenStatsWindow.previousDays, 30, "window days")
    expect(TokenStatsWindow.weekColumns, 5, "week columns")
    expect(TokenStatsWindow.dayKey(from: now, calendar: calendar), "2026-08-14", "day key")

    let since = TokenStatsWindow.sinceDate(now: now, calendar: calendar)
    expect(TokenStatsWindow.dayKey(from: since, calendar: calendar), "2026-07-15", "since is today-30")
    expect(since, calendar.startOfDay(for: since), "since is start of day")

    let justInside = since
    let justOutside = since.addingTimeInterval(-1)
    expect(justInside >= since, true, "earliest midnight is included")
    expect(justOutside >= since, false, "one second before window is excluded")

    var accumulator = DailyTokenAccumulator()
    accumulator.add(day: "2026-08-14", tokens: 100)
    accumulator.add(day: "2026-08-14", tokens: 40)
    accumulator.add(day: "2026-08-13", tokens: 10)
    let days = accumulator.days()
    expect(days.first(where: { $0.date == "2026-08-14" })?.totalTokens, 140, "same day sums")
    expect(TokenStatsPresentation.todayTokens(days: days, now: now, calendar: calendar), 140, "today")
    expect(TokenStatsPresentation.last31DaysTokens(days: days), 150, "period")
    expect(TokenStatsPresentation.todayTokens(days: [], now: now, calendar: calendar), nil, "missing today is nil")
    expect(TokenStatsPresentation.last31DaysTokens(days: []), nil, "empty period is nil")

    expect(TokenCountFormatter.compact(38_000), "38k", "thousands")
    expect(TokenCountFormatter.compact(1_200), "1.2k", "fractional k")
    expect(TokenCountFormatter.compact(999), "999", "under 1000")
    expect(TokenCountFormatter.compact(1_500_000), "1.5M", "millions")
    expect(TokenCountFormatter.compact(1_000_000), "1M", "exact million")
    expect(TokenCountFormatter.compact(1_100_000_000), "1.1B", "billions")

    let cells = TokenHeatmapLayout.cells(
        days: [
            TokenDayTotals(date: "2026-08-14", totalTokens: 100),
            TokenDayTotals(date: "2026-08-13", totalTokens: 25)
        ],
        now: now,
        calendar: calendar
    )
    expect(cells.count, 35, "5x7")
    let today = cells.first(where: { $0.dayKey == "2026-08-14" })!
    expect(today.level, 4, "max day is top bucket")
    expect(today.isFuture, false, "today is not future")
    expect(today.isInWindow, true, "today in window")
    let quarter = cells.first(where: { $0.dayKey == "2026-08-13" })!
    expect(quarter.level, 1, "25/100 is first bucket")
    expect(cells.contains(where: { $0.isFuture }), true, "current week has future days")
    expect(cells.filter(\.isFuture).allSatisfy { $0.level == 0 }, true, "future days hollow")
    // 2026-08-14 周五；firstWeekday=周一 → 本周 Mon 8/10–Sun 8/16，
    // 5 列从 2026-07-13 起。窗口 since=07-15，故 07-13/07-14 在网格内但窗外。
    let beforeWindow = cells.first(where: { $0.dayKey == "2026-07-13" })!
    expect(beforeWindow.isInWindow, false, "grid day before 31-day window is outside")
    expect(beforeWindow.level, 0, "outside window hollow")
    expect(beforeWindow.isFuture, false, "July 13 is not future")
}

func runTokenStatsChecks() async {
    runTokenStatsModelChecks()
}
```

`main.swift` 在 `await runUsageModelChecks()` 后加 `await runTokenStatsChecks()`。

- [ ] **Step 2: Run test to verify it fails**

Run: `cd src/macos && swift run AgentHaloCoreChecks`

Expected: FAIL，找不到 `TokenStatsWindow` / `TokenCountFormatter` / `TokenHeatmapLayout`。

- [ ] **Step 3: Write minimal implementation**

`TokenStatsModels.swift`：实现规格里的 `TokenDayTotals`、`TokenStatsSnapshot`、`TokenStatsStatus`、`TokenLogScanResult`、`TokenLogScanning`，以及：

```swift
public enum TokenStatsWindow {
    public static let previousDays = 30
    public static let weekColumns = 5

    public static func dayKey(from date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    public static func sinceDate(now: Date, calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: -previousDays, to: today) ?? today
    }
}

public enum TokenStatsPresentation {
    public static func todayTokens(days: [TokenDayTotals], now: Date, calendar: Calendar) -> Int64? {
        let key = TokenStatsWindow.dayKey(from: now, calendar: calendar)
        let total = days.first(where: { $0.date == key })?.totalTokens ?? 0
        return total > 0 ? total : nil
    }

    public static func last31DaysTokens(days: [TokenDayTotals]) -> Int64? {
        let total = days.reduce(Int64(0)) { $0 + $1.totalTokens }
        return total > 0 ? total : nil
    }
}
```

`DailyTokenAccumulator.swift`：`add(day:tokens:)` 累加，`days()` 返回 `totalTokens > 0` 的条目。

`TokenCountFormatter.swift`：按规格四档；`< 1000` 原样；否则用 `en_US_POSIX` 一位小数，整除不写小数。单位 `k` / `M` / `B`。

`TokenHeatmapLayout.swift`：从「今天所在周」往左 4 周，共 5 列；每周 7 天从 `firstWeekday` 起。`isInWindow` 用同一个 calendar 的 `TokenStatsWindow.sinceDate...today`。`level`：`tokens == 0` 或窗外或未来 → 0；否则按相对**窗口内**最大日用量 `(0,0.25]=1 … (0.75,1]=4`（窗外日不参与 max）。

`DailyTokenAccumulator.add` 只接收扫描器已经用 `timestamp >= since` 滤过的行；`last31DaysTokens` 对传入数组求和即可。

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `cd src/macos && swift run AgentHaloCoreChecks`

Expected: `PASS AgentHaloCore checks`

- [ ] **Step 5: Commit**

```bash
git add src/macos/Sources/AgentHaloCore/TokenStats/TokenStatsModels.swift \
  src/macos/Sources/AgentHaloCore/TokenStats/DailyTokenAccumulator.swift \
  src/macos/Sources/AgentHaloCore/TokenStats/TokenCountFormatter.swift \
  src/macos/Sources/AgentHaloCore/TokenStats/TokenHeatmapLayout.swift \
  src/macos/Sources/AgentHaloCoreChecks/TokenStatsChecks.swift \
  src/macos/Sources/AgentHaloCoreChecks/TokenStatsCheckSupport.swift \
  src/macos/Sources/AgentHaloCoreChecks/main.swift
git commit -m "feat(macos): add token-stats window models and heatmap layout"
```

---

### Task 2: 路径与成功快照落盘

**Files:**
- Modify: `src/macos/Sources/AgentHaloCore/AgentHaloPaths.swift`
- Modify: `src/macos/Sources/AgentHaloCoreChecks/main.swift`（`testAgentHaloPathsLayoutV2`）
- Create: `src/macos/Sources/AgentHaloCore/TokenStats/TokenStatsSnapshotStore.swift`
- Modify: `src/macos/Sources/AgentHaloCoreChecks/TokenStatsChecks.swift`

**Interfaces:**
- Consumes: `TokenStatsSnapshot`、`AgentKind`、`AgentHaloPaths.cacheDirectory`
- Produces: `AgentHaloPaths.tokenStatsSnapshots`、`AgentHaloPaths.logScanCacheDirectory`、`TokenStatsSnapshotStore.load/save`

- [ ] **Step 1: Write the failing checks**

在 `testAgentHaloPathsLayoutV2` 末尾加：

```swift
expect(
    paths.tokenStatsSnapshots.path,
    root.appendingPathComponent("cache", isDirectory: true).appendingPathComponent("token-stats-v1.json").path,
    "token stats snapshots"
)
expect(
    paths.logScanCacheDirectory,
    root.appendingPathComponent("cache", isDirectory: true).appendingPathComponent("log-scan", isDirectory: true),
    "log scan cache dir"
)
```

在 `runTokenStatsChecks` 增加 `try await runTokenStatsSnapshotStoreChecks()`：

```swift
func runTokenStatsSnapshotStoreChecks() async throws {
    let fm = FileManager.default
    let home = fm.temporaryDirectory.appendingPathComponent("token-stats-store-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: home) }
    let paths = AgentHaloPaths(homeDirectory: home)
    try fm.createDirectory(at: paths.cacheDirectory, withIntermediateDirectories: true)
    let now = Date(timeIntervalSince1970: 1_800_000_000) // 2027-01-15
    let store = TokenStatsSnapshotStore(paths: paths, now: { now })

    expect(store.load(agent: .codex), nil, "missing file is nil")

    let snap = TokenStatsSnapshot(
        agent: .codex,
        days: [TokenDayTotals(date: "2026-08-14", totalTokens: 12)],
        scannedAt: now
    )
    try store.save(snap)
    expect(store.load(agent: .codex)?.days.first?.totalTokens, 12, "round trip")
    expect(store.load(agent: .claudeCode), nil, "agents isolated")

    var attrs = try fm.attributesOfItem(atPath: paths.tokenStatsSnapshots.path)
    let mode = (attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
    expect(mode, 0o600, "snapshot file is 0600")

    let stale = TokenStatsSnapshot(
        agent: .grok,
        days: [TokenDayTotals(date: "2026-01-01", totalTokens: 1)],
        scannedAt: now.addingTimeInterval(-31 * 24 * 60 * 60)
    )
    try store.save(stale)
    expect(store.load(agent: .grok), nil, "entries older than 30 days dropped")
    expect(store.load(agent: .codex)?.days.isEmpty, false, "fresh agent kept")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd src/macos && swift run AgentHaloCoreChecks`

Expected: FAIL，`tokenStatsSnapshots` 不存在。

- [ ] **Step 3: Write minimal implementation**

`AgentHaloPaths` 增加：

```swift
public var tokenStatsSnapshots: URL {
    cacheDirectory.appendingPathComponent("token-stats-v1.json")
}
public var logScanCacheDirectory: URL {
    cacheDirectory.appendingPathComponent("log-scan", isDirectory: true)
}
```

`TokenStatsSnapshotStore`：

```swift
public struct TokenStatsSnapshotStore: Sendable {
    public init(paths: AgentHaloPaths, now: @escaping @Sendable () -> Date = Date.init)
    public func load(agent: AgentKind) -> TokenStatsSnapshot?
    public func save(_ snapshot: TokenStatsSnapshot) throws
}
```

JSON `{ "schemaVersion": 1, "agents": { "<AgentKind.rawValue>": { "days": [...], "scannedAt": ... } } }`。`load` 丢掉 `scannedAt < now-30d` 的条目。`save` 合并该 agent、原子写、`0600`。不写路径或行内容。空结果（`days: []`）也要能 round-trip，供 coordinator 把权威 `empty` 留下。

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `cd src/macos && swift run AgentHaloCoreChecks`

Expected: `PASS AgentHaloCore checks`

- [ ] **Step 5: Commit**

```bash
git add src/macos/Sources/AgentHaloCore/AgentHaloPaths.swift \
  src/macos/Sources/AgentHaloCore/TokenStats/TokenStatsSnapshotStore.swift \
  src/macos/Sources/AgentHaloCoreChecks/main.swift \
  src/macos/Sources/AgentHaloCoreChecks/TokenStatsChecks.swift
git commit -m "feat(macos): persist per-agent token-stats snapshots"
```

---

### Task 3: 增量 JSONL 扫描与解析缓存

**Files:**
- Create: `src/macos/Sources/AgentHaloCore/TokenStats/JSONLScanning.swift`
- Create: `src/macos/Sources/AgentHaloCore/TokenStats/JSONLScanCacheStore.swift`
- Create: `src/macos/Sources/AgentHaloCore/TokenStats/IncrementalJSONLScanner.swift`
- Modify: `src/macos/Sources/AgentHaloCoreChecks/TokenStatsChecks.swift`

**Interfaces:**
- Consumes: `AgentHaloPaths.logScanCacheDirectory`
- Produces: `JSONLScanning.sinceDate/jsonlFiles`、`IncrementalJSONLScanner.items`（取消 → `nil`；完成无行 → `[]`）

`IncrementalJSONLScanner` 是 `actor`。`items` 签名必须让 Task 3 取消检查能编过：

```swift
func items(
    from files: [JSONLScanning.DiscoveredFile],
    since: Date,
    cacheIdentity: String,
    parse: @Sendable @escaping (Data) async -> [Item]
) async -> [Item]?
```

`parse` **必须是 `async`**。同步 `(Data) -> [Item]` 无法在闭包里 `await gate.waitUntilCancelled()`。parse 返回后若 `Task.isCancelled`，整次 `items` 仍是 `nil`，不得把 `["x"]` 拼进结果。

- [ ] **Step 1: Write the failing checks**

```swift
func runIncrementalJSONLScannerChecks() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("jsonl-scan-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: root) }
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("a.jsonl")
    try "keep\nskip\nkeep\n".write(to: file, atomically: true, encoding: .utf8)

    let discovered = JSONLScanning.jsonlFiles(under: root)
    expect(discovered.count, 1, "discovers jsonl")

    // parse 是 @Sendable：禁止 mutate 局部 var；禁止嵌套 func（SendableClosureCaptures）。
    // 用文件级 tokenStatsKeepLines + 现网 LockedBox。
    let parseCount = LockedBox(0)
    let scanner = IncrementalJSONLScanner<String>(
        cacheDirectory: root.appendingPathComponent("cache", isDirectory: true),
        namespace: "test",
        schemaVersion: 1
    )
    let first = await scanner.items(from: discovered, since: .distantPast, cacheIdentity: "home") { data in
        parseCount.withValue { $0 += 1 }
        return tokenStatsKeepLines(data)
    }
    expect(first, ["keep", "keep"], "parses lines")
    expect(parseCount.value, 1, "first pass parses")

    parseCount.withValue { $0 = 0 }
    let second = await scanner.items(from: discovered, since: .distantPast, cacheIdentity: "home") { _ in
        parseCount.withValue { $0 += 1 }
        return ["should-not-run"]
    }
    expect(second, ["keep", "keep"], "cache hit")
    expect(parseCount.value, 0, "unchanged file not reparsed")

    try "keep\n".write(to: file, atomically: true, encoding: .utf8)
    parseCount.withValue { $0 = 0 }
    let third = await scanner.items(from: discovered, since: .distantPast, cacheIdentity: "home") { data in
        parseCount.withValue { $0 += 1 }
        return tokenStatsKeepLines(data)
    }
    expect(parseCount.value, 1, "mtime/size change reparses")
    expect(third, ["keep"], "new contents")

    let old = root.appendingPathComponent("old.jsonl")
    try "ancient\n".write(to: old, atomically: true, encoding: .utf8)
    try fm.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: 10)],
        ofItemAtPath: old.path
    )
    let parsedAncient = LockedBox(0)
    _ = await scanner.items(
        from: JSONLScanning.jsonlFiles(under: root),
        since: Date(timeIntervalSince1970: 100),
        cacheIdentity: "window"
    ) { data in
        if String(data: data, encoding: .utf8)?.contains("ancient") == true {
            parsedAncient.withValue { $0 += 1 }
        }
        return []
    }
    expect(parsedAncient.value, 0, "mtime older than since is not parsed")

    let gate = TokenStatsCancelGate()
    let cancelTask = Task { () -> [String]? in
        await scanner.items(from: discovered, since: .distantPast, cacheIdentity: "cancel") { _ in
            await gate.waitUntilCancelled()
            return ["x"]
        }
    }
    await gate.markReady()
    cancelTask.cancel()
    expect(await cancelTask.value, nil, "cancel is nil, never []")
}
```

`TokenStatsCancelGate` 放在 `TokenStatsCheckSupport.swift`：actor，`markReady()` 放行，`waitUntilCancelled()` 等到 `Task.isCancelled`。`items` 在 `parse` 期间看到取消必须把整次扫描收成 `nil`，不能把 `["x"]` 拼进结果。

- [ ] **Step 2: Run test to verify it fails**

Run: `cd src/macos && swift run AgentHaloCoreChecks`

Expected: FAIL，找不到 `IncrementalJSONLScanner`。

- [ ] **Step 3: Write minimal implementation**

`JSONLScanning`：`sinceDate` 委托 `TokenStatsWindow.sinceDate`；`jsonlFiles(under:)` 先 `resolvingSymlinksInPath`，递归收 `*.jsonl` 正规文件，带 `size`/`mtime`，按 path 排序。

`IncrementalJSONLScanner<Item: Codable & Sendable>` 是 actor：

- 缓存键 `path + size + mtime`
- `mtime < since` 跳过
- 未变化复用；变化则读文件并 `await parse`
- 读失败：该文件不缓存，其它文件继续
- `Task.isCancelled`（进入 `items`、每个文件 parse 之后、拼结果之前）→ 返回 `nil`（区别于 `[]`）
- 最多 8 路并发
- 变更后把 record 写到 `cacheDirectory/<namespace>-<fnv1a(identity)>/`，`schemaVersion` 不匹配则整仓作废
- 权限 `0600`

不必移植 OpenUsage 的多账户 waiter；Halo 同一时刻只扫一个 Agent。

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `cd src/macos && swift run AgentHaloCoreChecks`

Expected: `PASS AgentHaloCore checks`

- [ ] **Step 5: Commit**

```bash
git add src/macos/Sources/AgentHaloCore/TokenStats/JSONLScanning.swift \
  src/macos/Sources/AgentHaloCore/TokenStats/JSONLScanCacheStore.swift \
  src/macos/Sources/AgentHaloCore/TokenStats/IncrementalJSONLScanner.swift \
  src/macos/Sources/AgentHaloCoreChecks/TokenStatsChecks.swift
git commit -m "feat(macos): add incremental JSONL parse cache for token stats"
```

---

### Task 4: Codex 日志扫描器

**Files:**
- Create: `src/macos/Sources/AgentHaloCore/TokenStats/CodexTokenLogScanner.swift`
- Modify: `src/macos/Sources/AgentHaloCoreChecks/TokenStatsChecks.swift`
- Modify: `src/macos/Sources/AgentHaloCoreChecks/TokenStatsCheckSupport.swift`（Codex fixture 行）

**Interfaces:**
- Consumes: `TokenLogScanning`、`IncrementalJSONLScanner`、`DailyTokenAccumulator`、`UsageEnvironmentReading`
- Produces: `CodexTokenLogScanner.scan`、`CodexTokenLogScanner.parseFile`（public，供检查）

语义必须对齐 `/Users/wjs/work/ossp/openusage/Sources/OpenUsage/Providers/Codex/CodexLogUsageScanner.swift` 的去重，但只累加 token、不计价。

- [ ] **Step 1: Write the failing checks**

复用 `FakeUsageEnvironment`。在临时目录建 `sessions/`，用 `CODEX_HOME` 指向它。`now` 固定为 `2026-08-14T18:00:00Z`。

`token_count` 行模板（写进 `TokenStatsCheckSupport.swift` 的 `codexTokenCountLine(...)`）：

```text
{"timestamp":"<ts>","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":<in>,"cached_input_tokens":<c>,"output_tokens":<out>,"reasoning_output_tokens":<r>,"total_tokens":<tot>},"last_token_usage":{...optional}}}}
```

检查函数（均 `async`，断言 `.scanned` 里 `2026-08-14` 的合计）：

1. totals=100、last=7 → 日合计 7
2. 两行 totals 完全相同、第二行仍带 last=7 → 日合计仍是第一行那一次
3. 子会话文件：首行 `session_meta` `forked_from_id":"parent"` `timestamp` 为 T；接着回放 `token_count` last=50；再 `task_started.started_at` ≥ T；再 live `token_count` last=9 → 日合计 9
4. `forked_from_id: null` + last=9 → 日合计 9
5. `sessions/a.jsonl` last=9 与 `archived_sessions/a.jsonl` last=90 → 日合计 9
6. 两个不同相对路径文件写入完全相同的一行 last=9 → 日合计 9
7. `CODEX_HOME` 指向不存在的目录 → `.missingRoot`

调用：`CodexTokenLogScanner(environment:env, homeDirectory:{ homeURL }).scan(now: now)`。

- [ ] **Step 2: Run test to verify it fails**

Run: `cd src/macos && swift run AgentHaloCoreChecks`

Expected: FAIL，找不到 `CodexTokenLogScanner`。

- [ ] **Step 3: Write minimal implementation**

发现：`$CODEX_HOME` 逗号分隔，否则 `~/.codex`；扫 `sessions/` 与 `archived_sessions/`，同相对路径 sessions 赢；都没有则扫 home。跟随 symlink。

`parseFile`：只处理 `turn_context` / `session_meta` / `task_started` / `token_count`。delta 与子会话闸门按规格与 OpenUsage。发出的 event 用 `DailyTokenAccumulator.add`。`cached = min(cached, input)`。`total` 优先日志 `total_tokens`。

`scan`：无 home/无文件 → `.missingRoot`；取消 → `.cancelled`；有文件但窗口内 0 → `.scanned([])`。

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `cd src/macos && swift run AgentHaloCoreChecks`

Expected: `PASS AgentHaloCore checks`

- [ ] **Step 5: Commit**

```bash
git add src/macos/Sources/AgentHaloCore/TokenStats/CodexTokenLogScanner.swift \
  src/macos/Sources/AgentHaloCoreChecks/TokenStatsChecks.swift \
  src/macos/Sources/AgentHaloCoreChecks/TokenStatsCheckSupport.swift
git commit -m "feat(macos): scan Codex rollouts for daily token totals"
```

---

### Task 5: Claude 日志扫描器

**Files:**
- Create: `src/macos/Sources/AgentHaloCore/TokenStats/ClaudeTokenLogScanner.swift`
- Modify: `src/macos/Sources/AgentHaloCoreChecks/TokenStatsChecks.swift`

**Interfaces:**
- Consumes: `TokenLogScanning`、`IncrementalJSONLScanner`、`DailyTokenAccumulator`、`FakeUsageEnvironment`、`TokenStatsWindow`
- Produces: `ClaudeTokenLogScanner.scan`、`ClaudeTokenLogScanner.parseFile`、`ClaudeTokenLogScanner.dedup`

对齐 `/Users/wjs/work/ossp/openusage/Sources/OpenUsage/Providers/Claude/ClaudeLogUsageScanner.swift`，不计价。Cowork 目录本期不扫。

- [ ] **Step 1: Write the failing checks**

1. `total = input + cache5m + cache1h + cacheRead + output`
2. 跨文件相同 `(message.id, requestId)` 去重
3. sidechain 换 requestId 重放同一 message.id → 留非 sidechain
4. `advisor_message` 另计；普通 iteration 不计
5. `speed: "turbo"` 整行丢
6. 含 `"costUSD":null` 等 unsupported null 字段的行丢
7. 有 `costUSD` 数字仍按分桶加 token
8. 无 `projects/` 的 config dir → `.missingRoot`

- [ ] **Step 2: Run test to verify it fails**

Run: `cd src/macos && swift run AgentHaloCoreChecks`

Expected: FAIL，找不到 `ClaudeTokenLogScanner`。

- [ ] **Step 3: Write minimal implementation**

根：`$CLAUDE_CONFIG_DIR` 或 `~/.config/claude` + `~/.claude`，且必须有 `projects/`。只扫 `projects/**/*.jsonl`。`unsupportedNullableFields` 与 OpenUsage 相同。`dedup` / `shouldReplace` 按规格。

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `cd src/macos && swift run AgentHaloCoreChecks`

Expected: `PASS AgentHaloCore checks`

- [ ] **Step 5: Commit**

```bash
git add src/macos/Sources/AgentHaloCore/TokenStats/ClaudeTokenLogScanner.swift \
  src/macos/Sources/AgentHaloCoreChecks/TokenStatsChecks.swift
git commit -m "feat(macos): scan Claude project logs for daily token totals"
```

---

### Task 6: Grok 与 Pi 扫描器

**Files:**
- Create: `src/macos/Sources/AgentHaloCore/TokenStats/GrokTokenLogScanner.swift`
- Create: `src/macos/Sources/AgentHaloCore/TokenStats/PiTokenLogScanner.swift`
- Modify: `src/macos/Sources/AgentHaloCoreChecks/TokenStatsChecks.swift`

**Interfaces:**
- Produces: `GrokTokenLogScanner`、`PiTokenLogScanner`，均符合 `TokenLogScanning`

- [ ] **Step 1: Write the failing checks**

Grok：

1. 只认 `msg == "shell.turn.inference_done"`
2. `total = prompt + completion + reasoning`；`cached_prompt_tokens` 不重复加
3. 读 `$GROK_HOME/logs/unified.jsonl`
4. 同目录放一个带 `totalTokens` 的 `updates.jsonl` fixture，断言不计入
5. 无模型字段仍计入
6. 文件不存在 → `.missingRoot`

Pi：

1. assistant `usage.totalTokens` 优先，否则 `input+output+cacheRead+cacheWrite`
2. 同一 `id` 出现两次只计一次
3. `agent == .pi`
4. 目录不存在 → `.missingRoot`

- [ ] **Step 2: Run test to verify it fails**

Run: `cd src/macos && swift run AgentHaloCoreChecks`

Expected: FAIL，找不到两个 scanner。

- [ ] **Step 3: Write minimal implementation**

Grok：整文件扫描。把 `{path,size,mtime,days}` 写到 `log-scan` 下的小 JSON（例如 `grok-<fingerprint>.json`，`0600`）。下次 size+mtime 未变则不再读 `unified.jsonl`。不解析模型。`updates.jsonl` 即使同目录存在也绝不打开。

Pi：用 `IncrementalJSONLScanner`，目录 `$PI_CODING_AGENT_SESSION_DIR` 或 `~/.pi/agent/sessions`。

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `cd src/macos && swift run AgentHaloCoreChecks`

Expected: `PASS AgentHaloCore checks`

- [ ] **Step 5: Commit**

```bash
git add src/macos/Sources/AgentHaloCore/TokenStats/GrokTokenLogScanner.swift \
  src/macos/Sources/AgentHaloCore/TokenStats/PiTokenLogScanner.swift \
  src/macos/Sources/AgentHaloCoreChecks/TokenStatsChecks.swift
git commit -m "feat(macos): scan Grok and Pi native logs for daily tokens"
```

---

### Task 7: TokenStatsCoordinator

**Files:**
- Create: `src/macos/Sources/AgentHaloCore/TokenStats/TokenStatsCoordinator.swift`
- Modify: `src/macos/Sources/AgentHaloCoreChecks/TokenStatsChecks.swift`
- Modify: `src/macos/Sources/AgentHaloCoreChecks/TokenStatsCheckSupport.swift`（`FakeTokenLogScanner`、`TokenStatsScanHold`）

**Interfaces:**
- Consumes: `TokenLogScanning`、`TokenStatsSnapshotStore`、`TokenLogScanResult`
- Produces: `TokenStatsCoordinator.prepare/ensureFresh/state/cancelAll`

- [ ] **Step 1: Write the failing checks**

`FakeTokenLogScanner` 放进 `TokenStatsCheckSupport.swift`。必须是 class，不能是 actor：

```swift
final class FakeTokenLogScanner: TokenLogScanning, @unchecked Sendable {
    let agent: AgentKind
    private let lock = NSLock()
    private var storedResult: TokenLogScanResult
    private var storedCalls = 0
    private var hold: (@Sendable () async -> Void)?

    init(
        agent: AgentKind,
        result: TokenLogScanResult,
        hold: (@Sendable () async -> Void)? = nil
    ) {
        self.agent = agent
        self.storedResult = result
        self.hold = hold
    }

    var result: TokenLogScanResult {
        get { lock.lock(); defer { lock.unlock() }; return storedResult }
        set { lock.lock(); storedResult = newValue; lock.unlock() }
    }

    var calls: Int {
        lock.lock(); defer { lock.unlock() }; return storedCalls
    }

    func setHold(_ hold: (@Sendable () async -> Void)?) {
        lock.lock(); self.hold = hold; lock.unlock()
    }

    func scan(now: Date) async -> TokenLogScanResult {
        lock.lock(); storedCalls += 1; let hold = self.hold; lock.unlock()
        if let hold { await hold() }
        return result
    }
}
```

`TokenStatsScanHold`（同文件）。禁止忙等 `Task.sleep` 轮询：

```swift
actor TokenStatsScanHold {
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enterAndWait() async {
        entered = true
        enteredWaiters.forEach { $0.resume() }
        enteredWaiters.removeAll()
        if released { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}
```

即时返回的 fake 即可覆盖：

1. `prepare` 无缓存 → `.empty`，且 `calls == 0`
2. `save` 后 `prepare` → `.ready`，仍不扫
3. 磁盘 `ready` 后第一次 `ensureFresh` 仍扫（不算 fresh）
4. 本进程成功扫完 5 分钟内第二次 `ensureFresh` 不扫
5. `scanned([])` / `missingRoot` → `.empty` 并落盘，再次 `prepare` 仍 empty
6. 先 `ready`，再 `failed` → 仍 `ready` 旧快照
8. 两个 agent 的 scanner 互不覆盖
9. `isPaused == true` 时 `ensureFresh` 不调用 `scan`
10. 同 agent 并发两次 `ensureFresh` 只扫一次

第 7、11 条必须挂起，否则看不到中间态：

```swift
func runTokenStatsCoordinatorHoldChecks() async throws {
    let fm = FileManager.default
    let home = fm.temporaryDirectory.appendingPathComponent("token-stats-coord-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: home) }
    let paths = AgentHaloPaths(homeDirectory: home)
    try fm.createDirectory(at: paths.cacheDirectory, withIntermediateDirectories: true)
    let clock = LockedBox(tokenStatsDate("2026-08-14", calendar: tokenStatsUTCCalendar()))
    let store = TokenStatsSnapshotStore(paths: paths, now: { clock.value })

    let firstHold = TokenStatsScanHold()
    let scanner = FakeTokenLogScanner(
        agent: .codex,
        result: .scanned([TokenDayTotals(date: "2026-08-14", totalTokens: 10)]),
        hold: { await firstHold.enterAndWait() }
    )
    let coordinator = TokenStatsCoordinator(
        scanners: [scanner],
        store: store,
        now: { clock.value }
    )

    let first = Task { await coordinator.ensureFresh(.codex) }
    await firstHold.waitUntilEntered()
    expect(await coordinator.state(for: .codex), .scanning, "first in-flight scan is scanning")
    await firstHold.release()
    let ready = await first.value
    guard case .ready(let snap) = ready else {
        fatalError("first scan should become ready")
    }
    expect(snap.days.first?.totalTokens, 10, "ready snapshot")

    // 本进程成功扫完 5 分钟内 ensureFresh 不进 scan。必须把 now 推过窗口，
    // 否则 cancelHold.waitUntilEntered 会永远等。
    clock.withValue { $0 = $0.addingTimeInterval(5 * 60 + 1) }
    let cancelHold = TokenStatsScanHold()
    scanner.setHold { await cancelHold.enterAndWait() }
    scanner.result = .cancelled
    let second = Task { await coordinator.ensureFresh(.codex) }
    await cancelHold.waitUntilEntered()
    await coordinator.cancelAll()
    await cancelHold.release()
    _ = await second.value
    guard case .ready(let kept) = await coordinator.state(for: .codex) else {
        fatalError("cancel must keep the previous ready snapshot")
    }
    expect(kept.days.first?.totalTokens, 10, "cancel is not empty")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd src/macos && swift run AgentHaloCoreChecks`

Expected: FAIL，找不到 `TokenStatsCoordinator`。

- [ ] **Step 3: Write minimal implementation**

按规格实现 actor。`fresh` 只认本进程 `ensureFresh` 成功写入的时间。磁盘加载只用于 `prepare` 展示。同 agent 一个 in-flight Task。`cancelAll()` 是 `async`：取消 in-flight 并 `await` 它们结束，吞掉 `.cancelled`，不把状态改成 `.empty`。无快照时必须在 `await scanner.scan` **之前** 把 `state` 写成 `.scanning`，否则挂起检查看不到中间态。

同时提供：

```swift
extension TokenStatsCoordinator {
    public static func live(
        paths: AgentHaloPaths = AgentHaloPaths(),
        environment: any UsageEnvironmentReading = ProcessInfoUsageEnvironment(),
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser },
        now: @escaping @Sendable () -> Date = Date.init,
        isPaused: @escaping @Sendable () -> Bool = { false }
    ) -> TokenStatsCoordinator
}
```

环境读复用已有 `ProcessInfoUsageEnvironment`。`.live()` 组装四个真实 scanner + `TokenStatsSnapshotStore(paths:)`。

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `cd src/macos && swift run AgentHaloCoreChecks`

Expected: `PASS AgentHaloCore checks`

- [ ] **Step 5: Commit**

```bash
git add src/macos/Sources/AgentHaloCore/TokenStats/TokenStatsCoordinator.swift \
  src/macos/Sources/AgentHaloCoreChecks/TokenStatsChecks.swift \
  src/macos/Sources/AgentHaloCoreChecks/TokenStatsCheckSupport.swift
git commit -m "feat(macos): coordinate focused-agent token-stat refreshes"
```

---

### Task 8: Locale、紧凑数字接到详情面板

**Files:**
- Modify: `src/shared/locales/en.json`
- Modify: `src/shared/locales/zh.json`
- Modify: `src/macos/Sources/AgentHaloCore/locales/en.json`
- Modify: `src/macos/Sources/AgentHaloCore/locales/zh.json`
- Modify: `src/macos/Sources/AgentHaloMac/DetailsPanel.swift`（`compactTokenCount` 改调 `TokenCountFormatter`）
- Modify: `src/macos/Sources/AgentHaloMac/HaloInteractionChecks.swift`

**Interfaces:**
- Consumes: `TokenCountFormatter.compact`
- Produces: locale keys；会话卡 ≥1M 显示 `1.5M`

Locale：

| key | en | zh |
| --- | --- | --- |
| `tokens.summary.today` | `Today` | `今日` |
| `tokens.summary.period` | `30d` | `30天` |
| `tokens.cell.date` | `MMM d` | `M月d日` |
| `tokens.cell.tooltip` | `{0} · {1} tokens` | `{0} · {1} tokens` |
| `tokens.page.show_stats` | `Show token stats` | `显示 Token 统计` |
| `tokens.page.show_default` | `Show status details` | `显示状态详情` |

- [ ] **Step 1: Write the failing check**

在 `HaloInteractionChecks.swift` 增加：

```swift
@MainActor
private func testCompactTokenCountUsesMillionsAndKeepsThousands() {
    expect(DetailsPanel.compactTokenCount(38_000), "38k", "thousands unchanged")
    expect(DetailsPanel.compactTokenCount(1_500_000), "1.5M", "millions")
    expect(DetailsPanel.compactTokenCount(nil), "--", "nil stays placeholder on session card")
}
```

并在 `runHaloInteractionChecks()` 里调用。现网 `compactTokenCount(1_500_000)` 是 `1500k`，检查应失败。

- [ ] **Step 2: Run test to verify it fails**

Run: `cd src/macos && swift run AgentHaloMac --self-check`

Expected: FAIL，`1500k` vs `1.5M`。

- [ ] **Step 3: Write minimal implementation**

```swift
static func compactTokenCount(_ count: Int64?) -> String {
    guard let count else { return "--" }
    return TokenCountFormatter.compact(count)
}
```

写入四份 locale。四份必须同 key。

- [ ] **Step 4: Run the tests and make sure they pass**

Run:

```bash
cd src/macos
swift run AgentHaloCoreChecks
swift run AgentHaloMac --self-check
```

Expected: 两处 PASS。

- [ ] **Step 5: Commit**

```bash
git add src/shared/locales/en.json src/shared/locales/zh.json \
  src/macos/Sources/AgentHaloCore/locales/en.json \
  src/macos/Sources/AgentHaloCore/locales/zh.json \
  src/macos/Sources/AgentHaloMac/DetailsPanel.swift \
  src/macos/Sources/AgentHaloMac/HaloInteractionChecks.swift
git commit -m "feat(macos): format token totals with M/B and add token-stats strings"
```

---

### Task 9: 详情面板翻页、摘要与热力

**Files:**
- Modify: `src/macos/Sources/AgentHaloMac/DetailsPanel.swift`
- Modify: `src/macos/Sources/AgentHaloMac/HaloInteractionChecks.swift`

**Interfaces:**
- Consumes: `TokenStatsStatus`、`TokenHeatmapLayout`、`TokenStatsPresentation`、`TokenCountFormatter`
- Produces: `DetailsPanel.render(..., tokenStats:)`；测试钩子见下

`render` 现有签名保持 `aggregate` + `model`，增加 `tokenStats: TokenStatsStatus = .empty`。翻页是面板私有状态。

**必须改的 inset：** `init` 里 `edgeInsets` 改为 `top: 6, left: 17, bottom: 12, right: 17`。`render` 里两处 `stack.edgeInsets.bottom = 4` **删掉**，否则会盖掉 12pt 点槽。就地改现网 `testDetailsPanelUsesTightBottomInset`：查找条件从 `top == 14 && left == 17` 改成 `top == 6 && left == 17`，断言 `bottom == 12`。不改这条，自检会 `fatalError`（找不到 stack）。

**点的装法：** `PageDotsView` 加在 `contentView`/`NSVisualEffectView` 上，约束贴容器底边居中，高度 12。**不要** `stack.addArrangedSubview(dots)`。stack fitting height 只来自顶栏 + 标题 + 额度/会话/tokens 槽；点占用 inset 留白，不增加 arranged 高度。

新增测试钩子（public / internal for testing）：

```swift
var showsTokenStatsPageForTesting: Bool
var quotaGroupHiddenForTesting: Bool
func selectTokenStatsPageForTesting()
func selectDefaultPageForTesting()
var tokenSummaryTextForTesting: String
var heatmapCellCountForTesting: Int
var heatmapFilledCountForTesting: Int
func heatmapLevelForTesting(column: Int, row: Int) -> Int
var pageDotsFrameForTesting: CGRect
var weeklyMeterFrameInWindowForTesting: CGRect
var sessionCardFooterFrameInWindowForTesting: CGRect
```

- [ ] **Step 1: Write the failing checks**

```swift
@MainActor
private func testDetailsPanelInsetsLeaveRoomForPageDots() {
    let panel = DetailsPanel()
    guard let contentView = panel.contentView,
          let contentStack = allDescendants(of: contentView)
            .compactMap({ $0 as? NSStackView })
            .first(where: { $0.edgeInsets.left == 17 && $0.edgeInsets.top == 6 }) else {
        fatalError("details panel should expose its content stack")
    }
    expect(contentStack.edgeInsets.bottom, 12, "bottom inset hosts page dots")
    panel.render(aggregate: detailsAggregate(), model: usageDetailsModel(), tokenStats: .empty)
    panel.contentView?.layoutSubtreeIfNeeded()
    expect(panel.frameHeightForTesting, 172, "inset swap keeps fitted height")
}

@MainActor
private func testDetailsPanelOpensOnDefaultPageAndFlipsToTokenStats() {
    L10n.shared.setLanguage("zh")
    let panel = DetailsPanel()
    let snap = TokenStatsSnapshot(
        agent: .codex,
        days: [TokenDayTotals(date: TokenStatsWindow.dayKey(from: Date()), totalTokens: 1_500_000)],
        scannedAt: Date()
    )
    panel.render(
        aggregate: detailsAggregate(),
        model: usageDetailsModel(),
        tokenStats: .ready(snap)
    )
    panel.contentView?.layoutSubtreeIfNeeded()
    expect(panel.showsTokenStatsPageForTesting, false, "opens on quota page")
    expect(panel.quotaGroupHiddenForTesting, false, "quota visible")
    panel.selectTokenStatsPageForTesting()
    panel.contentView?.layoutSubtreeIfNeeded()
    expect(panel.showsTokenStatsPageForTesting, true, "flipped")
    expect(panel.tokenSummaryTextForTesting.contains("1.5M"), true, "today compact")
    expect(panel.heatmapCellCountForTesting, 35, "5x7")
    expect(panel.frameHeightForTesting, 172, "flip does not grow")
    expect(panel.frameWidthForTesting, 278, "flip does not widen")
}

@MainActor
private func testDetailsPanelTokenStatsKeepsFrameContract() {
    let panel = DetailsPanel()
    let windows = [
        UsageWindow(kind: .session, usedPercent: 20, resetsAt: Date().addingTimeInterval(3600), duration: 5 * 3600),
        UsageWindow(kind: .weekly, usedPercent: 40, resetsAt: Date().addingTimeInterval(86_400), duration: 7 * 86_400)
    ]
    let snap = TokenStatsSnapshot(
        agent: .codex,
        days: [TokenDayTotals(date: TokenStatsWindow.dayKey(from: Date()), totalTokens: 38_000)],
        scannedAt: Date()
    )
    panel.render(
        aggregate: detailsAggregate(),
        model: usageDetailsModel(windows: windows),
        tokenStats: .ready(snap)
    )
    panel.contentView?.layoutSubtreeIfNeeded()
    expect(panel.frameWidthForTesting, 278, "oauth default width")
    expect(panel.frameHeightForTesting, 172, "oauth default height")
    panel.selectTokenStatsPageForTesting()
    panel.contentView?.layoutSubtreeIfNeeded()
    expect(panel.frameWidthForTesting, 278, "oauth tokens width")
    expect(panel.frameHeightForTesting, 172, "oauth tokens height")

    panel.selectDefaultPageForTesting()
    panel.render(
        aggregate: detailsAggregate(agent: .claudeCode),
        model: sessionDetailsModel(session: SessionDetailsSnapshot(
            sessionTitle: "Card",
            modelName: "opus",
            inputTokens: 38_000,
            outputTokens: 1_200
        )),
        tokenStats: .ready(snap)
    )
    panel.contentView?.layoutSubtreeIfNeeded()
    expect(panel.frameWidthForTesting, 278, "session default width")
    expect(panel.frameHeightForTesting, 172, "session default height")
    panel.selectTokenStatsPageForTesting()
    panel.contentView?.layoutSubtreeIfNeeded()
    expect(panel.frameWidthForTesting, 278, "session tokens width")
    expect(panel.frameHeightForTesting, 172, "session tokens height")
}

@MainActor
private func testDetailsPanelHidesZeroTokenSummary() {
    let panel = DetailsPanel()
    panel.render(
        aggregate: detailsAggregate(),
        model: usageDetailsModel(),
        tokenStats: .empty
    )
    panel.selectTokenStatsPageForTesting()
    panel.contentView?.layoutSubtreeIfNeeded()
    // 整行隐藏。不要对拼接字符串做 contains("0")：locale「30d」/「30天」本身带 0。
    expect(panel.tokenSummaryTextForTesting, "", "empty status hides the whole summary row")
    expect(panel.heatmapCellCountForTesting, 35, "empty still draws 5x7")
    expect(panel.heatmapFilledCountForTesting, 0, "empty cells are hollow")
}

@MainActor
private func testDetailsPanelResetsTokenPageWhenAgentChanges() {
    let panel = DetailsPanel()
    let today = TokenStatsWindow.dayKey(from: Date())
    let codex = TokenStatsSnapshot(
        agent: .codex,
        days: [TokenDayTotals(date: today, totalTokens: 1_500_000)],
        scannedAt: Date()
    )
    let claude = TokenStatsSnapshot(
        agent: .claudeCode,
        days: [TokenDayTotals(date: today, totalTokens: 2_000)],
        scannedAt: Date()
    )
    panel.render(
        aggregate: detailsAggregate(agent: .codex),
        model: usageDetailsModel(),
        tokenStats: .ready(codex)
    )
    panel.selectTokenStatsPageForTesting()
    expect(panel.showsTokenStatsPageForTesting, true, "codex tokens visible")
    panel.render(
        aggregate: detailsAggregate(agent: .claudeCode),
        model: usageDetailsModel(provider: "Claude Code"),
        tokenStats: .ready(claude)
    )
    panel.contentView?.layoutSubtreeIfNeeded()
    expect(panel.showsTokenStatsPageForTesting, false, "agent change returns to default page")
    panel.selectTokenStatsPageForTesting()
    expect(panel.tokenSummaryTextForTesting.contains("1.5M") == false, "old Codex total is gone")
    expect(panel.tokenSummaryTextForTesting.contains("2k"), true, "Claude totals replaced Codex")
}

@MainActor
private func testDetailsPanelResetsTokenPageWhenHidden() {
    let panel = DetailsPanel()
    panel.render(
        aggregate: detailsAggregate(),
        model: usageDetailsModel(),
        tokenStats: .empty
    )
    panel.selectTokenStatsPageForTesting()
    expect(panel.showsTokenStatsPageForTesting, true, "flipped before hide")
    panel.orderOut(nil)
    expect(panel.showsTokenStatsPageForTesting, false, "orderOut resets to default page")
}

@MainActor
private func testDetailsPanelPageDotsDoNotCoverQuotaOrSessionFooter() {
    let panel = DetailsPanel()
    let windows = [
        UsageWindow(kind: .session, usedPercent: 20, resetsAt: Date().addingTimeInterval(3600), duration: 5 * 3600),
        UsageWindow(kind: .weekly, usedPercent: 40, resetsAt: Date().addingTimeInterval(86_400), duration: 7 * 86_400)
    ]
    panel.render(
        aggregate: detailsAggregate(),
        model: usageDetailsModel(windows: windows),
        tokenStats: .empty
    )
    panel.contentView?.layoutSubtreeIfNeeded()
    expect(
        panel.pageDotsFrameForTesting.intersects(panel.weeklyMeterFrameInWindowForTesting) == false,
        "dots must not cover the Weekly meter"
    )
    panel.render(
        aggregate: detailsAggregate(),
        model: sessionDetailsModel(session: SessionDetailsSnapshot(
            sessionTitle: "Card",
            modelName: "opus",
            inputTokens: 100,
            outputTokens: 20
        )),
        tokenStats: .empty
    )
    panel.contentView?.layoutSubtreeIfNeeded()
    expect(
        panel.pageDotsFrameForTesting.intersects(panel.sessionCardFooterFrameInWindowForTesting) == false,
        "dots must not cover the session card footer"
    )
}

@MainActor
private func testDetailsPanelTokenPageDoesNotChangeHaloState() {
    let panel = DetailsPanel()
    let aggregate = detailsAggregate(state: .working, label: "EXECUTING")
    panel.render(aggregate: aggregate, model: usageDetailsModel(), tokenStats: .empty)
    let title = panel.titleTextForTesting
    panel.selectTokenStatsPageForTesting()
    panel.contentView?.layoutSubtreeIfNeeded()
    expect(panel.titleTextForTesting, title, "flip does not change status title")
    expect(panel.titleTextForTesting, "EXECUTING", "halo lifecycle label stays")
}
```

把它们挂进 `runHaloInteractionChecks()`。

- [ ] **Step 2: Run test to verify it fails**

Run: `cd src/macos && swift run AgentHaloMac --self-check`

Expected: FAIL，inset 仍是 14/4 或没有 tokens 页。

- [ ] **Step 3: Write minimal implementation**

- 底边 inset 放 `PageDotsView`（两圆，直径 4，间距 8；当前 45% 墨，另一 12%）。命中整条 12pt 带。左默认、右 tokens。VoiceOver 用两个 locale key。
- `tokenStatsGroup` **钉死 `heightAnchor = 70`**（与 `quotaGroup` 同槽）。摘要 14 + 间隙 4 + 热力 47 = 65，余 5pt 留在 70 槽内。禁止靠减 inset 或加高面板补齐。
- 切到 tokens 页时必须 `stack.setCustomSpacing(16, after: detailField)`。从会话页（spacing 11 + 75）切过来若仍用 11 + 70，拟合高会掉到 167。切回会话页恢复 11；切回额度页保持 16。
- 摘要行（左 Today、右 30d，`nil` 则藏该侧；都 nil 藏整行）+ `TokenHeatmapView`（5×7，格 5pt，隙 2pt，命中 7pt）。颜色按规格。有用量的格设 `toolTip` 为 `tokens.cell.tooltip`（日期用 `tokens.cell.date` + `date.culture`，**禁止** `date.other_format`）。空心格无 tooltip。热力一个 accessibility group。
- `scanning` / `empty`：摘要藏，35 格全空心。
- 切页：先藏 quota/metadata/tokenStats 再显示目标；不改高度、不动画。
- `render` 时若 `aggregate.focusedAgent` 变了，强制默认页并换数据。
- 面板隐藏重置默认页：覆盖 `orderOut`（或等价的实际隐藏入口）。`onMouseExited` 只回调 AppDelegate，`hideDetailsImmediately` 走 `orderOut`，只挂 mouseExited 测不到。
- 点不得与 70pt 主体槽重叠。

- [ ] **Step 4: Run the tests and make sure they pass**

Run:

```bash
cd src/macos
swift run AgentHaloCoreChecks
swift run AgentHaloMac --self-check
```

Expected: 两处 PASS；所有原有 172/278 检查仍过。

- [ ] **Step 5: Commit**

```bash
git add src/macos/Sources/AgentHaloMac/DetailsPanel.swift \
  src/macos/Sources/AgentHaloMac/HaloInteractionChecks.swift
git commit -m "feat(macos): flip details body to token heatmap without growing the panel"
```

---

### Task 10: AppDelegate 接入与暂停

**Files:**
- Modify: `src/macos/Sources/AgentHaloMac/AppDelegate.swift`
- Modify: `src/macos/Sources/AgentHaloMac/HaloInteractionChecks.swift`（含现网 `testUsageMonitoringLifecycleWiring` / `testUsageTerminationWaitsForCoordinatorCancellation`，不另起 runtime spy）

**Interfaces:**
- Consumes: `TokenStatsCoordinator`、`TokenStatsSnapshotStore`、四个 scanner
- Produces: 打开详情 / 切 Agent / 5 分钟循环调用 `ensureFresh`；`render` 传入当前焦点状态

- [ ] **Step 1: Write the failing checks**

不要写 spy / 不要调私有 `showDetails()`。`TokenStatsCoordinator` 是 actor，不能子类化。接线检查必须顺着现网 `testUsageMonitoringLifecycleWiring` / `testUsageTerminationWaitsForCoordinatorCancellation` 的**源码断言**。

`init` 增加默认可注入参数（只为不扫真实家目录，检查仍读源码，不传入 spy）：

```swift
tokenStatsCoordinator: TokenStatsCoordinator = .live()
```

在 `testUsageMonitoringLifecycleWiring` 里追加（同一份 `source` / `showSource` / `updateSource` / `selectionSource` / `loopSource` / `launchSource` / `terminationSource`）：

```swift
expect(
    source.contains("private let tokenStatsCoordinator: TokenStatsCoordinator")
        && source.contains("tokenStatsCoordinator: TokenStatsCoordinator = .live()")
        && source.contains("self.tokenStatsCoordinator = tokenStatsCoordinator")
        && source.contains("private var tokenStatsStates: [AgentKind: TokenStatsStatus]"),
    "AppDelegate should own an injectable token-stats coordinator and a MainActor status cache"
)
expect(
    updateSource.contains("detailsPanel.render(aggregate: displayedAggregate, model: model, tokenStats:")
        && updateSource.contains("tokenStatsStates[")
        && !updateSource.contains("tokenStatsCoordinator.state(for:"),
    "details render must pass the MainActor token-stats cache, not hop the actor from the sync path"
)
expect(
    showSource.contains("requestTokenStatsRefresh")
        && selectionSource.contains("requestTokenStatsRefresh")
        && launchSource.contains("requestTokenStatsRefresh")
        && loopSource.contains("requestTokenStatsRefresh"),
    "showDetails, focus change, launch, and the five-minute loop should refresh token stats"
)
expect(
    source.contains("private func requestTokenStatsRefresh"),
    "token-stats refresh should be a dedicated method"
)
guard
    let tokenStatsRequestStart = source.range(of: "    private func requestTokenStatsRefresh")?.lowerBound,
    let tokenStatsRequestEnd = source.range(
        of: "    private func ",
        range: source.index(after: tokenStatsRequestStart)..<source.endIndex
    )?.lowerBound
else {
    fatalError("requestTokenStatsRefresh source should be readable")
}
let tokenStatsRequestSource = source[tokenStatsRequestStart..<tokenStatsRequestEnd]
expect(
    tokenStatsRequestSource.contains("settings.paused")
        && tokenStatsRequestSource.contains("await coordinator.prepare(")
        && tokenStatsRequestSource.contains("await coordinator.ensureFresh(")
        && !tokenStatsRequestSource.contains("usageProviderID"),
    "token-stats refresh must pause on settings.paused and must not gate on usageProviderID"
)
expect(
    {
        guard
            let branchStart = loopSource.range(of: "if let providerID = Self.usageProviderID")?.lowerBound,
            let usageCall = loopSource.range(
                of: "requestUsageRefresh",
                range: branchStart..<loopSource.endIndex
            )
        else {
            return false
        }
        return !loopSource[branchStart..<usageCall.upperBound].contains("requestTokenStatsRefresh")
    }(),
    "the five-minute loop must call requestTokenStatsRefresh outside the usageProviderID branch"
)
```

把现网这一行：

```swift
updateSource.contains("detailsPanel.render(aggregate: displayedAggregate, model: model)")
```

改成带 `tokenStats:` 的那条。不改会在 Task 10 接线后变红。

`testUsageTerminationWaitsForCoordinatorCancellation` 的 `shouldSource` 增加：

```swift
&& shouldSource.contains("await self.tokenStatsCoordinator.cancelAll()")
```

并保持原有 `await self.usageCoordinator.cancelAll()` 仍在 `finishCancellation` 之前。`willSource` / `terminationSource` 继续禁止任何 `cancelAll`（额度与 token stats 都只在 `applicationShouldTerminate` 那条 Task 里）。

- [ ] **Step 2: Run test to verify it fails**

Run: `cd src/macos && swift run AgentHaloMac --self-check`

Expected: FAIL，init 没有 `tokenStatsCoordinator` 或未接线。

- [ ] **Step 3: Write minimal implementation**

- 启动：`requestTokenStatsRefresh()`（内部 `prepare` 立刻 publish 缓存，再 `ensureFresh`）。
- 打开详情、`setFocusedAgent`、5 分钟循环都调用 `requestTokenStatsRefresh()`，只针对 `settings.focusedAgent`。
- 循环里 `requestTokenStatsRefresh()` 必须写在 `if let providerID = Self.usageProviderID` **外面**。额度对 Pi 仍是 `nil`；token stats 仍要扫 Pi。
- `requestTokenStatsRefresh` 开头 `guard !settings.paused else { return }`。不要从 actor 的 `isPaused` 闭包读 MainActor 的 `settings`（隔离编不过）。Coordinator 单测继续用注入的 `isPaused`。
- `updateDetailsPanelContent` 是同步的。从 `tokenStatsStates[focusedAgent] ?? .empty` 传给 `render`，**禁止** `await tokenStatsCoordinator.state(for:)`。
- `publishTokenStats` 写入 `tokenStatsStates`，若仍是焦点且面板可见再 `updateDetailsPanelContent()`。
- 退出：在现有 `await self.usageCoordinator.cancelAll()` 同一 `Task` 里再 `await self.tokenStatsCoordinator.cancelAll()`。
- 诊断只记 agent、文件数、命中、耗时。
- Pi 焦点：usage coordinator 仍可 deactivate（现网如此）；token stats 仍扫 Pi。

- [ ] **Step 4: Run the tests and make sure they pass**

Run:

```bash
cd src/macos
swift run AgentHaloCoreChecks
swift run AgentHaloMac --self-check
```

Expected: PASS。

- [ ] **Step 5: Commit**

```bash
git add src/macos/Sources/AgentHaloMac/AppDelegate.swift \
  src/macos/Sources/AgentHaloMac/HaloInteractionChecks.swift \
  src/macos/Sources/AgentHaloCore/TokenStats/TokenStatsCoordinator.swift
git commit -m "feat(macos): refresh focused-agent token stats from the details panel"
```

---

### Task 11: 打包验证与规格收口

**Files:**
- Modify: `docs/superpowers/specs/2026-08-14-macos-token-stats-heatmap-design.md`（状态改为已实现，待打包验证）
- 本任务不改产品代码，除非上一步验证失败需要最小修复（修复走原文件，不扩范围）

- [ ] **Step 1: Run the full check suite**

```bash
cd src/macos
swift run AgentHaloCoreChecks
swift run AgentHaloMac --self-check
swift build
cd ../..
git diff --check
```

Expected: 全部 PASS，无空白错误。

- [ ] **Step 2: Build and verify the packaged app**

```bash
bash scripts/build-macos.sh
bash scripts/run-macos.sh --verify
```

Expected: 打包 `outputs/AgentHalo-macOS/AgentHalo.app` 的自检通过。用户验收对象是这个 app，不是 `.build`。

- [ ] **Step 3: Manual smoke（写进计划备忘，执行者在真机做）**

- 焦点 Codex，打开详情：默认额度页，底边两点，高度 172。
- 点右点：今日/30d + 5×7 黄橙格；点不挡 Weekly。
- 切 Claude：回到默认页，数字换成 Claude。
- 关再开：默认页。
- 暂停监控：热力仍显示上一份，不再扫。

- [ ] **Step 4: Commit spec status only if checks passed**

```bash
git add docs/superpowers/specs/2026-08-14-macos-token-stats-heatmap-design.md
git commit -m "docs: mark token-stats heatmap spec implemented"
```

---

## 推迟（刻意不补，不是遗漏）

- Task 5 / 6 不逐行贴完整 JSONL fixture；语义仍指向 `/Users/wjs/work/ossp/openusage` 对应 scanner。
- Task 1 不单列夏令时跨日夹具。规格要求注入 Calendar；需要时再加。
- 不把六个新 locale key 扩进 `UsageMonitoringChecks` 既有翻译表（四份 json 同 key 由 Task 8 约束）。
- 不移植 OpenUsage `IncrementalJSONLScanner` 的多账户 waiter。
- 不把 `TokenStatsCoordinator` 抽成 protocol 以便 spy；AppDelegate 接线走源码断言。

## Spec coverage（自检）

| 规格要求 | 任务 |
| --- | --- |
| 日键 / 31 日窗口 / 禁止 wall-clock 30×86400 | 1 |
| 热力 5×7、未来日/窗外/零用量空心、浓度档 | 1、9 |
| 快照按 AgentKind 落盘、0600、30 天淘汰 | 2 |
| 增量 JSONL 缓存、取消 ≠ 空 | 3 |
| Codex 去重与发现 | 4 |
| Claude 去重、advisor、null、Cowork 不做 | 5 |
| Grok unified.jsonl、不计 updates.jsonl | 6 |
| Pi 原生日志、不折算 | 6 |
| Coordinator 5 分钟、取消、失败保留、paused | 7、10 |
| locale、M/B、不复用 date.other_format | 8、9 |
| 278×172、inset 6/12、点不挡条 | 9 |
| 翻页瞬时、切 Agent / 隐藏重置 | 9、10 |
| 无美元、无 Windows、不动 UsageSnapshot | 全局约束 |
| 打包 App 验证 | 11 |
