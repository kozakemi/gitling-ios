# 扩展文件预览规划

日期：2026-11-13。状态：四轮基础功能及二进制/ZIP兜底已实现。本次复查补齐历史和比较入口，修复前三轮的生命周期、资源引用和布局问题。下方各轮旧验证为实施记录，最新结论见“本次四项复查”。

最新追加：Markdown已改为默认渲染，增加GFM语法及逐篇远程图片许可，文本/源码支持行号开关；此前本页各轮“默认源码/不使用网页视图/不加载远程图片”描述为历史实现，当前行为以[Markdown与行号](markdown-preview.md)为准。最新完整基线为两台各309项。

## 当前实现与结论

`FileContentsPage` 和固定提交的 `FileRevisionPage` 共用 `PreviewContentsPage`。工作区通过安全目录FD和外部工作区授权读取；历史版本通过完整固定commit OID读取树和blob，不依赖当前索引、HEAD或工作文件。文本预览限256 KiB；媒体、文档和二进制快照限32 MiB。Blame、`GitClient.readText` 和文本diff保留原有UTF-8及各自预算。

可以在保留这些保护的基础上增加多格式预览。Apple的 `QLPreviewController` 支持图片、PDF、Office/iWork、RTF等常见类型；实际支持范围可能随系统版本变化，应先调用 `canPreview` 探测，准备明确的不可预览状态，不能承诺所有扩展名都可打开。图片和PDF最适合作为首轮，覆盖工程截图、设计资料和技术文档，系统组件也便于Duo适配。

## 建议顺序与交付范围

| 轮次 | 范围 | 主要交付与边界 |
| --- | --- | --- |
| 第一轮 | 统一只读预览通道＋工作区图片/PDF | PNG/JPEG/HEIC及系统可识别的静态图片、PDF；图片缩放/平移、像素与大小信息，PDF基础浏览；保留文本源码模式和现有历史入口 |
| 第二轮 | 其他文本编码＋Markdown | BOM明确的UTF-16等编码；GB18030等提供手动编码选择和当前编码标识，不把启发式结果冒充确定；Markdown源码/渲染切换，首版禁用远程资源和脚本 |
| 第三轮 | 常见文档＋音视频 | 对Office/iWork/RTF等探测Quick Look支持，媒体使用系统播放器；先做基础只读预览，不做编辑器、格式转换或自动播放 |
| 第四轮 | 历史文件与比较入口复用 | 从固定提交/OID读取blob，复用预览通道及缓存；图片两版本切换或并排查看，随后再考虑更复杂的视觉差异 |
| 第四轮一并完成 | 二进制与压缩包 | 十六进制分页、文件元数据；ZIP等先只列目录，默认不解压，不执行可执行文件；未知类型仍可显示大小/类型/无法预览原因 |

第一轮不需要同时扩展历史blob和所有媒体类型，便于先验证外部工作区授权、文件快照与内存开销。已有Blame和文本diff继续遵循各自UTF-8与资源限制，非UTF-8预览不会自动扩大其支持范围。

## 实现结构

1. 增加 `PreviewSource`（工作区路径／固定commit blob）、`PreviewDescriptor`（类型、大小、编码、预算与状态）和持有生命周期的 `PreviewAsset`。用UTType和必要的少量文件头联合判断；扩展名只作为提示，伪装或损坏内容要能降级。
2. 在现有安全目录FD读取基础上增加有界文件快照服务。继续使用 `openat`、`O_NOFOLLOW`、普通文件检查和外部工作区访问作用域，不能为了交给系统预览器而直接绕过现有路径检查。
3. Quick Look接收应用私有临时快照，而非可写的源仓库文件URL。快照用独立UUID目录和受控后缀，预览关闭后回收；历史对象按OID隔离缓存，工作区缓存包含文件身份与变化信息。外部提供方需协调读取；复制前后检测变化，发现变化时要求重新加载，不能宣称对所有外部写入提供原子快照。
4. 首轮用Quick Look完成基础PDF/文档浏览；图片可用系统预览，若自建图片页则用Image I/O按视口降采样，避免把完整超大位图直接交给SwiftUI。需要PDF页码、文本搜索或更深定制时再引入PDFKit。
5. 探测、快照、读取和解码准备放后台，共用有界串行/限并发队列；切换文件取消旧请求并核对generation。加载、错误、超限和不支持状态明确显示，长复制沿用现有操作进度展示模式。

## 资源与行为约束

