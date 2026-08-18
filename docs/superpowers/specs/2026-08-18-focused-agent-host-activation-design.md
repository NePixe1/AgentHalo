# 聚焦 Agent 宿主激活设计

## 文档状态

- 日期：2026-08-18
- 状态：设计已确认；待写实施计划
- 实现范围：AgentHalo **Windows + macOS**（Antigravity 仍只在 macOS）
- 产品原则：见 [PRODUCT.md](../../PRODUCT.md)
- 相关先例：
  - macOS `CodexAppDetector.activateCodex()`
  - Windows `HaloWindow.BringCodexForward()`
  - [macOS Grok Build 额度与最小生命周期设计](./2026-07-25-macos-grok-build-usage-lifecycle-design.md)（原文「不做 click-to-activate」，由本文取代）
  - [Windows Grok Build 完整对齐设计](./2026-07-29-windows-grok-build-parity-design.md)（同上）
  - [macOS Antigravity Agent 设计](./2026-08-14-antigravity-agent-macos-design.md)（同上）

## 目标

双击圆环时，按**当前聚焦的 agent** 把「正在驱动光环的那次会话」的宿主应用带到前台。

| 聚焦 | 行为 |
| --- | --- |
| Codex | 保持现状：扫描 Codex 桌面应用并激活，不依赖 session PID |
| Claude / Grok / Pi / Antigravity | 用该会话的 live PID，沿进程树走到第一个 GUI 宿主再激活 |

没有可用 PID、PID 已死、或走不到 GUI 宿主 → **静默跳过**。不启动应用，不申请辅助功能权限，不切具体 tab。

Windows 和 macOS 都做。Antigravity 仍只在 macOS。

## 非目标

- 单击激活（单击仍只用于拖动 / 悬停）
- 按窗口标题模糊匹配
- 把 `processId` 写进共享 `SessionSnapshot` / 跨平台会话模型
- 修改 `agent-halo.v2.json` 动画或视觉参数
- 为 Claude Desktop 或其他桌面应用单独编一条「没 PID 也激活」的退路
- 切到终端里的具体窗口 / 标签页
- 新设置项、新菜单项、权限提示、用户可见错误
- 改变 Codex 现有的桌面应用扫描（不改成必须有 session PID）

## 已确认的产品选择

1. **激活对象**：当前圆环对应的那次会话的宿主应用（方案 1）。Claude 在 iTerm 就切 iTerm，在 Ghostty 就切 Ghostty。
2. **无 PID**：静默什么都不做。不退回「常见终端」或「已知桌面应用」。
3. **平台**：Windows 和 macOS 一起做。
4. **实现路径**：统一的「聚焦会话宿主」激活器。不给每个 agent 复制一套 `activateXxx`，也不把 PID 塞进 `SessionSnapshot`。
5. **手势**：继续双击。单击不激活。
6. **精度**：激活宿主 **app**，不切 tab。

## 背景

### 现状

- 双击圆环只在聚焦 Codex 时激活：
  - macOS：`haloView.onDoubleClick` → `bringCodexForward()` → `focusedAgent == .codex` 才调用 `CodexAppDetector.activateCodex()`，扫描 regular Codex 桌面应用。
  - Windows：`OnDoubleClick` → `GetFocusedAgent() == Codex` 才 `BringCodexForward()`，按进程名 / 窗口标题匹配。
- 单击明确不激活（`handleHaloPrimaryClick` 为空；测试 `testSingleClickDoesNotActivateCodex`）。
- 产品文档与测试曾写死「Claude / Grok / Antigravity 不做 click-to-activate」。
- Claude / Grok / Pi 已有 live PID（session 文件、`active_sessions.json`、Pi status / runtime）。Antigravity hook **没有** per-session pid，在场靠扫描 `agy` / `Antigravity` 主应用。

### 问题

聚焦非 Codex 时双击圆环没有反馈路径。用户已经在看那个 agent 的状态，却不能回到对应的终端或桌面应用。

## 架构

一条入口，平台各做激活，会话选择对齐现有聚合。不改共享会话模型。

