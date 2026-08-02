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
    <img src="https://img.shields.io/badge/macOS-13%2B-000000?style=for-the-badge&logo=apple&logoColor=white" alt="macOS 13+"/>
    <img src="https://img.shields.io/badge/Windows-10%20%2F%2011-0078D4?style=for-the-badge&logo=windows&logoColor=white" alt="Windows 10 / 11"/>
    <img src="https://img.shields.io/badge/local--first-0F172A?style=for-the-badge" alt="本地优先"/>
    <img src="https://img.shields.io/badge/license-MIT-14B8A6?style=for-the-badge" alt="MIT 许可证"/>
  </p>
  <p>无需切换窗口，随时知道编码 Agent 正在思考、执行、完成、受阻，还是等待你。</p>
  <p><a href="README.md">English</a> | 简体中文</p>
</div>

---

## 功能亮点

- **一眼看懂状态。** 一枚常驻光环区分规划思考、工具执行、任务完成、等待输入与阻断故障。任务完成后会持续呼吸，直到你确认它。
- **多个 Agent，一个焦点。** Agent Halo 并行监听已支持的 Agent，光环与详情面板只跟随当前选中的对象；切换焦点不会停止其它监听。
- **需要时再看详情。** 悬停可查看官方额度、上下文或会话信息。自定义 Codex / API Key 会话显示项目、模型与本轮输入/输出 Token，但不暴露 API Key、Base URL 或中转工具名称，也不伪造官方额度。
- **真正的原生桌面体验。** Windows 与 macOS 应用无需浏览器或云端面板；支持置顶、拖动吸附、缩放、暂停、开机启动以及显示器变化后的位置恢复。
- **从设计上保持本地。** 生命周期与会话内容留在本机。官方额度刷新复用已有登录；Agent Halo 不需要、也不会读取 OpenAI API Key。

## 平台支持

| 平台 | 支持的 Agent | 系统要求 |
| --- | --- | --- |
| Windows | Codex、Claude Code | Windows 10 或 11；.NET Framework 4.8（通常已自带） |
| macOS | Codex、Claude Code、Grok Build | macOS 13 及以上 |

使用前请至少安装并登录一种受支持的 Agent。Grok Build 监听目前仅支持 macOS。

## 安装

从 [GitHub 最新版本](https://github.com/NePixe1/AgentHalo/releases/latest) 下载。

### Windows

1. 下载 `AgentHalo-Windows-v*.zip`。
2. 解压整个压缩包（不要在压缩包内直接运行）。
3. 双击 `AgentHalo.exe`，光环会出现在主显示器右上方附近。

### macOS

1. 下载 `AgentHalo-macOS-*.dmg`。
2. 打开 DMG，将 Agent Halo 拖入「应用程序」。
3. 从「应用程序」启动。Agent Halo 为菜单栏应用，不显示 Dock 图标。

官方账号不需要 OpenAI API Key。可用时，额度刷新会复用你已有的提供商登录。

## 快速使用

- **拖动**光环调整位置，靠近屏幕边缘会轻微吸附。
- **悬停**查看状态与额度 / 会话详情；macOS 可切换 **Codex / CC / Grok**，Windows 可切换 **Codex / CC**。
- **单击**光环可将 Codex 窗口切到前台（在相关场景下）。
- **右键**打开状态预览、临时暂停、开机启动、置顶、光环大小（`75% / 100% / 125%`）、**脱离卡死**与退出。暂停会在下次启动时自动取消。
- 显示器变化后，离屏光环会回到主屏。macOS 还会在原显示器重新连接后恢复记忆位置。

## 状态颜色

| 颜色 | 含义 |
| --- | --- |
| 黄色（呼吸） | 思考 / 规划 |
| 蓝色（呼吸） | 正在执行命令、搜索、编辑或调用工具 |
| 绿色双闪 → 缓慢呼吸 | 任务已完成，正在等待你确认 |
| 紫色双脉冲 | 等待授权、确认或输入 |
| 红色 | 故障或中断导致任务无法继续 |
| 稳定绿色 | 当前聚焦的 Agent 正在运行，但没有活动任务 |
| 暗白色 | 暂无可见的被监听活动 |

## 隐私

- 生命周期与会话内容**仅留在本机**，不会上传对话或会话正文。
- Agent Halo **不会**读取或保存 OpenAI API Key，也不在界面显示 Key 或私有端点信息。
- 可选的额度查询使用你已有的登录凭据，并只访问官方接口。
- 刷新 Codex 额度时，OAuth Token 不会存入 Agent Halo 缓存；额度快照只包含账户哈希、百分比和重置时间。

路径、hooks 与缓存布局等实现细节见 [AGENTS.md](AGENTS.md)。

## 常见问题

### Windows SmartScreen 提示

个人 Windows 构建未使用商业代码签名，SmartScreen 可能提示警告。请只运行可信来源的压缩包，并核对 `SHA256.txt`：

```powershell
Get-FileHash .\AgentHalo.exe -Algorithm SHA256
```

输出的哈希必须与 `SHA256.txt` 中的值完全一致。

### macOS 上 Grok Build hook 重复

Grok Build 默认也可能加载 Claude Code 的 `~/.claude/settings.json` hooks（兼容模式）。因此同一条 Agent Halo 状态 hook 在 Grok 会话里可能出现两次（`agent-halo-status` 与 `settings`）。功能正常，只是重复执行。

若只想保留 Grok 原生路径，可在 `~/.grok/config.toml` 中设置：

```toml
[compat.claude]
hooks = false
```

这只关闭 Claude hooks 导入，不影响 skills / rules / MCP，也不影响 Claude Code 本身。修改后需重启 Grok 会话才会生效。若你还有**仅**写在 `~/.claude/settings.json` 中的其它 hooks，关闭后它们在 Grok 中也不会再运行。

## 开发与贡献

README 有意只保留安装与使用信息。架构、源码构建、诊断、共享契约修改与贡献者检查见 **[AGENTS.md](AGENTS.md)**。

## 许可证

本项目采用 [MIT License](LICENSE) 开源。
