# Agent Halo 1.1.1

此版本包含最新 macOS 修复：

- 紧凑显示自定义 API Key 会话的 Token 指标。
- 优化详情面板的毛玻璃材质与文本截断，维持低噪、易扫读的界面。
- 修复已安装 DMG 在非构建机器上启动时的 SwiftPM 资源回退问题。

## 安装

- macOS：打开 `AgentHalo-macOS-1.1.1.dmg`，将 Agent Halo 拖入“应用程序”。首次启动若被 macOS 拦截，请前往“系统设置 → 隐私与安全性”，点按“仍要打开”。
- Windows：此发布继续提供 `v1.1.0` 的 `AgentHalo.exe` 及 `AgentHalo-Windows-v1.1.0.zip`，以保持与上一版 Windows 构建一致。Windows 需要 .NET Framework 4.8。

## 说明

- macOS DMG 使用 ad-hoc 签名，未经 Apple 公证，首次启动需要手动批准。
- Windows 个人构建可能触发 SmartScreen；ZIP 包含 SHA-256 校验值。
