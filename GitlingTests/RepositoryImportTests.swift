import CryptoKit
import XCTest
@testable import Gitling

final class RepositoryImportTests: XCTestCase {
    private struct Fixture {
        var root: URL
        var source: URL
        var imports: URL { root.appendingPathComponent("repositories") }
    }

    private func fixture(committed: Bool = true) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let name = "source-" + UUID().uuidString
        try GitClient.initialize(name: name, root: root)
        let source = root.appendingPathComponent(name)
        try write("base\n", at: source.appendingPathComponent("a.txt"))
        try write("ignored.txt\n", at: source.appendingPathComponent(".gitignore"))
        if committed { try commit(source, "base") }
        return Fixture(root: root, source: source)
    }

    private func write(_ text: String, at url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func commit(_ repo: URL, _ message: String) throws {
        try GitClient.stageAll(at: repo)
        try GitClient.commit(at: repo, message: message, name: "Test", email: "test@example.com")
    }

    /// Contents and symbolic links, not access times changed by reading files.
    private func contents(_ directory: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey]))
        for case let url as URL in enumerator {
            let path = String(url.path.dropFirst(directory.path.count + 1))
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            if values.isSymbolicLink == true {
                result[path] = "link:" + (try FileManager.default.destinationOfSymbolicLink(atPath: url.path))
            } else if values.isDirectory == true {
                result[path] = "directory"
            } else {
                result[path] = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
            }
        }
        return result
    }

    private func assertRolledBack(_ f: Fixture, name: String = "imported", file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.imports.appendingPathComponent(name).path), file: file, line: line)
        let staging = f.root.appendingPathComponent(".gitling-imports")
        let children = (try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []
        XCTAssertTrue(children.isEmpty, file: file, line: line)
    }

    func testCopyPreservesWorktreeIndexStashRefsReflogsAndUnreferencedObjects() throws {
        let f = try fixture()
        let source = f.source
        try GitClient.addRemote(at: source, name: "company", url: "https://example.invalid/team/project.git")
        try GitClient.createBranch(at: source, name: "feature/work", checkout: true)
        try write("feature\n", at: source.appendingPathComponent("a.txt"))
        try commit(source, "feature")
        try GitClient.checkout(at: source, branch: "master")
        try GitClient.createBranch(at: source, name: "lost", checkout: true)
        try write("preserve unreferenced commit\n", at: source.appendingPathComponent("a.txt"))
        try commit(source, "unreferenced")
        let lost = try XCTUnwrap(GitClient.history(at: source).first?.id)
        try GitClient.checkout(at: source, branch: "master")
        try FileManager.default.removeItem(at: source.appendingPathComponent(".git/refs/heads/lost"))
        let base = try XCTUnwrap(GitClient.history(at: source).first?.id)
        let tags = source.appendingPathComponent(".git/refs/tags")
        try FileManager.default.createDirectory(at: tags, withIntermediateDirectories: true)
        try write(base + "\n", at: tags.appendingPathComponent("v1"))
        try write("saved\n", at: source.appendingPathComponent("stash.txt"))
        try GitClient.saveStash(at: source, message: "preserve stash", includeUntracked: true, name: "Test", email: "test@example.com")
        try write("staged\n", at: source.appendingPathComponent("a.txt"))
        try GitClient.stage(at: source, path: "a.txt")
        try write("unstaged\n", at: source.appendingPathComponent("a.txt"))
        try write("untracked\n", at: source.appendingPathComponent("new.txt"))
        try write("ignored\n", at: source.appendingPathComponent("ignored.txt"))
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("file-link").path, withDestinationPath: "a.txt")
        let before = try contents(source)
        let status = try GitClient.status(at: source)
        let history = try GitClient.history(at: source, allBranches: true).map(\.id)
        let stash = try GitClient.stashes(at: source).map(\.oid)
        try GitClient.importRepository(from: source, name: "imported", root: f.imports)
        let imported = f.imports.appendingPathComponent("imported")
        XCTAssertEqual(try contents(source), before)
        XCTAssertEqual(try GitClient.status(at: imported), status)
        XCTAssertEqual(try GitClient.history(at: imported, allBranches: true).map(\.id), history)
        XCTAssertEqual(try GitClient.stashes(at: imported).map(\.oid), stash)
        XCTAssertEqual(try GitClient.remotes(at: imported).map(\.url), ["https://example.invalid/team/project.git"])
        XCTAssertEqual(try contents(imported.appendingPathComponent(".git/objects")), try contents(source.appendingPathComponent(".git/objects")))
        XCTAssertEqual(try Data(contentsOf: imported.appendingPathComponent(".git/index")), try Data(contentsOf: source.appendingPathComponent(".git/index")))
        XCTAssertEqual(try Data(contentsOf: imported.appendingPathComponent(".git/logs/HEAD")), try Data(contentsOf: source.appendingPathComponent(".git/logs/HEAD")))
        XCTAssertEqual(try GitClient.readText(at: imported, relative: "new.txt"), "untracked\n")
        XCTAssertEqual(try GitClient.readText(at: imported, relative: "ignored.txt"), "ignored\n")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: imported.appendingPathComponent("file-link").path), "a.txt")
        XCTAssertTrue(try GitClient.show(at: imported, commit: lost).contains("preserve unreferenced commit"))
        XCTAssertTrue(try GitClient.diff(at: imported, scope: .staged).contains("+staged"))
        XCTAssertTrue(try GitClient.diff(at: imported, scope: .worktree).contains("+unstaged"))
        XCTAssertEqual(try Data(contentsOf: imported.appendingPathComponent(".git/refs/tags/v1")), try Data(contentsOf: tags.appendingPathComponent("v1")))
    }

    func testAbsoluteSourceWorktreeIsReboundOnlyInImportedCopy() throws {
        let f = try fixture()
        let config = f.source.appendingPathComponent(".git/config")
        var text = try String(contentsOf: config, encoding: .utf8)
        text += "\n[core]\n\tworktree = \(f.source.path)\n"
        try write(text, at: config)
        let before = try contents(f.source)
        try GitClient.importRepository(from: f.source, name: "imported", root: f.imports)
        let imported = f.imports.appendingPathComponent("imported")
        try write("only the copy\n", at: imported.appendingPathComponent("a.txt"))
        try commit(imported, "independent copy")
        XCTAssertEqual(try contents(f.source), before)
        XCTAssertEqual(try GitClient.readText(at: f.source, relative: "a.txt"), "base\n")
        XCTAssertEqual(try GitClient.history(at: imported).count, 2)
        XCTAssertEqual(try GitClient.history(at: f.source).count, 1)
    }

    func testReadOnlySourceRemainsReadOnlyWhileItsCopyIsEditable() throws {
        let f = try fixture()
        let file = f.source.appendingPathComponent("a.txt")
        let config = f.source.appendingPathComponent(".git/config")
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: config.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: f.source.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.source.path)
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: config.path)
        }
        let before = try contents(f.source)
        try GitClient.importRepository(from: f.source, name: "imported", root: f.imports)
        let imported = f.imports.appendingPathComponent("imported")
        try write("editable copy\n", at: imported.appendingPathComponent("a.txt"))
        try commit(imported, "copy edit")
        XCTAssertEqual(try contents(f.source), before)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: f.source.path)[.posixPermissions] as? NSNumber)?.intValue, 0o555)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: config.path)[.posixPermissions] as? NSNumber)?.intValue, 0o444)
    }

    func testUnbornWorkingRepositoryImportsWithoutCheckoutOrDataLoss() throws {
        let f = try fixture(committed: false)
        try GitClient.stage(at: f.source, path: "a.txt")
        let before = try contents(f.source)
        try GitClient.importRepository(from: f.source, name: "imported", root: f.imports)
        let imported = f.imports.appendingPathComponent("imported")
        XCTAssertTrue(try GitClient.history(at: imported).isEmpty)
        XCTAssertTrue(try GitClient.status(at: imported).contains { $0.path == "a.txt" && $0.staged })
        XCTAssertEqual(try contents(f.source), before)
    }

    func testEmptyBareRepositoryBecomesAnIndependentEditableCopy() throws {
        let f = try fixture()
        let name = "bare-" + UUID().uuidString
        try GitClient.initialize(name: name, root: f.root, bare: true)
        let bare = f.root.appendingPathComponent(name)
        let before = try contents(bare)
        try GitClient.importRepository(from: bare, name: "imported", root: f.imports)
        let imported = f.imports.appendingPathComponent("imported")
        XCTAssertTrue(try GitClient.history(at: imported).isEmpty)
        try write("new working file\n", at: imported.appendingPathComponent("a.txt"))
        try commit(imported, "first imported commit")
        XCTAssertEqual(try GitClient.history(at: imported).count, 1)
        XCTAssertEqual(try contents(bare), before)
    }

    func testPartialCopyAndCancellationFailuresRemoveOnlyTheirStagingDirectory() throws {
        let f = try fixture()
        let before = try contents(f.source)
        for cancel in [false, true] {
            XCTAssertThrowsError(try GitClient.importRepository(from: f.source, name: "imported", root: f.imports, copyItem: { _, target in
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                try self.write("partial", at: target.appendingPathComponent("partial"))
                if cancel { throw CancellationError() }
                try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: target.path)
                throw CocoaError(.fileWriteOutOfSpace)
            }))
            try assertRolledBack(f)
            XCTAssertEqual(try contents(f.source), before)
        }
    }

    func testCorruptCopiedMetadataRollsBackWithoutTouchingSource() throws {
        let f = try fixture()
        let before = try contents(f.source)
        XCTAssertThrowsError(try GitClient.importRepository(from: f.source, name: "imported", root: f.imports, copyItem: { source, target in
            try FileManager.default.copyItem(at: source, to: target)
            try self.write("not a valid HEAD\n", at: target.appendingPathComponent(".git/HEAD"))
        }))
        try assertRolledBack(f)
        XCTAssertEqual(try contents(f.source), before)
    }

    func testMissingCopiedWorkingFileDoesNotPublishAnIncompleteRepository() throws {
        let f = try fixture()
        try write("must survive\n", at: f.source.appendingPathComponent("untracked.txt"))
        let before = try contents(f.source)
        XCTAssertThrowsError(try GitClient.importRepository(from: f.source, name: "imported", root: f.imports, copyItem: { source, target in
            try FileManager.default.copyItem(at: source, to: target)
            try FileManager.default.removeItem(at: target.appendingPathComponent("untracked.txt"))
        }))
        try assertRolledBack(f)
        XCTAssertEqual(try contents(f.source), before)
    }

    func testConcurrentSourceEditIsPreservedAndImportIsNotPublished() throws {
        let f = try fixture()
        let originalHead = try GitClient.history(at: f.source).first?.id
        XCTAssertThrowsError(try GitClient.importRepository(from: f.source, name: "imported", root: f.imports, copyItem: { source, target in
            try FileManager.default.copyItem(at: source, to: target)
            try self.write("external edit during copy\n", at: source.appendingPathComponent("a.txt"))
        }))
        try assertRolledBack(f)
        XCTAssertEqual(try GitClient.readText(at: f.source, relative: "a.txt"), "external edit during copy\n")
        XCTAssertEqual(try GitClient.history(at: f.source).first?.id, originalHead)
    }

    func testTargetAppearingDuringCopyIsNeverReplacedEvenIfEmpty() throws {
        let f = try fixture()
        let before = try contents(f.source)
        let target = f.imports.appendingPathComponent("imported")
        XCTAssertThrowsError(try GitClient.importRepository(from: f.source, name: "imported", root: f.imports, copyItem: { source, staged in
            try FileManager.default.copyItem(at: source, to: staged)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        }))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), [])
        XCTAssertEqual(try contents(f.source), before)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: f.root.appendingPathComponent(".gitling-imports").path).isEmpty)
    }

    func testExistingTargetAndDanglingSymlinkAreNotReplaced() throws {
        let f = try fixture()
        try FileManager.default.createDirectory(at: f.imports, withIntermediateDirectories: true)
        let before = try contents(f.source)
        let target = f.imports.appendingPathComponent("imported")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try write("keep", at: target.appendingPathComponent("sentinel"))
        XCTAssertThrowsError(try GitClient.importRepository(from: f.source, name: "imported", root: f.imports))
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("sentinel"), encoding: .utf8), "keep")
        try FileManager.default.removeItem(at: target)
        try FileManager.default.createSymbolicLink(atPath: target.path, withDestinationPath: "missing-target")
        XCTAssertThrowsError(try GitClient.importRepository(from: f.source, name: "imported", root: f.imports))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: target.path), "missing-target")
        XCTAssertEqual(try contents(f.source), before)
    }

    func testSourceLocksAndExternalGitDependenciesAreRejectedWithoutModification() throws {
        for item in ["index.lock", "commondir", "objects/info/alternates"] {
            let f = try fixture()
            let file = f.source.appendingPathComponent(".git").appendingPathComponent(item)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try write("external-or-busy\n", at: file)
            let before = try contents(f.source)
            XCTAssertThrowsError(try GitClient.importRepository(from: f.source, name: "imported", root: f.imports))
            XCTAssertEqual(try contents(f.source), before)
            try assertRolledBack(f)
        }
    }

    func testGitFileAndMetadataSymlinkAreRejectedInsteadOfKeepingSourceReferences() throws {
        let f = try fixture()
        let git = f.source.appendingPathComponent(".git")
        let external = f.root.appendingPathComponent("external-git")
        try FileManager.default.moveItem(at: git, to: external)
        try write("gitdir: \(external.path)\n", at: git)
        let before = try contents(f.source)
        XCTAssertThrowsError(try GitClient.importRepository(from: f.source, name: "imported", root: f.imports))
        XCTAssertEqual(try contents(f.source), before)
        try FileManager.default.removeItem(at: git)
        try FileManager.default.createSymbolicLink(at: git, withDestinationURL: external)
        XCTAssertThrowsError(try GitClient.importRepository(from: f.source, name: "imported", root: f.imports))
        try assertRolledBack(f)
    }

    func testOverlappingDestinationInvalidNamesAndChildFolderLeaveSourceUnchanged() throws {
        let f = try fixture()
        let before = try contents(f.source)
        XCTAssertThrowsError(try GitClient.importRepository(from: f.source, name: "copy", root: f.source.appendingPathComponent("nested-imports")))
        XCTAssertEqual(try contents(f.source), before)
        for name in ["../outside", ".hidden", "bad/name", ""] {
            XCTAssertThrowsError(try GitClient.importRepository(from: f.source, name: name, root: f.imports))
        }
        let child = f.source.appendingPathComponent("subdirectory")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        XCTAssertThrowsError(try GitClient.importRepository(from: child, name: "imported", root: f.imports))
        try assertRolledBack(f)
    }

    func testFileCopyDoesNotHoldTheGlobalGitLock() async throws {
        let f = try fixture()
        let source = f.source
        let root = f.imports
        let copying = expectation(description: "copy started")
        let releaseCopy = DispatchSemaphore(value: 0)
        let task = Task.detached {
            try GitClient.importRepository(from: source, name: "imported", root: root, copyItem: { source, target in
                copying.fulfill()
                guard releaseCopy.wait(timeout: .now() + 10) == .success else { throw CancellationError() }
                try FileManager.default.copyItem(at: source, to: target)
            })
        }
        await fulfillment(of: [copying], timeout: 5)
        let metadataRead = expectation(description: "metadata read finishes before copy is released")
        let reader = Task.detached {
            _ = try GitClient.header(at: source)
            metadataRead.fulfill()
        }
        await fulfillment(of: [metadataRead], timeout: 2)
        releaseCopy.signal()
        try await reader.value
        try await task.value
    }

    @MainActor
    func testSuccessfulImportClearsStaleWorkspaceAndAccountLinksOnlyAfterCommit() async throws {
        let f = try fixture()
        let name = "imported-" + UUID().uuidString
        let stale = f.root.appendingPathComponent("old-workspace")
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try write("keep old workspace", at: stale.appendingPathComponent("sentinel"))
        try WorktreeLink.save(repoName: name, data: WorktreeLink.bookmark(for: stale))
        let store = RepoStore(root: f.imports, reloadOnStart: false)
        let account = try XCTUnwrap(store.addAccount(provider: .gitlab, baseURL: "https://import-test.example.invalid", username: UUID().uuidString, token: "test-only"))
        store.linkRepo(name, to: account)
        defer { store.removeAccount(account); store.removeRepoLink(name); WorktreeLink.remove(repoName: name); RepoDetailCache.remove(name) }
        RepoDetailCache.save(RepoDetailSnapshot(), for: name)
        store.importRepository(name: name, sourceBookmark: try WorktreeLink.bookmark(for: f.source))
        for _ in 0..<1000 where store.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(store.isBusy)
        XCTAssertNil(store.alert)
        XCTAssertNil(store.linkedAccountID(for: name))
        XCTAssertNil(WorktreeLink.begin(repoName: name))
        XCTAssertNil(RepoDetailCache.load(name))
        XCTAssertEqual(try GitClient.readText(at: f.imports.appendingPathComponent(name), relative: "a.txt"), "base\n")
        XCTAssertEqual(try String(contentsOf: stale.appendingPathComponent("sentinel"), encoding: .utf8), "keep old workspace")
        // A later failed duplicate import must keep the existing repo's associations.
        store.linkRepo(name, to: account)
        store.importRepository(name: name, sourceBookmark: try WorktreeLink.bookmark(for: f.source))
        for _ in 0..<1000 where store.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(store.alert)
        XCTAssertEqual(store.linkedAccountID(for: name), account.id)
    }

    @MainActor
    func testStoreBookmarkImportPublishesOnlySuccessfulCopy() async throws {
        let f = try fixture()
        let before = try contents(f.source)
        let store = RepoStore(root: f.imports, reloadOnStart: false)
        store.importRepository(name: "imported", sourceBookmark: try WorktreeLink.bookmark(for: f.source))
        for _ in 0..<1000 where store.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(store.isBusy)
        XCTAssertNil(store.alert)
        XCTAssertEqual(store.focusName, "imported")
        XCTAssertEqual(store.repos.map(\.name), ["imported"])
        XCTAssertEqual(try contents(f.source), before)
        store.importRepository(name: "imported", sourceBookmark: try WorktreeLink.bookmark(for: f.source))
        for _ in 0..<1000 where store.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(store.alert)
        XCTAssertEqual(store.repos.map(\.name), ["imported"])
        XCTAssertEqual(try contents(f.source), before)
    }
}
