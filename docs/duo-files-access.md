# Duo 模拟器文件访问修复

2026-11-11。建议入口为 **“文件”App → 浏览 → Gitling**；系统导入选择器同样选择“浏览 → Gitling”。若未显示位置，点击“更多 → 编辑”启用 Gitling。首次访问可能要求打开 Gitling 完成激活。

## 诊断和修复

本轮发现两类工程缺陷及一项模拟器系统限制：

1. 工程禁用了模拟器标准签名，再用脚本手动签 App Group。手动签名没有 Xcode 注入的 Mach-O 模拟身份，File Provider 注册报告 applicationExtensionNotFound。脚本还在 XCTest 更新测试包之前签父应用，导致测试后资源封印失效。已恢复 Xcode 对应用和扩展的标准模拟器签名，删除手工签名阶段；设备未签名构建仍可通过命令行显式关闭签名。
2. 扩展曾用自身沙箱计算 Documents 和元数据路径，并在初始化中重复执行仓库迁移。现在由宿主迁移完成后在 App Group 原子发布实际仓库根目录与元数据目录的书签，扩展在访问期间持有相应权限。关联外部工作区也使用宿主元数据。缺少或损坏的记录直接报错，不创建看似成功的空工作区。仓库未移动、复制或重置，完整 Git 数据及未提交内容保持原地。
3. Duo iOS 27.2 的旧 **“我的 iPhone → Gitling”** app-container 入口仍存在系统映射异常。无扩展的最小文档共享示例也可复现；Files 日志报告 `Cannot find source for location`，尽管目录权限、共享声明和枚举结果正常。本轮通过正式 File Provider 位置恢复工作流，**没有修复或宣称修复系统旧入口**。该位置公开仓库工作树，不公开 Documents 中所有杂项文件。

补充根目录和工作集变化通知，使没有活动目录枚举器时新增仓库仍能被索引。工作集仅列出仓库根节点，不递归扫描仓库或加载历史；书签解析也不复制 Git 数据。扩展不再触发宿主迁移/备份，避免启动时重复扫描。

## 手动验证

在隔离的 `Gitling Duo Layout QA` 模拟器上，复用已有离线仓库及本地构造的冲突仓库：

- “文件”App 的 Gitling 位置显示既有仓库，进入仓库并用 Quick Look 读取含中文长文件名的文本。
- 系统导入选择器从“浏览 → Gitling → Conflict-Workflow-QA”选取该文本，成功导入 `Documents-Browse-QA` 的冲突文件，工作文件预览显示原文。
- 确认解决后继续合并。最终 HEAD `43d59da5bd3892dbcdc462f6a2864fd2cfd8139d` 有两个父提交，工作区干净，提交内容与导入源一致，源文件未改动，MERGE_HEAD 和 Gitling 操作记录均清理。
- 工作集通知修复后，“文件”App 显示全部四个仓库，新增的 `Documents-Browse-QA` 可以进入并列出两个文本文件。

核对记录：`build/documents-duo-manual-verification.json`。未连接远端 Git 服务器，未重新拉取；未进行真机或第三方编辑器测试。

## 回归测试

新增 9 项：`DocumentsSharingTests` 的文档声明、实际域注册及模拟器运行身份检查；`ProviderWorkspaceTests` 的宿主/扩展路径隔离、Git 数据保全、容器更新、损坏记录拒绝、外部工作区及无需重新发布即可发现新增仓库。

最终全量结果及构建日志：

| 环境 | 结果 |
| --- | --- |
| iPhone Duo / iOS 27.2 | 114/114 通过，0 失败（`build/documents-duo-tests-final.log`） |
| iPhone 16 Pro / iOS 18.6 | 114/114 通过，0 失败 |
| 通用 iOS 设备 Release | 通过，未签名构建（`build/documents-release-final.log`） |

两套测试产物均通过 `codesign --verify --deep --strict`；本地化完整性检查和 `git diff --check` 通过。

全量测试继续包含既有真实仓库的分支切换、历史加载和复制导入离线基准，以及 Duo 自适应布局回归。模拟器上的耗时受宿主负载影响，不代表真机性能。
