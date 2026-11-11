# Gitling for iOS

English | [简体中文](README.zh-CN.md)

[![Build IPA](https://github.com/kozakemi/gitling-ios/actions/workflows/build-ipa.yml/badge.svg)](https://github.com/kozakemi/gitling-ios/actions/workflows/build-ipa.yml)

An open-source Git client for iPhone and iPad, built with SwiftUI and libgit2.

> **Unofficial version**
>
> This project is maintained by community developers and is not affiliated with,
> authorized by, or endorsed by the original author, Maneesha Cooray.
> The features and interaction are inspired by the Android version of
> [Gitling](https://github.com/maneeshacooray/Gitling); the iOS code is an
> independent implementation.

Gitling for iOS brings the Gitling mobile Git workflow to iOS: clone repositories,
browse history and diffs, commit, and push. Workspaces are exposed in the Files app
so other editors can modify files.

## Progress and roadmap

[Project progress, validation, limitations, and priorities (Chinese)](docs/project-progress.md), updated 2026-11-11.

## Features

- Copy-import existing repositories while preserving the source, full local Git data, and uncommitted state; convert bare repositories offline

- Stage and unstage individual files, with separate working-tree and staged diffs
- Restore individual working files from the index, including deleted files, while preserving staged changes ([details](docs/file-restore.md))
- Save, list, apply, pop, and delete stashes, optionally including untracked files
- Recoverable merge/rebase/cherry-pick conflicts: inspect both sides and the working file, import external edits, confirm resolutions, continue or abort ([details](docs/conflict-resolution.md))
- Submodule status, initialization, updates, and recursion, with dirty-worktree protection and resumable failures ([details](docs/submodules.md))
- Tag lists, details, and safe checkout with explicit detached HEAD state and local-change protection ([details](docs/tags-and-diff-layout.md))
- Full-history search by message, author/email and OID; recursive file name/path search with cancellation and pagination ([details](docs/repository-search.md))
- Support `feature/topic` branch names, branch renaming, and safe deletion of merged branches
- Set or clear upstream branches; select a remote for Fetch/Push, with default sync following the upstream remote and branch name

- Clone HTTPS repositories and initialize local repositories
- Commit, stage, unstage, fetch, pull, and push
- Browse commit history, branch graphs, and commit diffs
- Large histories load in pages with a bottom loading indicator
- Use a dropdown branch picker for long branch lists, with all local and remote-tracking branches available
- Checkout a selected local branch, or create a local tracking branch from a remote branch
- Colorized commit diffs: additions in green, deletions in red, hunk headers in blue,
  file headers in gray
- Chinese, English, and Japanese interfaces
- Gitling location in the Files app through a File Provider extension ([Duo simulator access notes](docs/duo-files-access.md))
- Link an external folder from the Files app as the working tree
- GitHub Device Flow sign-in
- GitLab.com and self-hosted GitLab, with multiple accounts per platform
- HTTP, HTTPS, and SSH transports; import an existing SSH private key and link it to a clone
- SSH host keys use trust-on-first-use and reject a changed key
- Git LFS pointer download and checkout, plus clean/upload of LFS-tracked files
- Personal Access Tokens stored in the Keychain, never in `.git/config`
- New repositories default to local initialization; when cloning, choose an account
  first and only then load that account's remote repositories
- The add button uses Liquid Glass on iOS 26 and falls back to the solid brand button
  on iOS 18

## Screenshots

| Home | Commit history and graph |
| --- | --- |
| ![Home](docs/images/home.png) | ![Commit history](docs/images/commits.png) |

| Colorized diff | GitLab project picker |
| --- | --- |
| ![Diff](docs/images/diff.png) | ![GitLab](docs/images/gitlab-projects.png) |

## Requirements

- iOS 18.0 or later
- Xcode 26 / 27
- Swift 5
- libgit2 1.8.4 and libssh2/OpenSSL (static, prebuilt libraries are included)
- No CocoaPods or external Swift Package downloads required

## Build

```sh
open Gitling.xcodeproj
```

Select the `Gitling` scheme and a simulator or device in Xcode.

Build an unsigned IPA:

```sh
./scripts/build-ipa.sh
```

The output is `build/Gitling.ipa`. An unsigned IPA cannot be installed directly on a device.

GitHub Actions also builds the unsigned IPA on every push to `main`, on pull
requests, and on manual dispatch. Open the latest run on the
[Actions page](https://github.com/kozakemi/gitling-ios/actions/workflows/build-ipa.yml)
and download the `Gitling-unsigned-ipa` artifact. The artifact is unsigned; sign
it with your own certificate and provisioning profile before installing it.

If libgit2 is not already built, the script invokes `scripts/build-libgit2.sh`.
You can also build it manually first:

```sh
./scripts/build-libgit2.sh
```

## Tests and checks

```sh
./scripts/test.sh
```

Localization coverage check:

```sh
./scripts/check-localizations.py
```

## Project layout

```text
Gitling/                 iOS app, UI, accounts, SSH/LFS, GitHub/GitLab clients
GitlingFileProvider/     Files app File Provider extension
Shared/                  Repository storage, worktree, write lock, File Provider sharing
GitlingTests/            XCTest unit tests
Vendor/static-libgit2/   libgit2 static xcframework and local Swift Package
Vendor/libssh2/          Prebuilt libssh2/OpenSSL static libraries and licenses
scripts/                 Build, IPA, and localization scripts
docs/                    Screenshots
```

## Accounts and credentials

- GitHub uses Device Flow; no account password is stored in the app.
- GitLab uses a Personal Access Token. Recommended scopes:
  - `read_api`
  - `read_user`
  - `read_repository`
  - `write_repository`
- Account tokens are stored in the Keychain per account.
- After a successful clone, the repository records the account it used; later
  fetches and pushes prefer that account.
- Multiple accounts are supported for both GitHub and GitLab.

## Known limitations

- Copy import requires self-contained Git data. External `.git` directories, shared object stores, and promisor dependencies are rejected to avoid incomplete copies or writes back to the source.

- A conflicted stash restore keeps the stash and conflict contents. Use the conflict resolution screen to inspect, import edits, and confirm each resolved file.

- SSH keys are imported, not generated or exported. The passphrase is stored in the Keychain.
- SSH host keys use trust-on-first-use. A changed host key is rejected; there is no known-hosts management UI yet.
- Git LFS supports pointer download/checkout and clean/upload for LFS-tracked files. LFS lock commands and a dedicated progress UI are not implemented.
- HTTP is supported for compatibility with local or legacy servers. It sends credentials and data in clear text; use HTTPS whenever possible.
- Interactive rebase and custom merge drivers are not supported.
- Commit diffs treat files larger than 256 KB as binary to keep the UI responsive.
- GPLv3 and App Store distribution terms have known compatibility disputes. If you
  plan to publish on the App Store, complete a license audit and consider dual
  licensing or an App Store exception. This is not legal advice.
- This is an unofficial client. Verify the use of the project name, icon, and
  trademarks before distributing.

## Development notes

This project was developed with **Grok** and **DeepSeek** as AI coding assistants
for code generation, refactoring suggestions, tests, and documentation. All commits
are reviewed by the maintainer before they are merged.

## Third-party licenses

- [libgit2](https://libgit2.org/) — GPL-2.0 with Linking Exception
- [libssh2](https://www.libssh2.org/) — BSD-3-Clause; see `Vendor/libssh2/LICENSE-libssh2`
- [OpenSSL](https://www.openssl.org/) — Apache-2.0; see `Vendor/libssh2/LICENSE-OpenSSL`

## License

This project is released under the
[GNU General Public License v3.0](LICENSE).

Original Gitling for Android:

- Author: Maneesha Cooray
- Project: https://github.com/maneeshacooray/Gitling
- License: GPLv3

This repository: https://github.com/kozakemi/gitling-ios
