# Cursor 与 DeepSeek Harness MCP 封装评估

日期：2026-11-12。范围：本机任务调度与结果查看，不属于 Gitling iOS App 运行时。本文件保留实施前的设计依据；现已完成首版并注册Codex。当前实现与边界以独立工程的[README](/Volumes/ExternalSSD/git/agent-runner-mcp/README.md)及[验证记录](/Volumes/ExternalSSD/git/agent-runner-mcp/docs/verification.md)为准。

## 本次检查

- 上次 `build/cursor-next-comparison-plan.log` 只有一个换行。其进程退出码虽为0，但没有计划正文，不能视为已完成。下一轮比较功能仍未开始实现。
- 本机 Cursor CLI 支持 `--print --output-format stream-json`、`--mode ask/plan`、`--resume <session>`。最小 ask 探测已收到 `result/subtype=success`、`is_error=false`、`result=MCP_CURSOR_OK`。本次实际计划改用 ask 模式重试，已收到success终态和非空正文，见[计划及评审](../tasks/cursor-commit-comparison-plan.md)；一次空结果不足以证明根因在 plan 模式。
- 本机已安装官方 `@deepseek-ai/dsh`，检查版本为 `0.2.0-rc.2`。`dsh --profile headless --json` 支持一次任务的JSON行事件，`--session-id`恢复已有会话；`dsh --profile sdk`提供Harness自己的JSON-RPC SDK协议，`acp`提供ACP，二者不是现成的MCP服务。
- Harness最小探测退出码0，已收到`final.text=MCP_DEEPSEEK_OK`。探测只发送固定应答请求，没有把仓库内容交给DeepSeek，没有读取凭据文件或更改安全配置。

本次证据在`build/agent-mcp-evaluation/`：单独保存stdout事件流、stderr、进程退出码及摘要。构建目录不入版本控制。

## 结论与首版边界

可以创建一个独立的本地MCP服务，使用两个适配器调度CLI。首版优先stdio和单任务/仓库串行调度，通过持久化job ID查询；后续需要权限交互和更完整的会话控制时，再替换DeepSeek适配器为SDK/ACP。不要在iOS主工程中引入服务或模型依赖。

先支持计划/只读审查，不默认支持写代码、commit、push或修改系统。`dsh`的plan模式只是指导，所有工具仍可调用；只有专用profile移除写入/执行工具、经验证的沙箱等实际约束存在时，才允许宣称“强制只读”。否则应返回`unsupported_mode`，不能仅靠提示词保证。Cursor的ask/plan也应在集成测试中核对实际权限；MCP包装本身不赋予或限制底层代理全部权限。

## 建议的普通MCP工具

以下是自定义工具，不冒充协议内置Tasks方法。

| 工具 | 输入重点 | 返回 |
| --- | --- | --- |
| `agent_backends` | 无 | CLI路径/版本、可用能力、模式与适配器状态；不回显认证信息 |
| `agent_start` | backend、已批准workspace、prompt、mode、timeout、可选session ID | 已落盘job ID、初始状态、建议轮询间隔 |
| `agent_status` | job ID | 状态、阶段、最近事件时间、退出码、错误类别 |
| `agent_events` | job ID、after游标、limit | 有界事件页、新游标、是否还有更多；保留事件序号 |
| `agent_result` | job ID | 最终正文、后端session ID、执行与验证状态、结果文件定位；未完成则明确返回状态 |
| `agent_cancel` | job ID | 取消请求是否已接收，以及最终是否实际停止；不把请求当作停止成功 |

状态至少包含`queued/running/input_required/succeeded/failed/cancelling/cancelled/timed_out/interrupted`。没有权限请求事件的后端，不能根据静默输出猜测“等待授权”；超时应标记超时而非已确认授权阻塞。最终内容支持分页或资源读取，不把巨大日志一次塞进上下文。

## 成功判定与可观测性

- Cursor：退出码0、合法终态`result`、无错误标记、期望任务有非空正文，四者均满足才算成功；CLI版本变化必须重新验证契约。
- DeepSeek headless：退出码0、无失败终态、存在合法`final`和期望正文。单有`final`仍不够，安装包文档说明轮内错误也可能给出空`final`，须结合退出码和`turn_end`原因。
- 正常退出但空答案：`failed/no_result`。流中断、无终态、非法JSON、仅部分文本分别报告，不把partial当最终结果。已有工具调用或文件写入后失败时不自动重试，避免重复副作用。
- 分开记录“代理说完成”“进程已成功”“父代理实际测试通过”。代理宣称测试成功只是报告，验证结果应另附真实命令、退出码、日志与源码版本。
- 每次启动记录工作区realpath、Git HEAD与dirty快照摘要、后端/CLI版本、模式、启动/结束时间、退出码、session ID。日志、结果、元数据先落盘再返回job ID；在外置SSD的独立任务目录持久化，不只依赖终端session。
- 使用官方MCP SDK，stdio stdout仅承载协议；子进程stdout由适配器解析，子进程stderr进入私有日志，MCP诊断走stderr。

