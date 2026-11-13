import Clibgit2
import CryptoKit
import Darwin
import Foundation
import LinkerConfigurator
import Security

struct RepoSummary: Identifiable, Hashable, Codable {
    var id: String { name }
    var name: String
    var branch: String?
    var isDirty: Bool
    var origin: String?
    var unavailable: Bool
}

struct CommitInfo: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var summary: String
    var author: String
    var date: Date
    var parents: [String] = []
}

struct BranchInfo: Identifiable, Hashable, Codable {
    var name: String
    var isCurrent: Bool
    var isRemote: Bool
    /// Commit this ref points at, when libgit2 reports a direct target.
    var target: String?
    var id: String { (isRemote ? "remote:" : "local:") + name }
}

struct RemoteInfo: Identifiable, Hashable, Codable {
    var name: String
    var url: String
    var id: String { name }
}

struct SyncCounts: Equatable, Codable {
    var ahead: Int
    var behind: Int
}

struct RepositoryHeader {
    var branch: String
    var origin: String
    var branches: [BranchInfo]
    var remotes: [RemoteInfo]
    var linkedFolder: String?
    var upstream: String?
    var pendingSubmodules: Bool = false
    var detachedOID: String? = nil
}

struct StatusEntry: Identifiable, Hashable, Codable {
    var id: String { path }
    var path: String
    var staged: Bool
    var unstaged: Bool
    var untracked: Bool
    var originalPath: String? = nil
    var conflicted: Bool? = nil
}

struct WorkEntry: Identifiable, Hashable, Sendable {
    var id: String { path }
    var path: String
    var name: String
    var isDirectory: Bool
}

struct GitFailure: LocalizedError {
    var message: String
    var errorDescription: String? { message }

    static func message(_ text: String) -> GitFailure {
        GitFailure(message: text)
    }
}

enum GitClient {
    private static let lock = NSLock()
    private static let ready: Void = {
        _ = git_libgit2_init()
        LibGit2Link.register()
    }()

