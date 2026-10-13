# OpenCode 监控接入

## 调研与取舍

2026-09-11 调研，Windows 首版实现。macOS 可复用插件与快照协议，本轮不改其手写监控代码。

| 来源 | 借鉴的经验 | Agent Halo 的选择 |
| --- | --- | --- |
| [actualyze-ai/opencode-monitor](https://github.com/actualyze-ai/opencode-monitor) | 插件转发事件，不依靠进程名或文本猜测；连接生命周期单独管理 | 插件直接写本地原子快照，不额外常驻 WebSocket 服务 |
| [mohak34/opencode-notifier](https://github.com/mohak34/opencode-notifier) | busy 到 idle 才算完成；过滤子会话完成；重复事件去重 | 分会话维护状态、并行工具集合与待授权集合 |
| [kdcokenny/opencode-notify](https://github.com/kdcokenny/opencode-notify) | 避免无差别通知，区分需要操作与普通活动 | 复用原有状态环，不新增通知弹窗 |
| [OpenCode 插件文档](https://opencode.ai/docs/plugins/) / [服务接口](https://opencode.ai/docs/server/) | 正式插件钩子、会话事件和模型元数据 | 使用 SDK 读取会话标题、最近 assistant Token、模型上下文上限 |
| [OpenCode 子任务事件问题](https://github.com/anomalyco/opencode/issues/46685) | 子任务的完成与授权不能不加区分地映射到主任务 | 忽略子任务完成，保留子任务授权提示 |

不读取 OpenCode SQLite 私有表，不读取 API 密钥，不抓取界面文本，不上传会话。快照含会话标题、工作目录、模型名与用量统计；不保存消息正文和工具参数。

## 状态规则

| 环与标题 | 依据 |
| --- | --- |
| 灰色 OFFLINE | 无有效插件心跳，且没有 OpenCode 进程；校验进程启动时间，避免 PID 复用 |
| 灰色 CONNECTING | OpenCode 进程存在，但没有有效插件心跳；提示等待监控接入，不推测任务是思考、执行还是待命 |
| 稳定绿色 STANDBY | 插件在线，没有正在进行的任务；历史 idle 不触发完成闪 |
| 黄色 THINKING | `chat.message`、busy/retry；当前没有工具或授权等待 |
| 蓝色 EXECUTING | `tool.execute.before`、运行中的 tool part；上下文压缩钩子 |
| 紫色 ATTENTION | `permission.asked`、`question.asked` 或 question 工具；回复后恢复对应活动 |
| 绿色 COMPLETE | 活动回合收到 idle；重复 idle 不重设完成时间；沿用现有完成展示时长 |
| 红色 ERROR | `session.error`；普通工具失败、API 重试不直接等同于整个任务故障 |

用户主动中止（`MessageAbortedError`）回待命，不报红。文本片段不触发绿色流式输出，避免中间说明被当作最终完成。并行工具只有全部结束才回黄色。

## 安装与使用

1. 在 Windows 右键菜单“监控对象”中勾选 OpenCode。保留原有 Agent 勾选，不自动更改已保存的选择。
2. Agent Halo 将内嵌插件安装到 `~/.config/opencode/plugins/agent-halo-status.js`；尊重 `OPENCODE_CONFIG_DIR` 和 `XDG_CONFIG_HOME`。
3. 重启已经打开的 OpenCode，让插件加载。无需修改 API 配置，也无需安装第二个 EXE。
4. 切换到 OpenCode 图标，复用现有会话卡片：标题、模型、输入/输出、右上角上下文。OpenCode 不显示 ChatGPT 官方额度。

插件每个实例维护一个 `~/.agent-halo/cache/opencode/<pid>-<instance>.json` 原子快照。事件合并窗口 50ms，心跳 3s。Windows 后台每 500ms 读取，15s 无心跳则视为不可用；只在选中 OpenCode 时轮询，不在 WPF 渲染线程做文件或进程检查。

没有消息用量时不伪造数字；上下文为最近 assistant 的 input + cache read/write + output，除以模型上下文上限，不保证等同于服务端下一请求的实际占用。会话首次加载会补读近期消息元数据。

限制：`--pure` 禁用外部插件时无法监控；远程服务器上的插件快照不在本机，也不属于此版本支持范围。心跳代表 OpenCode 实例在线，并不能证明某个终端窗口正在前台。

## 验证

- `node scripts/test-opencode-plugin.mjs`：事件归约、并发工具、权限、重试、压缩、Token、重复完成、子任务和退出清理。
- Windows `--self-test`：快照解析、父子会话、离线/待命/暂停与设置持久化。
- Windows `--render-states`：新增 `panel-opencode.png`，校验与其他面板高度一致，包含全部五个切换图标。
- Windows `--benchmark`：验证动画回归，不等同于长时间真实任务负载测试。
- `scripts/test-opencode-live.ps1`：安装插件，启动仅监听本地回环的临时 OpenCode 服务；创建并删除空测试会话，验证真实插件加载、STANDBY 与进程退出 OFFLINE；不调用模型。

本机 OpenCode 1.18.30 已通过真实服务加载测试。完整模型执行/人工授权流程仍需真实交互验收，不能用模拟事件测试代替。

2026-09-15 实机修复：Windows .NET Framework 的 `Process.HasExited` 对部分运行中的 OpenCode 进程抛出拒绝访问，导致有效心跳被丢弃。改用 `PROCESS_QUERY_LIMITED_INFORMATION` 查询退出状态和创建时间，保留 PID 复用校验；已经用用户正在运行的实例确认可以读取 Thinking，不需要重启 OpenCode。

官方图标来源：[OpenCode Mark](https://github.com/anomalyco/opencode/blob/dev/packages/ui/src/components/logo.tsx)。矢量放在 `src/shared/assets/agent-switch/opencode.svg`，Windows 内嵌同源路径，安装包不依赖外置图标。
