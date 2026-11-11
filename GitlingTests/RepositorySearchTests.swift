import Darwin
import Clibgit2
import CryptoKit
import XCTest
@testable import Gitling

final class RepositorySearchTests: XCTestCase {
    private func repository() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let name = "search-" + UUID().uuidString
        try GitClient.initialize(name: name, root: root)
        let repo = root.appendingPathComponent(name)
        addTeardownBlock { try? FileManager.default.removeItem(at: root); WorktreeLink.remove(repoName: name) }
        return repo
    }
    private func write(_ text: String, _ path: String, _ repo: URL) throws {
        let file = repo.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }
    private func commit(_ repo: URL, message: String, name: String = "Search Author", email: String = "search@example.invalid") throws -> String {
        try GitClient.stageAll(at: repo)
        try GitClient.commit(at: repo, message: message, name: name, email: email)
        return try GitClient.history(at: repo, limit: 1)[0].id
    }
    private func collect<T: Sendable>(_ cursor: RepositorySearchCursor<T>, size: Int = 37) throws -> ([T], Int) {
        var result: [T] = [], scanned = 0, last = 0
        while true {
            let page = try cursor.nextPage(limit: size)
            result += page.items; scanned = page.scanned
            XCTAssertGreaterThanOrEqual(scanned, last); last = scanned
            if !page.hasMore { break }
            XCTAssertFalse(page.items.isEmpty)
        }
        return (result, scanned)
    }
    private func withRepo<T>(_ repo: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
        var pointer: OpaquePointer?
        XCTAssertEqual(git_repository_open(&pointer, repo.path), 0)
        let opened = try XCTUnwrap(pointer)
        defer { git_repository_free(opened) }
        return try body(opened)
    }
    private func ref(_ repo: URL, _ name: String, _ target: String) throws {
        try withRepo(repo) { raw in
            var oid = git_oid(), reference: OpaquePointer?
            XCTAssertEqual(git_oid_fromstr(&oid, target), 0)
            XCTAssertEqual(git_reference_create(&reference, raw, name, &oid, 1, "offline search fixture"), 0)
            git_reference_free(reference)
        }
    }

    private func appendCommits(_ repo: URL, count: Int, prefix: String) throws {
        try withRepo(repo) { raw in
            var head: OpaquePointer?, tree: OpaquePointer?, signature: UnsafeMutablePointer<git_signature>?
            XCTAssertEqual(git_repository_head(&head, raw), 0)
            defer { git_reference_free(head) }
            var oid = git_reference_target(head)!.pointee
            var initial: OpaquePointer?
            XCTAssertEqual(git_commit_lookup(&initial, raw, &oid), 0)
            XCTAssertEqual(git_commit_tree(&tree, initial), 0)
            git_commit_free(initial)
            defer { git_tree_free(tree) }
            XCTAssertEqual(git_signature_now(&signature, "New Author", "new@unit.invalid"), 0)
            defer { git_signature_free(signature) }
            for number in 0..<count {
                var parent: OpaquePointer?, result = git_oid()
                XCTAssertEqual(git_commit_lookup(&parent, raw, &oid), 0)
                var parents = [parent]
                let code = parents.withUnsafeMutableBufferPointer {
                    git_commit_create(&result, raw, "HEAD", signature, signature, nil, "\(prefix) \(number)", tree, 1, $0.baseAddress)
                }
                git_commit_free(parent)
                XCTAssertEqual(code, 0)
                oid = result
            }
        }
    }

    func testMessageBodyAuthorEmailUnicodeAndCaseInsensitiveMatching() throws {
        let repo = try repository()
        try write("base", "a.txt", repo)
        let oid = try commit(repo, message: "summary only\n\nDeep body needle：存储与内存\n", name: "Alice Example", email: "alice@unit.invalid")
        for (query, field) in [("DEEP BODY NEEDLE", CommitSearchField.message), ("存储与内存", .message), ("alice example", .author), ("ALICE@UNIT.INVALID", .author), ("Alice", .all)] {
            let page = try GitClient.historySearch(at: repo, query: query, field: field).nextPage()
            XCTAssertEqual(page.items.map(\.id), [oid], query)
            XCTAssertFalse(page.hasMore)
        }
        XCTAssertTrue(try GitClient.historySearch(at: repo, query: "Alice", field: .message).nextPage().items.isEmpty)
    }

    func testFullAndAbbreviatedOIDAreLiteralPrefixesAndInvalidInputIsReported() throws {
        let repo = try repository()
        try write("base", "a.txt", repo)
        let oid = try commit(repo, message: "base")
        for query in [oid, String(oid.prefix(9)).uppercased()] {
            XCTAssertEqual(try GitClient.historySearch(at: repo, query: query, field: .oid).nextPage().items.map(\.id), [oid])
        }
        XCTAssertThrowsError(try GitClient.historySearch(at: repo, query: "not-an-oid", field: .oid))
        XCTAssertThrowsError(try GitClient.historySearch(at: repo, query: String(repeating: "a", count: 41), field: .oid))
    }

    func testSearchFindsCommitBeyondTheFirstLoadedHistoryPage() throws {
        let repo = try repository()
        try write("base", "a.txt", repo)
        let oldest = try commit(repo, message: "unique-old-message\n\nfull-body-only", name: "Unique Old Author")
        // Empty commits are real independent objects and avoid filesystem noise.
        try appendCommits(repo, count: 330, prefix: "newer")
        XCTAssertFalse(try GitClient.history(at: repo, limit: 300).contains { $0.id == oldest })
        let page = try GitClient.historySearch(at: repo, query: "full-body-only", field: .message).nextPage()
        XCTAssertEqual(page.items.map(\.id), [oldest])
        XCTAssertEqual(page.scanned, 331)
    }

    func testPaginationContinuesOneWalkWithoutDuplicatesAndScannedCountDoesNotRestart() throws {
        let repo = try repository()
        try write("base", "a.txt", repo)
        _ = try commit(repo, message: "match base")
        try appendCommits(repo, count: 112, prefix: "match")
        let cursor = try GitClient.historySearch(at: repo, query: "match", field: .message)
        let (items, scanned) = try collect(cursor, size: 11)
        XCTAssertEqual(items.count, 113)
        XCTAssertEqual(Set(items.map(\.id)).count, 113)
        XCTAssertEqual(scanned, 113)
        XCTAssertTrue(try cursor.nextPage().items.isEmpty)
    }

    func testCurrentSelectedRemoteTagAndDetachedScopesAreExplicit() throws {
        let repo = try repository()
        try write("base", "a.txt", repo); _ = try commit(repo, message: "common")
        try GitClient.createBranch(at: repo, name: "feature/topic", checkout: true)
        try write("feature", "a.txt", repo)
        let feature = try commit(repo, message: "scope-only-feature")
        try ref(repo, "refs/remotes/team/topic", feature)
        try ref(repo, "refs/tags/tag-only", feature)
        try GitClient.checkout(at: repo, branch: "master")
        XCTAssertTrue(try GitClient.historySearch(at: repo, query: "scope-only-feature", scope: .current).nextPage().items.isEmpty)
        XCTAssertEqual(try GitClient.historySearch(at: repo, query: "scope-only-feature", scope: .reference("refs/remotes/team/topic")).nextPage().items.map(\.id), [feature])
        try withRepo(repo) { raw in XCTAssertEqual(git_reference_remove(raw, "refs/heads/feature/topic"), 0); XCTAssertEqual(git_reference_remove(raw, "refs/remotes/team/topic"), 0) }
        XCTAssertEqual(try GitClient.historySearch(at: repo, query: "scope-only-feature", scope: .all).nextPage().items.map(\.id), [feature])
        try GitClient.checkoutTag(at: repo, tag: GitClient.tagDetail(at: repo, name: "tag-only"))
        try withRepo(repo) { raw in XCTAssertEqual(git_reference_remove(raw, "refs/tags/tag-only"), 0) }
        XCTAssertEqual(try GitClient.historySearch(at: repo, query: "scope-only-feature", scope: .all).nextPage().items.map(\.id), [feature])
        XCTAssertThrowsError(try GitClient.historySearch(at: repo, query: "x", scope: .reference("master")))
        XCTAssertThrowsError(try GitClient.historySearch(at: repo, query: "x", scope: .reference("refs/stash")))
    }

    func testNonCommitTagIsSkippedButCorruptHistoryFailsInsteadOfClaimingNoResults() throws {
        let repo = try repository()
        try write("base", "a.txt", repo); _ = try commit(repo, message: "found")
        try withRepo(repo) { raw in
            var oid = git_oid(), reference: OpaquePointer?
            let data = Data("blob".utf8)
            XCTAssertEqual(data.withUnsafeBytes { git_blob_create_from_buffer(&oid, raw, $0.baseAddress, $0.count) }, 0)
            XCTAssertEqual(git_reference_create(&reference, raw, "refs/tags/blob", &oid, 0, "test"), 0)
            git_reference_free(reference)
        }
        XCTAssertEqual(try GitClient.historySearch(at: repo, query: "found").nextPage().items.count, 1)
        try (String(repeating: "f", count: 40) + "\n").write(to: repo.appendingPathComponent(".git/refs/heads/broken"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try GitClient.historySearch(at: repo, query: "found"))
    }

    func testHistoryQueryIsReadOnlyAndDoesNotNeedAnAvailableExternalWorktree() throws {
        let repo = try repository()
        try write("base", "a.txt", repo); _ = try commit(repo, message: "searchable")
        try write("staged", "a.txt", repo); try GitClient.stage(at: repo, path: "a.txt")
        try write("unstaged", "a.txt", repo)
        let index = try Data(contentsOf: repo.appendingPathComponent(".git/index")), head = try Data(contentsOf: repo.appendingPathComponent(".git/HEAD"))
        try WorktreeLink.save(repoName: repo.lastPathComponent, data: Data("broken bookmark".utf8))
        XCTAssertEqual(try GitClient.historySearch(at: repo, query: "searchable").nextPage().items.count, 1)
        XCTAssertEqual(try Data(contentsOf: repo.appendingPathComponent(".git/index")), index)
        XCTAssertEqual(try Data(contentsOf: repo.appendingPathComponent(".git/HEAD")), head)
        XCTAssertEqual(try String(contentsOf: repo.appendingPathComponent("a.txt"), encoding: .utf8), "unstaged")
        XCTAssertThrowsError(try GitClient.fileSearch(at: repo, query: "a"))
    }

    func testEmptyQueryAndEmptyRepositoryDoNotPretendThereAreMatches() throws {
        let repo = try repository()
        XCTAssertTrue(try GitClient.historySearch(at: repo, query: "anything").nextPage().items.isEmpty)
        XCTAssertTrue(try GitClient.historySearch(at: repo, query: "anything", scope: .current).nextPage().items.isEmpty)
        XCTAssertEqual(try GitClient.historySearch(at: repo, query: " \n ").nextPage().scanned, 0)
        XCTAssertEqual(try GitClient.fileSearch(at: repo, query: " ").nextPage().scanned, 0)
    }

    func testFileNameAndRelativePathQueriesIncludeHiddenIgnoredAndUntrackedFiles() throws {
        let repo = try repository()
        for path in ["src/嵌入式/Storage[1].swift", "docs/storage.md", ".hidden/notes.txt", "ignored/secret.txt"] {
            try write("contents must not be searched", path, repo)
        }
        try write("ignored/\n", ".gitignore", repo)
        let results = try collect(GitClient.fileSearch(at: repo, query: "STORAGE")).0
        XCTAssertEqual(Set(results.map(\.path)), ["src/嵌入式/Storage[1].swift", "docs/storage.md"])
        XCTAssertEqual(try GitClient.fileSearch(at: repo, query: "src/嵌入式/").nextPage().items.map(\.path), ["src/嵌入式/Storage[1].swift"])
        XCTAssertEqual(try GitClient.fileSearch(at: repo, query: ".hidden/notes").nextPage().items.count, 1)
        XCTAssertEqual(try GitClient.fileSearch(at: repo, query: "ignored/secret").nextPage().items.count, 1)
        XCTAssertTrue(try GitClient.fileSearch(at: repo, query: "contents must not").nextPage().items.isEmpty)
        XCTAssertTrue(try GitClient.fileSearch(at: repo, query: "Storage[1]").nextPage().items.count == 1)
    }

    func testFilePaginationWalksPastHundredsOfEarlierEntriesWithoutDuplicates() throws {
        let repo = try repository()
        for index in 0..<350 { try write("file", "deep/path/match-\(index).txt", repo) }
        let (items, scanned) = try collect(GitClient.fileSearch(at: repo, query: "match-"), size: 17)
        XCTAssertEqual(items.count, 350)
        XCTAssertEqual(Set(items.map(\.path)).count, 350)
        XCTAssertGreaterThanOrEqual(scanned, 352)
        XCTAssertTrue(items.allSatisfy { !$0.isDirectory })
    }

    func testGitMetadataAndSymlinkedFilesDirectoriesLoopsAndDanglingLinksAreExcluded() throws {
        let repo = try repository()
        try write("safe", "safe/needle.txt", repo)
        try write("private", ".git/needle.txt", repo)
        let outside = repo.deletingLastPathComponent().appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "private".write(to: outside.appendingPathComponent("needle.txt"), atomically: true, encoding: .utf8)
        for (path, target) in [("linked-dir", outside), ("needle-link.txt", outside.appendingPathComponent("needle.txt")), ("loop", repo), ("dangling", outside.appendingPathComponent("missing"))] {
            try FileManager.default.createSymbolicLink(at: repo.appendingPathComponent(path), withDestinationURL: target)
        }
        XCTAssertEqual(try collect(GitClient.fileSearch(at: repo, query: "needle")).0.map(\.path), ["safe/needle.txt"])
        XCTAssertThrowsError(try GitClient.readText(at: repo, relative: "needle-link.txt"))
        XCTAssertThrowsError(try GitClient.readText(at: repo, relative: "linked-dir/needle.txt"))
        XCTAssertThrowsError(try GitClient.readText(at: repo, relative: ".git/needle.txt"))
        XCTAssertThrowsError(try GitClient.readText(at: repo, relative: "../outside/needle.txt"))
    }

    func testPreviewRechecksResultReplacedBySymlinkAndSpecialFile() throws {
        let repo = try repository()
        try write("safe", "match.txt", repo)
        XCTAssertEqual(try GitClient.fileSearch(at: repo, query: "match").nextPage().items.count, 1)
        let file = repo.appendingPathComponent("match.txt"), outside = repo.deletingLastPathComponent().appendingPathComponent("outside.txt")
        try "outside".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
        XCTAssertThrowsError(try GitClient.readText(at: repo, relative: "match.txt"))
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(mkfifo(file.path, 0o600), 0)
        XCTAssertThrowsError(try GitClient.readText(at: repo, relative: "match.txt"))
    }

    func testExternalFileSearchKeepsActualScopeAndMissingRootIsNotRecreated() throws {
        let repo = try repository()
        try write("base", "a.txt", repo); _ = try commit(repo, message: "base")
        let external = repo.deletingLastPathComponent().appendingPathComponent("external")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try GitClient.link(at: repo, bookmark: WorktreeLink.bookmark(for: external))
        let actual = external.appendingPathComponent(repo.lastPathComponent)
        try write("external", "deep/needle.txt", actual)
        XCTAssertEqual(try GitClient.fileSearch(at: repo, query: "needle").nextPage().items.map(\.path), ["deep/needle.txt"])
        XCTAssertEqual(try GitClient.readText(at: repo, relative: "deep/needle.txt"), "external")
        try FileManager.default.removeItem(at: external)
        XCTAssertThrowsError(try GitClient.fileSearch(at: repo, query: "needle"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: external.path))
    }

    func testCursorDetectsReplacedWorkingFolderAndCancellationStopsBothSearches() throws {
        let repo = try repository()
        try write("base", "a.txt", repo); _ = try commit(repo, message: "base")
        let fileCursor = try GitClient.fileSearch(at: repo, query: "a")
        let parked = repo.deletingLastPathComponent().appendingPathComponent("parked")
        try FileManager.default.moveItem(at: repo, to: parked)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        XCTAssertThrowsError(try fileCursor.nextPage())
        try FileManager.default.removeItem(at: repo); try FileManager.default.moveItem(at: parked, to: repo)
        let history = try GitClient.historySearch(at: repo, query: "base")
        history.cancel()
        XCTAssertThrowsError(try history.nextPage()) { XCTAssertTrue($0 is CancellationError) }
        let files = try GitClient.fileSearch(at: repo, query: "a")
        files.cancel()
        XCTAssertThrowsError(try files.nextPage()) { XCTAssertTrue($0 is CancellationError) }
        let cancelled = SearchCancellation(); cancelled.cancel()
        XCTAssertThrowsError(try GitClient.historySearch(at: repo, query: "a", cancellation: cancelled))
        XCTAssertThrowsError(try GitClient.fileSearch(at: repo, query: "a", cancellation: cancelled))
    }
    func testHistoryCursorKeepsItsReferenceSnapshotUntilAQueryIsRestarted() throws {
        let repo = try repository()
        try write("base", "a.txt", repo); let first = try commit(repo, message: "match")
        let reader = try GitClient.historySearch(at: repo, query: "match")
        try appendCommits(repo, count: 2, prefix: "match")
        XCTAssertEqual(try collect(reader).0.map(\.id), [first])
        XCTAssertEqual(try collect(GitClient.historySearch(at: repo, query: "match")).0.count, 3)
    }

    func testFileSearchDoesNotReadLargeContentOrChangeIndexHeadAndDirtyFiles() throws {
        let repo = try repository()
        try write("base", "a.txt", repo); _ = try commit(repo, message: "base")
        try write("dirty", "a.txt", repo)
        let big = repo.appendingPathComponent("large-needle.bin")
        let data = Data(repeating: 0x91, count: 8 * 1024 * 1024)
        try data.write(to: big)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: big.path)
        let before = try Data(contentsOf: repo.appendingPathComponent(".git/index")), head = try Data(contentsOf: repo.appendingPathComponent(".git/HEAD"))
        XCTAssertEqual(try GitClient.fileSearch(at: repo, query: "large-needle").nextPage().items.map(\.path), ["large-needle.bin"])
        XCTAssertEqual(try Data(contentsOf: repo.appendingPathComponent(".git/index")), before)
        XCTAssertEqual(try Data(contentsOf: repo.appendingPathComponent(".git/HEAD")), head)
        XCTAssertEqual(try String(contentsOf: repo.appendingPathComponent("a.txt"), encoding: .utf8), "dirty")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: big.path)
        XCTAssertEqual(try Data(contentsOf: big), data)
        XCTAssertThrowsError(try GitClient.readText(at: repo, relative: "large-needle.bin"))
    }

    func testSearchRejectsSymbolicWorkingRootRatherThanFollowingIt() throws {
        let repo = try repository()
        try write("safe", "needle.txt", repo)
        let link = repo.deletingLastPathComponent().appendingPathComponent("linked-root-" + UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: repo)
        XCTAssertThrowsError(try GitClient.fileSearch(at: link, query: "needle"))
        XCTAssertThrowsError(try GitClient.readText(at: link, relative: "needle.txt"))
    }

    func testReadOnlyQueriesDoNotTakeTheRepositoryWriteLock() throws {
        let repo = try repository()
        try write("base", "a.txt", repo); _ = try commit(repo, message: "base")
        try RepoWriteLock.withLock(at: repo) {
            XCTAssertEqual(try GitClient.historySearch(at: repo, query: "base").nextPage().items.count, 1)
            XCTAssertEqual(try GitClient.fileSearch(at: repo, query: "a.txt").nextPage().items.count, 1)
        }
    }

}
