# 真实仓库的离线性能测试

日期：2026-11-10。对象：用户提供的 Js_ms_rtos 仓库。本报告不包含登录凭据。

## 获取与隔离

只执行了一次完整历史的 `git clone --bare --no-tags`，耗时约 10.65 秒；没有递归更新子模块或下载 LFS。克隆完成后删除缓存仓库的 HTTP remote。之后所有检查、分支切换和测试都在本地进行，没有再执行服务器 fetch/pull。

缓存位于被 Git 忽略的 `build/performance-fixtures/Js_ms_rtos.git`。安装脚本只接受本地目录，要求无 remote、非浅克隆；不会自动下载。测试工作副本的 origin 只指向模拟器内的本地文件 URL。

数据快照：

- HEAD：`b4d1445acccf60cafd510178f7f1d573f25c6105`，默认分支 master。
- 14 个分支，全部分支可达提交共 408 个；master 可达提交 49 个。
- master 中有 1,913 个文件，总内容约 52.34 MiB，最大单文件约 4.60 MiB。
- bare 缓存约 20.16 MiB。标签未下载，测试不覆盖标签加载。

## 方法

测试调用应用实际使用的 `GitClient` / libgit2，不以桌面 Git 命令的耗时代替应用耗时。

环境为 Xcode 27.2、arm64 iPhone 17 / iOS 27.0 模拟器。Debug 和 Release 分别运行；Release 测试开启 `ENABLE_TESTABILITY=YES`，使用 arm64 活动架构。没有清空操作系统文件缓存，所谓“首次调用”仅指新工作副本内第一次调用，不代表设备冷启动或冷磁盘。

分支切换使用实际分支：

- master 与 develop：16 个路径存在差异。
- master 与 why_md：471 个路径存在差异；why_md 可达提交 396 个。

每个方向重复 7 次，报告中位数。“切换与刷新”重复 3 次，依次包含 checkout、Store 完成时的 summary、详情页 header、全部分支的前 300 条历史、提交图数据计算和详情缓存保存。初始本地克隆、测试断言和返回原分支不计入该项。

历史重复调用各 9 次。除计时外，还检查全历史数量、提交唯一性、分页顺序、相邻页不重复及选中分支计数。

## 分支切换结果

单位：ms，中位数。

| 路径 | Debug | Release |
| --- | ---: | ---: |
| master → develop，检出本身 | 41.50 | 48.68 |
| develop → master，检出本身 | 48.61 | 52.69 |
| master → why_md，检出本身 | 289.94 | 297.37 |
| why_md → master，检出本身 | 200.49 | 207.09 |
| master → develop，切换与刷新 | 91.54 | 95.24 |
| master → why_md，切换与刷新 | 336.46 | 353.44 |

首次选择远程分支并创建本地跟踪分支：Release 下 develop 为 52.43 ms，why_md 为 305.54 ms，均为单次结果。

Debug 与 Release 检出耗时接近，并非 Swift 优化级别越高就一定更快；这些路径主要运行相同的预编译 libgit2，并受文件系统缓存、文件写入及进程调度影响。

## 历史加载结果

单位：ms。首次调用为单次值，其余为中位数。

| 路径 | 返回数量/范围 | Debug | Release |
| --- | --- | ---: | ---: |
| 全部分支历史首次读取 | 前 300 条 | 4.13 | 4.11 |
| 全部分支历史重复读取 | 前 300 条 | 3.89 | 3.75 |
| 全部分支第二页 | offset 300，108 条 | 3.53 | 3.52 |
| 当前 master 分支历史 | 49 条 | 0.74 | 0.71 |
| 指定 why_md 分支历史 | 前 300 条 | 2.57 | 2.51 |
| 首屏提交图数据计算 | 300 条 | 0.48 | 0.07 |
| 追加第二页后的图数据计算 | 408 条 | 0.66 | 0.10 |
| 首屏详情缓存保存并读取 | 300 条 | 1.33 | 1.31 |

缓存项包括 JSON 编解码和 UserDefaults 调用，不代表同步刷盘完成。提交图项仅测量 `CommitGraph.rows` 的数据计算，不包括 SwiftUI / Canvas 绘制与首帧呈现。

## 结论与限制

这个快照中，历史数据读取不是主要耗时来源。471 路径差异的分支切换，检出本身约占所测完整数据处理链的 84%；全部分支历史读取只需约 4 ms。

更换数百个文件的检出可感知到约 0.2–0.3 秒等待，叠加刷新约 0.35 秒。若实际使用仍有数秒等待，下一步应在真机上分别记录 Git 锁等待、checkout、列表刷新、历史数据准备、SwiftUI 首帧，以及外部文件提供方的文件下载/协调耗时。

本基准使用模拟器本地工作区，不包含真机性能、iCloud/第三方 File Provider、网络操作期间的全局锁竞争或界面渲染。408 个提交也不足以证明数万提交仓库的性能；当前 offset 分页仍会从头建立 revwalk，深分页的扩展性需要更长历史的独立基准。

## 离线复测

已下载的缓存可反复使用，无需再次联系服务器：

```sh
./scripts/install-offline-benchmark-fixture.py \
  build/performance-fixtures/Js_ms_rtos.git \
  --device <simulator-udid>
```

运行 `OfflineRepositoryPerformanceTests`，日志中 `OFFLINE_PERF` 行包含每次采样的 JSON。没有安装本地夹具时，这两个测试明确跳过，不会自动克隆或联网。

完整回归仍可运行：

```sh
./scripts/test.sh
```

本次原始采样另保存在被忽略的 `build/performance-fixtures/results-debug.json` 和 `results-release.json`。
