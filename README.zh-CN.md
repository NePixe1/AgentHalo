<a id="readme-top"></a>

<div align="center">
  <img src="assets/agent-halo-readme-banner.png" alt="Agent Halo Banner" width="760"/>
</div>

<h1 align="center">Agent Halo</h1>

<div align="center">
  <p>
    <a href="https://github.com/NePixe1/AgentHalo/releases/latest">
      <img src="https://img.shields.io/github/downloads/NePixe1/AgentHalo/latest/total?style=flat&label=%E6%9C%80%E6%96%B0%E4%B8%8B%E8%BD%BD%20%40latest&labelColor=444&logo=github&logoColor=white&cacheSeconds=600" alt="最新下载">
    </a>
    <a href="https://github.com/NePixe1/AgentHalo/releases">
      <img src="https://img.shields.io/github/downloads/NePixe1/AgentHalo/total?label=%E6%80%BB%E4%B8%8B%E8%BD%BD%E9%87%8F" alt="总下载量">
    </a>
  </p>
  <p>
    <img src="https://img.shields.io/badge/版本-1.0.0-14B8A6?style=for-the-badge" alt="Version"/>
    <img src="https://img.shields.io/badge/隐私优先-0F172A?style=for-the-badge" alt="Privacy First"/>
    <img src="https://img.shields.io/badge/Swift-FA7343?style=for-the-badge&logo=swift&logoColor=white" alt="Swift"/>
    <img src="https://img.shields.io/badge/Xcode-007ACC?style=for-the-badge&logo=xcode&logoColor=white" alt="Xcode"/>
    <img src="https://img.shields.io/badge/C%23-512BD4?style=for-the-badge&logo=csharp&logoColor=white" alt="C#"/>
    <img src="https://img.shields.io/badge/.NET-512BD4?style=for-the-badge&logo=dotnet&logoColor=white" alt=".NET"/>
    <img src="https://img.shields.io/badge/macOS-000000?style=for-the-badge&logo=apple&logoColor=white" alt="macOS"/>
    <img src="https://img.shields.io/badge/Windows-0078D4?style=for-the-badge&logo=windows&logoColor=white" alt="Windows"/>
    <img src="https://img.shields.io/badge/Git-E44C30?style=for-the-badge&logo=git&logoColor=white" alt="Git"/>
  </p>
  <p>Agent 的本地常驻状态光环。在桌面上原生呈现各种 Agent 的执行与规划状态。</p>
  <p><a href="README.md">English</a> | 简体中文</p>
</div>


---

跨平台行为以
[`src/shared/spec/agent-halo.v2.json`](src/shared/spec/agent-halo.v2.json)
为唯一参数来源，并生成 C# 与 Swift 常量；Windows 和 macOS 继续使用各自的原生渲染。
详见 [共享契约说明](src/shared/README.md) 与
[跨平台架构说明](docs/CROSS_PLATFORM_SHARED_CONTRACT.md)。

## 系统要求

- Windows 10 或 Windows 11
- 已安装并使用 Codex 桌面端，或在 macOS 上使用 Claude Code / Grok Build
- .NET Framework 4.8（目前的 Windows 10/11 通常已自带）

## macOS 开发版

运行并验证：

```bash
bash ./scripts/run-macos.sh --verify
```

应用是菜单栏辅助应用，不显示 Dock 图标。可以从菜单栏 Agent Halo 图标退出，也可以执行：

```bash
pkill -x AgentHaloMac
```

诊断命令：

```bash
cd src/macos
swift run AgentHaloDiagnostics --self-test /tmp/agent-halo-self-test.txt
swift run AgentHaloDiagnostics --render-states /tmp/agent-halo-states
swift run AgentHaloDiagnostics --transition-strip /tmp/agent-halo-transitions
```

## 安装与运行

1. 从 GitHub Releases 下载最新的 `AgentHalo-Windows-v*.zip`。
2. 解压整个 ZIP 压缩包，不要直接在压缩包内运行。
3. 双击 `AgentHalo.exe`，光环会出现在主显示器右上方附近。

程序没有安装器，也不需要 OpenAI API Key。为独立刷新额度，Agent Halo
会复用 Codex 已有的 OAuth 登录凭据；OAuth Token 轮换时会原子更新 Codex
原有的 `auth.json`。

## 操作

- 拖动光环：调整位置，靠近屏幕边缘时会自动吸附。
- 鼠标悬停：查看当前状态；官方 Codex OAuth 显示 5 小时额度和周额度。
- 使用 CCSwitch、自定义模型提供商或 API Key 时，Codex 面板会自动改为显示项目、模型和本轮输入/输出 Token，不展示 API Key、Base URL 或中转工具名称。
- 悬停详情面板提供 `Codex / CC / Grok` 切换（macOS；Windows 仍为 `Codex / CC`）。Agent Halo 会同时监听可用工具，但光环颜色、状态文案和额度行只跟随当前选中的监控对象。macOS 另支持 Grok Build 周额度与最小生命周期（无 Pay-as-you-go UI）。
- 上下文 pill 显示当前监控对象的上下文占用：Codex 显示配额上下文占用，Claude Code 显示通过 status line proxy 捕获的上下文窗口使用率。
- Codex 官方额度行只在 OAuth 模式显示；自定义 API 模式和 `CC` 视图使用相同高度的信息行，不混入虚假的官方额度。
- 任务完成后绿色会缓慢呼吸；再次打开 Codex 后自动确认并变为不发光的稳定绿色。
- 右键单击：打开状态预览、暂停监听、开机启动和退出菜单。
- 右键”光环大小”：选择 `75% / 100% / 125%`，重启后保持设置。
- macOS 会记住光环所属显示器及相对位置；该显示器断开时临时移到主屏右上角，重新连接后恢复原位置。临时回退期间如果手动拖动光环，新位置会成为首选位置，不再返回原显示器。
- Windows 保持原有离屏恢复行为：启动或显示器变化后，如果光环完全离开所有屏幕，会自动移回主屏右上角。
- 两个平台都可从右键菜单选择“脱离卡死”，明确重置到主屏右上角。
- 单击光环：将 Codex 窗口切到前台。

