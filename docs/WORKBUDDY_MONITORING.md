# WorkBuddy Windows 监控

## 数据来源

在本机 WorkBuddy 2.137.1 CLI 对应的桌面安装上验证。仅只读访问本地数据，
不修改 WorkBuddy 配置、不注入程序、不安装 hook，也不调用需要认证的本地 HTTP 接口。

- `~/.workbuddy/sessions/*.json`：通过 PID 和进程创建时间确认活会话。忽略 `kind=prewarm`。
- `~/.workbuddy/workbuddy.db`：`sessions` 表提供会话状态、标题、目录、模型、更新时间。
- 同一数据库的 `session_usage` 表：`used / size` 提供上下文占用及实际窗口大小。
- `~/.workbuddy/projects/<转义目录>/<sessionId>.jsonl`：模型响应的
  `message.usage.input_tokens / output_tokens` 提供最近一次响应的输入/输出，
  `providerData.requestModelName` 提供模型显示名。不是累计账单用量。

SQLite 使用 Windows 自带的 `winsqlite3.dll`，只读打开，兼容 WAL；不打包 `sqlite3.exe`。
后台至多每 500ms 发起一次扫描，只在选中 WorkBuddy 且未暂停时轮询；
JSONL 首次只读尾部，后续增量读取，不在 UI 线程扫描文件。

## 状态映射

| WorkBuddy 原生状态 | Agent Halo |
| --- | --- |
| `planning` | 黄色 Thinking |
| `working`、`streaming` | 蓝色 Working |
| `pending`、`waiting_permission`、`waiting_question`、`paused` | 紫色 Attention |
| `completed` | 绿色 Done，8 秒后稳定绿色待命 |
| `error`、`failed`、`interrupted` | 红色 Error |
| 应用在线、没有活动任务 | 稳定绿色 Standby |
| 应用进程退出 | 灰色 Offline，隐藏旧会话数据 |
| 应用在线但数据库无法读取 | 灰色 Connecting，不假装完成 |

状态以 WorkBuddy 自己的状态机为准，不把 assistant 中途输出视为任务完成，
不根据日志停止更新猜测任务结束，不把单个工具报错直接视为整轮失败。
历史活动记录必须匹配活会话；历史完成记录不会在重启 Agent Halo 后重播完成提醒。
应用自身的 `paused` 表示任务等待，和 Agent Halo 的“暂停监控”不是同一概念。

## 面板与启用

沿用现有会话卡片：标题、模型、最近一次响应输入/输出、右上角上下文占用。
现有监控对象勾选列表保持原样；在“监控对象”中启用 WorkBuddy 后可切换查看。
六个对象全部启用时压缩切换槽位，面板宽高不变。

`docs/assets/agent-switch/workbuddy.png` 来自已安装官方客户端的
`resources/app.asar.unpacked/resources/icon.png`，品牌归原权利人所有。
图标内嵌进 EXE，运行时不依赖 docs 目录。

## 验证与边界

- 本机持续任务期间观察到原生 `planning / working` 切换，结束后状态为 `completed`。
- `--workbuddy-snapshot <输出文件>` 可生成不含正文、密钥的诊断快照。
- self-test 覆盖状态映射、旧记录排除、完成生命周期、勾选记忆、JSONL 增量及半行写入。
- 授权、故障分支来自本机安装版本的原生状态定义及合成测试，未人为中断真实任务触发。
- 本轮只实现 Windows；macOS 只同步通用翻译，不新增监控逻辑。
- 本地数据库不是承诺稳定的公共 API。后续 WorkBuddy 改版可能需要适配；
  当前仅覆盖本机本地会话，远程或云端任务不保证能检测到。