    static func repositoryNames(root: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? [])
        .compactMap { url in
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return isDirectory ? url.lastPathComponent : nil
        }
        .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    static func list(root: URL) -> [RepoSummary] {
        let children = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return children.compactMap { url in
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDirectory else { return nil }
            return (try? summarize(at: url)) ?? RepoSummary(
                name: url.lastPathComponent,
                branch: nil,
                isDirty: false,
                origin: nil,
                unavailable: true
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Copy a self-contained repository without cloning away local Git state.
    static func importRepository(
        from source: URL, name: String, root: URL,
        copyItem: RepositoryImporter.CopyItem = { try FileManager.default.copyItem(at: $0, to: $1) }
    ) throws {
        try WorkingTree.requireSafeName(name.trimmingCharacters(in: .whitespacesAndNewlines))
        // Preflight before destinationURL or the write lock can create directories.
        try RepositoryImporter.validateLocation(from: source, to: root.appendingPathComponent(name.trimmingCharacters(in: .whitespacesAndNewlines)))
        let destination = try destinationURL(name: name, root: root)
        try writing(destination) {
            try RepositoryImporter.copy(from: source, to: destination, copyItem: copyItem, inspect: { location, bare in
                try locked { try validateImport(at: location, bare: bare) }
            }, prepare: { location, wasBare in
                try locked {
                    let git = location.appendingPathComponent(".git", isDirectory: true)
                    for file in [git.appendingPathComponent("config"), git.appendingPathComponent("config.worktree")] {
                        if file.lastPathComponent == "config.worktree", !FileManager.default.fileExists(atPath: file.path) { continue }
                        var config: OpaquePointer?
                        try check(git_config_open_ondisk(&config, file.path), String(localized: "Could not import repository."))
                        defer { git_config_free(config) }
                        try check(git_config_set_bool(config, "core.bare", 0), String(localized: "Could not import repository."))
                        // Relative to .git, so publishing the staged copy is relocatable.
                        try check(git_config_set_string(config, "core.worktree", ".."), String(localized: "Could not import repository."))
                    }
                    try validateImport(at: location, bare: false)
                    if wasBare {
                        var repo: OpaquePointer?
                        try check(git_repository_open_ext(&repo, location.path, UInt32(GIT_REPOSITORY_OPEN_NO_SEARCH.rawValue), nil), String(localized: "Could not import repository."))
                        defer { git_repository_free(repo) }
                        var options = git_checkout_options()
                        try check(git_checkout_options_init(&options, UInt32(GIT_CHECKOUT_OPTIONS_VERSION)), String(localized: "Could not import repository."))
                        options.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue | GIT_CHECKOUT_RECREATE_MISSING.rawValue
                        let result = git_repository_head_unborn(repo) == 1 ? GIT_EUNBORNBRANCH.rawValue : git_checkout_head(repo, &options)
                        if !matches(result, GIT_EUNBORNBRANCH) && !matches(result, GIT_ENOTFOUND) {
                            try check(result, String(localized: "Could not import repository."))
                        }
                    }
                }
            })
        }
    }

    private static func validateImport(at location: URL, bare: Bool) throws {
        var repo: OpaquePointer?
        try check(git_repository_open_ext(&repo, location.path, UInt32(GIT_REPOSITORY_OPEN_NO_SEARCH.rawValue), nil), String(localized: "Could not import repository."))
        defer { git_repository_free(repo) }
        guard let repo, (git_repository_is_bare(repo) != 0) == bare else { throw RepositoryImporter.Failure.invalidSource }
        let expectedGit = bare ? location : location.appendingPathComponent(".git")
        guard gitDirectory(repo).resolvingSymlinksInPath().standardizedFileURL == expectedGit.resolvingSymlinksInPath().standardizedFileURL else {
            throw RepositoryImporter.Failure.externalGitData
        }
        if !bare, try workDirectory(repo).resolvingSymlinksInPath().standardizedFileURL != location.resolvingSymlinksInPath().standardizedFileURL {
            throw RepositoryImporter.Failure.externalGitData
        }
        let tree = try headTree(repo)
        git_tree_free(tree)
        var refs: OpaquePointer?
        try check(git_reference_iterator_new(&refs, repo), String(localized: "Could not import repository."))
        defer { git_reference_iterator_free(refs) }
        while true {
            var reference: OpaquePointer?
            let code = git_reference_next(&reference, refs)
            if matches(code, GIT_ITEROVER) { break }
            try check(code, String(localized: "Could not import repository."))
            defer { git_reference_free(reference) }
            var resolved: OpaquePointer?
            try check(git_reference_resolve(&resolved, reference), String(localized: "Could not import repository."))
            defer { git_reference_free(resolved) }
            if let target = git_reference_target(resolved) {
                var oid = target.pointee
                var object: OpaquePointer?
                try check(git_object_lookup(&object, repo, &oid, GIT_OBJECT_ANY), String(localized: "Could not import repository."))
                git_object_free(object)
            }
        }
        if !bare {
            var index: OpaquePointer?
            try check(git_repository_index(&index, repo), String(localized: "Could not import repository."))
            git_index_free(index)
        }
    }

    static func initialize(name: String, root: URL, bare: Bool = false, worktreeBookmark: Data? = nil) throws {
        let destination = try destinationURL(name: name, root: root)
        try writing(destination) {
            try locked {
                var repo: OpaquePointer?
                let code = git_repository_init(&repo, destination.path, bare ? 1 : 0)
                try check(code, String(localized: "Could not create repository"))
                defer { git_repository_free(repo) }
                if let repo, !bare {
                    tune(repo)
                    if let worktreeBookmark {
                        try attach(repo, repoURL: destination, bookmark: worktreeBookmark)
                    }
                }
            }
        }
    }

    static func clone(
        url: String,
        name: String,
        root: URL,
        username: String,
        secret: String,
        sshKey: SSHKeyMaterial? = nil,
        lfsAuth: LFSAuth? = nil,
        worktreeBookmark: Data? = nil,
        progress: GitProgressHandler? = nil
    ) throws {
        let reporter = GitProgressReporter(handler: progress)
        reporter.report(.preparing)
        let destination = try destinationURL(name: name, root: root)
        try writing(destination) {
            var succeeded = false
            defer {
                if !succeeded {
                    try? FileManager.default.removeItem(at: destination)
                }
            }
            try locked {
            let box = CredentialBox(username: username, secret: secret, sshKey: sshKey, progress: reporter)
            defer { withExtendedLifetime(box) {} }
            var options = git_clone_options()
            try check(
                git_clone_options_init(&options, UInt32(GIT_CLONE_OPTIONS_VERSION)),
                String(localized: "Could not clone")
            )
            applyTransport(&options.fetch_opts.callbacks, box: box)
            applyCheckoutProgress(&options.checkout_opts, box: box)
            reporter.report(.connecting)
            var repo: OpaquePointer?
            let code = git_clone(&repo, url, destination.path, &options)
            try check(code, String(localized: "Could not clone"))
            defer { git_repository_free(repo) }
            if let repo {
                tune(repo)
                if let worktreeBookmark {
                    try attach(repo, repoURL: destination, bookmark: worktreeBookmark)
                }
            }
            }
            succeeded = true
            reporter.report(.largeFiles)
            try smudgeLFS(at: destination, remoteURL: url, auth: lfsAuth)
        }
    }

    static func link(at repoURL: URL, bookmark: Data) throws {
        try writing(repoURL) {
            try locked {
                let opened = try open(repoURL)
                defer { withExtendedLifetime(opened) {} }
                try requireNoOperation(opened.repo)
                try attach(opened.repo, repoURL: repoURL, bookmark: bookmark)
            }
        }
    }

    static func unlink(at repoURL: URL) throws {
        try writing(repoURL) {
            try locked {
                let opened = try open(repoURL)
                defer { withExtendedLifetime(opened) {} }
                try requireNoOperation(opened.repo)
                let source = try workDirectory(opened.repo)
                try copyWorkingFiles(from: source, to: repoURL)
                try check(
                    git_repository_set_workdir(opened.repo, repoURL.path, 0),
                    String(localized: "Could not use that folder.")
                )
                WorktreeLink.remove(repoName: repoURL.lastPathComponent)
            }
        }
    }

    static func linkedFolderName(at repoURL: URL) -> String? {
        WorktreeLink.displayName(repoName: repoURL.lastPathComponent)
    }

    static func addRemote(at repoURL: URL, name: String = "origin", url: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw GitFailure.message(String(localized: "Enter a repository name."))
        }
        try locked {
            let handle = try open(repoURL)
            defer { withExtendedLifetime(handle) {} }
            var remote: OpaquePointer?
            try check(
                git_remote_create(&remote, handle.repo, name, url),
                String(localized: "Could not clone")
            )
            git_remote_free(remote)
        }
    }

    static func status(at repoURL: URL) throws -> [StatusEntry] {
        try locked {
            let opened = try open(repoURL)
            defer { withExtendedLifetime(opened) {} }
            return try statusUnlocked(opened.repo)
        }
    }

    static func history(
        at repoURL: URL,
        limit: Int = 100,
        allBranches: Bool = false,
        ref: String? = nil,
        offset: Int = 0
    ) throws -> [CommitInfo] {
        try locked {
            let opened = try open(repoURL)
            defer { withExtendedLifetime(opened) {} }
            let repo = opened.repo
            var walker: OpaquePointer?
            try check(git_revwalk_new(&walker, repo), String(localized: "Could not read history"))
            defer { git_revwalk_free(walker) }
            git_revwalk_sorting(
                walker,
                UInt32(GIT_SORT_TOPOLOGICAL.rawValue | GIT_SORT_TIME.rawValue)
            )
            if let ref {
                var pushed = false
                let names = ref.hasPrefix("refs/")
                    ? [ref]
                    : ["refs/heads/\(ref)", "refs/remotes/\(ref)"]
                for name in names {
                    let result = git_revwalk_push_ref(walker, name)
                    if result == 0 { pushed = true }
                }
                if !pushed {
                    throw GitFailure.message(String(localized: "Could not read history"))
                }
            } else if allBranches {
                // Include local branches and remote-tracking branches. Push
                // each ref explicitly: globs do not reliably cross the slash
                // in refs/remotes/origin/feature or branch names with slashes.
                var iterator: OpaquePointer?
                if git_branch_iterator_new(&iterator, repo, GIT_BRANCH_ALL) == 0,
                   let iterator {
                    defer { git_branch_iterator_free(iterator) }
                    while true {
                        var reference: OpaquePointer?
                        var type = git_branch_t(0)
                        if git_branch_next(&reference, &type, iterator) != 0 { break }
                        if let reference {
                            if let refName = git_reference_name(reference) {
                                _ = git_revwalk_push_ref(walker, refName)
                            }
                            git_reference_free(reference)
                        }
                    }
                }
                if git_repository_head_detached(repo) == 1 { _ = git_revwalk_push_head(walker) }
            } else {
                if git_repository_head_unborn(repo) == 1 { return [] }
                let pushed = git_revwalk_push_head(walker)
                if matches(pushed, GIT_EUNBORNBRANCH) || matches(pushed, GIT_ENOTFOUND) {
                    return []
                }
                try check(pushed, String(localized: "Could not read history"))
            }

            var commits: [CommitInfo] = []
            var oid = git_oid()
            var skipped = 0
            while commits.count < limit, git_revwalk_next(&oid, walker) == 0 {
                if skipped < offset {
                    skipped += 1
                    continue
                }
                var commit: OpaquePointer?
                guard git_commit_lookup(&commit, repo, &oid) == 0, let commit else { continue }
                defer { git_commit_free(commit) }
                let summary = git_commit_summary(commit).map { String(cString: $0) } ?? ""
                let author = git_commit_author(commit).map { String(cString: $0.pointee.name) } ?? ""
                let time = Date(timeIntervalSince1970: TimeInterval(git_commit_time(commit)))
                var parents: [String] = []
                let parentCount = Int(git_commit_parentcount(commit))
                if parentCount > 0 {
                    for index in 0..<parentCount {
                        if let parent = git_commit_parent_id(commit, UInt32(index)) {
                            parents.append(format(parent.pointee))
                        }
                    }
                }
                commits.append(CommitInfo(id: format(oid), summary: summary, author: author, date: time, parents: parents))
            }
            return commits
        }
    }

    enum DiffScope: String, CaseIterable {
        case combined, worktree, staged
    }

    static func diff(at repoURL: URL, scope: DiffScope = .combined, path: String? = nil) throws -> String {
        try locked {
            let opened = try open(repoURL)
            defer { withExtendedLifetime(opened) {} }
            let repo = opened.repo
            let tree = try headTree(repo)
            defer { git_tree_free(tree) }
            var diff: OpaquePointer?
            var options = git_diff_options()
            git_diff_options_init(&options, UInt32(GIT_DIFF_OPTIONS_VERSION))
            options.max_size = 256 * 1024
            options.flags = GIT_DIFF_DISABLE_PATHSPEC_MATCH.rawValue
            if scope == .worktree {
                options.flags |= GIT_DIFF_INCLUDE_UNTRACKED.rawValue | GIT_DIFF_RECURSE_UNTRACKED_DIRS.rawValue
                    | GIT_DIFF_SHOW_UNTRACKED_CONTENT.rawValue
            }
            let makeDiff = {
                let code: Int32
                switch scope {
                case .combined: code = git_diff_tree_to_workdir_with_index(&diff, repo, tree, &options)
                case .staged: code = git_diff_tree_to_index(&diff, repo, tree, nil, &options)
                case .worktree: code = git_diff_index_to_workdir(&diff, repo, nil, &options)
                }
                try check(code, String(localized: "Could not read changes"))
            }
            if let path {
                try requireFilePath(path)
                try withRefspec(path) { paths in
                    options.pathspec = paths.pointee
                    try makeDiff()
                }
            } else { try makeDiff() }
            defer { git_diff_free(diff) }
            var buffer = git_buf()
            defer { git_buf_dispose(&buffer) }
            try check(
                git_diff_to_buf(&buffer, diff, GIT_DIFF_FORMAT_PATCH),
                String(localized: "Could not read changes")
            )
            guard let pointer = buffer.ptr else { return "" }
            return String(cString: pointer)
        }
    }

    static func stageAll(at repoURL: URL, lfsAuth: LFSAuth? = nil) throws {
        try writing(repoURL) {
        try locked {
            let opened = try open(repoURL)
            defer { withExtendedLifetime(opened) {} }
            let repo = opened.repo
            guard !indexHasConflicts(repo) else { throw GitFailure.message(operationError) }
            var index: OpaquePointer?
            try check(git_repository_index(&index, repo), String(localized: "Could not stage files"))
            defer { git_index_free(index) }
            try check(git_index_add_all(index, nil, 0, nil, nil), String(localized: "Could not stage files"))
            let indexedPaths = Set((0..<git_index_entrycount(index)).compactMap { offset -> String? in
                guard let entry = git_index_get_byindex(index, offset), let path = entry.pointee.path else { return nil }
                return String(cString: path)
            })
            try applyLFSClean(repo: repo, index: index!, auth: lfsAuth, paths: indexedPaths)
            try check(git_index_write(index), String(localized: "Could not stage files"))
        }
        }
    }

    static func unstageAll(at repoURL: URL) throws {
        try writing(repoURL) {
        try locked {
            let opened = try open(repoURL)
            defer { withExtendedLifetime(opened) {} }
            let repo = opened.repo
            try requireNoOperation(repo)
            guard !indexHasConflicts(repo) else { throw GitFailure.message(operationError) }
            var head: OpaquePointer?
            let code = git_revparse_single(&head, repo, "HEAD")
            if code < 0 {
                var index: OpaquePointer?
                try check(git_repository_index(&index, repo), String(localized: "Could not unstage files"))
                defer { git_index_free(index) }
                git_index_clear(index)
                try check(git_index_write(index), String(localized: "Could not unstage files"))
                return
            }
            defer { git_object_free(head) }
            try check(
                git_reset(repo, head, GIT_RESET_MIXED, nil),
                String(localized: "Could not unstage files")
            )
        }
        }
    }

    static func commit(
        at repoURL: URL,
        message: String,
        name: String,
        email: String,
        lfsAuth: LFSAuth? = nil
    ) throws {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw GitFailure.message(String(localized: "Enter a commit message."))
        }
        guard !name.isEmpty, !email.isEmpty else {
            throw GitFailure.message(String(localized: "Set your name and email in Settings before committing."))
        }
        try writing(repoURL) {
        try locked {
            let opened = try open(repoURL)
            defer { withExtendedLifetime(opened) {} }
            let repo = opened.repo
            try requireNoOperation(repo)
            let entries = try statusUnlocked(repo)
            guard entries.contains(where: \.staged) else {
                throw GitFailure.message(String(localized: "Nothing to commit"))
            }
            var index: OpaquePointer?
            try check(git_repository_index(&index, repo), String(localized: "Could not commit"))
            defer { git_index_free(index) }
            var tree = git_oid()
            try check(git_index_write_tree(&tree, index), String(localized: "Could not commit"))
            let parent = try headCommit(repo)
            defer { git_commit_free(parent) }
            let parents = parent.map { [$0] } ?? []
            try writeCommit(repo: repo, tree: tree, parents: parents, message: trimmed, name: name, email: email)
        }
        }
    }

    static func pull(
        at repoURL: URL,
        username: String,
        secret: String,
        sshKey: SSHKeyMaterial? = nil,
        lfsAuth: LFSAuth? = nil,
        name: String,
        email: String,
        progress: GitProgressHandler? = nil
    ) throws {
        let reporter = GitProgressReporter(handler: progress)
        reporter.report(.preparing)
        try writing(repoURL) {
        try locked {
            let opened = try open(repoURL)
            defer { withExtendedLifetime(opened) {} }
            let repo = opened.repo
            try requireCleanOperationStart(repo)
            let upstream = try fetchUpstream(repo, username: username, secret: secret, sshKey: sshKey, progress: reporter)
            defer { git_reference_free(upstream) }
            var annotated: OpaquePointer?
            try check(
                git_annotated_commit_from_ref(&annotated, repo, upstream),
                String(localized: "Could not pull")
            )
            defer { git_annotated_commit_free(annotated) }
            reporter.report(.merging)
            let analysis = try mergeAnalysis(repo, annotated: annotated)
            if analysis.upToDate { return }
            if analysis.fastForward {
                try fastForward(repo, to: upstream, progress: reporter)
                return
            }
            if analysis.normal {
                guard !name.isEmpty, !email.isEmpty else {
                    throw GitFailure.message(String(localized: "Set your name and email in Settings before committing."))
                }
                try merge(repo, annotated: annotated, name: name, email: email, progress: reporter)
                return
            }
            throw GitFailure.message(String(localized: "Could not pull"))
        }
        reporter.report(.largeFiles)
        try smudgeLFS(at: repoURL, remoteURL: try transportURL(at: repoURL), auth: lfsAuth)
        }
    }

    static func push(
        at repoURL: URL,
        username: String,
        secret: String,
        sshKey: SSHKeyMaterial? = nil,
        lfsAuth: LFSAuth? = nil,
        remoteName: String? = nil,
        progress: GitProgressHandler? = nil
    ) throws {
        let reporter = GitProgressReporter(handler: progress)
        reporter.report(.preparing)
        try writing(repoURL) {
        try locked {
            let handle = try open(repoURL)
            defer { withExtendedLifetime(handle) {} }
            let repo = handle.repo
            guard git_repository_head_detached(repo) != 1 else {
                throw GitFailure.message(String(localized: "Create or check out a branch before pushing from detached HEAD."))
            }
            let branch = try currentBranch(repo)
            let destination = try syncRemote(repo, requested: remoteName)
            let upstream = upstreamUnlocked(repo)
            var target = branch
            if let upstream, upstream.remote == destination { target = upstream.branch }
            var remote: OpaquePointer?
            let lookup = git_remote_lookup(&remote, repo, destination)
            if lookup < 0 {
                throw GitFailure.message(String(localized: "This repository has no origin remote."))
            }
            defer { git_remote_free(remote) }

            let box = CredentialBox(username: username, secret: secret, sshKey: sshKey, progress: reporter)
            defer { withExtendedLifetime(box) {} }
            var options = git_push_options()
            try check(git_push_options_init(&options, UInt32(GIT_PUSH_OPTIONS_VERSION)), String(localized: "Could not push"))
            applyTransport(&options.callbacks, box: box)

            reporter.report(.connecting)
            let spec = "refs/heads/\(branch):refs/heads/\(target)"
            try withRefspec(spec) { refspecs in
                try check(git_remote_push(remote, refspecs, &options), String(localized: "Could not push"))
            }

            if let rejected = box.pushError { throw GitFailure.message(rejected) }
            var branchRef: OpaquePointer?
            if upstream == nil, git_branch_lookup(&branchRef, repo, branch, GIT_BRANCH_LOCAL) == 0 {
                defer { git_reference_free(branchRef) }
                try check(git_branch_set_upstream(branchRef, "\(destination)/\(target)"), String(localized: "Could not update branch."))
            }
        }
        }
    }

    static func fetch(
        at repoURL: URL,
        username: String,
        secret: String,
        sshKey: SSHKeyMaterial? = nil,
        lfsAuth: LFSAuth? = nil,
        remoteName: String? = nil,
        progress: GitProgressHandler? = nil
    ) throws {
        let reporter = GitProgressReporter(handler: progress)
        reporter.report(.preparing)
        try writing(repoURL) {
            try locked {
                let opened = try open(repoURL)
                defer { withExtendedLifetime(opened) {} }
                try fetchOrigin(opened.repo, username: username, secret: secret, sshKey: sshKey, remoteName: remoteName, progress: reporter)
            }
        }
    }

    static func show(at repoURL: URL, commit id: String) throws -> String {
        try locked {
            let opened = try open(repoURL)
            defer { withExtendedLifetime(opened) {} }
            let repo = opened.repo
            var oid = git_oid()
            try check(git_oid_fromstr(&oid, id), String(localized: "Could not read that commit."))
            var lookedUp: OpaquePointer?
            try check(git_commit_lookup(&lookedUp, repo, &oid), String(localized: "Could not read that commit."))
            guard let commit = lookedUp else {
                throw GitFailure.message(String(localized: "Could not read that commit."))
            }
            defer { git_commit_free(commit) }
            let message = git_commit_message(commit).map { String(cString: $0) } ?? ""
            var newTree: OpaquePointer?
            try check(git_commit_tree(&newTree, commit), String(localized: "Could not read that commit."))
            defer { git_tree_free(newTree) }
            var oldTree: OpaquePointer?
            if git_commit_parentcount(commit) > 0 {
                var parent: OpaquePointer?
                if git_commit_parent(&parent, commit, 0) == 0 {
                    defer { git_commit_free(parent) }
                    git_commit_tree(&oldTree, parent)
                }
            }
            defer { git_tree_free(oldTree) }
            var diff: OpaquePointer?
            var options = git_diff_options()
            git_diff_options_init(&options, UInt32(GIT_DIFF_OPTIONS_VERSION))
            // A single huge generated file can make libgit2's line diff take many
            // seconds. Treat blobs above this size as binary; the patch then stays
            // small and the commit page opens immediately.
            options.max_size = 256 * 1024
            try check(
                git_diff_tree_to_tree(&diff, repo, oldTree, newTree, &options),
                String(localized: "Could not read that commit.")
            )
            defer { git_diff_free(diff) }
            var buffer = git_buf()
            defer { git_buf_dispose(&buffer) }
            try check(git_diff_to_buf(&buffer, diff, GIT_DIFF_FORMAT_PATCH), String(localized: "Could not read that commit."))
            let patch = buffer.ptr.map { String(cString: $0) } ?? ""
            let text = message + (patch.isEmpty ? "" : "\n" + patch)
            return text.count > 80_000 ? String(text.prefix(80_000)) : text
        }
    }

    static func branches(at repoURL: URL) throws -> [BranchInfo] {
        try locked {
            let opened = try open(repoURL)
            defer { withExtendedLifetime(opened) {} }
            return try branchesUnlocked(opened.repo)
        }
    }

    private static func branchesUnlocked(_ repo: OpaquePointer) throws -> [BranchInfo] {
        let current = try? currentBranch(repo)
        var iterator: OpaquePointer?
        try check(
            git_branch_iterator_new(&iterator, repo, GIT_BRANCH_ALL),
            String(localized: "Could not read branches.")
        )
        defer { git_branch_iterator_free(iterator) }
        var listed: [BranchInfo] = []
        while true {
            var reference: OpaquePointer?
            var type = git_branch_t(0)
            let code = git_branch_next(&reference, &type, iterator)
            if code != 0 { break }
            defer { git_reference_free(reference) }
            guard let reference, let raw = git_reference_shorthand(reference) else { continue }
            let name = String(cString: raw)
            let remote = type == GIT_BRANCH_REMOTE
            let target = git_reference_target(reference).map { format($0.pointee) }
            listed.append(BranchInfo(
                name: name,
                isCurrent: !remote && name == current,
                isRemote: remote,
                target: target
            ))
        }
        return listed.sorted { lhs, rhs in
            if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent }
            if lhs.isRemote != rhs.isRemote { return !lhs.isRemote }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    static func createBranch(at repoURL: URL, name branch: String, checkout: Bool) throws {
        let branch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidBranchName(branch) else {
            throw GitFailure.message(String(localized: "Enter a valid branch name."))
        }
        try writing(repoURL) {
            try locked {
                let opened = try open(repoURL)
                defer { withExtendedLifetime(opened) {} }
                try requireNoOperation(opened.repo)
                guard let head = try headCommit(opened.repo) else {
                    throw GitFailure.message(String(localized: "No commits yet"))
                }
                defer { git_commit_free(head) }
                var reference: OpaquePointer?
                try check(
                    git_branch_create(&reference, opened.repo, branch, head, 0),
                    String(localized: "Could not create that branch.")
                )
                git_reference_free(reference)
                if checkout {
                    try checkoutLocal(opened.repo, branch: branch)
                }
            }
        }
    }

    static func checkout(at repoURL: URL, branch: String) throws {
        try writing(repoURL) {
            try locked {
                let opened = try open(repoURL)
                defer { withExtendedLifetime(opened) {} }
                try requireNoOperation(opened.repo)
                try checkoutLocal(opened.repo, branch: branch)
            }
        }
    }

    @discardableResult
    static func checkoutRemote(at repoURL: URL, branch remoteBranch: String) throws -> String {
        var localResult = ""
        try writing(repoURL) {
            try locked {
                let opened = try open(repoURL)
                defer { withExtendedLifetime(opened) {} }
                let repo = opened.repo
                try requireNoOperation(repo)
                let parts = remoteBranch.split(separator: "/", maxSplits: 1)
                guard parts.count == 2, !parts[1].isEmpty else {
                    throw GitFailure.message(String(localized: "Could not switch to that branch."))
                }
                let localName = String(parts[1])

                var existing: OpaquePointer?
                if git_branch_lookup(&existing, repo, localName, GIT_BRANCH_LOCAL) == 0 {
                    git_reference_free(existing)
                    try checkoutLocal(repo, branch: localName)
                    localResult = localName
                    return
                }

                var remoteRef: OpaquePointer?
                try check(
                    git_branch_lookup(&remoteRef, repo, remoteBranch, GIT_BRANCH_REMOTE),
                    String(localized: "Could not switch to that branch.")
                )
                defer { git_reference_free(remoteRef) }
                guard let target = git_reference_target(remoteRef) else {
                    throw GitFailure.message(String(localized: "Could not switch to that branch."))
                }
                var oid = target.pointee
                var commit: OpaquePointer?
                try check(
                    git_commit_lookup(&commit, repo, &oid),
                    String(localized: "Could not switch to that branch.")
                )
                defer { git_commit_free(commit) }
                var localRef: OpaquePointer?
                try check(
                    git_branch_create(&localRef, repo, localName, commit, 0),
                    String(localized: "Could not switch to that branch.")
                )
                if let localRef {
                    git_branch_set_upstream(localRef, remoteBranch)
                    git_reference_free(localRef)
                }
                try checkoutLocal(repo, branch: localName)
                localResult = localName
            }
        }
        return localResult
    }

    static func mergeBranch(at repoURL: URL, branch: String, name: String, email: String) throws {
        try writing(repoURL) {
            try locked {
                let opened = try open(repoURL)
                defer { withExtendedLifetime(opened) {} }
                let repo = opened.repo
            try requireCleanOperationStart(repo)
                var reference: OpaquePointer?
                try check(
                    git_branch_lookup(&reference, repo, branch, GIT_BRANCH_LOCAL),
                    String(localized: "Could not merge that branch.")
                )
                defer { git_reference_free(reference) }
                var annotated: OpaquePointer?
                try check(
                    git_annotated_commit_from_ref(&annotated, repo, reference),
                    String(localized: "Could not merge that branch.")
                )
                defer { git_annotated_commit_free(annotated) }
                let analysis = try mergeAnalysis(repo, annotated: annotated)
                if analysis.upToDate { return }
                if analysis.fastForward {
                    try fastForward(repo, to: reference)
                    return
                }
                if analysis.normal {
                    guard !name.isEmpty, !email.isEmpty else {
                        throw GitFailure.message(String(localized: "Set your name and email in Settings before committing."))
                    }
                    try merge(repo, annotated: annotated, name: name, email: email)
                    return
                }
                throw GitFailure.message(String(localized: "Could not merge that branch."))
            }
        }
    }

    static func rebase(at repoURL: URL, onto branch: String, name: String, email: String) throws {
        guard !name.isEmpty, !email.isEmpty else {
            throw GitFailure.message(String(localized: "Set your name and email in Settings before committing."))
        }
        try writing(repoURL) {
            try locked {
                let opened = try open(repoURL)
                defer { withExtendedLifetime(opened) {} }
                let repo = opened.repo
                var reference: OpaquePointer?
                try check(
                    git_branch_lookup(&reference, repo, branch, GIT_BRANCH_LOCAL),
                    String(localized: "Could not rebase.")
                )
                defer { git_reference_free(reference) }
                var onto: OpaquePointer?
                try check(
                    git_annotated_commit_from_ref(&onto, repo, reference),
                    String(localized: "Could not rebase.")
                )
                defer { git_annotated_commit_free(onto) }
                var options = git_rebase_options()
                try check(
                    git_rebase_options_init(&options, UInt32(GIT_REBASE_OPTIONS_VERSION)),
                    String(localized: "Could not rebase.")
                )
                var rebase: OpaquePointer?
                try beginOperation(repo, kind: .rebase, target: oidString(git_annotated_commit_id(onto)))
                options.checkout_options.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue | GIT_CHECKOUT_RECREATE_MISSING.rawValue | GIT_CHECKOUT_DONT_OVERWRITE_IGNORED.rawValue
                let started = git_rebase_init(&rebase, repo, nil, onto, nil, &options)
                try check(started, String(localized: "Could not rebase."))
                defer { git_rebase_free(rebase) }
                var signature: UnsafeMutablePointer<git_signature>?
                try check(git_signature_now(&signature, name, email), String(localized: "Could not rebase."))
                defer { git_signature_free(signature) }
                try advanceRebase(repo, rebase: rebase, signature: signature, commitCurrent: false)
            }
        }
    }

    static func cherryPick(at repoURL: URL, commit id: String, name: String, email: String) throws {
        let revision = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !revision.isEmpty else {
            throw GitFailure.message(String(localized: "Enter a commit."))
        }
        guard !name.isEmpty, !email.isEmpty else {
            throw GitFailure.message(String(localized: "Set your name and email in Settings before committing."))
        }
        try writing(repoURL) {
            try locked {
                let opened = try open(repoURL)
                defer { withExtendedLifetime(opened) {} }
                let repo = opened.repo
                // Recovery and abort are safe only when the operation starts clean.
                guard git_repository_state(repo) == GIT_REPOSITORY_STATE_NONE.rawValue,
                      try statusUnlocked(repo).isEmpty else {
                    throw GitFailure.message(String(localized: "Commit or discard your changes before cherry-picking."))
                }
                var object: OpaquePointer?
                try check(git_revparse_single(&object, repo, revision), String(localized: "Could not cherry-pick that commit."))
                defer { git_object_free(object) }
                var commit: OpaquePointer?
                try check(
                    git_commit_lookup(&commit, repo, git_object_id(object)),
                    String(localized: "Could not cherry-pick that commit.")
                )
                defer { git_commit_free(commit) }
                if git_commit_parentcount(commit) > 1 {
                    throw GitFailure.message(String(localized: "Cherry-pick of a merge commit is not in this version."))
                }
                var options = git_cherrypick_options()
                try check(
                    git_cherrypick_options_init(&options, UInt32(GIT_CHERRYPICK_OPTIONS_VERSION)),
                    String(localized: "Could not cherry-pick that commit.")
                )
                try beginOperation(repo, kind: .cherryPick, target: oidString(git_commit_id(commit)))
                options.checkout_opts.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue | GIT_CHECKOUT_RECREATE_MISSING.rawValue | GIT_CHECKOUT_DONT_OVERWRITE_IGNORED.rawValue
                let picked = git_cherrypick(repo, commit, &options)
                if indexHasConflicts(repo) { return }
                try check(picked, String(localized: "Could not cherry-pick that commit."))
                try finishOperationCommit(repo, name: name, email: email)
            }
        }
    }

    static func resetHard(at repoURL: URL) throws {
        try writing(repoURL) {
            try locked {
                let opened = try open(repoURL)
                defer { withExtendedLifetime(opened) {} }
                try requireNoOperation(opened.repo)
                var head: OpaquePointer?
                try check(git_revparse_single(&head, opened.repo, "HEAD"), String(localized: "Could not reset."))
                defer { git_object_free(head) }
                var checkout = git_checkout_options()
                try check(
                    git_checkout_options_init(&checkout, UInt32(GIT_CHECKOUT_OPTIONS_VERSION)),
                    String(localized: "Could not reset.")
                )
                checkout.checkout_strategy = GIT_CHECKOUT_FORCE.rawValue
                try check(
                    git_reset(opened.repo, head, GIT_RESET_HARD, &checkout),
                    String(localized: "Could not reset.")
                )
            }
        }
    }

    static func remotes(at repoURL: URL) throws -> [RemoteInfo] {
        try locked {
            let opened = try open(repoURL)
            defer { withExtendedLifetime(opened) {} }
            return try remotesUnlocked(opened.repo)
        }
    }

    private static func remotesUnlocked(_ repo: OpaquePointer) throws -> [RemoteInfo] {
        var names = git_strarray()
        try check(git_remote_list(&names, repo), String(localized: "Could not read remotes."))
        defer { git_strarray_dispose(&names) }
        var listed: [RemoteInfo] = []
        let count = Int(names.count)
        guard let strings = names.strings else { return [] }
        for index in 0..<count {
            guard let pointer = strings[index] else { continue }
            let name = String(cString: pointer)
            var remote: OpaquePointer?
            guard git_remote_lookup(&remote, repo, name) == 0, let remote else { continue }
            let url = git_remote_url(remote).map { String(cString: $0) } ?? ""
            git_remote_free(remote)
            listed.append(RemoteInfo(name: name, url: url))
        }
        return listed
    }

    static func removeRemote(at repoURL: URL, name: String) throws {
        try writing(repoURL) {
            try locked {
                let opened = try open(repoURL)
                defer { withExtendedLifetime(opened) {} }
                try check(git_remote_delete(opened.repo, name), String(localized: "Could not remove that remote."))
            }
        }
    }

    static func syncCounts(at repoURL: URL) -> SyncCounts? {
        do {
            return try locked {
                let opened = try open(repoURL)
                defer { withExtendedLifetime(opened) {} }
                var head: OpaquePointer?
                guard git_repository_head(&head, opened.repo) == 0, let head else { return nil }
                defer { git_reference_free(head) }
                var upstream: OpaquePointer?
                guard git_branch_upstream(&upstream, head) == 0, let upstream else { return nil }
                defer { git_reference_free(upstream) }
                guard let local = git_reference_target(head), let remote = git_reference_target(upstream) else { return nil }
                var ahead: Int = 0
                var behind: Int = 0
                var localOID = local.pointee
                var remoteOID = remote.pointee
                guard git_graph_ahead_behind(&ahead, &behind, opened.repo, &localOID, &remoteOID) == 0 else { return nil }
                return SyncCounts(ahead: ahead, behind: behind)
            }
        } catch {
            return nil
        }
    }

    static func createWorkItem(at repoURL: URL, name: String, directory: Bool) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), name != ".", name != "..", name != ".git" else {
            throw GitFailure.message(String(localized: "Enter a file name."))
        }
        try writing(repoURL) {
            try locked {
                let opened = try open(repoURL)
                defer { withExtendedLifetime(opened) {} }
                guard let path = git_repository_workdir(opened.repo) else {
                    throw GitFailure.message(String(localized: "Could not use that folder."))
                }
                let target = URL(fileURLWithPath: String(cString: path), isDirectory: true).appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: target.path) {
                    throw GitFailure.message(String(localized: "That name is already used."))
                }
                if directory {
                    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
                } else if !FileManager.default.createFile(atPath: target.path, contents: Data()) {
                    throw GitFailure.message(String(localized: "Could not use that folder."))
                }
            }
        }
    }

    static func configText(at repoURL: URL) -> String {
        let url = repoURL.appendingPathComponent(".git/config")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    static func commandOutput(at repoURL: URL, line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = trimmed.hasPrefix("git ") ? String(trimmed.dropFirst(4)) : trimmed
        let parts = command.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let name = parts.first else { return "" }
        switch name {
        case "help", "--help", "-h":
            return String(localized: "Commands: status, log, diff, branch, help. This console runs those Git commands. It is not a shell.")
        case "status":
            return (try? statusText(at: repoURL)) ?? String(localized: "Could not read changes")
        case "log":
            let commits = (try? history(at: repoURL, limit: 20, allBranches: parts.contains("--all"))) ?? []
            if commits.isEmpty { return String(localized: "No commits yet") }
            return commits.map { "\(String($0.id.prefix(7))) \($0.summary)" }.joined(separator: "\n")
        case "diff":
            let scope: DiffScope = parts.contains("--cached") || parts.contains("--staged") ? .staged : .worktree
            let text = (try? diff(at: repoURL, scope: scope)) ?? ""
            return text.isEmpty ? String(localized: "No changes") : text
        case "branch":
            let listed = (try? branches(at: repoURL)) ?? []
            if listed.isEmpty { return String(localized: "No commits yet") }
            return listed.map { "\($0.isCurrent ? "* " : "  ")\($0.name)" }.joined(separator: "\n")
        default:
            return String(localized: "Unknown command. Try help.")
        }
    }

    static func statusText(at repoURL: URL) throws -> String {
        let head = try locked { () -> (String, String?) in
            let opened = try open(repoURL)
            defer { withExtendedLifetime(opened) {} }
            return (headLabel(opened.repo) ?? String(localized: "No commits yet"), detachedOID(opened.repo))
        }
        let entries = try status(at: repoURL)
        return statusText(entries: entries, branch: head.0, sync: syncCounts(at: repoURL), detachedOID: head.1)
    }

    static func statusText(entries: [StatusEntry], branch: String, sync: SyncCounts?, detachedOID: String? = nil) -> String {
        let heading = detachedOID.map { String(format: String(localized: "Detached HEAD · %@"), String($0.prefix(12))) }
            ?? String(format: String(localized: "On branch %@"), branch)
        var lines = [heading]
        let staged = entries.filter(\.staged)
        let unstaged = entries.filter { $0.unstaged && !$0.untracked }
        let untracked = entries.filter(\.untracked)
        if !staged.isEmpty {
            lines.append("")
            lines.append(String(localized: "Changes to be committed:"))
            staged.forEach { lines.append("        \($0.path)") }
        }
        if !unstaged.isEmpty {
            lines.append("")
            lines.append(String(localized: "Changes not staged for commit:"))
            unstaged.forEach { lines.append("        \($0.path)") }
        }
        if !untracked.isEmpty {
            lines.append("")
            lines.append(String(localized: "Untracked files:"))
            untracked.forEach { lines.append("        \($0.path)") }
        }
        if staged.isEmpty && unstaged.isEmpty && untracked.isEmpty {
            lines.append(String(localized: "nothing to commit, working tree clean"))
        }
        if let counts = sync, counts.ahead > 0 || counts.behind > 0 {
            lines.append(String(format: String(localized: "Your branch is %@ ahead and %@ behind."), "\(counts.ahead)", "\(counts.behind)"))
        }
        return lines.joined(separator: "\n")
    }

    static func entries(at repoURL: URL, directory: String) throws -> [WorkEntry] {
        let access = WorktreeLink.begin(repoName: repoURL.lastPathComponent)
        defer { access?.stop() }
        let folder = (access?.url ?? repoURL).appendingPathComponent(directory)
        let items = try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )
        return items.compactMap { url in
            if url.lastPathComponent == ".git" { return nil }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let relative = directory.isEmpty ? url.lastPathComponent : directory + "/" + url.lastPathComponent
            return WorkEntry(path: relative, name: url.lastPathComponent, isDirectory: isDirectory)
        }
        .sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory && !rhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    static func readText(at repoURL: URL, relative: String) throws -> String {
        let access = try WorktreeLink.beginForFileRestore(repoName: repoURL.lastPathComponent)
        defer { access?.stop() }
        let root = try SearchWorktreeAccess.root(access?.url ?? repoURL)
        return try SearchWorktreeAccess.preview(root: root, path: relative)
    }

    static func originURL(_ repoURL: URL) throws -> String {
        try locked {
            let opened = try open(repoURL)
            defer { withExtendedLifetime(opened) {} }
            var remote: OpaquePointer?
            if git_remote_lookup(&remote, opened.repo, "origin") == 0, let remote {
                defer { git_remote_free(remote) }
                if let url = git_remote_url(remote) { return String(cString: url) }
            }
            throw GitFailure.message(String(localized: "This repository has no origin remote."))
        }
    }

    static func host(of urlString: String) -> String? {
        if let host = URL(string: urlString)?.host { return host.lowercased() }
        return SSHURL.host(urlString)
    }

    /// Header reads refs/config only. It must not enumerate or hash the worktree.
    static func header(at repoURL: URL) throws -> RepositoryHeader {
        try locked {
            let opened = try open(repoURL)
            defer { withExtendedLifetime(opened) {} }
            return RepositoryHeader(
                branch: headLabel(opened.repo) ?? "",
                origin: originURLUnlocked(opened.repo) ?? "",
                branches: try branchesUnlocked(opened.repo),
                remotes: try remotesUnlocked(opened.repo),
                linkedFolder: opened.access.map { WorktreeLink.displayName(for: $0) },
                upstream: upstreamUnlocked(opened.repo)?.shorthand,
                pendingSubmodules: FileManager.default.fileExists(atPath: submoduleJournalURL(opened.repo).path),
                detachedOID: detachedOID(opened.repo)
            )
        }
    }

    static func summary(at repoURL: URL) -> RepoSummary? {
        try? summarize(at: repoURL)
    }

    private static func summarize(at url: URL) throws -> RepoSummary {
        try locked {
            let opened = try open(url)
            defer { withExtendedLifetime(opened) {} }
            let repo = opened.repo
            let branch = headLabel(repo)
            let dirty = (try? statusUnlocked(repo).isEmpty) == false
            var remote: OpaquePointer?
            var origin: String?
            if git_remote_lookup(&remote, repo, "origin") == 0, let remote {
                origin = git_remote_url(remote).map { String(cString: $0) }
                git_remote_free(remote)
            }
            return RepoSummary(
                name: url.lastPathComponent,
                branch: branch,
                isDirty: dirty,
                origin: origin,
                unavailable: false
            )
        }
    }

    private final class OpenRepo {
        let repo: OpaquePointer
        let access: WorktreeLink.Access?
        init(path: String, access: WorktreeLink.Access?) throws {
            var repo: OpaquePointer?
            let code = git_repository_open(&repo, path)
            if code < 0 || repo == nil {
                throw GitFailure.message(String(localized: "Could not open repository"))
            }
            self.repo = repo!
            self.access = access
            if let access {
                try GitClient.useWorkDirectory(access, repo: self.repo)
            }
        }
        deinit {
            git_repository_free(repo)
            access?.stop()
        }
    }

    private static func open(_ url: URL) throws -> OpenRepo {
        let access = WorktreeLink.begin(repoName: url.lastPathComponent)
        do {
            return try OpenRepo(path: url.path, access: access)
        } catch {
            access?.stop()
            throw error
        }
    }

    private static func workDirectory(_ repo: OpaquePointer) throws -> URL {
        guard let path = git_repository_workdir(repo) else {
            throw GitFailure.message(String(localized: "Could not use that folder."))
        }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
    }

    private static func attach(_ repo: OpaquePointer, repoURL: URL, bookmark: Data) throws {
        let access = try WorktreeLink.makeAccess(from: bookmark, repoName: repoURL.lastPathComponent)
        defer { access.stop() }
        let source = try workDirectory(repo)
        let target = access.url.resolvingSymlinksInPath().standardizedFileURL
        guard target != repoURL.resolvingSymlinksInPath().standardizedFileURL,
              (try? target.appendingPathComponent(".git").resourceValues(forKeys: [.isSymbolicLinkKey])) == nil else {
            throw GitFailure.message(String(localized: "Could not use that folder."))
        }
        // Copy the actual worktree, including staged, unstaged, ignored and untracked
        // files. HEAD is not a backup of the user's current files.
        try copyWorkingFiles(from: source, to: target)
        try useWorkDirectory(access, repo: repo)
        do {
            try WorktreeLink.save(repoName: repoURL.lastPathComponent, data: bookmark)
        } catch {
            _ = git_repository_set_workdir(repo, source.path, 0)
            throw error
        }
        // Only the internal copy is removed. Previously linked folders stay intact.
        if source.resolvingSymlinksInPath().standardizedFileURL == repoURL.resolvingSymlinksInPath().standardizedFileURL {
            try removeWorkingFiles(at: repoURL)
        }
    }

    private static func useWorkDirectory(_ access: WorktreeLink.Access, repo: OpaquePointer) throws {
        try check(
            git_repository_set_workdir(repo, access.url.path, 0),
            String(localized: "Could not use that folder.")
        )
    }

    /// Validate all collisions before copying anything; never overwrite destination
    /// files and never remove a source until both copying and bookmark storage succeed.
    private static func copyWorkingFiles(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        let source = source.resolvingSymlinksInPath().standardizedFileURL
        let destination = destination.resolvingSymlinksInPath().standardizedFileURL
        if source == destination { return }
        guard !destination.path.hasPrefix(source.path + "/"),
              !source.path.hasPrefix(destination.path + "/") else {
            throw GitFailure.message(String(localized: "Could not use that folder."))
        }
        var copies: [(URL, URL)] = []
        func plan(_ from: URL, _ to: URL) throws {
            let sourceValues = try from.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            // resourceValues also detects dangling symbolic links, unlike fileExists.
            guard let targetValues = try? to.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
                copies.append((from, to))
                return
            }
            if sourceValues.isSymbolicLink == true || targetValues.isSymbolicLink == true {
                guard sourceValues.isSymbolicLink == true, targetValues.isSymbolicLink == true,
                      try fm.destinationOfSymbolicLink(atPath: from.path) == fm.destinationOfSymbolicLink(atPath: to.path) else {
                    throw WorkingTreeError.collision
                }
            } else if sourceValues.isDirectory == true && targetValues.isDirectory == true {
                for child in try fm.contentsOfDirectory(at: from, includingPropertiesForKeys: nil) {
                    try plan(child, to.appendingPathComponent(child.lastPathComponent))
                }
            } else if sourceValues.isDirectory != targetValues.isDirectory || !fm.contentsEqual(atPath: from.path, andPath: to.path) {
                throw WorkingTreeError.collision
            }
        }
        for item in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) where item.lastPathComponent != ".git" {
            try plan(item, destination.appendingPathComponent(item.lastPathComponent))
        }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        for (from, to) in copies { try fm.copyItem(at: from, to: to) }
    }

    private static func fetchOrigin(
        _ repo: OpaquePointer,
        username: String,
        secret: String,
        sshKey: SSHKeyMaterial?,
        remoteName: String? = nil,
        progress: GitProgressReporter = .init(handler: nil)
    ) throws {
        let destination = try syncRemote(repo, requested: remoteName)
        var remote: OpaquePointer?
        if git_remote_lookup(&remote, repo, destination) < 0 {
            throw GitFailure.message(String(localized: "This repository has no origin remote."))
        }
        defer { git_remote_free(remote) }
        let box = CredentialBox(username: username, secret: secret, sshKey: sshKey, progress: progress)
            defer { withExtendedLifetime(box) {} }
        var fetch = git_fetch_options()
        try check(git_fetch_options_init(&fetch, UInt32(GIT_FETCH_OPTIONS_VERSION)), String(localized: "Could not pull"))
        applyTransport(&fetch.callbacks, box: box)
        progress.report(.connecting)
        try check(git_remote_fetch(remote, nil, &fetch, "fetch"), String(localized: "Could not pull"))
    }

    private static func checkoutLocal(_ repo: OpaquePointer, branch: String) throws {
        var reference: OpaquePointer?
        try check(
            git_branch_lookup(&reference, repo, branch, GIT_BRANCH_LOCAL),
            String(localized: "Could not switch to that branch.")
        )
        defer { git_reference_free(reference) }
        guard let target = git_reference_target(reference) else {
            throw GitFailure.message(String(localized: "Could not switch to that branch."))
        }
        var oid = target.pointee
        var object: OpaquePointer?
        try check(
            git_object_lookup(&object, repo, &oid, GIT_OBJECT_COMMIT),
            String(localized: "Could not switch to that branch.")
        )
        defer { git_object_free(object) }
        var options = git_checkout_options()
        try check(
            git_checkout_options_init(&options, UInt32(GIT_CHECKOUT_OPTIONS_VERSION)),
            String(localized: "Could not switch to that branch.")
        )
        options.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue | GIT_CHECKOUT_RECREATE_MISSING.rawValue
        try check(git_checkout_tree(repo, object, &options), String(localized: "Could not switch to that branch."))
        try check(
            git_repository_set_head(repo, "refs/heads/\(branch)"),
            String(localized: "Could not switch to that branch.")
        )
    }

    private static func removeWorkingFiles(at repoURL: URL) throws {
        let items = try FileManager.default.contentsOfDirectory(at: repoURL, includingPropertiesForKeys: nil)
        for item in items where item.lastPathComponent != ".git" {
            try FileManager.default.removeItem(at: item)
        }
    }

    private static func locked<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        _ = ready
        return try body()
    }

    private static func writing(_ repoURL: URL, _ body: () throws -> Void) throws {
        try RepoWriteLock.withLock(at: repoURL, body)
    }

    private static func destinationURL(name: String, root: URL) throws -> URL {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw GitFailure.message(String(localized: "Enter a repository name."))
        }
        if trimmed.contains("/") || trimmed.contains("\\") || trimmed.hasPrefix(".") || trimmed == ".." {
            throw GitFailure.message(String(localized: "Use a name without slashes or a leading dot."))
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent(trimmed, isDirectory: true)
        let rootPath = root.standardizedFileURL.path
        let destinationPath = destination.standardizedFileURL.path
        guard destinationPath.hasPrefix(rootPath + "/") else {
            throw GitFailure.message(String(localized: "Enter a repository name."))
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            throw GitFailure.message(String(localized: "That name is already used."))
        }
        return destination
    }

    private static func tune(_ repo: OpaquePointer) {
        var config: OpaquePointer?
        guard git_repository_config(&config, repo) == 0 else { return }
        defer { git_config_free(config) }
        git_config_set_bool(config, "core.ignorecase", 1)
        git_config_set_bool(config, "core.filemode", 0)
    }

    private static func gitDirectory(_ repo: OpaquePointer) -> URL {
        URL(fileURLWithPath: String(cString: git_repository_path(repo)), isDirectory: true)
    }

    private static func smudgeLFS(at repoURL: URL, remoteURL: String, auth: LFSAuth?) throws {
        try locked {
            let opened = try open(repoURL)
            defer { withExtendedLifetime(opened) {} }
            try LFSClient.smudge(
                at: workDirectory(opened.repo),
                gitDirectory: gitDirectory(opened.repo),
                remoteURL: remoteURL,
                auth: auth
            )
        }
    }

    private static func applyLFSClean(
        repo: OpaquePointer,
        index: OpaquePointer,
        auth: LFSAuth?,
        paths: Set<String>? = nil
    ) throws {
        guard let remote = try? syncURLUnlocked(repo) else { return }
        let regularPaths = paths.map { paths in Set(paths.filter { path in
            guard let entry = git_index_get_bypath(index, path, 0) else { return true }
            return entry.pointee.mode & 0o170000 == 0o100000
        }) }
        let pointers = try LFSClient.clean(at: workDirectory(repo), gitDirectory: gitDirectory(repo), remoteURL: remote, auth: auth, paths: regularPaths)
        guard !pointers.isEmpty else { return }
        for (path, pointer) in pointers {
            let code = path.withCString { pathPointer -> Int32 in
                var entry = git_index_get_bypath(index, pathPointer, 0)?.pointee ?? git_index_entry()
                if entry.mode == 0 { entry.mode = 0o100644 }
                entry.path = pathPointer
                return pointer.raw.withCString { buffer in
                    git_index_add_from_buffer(
                        index,
                        &entry,
                        buffer,
                        pointer.raw.utf8.count
                    )
                }
            }
            try check(code, String(localized: "Could not stage Git LFS files."))
        }
    }

    private static func originURLUnlocked(_ repo: OpaquePointer) -> String? {
        var remote: OpaquePointer?
        guard git_remote_lookup(&remote, repo, "origin") == 0, let remote else { return nil }
        defer { git_remote_free(remote) }
        return git_remote_url(remote).map { String(cString: $0) }
    }

    private static func lfsIndexPointers(_ repo: OpaquePointer, paths: Set<String>) -> [String: LFSPointer] {
        guard !paths.isEmpty else { return [:] }
        var index: OpaquePointer?
        guard git_repository_index(&index, repo) == 0 else { return [:] }
        defer { git_index_free(index) }
        var database: OpaquePointer?
        guard git_repository_odb(&database, repo) == 0 else { return [:] }
        defer { git_odb_free(database) }
        var pointers: [String: LFSPointer] = [:]
        for path in paths {
            guard let entry = git_index_get_bypath(index, path, 0) else { continue }
            var oid = entry.pointee.id
            var objectSize = 0
            var objectType = GIT_OBJECT_INVALID
            // Read the object header before looking up a blob: a modified large
            // normal file must not be decompressed just to detect an LFS pointer.
            guard git_odb_read_header(&objectSize, &objectType, database, &oid) == 0,
                  objectType == GIT_OBJECT_BLOB, objectSize <= 1024 else { continue }
            var blob: OpaquePointer?
            guard git_blob_lookup(&blob, repo, &oid) == 0 else { continue }
            defer { git_blob_free(blob) }
            let size = git_blob_rawsize(blob)
            guard size <= 1024, let bytes = git_blob_rawcontent(blob),
                  let pointer = LFSClient.isPointer(Data(bytes: bytes, count: Int(size))) else { continue }
            pointers[path] = pointer
        }
        return pointers
    }

    private static func statusUnlocked(_ repo: OpaquePointer) throws -> [StatusEntry] {
        var options = git_status_options()
        try check(git_status_options_init(&options, UInt32(GIT_STATUS_OPTIONS_VERSION)), String(localized: "Could not read status"))
        options.flags = GIT_STATUS_OPT_INCLUDE_UNTRACKED.rawValue
            | GIT_STATUS_OPT_RECURSE_UNTRACKED_DIRS.rawValue
            | GIT_STATUS_OPT_RENAMES_HEAD_TO_INDEX.rawValue
            | GIT_STATUS_OPT_RENAMES_INDEX_TO_WORKDIR.rawValue
        var list: OpaquePointer?
        try check(git_status_list_new(&list, repo, &options), String(localized: "Could not read status"))
        defer { git_status_list_free(list) }
        let count = git_status_list_entrycount(list)
        var entries: [StatusEntry] = []
        for index in 0..<count {
            guard let entry = git_status_byindex(list, index) else { continue }
            let status = entry.pointee.status.rawValue
            let path = statusPath(entry)
            guard !path.isEmpty else { continue }
            let indexMask = GIT_STATUS_INDEX_NEW.rawValue
                | GIT_STATUS_INDEX_MODIFIED.rawValue
                | GIT_STATUS_INDEX_DELETED.rawValue
                | GIT_STATUS_INDEX_RENAMED.rawValue
                | GIT_STATUS_INDEX_TYPECHANGE.rawValue
            let workMask = GIT_STATUS_WT_MODIFIED.rawValue
                | GIT_STATUS_WT_DELETED.rawValue
                | GIT_STATUS_WT_RENAMED.rawValue
                | GIT_STATUS_WT_TYPECHANGE.rawValue
            entries.append(StatusEntry(
                path: path,
                staged: status & indexMask != 0,
                unstaged: status & workMask != 0 || status & GIT_STATUS_CONFLICTED.rawValue != 0,
                untracked: status & GIT_STATUS_WT_NEW.rawValue != 0,
                originalPath: {
                    let delta = status & GIT_STATUS_INDEX_RENAMED.rawValue != 0
                        ? entry.pointee.head_to_index : entry.pointee.index_to_workdir
                    guard let delta, delta.pointee.status == GIT_DELTA_RENAMED,
                          let old = delta.pointee.old_file.path else { return nil }
                    return String(cString: old)
                }(),
                conflicted: status & GIT_STATUS_CONFLICTED.rawValue != 0
            ))
        }
        let workdir = git_repository_workdir(repo).map { URL(fileURLWithPath: String(cString: $0)) }
        if let workdir {
            let candidates = Set(entries.filter(\.unstaged).map(\.path))
            let lfsClean = LFSClient.cleanPaths(
                at: workdir, gitDirectory: gitDirectory(repo), candidates: candidates,
                indexPointers: lfsIndexPointers(repo, paths: candidates)
            )
            if !lfsClean.isEmpty {
                return entries.map { entry in
                    var entry = entry
                    if entry.conflicted != true, lfsClean.contains(entry.path) {
                        entry.unstaged = false
                    }
                    return entry
                }.filter { $0.staged || $0.unstaged || $0.untracked }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            }
        }
        return entries.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private static func statusPath(_ entry: UnsafePointer<git_status_entry>) -> String {
        if let workdir = entry.pointee.index_to_workdir, let path = workdir.pointee.new_file.path {
            return String(cString: path)
        }
        if let index = entry.pointee.head_to_index {
            if let path = index.pointee.new_file.path ?? index.pointee.old_file.path {
                return String(cString: path)
            }
        }
        return ""
    }

    private static func headTree(_ repo: OpaquePointer) throws -> OpaquePointer? {
        guard let commit = try headCommit(repo) else { return nil }
        defer { git_commit_free(commit) }
        var tree: OpaquePointer?
        try check(git_commit_tree(&tree, commit), String(localized: "Could not read changes"))
        return tree
    }

    private static func headCommit(_ repo: OpaquePointer) throws -> OpaquePointer? {
        var object: OpaquePointer?
        let code = git_revparse_single(&object, repo, "HEAD")
        if matches(code, GIT_EUNBORNBRANCH) || matches(code, GIT_ENOTFOUND) {
            return nil
        }
        try check(code, String(localized: "Could not commit"))
        var commit: OpaquePointer?
        try check(git_commit_lookup(&commit, repo, git_object_id(object)), String(localized: "Could not commit"))
        git_object_free(object)
        return commit
    }

    private static func writeCommit(
        repo: OpaquePointer,
        tree: git_oid,
        parents: [OpaquePointer],
        message: String,
        name: String,
        email: String
    ) throws {
        var signature: UnsafeMutablePointer<git_signature>?
        try check(git_signature_now(&signature, name, email), String(localized: "Could not commit"))
        defer { git_signature_free(signature) }
        var treeOID = tree
        var treeObject: OpaquePointer?
        try check(git_tree_lookup(&treeObject, repo, &treeOID), String(localized: "Could not commit"))
        defer { git_tree_free(treeObject) }
        var commitOID = git_oid()
        let text = message.hasSuffix("\n") ? message : message + "\n"
        if parents.isEmpty {
            try check(
                git_commit_create(&commitOID, repo, "HEAD", signature, signature, nil, text, treeObject, 0, nil),
                String(localized: "Could not commit")
            )
            return
        }
        var parentPointers: [OpaquePointer?] = parents.map { $0 }
        let parentCount = parentPointers.count
        try parentPointers.withUnsafeMutableBufferPointer { buffer in
            try check(
                git_commit_create(
                    &commitOID,
                    repo,
                    "HEAD",
                    signature,
                    signature,
                    nil,
                    text,
                    treeObject,
                    parentCount,
                    buffer.baseAddress
                ),
                String(localized: "Could not commit")
            )
        }
    }

    private struct MergeAnalysis {
        var upToDate = false
        var fastForward = false
        var normal = false
    }

    private static func mergeAnalysis(_ repo: OpaquePointer, annotated: OpaquePointer?) throws -> MergeAnalysis {
        var analysis = git_merge_analysis_t(0)
        var preference = git_merge_preference_t(0)
        var annotated = annotated
        try check(
            git_merge_analysis(&analysis, &preference, repo, &annotated, 1),
            String(localized: "Could not pull")
        )
        return MergeAnalysis(
            upToDate: analysis.rawValue & GIT_MERGE_ANALYSIS_UP_TO_DATE.rawValue != 0,
            fastForward: analysis.rawValue & GIT_MERGE_ANALYSIS_FASTFORWARD.rawValue != 0,
            normal: analysis.rawValue & GIT_MERGE_ANALYSIS_NORMAL.rawValue != 0
        )
    }

    private static func fetchUpstream(
        _ repo: OpaquePointer,
        username: String,
        secret: String,
        sshKey: SSHKeyMaterial?,
        progress: GitProgressReporter = .init(handler: nil)
    ) throws -> OpaquePointer? {
        guard let configured = upstreamUnlocked(repo), configured.remote != "." else {
            throw GitFailure.message(String(localized: "This branch has no upstream. Push it first."))
        }
        var remote: OpaquePointer?
        if git_remote_lookup(&remote, repo, configured.remote) < 0 {
            throw GitFailure.message(String(localized: "This repository has no origin remote."))
        }
        defer { git_remote_free(remote) }
        let box = CredentialBox(username: username, secret: secret, sshKey: sshKey, progress: progress)
            defer { withExtendedLifetime(box) {} }
        var fetch = git_fetch_options()
        try check(git_fetch_options_init(&fetch, UInt32(GIT_FETCH_OPTIONS_VERSION)), String(localized: "Could not pull"))
        applyTransport(&fetch.callbacks, box: box)
        progress.report(.connecting)
        try check(git_remote_fetch(remote, nil, &fetch, "pull"), String(localized: "Could not pull"))

        var head: OpaquePointer?
        try check(git_repository_head(&head, repo), String(localized: "Could not pull"))
        defer { git_reference_free(head) }
        var upstream: OpaquePointer?
        let upstreamCode = git_branch_upstream(&upstream, head)
        if upstreamCode < 0 {
            throw GitFailure.message(String(localized: "This branch has no upstream. Push it first."))
        }
        return upstream
    }

    private static func fastForward(_ repo: OpaquePointer, to upstream: OpaquePointer?, progress: GitProgressReporter = .init(handler: nil)) throws {
        var resolved: OpaquePointer?
        try check(git_reference_resolve(&resolved, upstream), String(localized: "Could not pull"))
        defer { git_reference_free(resolved) }
        guard let target = git_reference_target(resolved) else {
            throw GitFailure.message(String(localized: "Could not pull"))
        }
        var oid = target.pointee
        var object: OpaquePointer?
        try check(git_object_lookup(&object, repo, &oid, GIT_OBJECT_COMMIT), String(localized: "Could not pull"))
        defer { git_object_free(object) }
        var checkout = git_checkout_options()
        try check(
            git_checkout_options_init(&checkout, UInt32(GIT_CHECKOUT_OPTIONS_VERSION)),
            String(localized: "Could not pull")
        )
        checkout.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue
        let progressBox = GitTransportProgressBox(progress: progress)
        defer { withExtendedLifetime(progressBox) {} }
        applyCheckoutProgress(&checkout, box: progressBox)
        progress.report(.checkingOut)
        try check(git_checkout_tree(repo, object, &checkout), String(localized: "Could not pull"))
        var head: OpaquePointer?
        try check(git_repository_head(&head, repo), String(localized: "Could not pull"))
        defer { git_reference_free(head) }
        var updated: OpaquePointer?
        try check(
            git_reference_set_target(&updated, head, &oid, "pull: fast-forward"),
            String(localized: "Could not pull")
        )
        git_reference_free(updated)
    }

    private static func merge(
        _ repo: OpaquePointer,
        annotated: OpaquePointer?,
        name: String,
        email: String,
        progress: GitProgressReporter = .init(handler: nil)
    ) throws {
        try beginOperation(repo, kind: .merge, target: oidString(git_annotated_commit_id(annotated)))
        var annotated = annotated
        var mergeOptions = git_merge_options()
        try check(git_merge_options_init(&mergeOptions, UInt32(GIT_MERGE_OPTIONS_VERSION)), String(localized: "Could not pull"))
        var checkout = git_checkout_options()
        try check(git_checkout_options_init(&checkout, UInt32(GIT_CHECKOUT_OPTIONS_VERSION)), String(localized: "Could not pull"))
        checkout.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue | GIT_CHECKOUT_DONT_OVERWRITE_IGNORED.rawValue
        let progressBox = GitTransportProgressBox(progress: progress)
        defer { withExtendedLifetime(progressBox) {} }
        applyCheckoutProgress(&checkout, box: progressBox)
        progress.report(.merging)
        let code = git_merge(repo, &annotated, 1, &mergeOptions, &checkout)
        if indexHasConflicts(repo) { return }
        try check(code, String(localized: "Could not pull"))
        try finishOperationCommit(repo, name: name, email: email)
    }

    private static func conflictMessage(_ summary: String, paths: [String]) -> String {
        guard !paths.isEmpty else { return summary }
        return summary + "\n" + paths.joined(separator: "\n")
    }

    private static func conflictPaths(_ repo: OpaquePointer) -> [String] {
        var index: OpaquePointer?
        guard git_repository_index(&index, repo) == 0, let index else { return [] }
        defer { git_index_free(index) }
        var iterator: OpaquePointer?
        guard git_index_conflict_iterator_new(&iterator, index) == 0 else { return [] }
        defer { git_index_conflict_iterator_free(iterator) }
        var paths: [String] = []
        while true {
            var ancestor: UnsafePointer<git_index_entry>?
            var ours: UnsafePointer<git_index_entry>?
            var theirs: UnsafePointer<git_index_entry>?
            let code = git_index_conflict_next(&ancestor, &ours, &theirs, iterator)
            if matches(code, GIT_ITEROVER) { break }
            if code < 0 { break }
            let entry = ours ?? theirs ?? ancestor
            if let path = entry?.pointee.path {
                paths.append(String(cString: path))
            }
        }
        return paths
    }

    private static func indexHasConflicts(_ repo: OpaquePointer) -> Bool {
        var index: OpaquePointer?
        guard git_repository_index(&index, repo) == 0, let index else { return false }
        defer { git_index_free(index) }
        return git_index_has_conflicts(index) != 0
    }

    private static func currentBranch(_ repo: OpaquePointer) throws -> String {
        var head: OpaquePointer?
        let code = git_repository_head(&head, repo)
        if matches(code, GIT_EUNBORNBRANCH) {
            throw GitFailure.message(String(localized: "No commits yet"))
        }
        try check(code, String(localized: "Could not open repository"))
        defer { git_reference_free(head) }
        guard let name = git_reference_shorthand(head) else {
            throw GitFailure.message(String(localized: "Could not open repository"))
        }
        return String(cString: name)
    }

    private static func applyTransport(_ callbacks: inout git_remote_callbacks, box: CredentialBox) {
        applyTransferProgress(&callbacks, reporter: box.progress)
        callbacks.credentials = acquireCredentials
        callbacks.certificate_check = checkServerCertificate
        callbacks.push_update_reference = { _, status, payload in
            if let status, let payload {
                Unmanaged<CredentialBox>.fromOpaque(payload).takeUnretainedValue().pushError = String(cString: status)
            }
            return 0
        }
        callbacks.payload = Unmanaged.passUnretained(box).toOpaque()
    }

    private static func applyTransferProgress(_ callbacks: inout git_remote_callbacks, reporter: GitProgressReporter) {
        guard reporter.handler != nil else { return }
        callbacks.transfer_progress = { stats, payload in
            guard let stats, let payload else { return 0 }
            let progress = Unmanaged<GitTransportProgressBox>.fromOpaque(payload).takeUnretainedValue().progress
            let s = stats.pointee
            if s.received_objects == s.total_objects, s.total_deltas > 0 {
                progress.report(.resolving, completed: Int(s.indexed_deltas), total: Int(s.total_deltas), bytes: s.received_bytes)
            } else if s.received_objects == s.total_objects, s.indexed_objects < s.total_objects {
                progress.report(.indexing, completed: Int(s.indexed_objects), total: Int(s.total_objects), bytes: s.received_bytes)
            } else {
                progress.report(.receiving, completed: Int(s.received_objects), total: Int(s.total_objects), bytes: s.received_bytes)
            }
            return 0
        }
        callbacks.pack_progress = { _, current, total, payload in
            guard let payload else { return 0 }
            Unmanaged<GitTransportProgressBox>.fromOpaque(payload).takeUnretainedValue().progress
                .report(.packing, completed: Int(current), total: Int(total))
            return 0
        }
        callbacks.push_transfer_progress = { current, total, bytes, payload in
            guard let payload else { return 0 }
            Unmanaged<GitTransportProgressBox>.fromOpaque(payload).takeUnretainedValue().progress
                .report(total > 0 && current >= total ? .waitingForRemote : .sending,
                        completed: Int(current), total: current >= total ? 0 : Int(total), bytes: bytes)
            return 0
        }
    }

    private static func applyCheckoutProgress(_ options: inout git_checkout_options, box: GitTransportProgressBox) {
        guard box.progress.handler != nil else { return }
        options.progress_payload = Unmanaged.passUnretained(box).toOpaque()
        options.progress_cb = { _, completed, total, payload in
            guard let payload else { return }
            Unmanaged<GitTransportProgressBox>.fromOpaque(payload).takeUnretainedValue().progress
                .report(.checkingOut, completed: completed, total: total)
        }
    }

    private static func withRefspec(_ spec: String, _ body: (UnsafePointer<git_strarray>) throws -> Void) throws {
        let copy = strdup(spec)
        defer { free(copy) }
        var string = copy
        try withUnsafeMutablePointer(to: &string) { strings in
            var array = git_strarray(strings: strings, count: 1)
            try withUnsafePointer(to: &array) { pointer in
                try body(pointer)
            }
        }
    }

    private static func format(_ oid: git_oid) -> String {
        var oid = oid
        var bytes = [CChar](repeating: 0, count: 41)
        git_oid_tostr(&bytes, bytes.count, &oid)
        return String(cString: bytes)
    }

    private static func matches(_ code: Int32, _ expected: git_error_code) -> Bool {
        code == expected.rawValue
    }

    private static func check(_ code: Int32, _ context: String) throws {
        guard code < 0 else { return }
        let detail: String
        if let error = git_error_last(), let message = error.pointee.message {
            detail = String(cString: message)
        } else {
            detail = String(localized: "Unknown Git error")
        }
        throw GitFailure.message("\(context): \(detail)")
    }
}


