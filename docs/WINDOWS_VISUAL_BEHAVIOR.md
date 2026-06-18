# Windows 视觉行为说明

本文记录 Agent Halo Windows 端当前的光环动效和状态表现。README 只保留安装、使用和状态速览，细节放在这里维护。共享状态机规则见
[Cross-Platform Shared Contract](CROSS_PLATFORM_SHARED_CONTRACT.md)。

## 断点运动

大断点会追赶缓慢往返漂移的小断点。接近约 40° 时，小断点会像受到磁斥一样平滑推开到约 150°，随后带着逐渐衰减的惯性继续滑行并往返漂移。

待机状态也会持续运动。思考和执行状态转得更快。磁斥时长和离场惯性会根据当前实际转速自动调整，慢状态不会被突然拉走。

## 发光材质

思考和执行期间，环条本体会从暗色材质逐渐点亮：主体升为亮白灯芯，状态色保留在灯管边缘；窄光晕同步增强，中心保持透明。

材质模型使用 `src/shared/spec/agent-halo.v2.json` 中共享的
`darkLitTubeWhiteCoreV1` 参数。

## 呼吸与状态切换

思考、执行和完成状态采用连续的长亮短暗非对称呼吸。

状态切换不会硬切颜色，而是先柔和收光，在暗部完成颜色渐变，再自然点亮到目标状态。

工具输出后蓝色会短暂保持约 1.8 秒，让快速工具调用也能清楚看见执行状态。

完成状态会先执行 Windows 端的双闪确认，再进入绿色呼吸。

## Plan Mode 收尾

当 Codex 以 Plan Mode 启动并产出最终答案后，光环会在 `task_complete`
时停在珊瑚色 `attention` 状态（提示文本 "Waiting for your choice"），
而不是直接转绿色 `done`，提醒你回到 Codex 选择「实施 / 编辑」。
普通任务完成仍按原有逻辑直接转绿。

详细字段约定与 reducer 标志位见
[Cross-Platform Shared Contract](CROSS_PLATFORM_SHARED_CONTRACT.md#plan-mode-lifecycle-cross-platform)。
最终答案产出过程当前仍走既有 thinking / working 流程，不强制锁蓝。

## 刷新率与监听

动画直接跟随桌面合成刷新频率，不再对待机或完成状态主动降帧。

“暂停状态监听”只在当前运行期间有效，重新启动后会自动恢复实时监听。

## Windows 专属行为

- 渲染器是原生 WPF，并作为透明、置顶的桌面覆盖层运行。
- 完成确认、托盘控制、启动项注册和边缘吸附属于 Windows shell 行为，不与 macOS 共享。
- 会话状态 reducer 位于 `src/windows/CodexMonitor.cs`；视觉渲染位于
  `src/windows/HaloVisual.cs`；共享 spec 生成的常量位于
  `src/windows/GeneratedHaloSpec.cs`。
