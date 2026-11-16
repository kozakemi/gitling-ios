# iSH 内嵌原型：受控挂载与会话生命周期

> 本文保留隔离原型的重现方式和阶段性测量。正式应用现已接入持久 PTY、自动启动、跨 Tab 暂停与恢复及设置中的环境重设；当前行为和验证见 [主 README](../../README.zh-CN.md) 与 [运行时说明](../../Vendor/IshRuntime/README.md)。以下原型数据不代表最新完整回归结果。

原型阶段（2026-11-16）修复上一版复现的任意宿主目录挂载、后台子孙进程逃逸及超时退出确认问题，补齐原生读取门禁。仍只运行隔离夹具，不替换普通控制台，也未开放交互 PTY 或真实用户仓库选择。

## 构建与重现

从工程根目录执行。首次只获取固定的公开依赖；缓存齐全后离线运行，不访问原始性能服务器。

```sh
python3 Prototypes/Ish/prepare.py
python3 Prototypes/Ish/run.py --device 0ED9A62A-B9F4-4BC9-AA3B-0CF0B3D93F1E --fresh
python3 Prototypes/Ish/run.py --device D2A546B7-9C01-4668-B2EE-F13A1B9FC9D5 --fresh
python3 Prototypes/Ish/test_layout.py --device D2A546B7-9C01-4668-B2EE-F13A1B9FC9D5
python3 -m unittest discover -s Prototypes/Ish -p 'test_*.py'
```

只接受上述既有白名单设备，不创建、克隆、擦除或删除模拟器。构建、依赖、日志及备份写在 SSD `build/`，DerivedData 按 UDID 区分。`--fresh` 终止 QA App 后把旧原型目录归档到 `build/ish-prototype/previous-*`，不清空正常仓库、账户或授权。普通 `scripts/test.sh` 恢复默认构建。