struct StashEntry: Identifiable, Equatable {
    var index: Int
    var oid: String
    var message: String
    var id: String { "\(index):\(oid)" }
}

private final class StashListBox { var entries: [StashEntry] = [] }

extension GitClient {
    private static func requireFilePath(_ path: String) throws {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, !path.contains("\0"), parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0 != ".git" }) else {
            throw WorkingTreeError.outside
        }
    }

    static func stage(at repoURL: URL, path: String, originalPath: String? = nil, lfsAuth: LFSAuth? = nil) throws {
        try requireFilePath(path)
        if let originalPath { try requireFilePath(originalPath) }
        try writing(repoURL) {
            try locked {
                let opened = try open(repoURL)
                defer { withExtendedLifetime(opened) {} }
                let repo = opened.repo
                guard try !conflicts(repo).contains(where: { $0.path == path || $0.path == originalPath }) else { throw GitFailure.message(operationError) }
                var index: OpaquePointer?
                try check(git_repository_index(&index, repo), String(localized: "Could not stage files"))
                defer { git_index_free(index) }
                let root = try workDirectory(repo)
                for item in Set([path, originalPath].compactMap { $0 }) {
                    let file = root.appendingPathComponent(item)
                    var info = stat()
                    if file.path.withCString({ lstat($0, &info) }) == 0 {
                        try check(git_index_add_bypath(index, item), String(localized: "Could not stage files"))
                    } else if errno == ENOENT {
                        let removed = git_index_remove_bypath(index, item)
                        if !matches(removed, GIT_ENOTFOUND) { try check(removed, String(localized: "Could not stage files")) }
                    } else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                }
                try applyLFSClean(repo: repo, index: index!, auth: lfsAuth, paths: [path])
                try check(git_index_write(index), String(localized: "Could not stage files"))
            }
        }
    }

    static func unstage(at repoURL: URL, path: String, originalPath: String? = nil) throws {
        try requireFilePath(path)
        if let originalPath { try requireFilePath(originalPath) }
        try writing(repoURL) {
            try locked {
                let opened = try open(repoURL)
                defer { withExtendedLifetime(opened) {} }
                let tree = try headTree(opened.repo)
                defer { git_tree_free(tree) }
                var index: OpaquePointer?
                try check(git_repository_index(&index, opened.repo), String(localized: "Could not unstage files"))
                defer { git_index_free(index) }
                // Restore only literal paths from HEAD, avoiding wildcard pathspecs.
                for item in Set([path, originalPath].compactMap { $0 }) {
                    var entry: OpaquePointer?
                    let lookup = tree.map { git_tree_entry_bypath(&entry, $0, item) } ?? GIT_ENOTFOUND.rawValue
                    defer { git_tree_entry_free(entry) }
                    if matches(lookup, GIT_ENOTFOUND) {
                        let removed = git_index_remove_bypath(index, item)
                        if !matches(removed, GIT_ENOTFOUND) { try check(removed, String(localized: "Could not unstage files")) }
                    } else {
                        try check(lookup, String(localized: "Could not unstage files"))
                        try item.withCString { path in
                            var restored = git_index_entry()
                            restored.path = path
                            restored.mode = UInt32(git_tree_entry_filemode(entry).rawValue)
                            restored.id = git_tree_entry_id(entry).pointee
                            try check(git_index_add(index, &restored), String(localized: "Could not unstage files"))
                        }
                    }
                }
                try check(git_index_write(index), String(localized: "Could not unstage files"))
            }
        }
    }

    static func isValidBranchName(_ name: String) -> Bool {
        var valid: Int32 = 0
        return !name.isEmpty && git_branch_name_is_valid(&valid, name) == 0 && valid != 0
    }

    static func renameBranch(at repoURL: URL, branch: String, to name: String) throws {
        guard isValidBranchName(name) else { throw GitFailure.message(String(localized: "Enter a valid branch name.")) }
        try writing(repoURL) {
            try locked {
                let opened = try open(repoURL)
                defer { withExtendedLifetime(opened) {} }
                try requireNoOperation(opened.repo)
                var ref: OpaquePointer?
                try check(git_branch_lookup(&ref, opened.repo, branch, GIT_BRANCH_LOCAL), String(localized: "Could not update branch."))
                defer { git_reference_free(ref) }
                var renamed: OpaquePointer?
                try check(git_branch_move(&renamed, ref, name, 0), String(localized: "Could not update branch."))
                git_reference_free(renamed)
            }
        }
    }

    static func deleteBranch(at repoURL: URL, branch: String) throws {
        try writing(repoURL) {
            try locked {
                let opened = try open(repoURL)
                defer { withExtendedLifetime(opened) {} }
                let repo = opened.repo
                try requireNoOperation(repo)
                var ref: OpaquePointer?
                try check(git_branch_lookup(&ref, repo, branch, GIT_BRANCH_LOCAL), String(localized: "Could not update branch."))
                defer { git_reference_free(ref) }
                guard git_branch_is_head(ref) == 0 else { throw GitFailure.message(String(localized: "Cannot delete the current branch.")) }
                var head: OpaquePointer?
                try check(git_repository_head(&head, repo), String(localized: "Could not update branch."))
                defer { git_reference_free(head) }
                guard let current = git_reference_target(head), let target = git_reference_target(ref) else {
                    throw GitFailure.message(String(localized: "Could not update branch."))
                }
                guard git_oid_cmp(current, target) == 0 || git_graph_descendant_of(repo, current, target) == 1 else {
                    throw GitFailure.message(String(localized: "This branch has unmerged commits."))
                }
                try check(git_branch_delete(ref), String(localized: "Could not update branch."))
            }
        }
    }

    static func setUpstream(at repoURL: URL, branch: String, upstream: String?) throws {
        try writing(repoURL) {
            try locked {
                let opened = try open(repoURL)
                defer { withExtendedLifetime(opened) {} }
                var ref: OpaquePointer?
                try check(git_branch_lookup(&ref, opened.repo, branch, GIT_BRANCH_LOCAL), String(localized: "Could not update branch."))
                defer { git_reference_free(ref) }
                try check(git_branch_set_upstream(ref, upstream), String(localized: "Could not update branch."))
            }
        }
    }

    private static func stashesUnlocked(_ repo: OpaquePointer) throws -> [StashEntry] {
        let box = StashListBox()
        try check(git_stash_foreach(repo, { index, message, oid, payload in
            guard let payload, let oid else { return -1 }
            let box = Unmanaged<StashListBox>.fromOpaque(payload).takeUnretainedValue()
            box.entries.append(StashEntry(index: index, oid: GitClient.format(oid.pointee), message: message.map { String(cString: $0) } ?? ""))
            return 0
        }, Unmanaged.passUnretained(box).toOpaque()), String(localized: "Could not read stashes."))
        return box.entries
    }

    static func stashes(at repoURL: URL) throws -> [StashEntry] {
        try locked {
            let opened = try open(repoURL)
            defer { withExtendedLifetime(opened) {} }
            return try stashesUnlocked(opened.repo)
        }
    }

    static func saveStash(at repoURL: URL, message: String, includeUntracked: Bool, name: String, email: String) throws {
        guard !name.isEmpty, !email.isEmpty else {
            throw GitFailure.message(String(localized: "Set your name and email in Settings before committing."))
        }
        try writing(repoURL) {
            try locked {
                let opened = try open(repoURL)
                defer { withExtendedLifetime(opened) {} }
                try requireNoOperation(opened.repo)
                guard git_repository_state(opened.repo) == GIT_REPOSITORY_STATE_NONE.rawValue,
                      !indexHasConflicts(opened.repo) else { throw GitFailure.message(String(localized: "Resolve the current Git operation first.")) }
                var signature: UnsafeMutablePointer<git_signature>?
                try check(git_signature_now(&signature, name, email), String(localized: "Could not save stash."))
                defer { git_signature_free(signature) }
                var oid = git_oid()
                try check(git_stash_save(&oid, opened.repo, signature, message, includeUntracked ? GIT_STASH_INCLUDE_UNTRACKED.rawValue : 0), String(localized: "Could not save stash."))
            }
        }
    }

    static func applyStash(at repoURL: URL, oid: String, pop: Bool = false) throws {
        try writing(repoURL) {
            try locked {
                let opened = try open(repoURL)
                defer { withExtendedLifetime(opened) {} }
                try requireNoOperation(opened.repo)
                let repo = opened.repo
                guard git_repository_state(repo) == GIT_REPOSITORY_STATE_NONE.rawValue,
                      try statusUnlocked(repo).isEmpty else {
                    throw GitFailure.message(String(localized: "Commit or stash your changes before restoring a stash."))
                }
                guard let entry = try stashesUnlocked(repo).first(where: { $0.oid == oid }) else {
                    throw GitFailure.message(String(localized: "That stash no longer exists."))
                }
                var options = git_stash_apply_options()
                try check(git_stash_apply_options_init(&options, UInt32(GIT_STASH_APPLY_OPTIONS_VERSION)), String(localized: "Could not restore stash."))
                options.flags = GIT_STASH_APPLY_REINSTATE_INDEX.rawValue
                // Apply first; remove only on success, so a failed pop keeps the stash.
                try check(git_stash_apply(repo, entry.index, &options), String(localized: "Could not restore stash."))
                // libgit2 can return success with conflict stages in the index.
                // Keep both the stash and conflict contents for external resolution.
                if indexHasConflicts(repo) {
                    throw GitFailure.message(conflictMessage(
                        String(localized: "The stash has conflicts. The stash was kept. Resolve the files before staging."),
                        paths: conflictPaths(repo)
                    ))
                }
                if pop { try check(git_stash_drop(repo, entry.index), String(localized: "Could not remove stash.")) }
            }
        }
    }

    static func dropStash(at repoURL: URL, oid: String) throws {
        try writing(repoURL) {
            try locked {
                let opened = try open(repoURL)
                defer { withExtendedLifetime(opened) {} }
                guard let entry = try stashesUnlocked(opened.repo).first(where: { $0.oid == oid }) else {
                    throw GitFailure.message(String(localized: "That stash no longer exists."))
                }
                try check(git_stash_drop(opened.repo, entry.index), String(localized: "Could not remove stash."))
            }
        }
    }

    private struct Upstream {
        var remote: String
        var branch: String
        var shorthand: String
    }

    private static func upstreamUnlocked(_ repo: OpaquePointer, branch requestedBranch: String? = nil) -> Upstream? {
        guard let branch = requestedBranch ?? (try? currentBranch(repo)) else { return nil }
        let ref = "refs/heads/\(branch)"
        var remote = git_buf()
        var merge = git_buf()
        defer { git_buf_dispose(&remote); git_buf_dispose(&merge) }
        guard git_branch_upstream_remote(&remote, repo, ref) == 0,
              git_branch_upstream_merge(&merge, repo, ref) == 0,
              let remoteName = remote.ptr, let mergeName = merge.ptr else { return nil }
        let remoteString = String(cString: remoteName)
        let fullBranch = String(cString: mergeName)
        guard fullBranch.hasPrefix("refs/heads/") else { return nil }
        let shortBranch = String(fullBranch.dropFirst("refs/heads/".count))
        return Upstream(remote: remoteString, branch: shortBranch,
                        shorthand: remoteString == "." ? shortBranch : "\(remoteString)/\(shortBranch)")
    }

    static func upstream(at repoURL: URL, branch: String) throws -> String? {
        try locked {
            let opened = try open(repoURL)
            defer { withExtendedLifetime(opened) {} }
            return upstreamUnlocked(opened.repo, branch: branch)?.shorthand
        }
    }

    private static func syncRemote(_ repo: OpaquePointer, requested: String? = nil) throws -> String {
        if let requested, !requested.isEmpty { return requested }
        if let upstream = upstreamUnlocked(repo), upstream.remote != "." { return upstream.remote }
        let remotes = try remotesUnlocked(repo)
        if remotes.contains(where: { $0.name == "origin" }) { return "origin" }
        if remotes.count == 1 { return remotes[0].name }
        throw GitFailure.message(String(localized: "Select a remote for this operation."))
    }

    private static func syncURLUnlocked(_ repo: OpaquePointer, remoteName: String? = nil, push: Bool = false) throws -> String {
        let name = try syncRemote(repo, requested: remoteName)
        var remote: OpaquePointer?
        try check(git_remote_lookup(&remote, repo, name), String(localized: "Could not read remotes."))
        defer { git_remote_free(remote) }
        let configuredURL = push ? (git_remote_pushurl(remote) ?? git_remote_url(remote)) : git_remote_url(remote)
        guard let url = configuredURL else { throw GitFailure.message(String(localized: "Could not read remotes.")) }
        return String(cString: url)
    }

    static func transportURL(at repoURL: URL, remoteName: String? = nil, push: Bool = false) throws -> String {
        try locked {
            let opened = try open(repoURL)
            defer { withExtendedLifetime(opened) {} }
            return try syncURLUnlocked(opened.repo, remoteName: remoteName, push: push)
        }
    }
}

private class GitTransportProgressBox {
    let progress: GitProgressReporter
    init(progress: GitProgressReporter) { self.progress = progress }
}