```
双击圆环
  → activateFocusedAgent(focusedAgent)
      → Codex：现有桌面应用扫描（不变）
      → 其他：
          1. 选会话（可见会话第一条；STANDBY 用各 agent 已有的 preferred live session）
          2. threadId → live PID（读现成 reader）
          3. PID 沿父进程走到第一个 regular GUI app
             （跳过 CLI / conhost / Helper / Agent Halo 自己）
          4. 激活该应用；失败则 return
```

### 模块边界

| 单元 | 职责 | 不负责 |
| --- | --- | --- |
| `activateFocusedAgent`（平台入口） | 按聚焦分流；Codex 走旧路径；其它走解析 + 行走 + 激活 | 主 tick 轮询 |
| 会话 / PID 解析器 | 给定 focused agent + 当前 aggregate / live 缓存，产出一个 pid 或空 | 激活窗口 |
| 进程树行走（可注入进程表） | pid → 宿主 GUI 标识（macOS：`NSRunningApplication`；Windows：带主窗口的进程） | 读 session 文件 |
| 平台激活 | `NSRunningApplication.activate` / `ShowWindow` + `SetForegroundWindow` | 猜 tab |

主 tick **不**扫进程树。只在用户双击时走一次。不调用 `ps`。

### 平台落点

- **macOS**：`AppDelegate.bringCodexForward()` 扩成 `activateFocusedAgent()`；保留 `codexActivator` 注入供现有测试；新增可测的 PID 选择 + 进程树行走。
- **Windows**：`HaloWindow.OnDoubleClick` 按聚焦分流；进程树用已有 Toolhelp32 风格（`PiRuntimeMonitor` 已读 parent pid）；找到宿主后复用 `BringCodexForward` 的窗口 API。

## 会话选择

只看**当前聚焦 agent**。

1. **有可见会话**（thinking / working / done / attention / error）  
   用 `aggregate.sessions.first`。`SessionAggregator` 已按状态优先级 + 最近事件排序，这就是正在驱动光环的那条。

2. **STANDBY**（圆环为待机绿，但 `sessions` 为空）  
   用该 agent 已有的 preferred live session，与详情面板同一套优先级，不另发明排序。

3. **OFFLINE / PAUSED / 没有 preferred live session**  
   不激活。

Codex 不走本节。

## PID 映射

不给 `SessionSnapshot` 加重字段。按 agent 读现成 live 数据，用 `threadId` 对上后取 PID；对不上或 PID 无效则停。

| Agent | PID 来源 | 对不上时 |
| --- | --- | --- |
| Claude | `~/.claude/sessions/*.json` 的 `sessionId` + `pid`。macOS `ClaudeLiveSessionReader` 已有；Windows 现有 reader 只露出 id，实现时补出 pid（仍只在双击时读，不改主 tick） | 停 |
| Grok | `~/.grok/active_sessions.json` 的 `session_id` + `pid`。先精确 id，再用现有「同 workspace」匹配（与 `IsGrokHookSessionLive` 一致） | 条目没有 pid，或进程已死 → 停 |
| Pi | `pi-status.jsonl` / runtime 记录里的 `processId`（含 `pi-{pid}` 回退会话） | 停 |
| Antigravity | hook **没有** per-session pid。仅当本机只有 **一个** 可计为在场的进程（`agy` 或 `Antigravity` 主应用，与 `AntigravityActivityMonitor.countsAsPresentProcess` 一致）时用它 | 0 个或多个 → 停 |

Antigravity 是唯一的诚实放宽：没有会话级 PID，多开时无法知道该激哪一个，宁可不做。不因此退回「只要 `Antigravity.app` 在跑就激活」——那会违背「无 PID 静默跳过」。

解析出的 PID 只做一次探活：macOS `kill(pid, 0)`（允许 `EPERM`），Windows `OpenProcess` / `GetProcessById`。死了就停。

Grok 旧文件若所有条目都没有 pid：按现有 presence 规则那些会话仍可算 STANDBY，但**激活仍要求具体 pid**，因此 STANDBY 无 pid 时不激活。

## 进程树 → 宿主应用

拿到活着的 PID 后，只在双击这一刻沿父进程往上走。

约束：

- 最多 **32** 层
- visited 集防环
- 不调用 `ps`
- 主 tick 不走

**跳过（继续往上）：**