- 不直接取消现有256 KiB文本上限。首轮可提议普通预览文件32 MiB、临时缓存128 MiB、图片初始降采样长边2048像素；这些是待离线样本验证的起始预算，不是系统解码峰值内存保证。大文件超限需解释原因，后续再按格式调整。
- 图片还要检查像素尺寸与帧数，首轮GIF只考虑静态首帧；文件体积小不代表解码占用小。PDF按需显示，损坏、加密和无法解析分别提示，不一次渲染所有页面。
- Markdown/HTML/SVG不能当作任意网页加载。默认不执行脚本、不加载网络图片，不开放对仓库其他文件的无边界访问；首轮SVG/HTML可以保留源码或不支持提示。
- LFS指针保持指针提示，不因打开预览自动下载大对象；历史symlink仅显示记录的目标，gitlink仅显示OID，不访问链接目标或更新子模块。
- 预览保持只读。系统组件若提供标注能力，其变化也只能落到临时副本，不自动写回、暂存或提交。导出/分享由用户明确发起。

## 回归与验收

第一轮以小型离线图片、PDF及损坏样本验证：实际内容与扩展名不一致、超大像素/文件、加密PDF、不支持类型、符号链接/目录替换、外部授权失效、文件读取中变化、缓存清理、快速切换与迟到结果。预览前后核对HEAD、索引、工作区与未跟踪文件不变。

性能记录首屏时间、降采样后的内存、缓存命中与连续切换的峰值并发，不用固定毫秒阈值伪造真机保证。用既有离线仓库和本地小夹具；不额外抓取实际服务器。两套白名单模拟器完整回归、Release、本地化和签名检查；Duo内外屏、长路径、多语言、大字号，以及临时快照关闭后回收均实际验证。

以上顺序为原始计划；四轮基础功能现已落地，复杂二进制解释器仍不在本轮范围。

## 第一轮实现

工作区内容页仍保留文本、文件历史和 Blame。普通 UTF-8 文本继续停在 256 KiB；超过后说明上限和文件大小，不取消这条限制。图片和 PDF 走单独的只读快照：

- 从工作区根目录用 `openat`、`O_NOFOLLOW` 打开普通文件。符号链接（包括中间目录）、目录、`.git` 和 `..` 都不跟随。外部工作区仍先取得授权；书签无效时直接说明文件夹不可用，不改读应用沙盒里的另一份目录。
- 副本放在应用临时目录的 UUID 文件夹里，文件名固定为 `content.pdf` 或 `content.imgdata`，不用用户提供的扩展名。预览关闭、取消、发现读取过程中文件被替换，或判定为加密、损坏、超限时删除副本。
- 复制前后比较设备号、inode、大小和修改时间。不一致就丢弃副本并要求重新打开。这不是对所有外部写入的原子快照。
- 起始预算：普通预览文件 32 MiB，同时保留的副本 128 MiB，图片降采样长边 2048 像素，任一边超过 32768 或总像素超过 64MP 时不展开。这些是本进程愿意复制或交给 Image I/O 的上限，不是解码峰值内存、CPU 或耗时保证。
- 图片用 Image I/O 只生成一帧缩略图，再交给可捏合、双击缩放的滚动视图。GIF 只显示第一帧。扩展名只作提示；内容与扩展名不符时按实际内容降级。
- PDF 用 PDFKit 查看。只读取是否加锁和页数，不逐页绘制，也不尝试密码。加密文件不打开；无法建立文档或没有页面时分别说明损坏和无法读取。
- 小的 SVG、HTML 仍显示源码，不作为网页或图像加载。Git LFS 指针只显示对象信息，不下载。当时历史 blob 返回“尚未提供”；本次第四轮已替换为固定提交预览。
- 探测、复制和解码准备共用一个串行队列。切换文件会取消上一请求，迟到结果关闭自己的副本，不替换当前画面。达到 1 MiB 的复制按 100 毫秒合并字节进度。

Quick Look 留到第三轮的 Office、iWork 和 RTF。第一轮需要区分加密、损坏和无法读取，所以 PDF 直接使用 PDFKit，而不是把临时副本交给 Quick Look。

## 第一轮验证

2026-11-13：iPhone 16 Pro / iOS 18.6 与 Gitling Duo Layout QA / iOS 27.2 各 **283/283 通过，0 失败、0 跳过**。相对此前 267 项基线新增 16 项，覆盖内容与扩展名不符、降采样、JPEG/HEIC/GIF 首帧、超大声明像素、加密和损坏 PDF、符号链接、目录、路径穿越、复制中替换、取消、缓存回收、LFS 指针、SVG/HTML 源码、文本上限、历史 blob、只读 Git 状态、进度合并、串行队列、迟到结果，以及图片缩放、PDF 视图和多语言大字号布局。

通用 iOS Release 未签名构建通过。两台模拟器的构建产物和已安装应用都通过 `codesign --verify --deep --strict`。本地化检查和 `git diff --check` 通过。日志：`build/preview-ios18.log`、`build/preview-duo.log`、`build/preview-release.log`。一次 180×60 图片在模拟器中降到 40×13，缩略图 201 字节，约 1.8 毫秒；峰值并发为 1。这是小夹具样本，不是真机耗时或内存保证。本轮没有新增 Duo 手动点按验收，也没有真机或第三方文件提供方验收。