private final class CredentialBox: GitTransportProgressBox {
    let username: String
    let secret: String
    let sshKey: SSHKeyMaterial?
    var pushError: String?

    init(username: String, secret: String, sshKey: SSHKeyMaterial? = nil, progress: GitProgressReporter = .init(handler: nil)) {
        self.username = username
        self.secret = secret
        self.sshKey = sshKey
        super.init(progress: progress)
    }
}

private let acquireCredentials: git_credential_acquire_cb = { credential, _, usernameFromURL, allowedTypes, payload in
    guard let credential, let payload else { return -1 }
    let box = Unmanaged<CredentialBox>.fromOpaque(payload).takeUnretainedValue()
    box.progress.report(.authenticating)
    let usernameFromURL = usernameFromURL.map { String(cString: $0) } ?? ""
    let user = box.username.isEmpty ? usernameFromURL : box.username

    if allowedTypes & UInt32(GIT_CREDENTIAL_USERNAME.rawValue) != 0,
       box.sshKey != nil,
       allowedTypes & UInt32(GIT_CREDENTIAL_SSH_KEY.rawValue) == 0 {
        return user.withCString { git_credential_username_new(credential, $0) }
    }

    if allowedTypes & UInt32(GIT_CREDENTIAL_SSH_KEY.rawValue) != 0,
       let key = box.sshKey {
        let sshUser = user.isEmpty ? "git" : user
        return sshUser.withCString { userPointer in
            key.privateKey.withCString { privatePointer in
                if let passphrase = key.passphrase, !passphrase.isEmpty {
                    return passphrase.withCString { passPointer in
                        git_credential_ssh_key_memory_new(
                            credential,
                            userPointer,
                            nil,
                            privatePointer,
                            passPointer
                        )
                    }
                }
                return git_credential_ssh_key_memory_new(
                    credential,
                    userPointer,
                    nil,
                    privatePointer,
                    nil
                )
            }
        }
    }

    if box.username.isEmpty && box.secret.isEmpty {
        return GIT_PASSTHROUGH.rawValue
    }
    return git_credential_userpass_plaintext_new(credential, user, box.secret)
}

private let checkServerCertificate: @convention(c) (
    UnsafeMutablePointer<git_cert>?,
    Int32,
    UnsafePointer<CChar>?,
    UnsafeMutableRawPointer?
) -> Int32 = { certificate, valid, host, _ in
    guard let certificate, let host else { return -1 }
    let hostname = String(cString: host)

    if certificate.pointee.cert_type == GIT_CERT_HOSTKEY_LIBSSH2 {
        let hostKey = UnsafeMutableRawPointer(certificate).assumingMemoryBound(to: git_cert_hostkey.self).pointee
        let digest: Data
        if hostKey.type.rawValue & UInt32(GIT_CERT_SSH_SHA256.rawValue) != 0 {
            digest = withUnsafeBytes(of: hostKey.hash_sha256) { Data($0) }
        } else if hostKey.type.rawValue & UInt32(GIT_CERT_SSH_RAW.rawValue) != 0,
                  let raw = hostKey.hostkey {
            digest = Data(SHA256.hash(data: Data(bytes: raw, count: hostKey.hostkey_len)))
        } else {
            return -1
        }
        return trustSSHHost(host: hostname, fingerprint: digest.base64EncodedString()) ? 0 : -1
    }

    if valid != 0 { return 0 }
    guard certificate.pointee.cert_type == GIT_CERT_X509 else { return -1 }
    let x509 = UnsafeMutableRawPointer(certificate).assumingMemoryBound(to: git_cert_x509.self)
    guard let bytes = x509.pointee.data else { return -1 }
    let data = Data(bytes: bytes, count: x509.pointee.len)
    guard let der = SecCertificateCreateWithData(nil, data as CFData) else { return -1 }
    var trust: SecTrust?
    let policy = SecPolicyCreateSSL(true, hostname as CFString)
    guard SecTrustCreateWithCertificates([der] as CFArray, policy, &trust) == errSecSuccess, let trust else {
        return -1
    }
    return SecTrustEvaluateWithError(trust, nil) ? 0 : -1
}

/// Trust on first use. A changed host key is rejected, which protects later
/// connections from a swapped key even though there is no prompt in the
/// synchronous libgit2 callback.
private let sshTrustLock = NSLock()
private func trustSSHHost(host: String, fingerprint: String) -> Bool {
    sshTrustLock.lock()
    defer { sshTrustLock.unlock() }
    let key = "gitling.knownHosts.v1"
    var known = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    if let existing = known[host] {
        return existing == fingerprint
    }
    known[host] = fingerprint
    UserDefaults.standard.set(known, forKey: key)
    return true
}

// MARK: - Recoverable Git operations
extension GitClient {
    private static var operationError: String { String(localized: "Resolve the current Git operation first.") }
    private static var changedConflict: String { String(localized: "The conflict or file changed. Refresh before trying again.") }

    private static func oidString(_ oid: UnsafePointer<git_oid>?) -> String { oid.map { format($0.pointee) } ?? "" }
    private static func journalURL(_ repo: OpaquePointer) -> URL { gitDirectory(repo).appendingPathComponent("gitling-operation.json") }
    private static func journal(_ repo: OpaquePointer) throws -> GitOperationJournal? {
        let file = journalURL(repo)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try JSONDecoder().decode(GitOperationJournal.self, from: Data(contentsOf: file))
    }
    private static func saveJournal(_ value: GitOperationJournal, repo: OpaquePointer) throws {
        try JSONEncoder().encode(value).write(to: journalURL(repo), options: .atomic)
    }
    private static func removeJournal(_ repo: OpaquePointer) throws {
        let file = journalURL(repo)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
    private static func nativeKind(_ repo: OpaquePointer) -> GitOperationKind? {
        switch UInt32(git_repository_state(repo)) {
        case GIT_REPOSITORY_STATE_MERGE.rawValue: return .merge
        case GIT_REPOSITORY_STATE_CHERRYPICK.rawValue: return .cherryPick
        case GIT_REPOSITORY_STATE_REBASE_MERGE.rawValue: return .rebase
        default: return nil
        }
    }
    private static func headIdentity(_ repo: OpaquePointer) throws -> (String, String) {
        var head: OpaquePointer?
        try check(git_repository_head(&head, repo), operationError)
        defer { git_reference_free(head) }
        guard let name = git_reference_name(head), let oid = git_reference_target(head) else { throw GitFailure.message(operationError) }
        return (String(cString: name), format(oid.pointee))
    }
    private static func requireNoOperation(_ repo: OpaquePointer, allowSubmodule: Bool = false) throws {
        guard git_repository_state(repo) == GIT_REPOSITORY_STATE_NONE.rawValue, try journal(repo) == nil else { throw GitFailure.message(operationError) }
        if !allowSubmodule, FileManager.default.fileExists(atPath: submoduleJournalURL(repo).path) {
            throw GitFailure.message(String(localized: "Resume or end the pending submodule update first."))
        }
    }
    private static func requireCleanOperationStart(_ repo: OpaquePointer) throws {
        try requireNoOperation(repo)
        guard try statusUnlocked(repo).isEmpty else { throw GitFailure.message(String(localized: "Commit or stash your changes before starting this operation.")) }
    }
    private static func beginOperation(_ repo: OpaquePointer, kind: GitOperationKind, target: String) throws {
        try requireCleanOperationStart(repo)
        let (reference, head) = try headIdentity(repo)
        guard reference != "HEAD" else { throw GitFailure.message(String(localized: "Check out a local branch before starting this operation.")) }
        try saveJournal(.init(kind: kind, originalHead: head, reference: reference, target: target), repo: repo)
    }
    private static func conflictVersion(_ entry: UnsafePointer<git_index_entry>?) -> ConflictVersion? {
        entry.map { .init(oid: format($0.pointee.id), mode: $0.pointee.mode) }
    }
    private static func conflicts(_ repo: OpaquePointer) throws -> [ConflictFile] {
        var index: OpaquePointer?
        try check(git_repository_index(&index, repo), operationError)
        defer { git_index_free(index) }
        var iterator: OpaquePointer?
        try check(git_index_conflict_iterator_new(&iterator, index), operationError)
        defer { git_index_conflict_iterator_free(iterator) }
        var paths = Set<String>()
        while true {
            var base: UnsafePointer<git_index_entry>?, ours: UnsafePointer<git_index_entry>?, theirs: UnsafePointer<git_index_entry>?
            let code = git_index_conflict_next(&base, &ours, &theirs, iterator)
            if matches(code, GIT_ITEROVER) { break }
            try check(code, operationError)
            for entry in [base, ours, theirs] { if let path = entry?.pointee.path { paths.insert(String(cString: path)) } }
        }
        return try paths.sorted().map { path in
            var base: UnsafePointer<git_index_entry>?, ours: UnsafePointer<git_index_entry>?, theirs: UnsafePointer<git_index_entry>?
            try check(git_index_conflict_get(&base, &ours, &theirs, index, path), operationError)
            return ConflictFile(path: path, ancestor: conflictVersion(base), ours: conflictVersion(ours), theirs: conflictVersion(theirs))
        }
    }
    static func operation(at repoURL: URL) throws -> GitOperationSnapshot {
        try locked {
            let opened = try open(repoURL)
            defer { withExtendedLifetime(opened) {} }
            let repo = opened.repo
            let saved = try journal(repo)
            let native = nativeKind(repo)
            var step: Int?, total: Int?
            if native == .rebase {
                var rebase: OpaquePointer?
                try check(git_rebase_open(&rebase, repo, nil), operationError)
                defer { git_rebase_free(rebase) }
                let current = git_rebase_operation_current(rebase)
                step = current < 0 ? 0 : current + 1
                total = git_rebase_operation_entrycount(rebase)
            }
            let files = try conflicts(repo)
            return GitOperationSnapshot(kind: native ?? saved?.kind, conflicts: files,
                canContinue: saved != nil && files.isEmpty && (native != nil || saved?.plannedCommit != nil || saved?.kind == .rebase),
                canAbort: saved != nil && saved?.plannedCommit == nil, isExternal: native != nil && saved == nil, step: step, total: total)
        }
    }
    static func conflictPreview(at repoURL: URL, version: ConflictVersion?) throws -> ConflictPreview {
        guard let version else { return .init(text: nil, byteCount: 0, oid: nil) }
        return try locked {
            let opened = try open(repoURL)
            defer { withExtendedLifetime(opened) {} }
            var oid = git_oid()
            try check(git_oid_fromstr(&oid, version.oid), operationError)
            var odb: OpaquePointer?
            try check(git_repository_odb(&odb, opened.repo), operationError)
            defer { git_odb_free(odb) }
            var size = 0
            var type = GIT_OBJECT_ANY
            try check(git_odb_read_header(&size, &type, odb, &oid), operationError)
            guard type == GIT_OBJECT_BLOB, size <= 256_000 else { return .init(text: nil, byteCount: size, oid: version.oid) }
            var blob: OpaquePointer?
            try check(git_blob_lookup(&blob, opened.repo, &oid), operationError)
            defer { git_blob_free(blob) }
            let data = git_blob_rawcontent(blob).map { Data(bytes: $0, count: size) } ?? Data()
            let text = git_blob_is_binary(blob) == 0 ? String(data: data, encoding: .utf8) : nil
            return .init(text: text.map { String($0.prefix(80_000)) }, byteCount: size, oid: version.oid)
        }
    }
    private static func conflictURL(_ repo: OpaquePointer, path: String, deleting: Bool = false) throws -> URL {
        try requireFilePath(path)
        let root = try workDirectory(repo).resolvingSymlinksInPath().standardizedFileURL
        let file = root.appendingPathComponent(path)
        // Never follow symlinks. Explicit deletion may unlink the leaf itself.
        var cursor = root
        for component in path.split(separator: "/") {
            cursor.appendPathComponent(String(component))
            if (try? cursor.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                if deleting, cursor.standardizedFileURL == file.standardizedFileURL { return file }
                throw WorkingTreeError.outside
            }
        }
        guard file.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else { throw WorkingTreeError.outside }
        return file
    }
    private static func currentConflict(_ expected: ConflictFile, repo: OpaquePointer) throws {
        guard try conflicts(repo).contains(expected) else { throw GitFailure.message(changedConflict) }
    }
    private static func editContents(_ file: URL) throws -> Data {
        guard let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 16 * 1024 * 1024 else {
            throw GitFailure.message(String(localized: "This file is too large for the edit round trip."))
        }
        return try Data(contentsOf: file)
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func readConflictEditFile(at file: URL) throws -> Data {
        var result: Result<Data, Error>?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: file, options: [], error: &coordinationError) { url in
            result = Result { try editContents(url) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw WorkingTreeError.notFound }
        return try result.get()
    }
    static func conflictWorkingPreview(at repoURL: URL, conflict: ConflictFile) throws -> ConflictPreview {
        try RepoWriteLock.withSharedLock(at: repoURL) {
            let (opened, file) = try locked {
                let opened = try open(repoURL)
                try currentConflict(conflict, repo: opened.repo)
                return (opened, try conflictURL(opened.repo, path: conflict.path))
            }
            defer { withExtendedLifetime(opened) {} }
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 256_000 else { return .init(text: nil, byteCount: size, oid: "") }
            let data = try readConflictEditFile(at: file)
            let text = data.contains(0) ? nil : String(data: data, encoding: .utf8)
            return .init(text: text.map { String($0.prefix(80_000)) }, byteCount: data.count, oid: "")
        }
    }
    static func conflictEdit(at repoURL: URL, conflict: ConflictFile) throws -> ConflictEdit {
        try RepoWriteLock.withSharedLock(at: repoURL) {
            let (opened, file) = try locked {
                let opened = try open(repoURL)
                try currentConflict(conflict, repo: opened.repo)
                return (opened, try conflictURL(opened.repo, path: conflict.path))
            }
            defer { withExtendedLifetime(opened) {} }
            let data = try readConflictEditFile(at: file)
            return .init(conflict: conflict, digest: digest(data), contents: data)
        }
    }
    static func importConflictEdit(at repoURL: URL, edit: ConflictEdit, contents: Data) throws {
        guard contents.count <= 16 * 1024 * 1024 else { throw GitFailure.message(String(localized: "This file is too large for the edit round trip.")) }
        try writing(repoURL) {
            let (opened, file) = try locked {
                let opened = try open(repoURL)
                try currentConflict(edit.conflict, repo: opened.repo)
                return (opened, try conflictURL(opened.repo, path: edit.conflict.path))
            }
            defer { withExtendedLifetime(opened) {} }
            var coordinationError: NSError?
            var writeError: Error?
            NSFileCoordinator().coordinate(writingItemAt: file, options: .forReplacing, error: &coordinationError) { url in
                do {
                    guard digest(try editContents(url)) == edit.digest else { throw GitFailure.message(changedConflict) }
                    let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
                    try contents.write(to: url, options: .atomic)
                    if let permissions { try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path) }
                } catch { writeError = error }
            }
            if let error = coordinationError ?? (writeError as NSError?) { throw error }
        }
    }
    static func resolveConflict(at repoURL: URL, conflict: ConflictFile, delete: Bool = false, lfsAuth: LFSAuth? = nil) throws {
        try writing(repoURL) {
            let (opened, file) = try locked {
                let opened = try open(repoURL)
                try currentConflict(conflict, repo: opened.repo)
                return (opened, try conflictURL(opened.repo, path: conflict.path, deleting: delete))
            }
            defer { withExtendedLifetime(opened) {} }
            var coordinationError: NSError?
            var resolutionError: Error?
            NSFileCoordinator().coordinate(writingItemAt: file, options: delete ? .forDeleting : .forMerging, error: &coordinationError) { _ in
                do {
                    try locked {
                        let repo = opened.repo
                        try currentConflict(conflict, repo: repo)
                        _ = try conflictURL(repo, path: conflict.path, deleting: delete)
                        var index: OpaquePointer?
                        try check(git_repository_index(&index, repo), operationError)
                        defer { git_index_free(index) }
                        if delete {
                            let values = try? file.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                            guard values?.isDirectory != true || values?.isSymbolicLink == true else { throw GitFailure.message(directoryConflictError) }
                            if FileManager.default.fileExists(atPath: file.path) || values?.isSymbolicLink == true { try FileManager.default.removeItem(at: file) }
                            let removed = git_index_remove_bypath(index, conflict.path)
                            if !matches(removed, GIT_ENOTFOUND) { try check(removed, operationError) }
                            let cleared = git_index_conflict_remove(index, conflict.path)
                            if !matches(cleared, GIT_ENOTFOUND) { try check(cleared, operationError) }
                        } else {
                            let data = try editContents(file)
                            if let text = String(data: data, encoding: .utf8), text.split(separator: "\n", omittingEmptySubsequences: false).contains(where: {
                                $0.hasPrefix("<<<<<<<") || $0.hasPrefix("=======") || $0.hasPrefix(">>>>>>>") || $0.hasPrefix("|||||||")
                            }) { throw GitFailure.message(String(localized: "Remove the conflict markers before confirming resolution.")) }
                            try check(git_index_add_bypath(index, conflict.path), operationError)
                            try applyLFSClean(repo: repo, index: index!, auth: lfsAuth, paths: [conflict.path])
                        }
                        try check(git_index_write(index), operationError)
                    }
                } catch { resolutionError = error }
            }
            if let error = coordinationError ?? (resolutionError as NSError?) { throw error }
        }
    }
    private static func requireResolvedIndex(_ repo: OpaquePointer) throws {
        guard !indexHasConflicts(repo) else { throw GitFailure.message(operationError) }
        guard try !statusUnlocked(repo).contains(where: { $0.unstaged && !$0.untracked }) else {
            throw GitFailure.message(String(localized: "Stage your edited resolutions before continuing."))
        }
    }
    private static func advanceRebase(_ repo: OpaquePointer, rebase: OpaquePointer?, signature: UnsafePointer<git_signature>?, commitCurrent: Bool) throws {
        func commitStep() throws {
            try requireResolvedIndex(repo)
            var oid = git_oid()
            let code = git_rebase_commit(&oid, rebase, nil, signature, nil, nil)
            if !matches(code, GIT_EAPPLIED) { try check(code, operationError) }
        }
        if commitCurrent, git_rebase_operation_current(rebase) >= 0 { try commitStep() }
        while true {
            var operation: UnsafeMutablePointer<git_rebase_operation>?
            let code = git_rebase_next(&operation, rebase)
            if matches(code, GIT_ITEROVER) { break }
            if indexHasConflicts(repo) { return }
            try check(code, operationError)
            try commitStep()
        }
        try check(git_rebase_finish(rebase, signature), operationError)
        try removeJournal(repo)
    }
    static func continueOperation(at repoURL: URL, name: String, email: String) throws {
        guard !name.isEmpty, !email.isEmpty else { throw GitFailure.message(String(localized: "Set your name and email in Settings before committing.")) }
        try writing(repoURL) {
            try locked {
                let opened = try open(repoURL)
                defer { withExtendedLifetime(opened) {} }
                let repo = opened.repo
                guard let saved = try journal(repo) else { throw GitFailure.message(operationError) }
                if let planned = saved.plannedCommit {
                    try publishOperationCommit(repo, saved: saved, planned: planned)
                    return
                }
                try requireResolvedIndex(repo)
                if nativeKind(repo) == .rebase {
                    var rebase: OpaquePointer?
                    try check(git_rebase_open(&rebase, repo, nil), operationError)
                    defer { git_rebase_free(rebase) }
                    try validateRebaseIdentity(repo, rebase: rebase, saved: saved)
                    var signature: UnsafeMutablePointer<git_signature>?
                    try check(git_signature_now(&signature, name, email), operationError)
                    defer { git_signature_free(signature) }
                    try advanceRebase(repo, rebase: rebase, signature: signature, commitCurrent: true)
                } else if nativeKind(repo) == saved.kind {
                    try finishOperationCommit(repo, name: name, email: email)
                } else if saved.kind == .rebase {
                    // Finish may have completed just before process termination.
                    let (reference, head) = try headIdentity(repo)
                    var headOID = git_oid(), targetOID = git_oid()
                    try check(git_oid_fromstr(&headOID, head), operationError)
                    try check(git_oid_fromstr(&targetOID, saved.target), operationError)
                    guard reference == saved.reference, head == saved.target || git_graph_descendant_of(repo, &headOID, &targetOID) == 1 else { throw GitFailure.message(operationError) }
                    try removeJournal(repo)
                } else { throw GitFailure.message(operationError) }
            }
        }
    }
    static func abortOperation(at repoURL: URL) throws {
        try writing(repoURL) {
            try locked {
                let opened = try open(repoURL)
                defer { withExtendedLifetime(opened) {} }
                let repo = opened.repo
                guard let saved = try journal(repo) else { throw GitFailure.message(operationError) }
                guard git_repository_state(repo) == GIT_REPOSITORY_STATE_NONE.rawValue || nativeKind(repo) == saved.kind else { throw GitFailure.message(operationError) }
                // A published result must never be reset by a delayed Abort tap.
                guard saved.plannedCommit == nil else { throw GitFailure.message(String(localized: "This operation has already committed. Continue to finish recovery.")) }
                try protectAbortDirectories(repo, original: saved.originalHead)
                if nativeKind(repo) == .rebase {
                    var rebase: OpaquePointer?
                    try check(git_rebase_open(&rebase, repo, nil), operationError)
                    defer { git_rebase_free(rebase) }
                    try validateRebaseIdentity(repo, rebase: rebase, saved: saved)
                    try check(git_rebase_abort(rebase), operationError)
                } else {
                    let (reference, head) = try headIdentity(repo)
                    guard reference == saved.reference, head == saved.originalHead else { throw GitFailure.message(changedConflict) }
                    var object: OpaquePointer?
                    try check(git_revparse_single(&object, repo, saved.originalHead), operationError)
                    defer { git_object_free(object) }
                    try check(git_reset(repo, object, GIT_RESET_HARD, nil), operationError)
                    try check(git_repository_state_cleanup(repo), operationError)
                }
                try removeJournal(repo)
            }
        }
    }
    private static var directoryConflictError: String { String(localized: "A file or directory blocks restoration. Move it aside before resolving or aborting.") }
    private static func protectAbortDirectories(_ repo: OpaquePointer, original: String) throws {
        var object: OpaquePointer?, tree: OpaquePointer?
        try check(git_revparse_single(&object, repo, original), operationError)
        defer { git_object_free(object) }
        try check(git_commit_tree(&tree, object), operationError)
        defer { git_tree_free(tree) }
        let root = try workDirectory(repo)
        var index: OpaquePointer?
        try check(git_repository_index(&index, repo), operationError)
        defer { git_index_free(index) }
        for offset in 0..<git_index_entrycount(index) {
            guard let entry = git_index_get_byindex(index, offset), let path = entry.pointee.path,
                  entry.pointee.mode != GIT_FILEMODE_COMMIT.rawValue else { continue }
            let relative = String(cString: path)
            try requireFilePath(relative)
            let values = try? root.appendingPathComponent(relative).resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory != true || values?.isSymbolicLink == true else { throw GitFailure.message(directoryConflictError) }
        }
        func visit(_ tree: OpaquePointer?, prefix: String) throws {
            for offset in 0..<git_tree_entrycount(tree) {
                guard let entry = git_tree_entry_byindex(tree, offset), let name = git_tree_entry_name(entry) else { continue }
                let path = prefix + String(cString: name)
                try requireFilePath(path)
                let file = root.appendingPathComponent(path)
                let values = try? file.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if git_tree_entry_type(entry) == GIT_OBJECT_TREE {
                    guard values?.isSymbolicLink != true else { throw WorkingTreeError.outside }
                    guard values == nil || values?.isDirectory == true else { throw GitFailure.message(directoryConflictError) }
                    var subtree: OpaquePointer?, oid = git_tree_entry_id(entry).pointee
                    try check(git_tree_lookup(&subtree, repo, &oid), operationError)
                    defer { git_tree_free(subtree) }
                    try visit(subtree, prefix: path + "/")
                } else if git_tree_entry_type(entry) == GIT_OBJECT_BLOB {
                    guard values?.isDirectory != true || values?.isSymbolicLink == true else { throw GitFailure.message(directoryConflictError) }
                }
            }
        }
        try visit(tree, prefix: "")
    }
    private static func validateRebaseIdentity(_ repo: OpaquePointer, rebase: OpaquePointer?, saved: GitOperationJournal) throws {
        guard saved.kind == .rebase,
              git_rebase_orig_head_name(rebase).map({ String(cString: $0) }) == saved.reference,
              oidString(git_rebase_orig_head_id(rebase)) == saved.originalHead else { throw GitFailure.message(changedConflict) }
        var reference: OpaquePointer?
        try check(git_reference_lookup(&reference, repo, saved.reference), operationError)
        defer { git_reference_free(reference) }
        guard oidString(git_reference_target(reference)) == saved.originalHead else { throw GitFailure.message(changedConflict) }
    }
    private static func finishOperationCommit(_ repo: OpaquePointer, name: String, email: String) throws {
        try requireResolvedIndex(repo)
        guard var saved = try journal(repo), saved.kind != .rebase else { throw GitFailure.message(operationError) }
        let (reference, head) = try headIdentity(repo)
        guard reference == saved.reference, head == saved.originalHead else { throw GitFailure.message(changedConflict) }
        var original: OpaquePointer?, target: OpaquePointer?, index: OpaquePointer?, tree: OpaquePointer?
        try check(git_revparse_single(&original, repo, saved.originalHead), operationError)
        defer { git_object_free(original) }
        try check(git_revparse_single(&target, repo, saved.target), operationError)
        defer { git_object_free(target) }
        try check(git_repository_index(&index, repo), operationError)
        defer { git_index_free(index) }
        var treeOID = git_oid()
        try check(git_index_write_tree(&treeOID, index), operationError)
        try check(git_tree_lookup(&tree, repo, &treeOID), operationError)
        defer { git_tree_free(tree) }
        var signature: UnsafeMutablePointer<git_signature>?
        try check(git_signature_now(&signature, name, email), operationError)
        defer { git_signature_free(signature) }
        let message = saved.kind == .merge ? "Merge \(saved.target)\n" : git_commit_message(target).map { String(cString: $0) } ?? "Cherry-pick\n"
        let author = saved.kind == .cherryPick ? git_commit_author(target) : UnsafePointer(signature)
        var parents: [OpaquePointer?] = saved.kind == .merge ? [original, target] : [original]
        var commitOID = git_oid()
        let count = parents.count
        try parents.withUnsafeMutableBufferPointer { buffer in
            try check(git_commit_create(&commitOID, repo, nil, author, signature, nil, message, tree, count, buffer.baseAddress), operationError)
        }
        saved.plannedCommit = format(commitOID)
        try saveJournal(saved, repo: repo)
        try publishOperationCommit(repo, saved: saved, planned: format(commitOID))
    }
    private static func publishOperationCommit(_ repo: OpaquePointer, saved: GitOperationJournal, planned: String) throws {
        let (reference, head) = try headIdentity(repo)
        guard reference == saved.reference, head == saved.originalHead || head == planned else { throw GitFailure.message(changedConflict) }
        if head != planned {
            var oid = git_oid(), old = git_oid()
            try check(git_oid_fromstr(&oid, planned), operationError)
            try check(git_oid_fromstr(&old, saved.originalHead), operationError)
            var updated: OpaquePointer?
            try check(git_reference_create_matching(&updated, repo, saved.reference, &oid, 1, &old, "Gitling: finish operation"), operationError)
            git_reference_free(updated)
        }
        try check(git_repository_state_cleanup(repo), operationError)
        try removeJournal(repo)
    }
}

extension GitClient {
    private static func openForFileRestore(_ url: URL) throws -> OpenRepo {
        let access = try WorktreeLink.beginForFileRestore(repoName: url.lastPathComponent)
        do { return try OpenRepo(path: url.path, access: access) }
        catch { access?.stop(); throw error }
    }

    private static func restoreIndexVersion(_ repo: OpaquePointer, path: String) throws -> ConflictVersion {
        try requireFilePath(path)
        try requireNoOperation(repo)
        guard !indexHasConflicts(repo) else { throw GitFailure.message(operationError) }
        var index: OpaquePointer?
        try check(git_repository_index(&index, repo), operationError)
        defer { git_index_free(index) }
        try check(git_index_read(index, 1), operationError)
        guard let entry = git_index_get_bypath(index, path, 0) else {
            throw GitFailure.message(String(localized: "This file has no staged version. Untracked files and staged deletions are not restored."))
        }
        let version = entry.pointee
        guard version.mode == 0o100644 || version.mode == 0o100755 else { throw RestoreFileAccess.unsupported }
        guard lfsIndexPointers(repo, paths: [path]).isEmpty else {
            throw GitFailure.message(String(localized: "This file uses Git LFS. Restore it with an LFS-aware tool to avoid replacing its contents with a pointer."))
        }
        return .init(oid: format(version.id), mode: version.mode)
    }