- 起始 CLI 本身：`claude`、`grok`、`pi`、`agy`，以及作为包装出现的 `node` / `bun`
- 控制台垫层：`conhost`、`OpenConsole`、`wslrelay`、`wslhost`
- Helper / 非 regular 应用：`* Helper`、`Code Helper`、`language_server`
- Agent Halo 自己

**停下来并激活的第一个：**

- **macOS**：`NSRunningApplication.activationPolicy == .regular`（iTerm / Terminal / Ghostty / Warp / VS Code / Cursor / `Antigravity.app` 等）
- **Windows**：有主窗口（`MainWindowHandle != 0`）的进程，或 Windows Terminal / `Code` / `Cursor` 这类已知 GUI 宿主

起始 PID 自己就是 regular GUI 时（例如 Antigravity 桌面应用），不再往上走，直接激活。

走到 pid 0 / 1、父进程消失、没有 GUI 祖先（例如挂在 `sshd` 下）、或只有垫层 → 不激活。

## 激活与错误处理

| 平台 | 方式 |
| --- | --- |
| macOS | `activate(options: [.activateIgnoringOtherApps])` |
| Windows | 与现有 Codex 相同：`ShowWindow(SW_RESTORE)` + `SetForegroundWindow` |

全部静默：

- 找不到会话、PID 无效、走不到宿主、`activate` / `SetForegroundWindow` 失败 → return
- 需要时可写一条现有风格的 debug log（macOS 不强制；Windows 可沿用 `SettingsStorage.Log`）
- 不弹窗、不改设置、不请求辅助功能 / Accessibility 权限

已在前台的宿主再 activate 一次是无害的，不必先判断 foreground。

## 测试

纯逻辑用假进程表 / 注入的 live 数据测，不依赖本机真的开着终端。

### 会话选择 / PID

- 可见会话：取 `aggregate.sessions.first` 对应的 live PID，激活该 PID 的宿主
- STANDBY：用该 agent 已有的 preferred live session
- OFFLINE、PAUSED、PID 已死、Grok 条目无 pid → 不激活
- Antigravity：恰好一个在场进程 → 激活；0 个或多个 → 不激活
- Codex 双击仍走桌面应用扫描，不读 session PID
- 单击仍然不激活（包括非 Codex 焦点）

### 进程树

- `zsh → iTerm` / `node → Code Helper → Code` → 激活最上面的 GUI
- 起始就是 `Antigravity` 主应用 → 直接激活
- `agy → sshd` 或只有 `conhost` → 不激活
- 环、超过 32 层 → 不激活
- 不激活 Agent Halo 自己

### 测试落点

- macOS：`HaloInteractionChecks`（手势 / AppDelegate 分流）+ Core / 可单测的解析器与行走器
- Windows：`Diagnostics` 自测

删除或改写反向断言：

- `HaloInteractionChecks` 中 `Grok must not gain a click-to-activate terminal path`
- 以及「Claude 焦点不得激活」的过时断言

改成上述正向用例。单击不激活的测试保留。

## 文档

改用户能看到的约定，不再写「只有 Codex 才会切前台」：

- `README.md`：双击圆环会把**当前聚焦 agent** 对应的会话宿主带到前台（找不到则无操作）
- `docs/PRODUCT.md`：去掉「click-to-activate 仅限 Codex / Claude 不 foreground」
- `AGENTS.md`：同步「Click halo」一句
- 旧 spec（Grok / Antigravity）里「不做 click-to-activate」的句子加一句：已被本文取代

不改 `agent-halo.v2.json`。

## 实现约束（供计划使用）

- 不把 PID 放进共享 `SessionSnapshot`。
- 不在 0.3s tick 里做进程树或 `ps`。
- Windows Claude live reader 补 pid 时保持现有「文件存在 + 进程仍活」的判定，只是把 pid 一起返回。
- Antigravity 在场进程集合必须与 `AntigravityActivityMonitor` 的 `agy` / `Antigravity` 规则一致，排除 Helper 和 `language_server`。
- 保持双击手势；不要把激活绑到 `onClick` / 单击。
- 现有 Codex 测试（桌面应用扫描、单击不激活）必须继续通过。