## 第二轮实现

文本预览仍以 256 KiB 为上限。当时历史 blob、Blame 和 `GitClient.readText` 只接受 UTF-8；本次历史预览已复用编码菜单，Blame 和 `GitClient.readText` 继续只接受 UTF-8，不会因为预览能显示别的编码而放宽。

- 带 BOM 的 UTF-8、UTF-16 LE/BE 和 UTF-32 LE/BE 会去掉 BOM 后按该编码解码，并标明“字节顺序标记”。严格合法的无 BOM UTF-8 标为 UTF-8。这两种都不是猜测。
- GB18030、GBK、Big5 和 Shift JIS 只在用户从编码菜单里选中之后才解码，标签带“手动选择”。即使某种传统编码恰好能解出字符，也不会被自动当成确定结果。不是合法 UTF-8、又没有 BOM 的文本会停在“请选择编码”。
- 奇数长度的 UTF-16 和不是 4 字节倍数的 UTF-32 会拒绝，不补字节。
- `.md`、`.markdown`、`.mdown` 可以在源码和渲染之间切换，默认源码。渲染前先保护代码块，再去掉脚本、内嵌框架、远程图片、仓库相对路径和原始 HTML。渲染结果是本地富文本，不使用网页视图，也不打开链接或附件。
- SVG 和 HTML 仍然只显示源码。

## 第二轮验证

2026-11-13：iPhone 16 Pro / iOS 18.6 与 Gitling Duo Layout QA / iOS 27.2 各 **286/286 通过，0 失败、0 跳过**。相对第一轮 283 项新增 3 项：BOM 明确的 UTF-8/16/32、GB18030 不自动猜测、手动选择后的标签、UTF-16 奇数长度拒绝、`readText` 仍拒绝非 UTF-8、Markdown 去掉远程图片/脚本/仓库路径并保留代码中的地址，以及编码菜单和源码/渲染切换在大字号下的宽度。

通用 iOS Release 未签名构建通过。本地化检查和 `git diff --check` 通过。日志：`build/preview-round2-ios18.log`、`build/preview-round2-duo.log`、`build/preview-round2-release.log`。本轮没有新增 Duo 手动点按验收，也没有真机验收。

## 第三轮实现

Office、iWork、RTF 和音视频走同一条只读快照。扩展名只作提示，先看文件头：

- `{\rtf` 当作 RTF。`word/`、`xl/`、`ppt/` 分别当作 docx、xlsx、pptx。旧版 OLE 文档只在扩展名是 doc、xls 或 ppt 时选择对应后缀；类型不够明确时不猜测。当时普通 ZIP 不打开、不列出；本次已增加只列目录。
- 音频识别 ID3、WAV、AIFF、CAF 和 M4A。视频识别常见 `ftyp` 品牌。HEIC 仍走图片，不当成视频。
- 快照使用固定后缀，例如 `content.rtf` 或 `content.wav`，不把工作区原文件交给系统组件。Quick Look 先调用 `canPreview`；播放器先询问系统能否播放。系统拒绝时删除副本并说明当前系统不能预览，不承诺每种扩展名都能打开。
- 文档用 Quick Look。若系统提供标注，改动只留在临时副本里，预览结束即删除，不写回、不暂存、不提交。
- 音视频用系统播放器，创建时处于暂停。界面写明需要按播放才开始，不会自动播放。
- 超过 32 MiB 的文档和媒体沿用预览上限。LFS 指针、符号链接和 UTF-8 文本的既有规则不变。名为 `.docx` 的 UTF-8 文本仍按文本显示。

## 第三轮验证

2026-11-13：iPhone 16 Pro / iOS 18.6 与 Gitling Duo Layout QA / iOS 27.2 各 **288/288 通过，0 失败、0 跳过**。相对第二轮 286 项新增 2 项：文档和媒体按文件头分类而不是按扩展名猜测，系统拒绝时删除快照，普通 ZIP 不打开，播放器创建后保持暂停。通用 iOS Release 未签名构建通过。日志：`build/preview-round3-ios18.log`、`build/preview-round3-duo.log`、`build/preview-round3-release.log`。本轮没有新增 Duo 手动点按验收，也没有真机验收。

## 本次四项复查（2026-11-13）

| 工作项 | 结果 | 边界 |
| --- | --- | --- |
| 图片/PDF与安全快照 | 已实现并加强文件身份校验 | 静态首帧、按需PDF；加密不解锁，LFS不下载 |
| 编码/Markdown | 已实现并修复字体、动态字号和段落分隔 | 传统编码只手动选择；HTML/SVG源码，无网页或远程图片加载 |
| 文档/媒体 | 已实现原生预览通道并补生命周期保护 | 系统支持依运行时而定，Duo实际渲染结果见下；不作编辑器或格式转换 |
| 历史/比较及兜底 | 已实现固定提交、两端切换、十六进制分页、ZIP目录 | 无视觉差异算法、无解压、无缺失对象联网补齐 |