    static func prepareFileRestore(at repoURL: URL, path: String) throws -> FileRestorePlan {
        try RepoWriteLock.withSharedLock(at: repoURL) {
            try locked {
                let opened = try openForFileRestore(repoURL)
                defer { withExtendedLifetime(opened) {} }
                let version = try restoreIndexVersion(opened.repo, path: path)
                let root = try workDirectory(opened.repo).resolvingSymlinksInPath().standardizedFileURL
                let snapshot = try RestoreFileAccess.snapshot(root: root, path: path)
                return .init(path: path, root: root, indexOID: version.oid, indexMode: version.mode, snapshot: snapshot)
            }
        }
    }

    static func restoreFile(at repoURL: URL, plan: FileRestorePlan) throws {
        try writing(repoURL) {
            let opened = try locked { try openForFileRestore(repoURL) }
            defer { withExtendedLifetime(opened) {} }
            var result: Result<Void, Error>?
            var coordinationError: NSError?
            // File Provider/editor coordination must not wait with the global Git lock held.
            NSFileCoordinator().coordinate(writingItemAt: plan.root.appendingPathComponent(plan.path), options: .forReplacing, error: &coordinationError) { _ in
                result = Result {
                    try locked {
                        let root = try workDirectory(opened.repo).resolvingSymlinksInPath().standardizedFileURL
                        guard root == plan.root else { throw RestoreFileAccess.changed }
                        let version = try restoreIndexVersion(opened.repo, path: plan.path)
                        guard version.oid == plan.indexOID, version.mode == plan.indexMode else { throw RestoreFileAccess.changed }
                        var oid = git_oid()
                        try check(git_oid_fromstr(&oid, version.oid), operationError)
                        var blob: OpaquePointer?
                        try check(git_blob_lookup(&blob, opened.repo, &oid), operationError)
                        defer { git_blob_free(blob) }
                        // Some libgit2 binary fast paths leave the filtered buffer
                        // empty. Binary contents must be restored byte for byte.
                        if git_blob_is_binary(blob) != 0 {
                            try RestoreFileAccess.replace(plan: plan, bytes: git_blob_rawcontent(blob), count: Int(git_blob_rawsize(blob)))
                            return
                        }
                        var buffer = git_buf()
                        defer { git_buf_dispose(&buffer) }
                        var options = git_blob_filter_options()
                        try check(git_blob_filter_options_init(&options, UInt32(GIT_BLOB_FILTER_OPTIONS_VERSION)), operationError)
                        try check(git_blob_filter(&buffer, blob, plan.path, &options), operationError)
                        try RestoreFileAccess.replace(plan: plan, bytes: buffer.ptr.map { UnsafeRawPointer($0) }, count: buffer.size)
                    }
                }
            }
            if let coordinationError { throw coordinationError }
            guard let result else { throw WorkingTreeError.notFound }
            try result.get()
        }
    }
}

// MARK: - Submodules (one durable checkpoint per superproject)
private final class SubmoduleNames { var names: [String] = [] }
private final class SubmoduleTransportBox: GitTransportProgressBox {
    let expected: String
    let auth: SubmoduleAuth
    var attempts = 0
    var authenticationRejected = false
    init(expected: String, auth: SubmoduleAuth, progress: GitProgressReporter) {
        self.expected = expected; self.auth = auth
        super.init(progress: progress)
    }
}

extension GitClient {
    private static var submoduleFailure: String { String(localized: "Could not update submodules. Completed work and local Git data were kept. Retry after fixing the reported submodule.") }
    private static var submoduleAuthentication: String { String(localized: "The submodule remote rejected the sign-in. Enter the username and password for that server, then retry. Completed work and local Git data were kept.") }
    private static var changedSubmodules: GitFailure { .message(String(localized: "The parent index, submodule configuration, or working folder changed. End this update and review the new state before starting again.")) }
    private static var dirtySubmodules: GitFailure { .message(String(localized: "A submodule has local changes or an unfinished operation. Commit or stash them before updating. No force checkout is performed.")) }
    private static func submoduleJournalURL(_ repo: OpaquePointer) -> URL { gitDirectory(repo).appendingPathComponent("gitling-submodules.json") }
    private static func submoduleCheckpoint(_ repo: OpaquePointer) throws -> SubmoduleCheckpoint? {
        let url = submoduleJournalURL(repo)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let result = try JSONDecoder().decode(SubmoduleCheckpoint.self, from: Data(contentsOf: url))
        guard result.version == 1 else { throw changedSubmodules }
        return result
    }
    private static func saveSubmoduleCheckpoint(_ value: SubmoduleCheckpoint, repo: OpaquePointer) throws {
        try JSONEncoder().encode(value).write(to: submoduleJournalURL(repo), options: .atomic)
    }
    private static func submoduleNames(_ repo: OpaquePointer) throws -> [String] {
        let box = SubmoduleNames()
        try check(git_submodule_foreach(repo, { _, name, payload in
            guard let name, let payload else { return -1 }
            Unmanaged<SubmoduleNames>.fromOpaque(payload).takeUnretainedValue().names.append(String(cString: name))
            return 0
        }, Unmanaged.passUnretained(box).toOpaque()), submoduleFailure)
        return box.names.sorted()
    }
    private static func withSubmodule<T>(_ repo: OpaquePointer, name: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        try requireFilePath(name)
        guard !name.split(separator: "/").contains(where: { $0.lowercased() == ".git" }) else { throw WorkingTreeError.outside }
        var submodule: OpaquePointer?
        try check(git_submodule_lookup(&submodule, repo, name), submoduleFailure)
        guard let submodule else { throw WorkingTreeError.notFound }
        defer { git_submodule_free(submodule) }
        return try body(submodule)
    }
    private static func safeSubmodulePath(_ repo: OpaquePointer, path: String) throws -> URL {
        try requireFilePath(path)
        guard !path.split(separator: "/").contains(where: { $0.lowercased() == ".git" }) else { throw WorkingTreeError.outside }
        let root = try workDirectory(repo).resolvingSymlinksInPath().standardizedFileURL
        var cursor = root
        for part in path.split(separator: "/") {
            cursor.appendPathComponent(String(part))
            var info = stat()
            if cursor.path.withCString({ lstat($0, &info) }) == 0 {
                guard info.st_mode & S_IFMT == S_IFDIR else { throw WorkingTreeError.outside }
            } else if errno != ENOENT { throw WorkingTreeError.outside }
        }
        return cursor
    }
    private static func validateModulesFile(_ repo: OpaquePointer) throws {
        let file = try workDirectory(repo).appendingPathComponent(".gitmodules")
        var info = stat()
        if file.path.withCString({ lstat($0, &info) }) == 0 {
            guard info.st_mode & S_IFMT == S_IFREG else { throw WorkingTreeError.outside }
        } else if errno != ENOENT { throw WorkingTreeError.outside }
    }
    private static func resolvedSubmoduleURL(_ repo: OpaquePointer, submodule: OpaquePointer) throws -> String {
        guard let raw = git_submodule_url(submodule) else { throw WorkingTreeError.notFound }
        var buffer = git_buf()
        defer { git_buf_dispose(&buffer) }
        try check(git_submodule_resolve_url(&buffer, repo, raw), submoduleFailure)
        guard let ptr = buffer.ptr else { throw WorkingTreeError.notFound }
        let result = String(cString: ptr)
        if let url = URL(string: result), url.password != nil {
            throw GitFailure.message(String(localized: "Submodule URLs must not contain passwords. Configure credentials in Settings."))
        }
        guard GitRemoteURL.isSupported(result) || result.hasPrefix("/") || result.hasPrefix("file://") else { throw WorkingTreeError.outside }
        return result
    }
    private static func openSubmodule(_ parent: OpaquePointer, submodule: OpaquePointer, path: URL) throws -> OpaquePointer? {
        let metadataBase = gitDirectory(parent).standardizedFileURL
        let name = String(cString: git_submodule_name(submodule))
        let relative = String(cString: git_submodule_path(submodule))
        // Git uses the configured name; libgit2 also creates path-named
        // metadata directories. Accept those two literal locations only.
        for candidate in Set([name, relative]) {
            var cursor = metadataBase
            for part in ["modules"] + candidate.split(separator: "/").map(String.init) {
                cursor.appendPathComponent(part)
                if (try? cursor.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw WorkingTreeError.outside }
            }
        }
        var child: OpaquePointer?
        let code = git_submodule_open(&child, submodule)
        if code < 0 {
            // A failed clone can leave an empty metadata directory; it may be
            // retried, but an ordinary non-empty folder must never be adopted.
            var info = stat()
            if path.path.withCString({ lstat($0, &info) }) != 0 {
                guard errno == ENOENT else { throw WorkingTreeError.outside }
                return nil
            }
            let entries = try FileManager.default.contentsOfDirectory(atPath: path.path)
            guard entries.isEmpty else { throw WorkingTreeError.collision }
            return nil
        }
        guard let child else { throw WorkingTreeError.notFound }
        do {
            let actual = try workDirectory(child).resolvingSymlinksInPath().standardizedFileURL
            guard actual.path == path.standardizedFileURL.path else { throw WorkingTreeError.outside }
            let metadata = gitDirectory(child).resolvingSymlinksInPath().standardizedFileURL.path
            let moduleRoot = metadataBase.appendingPathComponent("modules")
            let allowed = [moduleRoot.appendingPathComponent(name).standardizedFileURL.path,
                           moduleRoot.appendingPathComponent(relative).standardizedFileURL.path,
                           path.appendingPathComponent(".git").path]
            guard allowed.contains(metadata) else { throw WorkingTreeError.outside }
            return child
        } catch { git_repository_free(child); throw error }
    }
    private static func regularSubmoduleDirty(_ repo: OpaquePointer) throws -> Bool {
        if git_repository_state(repo) != GIT_REPOSITORY_STATE_NONE.rawValue || indexHasConflicts(repo) { return true }
        if try journal(repo) != nil || FileManager.default.fileExists(atPath: submoduleJournalURL(repo).path) { return true }
        var options = git_status_options()
        try check(git_status_options_init(&options, UInt32(GIT_STATUS_OPTIONS_VERSION)), submoduleFailure)
        options.flags = GIT_STATUS_OPT_INCLUDE_UNTRACKED.rawValue | GIT_STATUS_OPT_RECURSE_UNTRACKED_DIRS.rawValue | GIT_STATUS_OPT_EXCLUDE_SUBMODULES.rawValue
        var list: OpaquePointer?
        try check(git_status_list_new(&list, repo, &options), submoduleFailure)
        defer { git_status_list_free(list) }
        return git_status_list_entrycount(list) != 0
    }
    private static func moduleConfigured(_ repo: OpaquePointer, name: String) -> Bool {
        var config: OpaquePointer?
        guard git_repository_config(&config, repo) == 0 else { return false }
        defer { git_config_free(config) }
        var value = git_buf()
        defer { git_buf_dispose(&value) }
        return git_config_get_string_buf(&value, config, "submodule." + name + ".url") == 0
    }
    private static func moduleHead(_ repo: OpaquePointer) -> String? {
        var head: OpaquePointer?
        guard git_repository_head(&head, repo) == 0 else { return nil }
        defer { git_reference_free(head) }
        return git_reference_target(head).map { format($0.pointee) }
    }
    private static func inspectSubmodules(_ repo: OpaquePointer, prefix: String, recursive: Bool, depth: Int,
                                          visited: inout Set<String>, items: inout [SubmoduleInfo], rejectDirty: Bool) throws {
        guard depth < 32, items.count < 4096 else { throw WorkingTreeError.outside }
        try validateModulesFile(repo)
        let identity = gitDirectory(repo).resolvingSymlinksInPath().path
        guard visited.insert(identity).inserted else { throw WorkingTreeError.outside }
        for name in try submoduleNames(repo) {
            do {
                try withSubmodule(repo, name: name) { submodule in
                    guard let raw = git_submodule_path(submodule) else { throw WorkingTreeError.notFound }
                    let relative = String(cString: raw), full = prefix + relative
                    let path = try safeSubmodulePath(repo, path: relative)
                    let url = try resolvedSubmoduleURL(repo, submodule: submodule)
                    let child = try openSubmodule(repo, submodule: submodule, path: path)
                    defer { git_repository_free(child) }
                    let dirty = try child.map { try regularSubmoduleDirty($0) } ?? false
                    if dirty && rejectDirty { throw GitFailure.message(full + ": " + dirtySubmodules.localizedDescription) }
                    items.append(.init(path: full, url: url, target: git_submodule_index_id(submodule).map { format($0.pointee) },
                                       head: child.flatMap { moduleHead($0) }, initialized: child != nil, configured: moduleConfigured(repo, name: name), dirty: dirty))
                    if recursive, let child {
                        try inspectSubmodules(child, prefix: full + "/", recursive: true, depth: depth + 1,
                                              visited: &visited, items: &items, rejectDirty: rejectDirty)
                    }
                }
            } catch {
                if rejectDirty { throw error }
                items.append(.init(path: prefix + name, url: "", target: nil, head: nil,
                                   initialized: false, configured: false, dirty: false, problem: error.localizedDescription))
            }
        }
    }

    static func submodules(at repoURL: URL, recursive: Bool = false) throws -> SubmoduleSnapshot {
        try RepoWriteLock.withSharedLock(at: repoURL) {
            let opened = try locked { try openForFileRestore(repoURL) }
            defer { withExtendedLifetime(opened) {} }
            let checkpoint = try submoduleCheckpoint(opened.repo)
            var visited = Set<String>(), items: [SubmoduleInfo] = []
            try inspectSubmodules(opened.repo, prefix: "", recursive: recursive || checkpoint?.recursive == true, depth: 0, visited: &visited, items: &items, rejectDirty: false)
            return .init(items: items, checkpoint: checkpoint)
        }
    }

    static func endSubmoduleUpdate(at repoURL: URL) throws {
        try writing(repoURL) {
            let opened = try locked { try openForFileRestore(repoURL) }
            defer { withExtendedLifetime(opened) {} }
            let file = submoduleJournalURL(opened.repo)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
    }

    static func updateSubmodules(at repoURL: URL, action: SubmoduleAction = .update, recursive: Bool = false,
                                 initializeMissing: Bool = true, resume: Bool = false, auth: SubmoduleAuth = .init(),
                                 progress: GitProgressHandler? = nil) throws {
        let reporter = GitProgressReporter(handler: progress)
        reporter.report(.checkingSubmodules)
        try writing(repoURL) {
            let opened = try locked { try openForFileRestore(repoURL) }
            defer { withExtendedLifetime(opened) {} }
            let repo = opened.repo
            try requireNoOperation(repo, allowSubmodule: true)
            guard !indexHasConflicts(repo) else { throw dirtySubmodules }
            let root = try workDirectory(repo).resolvingSymlinksInPath().path
            let index = digest(try Data(contentsOf: gitDirectory(repo).appendingPathComponent("index")))
            try validateModulesFile(repo)
            let modules = digest((try? Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent(".gitmodules"))) ?? Data())
            var checkpoint: SubmoduleCheckpoint
            if let saved = try submoduleCheckpoint(repo) {
                guard resume, saved.root == root, saved.index == index, saved.modules == modules else { throw changedSubmodules }
                checkpoint = saved
            } else {
                guard !resume else { throw changedSubmodules }
                checkpoint = .init(action: action, recursive: recursive, initializeMissing: initializeMissing, root: root, index: index, modules: modules)
            }
            // Inspect *all* existing descendants even for a non-recursive update:
            // checking out their parent must not remove a dirty nested worktree.
            if checkpoint.action == .update {
                var visited = Set<String>(), items: [SubmoduleInfo] = []
                try inspectSubmodules(repo, prefix: "", recursive: true, depth: 0, visited: &visited, items: &items, rejectDirty: true)
            }
            try saveSubmoduleCheckpoint(checkpoint, repo: repo)
            var visited = Set<String>()
            try runSubmodules(repo, journalRepo: repo, prefix: "", depth: 0, visited: &visited, checkpoint: &checkpoint, auth: auth, progress: reporter)
            try FileManager.default.removeItem(at: submoduleJournalURL(repo))
        }
    }

    private static func runSubmodules(_ repo: OpaquePointer, journalRepo: OpaquePointer, prefix: String, depth: Int,
                                      visited: inout Set<String>, checkpoint: inout SubmoduleCheckpoint, auth: SubmoduleAuth, progress: GitProgressReporter) throws {
        guard depth < 32, visited.count < 4096 else { throw WorkingTreeError.outside }
        try validateModulesFile(repo)
        guard visited.insert(gitDirectory(repo).resolvingSymlinksInPath().path).inserted else { throw WorkingTreeError.outside }
        for name in try submoduleNames(repo) {
            try withSubmodule(repo, name: name) { submodule in
                guard let raw = git_submodule_path(submodule) else { throw WorkingTreeError.notFound }
                let relative = String(cString: raw), full = prefix + relative
                let reporter = progress.scoped(to: full)
                reporter.report(.configuringSubmodule)
                let path = try safeSubmodulePath(repo, path: relative)
                let target = git_submodule_index_id(submodule).map { format($0.pointee) }
                guard let target else { throw changedSubmodules }
                let url = try resolvedSubmoduleURL(repo, submodule: submodule)
                if let expected = checkpoint.targets[full] {
                    guard expected == target, checkpoint.urls[full] == url else { throw changedSubmodules }
                } else { checkpoint.targets[full] = target; checkpoint.urls[full] = url }
                checkpoint.current = full
                try saveSubmoduleCheckpoint(checkpoint, repo: journalRepo)
                if checkpoint.completed.contains(full), checkpoint.action == .update {
                    let completed = try openSubmodule(repo, submodule: submodule, path: path)
                    defer { git_repository_free(completed) }
                    if completed != nil || checkpoint.initializeMissing {
                        guard completed.flatMap({ moduleHead($0) }) == target else { throw changedSubmodules }
                    }
                }
                if !checkpoint.completed.contains(full) {
                    let existing = try openSubmodule(repo, submodule: submodule, path: path)
                    defer { git_repository_free(existing) }
                    if let existing, try regularSubmoduleDirty(existing) { throw dirtySubmodules }
                    if checkpoint.action == .initialize {
                        try check(git_submodule_init(submodule, 0), submoduleFailure)
                    } else if existing != nil || checkpoint.initializeMissing {
                        // Preserve the previous checkout even if it was a detached
                        // local commit; ending a task never deletes this backup ref.
                        if let existing, let old = moduleHead(existing), old != target {
                            var oid = git_oid(), reference: OpaquePointer?
                            try check(git_oid_fromstr(&oid, old), submoduleFailure)
                            let backup = git_reference_create(&reference, existing, "refs/gitling/submodule-backups/" + checkpoint.id, &oid, 0, "Gitling submodule update backup")
                            if !matches(backup, GIT_EEXISTS) { try check(backup, submoduleFailure) }
                            git_reference_free(reference)
                        }
                        if existing == nil {
                            try check(git_submodule_init(submodule, 0), submoduleFailure)
                            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
                            _ = try safeSubmodulePath(repo, path: relative)
                        }
                        var options = git_submodule_update_options()
                        try check(git_submodule_update_options_init(&options, UInt32(GIT_SUBMODULE_UPDATE_OPTIONS_VERSION)), submoduleFailure)
                        options.checkout_opts.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue | GIT_CHECKOUT_DONT_OVERWRITE_IGNORED.rawValue
                        let expected = existing.flatMap { originURLUnlocked($0) } ?? url
                        let box = SubmoduleTransportBox(expected: expected, auth: auth, progress: reporter)
                        options.fetch_opts.callbacks.payload = Unmanaged.passUnretained(box).toOpaque()
                        options.fetch_opts.callbacks.certificate_check = checkServerCertificate
                        applyTransferProgress(&options.fetch_opts.callbacks, reporter: reporter)
                        applyCheckoutProgress(&options.checkout_opts, box: box)
                        options.fetch_opts.callbacks.credentials = { output, actual, user, allowed, payload in
                            guard let actual, let payload else { return -1 }
                            let box = Unmanaged<SubmoduleTransportBox>.fromOpaque(payload).takeUnretainedValue()
                            box.progress.report(.authenticating)
                            box.attempts += 1
                            guard box.attempts <= 4,
                                  let value = box.auth.credentials(for: String(cString: actual), expected: box.expected) else {
                                box.authenticationRejected = true
                                return GIT_EAUTH.rawValue
                            }
                            let credentials = CredentialBox(username: value.username, secret: value.secret, sshKey: value.sshKey)
                            let result = withExtendedLifetime(credentials) {
                                acquireCredentials(output, actual, user, allowed, Unmanaged.passUnretained(credentials).toOpaque())
                            }
                            if result < 0 {
                                box.authenticationRejected = true
                                return GIT_EAUTH.rawValue
                            }
                            return result
                        }
                        reporter.report(.connecting)
                        let code = git_submodule_update(submodule, checkpoint.initializeMissing ? 1 : 0, &options)
                        withExtendedLifetime(box) {}
                        guard code == 0 else {
                            // Do not include transport diagnostics: a remote URL can contain secrets.
                            let message = code == GIT_EAUTH.rawValue || box.authenticationRejected ? submoduleAuthentication : submoduleFailure
                            throw GitFailure.message(full + ": " + message)
                        }
                    }
                    checkpoint.completed.append(full)
                    try saveSubmoduleCheckpoint(checkpoint, repo: journalRepo)
                }
                if checkpoint.recursive, let child = try openSubmodule(repo, submodule: submodule, path: path) {
                    defer { git_repository_free(child) }
                    if checkpoint.action == .update, moduleHead(child) != target { throw changedSubmodules }
                    try runSubmodules(child, journalRepo: journalRepo, prefix: full + "/", depth: depth + 1,
                                      visited: &visited, checkpoint: &checkpoint, auth: auth, progress: progress)
                }
            }
        }
    }
}

// MARK: - Tags
extension GitClient {
    private static var tagError: String { String(localized: "Could not read that tag.") }
    private static func tagReference(_ repo: OpaquePointer, name: String) throws -> OpaquePointer {
        let full = "refs/tags/" + name
        var valid: Int32 = 0
        guard !name.isEmpty, !name.contains("\0"), git_reference_name_is_valid(&valid, full) == 0, valid == 1 else { throw GitFailure.message(tagError) }
        var reference: OpaquePointer?
        try check(git_reference_lookup(&reference, repo, full), tagError)
        guard let reference, git_reference_type(reference) == GIT_REFERENCE_DIRECT else {
            git_reference_free(reference)
            throw GitFailure.message(tagError)
        }
        return reference
    }

