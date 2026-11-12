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

调用 `cursor-agent` 时，在任务文本中再次明确本次允许使用的 UDID，要求先阅读本文件及 `.cursor/rules/simulators.mdc`。不使用 `--force`/`--yolo` 绕过命令拒绝；若 Cursor 不能运行 shell，由父代理负责验证。

云端 CI 的临时宿主不使用上述本机 UDID；允许选择该 CI 宿主已有的 iPhone 设备，仍禁止为测试创建克隆。

测试尽量复用 `build/performance-fixtures/Js_ms_rtos.git` 等现有离线夹具，不自行拉取原始性能服务器。构建、结果与备份写到外置 SSD 上的工程 `build/`，测试前留意内置磁盘空间，空间不足先报告。
