# Agent Halo v1.2.0：新增代理监控与界面优化 / New agent monitoring and UI refinements

## 中文

### 新增监控

- Windows 和 macOS 新增 OpenCode：通过内嵌插件和本地原子快照识别思考、工具执行、授权等待、完成和故障，展示会话、模型、输入输出及上下文占用。首次安装插件后需重启已经打开的 OpenCode。
- Windows 和 macOS 新增 WorkBuddy：只读本地活会话、数据库和响应日志，不安装 hook、不修改 WorkBuddy 配置，展示任务状态、模型、最近一次响应输入输出和上下文。
- 保留已有监控对象勾选记录；OpenCode 和 WorkBuddy 默认关闭，可在菜单中启用。

### 界面与可靠性

- Windows 优化状态文字和代理切换过渡，减少白闪、透明度突变和位移；将 Codex 扫描与界面读取解耦，减少切换卡顿。
- macOS 更新详情面板的浅色底板、留白、代理切换栏和上下文百分比样式；未选中的代理图标统一灰显，选中后恢复原色。
- 两端统一任务区左对齐和分割线，模型、输入和输出使用紧凑标签，输入为蓝色、输出为青绿色；无会话时保持相同的内容起点。
- macOS 的 Pi、OpenCode 和 WorkBuddy 详情优先显示完整工作目录；长模型名优先截断，为输入输出 token 数字保留空间。
- Windows 修复部分 Pi 和 OpenCode 运行中进程被误判为退出的问题，校验进程创建时间以避免 PID 复用，并改善恢复会话与长任务检测。
- macOS 改善监控快照重试和活任务保留，修复 Claude statusline 配置迁移，并确保交互自检必须输出完成标记。
- 内嵌 OpenCode 插件及 WorkBuddy 图标，安装包不依赖外置开发资源或 `sqlite3.exe`。

### 安装与说明

- **Windows 10/11**：完整解压 `AgentHalo-Windows-v1.2.0.zip` 后运行 `AgentHalo.exe`，需要 .NET Framework 4.8。未签名构建可能触发 SmartScreen。
- **macOS 13 及以上**：下载 `AgentHalo-macOS-1.2.0.dmg`，将应用拖入 Applications。此附件为 Apple Silicon 构建，采用临时签名，首次打开可能需要在“系统设置 → 隐私与安全性”中允许。
- `SHA256.txt` 提供发布附件的校验值；Windows 压缩包内也包含原始 EXE 的校验值。
- WorkBuddy 本地存储并非稳定公共 API，暂不保证远程或云端任务检测。输入输出展示最近一次有效响应用量，不代表累计账单；缺少数据时不伪造数字。
- 生命周期和会话内容保留在本地，不上传会话内容。

## English

### New monitoring

- Added OpenCode on Windows and macOS. A bundled plugin and local atomic snapshots track thinking, tool execution, approval waits, completion, and failures, with session, model, input/output tokens, and context usage. Restart any already running OpenCode instance after the plugin is first installed.
- Added WorkBuddy on Windows and macOS. Read-only monitoring of local live sessions, the database, and response logs provides task state, model, latest-response token counts, and context usage, without installing hooks or changing WorkBuddy settings.
- Existing enabled-agent selections are preserved. OpenCode and WorkBuddy are off by default and can be enabled from the menu.

### UI and reliability

- Windows refines status text and agent-switch transitions to reduce flashes, abrupt opacity changes, and movement. Codex scanning no longer blocks UI reads during switching.
- macOS refreshes the details panel with a light surface, improved spacing, agent switcher, and context percentage. All inactive agent icons are grayscale; selecting an agent restores its original colors.
- Both platforms align the session area and divider, with compact model, input, and output chips: blue for input and teal for output. Empty sessions retain the same content alignment.
- macOS prefers the full working directory in Pi, OpenCode, and WorkBuddy details. Long model names truncate first to preserve space for input/output token counts.
- Windows fixes false process-exit detection for some Pi and OpenCode sessions, checks process creation times against PID reuse, and improves resumed-session selection and long-running task detection.
- macOS improves snapshot retries and live-task retention, fixes Claude statusline configuration migration, and requires an explicit completion marker from interaction self-checks.
- The OpenCode plugin and WorkBuddy icon are bundled; installed apps do not depend on development resources or `sqlite3.exe`.

### Installation and notes

- **Windows 10/11:** Fully extract `AgentHalo-Windows-v1.2.0.zip`, then run `AgentHalo.exe`. Requires .NET Framework 4.8. Unsigned builds may trigger SmartScreen.
- **macOS 13 or later:** Download `AgentHalo-macOS-1.2.0.dmg` and drag the app into Applications. This asset is an Apple Silicon build with an ad-hoc signature; the first launch may require approval in System Settings → Privacy & Security.
- `SHA256.txt` contains checksums for the release assets. The Windows archive also includes the original EXE checksum.
- WorkBuddy's local storage is not a stable public API; remote or cloud task detection is not guaranteed. Input/output counts reflect the latest valid response rather than cumulative billing. Missing values are never fabricated.
- Lifecycle and session content remain local; session content is not uploaded.