    static func tags(at repoURL: URL) throws -> [TagInfo] {
        try locked {
            let opened = try open(repoURL)
            defer { withExtendedLifetime(opened) {} }
            var iterator: OpaquePointer?, database: OpaquePointer?
            try check(git_reference_iterator_glob_new(&iterator, opened.repo, "refs/tags/*"), tagError)
            defer { git_reference_iterator_free(iterator) }
            try check(git_repository_odb(&database, opened.repo), tagError)
            defer { git_odb_free(database) }
            var result: [TagInfo] = []
            while true {
                var reference: OpaquePointer?
                let code = git_reference_next(&reference, iterator)
                if matches(code, GIT_ITEROVER) { break }
                try check(code, tagError)
                defer { git_reference_free(reference) }
                guard let raw = git_reference_name(reference) else { continue }
                let name = String(cString: raw).dropFirst("refs/tags/".count)
                guard let target = git_reference_target(reference) else {
                    result.append(.init(name: String(name), referenceOID: "", annotated: false, problem: tagError))
                    continue
                }
                var type = GIT_OBJECT_INVALID, size = 0, oid = target.pointee
                let read = git_odb_read_header(&size, &type, database, &oid)
                result.append(.init(name: String(name), referenceOID: format(oid), annotated: type == GIT_OBJECT_TAG,
                                    problem: read < 0 ? String(localized: "The tag object is unavailable.") : nil))
            }
            return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    private static func tagDetailUnlocked(_ repo: OpaquePointer, name: String) throws -> TagDetail {
        let reference = try tagReference(repo, name: name)
        defer { git_reference_free(reference) }
        var oid = git_reference_target(reference)!.pointee
        let referenceOID = format(oid)
        var database: OpaquePointer?
        try check(git_repository_odb(&database, repo), tagError)
        defer { git_odb_free(database) }
        var annotated = false, tagger: String?, date: Date?, message: String?
        for depth in 0..<32 {
            var type = GIT_OBJECT_INVALID, size = 0
            try check(git_odb_read_header(&size, &type, database, &oid), tagError)
            if type == GIT_OBJECT_TAG {
                guard size <= 1_048_576 else { throw GitFailure.message(String(localized: "The tag metadata is too large to display safely.")) }
                var tag: OpaquePointer?
                try check(git_tag_lookup(&tag, repo, &oid), tagError)
                defer { git_tag_free(tag) }
                if depth == 0 {
                    annotated = true
                    message = git_tag_message(tag).map { String(String(cString: $0).prefix(64_000)) }
                    if let author = git_tag_tagger(tag) {
                        tagger = String(cString: author.pointee.name) + " <" + String(cString: author.pointee.email) + ">"
                        date = Date(timeIntervalSince1970: Double(author.pointee.when.time))
                    }
                }
                guard let target = git_tag_target_id(tag) else { throw GitFailure.message(tagError) }
                oid = target.pointee
                continue
            }
            var commitInfo: CommitInfo?
            if type == GIT_OBJECT_COMMIT {
                guard size <= 1_048_576 else { throw GitFailure.message(String(localized: "The tag metadata is too large to display safely.")) }
                var commit: OpaquePointer?
                try check(git_commit_lookup(&commit, repo, &oid), tagError)
                defer { git_commit_free(commit) }
                let author = git_commit_author(commit)
                commitInfo = .init(id: format(oid), summary: git_commit_summary(commit).map { String(String(cString: $0).prefix(8_000)) } ?? "",
                                   author: author.map { String(cString: $0.pointee.name) } ?? "",
                                   date: Date(timeIntervalSince1970: Double(git_commit_time(commit))))
            }
            // Blob/tree tags can be inspected without decompressing their contents.
            let typeName = git_object_type2string(type).map { String(cString: $0) } ?? "unknown"
            return .init(tag: .init(name: name, referenceOID: referenceOID, annotated: annotated, problem: nil),
                         targetOID: format(oid), targetType: typeName, tagger: tagger, tagDate: date, message: message, commit: commitInfo)
        }
        throw GitFailure.message(tagError)
    }

    static func tagDetail(at repoURL: URL, name: String) throws -> TagDetail {
        try locked {
            let opened = try open(repoURL)
            defer { withExtendedLifetime(opened) {} }
            return try tagDetailUnlocked(opened.repo, name: name)
        }
    }

    static func checkoutTag(at repoURL: URL, tag expected: TagDetail) throws {
        try writing(repoURL) {
            try locked {
                let opened = try openForFileRestore(repoURL)
                defer { withExtendedLifetime(opened) {} }
                let repo = opened.repo
                try requireCleanOperationStart(repo)
                var visited = Set<String>(), modules: [SubmoduleInfo] = []
                try inspectSubmodules(repo, prefix: "", recursive: true, depth: 0, visited: &visited, items: &modules, rejectDirty: true)
                var transaction: OpaquePointer?
                try check(git_transaction_new(&transaction, repo), tagError)
                defer { git_transaction_free(transaction) }
                // Lock HEAD before touching the worktree, including the source
                // branch and exact tag ref. A HEAD.lock failure leaves files alone.
                try check(git_transaction_lock_ref(transaction, "HEAD"), tagError)
                var sourceHead: OpaquePointer?
                try check(git_reference_lookup(&sourceHead, repo, "HEAD"), tagError)
                defer { git_reference_free(sourceHead) }
                if let sourceRef = git_reference_symbolic_target(sourceHead) {
                    // Also supports a fetched tag in a repository whose local
                    // branch has not received its first commit yet.
                    try check(git_transaction_lock_ref(transaction, sourceRef), tagError)
                }
                try check(git_transaction_lock_ref(transaction, "refs/tags/" + expected.tag.name), tagError)
                let actual = try tagDetailUnlocked(repo, name: expected.tag.name)
                guard actual.tag.referenceOID == expected.tag.referenceOID, actual.targetOID == expected.targetOID else {
                    throw GitFailure.message(String(localized: "The tag changed. Review its details before checking it out."))
                }
                guard actual.canCheckout else { throw GitFailure.message(String(localized: "Only tags pointing to commits can be checked out.")) }
                try requireCleanOperationStart(repo)
                var oid = git_oid(), commit: OpaquePointer?
                try check(git_oid_fromstr(&oid, actual.targetOID), tagError)
                try check(git_commit_lookup(&commit, repo, &oid), tagError)
                defer { git_commit_free(commit) }
                var signature: UnsafeMutablePointer<git_signature>?
                if git_signature_default(&signature, repo) < 0 {
                    try check(git_signature_now(&signature, "Gitling", "gitling@example.invalid"), tagError)
                }
                defer { git_signature_free(signature) }
                try check(git_transaction_set_target(transaction, "HEAD", &oid, signature, "checkout: tag " + actual.tag.name), tagError)
                var options = git_checkout_options()
                try check(git_checkout_options_init(&options, UInt32(GIT_CHECKOUT_OPTIONS_VERSION)), tagError)
                options.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue | GIT_CHECKOUT_DONT_OVERWRITE_IGNORED.rawValue | GIT_CHECKOUT_DRY_RUN.rawValue
                try check(git_checkout_tree(repo, commit, &options), tagError)
                options.checkout_strategy &= ~GIT_CHECKOUT_DRY_RUN.rawValue
                try check(git_checkout_tree(repo, commit, &options), tagError)
                try check(git_transaction_commit(transaction), tagError)
            }
        }
    }

    private static func detachedOID(_ repo: OpaquePointer) -> String? {
        guard git_repository_head_detached(repo) == 1 else { return nil }
        return moduleHead(repo)
    }
    private static func headLabel(_ repo: OpaquePointer) -> String? {
        if let oid = detachedOID(repo) {
            return String(format: String(localized: "Detached HEAD · %@"), String(oid.prefix(12)))
        }
        return try? currentBranch(repo)
    }
}

// MARK: - Full-scope, cancellable repository search
extension GitClient {
    private final class CommitSearchReader {
        let opened: OpenRepo
        let walker: OpaquePointer
        let query: String
        let field: CommitSearchField
        var buffered: CommitInfo?
        var scanned = 0
        var ended = false
        init(opened: OpenRepo, walker: OpaquePointer, query: String, field: CommitSearchField) {
            self.opened = opened; self.walker = walker; self.query = query; self.field = field
        }
        deinit { git_revwalk_free(walker) }
        func page(limit: Int, cancellation: SearchCancellation) throws -> RepositorySearchPage<CommitInfo> {
            var result: [CommitInfo] = []
            if let buffered { result.append(buffered); self.buffered = nil }
            while result.count < limit, let item = try next(cancellation) { result.append(item) }
            buffered = try next(cancellation)
            return .init(items: result, hasMore: buffered != nil, scanned: scanned)
        }
        private func next(_ cancellation: SearchCancellation) throws -> CommitInfo? {
            while true {
                try cancellation.check()
                if ended { return nil }
                var oid = git_oid()
                let code = git_revwalk_next(&oid, walker)
                if GitClient.matches(code, GIT_ITEROVER) { ended = true; return nil }
                try GitClient.check(code, String(localized: "Could not search commit history."))
                scanned += 1
                let id = GitClient.format(oid)
                let oidMatches = id.hasPrefix(query.lowercased())
                if field == .oid && !oidMatches { continue }
                var commit: OpaquePointer?
                try GitClient.check(git_commit_lookup(&commit, opened.repo, &oid), String(localized: "Could not search commit history."))
                defer { git_commit_free(commit) }
                let author = git_commit_author(commit)
                let name = author.map { String(cString: $0.pointee.name) } ?? ""
                let email = author.map { String(cString: $0.pointee.email) } ?? ""
                let authorMatches = (name + " <" + email + ">").localizedCaseInsensitiveContains(query)
                let messageMatches: Bool
                if field == .message || field == .all {
                    messageMatches = git_commit_message(commit).map { String(cString: $0).localizedCaseInsensitiveContains(query) } ?? false
                } else { messageMatches = false }
                let found: Bool
                switch field {
                case .all: found = oidMatches || authorMatches || messageMatches
                case .author: found = authorMatches
                case .message: found = messageMatches
                case .oid: found = oidMatches
                }
                if found {
                    return .init(id: id, summary: git_commit_summary(commit).map { String(String(cString: $0).prefix(8_000)) } ?? "",
                                 author: name, date: Date(timeIntervalSince1970: Double(git_commit_time(commit))))
                }
            }
        }
    }

    static func historySearch(at repoURL: URL, query raw: String, field: CommitSearchField = .all,
                              scope: HistorySearchScope = .all, cancellation: SearchCancellation = .init()) throws -> RepositorySearchCursor<CommitInfo> {
        try cancellation.check()
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty { return .init(cancellation: cancellation) { _, _ in .init(items: [], hasMore: false, scanned: 0) } }
        if field == .oid, query.count > 40 || !query.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) {
            throw GitFailure.message(String(localized: "Enter an OID prefix using up to 40 hexadecimal characters."))
        }
        // History needs the local Git database, not an external worktree scope.
        // Use a separate handle so a long walk never holds the global Git lock.
        _ = ready // Swift's once initialization is shared with other Git entry points.
        let opened = try OpenRepo(path: repoURL.path, access: nil)
        var walker: OpaquePointer?
        try check(git_revwalk_new(&walker, opened.repo), String(localized: "Could not search commit history."))
        guard let walker else { throw WorkingTreeError.notFound }
        var transferred = false
        defer { if !transferred { git_revwalk_free(walker) } }
        git_revwalk_sorting(walker, UInt32(GIT_SORT_TOPOLOGICAL.rawValue | GIT_SORT_TIME.rawValue))
        switch scope {
        case .current:
            if git_repository_head_unborn(opened.repo) != 1 {
                try check(git_revwalk_push_head(walker), String(localized: "Could not search commit history."))
            }
        case .reference(let ref):
            var valid: Int32 = 0
            guard ["refs/heads/", "refs/remotes/", "refs/tags/"].contains(where: { ref.hasPrefix($0) }), !ref.contains("\0"),
                  git_reference_name_is_valid(&valid, ref) == 0, valid == 1 else { throw WorkingTreeError.outside }
            try check(git_revwalk_push_ref(walker, ref), String(localized: "Could not search commit history."))
        case .all:
            var iterator: OpaquePointer?
            try check(git_reference_iterator_new(&iterator, opened.repo), String(localized: "Could not search commit history."))
            defer { git_reference_iterator_free(iterator) }
            while true {
                try cancellation.check()
                var ref: OpaquePointer?
                let code = git_reference_next(&ref, iterator)
                if matches(code, GIT_ITEROVER) { break }
                try check(code, String(localized: "Could not search commit history."))
                defer { git_reference_free(ref) }
                guard let rawName = git_reference_name(ref) else { continue }
                let name = String(cString: rawName)
                guard ["refs/heads/", "refs/remotes/", "refs/tags/"].contains(where: { name.hasPrefix($0) }) else { continue }
                let pushed = git_revwalk_push_ref(walker, rawName)
                // Tags to trees/blobs are valid, but have no commit history.
                if name.hasPrefix("refs/tags/"), matches(pushed, GIT_EINVALIDSPEC) || matches(pushed, GIT_EPEEL) { continue }
                try check(pushed, String(localized: "Could not search commit history."))
            }
            if git_repository_head_unborn(opened.repo) != 1 {
                try check(git_revwalk_push_head(walker), String(localized: "Could not search commit history."))
            }
        }
        let reader = CommitSearchReader(opened: opened, walker: walker, query: query, field: field)
        transferred = true
        return .init(cancellation: cancellation) { limit, token in try reader.page(limit: limit, cancellation: token) }
    }

    static func fileSearch(at repoURL: URL, query raw: String, cancellation: SearchCancellation = .init()) throws -> RepositorySearchCursor<WorkEntry> {
        try cancellation.check()
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty { return .init(cancellation: cancellation) { _, _ in .init(items: [], hasMore: false, scanned: 0) } }
        let access = try WorktreeLink.beginForFileRestore(repoName: repoURL.lastPathComponent)
        do {
            let root = try SearchWorktreeAccess.root(access?.url ?? repoURL)
            let reader = try FileNameSearchReader(root: root, access: access, query: query)
            return .init(cancellation: cancellation) { limit, token in try reader.page(limit: limit, cancellation: token) }
        } catch { access?.stop(); throw error }
    }
}

// MARK: - Read-only file history, historical blobs, and blame
extension GitClient {
    private struct IndexedFile {
        var oid: git_oid
        var mode: UInt32
        var type: git_object_t
    }

    /// History of one file reachable from HEAD by first parents only.
    /// A rename is followed when the path is absent in the first parent and
    /// Git's default similarity check treats another file in that parent as the source.
    /// Copies, later parents, and interactive rename editing are out of scope.
    static func fileHistory(at repoURL: URL, path: String, cancellation: SearchCancellation = .init()) throws -> RepositorySearchCursor<FileHistoryEntry> {
        try cancellation.check()
        try requireFilePath(path)
        _ = ready
        let opened = try OpenRepo(path: repoURL.path, access: nil)
        guard let head = try headCommit(opened.repo) else {
            return emptyFileHistory(cancellation)
        }
        defer { git_commit_free(head) }
        var tree: OpaquePointer?
        try check(git_commit_tree(&tree, head), String(localized: "Could not read file history."))
        defer { git_tree_free(tree) }
        if let current = try indexedFile(tree, path), current.type == GIT_OBJECT_TREE {
            throw GitFailure.message(String(localized: "File history follows one file, not a directory."))
        }
        var walker: OpaquePointer?
        try check(git_revwalk_new(&walker, opened.repo), String(localized: "Could not read file history."))
        guard let walker else { throw WorkingTreeError.notFound }
        var transferred = false
        defer { if !transferred { git_revwalk_free(walker) } }
        // Topological order keeps descendants before ancestors, including commits
        // created in the same second. Stopping at the introducing commit is then safe.
        git_revwalk_sorting(walker, UInt32(GIT_SORT_TOPOLOGICAL.rawValue | GIT_SORT_TIME.rawValue))
        try check(git_revwalk_simplify_first_parent(walker), String(localized: "Could not read file history."))
        try check(git_revwalk_push_head(walker), String(localized: "Could not read file history."))
        let reader = FileHistoryReader(opened: opened, walker: walker, path: path)
        transferred = true
        return .init(cancellation: cancellation) { limit, token in try reader.page(limit: limit, cancellation: token) }
    }

    static func fileRevision(at repoURL: URL, commit id: String, path: String) throws -> FileBlobState {
        try requireFilePath(path)
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.count == 40, trimmed.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw GitFailure.message(String(localized: "Could not read that file version."))
        }
        _ = ready
        let opened = try OpenRepo(path: repoURL.path, access: nil)
        defer { withExtendedLifetime(opened) {} }
        var oid = git_oid()
        guard git_oid_fromstr(&oid, trimmed) == 0 else {
            throw GitFailure.message(String(localized: "Could not read that file version."))
        }
        var commit: OpaquePointer?
        if git_commit_lookup(&commit, opened.repo, &oid) < 0 { return .missingObject }
        defer { git_commit_free(commit) }
        guard let commit else { return .missingObject }
        var tree: OpaquePointer?
        if git_commit_tree(&tree, commit) < 0 { return .missingObject }
        defer { git_tree_free(tree) }
        guard let file = try indexedFile(tree, path) else { return .missing }
        return try blobState(opened.repo, file)
    }

    /// Blame the worktree text of one regular UTF-8 file against the HEAD commit read once here.
    /// Lines that differ from that commit have no commit. The walk uses the first parent only.
    /// Untracked files are reported as uncommitted.
    ///
    /// `git_blame_file` and `git_blame_buffer` are synchronous and offer no cancellation callback.
    /// `cancellation` is checked before opening, before and after each libgit2 blame call, and in
    /// the pre-walk at each commit, path, diff entry, and candidate blob. Single libgit2 calls in
    /// the pre-walk (tree diff, `git_diff_find_similar`) and in blame run to completion once started.
    /// The pre-walk picks `oldest_commit` from an estimate of the blob bytes blame will read
    /// (see `BlameLimits`); it is not a hard cap on memory or CPU. `beforeBlame` runs after HEAD
    /// is resolved and checked, right before libgit2 starts. `onCancellationCheck` runs right
    /// before each pre-walk check.
    static func blame(at repoURL: URL, path: String, cancellation: SearchCancellation = .init(),
                      limits: BlameLimits = .standard, beforeBlame: () throws -> Void = {},
                      onCancellationCheck: () throws -> Void = {}) throws -> [BlameSpan] {
        func stopIfCancelled() throws {
            try onCancellationCheck()
            try cancellation.check()
        }
        try cancellation.check()
        try requireFilePath(path)
        _ = ready
        let access = try WorktreeLink.beginForFileRestore(repoName: repoURL.lastPathComponent)
        let opened: OpenRepo
        do { opened = try OpenRepo(path: repoURL.path, access: access) }
        catch { access?.stop(); throw error }
        defer { withExtendedLifetime(opened) {} }
        let root = try SearchWorktreeAccess.root(access?.url ?? repoURL)
        let text = try SearchWorktreeAccess.preview(root: root, path: path)
        guard !text.utf8.contains(0) else {
            throw GitFailure.message(String(localized: "This file is binary and cannot be blamed."))
        }
        let lines = splitLines(text)
        try cancellation.check()
        guard let head = try headCommit(opened.repo) else {
            return lines.isEmpty ? [] : [uncommitted(lines, path: path)]
        }
        defer { git_commit_free(head) }
        let newest = git_commit_id(head)!.pointee
        var tree: OpaquePointer?
        try check(git_commit_tree(&tree, head), String(localized: "Could not blame this file."))
        defer { git_tree_free(tree) }
        guard let file = try indexedFile(tree, path) else {
            return lines.isEmpty ? [] : [uncommitted(lines, path: path)]
        }
        if file.type == GIT_OBJECT_TREE {
            throw GitFailure.message(String(localized: "File history follows one file, not a directory."))
        }
        guard file.type == GIT_OBJECT_BLOB,
              file.mode != UInt32(GIT_FILEMODE_LINK.rawValue),
              file.mode != UInt32(GIT_FILEMODE_COMMIT.rawValue) else {
            throw GitFailure.message(String(localized: "Could not blame this file."))
        }
        var database: OpaquePointer?
        try check(git_repository_odb(&database, opened.repo), String(localized: "Could not blame this file."))
        defer { git_odb_free(database) }
        guard let database else { throw GitFailure.message(String(localized: "Could not blame this file.")) }
        let committedSize = try blameableBlobSize(opened.repo, database, file.oid)
        let boundary = try blameBoundary(opened.repo, database, head: head, path: path,
                                         spent: committedSize, limits: limits, stopIfCancelled: stopIfCancelled)
        try beforeBlame()
        try cancellation.check()
        var options = git_blame_options()
        try check(git_blame_options_init(&options, UInt32(GIT_BLAME_OPTIONS_VERSION)), String(localized: "Could not blame this file."))
        options.flags = UInt32(GIT_BLAME_FIRST_PARENT.rawValue)
        // Both ends are fixed OIDs, so a concurrent branch switch cannot change what libgit2 reads.
        options.newest_commit = newest
        options.oldest_commit = boundary.oldest
        var base: OpaquePointer?
        try path.withCString { pointer in
            try check(git_blame_file(&base, opened.repo, pointer, &options), String(localized: "Could not blame this file."))
        }
        defer { git_blame_free(base) }
        try cancellation.check()
        let data = Data(text.utf8)
        var blamed: OpaquePointer?
        if data.isEmpty {
            try check(git_blame_buffer(&blamed, base, "", 0), String(localized: "Could not blame this file."))
        } else {
            try data.withUnsafeBytes { raw in
                guard let pointer = raw.bindMemory(to: CChar.self).baseAddress else {
                    throw GitFailure.message(String(localized: "Could not blame this file."))
                }
                try check(git_blame_buffer(&blamed, base, pointer, data.count), String(localized: "Could not blame this file."))
            }
        }
        defer { git_blame_free(blamed) }
        try cancellation.check()
        guard let blamed else { return [] }
        let spans = blameSpans(blamed, lines: lines, repo: opened.repo, path: path, limitedAt: boundary.limited ? boundary.oldest : nil)
        return spans.isEmpty && !lines.isEmpty ? [uncommitted(lines, path: path)] : spans
    }

    /// Size of a blob read from its object header only, or nil when missing or not a blob.
    private static func blobSize(_ database: OpaquePointer, _ oid: git_oid) -> Int? {
        var oid = oid
        var length = 0
        var kind = GIT_OBJECT_INVALID
        guard git_odb_read_header(&length, &kind, database, &oid) == 0, kind == GIT_OBJECT_BLOB else { return nil }
        return length
    }

    /// The committed version libgit2 blames against must itself be a small, non-binary blob,
    /// whatever the size of the worktree file.
    private static func blameableBlobSize(_ repo: OpaquePointer, _ database: OpaquePointer, _ oid: git_oid) throws -> Int {
        guard let size = blobSize(database, oid) else {
            throw GitFailure.message(String(localized: "Could not blame this file."))
        }
        guard size <= FileInspection.maximumBytes else {
            throw GitFailure.message(String(localized: "The committed version of this file is too large to blame."))
        }
        var oid = oid
        var blob: OpaquePointer?
        try check(git_blob_lookup(&blob, repo, &oid), String(localized: "Could not blame this file."))
        defer { git_blob_free(blob) }
        guard git_blob_is_binary(blob) == 0 else {
            throw GitFailure.message(String(localized: "This file is binary and cannot be blamed."))
        }
        return size
    }

    private enum BlameStep {
        case next(cost: Int)
        case origin
        case limit
    }

    /// Walks the first-parent history libgit2 blame follows and returns the oldest commit libgit2
    /// may visit. Blob sizes come from object headers, but a step whose file is absent in the
    /// parent runs the same rename detection as blame, which reads candidate contents once they
    /// fit the budget. `limited` is true when the walk stopped for `limits`, an oversized or
    /// missing object, rather than at the file's origin.
    private static func blameBoundary(_ repo: OpaquePointer, _ database: OpaquePointer, head: OpaquePointer, path: String,
                                      spent: Int, limits: BlameLimits,
                                      stopIfCancelled: () throws -> Void) throws -> (oldest: git_oid, limited: Bool) {
        var duplicate: OpaquePointer?
        try check(git_commit_dup(&duplicate, head), String(localized: "Could not blame this file."))
        guard var commit = duplicate else { throw GitFailure.message(String(localized: "Could not blame this file.")) }
        defer { git_commit_free(commit) }
        var paths: Set<String> = [path]
        var current = path
        var remaining = limits.bytes - spent
        var visited = 1
        while true {
            try stopIfCancelled()
            let oldest = git_commit_id(commit)!.pointee
            guard git_commit_parentcount(commit) > 0 else { return (oldest, false) }
            guard visited < limits.commits, remaining >= 0 else { return (oldest, true) }
            var parent: OpaquePointer?
            guard git_commit_parent(&parent, commit, 0) == 0, let next = parent else { return (oldest, true) }
            let step: BlameStep
            do {
                step = try blameStep(repo, database, child: commit, parent: next, paths: &paths, current: &current,
                                     remaining: remaining, stopIfCancelled: stopIfCancelled)
            }
            catch { git_commit_free(next); throw error }
            switch step {
            case .origin:
                git_commit_free(next)
                return (oldest, false)
            case .limit:
                git_commit_free(next)
                return (oldest, true)
            case .next(let cost):
                remaining -= cost
                git_commit_free(commit)
                commit = next
                visited += 1
            }
        }
    }

    private static func blameStep(_ repo: OpaquePointer, _ database: OpaquePointer, child: OpaquePointer, parent: OpaquePointer,
                                  paths: inout Set<String>, current: inout String, remaining: Int,
                                  stopIfCancelled: () throws -> Void) throws -> BlameStep {
        var childTree: OpaquePointer?
        var parentTree: OpaquePointer?
        defer { git_tree_free(childTree); git_tree_free(parentTree) }
        guard git_commit_tree(&childTree, child) == 0, git_commit_tree(&parentTree, parent) == 0 else { return .limit }
        let gitlink = UInt32(GIT_FILEMODE_COMMIT.rawValue)
        var loaded: Set<String> = []
        var cost = 0
        func load(_ oid: git_oid) -> Bool {
            guard loaded.insert(format(oid)).inserted else { return true }
            guard let size = blobSize(database, oid), size <= FileInspection.maximumBytes else { return false }
            cost += size
            return cost <= remaining
        }
        // libgit2 detects changes with a pathspec, so glob characters can match more than one path.
        var changed = paths.contains { $0.rangeOfCharacter(from: CharacterSet(charactersIn: "*?[\\")) != nil }
        for name in paths {
            try stopIfCancelled()
            // libgit2 loads the parent's version of the path it follows at every step, even when
            // unchanged, and on a changed step one for every followed path the diff reports,
            // deletions included. Counting every followed path covers both.
            let before = try indexedFile(parentTree, name)
            if let before, before.type == GIT_OBJECT_BLOB, before.mode != gitlink, !load(before.oid) { return .limit }
            if !changed { changed = try !sameFile(indexedFile(childTree, name), before) }
        }
        let previous = try indexedFile(parentTree, current)
        var renamed: String?
        if changed {
            // libgit2 then diffs the whole trees with rename detection, which may read every candidate.
            try stopIfCancelled()
            guard let scan = try renameCandidates(repo, parentTree, childTree, paths: paths,
                                                  stopIfCancelled: stopIfCancelled) else { return .limit }
            for oid in scan.blobs {
                try stopIfCancelled()
                if !load(oid) { return .limit }
            }
            if scan.findsRenames {
                // Like libgit2, follow the source of every rename onto a followed path, so later
                // steps count the versions blame will load under those names too.
                for rename in try renames(parent: parent, child: child, repo: repo, stopIfCancelled: stopIfCancelled)
                where rename.old != rename.new && paths.contains(rename.new) {
                    paths.insert(rename.old)
                    if rename.new == current { renamed = rename.old }
                }
            }
        }
        guard let previous else {
            guard let renamed else { return .origin }
            current = renamed
            return .next(cost: cost)
        }
        return previous.type == GIT_OBJECT_BLOB && previous.mode != gitlink ? .next(cost: cost) : .origin
    }

    /// Blobs a full tree-to-tree diff with rename detection may read: `git_diff_find_similar` may
    /// compare any added file with any deleted one. `findsRenames` is true when it would run
    /// with a followed path among the added files. The diff call itself cannot be interrupted;
    /// its entries are checked one by one.
    private static func renameCandidates(_ repo: OpaquePointer, _ parentTree: OpaquePointer?, _ childTree: OpaquePointer?,
                                         paths: Set<String>,
                                         stopIfCancelled: () throws -> Void) throws -> (blobs: [git_oid], findsRenames: Bool)? {
        var options = git_diff_options()
        git_diff_options_init(&options, UInt32(GIT_DIFF_OPTIONS_VERSION))
        options.flags = UInt32(GIT_DIFF_SKIP_BINARY_CHECK.rawValue)
        var diff: OpaquePointer?
        guard git_diff_tree_to_tree(&diff, repo, parentTree, childTree, &options) == 0, let diff else { return nil }
        defer { git_diff_free(diff) }
        let gitlink = UInt32(GIT_FILEMODE_COMMIT.rawValue)
        var added: [git_oid] = []
        var deleted: [git_oid] = []
        var followedAdded = false
        for index in 0..<git_diff_num_deltas(diff) {
            try stopIfCancelled()
            guard let delta = git_diff_get_delta(diff, index)?.pointee else { continue }
            if delta.status == GIT_DELTA_ADDED, UInt32(delta.new_file.mode) != gitlink {
                added.append(delta.new_file.id)
                if let name = delta.new_file.path, paths.contains(String(cString: name)) { followedAdded = true }
            } else if delta.status == GIT_DELTA_DELETED, UInt32(delta.old_file.mode) != gitlink {
                deleted.append(delta.old_file.id)
            }
        }
        guard !added.isEmpty, !deleted.isEmpty else { return ([], false) }
        return (added + deleted, followedAdded)
    }

    private static func emptyFileHistory(_ cancellation: SearchCancellation) -> RepositorySearchCursor<FileHistoryEntry> {
        .init(cancellation: cancellation) { _, _ in .init(items: [], hasMore: false, scanned: 0) }
    }

    private static func indexedFile(_ tree: OpaquePointer?, _ path: String) throws -> IndexedFile? {
        guard let tree else { return nil }
        var entry: OpaquePointer?
        let code = git_tree_entry_bypath(&entry, tree, path)
        if matches(code, GIT_ENOTFOUND) { return nil }
        try check(code, String(localized: "Could not read file history."))
        defer { git_tree_entry_free(entry) }
        guard let entry, let identifier = git_tree_entry_id(entry) else { return nil }
        return IndexedFile(
            oid: identifier.pointee,
            mode: UInt32(git_tree_entry_filemode(entry).rawValue),
            type: git_tree_entry_type(entry)
        )
    }

    private static func blobState(_ repo: OpaquePointer, _ file: IndexedFile) throws -> FileBlobState {
        if file.type == GIT_OBJECT_TREE { return .directory }
        if file.type == GIT_OBJECT_COMMIT || file.mode == UInt32(GIT_FILEMODE_COMMIT.rawValue) {
            return .gitlink(format(file.oid))
        }
        guard file.type == GIT_OBJECT_BLOB else { return .missingObject }
        var oid = file.oid
        return try loadBlob(repo, oid: &oid, symlink: file.mode == UInt32(GIT_FILEMODE_LINK.rawValue))
    }

    private static func loadBlob(_ repo: OpaquePointer, oid: inout git_oid, symlink: Bool) throws -> FileBlobState {
        var database: OpaquePointer?
        guard git_repository_odb(&database, repo) == 0, let database else { return .missingObject }
        defer { git_odb_free(database) }
        guard let length = blobSize(database, oid) else { return .missingObject }
        if length > FileInspection.maximumBytes { return .tooLarge }
        var blob: OpaquePointer?
        if git_blob_lookup(&blob, repo, &oid) < 0 { return .missingObject }
        defer { git_blob_free(blob) }
        guard let blob else { return .missingObject }
        if !symlink, git_blob_is_binary(blob) == 1 { return .binary }
        let size = Int(git_blob_rawsize(blob))
        if size > FileInspection.maximumBytes { return .tooLarge }
        let data: Data
        if size == 0 {
            data = Data()
        } else if let pointer = git_blob_rawcontent(blob) {
            data = Data(bytes: pointer, count: size)
        } else {
            return .missingObject
        }
        guard let text = String(data: data, encoding: .utf8) else { return .notUTF8 }
        return symlink ? .symlink(text) : .text(text)
    }

    private static func oidsEqual(_ lhs: git_oid, _ rhs: git_oid) -> Bool {
        var lhs = lhs
        var rhs = rhs
        return git_oid_equal(&lhs, &rhs) == 1
    }

    private static func sameFile(_ lhs: IndexedFile?, _ rhs: IndexedFile?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (lhs?, rhs?):
            return lhs.type == rhs.type && lhs.mode == rhs.mode && oidsEqual(lhs.oid, rhs.oid)
        default: return false
        }
    }

    private static func renamedFrom(parent: OpaquePointer, child: OpaquePointer, path: String, repo: OpaquePointer,
                                    stopIfCancelled: () throws -> Void) throws -> String? {
        try renames(parent: parent, child: child, repo: repo, stopIfCancelled: stopIfCancelled)
            .first { $0.new == path && $0.old != path }?.old
    }

    /// Renames Git's default similarity check finds from `parent` to `child`, in diff order.
    /// `git_diff_tree_to_tree` and `git_diff_find_similar` each run to completion once started;
    /// cancellation is checked between them and at each resulting entry.
    private static func renames(parent: OpaquePointer, child: OpaquePointer, repo: OpaquePointer,
                                stopIfCancelled: () throws -> Void) throws -> [(new: String, old: String)] {
        var parentTree: OpaquePointer?
        var childTree: OpaquePointer?
        try check(git_commit_tree(&parentTree, parent), String(localized: "Could not read file history."))
        try check(git_commit_tree(&childTree, child), String(localized: "Could not read file history."))
        defer { git_tree_free(parentTree); git_tree_free(childTree) }
        var options = git_diff_options()
        git_diff_options_init(&options, UInt32(GIT_DIFF_OPTIONS_VERSION))
        var diff: OpaquePointer?
        try stopIfCancelled()
        try check(git_diff_tree_to_tree(&diff, repo, parentTree, childTree, &options), String(localized: "Could not read file history."))
        defer { git_diff_free(diff) }
        var find = git_diff_find_options()
        git_diff_find_options_init(&find, UInt32(GIT_DIFF_FIND_OPTIONS_VERSION))
        find.flags = UInt32(GIT_DIFF_FIND_RENAMES.rawValue)
        try stopIfCancelled()
        try check(git_diff_find_similar(diff, &find), String(localized: "Could not read file history."))
        guard let diff else { return [] }
        var found: [(new: String, old: String)] = []
        for index in 0..<git_diff_num_deltas(diff) {
            try stopIfCancelled()
            guard let delta = git_diff_get_delta(diff, index), delta.pointee.status == GIT_DELTA_RENAMED,
                  let newPath = delta.pointee.new_file.path,
                  let oldPath = delta.pointee.old_file.path else { continue }
            found.append((new: String(cString: newPath), old: String(cString: oldPath)))
        }
        return found
    }

