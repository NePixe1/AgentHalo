# Agent Halo

Codex 桌面端的本地常驻状态光环。  
A local, always-on-top status halo for the Codex desktop app.

当前版本支持 Codex；后续计划加入 Claude Code（CC）状态识别。  
The current release supports Codex, with Claude Code detection planned next.

版本 / Version: `0.9.6`（预发布 / Pre-release）

---

## 中文说明

### 系统要求

- Windows 10 或 Windows 11
- 已安装并使用 Codex 桌面端
- .NET Framework 4.8（目前的 Windows 10/11 通常已自带）

### 安装与运行

1. 解压整个 ZIP 压缩包，不要直接在压缩包内运行。
2. 双击 `AgentHalo.exe`。
3. 光环会出现在主显示器右上方附近。

程序没有安装器，不会修改 Codex，也不需要 OpenAI API Key。

### 操作

- 拖动光环：调整位置，靠近屏幕边缘时会自动吸附。
- 左键单击：查看当前及最近的 Codex 会话。
- 绿色会持续缓慢呼吸；再次打开 Codex 后自动确认并恢复待机。也可单击手动确认。
- 右键单击：打开状态预览、暂停监听、开机启动和退出菜单。
- 双击：将 Codex 窗口切到前台。

### 状态含义

- 黄色呼吸：Codex 正在思考或规划。
- 蓝色流动：Codex 正在执行命令、搜索、编辑文件或调用工具。
- 绿色双闪：Codex 已完成；高亮两次后持续缓慢呼吸，直到你再次打开 Codex。
- 红色双脉冲：Codex 需要输入、授权或遇到了问题。
- 暗白色：当前没有待处理任务。

大断点会追赶缓慢往返漂移的小断点；接近约 40° 时，小断点会像受到磁斥一样
平滑推开到约 150°，随后带着逐渐衰减的惯性继续滑行并往返漂移。待机也会
持续运动，思考和执行状态转得更快。思考和执行期间，环条本体会从暗色材质
逐渐点亮：主体升为亮白灯芯，状态色保留在灯管边缘；窄光晕同步增强，中心透明。
执行状态的完整呼吸周期约 3.2 秒，思考状态约 5.2 秒。磁斥时长和离场惯性
会根据当前实际转速自动调整，慢状态不会被突然拉走。
动画直接跟随桌面合成刷新频率，不再对待机或完成状态主动降帧。
“暂停状态监听”只在当前运行期间有效，重新启动后会自动恢复实时监听。
工具输出后蓝色会短暂保持约 1.8 秒，让快速工具调用也能清楚看见执行状态。

### 隐私

Agent Halo 只在本机读取 `%USERPROFILE%\.codex\sessions` 中的生命周期事件，
用于判断开始、工具执行和完成状态。它不会上传数据、调用网络服务、显示聊天内容，
也不会读取或保存 OpenAI API Key。

### Windows 安全提示

这是一个未购买商业代码签名证书的自制程序，因此 Windows SmartScreen 可能提示
“Windows 已保护你的电脑”。请只在确认压缩包来自可信发送者、并核对
`SHA256.txt` 后运行。确认无误时，可选择“更多信息”查看程序名称。

可以在解压后的文件夹中打开 PowerShell，并执行：

```powershell
Get-FileHash .\AgentHalo.exe -Algorithm SHA256
```

输出的哈希值应与 `SHA256.txt` 中的值完全一致。

---

## English

### Requirements

- Windows 10 or Windows 11
- The Codex desktop app installed and in use
- .NET Framework 4.8, normally included with current Windows 10/11 systems

### Install and run

1. Extract the entire ZIP archive. Do not run the app from inside the ZIP.
2. Double-click `AgentHalo.exe`.
3. The halo appears near the upper-right corner of the primary display.

There is no installer. Agent Halo does not modify Codex and does not require an
OpenAI API key.

### Controls

- Drag the halo to reposition it; it gently snaps to display edges.
- Left-click to inspect active and recently completed Codex sessions.
- Green breathes slowly until Codex returns to the foreground. Click it to acknowledge manually.
- Right-click for state previews, pause, startup, and exit controls.
- Double-click to bring the Codex window forward.

### Status language

- Amber breathing: Codex is thinking or planning.
- Blue orbit: Codex is running a command, search, edit, or tool.
- Green double flash: Codex finished, then breathes slowly until Codex returns to the foreground.
- Red paired pulse: Codex needs input or encountered a problem.
- Dim white: no pending activity.

The large gap chases a small gap that drifts gently back and forth. Near 40° of
separation, the small gap is smoothly repelled toward roughly 150°, then coasts with
decaying momentum before returning to its bounded drift. Thinking and working
accelerate the motion. The ring body itself powers up from a dim material into a
bright white core while the state color remains around the tube edge. Its narrow bloom
increases while the center stays transparent. A full working pulse takes roughly
3.2 seconds; thinking takes roughly 5.2 seconds. Repulsion duration and exit momentum
scale from the current orbit speed. Animation follows the desktop
composition refresh rate without lowering idle or completed states to 30 FPS.
Monitoring pause is runtime-only and automatically clears on the next launch.
Blue remains visible for roughly 1.8 seconds after a tool returns, so short tool calls
still produce a readable execution state.

### Privacy

Agent Halo reads lifecycle events from `%USERPROFILE%\.codex\sessions` locally to
detect task starts, tool activity, and completion. It does not upload data, call a
network service, display conversation content, or read/store an OpenAI API key.

### Windows security notice

This personal build is not signed with a commercial code-signing certificate, so
Windows SmartScreen may display a warning. Run it only when the archive came from
a trusted sender and the value in `SHA256.txt` matches the executable. Select
"More info" to inspect the application name before making a decision.

To verify the file, open PowerShell in the extracted folder and run:

```powershell
Get-FileHash .\AgentHalo.exe -Algorithm SHA256
```

The resulting hash must exactly match the value in `SHA256.txt`.

---

## Project notice / 项目声明

Agent Halo is an independent, unofficial open-source project. It is not affiliated
with or endorsed by OpenAI or Quantic Dream. It uses no game assets, names, logos,
or copied indicator geometry.

Agent Halo 是独立的非官方开源项目，与 OpenAI、Quantic Dream 均无隶属或背书关系。
项目不包含游戏素材、名称、Logo 或照搬的指示灯几何造型。


