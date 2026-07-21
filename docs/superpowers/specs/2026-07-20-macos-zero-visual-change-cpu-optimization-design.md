# macOS 圆环零视觉变化 CPU 优化设计

## 背景

AgentHalo macOS 圆环需要继续以活跃 60 FPS、低功耗 30 FPS 运行。当前 CPU 热点不只来自帧率：主线程每 0.3 秒查询前台应用和运行应用，状态刷新会触发重复圆环重绘，圆环每帧还会重复写入若干恒定的 `CAShapeLayer` 属性。

本次目标是在不改变圆环任何可见输出的前提下降低持续 CPU 占用。视觉等价是硬性验收条件；若某项优化导致像素、轨迹或时序变化，则回退该项优化，即使 CPU 指标因此未达到预期。

## 硬性视觉约束

- 保持活跃 `60 FPS` 和低功耗 `30 FPS`，不修改动画定时器或运行循环模式。
- 不修改 `HaloMath`、`HaloVisualModel`、状态机、过渡曲线及持续时间。
- 不修改圆环半径、八层线宽、颜色、透明度、发光层次、缺口尺寸或缺口轨迹。
- 不降低路径更新频率；运动状态仍每个动画帧生成并提交当前帧路径。
- 不使用父图层旋转替代现有路径运动，不迁移至 Metal，也不引入 Core Animation 隐式动画。
- 同一输入状态与同一动画时间必须得到相同的图层模型值和像素输出。

## 方案比较

### A. 只优化动画循环之外的工作

将 Codex 运行/前台状态改为系统事件驱动缓存，移除状态刷新中的重复 `redrawRing()`。该方案完全不改变 `HaloRenderer` 的逐帧计算，视觉风险最低，但 CPU 收益主要来自减少 LaunchServices 同步查询和额外刷新。

### B. A + 恒定图层属性初始化

在 A 的基础上，把 `fillColor`、`lineCap`、`lineJoin` 等恒定属性只在图层创建时设置。`frame` 只在尺寸变化时更新；`path`、`strokeColor`、`lineWidth` 仍按现有逻辑每帧写入。最终图层属性与当前实现相同，可减少每帧属性桥接和事务工作。

### C. 分离整体旋转与缺口形变

用父图层 transform 表达整体旋转，只在相对缺口间距变化时重建路径。虽然理论上可以保持平滑 60 FPS，但会改变路径栅格化方式和抗锯齿采样，无法满足本次“零视觉变化”要求。

采用方案 B。方案 C 明确排除在本次范围外。

## 设计

### 1. 工作区应用状态事件化

应用启动时允许执行一次 `NSWorkspace.shared.runningApplications` 初始扫描。此后通过以下通知维护缓存：

- `didLaunchApplicationNotification`：若新应用是 Codex，将 `codexRunning` 设为 `true`。
- `didTerminateApplicationNotification`：Codex 退出时，仅在仍可能存在另一个 Codex 进程的情况下执行一次校准扫描；稳定状态不再轮询。
- `didActivateApplicationNotification`：直接从通知携带的 `NSRunningApplication` 更新 `codexForeground` 和系统覆盖层暂停状态。
- `activeSpaceDidChangeNotification`：仅在空间切换事件发生时读取一次当前前台应用进行校准。

`tick()`、错误确认和聚合刷新只读取缓存布尔值，不再各自查询 `frontmostApplication`、bundle、可执行文件路径或本地化名称。`activateCodex()` 属于用户主动操作，仍可在点击时扫描候选应用。

为避免改变识别语义，应用识别继续复用当前 bundle identifier、可执行文件名和可选 localized name 规则。

### 2. 消除重复圆环刷新

`HaloView.updateLiveAggregate(...)` 已通过 `applyVisualState()` 提交当前视觉状态并调用 `redrawRing()`。因此 `refreshAggregateAndUI(...)` 末尾的第二次显式 `redrawRing()` 是相同主线程周期中的重复提交，删除后不会跳过任何状态变化。

动画帧仍由现有 60/30 FPS 驱动器调用 `redrawRing()`；本项不合并、不节流动画帧。

### 3. 恒定图层属性只初始化一次

`setupRingLayers()` 负责为八个 `CAShapeLayer` 设置：

- `fillColor = clear`
- `lineCap = round`
- `lineJoin = round`

`HaloRenderer.applyRingLayers(...)` 不再每帧重复写入上述值。尺寸变化由现有 `resizeForHaloSize(...)` / 布局路径统一更新图层 `frame`，普通动画帧不重复写相同 frame。

每帧仍保持以下顺序和数值来源：计算目标视觉、过渡视觉、动画颜色、呼吸/闪烁、材质、路径，然后在禁用隐式动画的 `CATransaction` 中提交 `path`、`strokeColor` 与 `lineWidth`。

## 视觉等价验证

现有 `AgentHaloDiagnostics` 使用独立的 CGContext 绘制路径，能够检查视觉模型，但不能证明运行时 `CAShapeLayer` 输出未变化。因此实施前先补充运行时等价检查。

### 图层模型基线

为 `HaloView` 提供仅供自检使用的确定性快照，记录每个圆环层的：

- frame、path 元素和坐标
- fill/stroke RGBA
- lineWidth、lineCap、lineJoin
- 动画时间、`gapA`、`gapB`

覆盖全部 `HaloState`、错误展示模式、answer streaming、steady done，以及状态过渡和完成双闪关键时间点。连续推进至少 120 个 `1/60s` 帧，逐帧比较动画时间和缺口轨迹。

### 像素基线

使用实际 `HaloView` 的图层树渲染测试图，而不是只调用 `DiagnosticHaloRenderer`。在固定色彩空间下覆盖 1x 与 2x、全部稳定状态及关键过渡帧。优化前后的图像尺寸和 RGBA 数据必须完全一致；若平台渲染存在非确定性，只允许预先证明来自图像编码元数据的差异，不接受圆环像素容差。

### 结构回归

自动检查必须确认：

- `normalAnimationInterval == 1 / 60`，`lowPowerAnimationInterval == 1 / 30`。
- 动画帧仍调用 `redrawRing()`，路径仍逐帧更新。
- `tick()` 不再直接读取 `frontmostApplication` 或扫描 `runningApplications`。
- 聚合刷新只触发一次状态提交，不额外调用 `redrawRing()`。
- 恒定图层属性在 setup 中设置，动态提交继续禁用隐式动画。

## 性能验证

从 `src/macos` 运行现有 benchmark 与完整自检，并打包 `outputs/AgentHalo-macOS/AgentHalo.app`。在相同机器、窗口位置、圆环状态和采样时长下，对优化前后进行 CPU 对比，分别记录稳定待机和持续运动状态。

性能结果只用于判断收益，不覆盖视觉门槛。如果安全优化后的 CPU 仍高于目标，先报告剩余热点，再决定下一阶段；不自动采用会改变渲染路径或帧输出的方案。

## 范围

本次仅修改 macOS 实现及其诊断/回归检查。Windows 不改；配额读取、会话解析、详情面板、菜单、持久化和产品文案不改。
