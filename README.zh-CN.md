# Gitling for iOS

[English](README.md) | 简体中文

[![Build IPA](https://github.com/kozakemi/gitling-ios/actions/workflows/build-ipa.yml/badge.svg)](https://github.com/kozakemi/gitling-ios/actions/workflows/build-ipa.yml)

一个面向 iPhone 和 iPad 的开源 Git 客户端，使用 SwiftUI + libgit2 实现。

> **非官方版本**
>
> 本项目由社区开发者维护，与原作者 Maneesha Cooray 没有隶属、授权或背书关系。
> 功能和交互参考了 Android 版 [Gitling](https://github.com/maneeshacooray/Gitling)，iOS 代码是独立实现。

Gitling for iOS 的目标是把 Gitling 的移动 Git 工作流带到 iOS：克隆仓库、查看历史和差异、提交并推送，同时把工作区放进「文件」App，方便其他编辑器修改文件。

## 进度与后续计划

[查看当前工作进度、验证结果、已知限制及后续优先级](docs/project-progress.md)（更新于 2026-11-14）。

## 功能

- 复制导入已有仓库，保留源目录、完整 Git 数据及未提交状态；支持裸仓库离线转换

- 状态页逐文件暂存、取消暂存，并分别查看工作区和暂存区差异
- 逐文件放弃未暂存修改及恢复已删除文件，保留索引和已暂存内容（[说明](docs/file-restore.md)）
- Stash 保存、列表、应用、恢复并删除，支持包含未跟踪文件
- Merge/rebase/cherry-pick 冲突列表、双方与工作文件查看、外部编辑导入、确认解决、继续/中止及重启恢复（[说明](docs/conflict-resolution.md)）
- 子模块状态、初始化、更新及递归处理，保护本地修改并支持失败后重试（[说明](docs/submodules.md)）
- Tag 列表、详情及安全检出，明确 detached HEAD 并保护未提交修改（[说明](docs/tags-and-diff-layout.md)）
- 提交正文、作者/邮箱和 OID 的完整历史搜索，以及递归文件名/路径搜索，支持取消和分页（[说明](docs/repository-search.md)）
- 文件历史、历史版本、工作区 Blame 与提交跳转，以及基础语法高亮（[说明](docs/file-inspection.md)）
- 任意两个固定提交比较、变更文件列表及两端文件预览切换（[说明](docs/commit-comparison.md)）
- 工作区与历史版本的只读图片、PDF、系统支持的 Office/RTF/iWork 文档及音视频预览，以及二进制十六进制分页和 ZIP 目录浏览（[说明](docs/file-preview-plan.md)）
- Markdown 默认渲染，支持 GFM 表格、任务列表、脚注、提示块、代码高亮和仓库相对路径图片；远程图片点击提示后才加载，文本及源码提供可记忆的行号开关（[说明](docs/markdown-preview.md)）
- Git 操作实时进度，包括 LFS 下载字节与百分比；首页先显示分支，再逐仓库后台更新状态（[说明](docs/lfs-progress-and-list-refresh.md)）
- 支持 `feature/topic` 分支名、重命名，以及安全删除已合并分支
- 设置或清除上游分支；Fetch/Push 可选择远程，默认同步跟随上游及其实际分支名

- 克隆 HTTPS 仓库，本地初始化仓库
- 提交、暂存、取消暂存、拉取、抓取、推送
- 查看提交历史、分支图和提交差异
- 大型仓库历史分页加载，底部显示加载提示
- 分支较多时使用下拉菜单选择本地或远程分支，也可以切换为只看当前分支
- 可以检出选中的本地分支；选择远程分支时可创建同名本地跟踪分支并检出
- 提交差异按行着色：新增绿色、删除红色、hunk 蓝色、文件头灰色
- 中文、英文、日语界面
- 通过 File Provider 在「文件」App 中提供 Gitling 位置（[Duo 模拟器访问说明](docs/duo-files-access.md)）
- 支持关联「文件」App 中的外部文件夹作为工作区
- GitHub Device Flow 登录
- GitLab.com 和自建 GitLab，支持多个同平台账户
- HTTP、HTTPS 和 SSH 传输；支持导入已有 SSH 私钥并关联到克隆的仓库
- SSH 主机密钥采用首次信任（TOFU），主机密钥变化时会拒绝连接
- Git LFS 指针下载和检出，以及对 LFS 跟踪文件执行 clean/upload
- Personal Access Token 保存到 Keychain，不写入 `.git/config`
- 新建仓库默认本地初始化；克隆时先选择账户，再加载该账户的远程仓库
- 右下角添加按钮在 iOS 26 使用 Liquid Glass，在 iOS 18 使用原来的实心品牌色按钮

## 截图

| 首页 | 提交历史与分支图 |
| --- | --- |
| ![首页](docs/images/home.png) | ![提交历史](docs/images/commits.png) |

| 带颜色的差异 | GitLab 项目选择 |
| --- | --- |
| ![差异](docs/images/diff.png) | ![GitLab](docs/images/gitlab-projects.png) |

## 环境要求

- iOS 18.0 或更高版本
- Xcode 26 / 27
- Swift 5
- libgit2 1.8.4 与 libssh2/OpenSSL（仓库内提供静态预编译库）
- 不需要 CocoaPods 或外部 Swift Package 下载

## 构建

```sh
open Gitling.xcodeproj
```

在 Xcode 中选择 `Gitling` scheme 和模拟器/设备运行。

构建未签名 IPA：

```sh
./scripts/build-ipa.sh
```

产物在 `build/Gitling.ipa`。未签名包不能直接安装到真机。

GitHub Actions 会在推送到 `main`、提交 Pull Request 以及手动触发时自动编译未签名 IPA。打开
[Actions 页面](https://github.com/kozakemi/gitling-ios/actions/workflows/build-ipa.yml) 的最新运行，
下载名为 `Gitling-unsigned-ipa` 的产物。该产物未签名，安装前需要用你自己的证书和描述文件签名。

如果本机没有预编译的 libgit2，脚本会调用 `scripts/build-libgit2.sh`。也可以手动先构建：

```sh
./scripts/build-libgit2.sh
```

## 测试与检查

```sh
./scripts/test.sh
```

本机模拟器遵守 [AGENTS.md](AGENTS.md) 白名单；测试脚本使用已有设备并关闭并行克隆。CI 使用临时宿主已有设备。

最近本机验证（2026-11-14）：iOS 18.6 与 Duo QA / iOS 27.2 各 **325/325 通过，0 失败、0 跳过**。通用 iOS Release 未签名构建、本地化及模拟器应用严格签名检查通过。模拟器验证不替代真机和第三方文件提供方验收。

本地化覆盖检查：

```sh
./scripts/check-localizations.py
```

## 目录结构

```text
Gitling/                 iOS 应用、界面、账户、SSH/LFS、GitLab/GitHub 客户端
GitlingFileProvider/     「文件」App 的 File Provider 扩展
Shared/                  仓库存储、工作区、写入锁、File Provider 共享逻辑
GitlingTests/            XCTest 单元测试
Vendor/static-libgit2/   libgit2 静态 xcframework 与本地 Swift Package
Vendor/libssh2/          libssh2/OpenSSL 静态库与许可证
scripts/                 构建、IPA、本地化检查脚本
docs/                    功能说明、验证记录、路线图和截图
```

## 账户与凭据

- GitHub 使用 Device Flow 登录，不在 App 内保存密码。
- GitLab 使用 Personal Access Token，建议权限：
  - `read_api`
  - `read_user`
  - `read_repository`
  - `write_repository`
- 账户 token 按账户保存到 Keychain。
- 克隆成功后，仓库会记录自己使用的账户；后续拉取和推送优先使用该账户。
- 同一个 GitHub/GitLab 平台可以绑定多个账户。

## 已知限制

- 复制导入首版要求独立 Git 数据目录；外置 `.git`、共享对象库及 promisor 依赖会明确拒绝，避免导入不完整或写回源目录。

- Stash 恢复发生冲突时保留原 Stash 和冲突内容；可通过冲突解决界面查看内容、导入编辑结果并逐个确认解决。

- SSH 私钥只支持导入，暂不支持在 App 内生成或导出；口令保存在 Keychain。
- SSH 主机密钥采用首次信任（TOFU）。主机密钥变化会拒绝连接，但暂未提供 known_hosts 管理界面。
- Git LFS 支持指针下载/检出、clean/upload 及实时下载进度；暂不支持 LFS lock、断点续传和磁盘缓冲下载。
- 文本预览限 256 KiB，历史 blob 和普通预览文件限 32 MiB；这些预算不是解码峰值内存的硬保证。GIF 只显示首帧，加密 PDF 不解锁，SVG/HTML 保留源码，ZIP 不解压。
- Markdown 尚未覆盖所有 GitHub 扩展：数学公式、Mermaid 和完整 emoji 短码暂不渲染。仓库图片读取工作区或同一固定提交，拒绝越界和符号链接，不自动下载 LFS 指针。
- 支持 HTTP 以兼容本地或旧服务器。HTTP 会明文传输凭据和数据，能用 HTTPS 时请优先使用 HTTPS。
- 不支持交互式 rebase 和自定义 merge driver。
- 超过 256 KB 的文件在提交差异中按二进制处理，避免界面卡死。
- GPLv3 与 App Store 分发条款存在兼容性争议。若要上架 App Store，建议先完成许可证审计，并考虑双许可证或 App Store 例外；这不是法律意见。
- 本项目是非官方客户端，使用前请自行确认名称、图标和商标的使用权限。

## 第三方许可证

- [libgit2](https://libgit2.org/)：GPL-2.0 with Linking Exception
- [libssh2](https://www.libssh2.org/)：BSD-3-Clause，见 `Vendor/libssh2/LICENSE-libssh2`
- [OpenSSL](https://www.openssl.org/)：Apache-2.0，见 `Vendor/libssh2/LICENSE-OpenSSL`
- [Marked](https://github.com/markedjs/marked)：MIT，[许可证](Gitling/MarkdownAssets/MARKED-LICENSE.txt)
- [marked-footnote](https://github.com/bent10/marked-extensions)：MIT，[许可证](Gitling/MarkdownAssets/MARKED-FOOTNOTE-LICENSE.txt)

Markdown 解析器版本、来源及校验值见 [MarkdownAssets/NOTICE.txt](Gitling/MarkdownAssets/NOTICE.txt)。解析器随应用打包，可离线使用，预览时不会从 CDN 下载脚本。

## 许可证

本项目以 [GNU General Public License v3.0](LICENSE) 发布。

原始 Android 版 Gitling：

- 作者：Maneesha Cooray
- 项目：https://github.com/maneeshacooray/Gitling
- 许可证：GPLv3

本仓库：https://github.com/kozakemi/gitling-ios