## 状态含义

- 黄色长亮短暗：Agent 正在思考或规划。
- 蓝色长亮短暗：Agent 正在执行命令、搜索、编辑文件或调用工具。
- 绿色双闪：Agent 已完成；高亮两次后持续缓慢呼吸，直到被确认。
- 珊瑚橙双脉冲：Agent 正在等待 Yes、授权、确认或输入。
- 红色：仅表示阻止任务继续的故障；未查看时爆闪，打开 Codex 后常亮，离开后变为暗红。
- 稳定绿色：被监听的 Agent 已运行且当前没有活动任务。
- 暗白色：当前没有可见的 Agent 活动。

详细动效规则按平台拆分：

- [Windows 视觉行为说明](docs/WINDOWS_VISUAL_BEHAVIOR.md)
- [macOS 视觉行为说明](docs/MACOS_VISUAL_BEHAVIOR.md)
- 共享状态机契约见 [CROSS_PLATFORM_SHARED_CONTRACT.md](docs/CROSS_PLATFORM_SHARED_CONTRACT.md)。

## 隐私

Agent Halo 只在本机读取 `%USERPROFILE%\.codex\sessions` 中的生命周期事件，
并在 macOS 上自动配置：

- Claude Code：`~/.claude/settings.json` 中的生命周期 hooks 与 status line proxy
- Grok Build：`~/.grok/hooks/agent-halo-status.json` 中的生命周期 hooks

用户主目录下的 `.agent-halo` 使用统一布局：

- `bin/` — staged hook 二进制（macOS 为 `status-hook` /
  `statusline-proxy`，Windows 为 `status-hook.exe`）
- `state/` — 小型持久状态（如 macOS statusline 下游命令）
- `logs/` — 近期生命周期事件（`claude-status.jsonl`、`grok-status.jsonl`，自动轮转）
- `cache/` — 可安全删除的缓存（Claude context 快照、用量快照）

Grok Build 默认也会加载 Claude 的 `settings.json` hooks（兼容扫描），因此同一条
Agent Halo `status-hook` 在 Grok 会话里可能出现两次（`agent-halo-status` 与
`settings`）。功能正常，只是重复执行。若只想保留 Grok 原生路径，可在
`~/.grok/config.toml` 中设置：

```toml
[compat.claude]
hooks = false
```

这只关闭 Claude hooks 导入，不影响 skills / rules / MCP，也不影响 Claude Code
本身。修改后需重启 Grok 会话才会生效。注意：若你还有**仅**写在
`~/.claude/settings.json` 中的其它 hooks，关闭后它们在 Grok 中也不会再运行。

Windows 应用设置与 `halo.log` 仍在 `%LOCALAPPDATA%\CodexHalo\`；**用量快照**
在 `.agent-halo\cache\`。应用启动时会把当前 `AgentHalo.exe` 原子暂存为稳定副本
`%USERPROFILE%\.agent-halo\bin\status-hook.exe`，Claude hooks 通过
`status-hook.exe --claude-hook <event>` 调用该副本；它不是需要单独下载的组件。
Agent Halo 还会只读查询 `logs_2.sqlite` 中结构化的 Codex 连接和服务故障记录。

为了独立刷新 Codex 额度，程序会读取现有 OAuth 登录凭据，并仅向
`auth.openai.com` 与 `chatgpt.com` 的官方接口发起 HTTPS 请求。OAuth Token
不会写入 Agent Halo 缓存；Token 轮换时只会原子写回 Codex 原有凭据文件。
Agent Halo 的额度缓存仅保存账户哈希、使用百分比和重置时间，不上传会话内容，
也不读取或保存 OpenAI API Key。

## Windows 安全提示

这是一个未购买商业代码签名证书的自制程序，因此 Windows SmartScreen 可能提示
“Windows 已保护你的电脑”。请只在确认压缩包来自可信发送者、并核对
`SHA256.txt` 后运行。确认无误时，可选择“更多信息”查看程序名称。

可以在解压后的文件夹中打开 PowerShell，并执行：

```powershell
Get-FileHash .\AgentHalo.exe -Algorithm SHA256
```

输出的哈希值应与 `SHA256.txt` 中的值完全一致。

---

## 项目声明

Agent Halo 是独立的非官方开源项目，与 OpenAI、Quantic Dream 均无隶属或背书关系。
项目不包含游戏素材、名称、Logo 或照搬的指示灯几何造型。

## License

本项目采用 [MIT License](LICENSE) 开源。
