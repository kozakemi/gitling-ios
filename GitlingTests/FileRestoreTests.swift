import XCTest
import Clibgit2
import Darwin
@testable import Gitling

final class FileRestoreTests: XCTestCase {
    private func repository(committed: Bool = true) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let name = "restore-" + UUID().uuidString
        try GitClient.initialize(name: name, root: root)
        let repo = root.appendingPathComponent(name)
        addTeardownBlock { try? FileManager.default.removeItem(at: root); WorktreeLink.remove(repoName: name) }
        try write("base\n", "a.txt", repo)
        try write("other\n", "b.txt", repo)
        if committed { try commit(repo) }
        return repo
    }
    private func write(_ text: String, _ path: String, _ repo: URL) throws {
        try text.write(to: repo.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }
    private func read(_ path: String, _ repo: URL) throws -> String {
        try String(contentsOf: repo.appendingPathComponent(path), encoding: .utf8)
    }
    private func commit(_ repo: URL) throws {
        try GitClient.stageAll(at: repo)
        try GitClient.commit(at: repo, message: "fixture", name: "Test", email: "test@example.invalid")
    }
    private func index(_ repo: URL) throws -> Data { try Data(contentsOf: repo.appendingPathComponent(".git/index")) }
    private func restore(_ path: String, _ repo: URL) throws {
        let before = try index(repo)
        let plan = try GitClient.prepareFileRestore(at: repo, path: path)
        try GitClient.restoreFile(at: repo, plan: plan)
        XCTAssertEqual(try index(repo), before, "Restoring must not rewrite even index stat data")
    }
    private func replaceIndexEntry(_ repo: URL, path: String, mode: UInt32? = nil) throws {
        var raw: OpaquePointer?
        XCTAssertEqual(git_repository_open(&raw, repo.path), 0)
        defer { git_repository_free(raw) }
        var index: OpaquePointer?
        XCTAssertEqual(git_repository_index(&index, raw), 0)
        defer { git_index_free(index) }
        var entry = try XCTUnwrap(git_index_get_bypath(index, path, 0)).pointee
        if let mode { entry.mode = mode }
        XCTAssertEqual(git_index_add(index, &entry), 0)
        XCTAssertEqual(git_index_write(index), 0)
    }

    func testRestoresIndexInsteadOfHeadAndKeepsOtherStagedUnstagedAndUntrackedFiles() throws {
        let repo = try repository()
        try write("staged\n", "a.txt", repo)
        try GitClient.stage(at: repo, path: "a.txt")
        try write("discard me\n", "a.txt", repo)
        try write("other staged\n", "b.txt", repo)
        try GitClient.stage(at: repo, path: "b.txt")
        try write("other newer\n", "b.txt", repo)
        try write("untracked\n", "new.txt", repo)
        let head = try GitClient.history(at: repo)[0].id
        try restore("a.txt", repo)
        XCTAssertEqual(try read("a.txt", repo), "staged\n")
        XCTAssertEqual(try read("b.txt", repo), "other newer\n")
        XCTAssertEqual(try read("new.txt", repo), "untracked\n")
        XCTAssertEqual(try GitClient.history(at: repo)[0].id, head)
        let entry = try XCTUnwrap(GitClient.status(at: repo).first { $0.path == "a.txt" })
        XCTAssertTrue(entry.staged); XCTAssertFalse(entry.unstaged)
        XCTAssertTrue(try GitClient.diff(at: repo, scope: .staged, path: "a.txt").contains("+staged"))
    }

    func testDeletedFileRestoresLatestIndexIncludingMissingParentDirectories() throws {
        let repo = try repository()
        let directory = repo.appendingPathComponent("nested/deep")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try write("staged nested\n", "nested/deep/中文[1]*.txt", repo)
        try GitClient.stage(at: repo, path: "nested/deep/中文[1]*.txt")
        try FileManager.default.removeItem(at: repo.appendingPathComponent("nested"))
        let plan = try GitClient.prepareFileRestore(at: repo, path: "nested/deep/中文[1]*.txt")
        XCTAssertTrue(plan.restoresDeletedFile)
        let before = try index(repo)
        try GitClient.restoreFile(at: repo, plan: plan)
        XCTAssertEqual(try read(plan.path, repo), "staged nested\n")
        XCTAssertEqual(try index(repo), before)
    }

    func testNewStagedFileRestoresBeforeFirstCommit() throws {
        let repo = try repository(committed: false)
        try GitClient.stage(at: repo, path: "a.txt")
        try write("newer\n", "a.txt", repo)
        try restore("a.txt", repo)
        XCTAssertEqual(try read("a.txt", repo), "base\n")
    }

    func testLiteralWildcardPathDoesNotRestoreMatchingSiblings() throws {
        let repo = try repository()
        try write("literal\n", "a[1]*.txt", repo)
        try write("sibling\n", "a1other.txt", repo)
        try commit(repo)
        try write("edit\n", "a[1]*.txt", repo)
        try write("keep\n", "a1other.txt", repo)
        try restore("a[1]*.txt", repo)
        XCTAssertEqual(try read("a[1]*.txt", repo), "literal\n")
        XCTAssertEqual(try read("a1other.txt", repo), "keep\n")
    }

    func testStagedRenameRestoresOnlyDestinationAndPreservesRenameInIndex() throws {
        let repo = try repository()
        try FileManager.default.moveItem(at: repo.appendingPathComponent("a.txt"), to: repo.appendingPathComponent("renamed.txt"))
        try GitClient.stage(at: repo, path: "renamed.txt", originalPath: "a.txt")
        try write("edit\n", "renamed.txt", repo)
        try restore("renamed.txt", repo)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent("a.txt").path))
        XCTAssertEqual(try read("renamed.txt", repo), "base\n")
        XCTAssertEqual(try GitClient.status(at: repo).first { $0.path == "renamed.txt" }?.originalPath, "a.txt")
    }

    func testUntrackedAndStagedDeletedFilesAreNeverRecreatedOrDeleted() throws {
        let repo = try repository()
        try write("keep\n", "new.txt", repo)
        XCTAssertThrowsError(try GitClient.prepareFileRestore(at: repo, path: "new.txt"))
        XCTAssertEqual(try read("new.txt", repo), "keep\n")
        try FileManager.default.removeItem(at: repo.appendingPathComponent("a.txt"))
        try GitClient.stage(at: repo, path: "a.txt")
        XCTAssertThrowsError(try GitClient.prepareFileRestore(at: repo, path: "a.txt"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent("a.txt").path))
    }

    func testChangedWorkFileSinceConfirmationIsPreservedEvenIfMtimeRestored() throws {
        let repo = try repository()
        try write("edit\n", "a.txt", repo)
        let file = repo.appendingPathComponent("a.txt")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let plan = try GitClient.prepareFileRestore(at: repo, path: "a.txt")
        try write("late\n", "a.txt", repo)
        try FileManager.default.setAttributes([.modificationDate: attributes[.modificationDate]!], ofItemAtPath: file.path)
        XCTAssertThrowsError(try GitClient.restoreFile(at: repo, plan: plan))
        XCTAssertEqual(try read("a.txt", repo), "late\n")
    }

    func testFileAppearingAfterDeletedFileConfirmationIsPreserved() throws {
        let repo = try repository()
        try FileManager.default.removeItem(at: repo.appendingPathComponent("a.txt"))
        let plan = try GitClient.prepareFileRestore(at: repo, path: "a.txt")
        try write("new file\n", "a.txt", repo)
        XCTAssertThrowsError(try GitClient.restoreFile(at: repo, plan: plan))
        XCTAssertEqual(try read("a.txt", repo), "new file\n")
    }

    func testIndexChangeSinceConfirmationIsRejectedAndPlanCannotBeReused() throws {
        let repo = try repository()
        try write("first edit\n", "a.txt", repo)
        let plan = try GitClient.prepareFileRestore(at: repo, path: "a.txt")
        try GitClient.stage(at: repo, path: "a.txt")
        try write("second edit\n", "a.txt", repo)
        let before = try index(repo)
        XCTAssertThrowsError(try GitClient.restoreFile(at: repo, plan: plan))
        XCTAssertEqual(try index(repo), before)
        XCTAssertEqual(try read("a.txt", repo), "second edit\n")
        let current = try GitClient.prepareFileRestore(at: repo, path: "a.txt")
        try GitClient.restoreFile(at: repo, plan: current)
        XCTAssertThrowsError(try GitClient.restoreFile(at: repo, plan: current))
    }

    func testLeafSymlinkAndDanglingSymlinkNeverTouchTheirTargets() throws {
        let repo = try repository()
        let target = repo.appendingPathComponent("b.txt")
        let file = repo.appendingPathComponent("a.txt")
        let plan = try GitClient.prepareFileRestore(at: repo, path: "a.txt")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        XCTAssertThrowsError(try GitClient.prepareFileRestore(at: repo, path: "a.txt"))
        XCTAssertThrowsError(try GitClient.restoreFile(at: repo, plan: plan))
        XCTAssertEqual(try read("b.txt", repo), "other\n")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: repo.appendingPathComponent("missing"))
        XCTAssertThrowsError(try GitClient.prepareFileRestore(at: repo, path: "a.txt"))
        XCTAssertNotNil(try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink)
    }

    func testSymlinkAncestorAndDirectoryReplacementAreProtected() throws {
        let repo = try repository()
        let nested = repo.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try write("nested\n", "nested/file.txt", repo)
        try GitClient.stage(at: repo, path: "nested/file.txt")
        let plan = try GitClient.prepareFileRestore(at: repo, path: "nested/file.txt")
        let outside = repo.deletingLastPathComponent().appendingPathComponent("outside")
        try FileManager.default.moveItem(at: nested, to: outside)
        try FileManager.default.createSymbolicLink(at: nested, withDestinationURL: outside)
        XCTAssertThrowsError(try GitClient.restoreFile(at: repo, plan: plan))
        XCTAssertThrowsError(try GitClient.prepareFileRestore(at: repo, path: "nested/file.txt"))
        XCTAssertEqual(try String(contentsOf: outside.appendingPathComponent("file.txt"), encoding: .utf8), "nested\n")
        try FileManager.default.removeItem(at: repo.appendingPathComponent("a.txt"))
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("a.txt/keep"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try GitClient.prepareFileRestore(at: repo, path: "a.txt"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.appendingPathComponent("a.txt/keep").path))
    }

    func testIndexSymlinkAndGitlinkAreRejected() throws {
        let repo = try repository()
        for mode: UInt32 in [0o120000, 0o160000] {
            try replaceIndexEntry(repo, path: "a.txt", mode: mode)
            XCTAssertThrowsError(try GitClient.prepareFileRestore(at: repo, path: "a.txt"))
            XCTAssertEqual(try read("a.txt", repo), "base\n")
        }
    }

    func testConflictAndOperationStartedAfterConfirmationBlockRestore() throws {
        let repo = try repository()
        try GitClient.createBranch(at: repo, name: "feature", checkout: true)
        try write("feature\n", "a.txt", repo); try commit(repo)
        try GitClient.checkout(at: repo, branch: "master")
        try write("master\n", "a.txt", repo); try commit(repo)
        let plan = try GitClient.prepareFileRestore(at: repo, path: "b.txt")
        try GitClient.mergeBranch(at: repo, branch: "feature", name: "Test", email: "test@example.invalid")
        XCTAssertFalse(try GitClient.operation(at: repo).conflicts.isEmpty)
        XCTAssertThrowsError(try GitClient.prepareFileRestore(at: repo, path: "a.txt"))
        XCTAssertThrowsError(try GitClient.restoreFile(at: repo, plan: plan))
        XCTAssertTrue(try read("a.txt", repo).contains("<<<<<<<"))
        XCTAssertEqual(try read("b.txt", repo), "other\n")
    }

    func testExternalWorktreeRestoresExternalFileAndRejectsChangedLink() throws {
        let repo = try repository()
        let external = repo.deletingLastPathComponent().appendingPathComponent("external")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try GitClient.link(at: repo, bookmark: WorktreeLink.bookmark(for: external))
        let worktree = external.appendingPathComponent(repo.lastPathComponent)
        try write("staged external\n", "a.txt", worktree)
        try GitClient.stage(at: repo, path: "a.txt")
        try write("discard external\n", "a.txt", worktree)
        try restore("a.txt", repo)
        XCTAssertEqual(try read("a.txt", worktree), "staged external\n")
        let plan = try GitClient.prepareFileRestore(at: repo, path: "a.txt")
        try GitClient.unlink(at: repo)
        XCTAssertThrowsError(try GitClient.restoreFile(at: repo, plan: plan))
        XCTAssertEqual(try read("a.txt", worktree), "staged external\n")
    }

    func testUnavailableOrCorruptExternalBookmarkNeverFallsBackOrRecreatesWorkspace() throws {
        let repo = try repository()
        try WorktreeLink.save(repoName: repo.lastPathComponent, data: Data("broken".utf8))
        XCTAssertThrowsError(try GitClient.prepareFileRestore(at: repo, path: "a.txt"))
        XCTAssertEqual(try read("a.txt", repo), "base\n")
        WorktreeLink.remove(repoName: repo.lastPathComponent)
        let external = repo.deletingLastPathComponent().appendingPathComponent("external")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try GitClient.link(at: repo, bookmark: WorktreeLink.bookmark(for: external))
        let plan = try GitClient.prepareFileRestore(at: repo, path: "a.txt")
        try FileManager.default.removeItem(at: external)
        XCTAssertThrowsError(try GitClient.prepareFileRestore(at: repo, path: "a.txt"))
        XCTAssertThrowsError(try GitClient.restoreFile(at: repo, plan: plan))
        XCTAssertFalse(FileManager.default.fileExists(atPath: external.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent("a.txt").path))
    }

    func testEmptyBinaryAndLargeFilesRestoreWithoutTextConversion() throws {
        let repo = try repository()
        for data in [Data(), Data([0, 255, 10, 128]), Data(repeating: 0x91, count: 8 * 1024 * 1024)] {
            try data.write(to: repo.appendingPathComponent("a.txt"))
            try GitClient.stage(at: repo, path: "a.txt")
            try write("discard\n", "a.txt", repo)
            try restore("a.txt", repo)
            XCTAssertEqual(try Data(contentsOf: repo.appendingPathComponent("a.txt")), data)
        }
    }

    func testRestoresExecutableModeAndCheckoutLineEndings() throws {
        let repo = try repository()
        try write("a.txt text eol=crlf\n", ".gitattributes", repo)
        try GitClient.stage(at: repo, path: ".gitattributes")
        try replaceIndexEntry(repo, path: "a.txt", mode: 0o100755)
        try write("discard\n", "a.txt", repo)
        try restore("a.txt", repo)
        XCTAssertEqual(try read("a.txt", repo), "base\r\n")
        let permissions = try FileManager.default.attributesOfItem(atPath: repo.appendingPathComponent("a.txt").path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o755)
    }

    func testInvalidPathsAndMissingBlobFailWithoutChangingWorkFileOrIndex() throws {
        let repo = try repository()
        for path in ["../a.txt", "/a.txt", "a/../a.txt", ".git/config", ".GIT/config", "a//b", "a/./b", "a.txt\0"] {
            XCTAssertThrowsError(try GitClient.prepareFileRestore(at: repo, path: path), path)
        }
        let plan = try GitClient.prepareFileRestore(at: repo, path: "a.txt")
        let object = repo.appendingPathComponent(".git/objects/" + plan.indexOID.prefix(2) + "/" + plan.indexOID.dropFirst(2))
        try FileManager.default.removeItem(at: object)
        let before = try index(repo)
        XCTAssertThrowsError(try GitClient.restoreFile(at: repo, plan: plan))
        XCTAssertEqual(try read("a.txt", repo), "base\n")
        XCTAssertEqual(try index(repo), before)
    }

    func testSelectedFileRestoreWithLargeUnrelatedWorktreeReportsOfflineTiming() throws {
        let repo = try repository()
        let unrelated = Data(repeating: 0x8f, count: 8 * 1024 * 1024)
        try unrelated.write(to: repo.appendingPathComponent("unrelated.bin"))
        let directory = repo.appendingPathComponent("unrelated-tree")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for index in 0..<500 {
            try Data().write(to: directory.appendingPathComponent("file-\(index)"))
        }
        let before = try index(repo)
        var samples: [Double] = []
        for _ in 0..<10 {
            try write("discard\n", "a.txt", repo)
            let start = DispatchTime.now().uptimeNanoseconds
            let plan = try GitClient.prepareFileRestore(at: repo, path: "a.txt")
            try GitClient.restoreFile(at: repo, plan: plan)
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            XCTAssertEqual(try read("a.txt", repo), "base\n")
        }
        XCTAssertEqual(try index(repo), before)
        XCTAssertEqual(try Data(contentsOf: repo.appendingPathComponent("unrelated.bin")), unrelated)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 500)
        print("RESTORE_PERF median_ms=\(samples.sorted()[samples.count / 2]) samples_ms=\(samples)")
    }

    func testLFSPointerIsRejectedWithoutReplacingRealContentOrNetworkAccess() throws {
        let repo = try repository()
        let pointer = LFSPointer.make(oid: String(repeating: "a", count: 64), size: 4)
        try write(pointer.raw, "a.txt", repo)
        try GitClient.stage(at: repo, path: "a.txt")
        try write("real content\n", "a.txt", repo)
        let before = try index(repo)
        XCTAssertThrowsError(try GitClient.prepareFileRestore(at: repo, path: "a.txt"))
        XCTAssertEqual(try read("a.txt", repo), "real content\n")
        XCTAssertEqual(try index(repo), before)
    }
}