    private static func splitLines(_ text: String) -> [String] {
        if text.isEmpty { return [] }
        var lines = text.components(separatedBy: "\n")
        if text.hasSuffix("\n") { lines.removeLast() }
        return lines
    }

    private static func uncommitted(_ lines: [String], path: String) -> BlameSpan {
        BlameSpan(commitID: nil, summary: "", author: "", date: nil, startLine: 1, lineCount: max(lines.count, 1), lines: lines, originPath: path)
    }

    private static func blameSpans(_ blame: OpaquePointer, lines: [String], repo: OpaquePointer, path: String, limitedAt limit: git_oid?) -> [BlameSpan] {
        var summaries: [String: String] = [:]
        var result: [BlameSpan] = []
        for index in 0..<git_blame_get_hunk_count(blame) {
            guard let hunk = git_blame_get_hunk_byindex(blame, index) else { continue }
            let raw = hunk.pointee
            let start = Int(raw.final_start_line_number)
            let lineCount = Int(raw.lines_in_hunk)
            guard start > 0, lineCount > 0 else { continue }
            let lower = min(lines.count, start - 1)
            let upper = min(lines.count, lower + lineCount)
            let slice = Array(lines[lower..<upper])
            var oid = raw.final_commit_id
            let origin = raw.orig_path.map { String(cString: $0) } ?? path
            guard git_oid_is_zero(&oid) == 0 else {
                result.append(BlameSpan(commitID: nil, summary: "", author: "", date: nil, startLine: start, lineCount: lineCount, lines: slice, originPath: origin))
                continue
            }
            let id = format(oid)
            if summaries[id] == nil { summaries[id] = commitSummary(repo, oid: &oid) }
            let signature = raw.final_signature
            result.append(BlameSpan(
                commitID: id,
                summary: summaries[id] ?? "",
                author: signature.map { String(cString: $0.pointee.name) } ?? "",
                date: signature.map { Date(timeIntervalSince1970: TimeInterval($0.pointee.when.time)) },
                startLine: start,
                lineCount: lineCount,
                lines: slice,
                originPath: origin,
                historyLimited: limit.map { oidsEqual($0, oid) } ?? false
            ))
        }
        return result
    }

    private static func commitSummary(_ repo: OpaquePointer, oid: inout git_oid) -> String {
        var commit: OpaquePointer?
        guard git_commit_lookup(&commit, repo, &oid) == 0, let commit else { return "" }
        defer { git_commit_free(commit) }
        return git_commit_summary(commit).map { String(String(cString: $0).prefix(8_000)) } ?? ""
    }

    private static func commitInfo(_ commit: OpaquePointer, oid: git_oid) -> CommitInfo {
        CommitInfo(
            id: format(oid),
            summary: git_commit_summary(commit).map { String(String(cString: $0).prefix(8_000)) } ?? "",
            author: git_commit_author(commit).map { String(cString: $0.pointee.name) } ?? "",
            date: Date(timeIntervalSince1970: TimeInterval(git_commit_time(commit)))
        )
    }

    private final class FileHistoryReader {
        let opened: OpenRepo
        let walker: OpaquePointer
        var path: String
        var buffered: FileHistoryEntry?
        var scanned = 0
        var ended = false

        init(opened: OpenRepo, walker: OpaquePointer, path: String) {
            self.opened = opened
            self.walker = walker
            self.path = path
        }

        deinit { git_revwalk_free(walker) }

        func page(limit: Int, cancellation: SearchCancellation) throws -> RepositorySearchPage<FileHistoryEntry> {
            var result: [FileHistoryEntry] = []
            if let buffered { result.append(buffered); self.buffered = nil }
            while result.count < limit, let item = try next(cancellation) { result.append(item) }
            buffered = try next(cancellation)
            return .init(items: result, hasMore: buffered != nil, scanned: scanned)
        }

        private func next(_ cancellation: SearchCancellation) throws -> FileHistoryEntry? {
            while true {
                try cancellation.check()
                if ended { return nil }
                var oid = git_oid()
                let code = git_revwalk_next(&oid, walker)
                if GitClient.matches(code, GIT_ITEROVER) { ended = true; return nil }
                try GitClient.check(code, String(localized: "Could not read file history."))
                scanned += 1
                if let entry = try change(at: oid, cancellation: cancellation) { return entry }
            }
        }

        private func change(at oid: git_oid, cancellation: SearchCancellation) throws -> FileHistoryEntry? {
            var oid = oid
            var child: OpaquePointer?
            try GitClient.check(git_commit_lookup(&child, opened.repo, &oid), String(localized: "Could not read file history."))
            defer { git_commit_free(child) }
            guard let child else { return nil }
            var childTree: OpaquePointer?
            try GitClient.check(git_commit_tree(&childTree, child), String(localized: "Could not read file history."))
            defer { git_tree_free(childTree) }
            let current = try GitClient.indexedFile(childTree, path)
            var parent: OpaquePointer?
            if git_commit_parentcount(child) > 0 {
                try GitClient.check(git_commit_parent(&parent, child, 0), String(localized: "Could not read file history."))
            }
            defer { git_commit_free(parent) }
            var parentTree: OpaquePointer?
            if let parent {
                try GitClient.check(git_commit_tree(&parentTree, parent), String(localized: "Could not read file history."))
            }
            defer { git_tree_free(parentTree) }
            let previous = try GitClient.indexedFile(parentTree, path)
            if GitClient.sameFile(current, previous) { return nil }
            let info = GitClient.commitInfo(child, oid: oid)
            if current == nil {
                return FileHistoryEntry(commit: info, path: path, kind: .deleted, previousPath: nil)
            }
            if previous == nil {
                if let parent, let old = try GitClient.renamedFrom(parent: parent, child: child, path: path, repo: opened.repo,
                                                                    stopIfCancelled: { try cancellation.check() }) {
                    let entry = FileHistoryEntry(commit: info, path: path, kind: .renamed, previousPath: old)
                    path = old
                    return entry
                }
                ended = true
                return FileHistoryEntry(commit: info, path: path, kind: .added, previousPath: nil)
            }
            return FileHistoryEntry(commit: info, path: path, kind: .modified, previousPath: nil)
        }
    }
}

// Appended to the end of Gitling/GitClient.swift
// (after the final closing brace of the existing file, line 3942).

// MARK: - Fixed commit comparison endpoints

extension GitClient {
    /// Resolve a user-entered commit reference to a fixed full commit OID.
    ///
    /// Accepted inputs, in order:
    /// 1. `HEAD`.
    /// 2. A full reference under `refs/heads/`, `refs/remotes/`, or `refs/tags/`.
    /// 3. Exactly one short branch, remote-branch, or tag name in those namespaces.
    /// 4. A unique hexadecimal object prefix with at least 7 characters.
    ///
    /// Short names are rejected when more than one namespace matches; pass a full
    /// reference to choose one. Annotated tags are peeled with a 32-object ceiling,
    /// and each tag or commit object is rejected if its header exceeds 1 MiB.
    ///
    /// This uses an independent `OpenRepo(path:access:nil)` handle and never reads or
    /// writes the worktree, index, refs, or remote state. libgit2 object-header,
    /// tag-lookup, and commit-lookup calls are synchronous and not individually
    /// interruptible; cancellation is checked before and between them.
    static func resolveComparisonCommit(at repoURL: URL, input raw: String,
                                        cancellation: SearchCancellation = .init()) throws -> ComparisonEndpoint {
        try cancellation.check()
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else {
            throw GitFailure.message(String(localized: "Enter a commit, branch, or tag."))
        }
        guard !input.contains("\0") else {
            throw GitFailure.message(String(localized: "That is not a valid commit reference."))
        }
        _ = ready
        let opened = try OpenRepo(path: repoURL.path, access: nil)
        defer { withExtendedLifetime(opened) {} }
        let repo = opened.repo

        // Refs take precedence over OID prefixes: a legal branch or tag name may be all hex.
        if input == "HEAD" {
            try cancellation.check()
            return try comparisonResolveReference(repo, reference: "HEAD", input: input,
                                                  source: .head, cancellation: cancellation)
        }
        if input.hasPrefix("refs/") {
            guard input.hasPrefix("refs/heads/")
                || input.hasPrefix("refs/remotes/")
                || input.hasPrefix("refs/tags/") else {
                throw GitFailure.message(String(localized: "Use a branch, remote branch, or tag reference."))
            }
            return try comparisonResolveReference(repo, reference: input, input: input,
                                                  source: comparisonSource(for: input),
                                                  cancellation: cancellation)
        }
        if let endpoint = try comparisonResolveShortName(repo, name: input, input: input,
                                                          cancellation: cancellation) {
            return endpoint
        }
        return try comparisonResolveOIDPrefix(repo, input: input, cancellation: cancellation)
    }

    /// Local branches, remote-tracking branches, tags, and HEAD as endpoint choices.
    ///
    /// The list comes from the repository database only, so it works without a worktree
    /// bookmark. Annotated tags report their direct tag-object target; resolving an
    /// endpoint peels that tag. No network or remote lookup is performed, and the whole
    /// reference list is bounded only by the repository's ref count and cancellation.
    static func comparisonReferences(at repoURL: URL,
                                     cancellation: SearchCancellation = .init()) throws -> [ComparisonReference] {
        try cancellation.check()
        _ = ready
        let opened = try OpenRepo(path: repoURL.path, access: nil)
        defer { withExtendedLifetime(opened) {} }
        let repo = opened.repo
        var database: OpaquePointer?
        try check(git_repository_odb(&database, repo), String(localized: "Could not read references."))
        guard let database else {
            throw GitFailure.message(String(localized: "Could not read references."))
        }
        defer { git_odb_free(database) }

        let current = comparisonCurrentReferenceName(repo)
        var result: [ComparisonReference] = []

        var head: OpaquePointer?
        try check(git_reference_lookup(&head, repo, "HEAD"), String(localized: "Could not read references."))
        guard let head else { throw GitFailure.message(String(localized: "Could not read references.")) }
        defer { git_reference_free(head) }
        result.append(ComparisonReference(
            name: "HEAD",
            reference: "HEAD",
            kind: .head,
            targetOID: comparisonReferenceOID(head).map { format($0) },
            annotated: false,
            isCurrent: false
        ))

        let list = try comparisonReferenceList(repo, database: database, current: current,
                                               cancellation: cancellation)
        result.append(contentsOf: list)
        return result
    }
}

// MARK: - Private comparison helpers

private extension GitClient {
    static func comparisonSource(for reference: String) -> ComparisonEndpoint.Source {
        if reference.hasPrefix("refs/heads/") { return .localBranch }
        if reference.hasPrefix("refs/remotes/") { return .remoteBranch }
        if reference.hasPrefix("refs/tags/") { return .tag }
        return .head
    }

    static func comparisonResolveReference(_ repo: OpaquePointer,
                                           reference: String,
                                           input: String,
                                           source: ComparisonEndpoint.Source,
                                           cancellation: SearchCancellation) throws -> ComparisonEndpoint {
        try cancellation.check()
        var ref: OpaquePointer?
        guard git_reference_lookup(&ref, repo, reference) == 0, let ref else {
            throw GitFailure.message(String(localized: "That branch or tag does not exist."))
        }
        defer { git_reference_free(ref) }

        var resolved: OpaquePointer?
        defer { if let resolved { git_reference_free(resolved) } }
        let targetRef: OpaquePointer
        if git_reference_type(ref) == GIT_REFERENCE_SYMBOLIC {
            try cancellation.check()
            guard git_reference_resolve(&resolved, ref) == 0, let resolved else {
                throw GitFailure.message(String(localized: "That reference does not point to a commit."))
            }
            targetRef = resolved
        } else {
            targetRef = ref
        }
        guard let target = git_reference_target(targetRef) else {
            throw GitFailure.message(String(localized: "That reference does not point to a commit."))
        }
        return try comparisonPeelCommit(repo, oid: target.pointee, input: input, source: source,
                                        cancellation: cancellation)
    }

    static func comparisonResolveShortName(_ repo: OpaquePointer,
                                           name: String,
                                           input: String,
                                           cancellation: SearchCancellation) throws -> ComparisonEndpoint? {
        let candidates: [(reference: String, source: ComparisonEndpoint.Source)] = [
            ("refs/heads/" + name, .localBranch),
            ("refs/remotes/" + name, .remoteBranch),
            ("refs/tags/" + name, .tag),
        ]
        var matches: [(reference: String, source: ComparisonEndpoint.Source)] = []
        for candidate in candidates {
            try cancellation.check()
            var ref: OpaquePointer?
            if git_reference_lookup(&ref, repo, candidate.reference) == 0, let ref {
                git_reference_free(ref)
                matches.append(candidate)
            }
        }
        guard !matches.isEmpty else { return nil }
        guard matches.count == 1, let match = matches.first else {
            let names = matches.map { $0.reference }.joined(separator: ", ")
            throw GitFailure.message(String(
                format: String(localized: "That name is ambiguous. Use a full reference: %@"),
                names
            ))
        }
        return try comparisonResolveReference(repo, reference: match.reference, input: input,
                                              source: match.source, cancellation: cancellation)
    }

    static func comparisonResolveOIDPrefix(_ repo: OpaquePointer,
                                           input: String,
                                           cancellation: SearchCancellation) throws -> ComparisonEndpoint {
        let hex = input.lowercased()
        guard hex.count >= 7, hex.count <= 40,
              hex.utf8.allSatisfy({ comparisonIsHexDigit($0) }) else {
            throw GitFailure.message(String(
                localized: "No branch or tag matches that name, and it is not an OID prefix of at least 7 hexadecimal characters."
            ))
        }
        try cancellation.check()

        var database: OpaquePointer?
        try check(git_repository_odb(&database, repo), String(localized: "Could not read the Git object database."))
        guard let database else {
            throw GitFailure.message(String(localized: "Could not read the Git object database."))
        }
        defer { git_odb_free(database) }

        var oid = git_oid()
        if hex.count == 40 {
            guard hex.withCString({ git_oid_fromstr(&oid, $0) }) == 0 else {
                throw GitFailure.message(String(localized: "That is not a valid commit OID."))
            }
        } else {
            var prefix = git_oid()
            guard hex.withCString({ git_oid_fromstrn(&prefix, $0, hex.count) }) == 0 else {
                throw GitFailure.message(String(localized: "That is not a valid commit OID."))
            }
            var full = git_oid()
            let code = git_odb_exists_prefix(&full, database, &prefix, hex.count)
            if matches(code, GIT_EAMBIGUOUS) {
                throw GitFailure.message(String(localized: "That OID prefix matches more than one object. Enter more characters."))
            }
            if matches(code, GIT_ENOTFOUND) {
                throw GitFailure.message(String(localized: "No object in this repository matches that OID prefix."))
            }
            try check(code, String(localized: "Could not read that object."))
            oid = full
        }
        return try comparisonPeelCommit(repo, oid: oid, input: input, source: .oidPrefix,
                                        cancellation: cancellation)
    }

    /// Follow bounded annotated-tag chains and load only a final commit.
    ///
    /// The object header is read before every load. A present tree/blob is rejected as a
    /// non-commit; a missing object is reported separately. The 1 MiB metadata ceiling
    /// applies to each tag object and to the final commit object.
    static func comparisonPeelCommit(_ repo: OpaquePointer,
                                     oid initial: git_oid,
                                     input: String,
                                     source: ComparisonEndpoint.Source,
                                     cancellation: SearchCancellation) throws -> ComparisonEndpoint {
        var database: OpaquePointer?
        try check(git_repository_odb(&database, repo), String(localized: "Could not read the Git object database."))
        guard let database else {
            throw GitFailure.message(String(localized: "Could not read the Git object database."))
        }
        defer { git_odb_free(database) }

        let limits = ComparisonLimits.standard
        var oid = initial
        for _ in 0..<limits.maximumTagPeelDepth {
            try cancellation.check()

            var type = GIT_OBJECT_INVALID
            var size = 0
            let header = git_odb_read_header(&size, &type, database, &oid)
            if matches(header, GIT_ENOTFOUND) {
                throw GitFailure.message(String(localized: "The selected object is missing from this repository."))
            }
            try check(header, String(localized: "Could not read that object."))

            if type == GIT_OBJECT_TAG {
                guard size <= limits.maximumMetadataBytes else {
                    throw GitFailure.message(String(localized: "The tag metadata is too large to read safely."))
                }
                var tag: OpaquePointer?
                try check(git_tag_lookup(&tag, repo, &oid), String(localized: "Could not read that tag."))
                guard let tag else { throw GitFailure.message(String(localized: "Could not read that tag.")) }
                defer { git_tag_free(tag) }
                guard let target = git_tag_target_id(tag) else {
                    throw GitFailure.message(String(localized: "Could not read that tag's target."))
                }
                oid = target.pointee
                continue
            }

            guard type == GIT_OBJECT_COMMIT else {
                throw GitFailure.message(String(localized: "That reference does not point to a commit."))
            }
            guard size <= limits.maximumMetadataBytes else {
                throw GitFailure.message(String(localized: "The commit metadata is too large to read safely."))
            }

            var commit: OpaquePointer?
            try check(git_commit_lookup(&commit, repo, &oid), String(localized: "Could not read that commit."))
            guard let commit else { throw GitFailure.message(String(localized: "Could not read that commit.")) }
            defer { git_commit_free(commit) }

            let author = git_commit_author(commit)
            return ComparisonEndpoint(
                oid: format(oid),
                input: input,
                source: source,
                summary: git_commit_summary(commit).map { String(String(cString: $0).prefix(8_000)) } ?? "",
                author: author.map { String(cString: $0.pointee.name) } ?? "",
                date: Date(timeIntervalSince1970: Double(git_commit_time(commit)))
            )
        }
        throw GitFailure.message(String(localized: "The tag chain is too deep to resolve safely."))
    }

    static func comparisonReferenceList(_ repo: OpaquePointer,
                                        database: OpaquePointer,
                                        current: String?,
                                        cancellation: SearchCancellation) throws -> [ComparisonReference] {
        var iterator: OpaquePointer?
        try check(git_reference_iterator_new(&iterator, repo), String(localized: "Could not read references."))
        guard let iterator else { throw GitFailure.message(String(localized: "Could not read references.")) }
        defer { git_reference_iterator_free(iterator) }

        var local: [ComparisonReference] = []
        var remote: [ComparisonReference] = []
        var tags: [ComparisonReference] = []

        while true {
            try cancellation.check()
            var reference: OpaquePointer?
            let code = git_reference_next(&reference, iterator)
            if matches(code, GIT_ITEROVER) { break }
            try check(code, String(localized: "Could not read references."))
            guard let reference else { continue }
            defer { git_reference_free(reference) }
            guard let raw = git_reference_name(reference) else { continue }
            let full = String(cString: raw)

            let kind: ComparisonReference.Kind
            let name: String
            if full.hasPrefix("refs/heads/") {
                kind = .localBranch
                name = String(full.dropFirst("refs/heads/".count))
            } else if full.hasPrefix("refs/remotes/") {
                kind = .remoteBranch
                name = String(full.dropFirst("refs/remotes/".count))
            } else if full.hasPrefix("refs/tags/") {
                kind = .tag
                name = String(full.dropFirst("refs/tags/".count))
            } else {
                continue
            }

            let target = comparisonReferenceOID(reference)
            var annotated = false
            if kind == .tag, let target {
                var oid = target
                var type = GIT_OBJECT_INVALID
                var size = 0
                annotated = git_odb_read_header(&size, &type, database, &oid) == 0
                    && type == GIT_OBJECT_TAG
            }

            let item = ComparisonReference(
                name: name,
                reference: full,
                kind: kind,
                targetOID: target.map { format($0) },
                annotated: annotated,
                isCurrent: kind == .localBranch && full == current
            )
            switch kind {
            case .localBranch: local.append(item)
            case .remoteBranch: remote.append(item)
            case .tag: tags.append(item)
            case .head: break
            }
        }

        return local.sorted(by: { comparisonReferenceOrder($0, $1) })
            + remote.sorted(by: { comparisonReferenceOrder($0, $1) })
            + tags.sorted(by: { comparisonReferenceOrder($0, $1) })
    }

    static func comparisonReferenceOID(_ reference: OpaquePointer) -> git_oid? {
        if let target = git_reference_target(reference) { return target.pointee }
        guard git_reference_type(reference) == GIT_REFERENCE_SYMBOLIC else { return nil }
        var resolved: OpaquePointer?
        guard git_reference_resolve(&resolved, reference) == 0, let resolved else { return nil }
        defer { git_reference_free(resolved) }
        return git_reference_target(resolved)?.pointee
    }

    static func comparisonCurrentReferenceName(_ repo: OpaquePointer) -> String? {
        var head: OpaquePointer?
        guard git_reference_lookup(&head, repo, "HEAD") == 0, let head else { return nil }
        defer { git_reference_free(head) }
        return git_reference_symbolic_target(head).map { String(cString: $0) }
    }

    static func comparisonReferenceOrder(_ lhs: ComparisonReference,
                                         _ rhs: ComparisonReference) -> Bool {
        if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    static func comparisonIsHexDigit(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
    }
}

// Appended to the end of Gitling/GitClient.swift

// MARK: - Commit comparison file list and single-file diff

// Callback state is carried through the C payload as an unretained pointer; the
// local strong reference plus withExtendedLifetime keeps it alive during the call.
private final class ComparisonDiffBox {
    let cancellation: SearchCancellation
    let onCheckpoint: () -> Void
    let onGeneratedDelta: () -> Void
    let maximumFiles: Int
    var accepted = 0
    var truncated = false
    var cancelled = false

    init(cancellation: SearchCancellation, onCheckpoint: @escaping () -> Void, maximumFiles: Int, onGeneratedDelta: @escaping () -> Void) {
        self.cancellation = cancellation
        self.onCheckpoint = onCheckpoint
        self.onGeneratedDelta = onGeneratedDelta
        self.maximumFiles = maximumFiles
    }
}

private final class ComparisonPatchBox {
    let cancellation: SearchCancellation
    let onCheckpoint: () -> Void
    let maximumBytes: Int
    var text = ""
    var byteCount = 0
    var insertions = 0
    var deletions = 0
    var truncated = false
    var binary = false
    var notUTF8 = false
    var cancelled = false

    init(cancellation: SearchCancellation, onCheckpoint: @escaping () -> Void, maximumBytes: Int) {
        self.cancellation = cancellation
        self.onCheckpoint = onCheckpoint
        self.maximumBytes = maximumBytes
    }

    func checkpoint() -> Int32 {
        onCheckpoint()
        do {
            try cancellation.check()
        } catch {
            cancelled = true
            return -1
        }
        return 0
    }

    /// Appends one complete line only. The accumulated text always ends at a
    /// complete UTF-8 line boundary when the byte budget is hit.
    func append(_ line: String) -> Bool {
        guard !line.isEmpty else { return true }
        let bytes = line.utf8.count
        guard byteCount + bytes <= maximumBytes else {
            truncated = true
            return false
        }
        text += line
        byteCount += bytes
        return true
    }
}

private final class ComparisonBlob {
    let pointer: OpaquePointer

    init(_ pointer: OpaquePointer) {
        self.pointer = pointer
    }

    deinit { git_blob_free(pointer) }
}

private struct ComparisonLoadedSide {
    var present: Bool
    var kind: ComparisonContentKind
    var size: Int?
    var blob: ComparisonBlob?
    var symlinkTarget: String?
    var gitlinkOID: String?
}

extension GitClient {
    /// List changed files between two fixed commits without touching the worktree,
    /// index, refs, or network.
    ///
    /// Deltas are generated with `GIT_DIFF_INCLUDE_TYPECHANGE`. The notify callback
    /// returns non-zero after `limits.maximumFiles`, so the diff list itself never
    /// accumulates more than the budget and `fileCount` is marked explicitly. Rename
    /// detection runs only on a complete list and only after the added/deleted object
    /// headers fit the candidate count, total byte, and per-blob budgets. The actual
    /// `git_diff_find_similar` call is synchronous and not interruptible; cancellation
    /// is checked immediately before and after it and between generated rows.
    static func comparisonFiles(at repoURL: URL,
                                comparison: CommitComparison,
                                limits: ComparisonLimits = .standard,
                                cancellation: SearchCancellation = .init(),
                                onCheckpoint: @escaping () -> Void = {},
                                onGeneratedDelta: @escaping () -> Void = {}) throws -> ComparisonListResult {
        func checkpoint() throws {
            onCheckpoint()
            try cancellation.check()
        }

        try comparisonValidate(comparison, limits: limits)
        try checkpoint()
        _ = ready
        let opened = try OpenRepo(path: repoURL.path, access: nil)
        defer { withExtendedLifetime(opened) {} }
        let repo = opened.repo

        let trees = try comparisonTrees(repo, comparison, limits: limits)
        defer {
            git_tree_free(trees.old)
            git_tree_free(trees.new)
        }
        try checkpoint()

        var database: OpaquePointer?
        try check(git_repository_odb(&database, repo), String(localized: "Could not read the Git object database."))
        guard let database else {
            throw GitFailure.message(String(localized: "Could not read the Git object database."))
        }
        defer { git_odb_free(database) }

        let box = ComparisonDiffBox(cancellation: cancellation, onCheckpoint: onCheckpoint,
                                    maximumFiles: limits.maximumFiles, onGeneratedDelta: onGeneratedDelta)
        defer { withExtendedLifetime(box) {} }

        var options = git_diff_options()
        try check(git_diff_options_init(&options, UInt32(GIT_DIFF_OPTIONS_VERSION)),
                  String(localized: "Could not compare those commits."))
        options.flags = UInt32(GIT_DIFF_INCLUDE_TYPECHANGE.rawValue)
            | UInt32(GIT_DIFF_SKIP_BINARY_CHECK.rawValue)
        options.max_size = Int64(limits.maximumBlobBytes) + 1
        options.notify_cb = { _, _, _, payload in
            guard let payload else { return 0 }
            let box = Unmanaged<ComparisonDiffBox>.fromOpaque(payload).takeUnretainedValue()
            box.onGeneratedDelta()
            box.onCheckpoint()
            do {
                try box.cancellation.check()
            } catch {
                box.cancelled = true
                return -1
            }
            if box.accepted >= box.maximumFiles {
                box.truncated = true
                return 1 // skip this delta, keep the generated list bounded
            }
            box.accepted += 1
            return 0
        }
        options.progress_cb = { _, _, _, payload in
            guard let payload else { return 0 }
            let box = Unmanaged<ComparisonDiffBox>.fromOpaque(payload).takeUnretainedValue()
            box.onCheckpoint()
            do {
                try box.cancellation.check()
            } catch {
                box.cancelled = true
                return -1
            }
            return 0
        }
        options.payload = Unmanaged.passUnretained(box).toOpaque()

        var diff: OpaquePointer?
        defer { git_diff_free(diff) }
        let diffCode = git_diff_tree_to_tree(&diff, repo, trees.old, trees.new, &options)
        if box.cancelled { throw CancellationError() }
        try checkpoint()
        try check(diffCode, String(localized: "Could not compare those commits."))
        guard let diff else {
            throw GitFailure.message(String(localized: "Could not compare those commits."))
        }

        var limitsReached: Set<ComparisonLimitReason> = []
        var truncated = box.truncated
        if truncated { limitsReached.insert(.fileCount) }

        if !truncated, git_diff_num_deltas_of_type(diff, GIT_DELTA_ADDED) > 0,
           git_diff_num_deltas_of_type(diff, GIT_DELTA_DELETED) > 0 {
            let renamesReady = try comparisonRenamePreflight(diff, database: database, limits: limits) {
                try checkpoint()
            }
            if renamesReady {
                var find = git_diff_find_options()
                try check(git_diff_find_options_init(&find, UInt32(GIT_DIFF_FIND_OPTIONS_VERSION)),
                          String(localized: "Could not compare those commits."))
                find.flags = UInt32(GIT_DIFF_FIND_RENAMES.rawValue) // no copy detection
                find.rename_limit = limits.maximumRenameCandidates
                try checkpoint()
                // Synchronous and not interruptible once entered. The preflight above
                // bounds candidates and content sizes, but this is a heuristic bound.
                try check(git_diff_find_similar(diff, &find),
                          String(localized: "Could not compare those commits."))
                try checkpoint()
            } else {
                limitsReached.insert(.renameCandidates)
            }
        }

        let count = git_diff_num_deltas(diff)
        var files: [ComparisonFile] = []
        files.reserveCapacity(min(count, limits.maximumFiles))
        for index in 0..<count {
            try checkpoint()
            if files.count >= limits.maximumFiles {
                truncated = true
                limitsReached.insert(.fileCount)
                break
            }
            guard let delta = git_diff_get_delta(diff, index)?.pointee else { continue }
            files.append(try comparisonFile(base: comparison.base.oid,
                                            target: comparison.target.oid,
                                            delta: delta,
                                            database: database,
                                            limits: limits))
        }

        return ComparisonListResult(files: files, truncated: truncated,
                                    limitsReached: limitsReached, limits: limits)
    }

