# Markdown 渲染与文本行号

更新：2026-11-14。Markdown 默认渲染，保留源码入口。固定提交及比较两端使用相同通道；本次补齐仓库相对路径图片，下方 2026-11-13 的测试记录保留为历史基线。

## 显示范围

以GitHub的GFM及常见文档排版为目标：ATX/Setext标题、粗体/斜体/删除线、行内代码、普通及嵌套列表、有序列表起始编号、只读任务复选框、引用、分隔线、表格及列对齐、围栏/缩进代码、引用式链接、自动链接和脚注。补充GitHub的NOTE/TIP/IMPORTANT/WARNING/CAUTION提示块，支持受限HTML中的details/summary、kbd、sup/sub和基础排版标签。

标题层级及分隔线、正文间距、引用边线、代码背景和语言标签、交替表格行、明暗主题均采用接近GitHub的样式。宽表格及代码块单独横向滚动，正文随视口换行；字号跟随系统。代码高亮复用现有基础词法扫描，不宣称等同GitHub Linguist。

解析使用随应用打包的Marked 18.2.0和marked-footnote 1.4.0，不从CDN运行脚本。依赖来自npm官方registry，下载时核对SHA512；固定版本、源地址、SHA256及MIT许可证位于`Gitling/MarkdownAssets/`。生成HTML在独立actor中串行进行，切换文档取消等待并丢弃迟到结果；仍遵守256 KiB文本预算。预算不是恶意语法或WebKit解码的CPU/峰值内存硬限制。

## 远程图片与访问边界

- Markdown图片语法及受限HTML的img标签会检测HTTP/HTTPS图片；默认不生成带src的img，也不请求网络。
- 检测到远程图片后，顶部显示数量及“点击加载”按钮。只在点击后生成图片资源并允许当前页面的HTTP/HTTPS图片；可再次点击停止加载。网络失败由图片替代文本保留，不承诺离线显示远程内容。
- 切换文件、仓库或固定提交版本会重建预览身份，恢复阻止远程图片；不会把某篇文档的许可用于下一篇，即使正文相同。源码/渲染切换也不保存永久许可。
- 使用独立非持久WebKit数据存储，不连接Git凭据或账户cookie；远程图片设置no-referrer。不接受URL内嵌用户名/密码、file/data/javascript等图片URL，不自动下载LFS。合法仓库相对图片由下述独立受限通道读取。
- 内容页面JavaScript禁用。CSP禁止脚本、连接、iframe、媒体、插件、表单和外部样式；原始HTML走标签白名单，去掉事件、任意style和活动内容。解析器运行在无DOM、网络、文件系统或仓库API的JavaScriptCore上下文，不执行文档脚本。
- 普通链接显示链接样式，保持现有不跳转外部页面/仓库文件的行为；脚注锚点可在本页跳转。未实现数学公式、Mermaid图、完整emoji短码、GitHub账户/issue引用或所有HTML/CSS特性，不能宣称与github.com完全一致。

## 仓库相对路径图片（2026-11-14）

此前渲染器只识别 HTTP/HTTPS 图片，其他来源一律替代文本；预览页也没有把仓库及 Markdown 路径传给渲染器。因此正常的 `![图](images/a.png)` 不会被读取。

现在工作区、文件历史和比较两端都传递仓库及完整文档来源。路径以 Markdown 所在目录为基准，支持 `./`、仓库内的 `../`、`/images/a.png` 仓库根路径、中文/空格、单次 URL 解码及查询/片段后缀；引用式图片及受限 HTML `<img>` 复用同一解析规则，HTML 属性支持常见字符实体。越过仓库根、`.git`、符号链接（含中间目录）、特殊文件、任意 file/data/javascript URL 均不会打开。

工作区图片复用外部授权及安全快照服务，授权失效不回退到内部副本；历史图片从 Markdown 对应的固定 commit 读取，既不读取当前 HEAD，也不依赖当前索引或工作文件。相同正文在不同提交中引用不同图片时，仍分别显示正确版本。

