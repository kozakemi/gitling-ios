import CryptoKit
import XCTest
@testable import Gitling

final class FirstRoundWorkflowTests: XCTestCase {
    private func repository(committed: Bool = true) throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let name = "workflow-" + UUID().uuidString
        addTeardownBlock { WorktreeLink.remove(repoName: name) }
        try GitClient.initialize(name: name, root: root)
        let repo = root.appendingPathComponent(name)
        try write("base\n", "a.txt", in: repo)
        try write("base\n", "b.txt", in: repo)
        if committed { try commitAll(repo, "base") }
        return (root, repo)
    }

    private func write(_ text: String, _ path: String, in repo: URL) throws {
        try text.write(to: repo.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }

    private func commitAll(_ repo: URL, _ message: String) throws {
        try GitClient.stageAll(at: repo)
        try GitClient.commit(at: repo, message: message, name: "Test", email: "test@example.com")
    }

    func testPartialStagingDiffAndCommitPreserveNewerWorktreeBytes() throws {
        let (_, repo) = try repository()
        try write("staged version\n", "a.txt", in: repo)
        try GitClient.stage(at: repo, path: "a.txt")
        try write("newer worktree\n", "a.txt", in: repo)
        try write("unselected\n", "b.txt", in: repo)
        let staged = try GitClient.diff(at: repo, scope: .staged, path: "a.txt")
        let unstaged = try GitClient.diff(at: repo, scope: .worktree, path: "a.txt")
        XCTAssertTrue(staged.contains("+staged version"))
        XCTAssertFalse(staged.contains("newer worktree"))
        XCTAssertTrue(unstaged.contains("+newer worktree"))
        XCTAssertTrue(try GitClient.diff(at: repo, scope: .staged, path: "b.txt").isEmpty)
        try GitClient.commit(at: repo, message: "selected", name: "Test", email: "test@example.com")
        let head = try GitClient.history(at: repo)[0]
        let patch = try GitClient.show(at: repo, commit: head.id)
        XCTAssertTrue(patch.contains("+staged version"))
        XCTAssertFalse(patch.contains("unselected"))
        XCTAssertEqual(try GitClient.readText(at: repo, relative: "a.txt"), "newer worktree\n")
        XCTAssertTrue(try GitClient.status(at: repo).allSatisfy { !$0.staged })
    }

    func testUnstageIsLiteralAndOnlyTouchesSelectedFileBeforeFirstCommit() throws {
        let (_, repo) = try repository(committed: false)
        try write("literal\n", "a[1].txt", in: repo)
        try write("other\n", "a1.txt", in: repo)
        try GitClient.stageAll(at: repo)
        try GitClient.unstage(at: repo, path: "a[1].txt")
        let status = try GitClient.status(at: repo)
        XCTAssertFalse(try XCTUnwrap(status.first { $0.path == "a[1].txt" }).staged)
        XCTAssertTrue(try XCTUnwrap(status.first { $0.path == "a1.txt" }).staged)
        XCTAssertEqual(try GitClient.readText(at: repo, relative: "a[1].txt"), "literal\n")
        XCTAssertTrue(try GitClient.diff(at: repo, scope: .staged, path: "a[1].txt").isEmpty)
        XCTAssertTrue(try GitClient.diff(at: repo, scope: .worktree, path: "a[1].txt").contains("+literal"))
    }

    func testDeletedAndRenamedFilesCanBeStagedAndUnstagedIndividually() throws {
        let (_, repo) = try repository()
        try FileManager.default.removeItem(at: repo.appendingPathComponent("b.txt"))
        try GitClient.stage(at: repo, path: "b.txt")
        XCTAssertTrue(try GitClient.diff(at: repo, scope: .staged, path: "b.txt").contains("deleted file"))
        try GitClient.unstage(at: repo, path: "b.txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent("b.txt").path))
        try FileManager.default.moveItem(at: repo.appendingPathComponent("a.txt"), to: repo.appendingPathComponent("renamed.txt"))
        try GitClient.stage(at: repo, path: "renamed.txt", originalPath: "a.txt")
        let renamed = try XCTUnwrap(GitClient.status(at: repo).first { $0.path == "renamed.txt" })
        XCTAssertTrue(renamed.staged)
        XCTAssertEqual(renamed.originalPath, "a.txt")
        try GitClient.unstage(at: repo, path: renamed.path, originalPath: renamed.originalPath)
        XCTAssertTrue(try GitClient.diff(at: repo, scope: .staged).isEmpty)
        XCTAssertEqual(try GitClient.readText(at: repo, relative: "renamed.txt"), "base\n")
        XCTAssertThrowsError(try GitClient.stage(at: repo, path: "../outside"))
        XCTAssertThrowsError(try GitClient.unstage(at: repo, path: ".git/config"))
    }

    func testSingleFileLFSCleanDoesNotUploadOrStageOtherFiles() throws {
        let (_, repo) = try repository()
        try GitClient.addRemote(at: repo, name: "company", url: "https://example.invalid/repo.git")
        try write("*.bin filter=lfs\n", ".gitattributes", in: repo)
        let first = LFSPointer.make(oid: String(repeating: "a", count: 64), size: 1)
        let second = LFSPointer.make(oid: String(repeating: "b", count: 64), size: 1)
        try write(first.raw, "selected.bin", in: repo)
        try write("must not be uploaded", "other.bin", in: repo)
        try GitClient.stage(at: repo, path: "selected.bin")
        let manifest = try JSONDecoder().decode([String: LFSPointer].self, from: Data(contentsOf: repo.appendingPathComponent(".git/lfs-pointers.json")))
        XCTAssertEqual(manifest["selected.bin"], first)
        XCTAssertNil(manifest["other.bin"])
        try write(second.raw, "selected.bin", in: repo)
        try GitClient.stage(at: repo, path: "a.txt")
        try GitClient.commit(at: repo, message: "selected LFS", name: "Test", email: "test@example.com")
        let patch = try GitClient.show(at: repo, commit: GitClient.history(at: repo)[0].id)
        XCTAssertTrue(patch.contains(first.oid))
        XCTAssertFalse(patch.contains(second.oid))
        XCTAssertFalse(patch.contains("other.bin"))
        XCTAssertEqual(try GitClient.readText(at: repo, relative: "selected.bin"), second.raw)
    }

    func testStashRoundTripPreservesIndexWorktreeAndUntrackedFiles() throws {
        let (_, repo) = try repository()
        try write("staged\n", "a.txt", in: repo)
        try GitClient.stage(at: repo, path: "a.txt")
        try write("unstaged\n", "a.txt", in: repo)
        try write("new\n", "untracked.txt", in: repo)
        try GitClient.saveStash(at: repo, message: "first", includeUntracked: true, name: "Test", email: "test@example.com")
        let original = try XCTUnwrap(GitClient.stashes(at: repo).first)
        XCTAssertTrue(try GitClient.status(at: repo).isEmpty)
        try GitClient.applyStash(at: repo, oid: original.oid)
        XCTAssertEqual(try GitClient.stashes(at: repo).count, 1)
        XCTAssertTrue(try GitClient.diff(at: repo, scope: .staged, path: "a.txt").contains("+staged"))
        XCTAssertTrue(try GitClient.diff(at: repo, scope: .worktree, path: "a.txt").contains("+unstaged"))
        XCTAssertEqual(try GitClient.readText(at: repo, relative: "untracked.txt"), "new\n")
        XCTAssertThrowsError(try GitClient.applyStash(at: repo, oid: original.oid, pop: true))
        try GitClient.saveStash(at: repo, message: "second", includeUntracked: true, name: "Test", email: "test@example.com")
        // Its numeric index shifted; the original OID still restores the right entry.
        try GitClient.applyStash(at: repo, oid: original.oid, pop: true)
        XCTAssertEqual(try GitClient.stashes(at: repo).count, 1)
        XCTAssertFalse(try GitClient.stashes(at: repo).contains { $0.oid == original.oid })
        XCTAssertEqual(try GitClient.readText(at: repo, relative: "a.txt"), "unstaged\n")
    }

    func testStashWithoutUntrackedAndFailedPopKeepUserDataAndStash() throws {
        let (_, repo) = try repository()
        try write("stashed\n", "a.txt", in: repo)
        try write("keep\n", "new.txt", in: repo)
        try GitClient.saveStash(at: repo, message: "conflict", includeUntracked: false, name: "Test", email: "test@example.com")
        let saved = try XCTUnwrap(GitClient.stashes(at: repo).first)
        XCTAssertEqual(try GitClient.readText(at: repo, relative: "new.txt"), "keep\n")
        try write("conflicting commit\n", "a.txt", in: repo)
        try GitClient.stage(at: repo, path: "a.txt")
        try GitClient.commit(at: repo, message: "conflict", name: "Test", email: "test@example.com")
        try FileManager.default.removeItem(at: repo.appendingPathComponent("new.txt"))
        XCTAssertThrowsError(try GitClient.applyStash(at: repo, oid: saved.oid, pop: true))
        XCTAssertEqual(try GitClient.stashes(at: repo).map(\.oid), [saved.oid])
        let conflicted = try GitClient.readText(at: repo, relative: "a.txt")
        XCTAssertTrue(conflicted.contains("conflicting commit"))
        XCTAssertTrue(conflicted.contains("stashed"))
        XCTAssertTrue(try GitClient.status(at: repo).contains { $0.path == "a.txt" && $0.conflicted == true })
        try GitClient.dropStash(at: repo, oid: saved.oid)
        XCTAssertTrue(try GitClient.stashes(at: repo).isEmpty)
        XCTAssertThrowsError(try GitClient.dropStash(at: repo, oid: saved.oid))
    }

    func testStashAndPartialStagingUseLinkedWorktree() throws {
        let (root, repo) = try repository()
        let folder = root.appendingPathComponent("vault")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try GitClient.link(at: repo, bookmark: WorktreeLink.bookmark(for: folder))
        let external = folder.appendingPathComponent(repo.lastPathComponent)
        try write("external staged\n", "a.txt", in: external)
        try GitClient.stage(at: repo, path: "a.txt")
        try write("external edit\n", "b.txt", in: external)
        try GitClient.saveStash(at: repo, message: "external", includeUntracked: true, name: "Test", email: "test@example.com")
        let stash = try XCTUnwrap(GitClient.stashes(at: repo).first)
        try GitClient.applyStash(at: repo, oid: stash.oid, pop: true)
        XCTAssertEqual(try GitClient.readText(at: repo, relative: "a.txt"), "external staged\n")
        XCTAssertTrue(try GitClient.diff(at: repo, scope: .worktree, path: "b.txt").contains("+external edit"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: external.appendingPathComponent(".git").path))
    }

    func testBranchNamesRenameAndProtectedDeletion() throws {
        let (_, repo) = try repository()
        for invalid in ["", "bad..name", "bad name", "a.lock", "a//b", "-option", "HEAD"] {
            XCTAssertFalse(GitClient.isValidBranchName(invalid), invalid)
        }
        try GitClient.createBranch(at: repo, name: "feature/demo", checkout: true)
        try GitClient.renameBranch(at: repo, branch: "feature/demo", to: "feature/renamed")
        XCTAssertEqual(try GitClient.header(at: repo).branch, "feature/renamed")
        XCTAssertThrowsError(try GitClient.deleteBranch(at: repo, branch: "feature/renamed"))
        try write("feature\n", "a.txt", in: repo)
        try commitAll(repo, "feature")
        try GitClient.checkout(at: repo, branch: "master")
        XCTAssertThrowsError(try GitClient.deleteBranch(at: repo, branch: "feature/renamed"))
        try GitClient.mergeBranch(at: repo, branch: "feature/renamed", name: "Test", email: "test@example.com")
        try GitClient.deleteBranch(at: repo, branch: "feature/renamed")
        XCTAssertEqual(try GitClient.branches(at: repo).filter { !$0.isRemote }.map(\.name), ["master"])
    }

    func testUpstreamRemoteAndDifferentBranchNameDrivePushFetchAndPull() throws {
        let (root, repo) = try repository()
        try GitClient.initialize(name: "company", root: root, bare: true)
        try GitClient.initialize(name: "backup", root: root, bare: true)
        let company = root.appendingPathComponent("company").absoluteString
        let backup = root.appendingPathComponent("backup").absoluteString
        try GitClient.addRemote(at: repo, name: "company", url: company)
        try GitClient.push(at: repo, username: "", secret: "", remoteName: "company")
        XCTAssertEqual(try GitClient.header(at: repo).upstream, "company/master")
        try GitClient.addRemote(at: repo, name: "origin", url: backup)
        try GitClient.renameBranch(at: repo, branch: "master", to: "work/topic")
        XCTAssertEqual(try GitClient.header(at: repo).upstream, "company/master")
        XCTAssertEqual(try GitClient.transportURL(at: repo), company)
        try write("pushed to company master\n", "a.txt", in: repo)
        try commitAll(repo, "company update")
        try GitClient.push(at: repo, username: "", secret: "")
        try GitClient.clone(url: company, name: "consumer", root: root, username: "", secret: "")
        let consumer = root.appendingPathComponent("consumer")
        XCTAssertEqual(try GitClient.readText(at: consumer, relative: "a.txt"), "pushed to company master\n")
        try write("remote update\n", "b.txt", in: consumer)
        try commitAll(consumer, "remote update")
        try GitClient.push(at: consumer, username: "", secret: "")
        try GitClient.pull(at: repo, username: "", secret: "", name: "Test", email: "test@example.com")
        XCTAssertEqual(try GitClient.readText(at: repo, relative: "b.txt"), "remote update\n")
        // An explicit push elsewhere does not silently replace the configured upstream.
        try GitClient.push(at: repo, username: "", secret: "", remoteName: "origin")
        XCTAssertEqual(try GitClient.header(at: repo).upstream, "company/master")
        try GitClient.fetch(at: repo, username: "", secret: "", remoteName: "company")
        try GitClient.setUpstream(at: repo, branch: "work/topic", upstream: nil)
        XCTAssertNil(try GitClient.header(at: repo).upstream)
        try GitClient.setUpstream(at: repo, branch: "work/topic", upstream: "company/master")
        XCTAssertEqual(try GitClient.upstream(at: repo, branch: "work/topic"), "company/master")
        XCTAssertThrowsError(try GitClient.setUpstream(at: repo, branch: "work/topic", upstream: "missing/nope"))
        XCTAssertEqual(try GitClient.header(at: repo).upstream, "company/master")
    }

    func testUnstagingLFSComparesAgainstRestoredIndexPointer() throws {
        let (_, repo) = try repository()
        try GitClient.addRemote(at: repo, url: "https://example.invalid/repo.git")
        try write("*.bin filter=lfs\n", ".gitattributes", in: repo)
        let first = Data("first".utf8)
        let second = Data("other".utf8)
        func pointer(_ data: Data) -> LFSPointer {
            LFSPointer.make(oid: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), size: data.count)
        }
        try write(pointer(first).raw, "asset.bin", in: repo)
        try commitAll(repo, "LFS base")
        try first.write(to: repo.appendingPathComponent("asset.bin"))
        XCTAssertTrue(try GitClient.status(at: repo).isEmpty)
        try write(pointer(second).raw, "asset.bin", in: repo)
        try GitClient.stage(at: repo, path: "asset.bin")
        try second.write(to: repo.appendingPathComponent("asset.bin"))
        XCTAssertTrue(try XCTUnwrap(GitClient.status(at: repo).first).staged)
        try GitClient.unstage(at: repo, path: "asset.bin")
        let status = try XCTUnwrap(GitClient.status(at: repo).first { $0.path == "asset.bin" })
        XCTAssertFalse(status.staged)
        XCTAssertTrue(status.unstaged)
    }

    func testEmptyAndUnbornStashFailuresPreserveFiles() throws {
        let (_, repo) = try repository(committed: false)
        XCTAssertThrowsError(try GitClient.saveStash(at: repo, message: "unborn", includeUntracked: true, name: "Test", email: "test@example.com"))
        XCTAssertEqual(try GitClient.readText(at: repo, relative: "a.txt"), "base\n")
        try commitAll(repo, "base")
        XCTAssertThrowsError(try GitClient.saveStash(at: repo, message: "empty", includeUntracked: true, name: "Test", email: "test@example.com"))
        XCTAssertTrue(try GitClient.stashes(at: repo).isEmpty)
    }

    @MainActor
    func testRemoteCredentialsDoNotFollowAnAccountLinkedToAnotherHost() throws {
        let (root, repo) = try repository()
        let store = RepoStore(root: root, reloadOnStart: false)
        let first = try XCTUnwrap(store.addAccount(provider: .gitlab, baseURL: "https://first.example.invalid", username: UUID().uuidString, token: "test-first"))
        let second = try XCTUnwrap(store.addAccount(provider: .gitlab, baseURL: "https://second.example.invalid", username: UUID().uuidString, token: "test-second"))
        defer { store.removeRepoLink(repo.lastPathComponent); store.removeAccount(first); store.removeAccount(second) }
        store.linkRepo(repo.lastPathComponent, to: first)
        XCTAssertEqual(store.account(for: "https://second.example.invalid/team/repo.git", repoName: repo.lastPathComponent)?.id, second.id)
        XCTAssertEqual(store.account(for: "git@second.example.invalid:team/repo.git", repoName: repo.lastPathComponent)?.id, second.id)
    }


    func testSingleFileStagingDoesNotApplyLFSFiltersToSymlinks() throws {
        let (_, repo) = try repository()
        try GitClient.addRemote(at: repo, url: "https://example.invalid/repo.git")
        try write("*.bin filter=lfs\n", ".gitattributes", in: repo)
        try write("must not upload target", "target.txt", in: repo)
        try FileManager.default.createSymbolicLink(atPath: repo.appendingPathComponent("asset.bin").path, withDestinationPath: "target.txt")
        try GitClient.stage(at: repo, path: "asset.bin")
        let patch = try GitClient.diff(at: repo, scope: .staged, path: "asset.bin")
        XCTAssertTrue(patch.contains("120000"))
        XCTAssertTrue(patch.contains("+target.txt"))
        XCTAssertFalse(patch.contains("must not upload target"))
    }

}