    /// Load one changed file from the fixed commit pair.
    ///
    /// The supplied row is verified against `git_tree_entry_bypath` metadata from
    /// both fixed trees before any blob is loaded. Object headers are read before
    /// every blob lookup, and a blob over `limits.maximumBlobBytes` is never loaded.
    /// Text patches use `git_diff_buffers` with the already-loaded blobs' raw bytes,
    /// so the diff has no repository context and cannot consult attributes or the
    /// index; line/hunk/file callbacks still stop at a complete UTF-8 line boundary
    /// at `limits.maximumPatchBytes`. This never uses the worktree, index, refs,
    /// checkout, or network, and never loads objects for any file except the selected row.
    static func comparisonFileDiff(at repoURL: URL,
                                   comparison: CommitComparison,
                                   file selectedFile: ComparisonFile,
                                   limits: ComparisonLimits = .standard,
                                   cancellation: SearchCancellation = .init(),
                                   onCheckpoint: @escaping () -> Void = {}) throws -> ComparisonFileDiff {
        func checkpoint() throws {
            onCheckpoint()
            try cancellation.check()
        }

        var file = selectedFile
        try comparisonValidate(comparison, limits: limits)
        guard file.baseOID.caseInsensitiveCompare(comparison.base.oid) == .orderedSame,
              file.targetOID.caseInsensitiveCompare(comparison.target.oid) == .orderedSame else {
            throw GitFailure.message(String(localized: "The selected file does not match this comparison."))
        }
        try checkpoint()
        _ = ready
        let opened = try OpenRepo(path: repoURL.path, access: nil)
        defer { withExtendedLifetime(opened) {} }
        let repo = opened.repo

        let trees = try comparisonTrees(repo, comparison, limits: limits)
        defer {
            git_tree_free(trees.old)
            git_tree_free(trees.new)
        }
        try checkpoint()

        let oldAbsent = file.change == .added
        let newAbsent = file.change == .deleted
        let oldPath: String? = oldAbsent ? nil : (file.oldPath ?? file.newPath)
        let newPath: String? = newAbsent ? nil : (file.newPath ?? file.oldPath)
        guard oldPath != nil || newPath != nil else {
            throw GitFailure.message(String(localized: "The selected file does not match this comparison."))
        }

        let oldEntry: IndexedFile?
        if let oldPath {
            try requireFilePath(oldPath)
            oldEntry = try indexedFile(trees.old, oldPath)
            guard let oldEntry else {
                throw GitFailure.message(String(localized: "The selected file does not match this comparison."))
            }
            guard comparisonOIDMatches(file.oldOID, oldEntry.oid) else {
                throw GitFailure.message(String(localized: "The selected file does not match this comparison."))
            }
            if file.oldMode != oldEntry.mode {
                throw GitFailure.message(String(localized: "The selected file does not match this comparison."))
            }
        } else {
            if let counterpart = newPath, try indexedFile(trees.old, counterpart) != nil {
                throw GitFailure.message(String(localized: "The selected file does not match this comparison."))
            }
            oldEntry = nil
        }

        let newEntry: IndexedFile?
        if let newPath {
            try requireFilePath(newPath)
            newEntry = try indexedFile(trees.new, newPath)
            guard let newEntry else {
                throw GitFailure.message(String(localized: "The selected file does not match this comparison."))
            }
            guard comparisonOIDMatches(file.newOID, newEntry.oid) else {
                throw GitFailure.message(String(localized: "The selected file does not match this comparison."))
            }
            if file.newMode != newEntry.mode {
                throw GitFailure.message(String(localized: "The selected file does not match this comparison."))
            }
        } else {
            if let counterpart = oldPath, try indexedFile(trees.new, counterpart) != nil {
                throw GitFailure.message(String(localized: "The selected file does not match this comparison."))
            }
            newEntry = nil
        }

        try comparisonValidateChange(file.change, oldEntry: oldEntry, newEntry: newEntry,
                                     oldPath: oldPath, newPath: newPath)

        if let oldEntry, let newEntry, oldPath == newPath,
           oldEntry.mode == newEntry.mode, oidsEqual(oldEntry.oid, newEntry.oid) {
            return ComparisonFileDiff(file: file, content: .unchanged)
        }

        var database: OpaquePointer?
        try check(git_repository_odb(&database, repo), String(localized: "Could not read the Git object database."))
        guard let database else {
            throw GitFailure.message(String(localized: "Could not read the Git object database."))
        }
        defer { git_odb_free(database) }

        try checkpoint()
        let oldSide = try comparisonLoadSide(repo, database: database, entry: oldEntry,
                                             absent: oldEntry == nil, limit: limits.maximumBlobBytes)
        try checkpoint()
        let newSide = try comparisonLoadSide(repo, database: database, entry: newEntry,
                                             absent: newEntry == nil, limit: limits.maximumBlobBytes)
        defer { withExtendedLifetime(oldSide) {}; withExtendedLifetime(newSide) {} }
        try checkpoint()

        file.oldContent = oldSide.kind; file.newContent = newSide.kind
        file.oldSize = oldSide.size; file.newSize = newSide.size
        if (oldSide.present && oldSide.kind == .missing) || (newSide.present && newSide.kind == .missing) {
            return ComparisonFileDiff(file: file, content: .missingObject)
        }
        if oldSide.kind == .tooLarge || newSide.kind == .tooLarge {
            return ComparisonFileDiff(file: file, content: .tooLarge(
                oldBytes: oldSide.size,
                newBytes: newSide.size
            ))
        }
        if oldSide.kind == .gitlink || newSide.kind == .gitlink {
            return ComparisonFileDiff(file: file, content: .gitlink(
                oldOID: oldSide.kind == .gitlink ? oldSide.gitlinkOID : nil,
                newOID: newSide.kind == .gitlink ? newSide.gitlinkOID : nil
            ))
        }
        if oldSide.kind == .symlink || newSide.kind == .symlink {
            return ComparisonFileDiff(file: file, content: .symlink(
                oldTarget: oldSide.kind == .symlink ? oldSide.symlinkTarget : nil,
                newTarget: newSide.kind == .symlink ? newSide.symlinkTarget : nil
            ))
        }
        if oldSide.kind == .directory || newSide.kind == .directory {
            return ComparisonFileDiff(file: file, content: .directory)
        }
        if oldSide.kind == .binary || newSide.kind == .binary {
            return ComparisonFileDiff(file: file, content: .binary)
        }
        if oldSide.kind == .notUTF8 || newSide.kind == .notUTF8 {
            return ComparisonFileDiff(file: file, content: .notUTF8)
        }
        if oldSide.kind == .unknown || newSide.kind == .unknown {
            return ComparisonFileDiff(file: file, content: .missingObject)
        }

        let header = comparisonPatchHeader(file: file, oldPath: oldPath, newPath: newPath,
                                           oldEntry: oldEntry, newEntry: newEntry)
        let box = ComparisonPatchBox(cancellation: cancellation, onCheckpoint: onCheckpoint,
                                     maximumBytes: limits.maximumPatchBytes)
        defer { withExtendedLifetime(box) {} }
        for line in header {
            if !box.append(line) { break }
        }
        if box.truncated {
            return ComparisonFileDiff(file: file, content: .patch(ComparisonPatch(
                text: box.text, truncated: true, insertions: 0, deletions: 0)))
        }

        var options = git_diff_options()
        try check(git_diff_options_init(&options, UInt32(GIT_DIFF_OPTIONS_VERSION)),
                  String(localized: "Could not compare this file."))
        options.max_size = Int64(limits.maximumBlobBytes) + 1

        let fileCallback: git_diff_file_cb = { _, _, payload in
            guard let payload else { return 0 }
            let box = Unmanaged<ComparisonPatchBox>.fromOpaque(payload).takeUnretainedValue()
            return box.checkpoint()
        }
        let binaryCallback: git_diff_binary_cb = { _, _, payload in
            guard let payload else { return 0 }
            let box = Unmanaged<ComparisonPatchBox>.fromOpaque(payload).takeUnretainedValue()
            let status = box.checkpoint()
            if status != 0 { return status }
            box.binary = true
            return 1
        }
        let hunkCallback: git_diff_hunk_cb = { _, hunk, payload in
            guard let payload else { return 0 }
            let box = Unmanaged<ComparisonPatchBox>.fromOpaque(payload).takeUnretainedValue()
            let status = box.checkpoint()
            if status != 0 { return status }
            guard let hunk else { return 0 }
            let header = GitClient.comparisonHunkHeader(hunk)
                .trimmingCharacters(in: CharacterSet.newlines)
            guard !header.isEmpty else { return 0 }
            return box.append(header + "\n") ? 0 : 1
        }
        let lineCallback: git_diff_line_cb = { _, _, line, payload in
            guard let payload, let line else { return 0 }
            let box = Unmanaged<ComparisonPatchBox>.fromOpaque(payload).takeUnretainedValue()
            let status = box.checkpoint()
            if status != 0 { return status }

            let origin = line.pointee.origin
            switch origin {
            case 32, 43, 45, 60, 61, 62:
                // context, addition, deletion, and the three EOF-newline markers
                break
            case 66:
                box.binary = true
                return 1
            default:
                // File and hunk headers are synthesized before the blob diff.
                return 0
            }

            guard let content = line.pointee.content, line.pointee.content_len > 0 else { return 0 }
            let data = Data(bytes: UnsafeRawPointer(content), count: Int(line.pointee.content_len))
            guard let text = String(data: data, encoding: .utf8) else {
                box.notUTF8 = true
                return -1
            }
            let prefix = origin == 43 ? "+" : origin == 45 ? "-" : origin == 32 ? " " : ""
            guard box.append(prefix + text) else { return 1 }
            if origin == 43 {
                box.insertions += 1
            } else if origin == 45 {
                box.deletions += 1
            }
            return 0
        }

        let oldName = oldPath ?? ""
        let newName = newPath ?? ""
        let oldBuffer = oldSide.blob.flatMap { git_blob_rawcontent($0.pointer) }
        let newBuffer = newSide.blob.flatMap { git_blob_rawcontent($0.pointer) }
        let oldSize = oldSide.blob.map { Int(git_blob_rawsize($0.pointer)) } ?? 0
        let newSize = newSide.blob.map { Int(git_blob_rawsize($0.pointer)) } ?? 0
        let code = oldName.withCString { oldPointer in
            newName.withCString { newPointer in
                git_diff_buffers(oldBuffer, oldSize, oldPointer,
                                 newBuffer, newSize, newPointer,
                                 &options,
                                 fileCallback, binaryCallback, hunkCallback, lineCallback,
                                 Unmanaged.passUnretained(box).toOpaque())
            }
        }

        if box.cancelled { throw CancellationError() }
        if box.notUTF8 { return ComparisonFileDiff(file: file, content: .notUTF8) }
        if box.binary { return ComparisonFileDiff(file: file, content: .binary) }
        if code < 0 && !box.truncated {
            try check(code, String(localized: "Could not compare this file."))
        }
        return ComparisonFileDiff(file: file, content: .patch(ComparisonPatch(
            text: box.text, truncated: box.truncated,
            insertions: box.insertions, deletions: box.deletions)))
    }
}

// MARK: - Comparison list and diff helpers

private extension GitClient {
    private static func comparisonValidate(_ comparison: CommitComparison,
                                   limits: ComparisonLimits) throws {
        try comparisonValidateOID(comparison.base.oid)
        try comparisonValidateOID(comparison.target.oid)
        try comparisonValidateLimits(limits)
    }

    private static func comparisonValidateOID(_ oid: String) throws {
        guard oid.count == 40, oid.utf8.allSatisfy({ comparisonIsHexDigit($0) }) else {
            throw GitFailure.message(String(localized: "Invalid comparison commit."))
        }
    }

    private static func comparisonValidateLimits(_ limits: ComparisonLimits) throws {
        let standard = ComparisonLimits.standard
        guard limits.maximumFiles > 0,
              limits.maximumFiles <= standard.maximumFiles,
              limits.maximumBlobBytes > 0,
              limits.maximumBlobBytes <= standard.maximumBlobBytes,
              limits.maximumPatchBytes > 0,
              limits.maximumPatchBytes <= standard.maximumPatchBytes,
              limits.maximumRenameCandidates > 0,
              limits.maximumRenameCandidates <= standard.maximumRenameCandidates,
              limits.maximumRenameBytes > 0,
              limits.maximumRenameBytes <= standard.maximumRenameBytes,
              limits.maximumTagPeelDepth > 0,
              limits.maximumTagPeelDepth <= standard.maximumTagPeelDepth,
              limits.maximumMetadataBytes > 0,
              limits.maximumMetadataBytes <= standard.maximumMetadataBytes else {
            throw GitFailure.message(String(localized: "Invalid comparison limits."))
        }
    }

    private static func comparisonTrees(_ repo: OpaquePointer,
                                _ comparison: CommitComparison, limits: ComparisonLimits) throws -> (old: OpaquePointer, new: OpaquePointer) {
        let old = try comparisonTree(repo, oid: comparison.base.oid, limit: limits.maximumMetadataBytes)
        do {
            let new = try comparisonTree(repo, oid: comparison.target.oid, limit: limits.maximumMetadataBytes)
            return (old, new)
        } catch {
            git_tree_free(old)
            throw error
        }
    }

    private static func comparisonTree(_ repo: OpaquePointer, oid: String, limit: Int) throws -> OpaquePointer {
        var value = git_oid()
        guard git_oid_fromstr(&value, oid) == 0 else {
            throw GitFailure.message(String(localized: "Could not read that commit."))
        }
        var database: OpaquePointer?
        try check(git_repository_odb(&database, repo), String(localized: "Could not read the Git object database."))
        defer { git_odb_free(database) }
        var size = 0, type = GIT_OBJECT_INVALID
        try check(git_odb_read_header(&size, &type, database, &value), String(localized: "Could not read that object."))
        guard type == GIT_OBJECT_COMMIT, size <= limit else { throw GitFailure.message(String(localized: "Invalid comparison commit.")) }
        var commit: OpaquePointer?
        try check(git_commit_lookup(&commit, repo, &value),
                  String(localized: "Could not read that commit."))
        guard let commit else {
            throw GitFailure.message(String(localized: "Could not read that commit."))
        }
        defer { git_commit_free(commit) }
        var tree: OpaquePointer?
        try check(git_commit_tree(&tree, commit),
                  String(localized: "Could not read that commit."))
        guard let tree else {
            throw GitFailure.message(String(localized: "Could not read that commit."))
        }
        return tree
    }

    private static func comparisonFile(base: String,
                               target: String,
                               delta: git_diff_delta,
                               database: OpaquePointer,
                               limits: ComparisonLimits) throws -> ComparisonFile {
        let status = delta.status
        let oldPresent = status != GIT_DELTA_ADDED
        let newPresent = status != GIT_DELTA_DELETED
        let rawOldPath = delta.old_file.path.map { String(cString: $0) }
        let rawNewPath = delta.new_file.path.map { String(cString: $0) }
        let oldPath = oldPresent ? (rawOldPath ?? rawNewPath) : nil
        let newPath = newPresent ? (rawNewPath ?? rawOldPath) : nil
        let oldMode = oldPresent ? UInt32(delta.old_file.mode) : nil
        let newMode = newPresent ? UInt32(delta.new_file.mode) : nil
        let oldOID = oldPresent ? comparisonOID(delta.old_file) : nil
        let newOID = newPresent ? comparisonOID(delta.new_file) : nil
        let oldInfo = try comparisonSideInfo(delta.old_file, present: oldPresent, mode: oldMode,
                                             database: database, limits: limits)
        let newInfo = try comparisonSideInfo(delta.new_file, present: newPresent, mode: newMode,
                                             database: database, limits: limits)
        let change = comparisonChange(status: status, oldOID: oldOID, newOID: newOID,
                                      oldMode: oldMode, newMode: newMode)
        return ComparisonFile(
            baseOID: base, targetOID: target, change: change,
            oldPath: oldPath, newPath: newPath,
            oldMode: oldMode, newMode: newMode,
            oldOID: oldOID, newOID: newOID,
            oldSize: oldInfo.size, newSize: newInfo.size,
            oldContent: oldInfo.content, newContent: newInfo.content,
            similarity: status == GIT_DELTA_RENAMED ? Int(delta.similarity) : nil
        )
    }

    private static func comparisonOID(_ file: git_diff_file) -> String? {
        let value = format(file.id)
        if value == String(repeating: "0", count: 40) { return nil }
        return value
    }

    private static func comparisonSideInfo(_ file: git_diff_file,
                                   present: Bool,
                                   mode: UInt32?,
                                   database: OpaquePointer,
                                   limits: ComparisonLimits) throws -> (content: ComparisonContentKind, size: Int?) {
        guard present, let mode else { return (.missing, nil) }
        if mode == UInt32(GIT_FILEMODE_COMMIT.rawValue) { return (.gitlink, nil) }
        if (mode & 0o170000) == 0o040000 { return (.directory, nil) }

        var oid = file.id
        var type = GIT_OBJECT_INVALID
        var size = 0
        let header = git_odb_read_header(&size, &type, database, &oid)
        if matches(header, GIT_ENOTFOUND) { return (.missing, nil) }
        try check(header, String(localized: "Could not read that object."))
        if type == GIT_OBJECT_COMMIT { return (.gitlink, size) }
        if type == GIT_OBJECT_TREE { return (.directory, size) }
        guard type == GIT_OBJECT_BLOB else { return (.unknown, size) }
        if size > limits.maximumBlobBytes { return (.tooLarge, size) }
        if mode == UInt32(GIT_FILEMODE_LINK.rawValue) { return (.symlink, size) }
        return (.unknown, size)
    }

    private static func comparisonChange(status: git_delta_t,
                                 oldOID: String?,
                                 newOID: String?,
                                 oldMode: UInt32?,
                                 newMode: UInt32?) -> ComparisonChangeKind {
        if status == GIT_DELTA_ADDED { return .added }
        if status == GIT_DELTA_DELETED { return .deleted }
        if status == GIT_DELTA_RENAMED { return .renamed }
        if status == GIT_DELTA_TYPECHANGE { return .typeChanged }
        if status == GIT_DELTA_MODIFIED {
            if let oldOID, let newOID, oldOID == newOID,
               let oldMode, let newMode, oldMode != newMode {
                return .modeChanged
            }
            return .modified
        }
        return .other
    }

    /// Header-only preflight for rename detection. No blob content is loaded here;
    /// missing/oversized/non-blob candidates, too many candidates, or too many total
    /// header bytes disable renames with an explicit `renameCandidates` reason.
    private static func comparisonRenamePreflight(_ diff: OpaquePointer,
                                          database: OpaquePointer,
                                          limits: ComparisonLimits,
                                          checkpoint: () throws -> Void) throws -> Bool {
        var candidates = 0
        var total = 0
        for index in 0..<git_diff_num_deltas(diff) {
            try checkpoint()
            guard let delta = git_diff_get_delta(diff, index)?.pointee else { continue }

            let file: git_diff_file
            let mode: UInt32
            if delta.status == GIT_DELTA_ADDED {
                file = delta.new_file
                mode = UInt32(delta.new_file.mode)
            } else if delta.status == GIT_DELTA_DELETED {
                file = delta.old_file
                mode = UInt32(delta.old_file.mode)
            } else {
                continue
            }

            candidates += 1
            if candidates > limits.maximumRenameCandidates { return false }
            let typeBits = mode & 0o170000
            guard typeBits == 0o100000 || typeBits == 0o120000 else { continue }

            var oid = file.id
            var type = GIT_OBJECT_INVALID
            var size = 0
            guard git_odb_read_header(&size, &type, database, &oid) == 0,
                  type == GIT_OBJECT_BLOB,
                  size <= limits.maximumBlobBytes else {
                return false
            }
            total += size
            if total > limits.maximumRenameBytes { return false }
        }
        return true
    }

    private static func comparisonOIDMatches(_ expected: String?, _ actual: git_oid) -> Bool {
        guard let expected, expected != String(repeating: "0", count: 40) else { return false }
        return expected.caseInsensitiveCompare(format(actual)) == .orderedSame
    }

    private static func comparisonValidateChange(_ change: ComparisonChangeKind,
                                         oldEntry: IndexedFile?,
                                         newEntry: IndexedFile?,
                                         oldPath: String?,
                                         newPath: String?) throws {
        let mismatch = GitFailure.message(String(localized: "The selected file does not match this comparison."))
        switch change {
        case .added:
            guard oldEntry == nil, newEntry != nil else { throw mismatch }
        case .deleted:
            guard oldEntry != nil, newEntry == nil else { throw mismatch }
        case .renamed:
            guard oldEntry != nil, newEntry != nil,
                  let oldPath, let newPath, oldPath != newPath else { throw mismatch }
        case .typeChanged:
            guard let oldEntry, let newEntry,
                  comparisonFileType(oldEntry.mode) != comparisonFileType(newEntry.mode) else {
                throw mismatch
            }
        case .modeChanged:
            guard let oldEntry, let newEntry,
                  comparisonFileType(oldEntry.mode) == comparisonFileType(newEntry.mode),
                  oldEntry.mode != newEntry.mode,
                  oidsEqual(oldEntry.oid, newEntry.oid) else {
                throw mismatch
            }
        case .modified:
            guard oldEntry != nil, newEntry != nil else { throw mismatch }
        case .other:
            break
        }
    }

    private static func comparisonFileType(_ mode: UInt32) -> UInt32 {
        mode & 0o170000
    }

    private static func comparisonLoadSide(_ repo: OpaquePointer,
                                   database: OpaquePointer,
                                   entry: IndexedFile?,
                                   absent: Bool,
                                   limit: Int) throws -> ComparisonLoadedSide {
        guard !absent, let entry else {
            return ComparisonLoadedSide(present: false, kind: .missing, size: nil,
                                        blob: nil, symlinkTarget: nil, gitlinkOID: nil)
        }
        if entry.mode == UInt32(GIT_FILEMODE_COMMIT.rawValue) || entry.type == GIT_OBJECT_COMMIT {
            return ComparisonLoadedSide(present: true, kind: .gitlink, size: nil,
                                        blob: nil, symlinkTarget: nil, gitlinkOID: format(entry.oid))
        }
        if entry.mode == UInt32(GIT_FILEMODE_TREE.rawValue) || entry.type == GIT_OBJECT_TREE {
            return ComparisonLoadedSide(present: true, kind: .directory, size: nil,
                                        blob: nil, symlinkTarget: nil, gitlinkOID: nil)
        }
        guard entry.type == GIT_OBJECT_BLOB else {
            return ComparisonLoadedSide(present: true, kind: .missing, size: nil,
                                        blob: nil, symlinkTarget: nil, gitlinkOID: nil)
        }

        var oid = entry.oid
        var type = GIT_OBJECT_INVALID
        var size = 0
        let header = git_odb_read_header(&size, &type, database, &oid)
        if matches(header, GIT_ENOTFOUND) {
            return ComparisonLoadedSide(present: true, kind: .missing, size: nil,
                                        blob: nil, symlinkTarget: nil, gitlinkOID: nil)
        }
        try check(header, String(localized: "Could not read that object."))
        guard type == GIT_OBJECT_BLOB else {
            return ComparisonLoadedSide(present: true, kind: .missing, size: nil,
                                        blob: nil, symlinkTarget: nil, gitlinkOID: nil)
        }
        if size > limit {
            return ComparisonLoadedSide(present: true, kind: .tooLarge, size: size,
                                        blob: nil, symlinkTarget: nil, gitlinkOID: nil)
        }

        var blob: OpaquePointer?
        let lookup = git_blob_lookup(&blob, repo, &oid)
        if matches(lookup, GIT_ENOTFOUND) {
            return ComparisonLoadedSide(present: true, kind: .missing, size: size,
                                        blob: nil, symlinkTarget: nil, gitlinkOID: nil)
        }
        try check(lookup, String(localized: "Could not read that object."))
        guard let blob else {
            return ComparisonLoadedSide(present: true, kind: .missing, size: size,
                                        blob: nil, symlinkTarget: nil, gitlinkOID: nil)
        }
        let rawSize = Int(git_blob_rawsize(blob))
        if rawSize > limit {
            git_blob_free(blob)
            return ComparisonLoadedSide(present: true, kind: .tooLarge, size: rawSize,
                                        blob: nil, symlinkTarget: nil, gitlinkOID: nil)
        }

        if entry.mode == UInt32(GIT_FILEMODE_LINK.rawValue) {
            let data = comparisonBlobData(blob)
            git_blob_free(blob)
            guard let data else {
                return ComparisonLoadedSide(present: true, kind: .missing, size: rawSize,
                                            blob: nil, symlinkTarget: nil, gitlinkOID: nil)
            }
            guard let target = String(data: data, encoding: .utf8) else {
                return ComparisonLoadedSide(present: true, kind: .notUTF8, size: rawSize,
                                            blob: nil, symlinkTarget: nil, gitlinkOID: nil)
            }
            return ComparisonLoadedSide(present: true, kind: .symlink, size: rawSize,
                                        blob: nil, symlinkTarget: target, gitlinkOID: nil)
        }

        if git_blob_is_binary(blob) == 1 {
            git_blob_free(blob)
            return ComparisonLoadedSide(present: true, kind: .binary, size: rawSize,
                                        blob: nil, symlinkTarget: nil, gitlinkOID: nil)
        }
        guard let data = comparisonBlobData(blob) else {
            git_blob_free(blob)
            return ComparisonLoadedSide(present: true, kind: .missing, size: rawSize,
                                        blob: nil, symlinkTarget: nil, gitlinkOID: nil)
        }
        guard String(data: data, encoding: .utf8) != nil else {
            git_blob_free(blob)
            return ComparisonLoadedSide(present: true, kind: .notUTF8, size: rawSize,
                                        blob: nil, symlinkTarget: nil, gitlinkOID: nil)
        }
        return ComparisonLoadedSide(present: true, kind: .text, size: rawSize,
                                    blob: ComparisonBlob(blob), symlinkTarget: nil, gitlinkOID: nil)
    }

    private static func comparisonBlobData(_ blob: OpaquePointer) -> Data? {
        let size = Int(git_blob_rawsize(blob))
        if size == 0 { return Data() }
        guard size <= FileInspection.maximumBytes,
              let pointer = git_blob_rawcontent(blob) else { return nil }
        return Data(bytes: pointer, count: size)
    }

    private static func comparisonPatchHeader(file: ComparisonFile,
                                      oldPath: String?,
                                      newPath: String?,
                                      oldEntry: IndexedFile?,
                                      newEntry: IndexedFile?) -> [String] {
        let oldName = oldPath ?? newPath ?? ""
        let newName = newPath ?? oldPath ?? ""
        var lines: [String] = []
        lines.append("diff --git \(comparisonQuotedPath("a/" + oldName)) \(comparisonQuotedPath("b/" + newName))\n")

        let oldMode = oldEntry.map { $0.mode }
        let newMode = newEntry.map { $0.mode }
        if oldEntry == nil, let newMode {
            lines.append("new file mode \(String(newMode, radix: 8))\n")
        } else if newEntry == nil, let oldMode {
            lines.append("deleted file mode \(String(oldMode, radix: 8))\n")
        } else if let oldMode, let newMode {
            if let oldPath, let newPath, oldPath != newPath {
                if let similarity = file.similarity {
                    lines.append("similarity index \(similarity)%\n")
                }
                lines.append("rename from \(comparisonQuotedPath(oldPath))\n")
                lines.append("rename to \(comparisonQuotedPath(newPath))\n")
            }
            if oldMode != newMode {
                lines.append("old mode \(String(oldMode, radix: 8))\n")
                lines.append("new mode \(String(newMode, radix: 8))\n")
            }
        }

        lines.append(oldEntry == nil ? "--- /dev/null\n" : "--- \(comparisonQuotedPath("a/" + oldName))\n")
        lines.append(newEntry == nil ? "+++ /dev/null\n" : "+++ \(comparisonQuotedPath("b/" + newName))\n")
        return lines
    }

    private static func comparisonQuotedPath(_ path: String) -> String {
        guard path.unicodeScalars.contains(where: { $0.value <= 32 || $0.value == 127 || $0 == "\"" || $0 == "\\" }) else { return path }
        var quoted = "\""
        for scalar in path.unicodeScalars {
            switch scalar.value {
            case 34: quoted += "\\\""
            case 92: quoted += "\\\\"
            case 10: quoted += "\\n"
            case 13: quoted += "\\r"
            case 9: quoted += "\\t"
            case 0..<32, 127: quoted += String(format: "\\%03o", scalar.value)
            default: quoted.unicodeScalars.append(scalar)
            }
        }
        return quoted + "\""
    }

    private static func comparisonHunkHeader(_ hunk: UnsafePointer<git_diff_hunk>) -> String {
        let length = min(Int(hunk.pointee.header_len), 128)
        var header = hunk.pointee.header
        let bytes: [UInt8] = withUnsafeBytes(of: &header) { raw in
            var slice = Array(raw.prefix(length))
            while slice.last == 0 { slice.removeLast() }
            return slice
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