WebKit 只拿到不含磁盘路径的随机 `gitling-image:` 地址；任务处理器只服务当前文档登记的引用，复用图片验证及 PNG 降采样结果，不把仓库目录直接开放给网页。同一路径复用快照；离开、切换或取消时撤销旧任务，迟到结果不回调已停止的 WebKit 请求。远程图片仍须点击顶部提示，本地图片不需要网络或额外许可。

每个文档最多登记 64 个不同图片路径，输入累计 64 MiB、输出 PNG 累计 32 MiB、降采样像素累计 16M；单文件继续受 32 MiB、2048 长边、64MP 等既有保护。上述是逻辑预算，不是 WebKit/Image I/O 峰值内存或 CPU 的硬保证。SVG/HTML 保持源码规则，LFS 指针不自动下载；损坏、缺失、超限及非图片资源保留替代内容，不影响正文阅读。

新增 9 项回归：路径与编码、越界/危险 URL、引用登记及上限、快照复用/累计预算/取消、符号链接与非图片、固定版本与只读数据、外部授权、实际 PreviewContentsPage/WebKit 图片解码及同文多版本快速切换、已停止/替换任务不接受迟到回调。

最终验证：iPhone 16 Pro / iOS 18.6 与 Duo QA / iOS 27.2 各 **325/325 通过，0 失败、0 跳过**；通用 iOS Release 未签名构建、本地化与差异检查通过；构建/安装应用共四处严格签名检查通过。实际 WebKit 页面验证了工作区蓝图、历史红图、相同 Markdown 正文切换提交及快速替换后的正确图片，同时核对 HEAD、索引和工作图像未变。本轮没有新增手工 Duo 点按或真机验收，没有访问原始 Git 服务器，没有调用 Cursor/DeepSeek，也未 commit/push。

日志为 `build/markdown-relative-ios18.log`、`build/markdown-relative-duo.log`、`build/markdown-relative-release.log`；测试摘要、签名及源码 SHA256 见 `build/markdown-relative-validation.json`。这些是本机产物，不作为永久提交证据库。

## 行号

文本预览、HTML/SVG源码及Markdown源码模式的编码栏提供行号开关，默认开启，并保存本机选择；Markdown渲染不显示源码行号。历史文本复用同一入口。行号绘制在独立视觉栏，按逻辑行编号，换行折行不重复编号；CRLF、CR、LF和Unicode分隔符均计数，支持尾部空行。复制、选择和语法高亮仍使用原始文本，行号不进入剪贴板。绘制只遍历可见行片段，并二分查找预先计算的UTF-16行起点。

Blame/diff已有各自的行号与数据语义，本轮不改其规则；二进制仍显示字节偏移，不增加文本行号。

## 验证

回归覆盖GFM结构和脚注、提示块及受限HTML、代码内容转义和高亮、危险URL/活动HTML、图片许可与CSP、超预算/取消、实际WebKit同文格式更新/字号，以及逻辑行和切换行号时的选择/复制数据不变。新增loopback PNG服务验证未允许时零请求、允许后实际解码成功、无Authorization/Cookie/Referer及新文档恢复阻止，不访问原始Git服务器。

最终完整测试和Duo手工验收结果在完成后记录于本文及项目进度。

## 参考

- [GitHub GFM规范](https://github.github.com/gfm/)
- [GitHub写作语法（含脚注及提示块）](https://docs.github.com/en/get-started/writing-on-github/getting-started-with-writing-and-formatting-on-github/basic-writing-and-formatting-syntax)
- [Marked扩展Renderer接口](https://marked.js.org/using_pro)


Final verification (2026-11-13): both approved simulators passed 309/309, zero failures/skips; unsigned iOS Release, localization/diff checks and four strict app signatures passed. Duo manual observations and all 13 fixture files/index/HEAD/status checks passed. The 2000-item parser sample was about 0.11 seconds on iOS18.6, excluding WebKit layout. Evidence: `build/markdown-validation.json`, `build/markdown-duo-verification.json`, `build/markdown-ios18.log`, `build/markdown-duo.log`, `build/markdown-release.log`. No original Git server fetch, Cursor/DeepSeek, commit or push.