依赖基于 [IshEmbed v0.3.3](https://github.com/Lolendor/ish-arm64-pkg/releases/tag/v0.3.3) 的 iSH ARM64 分支。`dependencies.json` 固定运行库、rootfs、25 个 Alpine 安装包 SHA256 和内核源提交 `2f075626049d989dc9ac350a35c09f0b18930ffc`。`build_policy.py` 从该提交重编译策略对象，替换静态库中对应对象，保留未修改的解释器/VDSO，不改变内核结构体布局。生成物仅在 `build/ish-prototype/policy/`。

内核及嵌入层按 GPL-3.0 分发，Alpine 各包保留各自许可。只通过脚本增加 `ISH_PROTOTYPE` 条件、C 桥和链接；普通 App 不包含 iSH，新增原生访问门禁则正常工作。未把第三方运行库或 Linux 二进制加入源码仓库。

## 文件系统边界

运行在 Gitling 的实际进程和 App 沙盒中。Guest 可使用自己的 Linux rootfs、运行时私有资源和宿主明确授权的 `/shared`；Guest root 权限不构成宿主授权。

- Guest mount/umount 系统调用一律拒绝，包括重新挂载、绑定挂载和 Guest root。宿主专用入口安装固定的共享目录描述符。
- `SecureHostFS.h` 逐层以不跟随符号链接的目录描述符解析路径，最终打开也使用 `O_NOFOLLOW`；覆盖读写、创建、stat/readlink、截断、重命名、删除、mkdir/symlink 及元数据修改，避免检查与使用之间的替换竞争。
- 截断推迟到已打开 inode 检查后。拒绝多链接普通文件、Guest 创建硬链接及共享目录 FIFO。Git 本地复制用例显式采用 `--no-hardlinks`；匿名管道不受此限制。含宿主硬链接的导入仓库需要先处理，不能宣称这类仓库完整兼容。
- 关闭 fakefs 宿主绑定注册旁路和 native offload。合法的仓库内相对符号链接仍按 Guest 语义解析；越界绝对链接、宿主硬链接及中间/最终路径替换不能读取或修改哨兵文件。

共享副本来自既有 `build/performance-fixtures/Js_ms_rtos.git`，无 hardlink/alternates、移除缓存远端，运行前后核对原始夹具全文件摘要不变。夹具含 408 个可达提交、HEAD 下 1,913 个文件、约 20 MiB 裸 Git 数据。

## 进程树与取消

原型明确只允许一个全局 Guest 调用，不支持多个并行 Shell/VM。PID 1 仅作为受信 supervisor，其余任务都归属当前串行调用；`setsid`、改变进程组、重定向输出、父进程退出或重新收养不能逃离清理。

在创建 pthread 前增加计数，在实际 pthread 最后阶段的清理回调中减少计数；关闭内核把未退出线程摘链并伪装为已退出的路径。不能仅依据 leader EXITED、pipe EOF 或 zombie 列表确认结束。

成功或非零退出也清理残留子孙任务。超时/取消通知全部非 PID1 任务，有界睡眠及可中断读取让 SIGKILL 能及时被处理。仅在收到 leader 退出事件且活动 Guest 线程为零后返回。取消 token 绑定本次调用，旧调用迟到取消不影响下一调用。

五秒清理期后仍无法确认时返回 `-1001`，Swift 在释放门禁/仓库租约前终止宿主，不通过普通错误展开后继续运行。真实不可中断设备 I/O 的失败关闭分支尚未进行真机验证；本轮也不代表整个模拟内核已完成通用不可信代码沙箱审计。

## 读写协调

`RepositoryAccessGate` 使用 App Group 内统一的跨进程 flock。原生操作共享持有，Guest 在整棵进程树期间独占。原型保守地暂停所有仓库的原生访问，覆盖别名及嵌套仓库；尚未做每仓库细分或并行 Guest。

门禁覆盖 GitClient 公共读/写入口、独立 OpenRepo 句柄、文件搜索 reader、工作文件预览、WorkingTree 和 File Provider。独立历史搜索、文件历史和比较句柄也保留租约；已打开的游标在销毁前阻止 Guest，启动交互终端时需取消并释放游标，不能只停止页面发布。

Guest 持锁期间原生读写快速返回 busy；File Provider 不能同时访问工作区。现有 `RepoWriteLock` 继续协调原生 Git 与 File Provider 写入。退出确认后，原生 libgit2 看到相同 HEAD/OID 与索引，写入恢复成功。

## 回归与性能

两台原型各 63 条检查全部通过，包含真实 `/bin/sh`、Git 2.43.7 提交/merge/rebase/cherry-pick/stash/tag/blame/restore、本地 clone/fetch/push、双向共享及完整 fsck，不是对全部 Git 子命令/选项的穷举认证。

新增验证覆盖越界 mount/umount、符号链接、合法共享内链接、宿主硬链接、正常/非零退出与超时/取消时脱离进程组的子孙、CPU 忙循环、迟到取消、退出后重取原生租约及等待超过攻击延时后无迟到写入。宿主使用同一描述符解析器执行 20,000 次并发符号链接替换。

默认构建 iOS 18.6 和 Duo 各 328/328 通过。准备及路径测试 4/4，Duo 布局专项 1/1（240/346/466/619/951 点及标准/辅助字号，共 10 组）通过。此前 Markdown 异步等待修正保留，未降低字号断言。

加固路径解析增加显著开销。同宿主 Debug 模拟器、三次热样本中位数如下，单位 ms。Shell 包含启动/协议/输出收集，测试顺序未随机化，不能用作算法或手机真机性能对比：

| 操作 | iOS 18.6 Shell | Duo Shell | Duo 原生 |
| --- | ---: | ---: | ---: |
| status | 3110.2 | 2483.6 | 90.7 |
| log 100 | 54.6 | 39.1 | 3.3 |
| checkout develop | 2314.5 | 1865.4 | 见原始 JSON |
| checkout master | 2554.3 | 2209.4 | 见原始 JSON |

日常刷新、历史和检出继续使用原生通道。后续描述符缓存优化必须保留路径替换和 inode 边界，不能退回 realpath 检查后打开字符串路径。

结果、日志、截图及摘要在 SSD `build/ish-prototype/policy-*` 和 `results-<UDID>.json`，不纳入版本控制。未接入交互 PTY/ANSI、外部工作区授权、真实用户仓库选择、SSH/LFS/Keychain、系统挂起/崩溃恢复及真机验收；任意命令入口仍禁用。本轮未 commit/push。
