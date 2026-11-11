import XCTest
import Clibgit2
@testable import Gitling

final class ConflictResolutionTests: XCTestCase {
    private let author = "Conflict Test"
    private let email = "conflict@example.invalid"

    private func repository() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let name = "conflict-" + UUID().uuidString
        try GitClient.initialize(name: name, root: root)
        let repo = root.appendingPathComponent(name)
        addTeardownBlock { try? FileManager.default.removeItem(at: root); WorktreeLink.remove(repoName: name) }
        try write("base\n", repo)
        try commit(repo, "base")
        return repo
    }
    private func write(_ text: String, _ repo: URL, path: String = "a.txt") throws {
        try text.write(to: repo.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }
    private func commit(_ repo: URL, _ message: String) throws {
        try GitClient.stageAll(at: repo)
        try GitClient.commit(at: repo, message: message, name: author, email: email)
    }
    private func diverged() throws -> (URL, String, String) {
        let repo = try repository()
        try GitClient.createBranch(at: repo, name: "feature", checkout: true)
        try write("feature\n", repo)
        try commit(repo, "feature")
        let target = try GitClient.history(at: repo)[0].id
        try GitClient.checkout(at: repo, branch: "master")
        try write("master\n", repo)
        try commit(repo, "master")
        return (repo, target, try GitClient.history(at: repo)[0].id)
    }
    private func resolve(_ repo: URL, text: String = "resolved\n") throws {
        let conflict = try XCTUnwrap(GitClient.operation(at: repo).conflicts.first)
        try write(text, repo, path: conflict.path)
        try GitClient.resolveConflict(at: repo, conflict: conflict)
    }
    private func start(_ kind: GitOperationKind, repo: URL, target: String) throws {
        switch kind {
        case .merge: try GitClient.mergeBranch(at: repo, branch: "feature", name: author, email: email)
        case .cherryPick: try GitClient.cherryPick(at: repo, commit: target, name: author, email: email)
        case .rebase: try GitClient.rebase(at: repo, onto: "feature", name: author, email: email)
        }
    }

    func testMergeConflictSurvivesReopenAndContinuesWithTwoParents() throws {
        let (repo, target, original) = try diverged()
        try start(.merge, repo: repo, target: target)
        let state = try GitClient.operation(at: repo)
        XCTAssertEqual(state.kind, .merge)
        XCTAssertFalse(state.canContinue)
        XCTAssertEqual(state.conflicts.map(\.path), ["a.txt"])
        let conflict = try XCTUnwrap(state.conflicts.first)
        XCTAssertEqual(try GitClient.conflictPreview(at: repo, version: conflict.ancestor).text, "base\n")
        XCTAssertEqual(try GitClient.conflictPreview(at: repo, version: conflict.ours).text, "master\n")
        XCTAssertEqual(try GitClient.conflictPreview(at: repo, version: conflict.theirs).text, "feature\n")
        XCTAssertThrowsError(try GitClient.continueOperation(at: repo, name: author, email: email))
        XCTAssertEqual(try GitClient.history(at: repo)[0].id, original)
        try resolve(repo)
        XCTAssertTrue(try GitClient.operation(at: repo).canContinue)
        try GitClient.continueOperation(at: repo, name: author, email: email)
        let result = try GitClient.history(at: repo)[0]
        XCTAssertEqual(result.parents, [original, target])
        XCTAssertFalse(try GitClient.operation(at: repo).needsAttention)
        XCTAssertTrue(try GitClient.status(at: repo).isEmpty)
    }

    func testCherryPickConflictContinuesAfterExternalEditAndPreservesAuthorMessage() throws {
        let (repo, target, original) = try diverged()
        try start(.cherryPick, repo: repo, target: target)
        let conflict = try XCTUnwrap(GitClient.operation(at: repo).conflicts.first)
        let edit = try GitClient.conflictEdit(at: repo, conflict: conflict)
        try GitClient.importConflictEdit(at: repo, edit: edit, contents: Data("external resolution\n".utf8))
        XCTAssertEqual(try GitClient.operation(at: repo).conflicts, [conflict])
        XCTAssertEqual(try GitClient.conflictWorkingPreview(at: repo, conflict: conflict).text, "external resolution\n")
        try GitClient.resolveConflict(at: repo, conflict: conflict)
        try GitClient.continueOperation(at: repo, name: "Different Committer", email: "other@example.invalid")
        let result = try GitClient.history(at: repo)[0]
        XCTAssertEqual(result.parents, [original])
        XCTAssertEqual(result.summary, "feature")
        XCTAssertEqual(result.author, author)
        XCTAssertEqual(try GitClient.readText(at: repo, relative: "a.txt"), "external resolution\n")
        XCTAssertNil(try GitClient.operation(at: repo).kind)
    }

    func testRebaseReopensAcrossMultipleConflictStops() throws {
        let repo = try repository()
        try GitClient.createBranch(at: repo, name: "feature", checkout: true)
        try write("feature one\n", repo); try commit(repo, "feature one")
        try write("feature two\n", repo); try commit(repo, "feature two")
        try GitClient.checkout(at: repo, branch: "master")
        try write("upstream\n", repo); try commit(repo, "upstream")
        let upstream = try GitClient.history(at: repo)[0].id
        try GitClient.checkout(at: repo, branch: "feature")
        try GitClient.rebase(at: repo, onto: "master", name: author, email: email)
        XCTAssertEqual(try GitClient.operation(at: repo).kind, .rebase)
        XCTAssertEqual(try GitClient.operation(at: repo).step, 1)
        XCTAssertEqual(try GitClient.operation(at: repo).total, 2)
        try resolve(repo, text: "resolved one\n")
        try GitClient.continueOperation(at: repo, name: author, email: email)
        XCTAssertEqual(try GitClient.operation(at: repo).step, 2)
        XCTAssertFalse(try GitClient.operation(at: repo).conflicts.isEmpty)
        try resolve(repo, text: "resolved two\n")
        try GitClient.continueOperation(at: repo, name: author, email: email)
        XCTAssertFalse(try GitClient.operation(at: repo).needsAttention)
        XCTAssertEqual(try GitClient.header(at: repo).branch, "feature")
        let history = try GitClient.history(at: repo)
        XCTAssertEqual(history[0].summary, "feature two")
        XCTAssertEqual(history[1].summary, "feature one")
        XCTAssertEqual(history[1].parents, [upstream])
        XCTAssertTrue(try GitClient.status(at: repo).isEmpty)
    }

    func testAbortAllThreeOperationsRestoresOriginalBranchAndKeepsUntrackedFile() throws {
        for kind in [GitOperationKind.merge, .rebase, .cherryPick] {
            let (repo, target, original) = try diverged()
            try start(kind, repo: repo, target: target)
            try write("keep\n", repo, path: "unrelated.txt")
            try write("partial resolution\n", repo)
            try GitClient.abortOperation(at: repo)
            XCTAssertEqual(try GitClient.header(at: repo).branch, "master")
            XCTAssertEqual(try GitClient.history(at: repo)[0].id, original)
            XCTAssertEqual(try GitClient.readText(at: repo, relative: "a.txt"), "master\n")
            XCTAssertEqual(try GitClient.readText(at: repo, relative: "unrelated.txt"), "keep\n")
            XCTAssertFalse(try GitClient.operation(at: repo).needsAttention)
            XCTAssertThrowsError(try GitClient.abortOperation(at: repo))
        }
    }

    func testDirtyStartIsRejectedWithoutChangingIndexWorktreeOrHead() throws {
        for kind in [GitOperationKind.merge, .rebase, .cherryPick] {
            let (repo, target, original) = try diverged()
            try write("staged\n", repo); try GitClient.stage(at: repo, path: "a.txt")
            try write("unstaged\n", repo)
            let status = try GitClient.status(at: repo)
            XCTAssertThrowsError(try start(kind, repo: repo, target: target))
            XCTAssertEqual(try GitClient.status(at: repo), status)
            XCTAssertEqual(try GitClient.history(at: repo)[0].id, original)
            XCTAssertEqual(try GitClient.readText(at: repo, relative: "a.txt"), "unstaged\n")
            XCTAssertFalse(try GitClient.operation(at: repo).needsAttention)
        }
    }

    func testMarkersCannotBeConfirmedOrBypassedWithOrdinaryStaging() throws {
        let (repo, target, _) = try diverged()
        try start(.merge, repo: repo, target: target)
        let conflict = try XCTUnwrap(GitClient.operation(at: repo).conflicts.first)
        XCTAssertThrowsError(try GitClient.resolveConflict(at: repo, conflict: conflict))
        XCTAssertThrowsError(try GitClient.stage(at: repo, path: "a.txt"))
        XCTAssertThrowsError(try GitClient.stageAll(at: repo))
        XCTAssertThrowsError(try GitClient.unstageAll(at: repo))
        XCTAssertThrowsError(try GitClient.checkout(at: repo, branch: "feature"))
        XCTAssertThrowsError(try GitClient.commit(at: repo, message: "wrong", name: author, email: email))
        XCTAssertEqual(try GitClient.operation(at: repo).conflicts, [conflict])
    }

    func testModifyDeleteConflictCanResolveAsDeletionOrKeepFile() throws {
        for delete in [true, false] {
            let repo = try repository()
            try GitClient.createBranch(at: repo, name: "feature", checkout: true)
            try FileManager.default.removeItem(at: repo.appendingPathComponent("a.txt")); try commit(repo, "deleted")
            try GitClient.checkout(at: repo, branch: "master")
            try write("modified\n", repo); try commit(repo, "modified")
            try GitClient.mergeBranch(at: repo, branch: "feature", name: author, email: email)
            let conflict = try XCTUnwrap(GitClient.operation(at: repo).conflicts.first)
            XCTAssertNil(conflict.theirs)
            XCTAssertNil(try GitClient.conflictPreview(at: repo, version: conflict.theirs).oid)
            try GitClient.resolveConflict(at: repo, conflict: conflict, delete: delete)
            try GitClient.continueOperation(at: repo, name: author, email: email)
            XCTAssertEqual(FileManager.default.fileExists(atPath: repo.appendingPathComponent("a.txt").path), !delete)
            XCTAssertTrue(try GitClient.status(at: repo).isEmpty)
        }
    }

    func testStaleImportedEditDoesNotOverwriteNewerWorktreeChanges() throws {
        let (repo, target, _) = try diverged()
        try start(.merge, repo: repo, target: target)
        let conflict = try XCTUnwrap(GitClient.operation(at: repo).conflicts.first)
        let edit = try GitClient.conflictEdit(at: repo, conflict: conflict)
        try write("newer editor content\n", repo)
        XCTAssertThrowsError(try GitClient.importConflictEdit(at: repo, edit: edit, contents: Data("old edit\n".utf8)))
        XCTAssertEqual(try GitClient.readText(at: repo, relative: "a.txt"), "newer editor content\n")
        try GitClient.resolveConflict(at: repo, conflict: conflict)
        XCTAssertThrowsError(try GitClient.resolveConflict(at: repo, conflict: conflict))
        XCTAssertThrowsError(try GitClient.importConflictEdit(at: repo, edit: edit, contents: Data("old edit\n".utf8)))
    }

    func testSymlinkEditCannotReadOrOverwriteOutsideWorktree() throws {
        let (repo, target, _) = try diverged()
        try start(.merge, repo: repo, target: target)
        let conflict = try XCTUnwrap(GitClient.operation(at: repo).conflicts.first)
        let edit = try GitClient.conflictEdit(at: repo, conflict: conflict)
        let outside = repo.deletingLastPathComponent().appendingPathComponent("outside.txt")
        try "outside\n".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: repo.appendingPathComponent("a.txt"))
        try FileManager.default.createSymbolicLink(at: repo.appendingPathComponent("a.txt"), withDestinationURL: outside)
        XCTAssertThrowsError(try GitClient.conflictEdit(at: repo, conflict: conflict))
        XCTAssertThrowsError(try GitClient.importConflictEdit(at: repo, edit: edit, contents: Data("changed\n".utf8)))
        XCTAssertThrowsError(try GitClient.resolveConflict(at: repo, conflict: conflict))
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "outside\n")
    }

    func testEditingAfterConfirmationMustBeStagedBeforeContinue() throws {
        let (repo, target, original) = try diverged()
        try start(.merge, repo: repo, target: target)
        try resolve(repo)
        try write("another edit\n", repo)
        XCTAssertThrowsError(try GitClient.continueOperation(at: repo, name: author, email: email))
        XCTAssertEqual(try GitClient.history(at: repo)[0].id, original)
        try GitClient.stage(at: repo, path: "a.txt")
        try GitClient.continueOperation(at: repo, name: author, email: email)
        XCTAssertEqual(try GitClient.readText(at: repo, relative: "a.txt"), "another edit\n")
    }

    func testLinkedWorktreeResolutionAndAbortUseExternalFiles() throws {
        let (repo, target, _) = try diverged()
        let vault = repo.deletingLastPathComponent().appendingPathComponent("vault")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        try GitClient.link(at: repo, bookmark: WorktreeLink.bookmark(for: vault))
        try start(.merge, repo: repo, target: target)
        let conflict = try XCTUnwrap(GitClient.operation(at: repo).conflicts.first)
        let edit = try GitClient.conflictEdit(at: repo, conflict: conflict)
        try GitClient.importConflictEdit(at: repo, edit: edit, contents: Data("external\n".utf8))
        XCTAssertEqual(try String(contentsOf: vault.appendingPathComponent(repo.lastPathComponent).appendingPathComponent("a.txt"), encoding: .utf8), "external\n")
        try GitClient.resolveConflict(at: repo, conflict: conflict)
        try GitClient.abortOperation(at: repo)
        XCTAssertEqual(try GitClient.readText(at: repo, relative: "a.txt"), "master\n")
    }

    func testRebaseEmptyResolutionFinishesWithoutDuplicateCommit() throws {
        let (repo, target, _) = try diverged()
        try start(.rebase, repo: repo, target: target)
        try resolve(repo, text: "feature\n") // identical to rebase's new base
        try GitClient.continueOperation(at: repo, name: author, email: email)
        XCTAssertEqual(try GitClient.history(at: repo)[0].id, target)
        XCTAssertFalse(try GitClient.operation(at: repo).needsAttention)
    }

    func testCrashRecoveryBeforeAndAfterHeadPublicationDoesNotDuplicateCommit() throws {
        for beforePublication in [true, false] {
            let (repo, target, original) = try diverged()
            try start(.merge, repo: repo, target: target); try resolve(repo)
            try GitClient.continueOperation(at: repo, name: author, email: email)
            let result = try GitClient.history(at: repo)[0].id
            if beforePublication {
                var native: OpaquePointer?, reference: OpaquePointer?
                XCTAssertEqual(git_repository_open(&native, repo.path), 0)
                defer { git_repository_free(native) }
                var oid = git_oid(); XCTAssertEqual(git_oid_fromstr(&oid, original), 0)
                XCTAssertEqual(git_reference_create(&reference, native, "refs/heads/master", &oid, 1, "test interrupted publish"), 0)
                git_reference_free(reference)
            }
            let saved = GitOperationJournal(kind: .merge, originalHead: original, reference: "refs/heads/master", target: target, plannedCommit: result)
            try JSONEncoder().encode(saved).write(to: repo.appendingPathComponent(".git/gitling-operation.json"), options: .atomic)
            XCTAssertThrowsError(try GitClient.abortOperation(at: repo))
            try GitClient.continueOperation(at: repo, name: author, email: email)
            XCTAssertEqual(try GitClient.history(at: repo)[0].id, result)
            XCTAssertEqual(try GitClient.history(at: repo)[0].parents, [original, target])
            XCTAssertFalse(try GitClient.operation(at: repo).needsAttention)
            XCTAssertThrowsError(try GitClient.continueOperation(at: repo, name: author, email: email))
        }
    }
    func testLargeBinarySidesAreNotLoadedIntoTextPreview() throws {
        let repo = try repository()
        try Data(repeating: 0, count: 300_000).write(to: repo.appendingPathComponent("a.txt"))
        try commit(repo, "binary base")
        try GitClient.createBranch(at: repo, name: "feature", checkout: true)
        try (Data([0, 1]) + Data(repeating: 1, count: 300_000)).write(to: repo.appendingPathComponent("a.txt"))
        try commit(repo, "binary feature")
        try GitClient.checkout(at: repo, branch: "master")
        try (Data([0, 2]) + Data(repeating: 2, count: 300_000)).write(to: repo.appendingPathComponent("a.txt"))
        try commit(repo, "binary master")
        try GitClient.mergeBranch(at: repo, branch: "feature", name: author, email: email)
        let conflict = try XCTUnwrap(GitClient.operation(at: repo).conflicts.first)
        let preview = try GitClient.conflictPreview(at: repo, version: conflict.theirs)
        XCTAssertEqual(preview.byteCount, 300_002)
        XCTAssertNil(preview.text)
        XCTAssertNotNil(preview.oid)
        try GitClient.resolveConflict(at: repo, conflict: conflict)
        try GitClient.continueOperation(at: repo, name: author, email: email)
        XCTAssertTrue(try GitClient.status(at: repo).isEmpty)
    }

    func testConflictSnapshotsDoNotReadUnrelatedWorktreeFileContents() throws {
        let (repo, target, _) = try diverged()
        try start(.merge, repo: repo, target: target)
        // Snapshot only enumerates conflict stages; a large untracked file does
        // not enter previews, history loading, or the edit round trip.
        try Data(repeating: 0, count: 8 * 1024 * 1024).write(to: repo.appendingPathComponent("unrelated.bin"))
        let start = ContinuousClock.now
        for _ in 0..<50 {
            XCTAssertEqual(try GitClient.operation(at: repo).conflicts.map(\.path), ["a.txt"])
        }
        print("CONFLICT_PERF snapshot-50-ms=\(start.duration(to: .now))")
    }

    func testStashConflictsCanBeConfirmedWithoutInventingMergeOperation() throws {
        let repo = try repository()
        try write("stashed\n", repo)
        try GitClient.saveStash(at: repo, message: "conflict", includeUntracked: false, name: author, email: email)
        let stash = try XCTUnwrap(GitClient.stashes(at: repo).first)
        try write("new base\n", repo); try commit(repo, "new base")
        XCTAssertThrowsError(try GitClient.applyStash(at: repo, oid: stash.oid, pop: true))
        let state = try GitClient.operation(at: repo)
        XCTAssertNil(state.kind)
        XCTAssertFalse(state.canContinue)
        XCTAssertFalse(state.canAbort)
        try resolve(repo)
        try GitClient.commit(at: repo, message: "resolved stash", name: author, email: email)
        XCTAssertEqual(try GitClient.stashes(at: repo).map(\.oid), [stash.oid])
    }

    func testImportedPausedMergeCanFinishWithoutChangingSource() throws {
        let (repo, target, original) = try diverged()
        try start(.merge, repo: repo, target: target)
        let sourceContents = try GitClient.readText(at: repo, relative: "a.txt")
        let root = repo.deletingLastPathComponent().appendingPathComponent("imported")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try GitClient.importRepository(from: repo, name: "copy", root: root)
        let copy = root.appendingPathComponent("copy")
        XCTAssertEqual(try GitClient.operation(at: copy).kind, .merge)
        try resolve(copy)
        try GitClient.continueOperation(at: copy, name: author, email: email)
        XCTAssertEqual(try GitClient.history(at: copy)[0].parents, [original, target])
        XCTAssertEqual(try GitClient.history(at: repo)[0].id, original)
        XCTAssertEqual(try GitClient.readText(at: repo, relative: "a.txt"), sourceContents)
        XCTAssertEqual(try GitClient.operation(at: repo).conflicts.count, 1)
    }

    func testChangedHeadCannotBeResetOrOverwrittenByRecovery() throws {
        let (repo, target, original) = try diverged()
        try start(.merge, repo: repo, target: target)
        var native: OpaquePointer?, reference: OpaquePointer?
        XCTAssertEqual(git_repository_open(&native, repo.path), 0)
        defer { git_repository_free(native) }
        var oid = git_oid(); XCTAssertEqual(git_oid_fromstr(&oid, target), 0)
        XCTAssertEqual(git_reference_create(&reference, native, "refs/heads/master", &oid, 1, "external branch change"), 0)
        git_reference_free(reference)
        XCTAssertThrowsError(try GitClient.abortOperation(at: repo))
        try resolve(repo)
        XCTAssertThrowsError(try GitClient.continueOperation(at: repo, name: author, email: email))
        XCTAssertEqual(try GitClient.history(at: repo)[0].id, target)
        XCTAssertNotEqual(target, original)
        XCTAssertEqual(try GitClient.readText(at: repo, relative: "a.txt"), "resolved\n")
    }

    func testExternalNativeOperationIsVisibleWithoutAssumingCleanInitialState() throws {
        let (repo, target, _) = try diverged()
        try start(.merge, repo: repo, target: target)
        try FileManager.default.removeItem(at: repo.appendingPathComponent(".git/gitling-operation.json"))
        let state = try GitClient.operation(at: repo)
        XCTAssertTrue(state.isExternal)
        XCTAssertEqual(state.kind, .merge)
        XCTAssertEqual(state.conflicts.count, 1)
        XCTAssertFalse(state.canContinue)
        XCTAssertFalse(state.canAbort)
        XCTAssertThrowsError(try GitClient.abortOperation(at: repo))
        XCTAssertThrowsError(try GitClient.continueOperation(at: repo, name: author, email: email))
        try resolve(repo)
        XCTAssertTrue(try GitClient.operation(at: repo).conflicts.isEmpty)
    }

    func testFileReplacedByDirectoryCannotRecursivelyDeleteUntrackedContent() throws {
        for kind in [GitOperationKind.merge, .rebase, .cherryPick] {
            let (repo, target, _) = try diverged()
            try start(kind, repo: repo, target: target)
            let conflict = try XCTUnwrap(GitClient.operation(at: repo).conflicts.first)
            let file = repo.appendingPathComponent("a.txt")
            try FileManager.default.removeItem(at: file)
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
            let child = file.appendingPathComponent("valuable.txt")
            try "untracked child\n".write(to: child, atomically: true, encoding: .utf8)
            XCTAssertThrowsError(try GitClient.resolveConflict(at: repo, conflict: conflict, delete: true))
            XCTAssertThrowsError(try GitClient.abortOperation(at: repo))
            XCTAssertEqual(try String(contentsOf: child, encoding: .utf8), "untracked child\n")
            XCTAssertEqual(try GitClient.operation(at: repo).conflicts, [conflict])
        }
    }

    func testResolvingAsDeletionRemovesOnlySymlinkNotItsTarget() throws {
        let (repo, target, _) = try diverged()
        try start(.merge, repo: repo, target: target)
        let conflict = try XCTUnwrap(GitClient.operation(at: repo).conflicts.first)
        let outside = repo.deletingLastPathComponent().appendingPathComponent("outside-kept.txt")
        try "keep\n".write(to: outside, atomically: true, encoding: .utf8)
        let file = repo.appendingPathComponent("a.txt")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
        try GitClient.resolveConflict(at: repo, conflict: conflict, delete: true)
        try GitClient.continueOperation(at: repo, name: author, email: email)
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "keep\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testDirectoryReplacedByFileIsPreservedWhenAbortIsBlocked() throws {
        let repo = try repository()
        let directory = repo.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "tracked\n".write(to: directory.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try commit(repo, "folder")
        try GitClient.createBranch(at: repo, name: "feature", checkout: true)
        try write("feature\n", repo); try commit(repo, "feature")
        try GitClient.checkout(at: repo, branch: "master")
        try write("master\n", repo); try commit(repo, "master")
        try GitClient.mergeBranch(at: repo, branch: "feature", name: author, email: email)
        try FileManager.default.removeItem(at: directory)
        try "new untracked content\n".write(to: directory, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try GitClient.abortOperation(at: repo))
        XCTAssertEqual(try String(contentsOf: directory, encoding: .utf8), "new untracked content\n")
        try FileManager.default.moveItem(at: directory, to: repo.appendingPathComponent("saved-content.txt"))
        try GitClient.abortOperation(at: repo)
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("tracked.txt"), encoding: .utf8), "tracked\n")
        XCTAssertEqual(try String(contentsOf: repo.appendingPathComponent("saved-content.txt"), encoding: .utf8), "new untracked content\n")
    }

}
