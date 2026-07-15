# macOS Claude 详情面板精简设计

## 背景

从 Codex 切换到 Claude Code 时，macOS 详情面板会因为 Claude 会话区额外展示 Project 行而变高。目标是在保留会话关键信息的同时，去掉这一行，减少切换时的高度变化。

## 范围

- 仅修改 `src/macos` 的 macOS 详情面板。
- Claude 会话区保留 `Session title`、`Model`、`Input/Output` 三行及其分隔线。
- 不修改 `SessionDetailsSnapshot.projectName`、Claude 会话解析逻辑或其他数据流；Project 数据仍可由底层继续产生，但不在详情面板展示。
- 不修改 Windows 详情窗口。

## 方案

从 `DetailsPanel` 的 metadata stack 中移除 `projectRow` 和 Project 与 Session title 之间的分隔线，并从 `renderSession` 中删除 Project 行的标题和值更新。测试专用的 Project 行枚举、值和 tooltip 暴露也一并移除，避免测试接口继续暗示该行存在。

新的会话区排列顺序为：

```text
Session title → separator → Model → separator → Input/Output
```

`sessionTitle`、`model`、`tokens` 的显示、离线清理、tooltip 和 28pt 行高保持现有行为。动态高度仍由 `resizeToFitContent()` 根据实际 stack 内容计算，切换时保留面板顶部位置和现有像素对齐策略。

## 测试与验收

先更新/新增 macOS 交互自检，使其在修改前失败并明确验证：

1. 会话区只包含三行和两条分隔线，且不包含 Project。
2. Session title、Model、Input/Output 的值与 tooltip 保持正确。
3. 离线状态仍会清空三行值。
4. Usage/session 切换仍按实际内容 resize，且不动画、不改变顶部边缘。

然后实现最小布局改动，运行 macOS SwiftPM 构建/自检，确认相关检查全部通过，并检查 git diff 仅涉及本需求范围。
