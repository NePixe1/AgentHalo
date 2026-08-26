# Agent Halo 1.1.0

Agent Halo 1.1.0 是 1.0 正式版后的首个功能更新，继续保持 Windows 与
macOS 原生客户端、共享行为规范和本地优先的监控方式。

## 主要变化

- Windows 与 macOS 新增 Grok Build 监控，包括生命周期、上下文和官方额度。
- macOS 可选支持 Antigravity，覆盖状态、权限等待和 Gemini 额度窗口。
- Windows 与 macOS 均可配置要监控的 Agent，减少无关轮询并记住选择。
- 支持双击光环激活当前 Agent 所在的桌面应用或终端宿主；单击仍不抢焦点。
- 更新 Agent Halo 应用图标、Agent 官方图标、README 横幅和中英文文档。
- 统一本地运行数据目录，迁移 hooks、日志、缓存和状态文件，并清理旧路径。
- 改进 Codex、Claude Code、Grok 和 Pi 的上下文、额度、会话标题及完成态判断。
- 优化 macOS 轮询与绘制开销，并修复多项菜单、设置和深色桌面可读性问题。

## 本次 Windows 修复

- 修复筛选监控 Agent 后，切换滑块仍停留在旧槽位的问题。
- 修复 Pi 恢复会话时被旧的完成记录覆盖，导致当前待命状态、模型、Token 或
  上下文显示不正确的问题。

## 安装

- Windows：完整解压 `AgentHalo-Windows-v1.1.0.zip`，运行 `AgentHalo.exe`。
- macOS：打开 `AgentHalo-macOS-1.1.0.dmg`，将 Agent Halo 拖入“应用程序”。
  首次启动若被 macOS 拦截，请前往“系统设置 → 隐私与安全性”，点按
  “仍要打开”并确认。

## 说明

- 应用仍为本地优先，生命周期和会话内容不会上传到 Agent Halo 服务。
- Windows 需要 .NET Framework 4.8；macOS 需要 macOS 13 或更高版本。
- macOS DMG 使用 ad-hoc 签名且未经 Apple 公证，首次启动需要手动批准。
- Windows 个人构建可能触发 SmartScreen；ZIP 包含 SHA-256 校验值。
