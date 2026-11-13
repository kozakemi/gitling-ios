# Cursor 提交比较计划及评审

日期：2026-11-12。基线：`006ba6c`。状态：只读计划已返回并经父代理复核，尚未开始功能实现。

首次plan/text调用虽退出0但日志为空，不能算成功。本次用ask/stream-json重试，收到明确success终态和非空正文；父代理检查了相关源码的实际访问级别和调用路径。任务本身未运行测试，也未改动应用代码。

## 父代理评审与实施约束

计划可作为下一轮基础，但以下修订必须先落实：

1. **复用边界**：`OpenRepo`、`indexedFile`、`blobSize`、`tagDetailUnlocked`位于`GitClient.swift`且为private；`DiffTextView`、`DiffStyler`也为`RepoDetailView.swift`内的private类型。新文件不能直接调用。应抽取最小内部只读服务/组件，或将需要访问private辅助函数的扩展留在原文件，不为方便而扩大整个GitClient的可见性。
2. **预算边界**：列表5000项、单文件补丁80 KiB、重命名候选64 MiB是待实施的建议值，不是已验证的性能保证。不能先无界生成整份patch再截断。需限制生成、持有、累计加载的内容；UTF-8文本按完整字符/行截断。树元数据、pack增量和同步库内部结构仍不构成硬内存/CPU上限。
3. **回调可取消性**：仅使用当前vendored头文件实际存在、且测试证明中止行为的libgit2回调；不能只按API名称宣称强中断。单文件结果也需generation校验，避免交换方向后迟到结果覆盖。
4. **范围默认值**：允许唯一OID前缀（界面建议至少7位，歧义必须拒绝）；包含本地及远端跟踪分支、标签和HEAD；默认libgit2重命名相似度；非UTF-8首版仅提示，不做十六进制查看。不检测复制或自动merge-base，不接入网络。
5. **模型与状态**：保留base→target两个完整OID，列表项标识需包含新旧路径与两端OID，不仅依赖文件名。缺失对象/超限/取消/空差异分别表示；错误不降级成空列表。
6. **验收与设备**：沿用任务书的只读保护、离线仓库、当前227项基线、Duo/多语言与预算/取消测试。只允许两台白名单设备，禁止创建、克隆或清空模拟器。下一轮实现后由父代理复核，未经授权不commit/push。

## Cursor 返回的计划

## 任意两提交比较：实施计划

**可直接复用的部分**
- 选择端点：`GitClient.historySearch` 可搜索全部引用，提供 `.oid` 字段和 `.all` 范围；配合 `RepositorySearchModel`、`RepositorySearchCursor`、`SearchCancellation`，以及 `branches`、`tags`。
- 剥离附注标签：复用 `tagDetailUnlocked`，它逐层读取对象头，最多 32 层。
- 只读访问：照 `fileRevision` 的做法，用 `OpenRepo(path:access:nil)` 打开独立句柄。它不占全局锁，也不依赖工作区授权。
- 对象读取：`indexedFile`、`blobSize`（只读对象头）、`loadBlob(symlink:)`、`FileBlobState`、`FileInspection.maximumBytes`。
- diff 写法：参照 `show` 里的 `git_diff_tree_to_tree` 加 `max_size`；界面复用 `DiffTextView`、`DiffStyler`、`DiffPanelLayout`。
- 新增两个文件 `CommitComparison.swift`（模型和 GitClient 扩展）与 `CommitComparisonViews.swift`。入口放在 `RepoDetailView` 历史区的工具栏，`CommitDetailView` 也可加“以此为基准”。

**数据模型**
- `ComparisonEndpoint`：用户输入、来源（分支、标签、OID、搜索、detached HEAD）、40 位 `oid`、提交摘要。
- `CommitComparison(base, target)`：提供 `swapped()`。
- `ComparisonFile`：状态（新增、修改、删除、重命名、类型变化、仅模式变化），新旧路径、模式、OID、对象头大小，内容类型（文本、二进制、符号链接、gitlink、过大、缺失）。
- `ComparisonList`：文件列表加 `truncated` 和超限原因。
- `ComparisonFileDiff`：补丁（带截断标记）、符号链接新旧目标、gitlink 新旧 OID、二进制、过大、非 UTF-8、对象缺失。

**固定 OID 的流程**
- `resolveCommit` 只调用一次，按输入类型解析：
  - 分支和标签用完整引用名查找，再剥离到最终对象；
  - OID 输入要求唯一前缀，有歧义就报错；
  - 最终对象不是提交（比如指向树或 blob 的标签）一律拒绝，对象缺失要单独提示。
- 解析后只保存 40 位 OID。之后所有接口都按 `fileRevision` 的方式校验 40 位，引用移动不会改变已选对象。
- 直接比较两棵树，不计算 merge-base。

**预算**
- 每个文件先读对象头，超过 256KB 的标为过大，不加载内容。
- 列表最多 5000 个变更项，超出时标 `truncated`。
- 重命名检测用 `find_similar` 的 `RENAMES`，设 `rename_limit`；候选总字节超过 64MB 时关闭重命名检测，并明确提示。
- 单文件补丁最多 80KB，超出截断。
- 所有跳过或截断都显示标记，不能显示成“无变化”。

**取消**
- 视图模型采用 generation 加 token：`.task(id:)` 以两端 OID 为键；改输入、交换方向、离开页面都取消旧任务，过期结果直接丢弃。
- 逐个变更项和逐个对象时检查 token。
- 需要如实说明边界：`git_diff_tree_to_tree`、`find_similar`、单文件补丁生成，一旦进入 libgit2 就会跑完。可以评估让 `notify_cb`/`progress_cb` 返回非 0 来提前中止，在实测证明前不能写成“可中断”。

**测试矩阵**（新增 `CommitComparisonTests`，全部用临时仓库）

| 场景 | 验证点 |
|---|---|
| 增、删、改、重命名、模式变化、类型变化 | 状态和路径正确 |
| 符号链接 | 只显示记录的链接目标 |
| gitlink | 只显示 OID 变化 |
| 相同提交 | 空列表，明确提示“相同提交” |
| 交换方向 | 状态和增删统计互换 |
| 非祖先提交、合并提交 | 结果与 merge-base 比较不同 |
| detached HEAD、附注标签 | 解析为正确提交 |
| 解析后移动引用 | OID 不变 |
| 树或 blob 标签、无效 OID、歧义前缀 | 拒绝 |
| 删除松散对象 | 报对象缺失 |
| 二进制、非 UTF-8、超过 256KB、超过列表上限 | 显示相应标记 |
| 比较前后 | HEAD、引用、索引字节、工作文件、未跟踪内容不变；工作区授权失效时仍能比较 |
| 取消和快速切换 | token 失效、旧结果不覆盖，设超时防止挂起 |
| 性能 | 用 `Js_ms_rtos.git` 记录列表和单文件 diff 耗时 |

**实施顺序**
1. 解析逻辑和模型测试；
2. 文件列表；
3. 单文件 diff 和预算；
4. 取消；
5. 页面和中英日本地化；
6. Duo 折叠/展开、窄宽度、大字号；
7. 两台允许的设备各跑完整回归，加上 Release 构建。

**还需你决定**
- 是否允许 OID 前缀，最短几位；
- 远端跟踪分支是否列为可选端点；
- 重命名相似度阈值；
- 非 UTF-8 文件是否只提示，不显示十六进制。

文档里要写明：不检测复制，重命名靠启发式判断，没有合并组合 diff。不能写成完整的 Git 语义。