历史读取先验证完整40位commit OID，检查对象头类型和大小，再查固定提交树。缺失与损坏分别提示；symlink只显示记录的目标，gitlink只显示OID，不跟随链接、不打开子模块。blob在物化前检查32 MiB逻辑大小，以64 KiB块复制并检查取消；临时中转和最终快照均计入缓存。修改当前引用、损坏索引、外部书签无效不应改变固定版本的结果。比较详情增加“预览两个版本”，Base/Target可切换；删除文件默认打开基准版本，缺失侧明确提示。

未知二进制按4096字节分页显示偏移、十六进制和ASCII，仅从私有快照读取；超过32 MiB不物化。ZIP只通过EOCD和中央目录读取元数据，目录预算1 MiB、最多显示2000项、单个名称最多4096字节；路径穿越和加密条目有标识，不提取任何内容。ZIP64、多卷、截断和超预算明确降级。非UTF-8名称无法确定时显示编码字节，不冒充正确解码；目录验证不等于载荷、CRC或压缩格式验证。

Office识别改用已验证中央目录中的`[Content_Types].xml`与主文档条目，避免伪造文件头字符串，并能识别首256 KiB之外的条目。iWork仅处理支持的ZIP容器，不遍历目录包。媒体探测最多等待5秒，超时取消加载；AVURLAsset使用`forbidAll`拒绝媒体容器的外部引用。切换URL及退出时暂停并清除旧播放器，不自动播放。Quick Look只在首次加载或URL变化时刷新，只接收私有快照。

快照校验增加ctime，并在平台探测/解码后从根重新打开完整路径比较身份，发现中间目录替换即丢弃。普通文件以`O_NONBLOCK`打开，防止替换为FIFO导致阻塞。异步结果在更新加载状态之前核对generation，旧结果回收副本；取消不留下永久转圈。Markdown为UIKit补齐语义字体和块间换行，修复内容相同但格式变化不刷新及动态字号不生效。

这些是逻辑字节、目录元数据和应用缓存的上限，不是libgit2 pack展开或系统解码器的CPU/峰值内存硬限制。系统`canPreview`仅是能力探测，不是实际成功渲染的保证。真机及第三方外部提供方仍待验收。

## 本次最终验证

两台白名单模拟器 iPhone 16 Pro / iOS 18.6 与 Duo QA / iOS 27.2 各 **301/301通过，0失败、0跳过**。预览专项34项：此前前三轮21项，本次新增13项。Markdown段落和Quick Look快照切换均已补回归；通用iOS Release未签名构建、本地化、差异检查及两台构建/安装产物共4处严格签名检查通过。

Duo离线夹具实际验证：工作区图片、历史图片与完整OID、PDF正文、GB18030手动中文、Markdown标题/段落/强调及远程内容禁用、RTF/DOCX正文、WAV播放器、三页二进制、ZIP中文目录和危险路径标签；比较页两版图片、删除侧默认基准及目标缺失状态。文档渲染发现空白问题后改用UIKit导航容器承载Quick Look，实际观察到RTF/DOCX正文；系统加载需要时间，不能仅凭`canPreview`判成功。内外屏切换和字号10检查后恢复展开/字号3。

前后HEAD、索引及11个工作文件摘要、暂存后再修改和未跟踪状态不变；无归档条目落盘，退出后无活跃预览快照。尚未完成真机、第三方文件提供方或全部Office/iWork变体的实际验收。

本地证据：`build/preview-audit-ios18-final.log`、`build/preview-audit-duo-final.log`、`build/preview-audit-release-final.log`、`build/preview-audit-signatures.json`、`build/preview-audit-duo-verification.json`；聚合结果与源文件SHA256见`build/preview-audit-validation.json`。这些是本机产物，不作为永久提交证据库。本轮未调用Cursor/DeepSeek、未拉取原始服务器，未commit/push。

## 官方依据

- [QLPreviewController及常见支持类型](https://developer.apple.com/documentation/quicklook/qlpreviewcontroller)
- [QLPreviewController.canPreview](https://developer.apple.com/documentation/quicklook/qlpreviewcontroller/canpreview(_:))
- [Image I/O缩略图/降采样入口](https://developer.apple.com/documentation/imageio/cgimagesourcecreatethumbnailatindex(_:_:_:))
- [PDFKit PDFView](https://developer.apple.com/documentation/pdfkit/pdfview)

- [AVAsset 外部引用限制](https://developer.apple.com/documentation/avfoundation/avassetreferencerestrictions/forbidall)
- [ZIP APPNOTE 格式定义](https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT)