## 调度、凭据与恢复

- 命令使用固定可执行文件和参数数组，不接受任意shell命令、额外flags或拼接命令字符串；不传`--force`、`--yolo`、自动批准MCP、改写endpoint或禁用沙箱。
- 工作区用配置白名单和realpath校验；任务自带工程`AGENTS.md`及允许模拟器UDID。遵守现有两台测试设备名单，禁止新建/克隆设备。提示词中的约束不是对任意恶意子进程的OS强制边界。
- 使用现有provider登录或必要环境变量；不要在MCP参数、命令行、响应和日志中传API key，不读取并打印账户配置。客户端默认只能访问脱敏事件摘要；原始日志0600、任务目录0700。
- 同一工作区最多一个可能写入的任务。首版全局并发1即可，等待队列及输出总量设置上限。日志限额耗尽时应明确失败并停止任务，不能悄悄丢终态。
- 创建独立进程组；超时/取消先TERM，再有界等待，必要时KILL整个进程组，并确认结束。取消不会回滚已产生的文件改动。
- 独立worker管理进程，MCP连接断开不应丢失任务。用SQLite/原子元数据记录状态；重启时只有确认worker仍持有该job身份才恢复running，否则标记interrupted，不能仅凭PID存在判断（PID可能复用）。
- MCP调用子代理时禁止子代理再调用同一调度MCP，避免递归任务循环。注册与启用由明确的本机配置步骤完成，本次未执行。

## 实施顺序与测试

1. 独立工程创建job store、后端事件解析器、普通MCP工具与模拟CLI；暂不自动注册到任何客户端。
2. 用离线模拟子进程测试：成功、退出0但空结果、非法/截断JSON、终态错误、stderr污染、权限请求、超时、取消进程树、并发/队列上限、日志上限、重启恢复及路径越界。
3. 分别做最小真机CLI协议验证，再用Cursor运行只读比较计划；DeepSeek审查真实仓库前需明确任务和数据范围。
4. 再增加受控实现模式、人工接管权限请求及SDK/ACP适配；根据客户端能力决定是否采用MCP Tasks扩展，不把扩展支持当成默认前提。

参考：
- [Cursor CLI结构化输出](https://docs.cursor.com/en/cli/reference/output-format)
- [MCP服务构建与stdio日志规则](https://modelcontextprotocol.io/docs/develop/build-server)
- [MCP Tasks扩展](https://tasks.extensions.modelcontextprotocol.io/)
- [DeepSeek Harness官方工程](https://github.com/deepseek-ai/deepseek-harness)

DeepSeek具体接口和边界已对照本机安装包的`dsh-headless`、`dsh-sdk-app`和`dsh-plan-mode`的README及对应构建代码；升级时需复核，不将本机版本行为当作永久契约。

## 首版实施完成（2026-11-12）

实现位于独立目录`/Volumes/ExternalSSD/git/agent-runner-mcp`，没有向iOS应用引入依赖。提供6个普通MCP工具，支持只读任务启动、状态、增量日志、结果分页、取消和执行超时；SQLite持久化与独立worker支持断连查询、串行调度及中断恢复。

两后端都使用实际macOS文件写入/进程执行限制，DeepSeek增加专用profile和只读overlay。Cursor现有登录通过可信调度层读取固定Keychain项临时传递，不向子代理开放security命令、不在响应或日志中写出token。具体读取及网络边界见实现README，不把提示词当作OS隔离。

最终离线回归38/38通过，无跳过；两个真实后端通过MCP读取验证夹具并返回正确标记，Codex CLI实际调用agent_backends成功。服务已全局注册为`local_agent_runner`。没有新增或操作模拟器，保留3台及原白名单。实现仅首版只读，不包含写代码、会话续跑或批准应答；不自动commit/push。

## 受控会话续接已实施（0.2，2026-11-12）

新增`agent_resume`、`agent_handoff`、`agent_context`，共9个工具。任务、后端对话、单轮job分别标识；只允许最新成功的托管轮次复用原生会话。绑定工作区规范路径及inode、后端CLI入口/版本与只读沙箱策略；数据库事务阻止并发分叉，不接受外部session ID，旧版历史保持可查询。

执行前复查绑定并生成有界代码变更检查点。Cursor→DeepSeek通过新对话和显式摘要交接，保留开发任务ID，不宣称共享隐藏历史。Cursor恢复会话的固定临时锁和tmux查询已做窄范围兼容，不允许shell、任意tmux命令或工作区写入。

49项离线回归通过，无失败或跳过。两个真实后端均跨MCP连接复用SID、记住未重发的随机标记、读取父进程更改后的夹具；Cursor→DeepSeek交接成功。用户模拟器白名单保留，本轮不操作模拟器、不访问原Git远端、不修改iOS运行时代码。详细约束、调用示例和证据见独立工程README及验证记录。
