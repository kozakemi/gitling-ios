import Clibgit2
import CryptoKit
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

struct CommitInfo: Identifiable, Hashable, Codable {
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

struct StatusEntry: Identifiable, Hashable, Codable {
    var id: String { path }
    var path: String
    var staged: Bool
    var unstaged: Bool
    var untracked: Bool
}

struct WorkEntry: Identifiable, Hashable {
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

    static func initialize(name: String, root: URL, bare: Bool = false, worktreeBookmark: Data? = nil) throws {
        let destination = try destinationURL(name: name, root: root)
        try writing(destination) {
            try locked {
                var repo: OpaquePointer?
                let code = git_repository_init(&repo, destination.path, bare ? 1 : 0)
                try check(code, String(localized: "Could not create repository"))
                if let repo, !bare {
                    tune(repo)
                    if let worktreeBookmark {
                        try attach(repo, repoURL: destination, bookmark: worktreeBookmark)
                    }
                    git_repository_free(repo)
                } else {
                    git_repository_free(repo)
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
        worktreeBookmark: Data? = nil
    ) throws {
        let destination = try destinationURL(name: name, root: root)
        try writing(destination) {
            var succeeded = false
            defer {
                if !succeeded {
                    try? FileManager.default.removeItem(at: destination)
                }
            }
            try locked {
            let box = CredentialBox(username: username, secret: secret, sshKey: sshKey)
            var options = git_clone_options()
            try check(
                git_clone_options_init(&options, UInt32(GIT_CLONE_OPTIONS_VERSION)),
                String(localized: "Could not clone")
            )
            applyTransport(&options.fetch_opts.callbacks, box: box)
            var repo: OpaquePointer?
            let code = git_clone(&repo, url, destination.path, &options)
            try check(code, String(localized: "Could not clone"))
            if let repo {
                tune(repo)
                if let worktreeBookmark {
                    try attach(repo, repoURL: destination, bookmark: worktreeBookmark)
                }
                git_repository_free(repo)
            }
            }
            succeeded = true
            try LFSClient.smudge(at: destination, remoteURL: url, auth: lfsAuth)
        }
    }

    static func link(at repoURL: URL, bookmark: Data) throws {
        try writing(repoURL) {
            try locked {
                let opened = try open(repoURL, applyingLink: false)
                defer { withExtendedLifetime(opened) {} }
                try attach(opened.repo, repoURL: repoURL, bookmark: bookmark)
            }
        }
    }

    static func unlink(at repoURL: URL) throws {
        try writing(repoURL) {
            try locked {
                let opened = try open(repoURL, applyingLink: false)
                defer { withExtendedLifetime(opened) {} }
                try check(
                    git_repository_set_workdir(opened.repo, repoURL.path, 0),
                    String(localized: "Could not use that folder.")
                )
                try checkoutHead(opened.repo)
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
            } else {
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

    static func diff(at repoURL: URL) throws -> String {
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
            try check(
                git_diff_tree_to_workdir_with_index(&diff, repo, tree, &options),
                String(localized: "Could not read changes")
            )
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
            var index: OpaquePointer?
            try check(git_repository_index(&index, repo), String(localized: "Could not stage files"))
            defer { git_index_free(index) }
            try check(git_index_add_all(index, nil, 0, nil, nil), String(localized: "Could not stage files"))
            try applyLFSClean(repoURL: repoURL, repo: repo, index: index!, auth: lfsAuth)
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
            let entries = try statusUnlocked(repo)
            guard entries.contains(where: \.staged) else {
                throw GitFailure.message(String(localized: "Nothing to commit"))
            }
            var index: OpaquePointer?
            try check(git_repository_index(&index, repo), String(localized: "Could not commit"))
            defer { git_index_free(index) }
            try applyLFSClean(repoURL: repoURL, repo: repo, index: index!, auth: lfsAuth)
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
        email: String
    ) throws {
        try writing(repoURL) {
        try locked {
            let opened = try open(repoURL)
            defer { withExtendedLifetime(opened) {} }
            let repo = opened.repo
            let upstream = try fetchUpstream(repo, username: username, secret: secret, sshKey: sshKey)
            defer { git_reference_free(upstream) }
            var annotated: OpaquePointer?
            try check(
                git_annotated_commit_from_ref(&annotated, repo, upstream),
                String(localized: "Could not pull")
            )
            defer { git_annotated_commit_free(annotated) }
            let analysis = try mergeAnalysis(repo, annotated: annotated)
            if analysis.upToDate { return }
            if analysis.fastForward {
                try fastForward(repo, to: upstream)
                return
            }
            if analysis.normal {
                guard !name.isEmpty, !email.isEmpty else {
                    throw GitFailure.message(String(localized: "Set your name and email in Settings before committing."))
                }
                try merge(repo, annotated: annotated, name: name, email: email)
                return
            }
            throw GitFailure.message(String(localized: "Could not pull"))
        }
        try LFSClient.smudge(at: repoURL, remoteURL: try originURL(repoURL), auth: lfsAuth)
        }
    }

    static func push(
        at repoURL: URL,
        username: String,
        secret: String,
        sshKey: SSHKeyMaterial? = nil,
        lfsAuth: LFSAuth? = nil
    ) throws {
        try writing(repoURL) {
        try locked {
            let handle = try open(repoURL)
            defer { withExtendedLifetime(handle) {} }
            let repo = handle.repo
            let branch = try currentBranch(repo)
            var remote: OpaquePointer?
            let lookup = git_remote_lookup(&remote, repo, "origin")
            if lookup < 0 {
                throw GitFailure.message(String(localized: "This repository has no origin remote."))
            }
            defer { git_remote_free(remote) }

            let box = CredentialBox(username: username, secret: secret, sshKey: sshKey)
            var options = git_push_options()
            try check(git_push_options_init(&options, UInt32(GIT_PUSH_OPTIONS_VERSION)), String(localized: "Could not push"))
            applyTransport(&options.callbacks, box: box)

            let spec = "refs/heads/\(branch):refs/heads/\(branch)"
            try withRefspec(spec) { refspecs in
                try check(git_remote_push(remote, refspecs, &options), String(localized: "Could not push"))
            }

            var branchRef: OpaquePointer?
            if git_branch_lookup(&branchRef, repo, branch, GIT_BRANCH_LOCAL) == 0 {
                defer { git_reference_free(branchRef) }
                git_branch_set_upstream(branchRef, "origin/\(branch)")
            }
        }
        }
    }

    static func fetch(
        at repoURL: URL,
        username: String,
        secret: String,
        sshKey: SSHKeyMaterial? = nil,
        lfsAuth: LFSAuth? = nil
    ) throws {
        try writing(repoURL) {
            try locked {
                let opened = try open(repoURL)
                defer { withExtendedLifetime(opened) {} }
                try fetchOrigin(opened.repo, username: username, secret: secret, sshKey: sshKey)
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
            let current = try? currentBranch(opened.repo)
            var iterator: OpaquePointer?
            try check(
                git_branch_iterator_new(&iterator, opened.repo, GIT_BRANCH_ALL),
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
    }

    static func createBranch(at repoURL: URL, name branch: String, checkout: Bool) throws {
        let branch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branch.isEmpty, !branch.contains("/"), !branch.contains("..") else {
            throw GitFailure.message(String(localized: "Enter a branch name."))
        }
        try writing(repoURL) {
            try locked {
                let opened = try open(repoURL)
                defer { withExtendedLifetime(opened) {} }
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
                let started = git_rebase_init(&rebase, repo, nil, onto, nil, &options)
                if started < 0 {
                    try check(started, String(localized: "Could not rebase."))
                }
                defer { git_rebase_free(rebase) }
                var signature: UnsafeMutablePointer<git_signature>?
                try check(git_signature_now(&signature, name, email), String(localized: "Could not rebase."))
                defer { git_signature_free(signature) }
                while true {
                    var operation: UnsafeMutablePointer<git_rebase_operation>?
                    let step = git_rebase_next(&operation, rebase)
                    if matches(step, GIT_ITEROVER) { break }
                    if step < 0 {
                        git_rebase_abort(rebase)
                        try check(step, String(localized: "Could not rebase."))
                    }
                    if indexHasConflicts(repo) {
                        let paths = conflictPaths(repo)
                        git_rebase_abort(rebase)
                        throw GitFailure.message(conflictMessage(
                            String(localized: "The rebase produced conflicts. The branch was left unchanged."),
                            paths: paths
                        ))
                    }
                    var commit = git_oid()
                    let written = git_rebase_commit(&commit, rebase, nil, signature, nil, nil)
                    if matches(written, GIT_EAPPLIED) { continue }
                    if matches(written, GIT_EUNMERGED) || written < 0 {
                        let paths = conflictPaths(repo)
                        git_rebase_abort(rebase)
                        if matches(written, GIT_EUNMERGED) {
                            throw GitFailure.message(conflictMessage(
                                String(localized: "The rebase produced conflicts. The branch was left unchanged."),
                                paths: paths
                            ))
                        }
                        try check(written, String(localized: "Could not rebase."))
                    }
                }
                try check(git_rebase_finish(rebase, signature), String(localized: "Could not rebase."))
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
                let picked = git_cherrypick(repo, commit, &options)
                let conflicted = indexHasConflicts(repo) || matches(picked, GIT_ECONFLICT)
                if picked < 0 || conflicted {
                    let paths = conflictPaths(repo)
                    abortCherryPick(repo)
                    if conflicted {
                        throw GitFailure.message(conflictMessage(
                            String(localized: "The cherry-pick produced conflicts. The branch was left unchanged."),
                            paths: paths
                        ))
                    }
                    try check(picked, String(localized: "Could not cherry-pick that commit."))
                }
                var index: OpaquePointer?
                try check(git_repository_index(&index, repo), String(localized: "Could not cherry-pick that commit."))
                defer { git_index_free(index) }
                try check(git_index_write(index), String(localized: "Could not cherry-pick that commit."))
                var tree = git_oid()
                try check(git_index_write_tree(&tree, index), String(localized: "Could not cherry-pick that commit."))
                guard let head = try headCommit(repo) else {
                    git_repository_state_cleanup(repo)
                    throw GitFailure.message(String(localized: "No commits yet"))
                }
                defer { git_commit_free(head) }
                let message = git_commit_message(commit).map { String(cString: $0) } ?? ""
                try writeCommit(repo: repo, tree: tree, parents: [head], message: message, name: name, email: email)
                git_repository_state_cleanup(repo)
            }
        }
    }

    static func resetHard(at repoURL: URL) throws {
        try writing(repoURL) {
            try locked {
                let opened = try open(repoURL)
                defer { withExtendedLifetime(opened) {} }
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
            var names = git_strarray()
            try check(git_remote_list(&names, opened.repo), String(localized: "Could not read remotes."))
            defer { git_strarray_dispose(&names) }
            var listed: [RemoteInfo] = []
            let count = Int(names.count)
            guard let strings = names.strings else { return [] }
            for index in 0..<count {
                guard let pointer = strings[index] else { continue }
                let name = String(cString: pointer)
                var remote: OpaquePointer?
                guard git_remote_lookup(&remote, opened.repo, name) == 0, let remote else { continue }
                let url = git_remote_url(remote).map { String(cString: $0) } ?? ""
                git_remote_free(remote)
                listed.append(RemoteInfo(name: name, url: url))
            }
            return listed
        }
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
            let text = (try? diff(at: repoURL)) ?? ""
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
        let branch = (try? locked {
            let opened = try open(repoURL)
            defer { withExtendedLifetime(opened) {} }
            return try currentBranch(opened.repo)
        }) ?? String(localized: "No commits yet")
        let entries = try status(at: repoURL)
        return statusText(entries: entries, branch: branch, sync: syncCounts(at: repoURL))
    }

    static func statusText(entries: [StatusEntry], branch: String, sync: SyncCounts?) -> String {
        var lines = [String(format: String(localized: "On branch %@"), branch)]
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
        let access = WorktreeLink.begin(repoName: repoURL.lastPathComponent)
        defer { access?.stop() }
        let url = (access?.url ?? repoURL).appendingPathComponent(relative)
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        if size > 256 * 1024 {
            throw GitFailure.message(String(localized: "This file is too large to preview."))
        }
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw GitFailure.message(String(localized: "This file is not UTF-8 text."))
        }
        return text
    }

    private static func originURL(_ repoURL: URL) throws -> String {
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

    static func summary(at repoURL: URL) -> RepoSummary? {
        try? summarize(at: repoURL)
    }

    private static func summarize(at url: URL) throws -> RepoSummary {
        try locked {
            let opened = try open(url)
            defer { withExtendedLifetime(opened) {} }
            let repo = opened.repo
            let branch = try? currentBranch(repo)
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

    private static func open(_ url: URL, applyingLink: Bool = true) throws -> OpenRepo {
        let access = applyingLink ? WorktreeLink.begin(repoName: url.lastPathComponent) : nil
        do {
            return try OpenRepo(path: url.path, access: access)
        } catch {
            access?.stop()
            throw error
        }
    }

    private static func attach(_ repo: OpaquePointer, repoURL: URL, bookmark: Data) throws {
        let access = try WorktreeLink.makeAccess(from: bookmark, repoName: repoURL.lastPathComponent)
        defer { access.stop() }
        try useWorkDirectory(access, repo: repo)
        try removeWorkingFiles(at: repoURL)
        try WorktreeLink.save(repoName: repoURL.lastPathComponent, data: bookmark)
    }

    private static func useWorkDirectory(_ access: WorktreeLink.Access, repo: OpaquePointer) throws {
        try FileManager.default.createDirectory(at: access.url, withIntermediateDirectories: true)
        try check(
            git_repository_set_workdir(repo, access.url.path, 0),
            String(localized: "Could not use that folder.")
        )
        let gitlink = access.url.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: gitlink.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            try? FileManager.default.removeItem(at: gitlink)
        }
        let scope = access.scope.standardizedFileURL.path
        let work = access.url.standardizedFileURL.path
        guard scope != work, isEffectivelyEmpty(access.url) else { return }
        try checkoutHead(repo)
        removeIdenticalCopies(from: access.scope, matching: access.url, protecting: access.url)
    }

    private static func isEffectivelyEmpty(_ url: URL) -> Bool {
        let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        return items.allSatisfy { $0.lastPathComponent == ".DS_Store" }
    }

    /// Drops files left in the chosen folder by an older checkout, when the repository folder now has the same bytes.
    private static func removeIdenticalCopies(from parent: URL, matching child: URL, protecting workRoot: URL) {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: child,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey]
        )) ?? []
        for item in items {
            let counterpart = parent.appendingPathComponent(item.lastPathComponent)
            if counterpart.standardizedFileURL.path == workRoot.standardizedFileURL.path { continue }
            guard FileManager.default.fileExists(atPath: counterpart.path) else { continue }
            let childIsDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            var parentIsDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: counterpart.path, isDirectory: &parentIsDirectory)
            if childIsDirectory && parentIsDirectory.boolValue {
                removeIdenticalCopies(from: counterpart, matching: item, protecting: workRoot)
                let left = (try? FileManager.default.contentsOfDirectory(at: counterpart, includingPropertiesForKeys: nil)) ?? []
                if left.isEmpty { try? FileManager.default.removeItem(at: counterpart) }
            } else if !childIsDirectory && !parentIsDirectory.boolValue && sameBytes(item, counterpart) {
                try? FileManager.default.removeItem(at: counterpart)
            }
        }
    }

    private static func sameBytes(_ lhs: URL, _ rhs: URL) -> Bool {
        let lhsSize = (try? lhs.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
        let rhsSize = (try? rhs.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
        guard lhsSize == rhsSize, lhsSize >= 0, lhsSize <= 8_000_000 else { return false }
        guard let left = try? Data(contentsOf: lhs), let right = try? Data(contentsOf: rhs) else { return false }
        return left == right
    }

    private static func fetchOrigin(
        _ repo: OpaquePointer,
        username: String,
        secret: String,
        sshKey: SSHKeyMaterial?
    ) throws {
        var remote: OpaquePointer?
        if git_remote_lookup(&remote, repo, "origin") < 0 {
            throw GitFailure.message(String(localized: "This repository has no origin remote."))
        }
        defer { git_remote_free(remote) }
        let box = CredentialBox(username: username, secret: secret, sshKey: sshKey)
        var fetch = git_fetch_options()
        try check(git_fetch_options_init(&fetch, UInt32(GIT_FETCH_OPTIONS_VERSION)), String(localized: "Could not pull"))
        applyTransport(&fetch.callbacks, box: box)
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

    private static func checkoutHead(_ repo: OpaquePointer) throws {
        var options = git_checkout_options()
        try check(
            git_checkout_options_init(&options, UInt32(GIT_CHECKOUT_OPTIONS_VERSION)),
            String(localized: "Could not use that folder.")
        )
        options.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue | GIT_CHECKOUT_RECREATE_MISSING.rawValue
        let code = git_checkout_head(repo, &options)
        if matches(code, GIT_EUNBORNBRANCH) || matches(code, GIT_ENOTFOUND) { return }
        try check(code, String(localized: "Could not use that folder."))
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

    private static func applyLFSClean(
        repoURL: URL,
        repo: OpaquePointer,
        index: OpaquePointer,
        auth: LFSAuth?
    ) throws {
        guard let remote = originURLUnlocked(repo) else { return }
        let pointers = try LFSClient.clean(at: repoURL, remoteURL: remote, auth: auth)
        guard !pointers.isEmpty else { return }
        for (path, pointer) in pointers {
            let code = path.withCString { pathPointer -> Int32 in
                var entry = git_index_entry()
                entry.mode = 0o100644
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
                unstaged: status & workMask != 0,
                untracked: status & GIT_STATUS_WT_NEW.rawValue != 0
            ))
        }
        let workdir = git_repository_workdir(repo).map { URL(fileURLWithPath: String(cString: $0)) }
        if let workdir {
            let lfsClean = LFSClient.cleanPaths(at: workdir)
            if !lfsClean.isEmpty {
                return entries.map { entry in
                    var entry = entry
                    if lfsClean.contains(entry.path) {
                        entry.unstaged = false
                    }
                    return entry
                }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
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
        sshKey: SSHKeyMaterial?
    ) throws -> OpaquePointer? {
        var remote: OpaquePointer?
        if git_remote_lookup(&remote, repo, "origin") < 0 {
            throw GitFailure.message(String(localized: "This repository has no origin remote."))
        }
        defer { git_remote_free(remote) }
        let box = CredentialBox(username: username, secret: secret, sshKey: sshKey)
        var fetch = git_fetch_options()
        try check(git_fetch_options_init(&fetch, UInt32(GIT_FETCH_OPTIONS_VERSION)), String(localized: "Could not pull"))
        applyTransport(&fetch.callbacks, box: box)
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

    private static func fastForward(_ repo: OpaquePointer, to upstream: OpaquePointer?) throws {
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
        email: String
    ) throws {
        var annotated = annotated
        var mergeOptions = git_merge_options()
        try check(git_merge_options_init(&mergeOptions, UInt32(GIT_MERGE_OPTIONS_VERSION)), String(localized: "Could not pull"))
        var checkout = git_checkout_options()
        try check(
            git_checkout_options_init(&checkout, UInt32(GIT_CHECKOUT_OPTIONS_VERSION)),
            String(localized: "Could not pull")
        )
        checkout.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue
        let mergeCode = git_merge(repo, &annotated, 1, &mergeOptions, &checkout)
        if mergeCode < 0 {
            git_repository_state_cleanup(repo)
            try check(mergeCode, String(localized: "Could not pull"))
        }
        var index: OpaquePointer?
        try check(git_repository_index(&index, repo), String(localized: "Could not pull"))
        defer { git_index_free(index) }
        if git_index_has_conflicts(index) != 0 {
            abortMerge(repo)
            throw GitFailure.message(String(localized: "The merge produced conflicts. The demo left the branch unchanged."))
        }
        try check(git_index_write(index), String(localized: "Could not pull"))
        var tree = git_oid()
        try check(git_index_write_tree(&tree, index), String(localized: "Could not pull"))
        let head = try headCommit(repo)
        defer { git_commit_free(head) }
        var theirCommit: OpaquePointer?
        if let theirOID = git_annotated_commit_id(annotated) {
            var oid = theirOID.pointee
            git_commit_lookup(&theirCommit, repo, &oid)
        }
        defer { git_commit_free(theirCommit) }
        var parents: [OpaquePointer] = []
        if let head { parents.append(head) }
        if let theirCommit { parents.append(theirCommit) }
        try writeCommit(
            repo: repo,
            tree: tree,
            parents: parents,
            message: "Merge remote-tracking branch",
            name: name,
            email: email
        )
        git_repository_state_cleanup(repo)
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

    private static func abortCherryPick(_ repo: OpaquePointer) {
        var head: OpaquePointer?
        if git_revparse_single(&head, repo, "HEAD") == 0 {
            var checkout = git_checkout_options()
            git_checkout_options_init(&checkout, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
            checkout.checkout_strategy = GIT_CHECKOUT_FORCE.rawValue
            git_reset(repo, head, GIT_RESET_HARD, &checkout)
            git_object_free(head)
        }
        git_repository_state_cleanup(repo)
    }

    private static func abortMerge(_ repo: OpaquePointer) {
        var head: OpaquePointer?
        if git_revparse_single(&head, repo, "HEAD") == 0 {
            git_reset(repo, head, GIT_RESET_HARD, nil)
            git_object_free(head)
        }
        git_repository_state_cleanup(repo)
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
        callbacks.credentials = acquireCredentials
        callbacks.certificate_check = checkServerCertificate
        callbacks.payload = Unmanaged.passUnretained(box).toOpaque()
    }

    private static func withRefspec(_ spec: String, _ body: (UnsafePointer<git_strarray>) throws -> Void) throws {
        let copy = strdup(spec)
        defer { free(copy) }
        var string = copy
        var array = git_strarray(strings: &string, count: 1)
        try withUnsafePointer(to: &array) { pointer in
            try body(pointer)
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

private final class CredentialBox {
    let username: String
    let secret: String
    let sshKey: SSHKeyMaterial?

    init(username: String, secret: String, sshKey: SSHKeyMaterial? = nil) {
        self.username = username
        self.secret = secret
        self.sshKey = sshKey
    }
}

private let acquireCredentials: git_credential_acquire_cb = { credential, _, usernameFromURL, allowedTypes, payload in
    guard let credential, let payload else { return -1 }
    let box = Unmanaged<CredentialBox>.fromOpaque(payload).takeUnretainedValue()
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
private func trustSSHHost(host: String, fingerprint: String) -> Bool {
    let key = "gitling.knownHosts.v1"
    var known = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    if let existing = known[host] {
        return existing == fingerprint
    }
    known[host] = fingerprint
    UserDefaults.standard.set(known, forKey: key)
    return true
}
