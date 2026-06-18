# macOS 视觉行为说明

本文记录 Agent Halo macOS 端当前的光环动效和状态表现。README 只保留安装、使用和状态速览，细节放在这里维护。共享的状态判定逻辑见
[Cross-Platform Shared Contract](CROSS_PLATFORM_SHARED_CONTRACT.md)。

## 断点运动

大断点会追赶缓慢往返漂移的小断点。接近约 40° 时，小断点会像受到磁斥一样平滑推开到约 150°，随后带着逐渐衰减的惯性继续滑行并往返漂移。

待机状态也会持续运动。思考和执行状态转得更快。磁斥时长和离场惯性会根据当前实际转速自动调整，慢状态不会被突然拉走。

## 发光材质

思考和执行期间，环条本体会从暗色材质逐渐点亮：主体升为亮白灯芯，状态色保留在灯管边缘；窄光晕同步增强，中心保持透明。

材质模型与 Windows 共享同一份 `darkLitTubeWhiteCoreV1` 参数（见
`src/shared/spec/agent-halo.v2.json` 的 `platformExtensions.macos.materialModel`）。

## 呼吸与状态切换

思考、执行和完成状态采用连续的长亮短暗非对称呼吸。

状态切换不会硬切颜色，而是先柔和收光，在暗部完成颜色渐变，再自然点亮到目标状态。

工具输出后蓝色会短暂保持约 1.8 秒，让快速工具调用也能清楚看见执行状态。

## Plan Mode 收尾

当 Codex 以 Plan Mode 启动并产出 proposed plan 后，光环会在 `task_complete` 时停在紫色
`attention` 状态（提示文本 "Waiting for your choice"），而不是直接转绿色 `done`，
提醒你回到 Codex 选择「实施 / 编辑」。普通 final answer 或普通任务完成仍按原有逻辑
直接转绿。详细字段约定与共享逻辑见
[Cross-Platform Shared Contract](CROSS_PLATFORM_SHARED_CONTRACT.md#plan-mode-lifecycle-cross-platform)。

最终答案产出过程当前仍走 `.thinking` / `.working` 视觉，不强制锁蓝。

## 刷新率与监听

动画通过 `CVDisplayLink` 跟随显示器实际刷新率推进，不再对待机或完成状态主动降帧。
长时间不活跃时帧间隔会被钳制，避免应用从待机恢复时出现跳跃。

「暂停状态监听」只在当前运行期间有效，重新启动后会自动恢复实时监听。

## macOS 专属交互

- 菜单栏图标与光环右键菜单暴露同一套控制项（`fullControlMenuV1`）。
- 启动项通过 LaunchAgent 注册，路径指向 `<App>.app/Contents/MacOS/AgentHaloMac`。
- 多显示器和窗口位置由原生 AppKit 行为管理，不与 Windows 共享。
