# 隐藏详情面板 Provider 头部设计

## 目标

暂时从 macOS 详情面板移除 Provider、Plan 与同一行的用量告警图标。保留用量监控后台接口、认证模式、计划名称和告警的解析逻辑，便于后续恢复展示。

## 方案

`DetailsPanel` 不再把 `ProviderHeaderView` 加入垂直布局栈，也不再在 `render` 时向它传入 Provider、Plan 或告警数据。详情面板首行仍为代理切换和上下文胶囊，随后直接显示状态标题、状态说明，以及用量或会话内容。

`DetailsContentResolver`、`DetailsPanelViewModel`、`UsageMonitorState` 与后台刷新链路保持不变；它们继续生成 Provider、Plan 与告警信息，但不再由详情面板消费。

## 回归边界

更新 `HaloInteractionChecks`：

- 详情面板顶层布局不包含 Provider 行；
- OAuth 和 API Key 两种数据模型均不会显示 Provider、Plan 或告警；
- 用量行、会话详情、状态标题与上下文胶囊仍按既有逻辑显示；
- 核心用量监控自检继续覆盖计划名称和告警生成，证明后台契约未被移除。

## 非目标

- 不删除或改造用量提供方接口；
- 不修改 Windows 端；
- 不增加配置开关或偏好设置。
