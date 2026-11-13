# Gitling iOS 本机协作约束

## 模拟器（含 Cursor Agent）

本机只允许使用以下现有设备运行测试，命令必须指定 UDID：

- 默认完整回归：iPhone 16 Pro / iOS 18.6，`0ED9A62A-B9F4-4BC9-AA3B-0CF0B3D93F1E`。
- Duo 适配及新系统回归：Gitling Duo Layout QA / iOS 27.2，`D2A546B7-9C01-4668-B2EE-F13A1B9FC9D5`。
- 用户原有 iPhone Duo：`28474273-D7E2-4599-9D76-43642D39CB22`，只保留，不运行自动化、不安装、不清空、不删除。

禁止自行创建、克隆、擦除或删除模拟器；禁止 `simctl create/clone/erase/delete`、Xcode 自动选择任意设备或并行测试克隆。设备不可用时报告问题，不创建替代设备。除用户明确授权外，不下载/删除运行时或改动其他工程的模拟器。运行测试加 `-parallel-testing-enabled NO`，同一设备不能同时运行两轮测试。

优先使用 `./scripts/test.sh`。指定 Duo：

```sh
TEST_DESTINATION='platform=iOS Simulator,id=D2A546B7-9C01-4668-B2EE-F13A1B9FC9D5' ./scripts/test.sh
```

测试脚本默认把 DerivedData 按目标 UDID 分开保存在外置 SSD 的 `build/TestDerivedData-<UDID>`，避免不同运行时的资源裁剪复用旧签名。若覆盖 `TEST_DERIVED_DATA`，两台设备也必须使用不同目录；不要复用旧的共享 `build/TestDerivedData` 安装产物。

调用 `cursor-agent` 时，在任务文本中再次明确本次允许使用的 UDID，要求先阅读本文件及 `.cursor/rules/simulators.mdc`。不使用 `--force`/`--yolo` 绕过命令拒绝；若 Cursor 不能运行 shell，由父代理负责验证。

云端 CI 的临时宿主不使用上述本机 UDID；允许选择该 CI 宿主已有的 iPhone 设备，仍禁止为测试创建克隆。

测试尽量复用 `build/performance-fixtures/Js_ms_rtos.git` 和 `build/performance-fixtures/fixed_unit_queue.git` 等现有离线夹具，不自行拉取原始性能服务器。构建、结果与备份写到外置 SSD 上的工程 `build/`，测试前留意内置磁盘空间，空间不足先报告。

## 当前协作方式（2026-11-13）

用户最新要求：除非再次明确声明恢复，不再调用 Cursor 或 DeepSeek（包括本地MCP启动、续接与交接）。由Codex直接排查、实现、审查和测试；下述历史代理流程暂停适用。

## 历史代理协作流程（当前暂停）

用户指定：Codex负责规划、验收和最终审查；通过本地MCP优先Cursor，Cursor失败或能力不适用时再使用DeepSeek。遵循`docs/tooling/agent-collaboration.md`。

现有`local_agent_runner`只允许read_only任务。实现任务由子代理返回可审查的补丁文本，不修改工作区；Codex核验基线、文件范围、路径与补丁有效性后应用，再独立审查和测试。不要为此自动放开MCP写权限，也不要把原始CLI调用冒充MCP调用。

空结果、非成功终态、超时、协议错误或明确能力限制可触发DeepSeek后备；先确认前一任务终止。编译/功能问题优先将精确失败和上下文反馈Cursor修正，不立即切换模型。两者均失败时报告证据，不伪称实现完成。

除用户本次任务另有授权，不自动commit/push。子代理报告的测试成功不替代Codex实际验证。模拟器白名单和离线仓库复用约束继续适用。
