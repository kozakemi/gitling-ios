import Clibgit2
import SwiftUI
import XCTest
@testable import Gitling

final class FileInspectionTests: XCTestCase {
    private func repository() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let name = "inspect-" + UUID().uuidString
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

    private func commit(_ repo: URL, _ message: String) throws -> String {
        try GitClient.stageAll(at: repo)
        try GitClient.commit(at: repo, message: message, name: "Inspect Author", email: "inspect@example.invalid")
        return try GitClient.history(at: repo, limit: 1)[0].id
    }

    private func collect(_ cursor: RepositorySearchCursor<FileHistoryEntry>, size: Int = 10) throws -> (items: [FileHistoryEntry], scanned: Int) {
        var items: [FileHistoryEntry] = []
        var scanned = 0
        var previous = 0
        while true {
            let page = try cursor.nextPage(limit: size)
            items += page.items
            scanned = page.scanned
            XCTAssertGreaterThanOrEqual(scanned, previous)
            previous = scanned
            if !page.hasMore { break }
            XCTAssertFalse(page.items.isEmpty)
        }
        return (items, scanned)
    }

    private func withRepo(_ repo: URL, _ body: (OpaquePointer) throws -> Void) throws {
        var pointer: OpaquePointer?
        XCTAssertEqual(git_repository_open(&pointer, repo.path), 0)
        let opened = try XCTUnwrap(pointer)
        defer { git_repository_free(opened) }
        try body(opened)
    }

    private func appendCommits(_ repo: URL, count: Int) throws {
        try withRepo(repo) { raw in
            var head: OpaquePointer?
            XCTAssertEqual(git_repository_head(&head, raw), 0)
            defer { git_reference_free(head) }
            var oid = git_reference_target(head)!.pointee
            var initial: OpaquePointer?
            XCTAssertEqual(git_commit_lookup(&initial, raw, &oid), 0)
            var tree: OpaquePointer?
            XCTAssertEqual(git_commit_tree(&tree, initial), 0)
            git_commit_free(initial)
            defer { git_tree_free(tree) }
            var signature: UnsafeMutablePointer<git_signature>?
            XCTAssertEqual(git_signature_now(&signature, "Inspect Author", "inspect@example.invalid"), 0)
            defer { git_signature_free(signature) }
            for number in 0..<count {
                var parent: OpaquePointer?
                var result = git_oid()
                XCTAssertEqual(git_commit_lookup(&parent, raw, &oid), 0)
                var parents = [parent]
                let code = parents.withUnsafeMutableBufferPointer {
                    git_commit_create(&result, raw, "HEAD", signature, signature, nil, "empty \(number)", tree, 1, $0.baseAddress)
                }
                git_commit_free(parent)
                XCTAssertEqual(code, 0)
                oid = result
            }
        }
    }

    private func removeFromIndex(_ repo: URL, path: String) throws {
        try withRepo(repo) { raw in
            var index: OpaquePointer?
            XCTAssertEqual(git_repository_index(&index, raw), 0)
            defer { git_index_free(index) }
            XCTAssertEqual(git_index_remove_bypath(index, path), 0)
            XCTAssertEqual(git_index_write(index), 0)
        }
        try FileManager.default.removeItem(at: repo.appendingPathComponent(path))
    }

    func testHistoryListsOnlyCommitsThatChangeTheFileAndSkipsOtherFiles() throws {
        let repo = try repository()
        try write("a\n", "a.txt", repo)
        let added = try commit(repo, "add a")
        try write("b\n", "b.txt", repo)
        let other = try commit(repo, "add b")
        try write("a2\n", "a.txt", repo)
        let edited = try commit(repo, "edit a")
        let page = try collect(try GitClient.fileHistory(at: repo, path: "a.txt"))
        XCTAssertEqual(page.items.map(\.commit.id), [edited, added])
        XCTAssertEqual(page.items.map(\.kind), [.modified, .added])
        XCTAssertEqual(page.items.map(\.path), ["a.txt", "a.txt"])
        XCTAssertFalse(page.items.contains { $0.commit.id == other })
        XCTAssertEqual(page.scanned, 3)
    }

    func testPaginationKeepsWalkingAndEmptyCommitsIncreaseTheScanCount() throws {
        let repo = try repository()
        for number in 0..<25 {
            try write("\(number)\n", "a.txt", repo)
            _ = try commit(repo, "edit \(number)")
        }
        try appendCommits(repo, count: 10)
        let page = try collect(try GitClient.fileHistory(at: repo, path: "a.txt"), size: 10)
        XCTAssertEqual(page.items.count, 25)
        XCTAssertEqual(Set(page.items.map(\.commit.id)).count, 25)
        XCTAssertEqual(page.items.last?.kind, .added)
        XCTAssertEqual(page.scanned, 35)
    }

    func testRenameFollowsThePreviousPathAndDissimilarReplacementDoesNot() throws {
        let repo = try repository()
        try write("alpha beta gamma delta epsilon\n", "old.txt", repo)
        let added = try commit(repo, "add old")
        try FileManager.default.moveItem(at: repo.appendingPathComponent("old.txt"), to: repo.appendingPathComponent("new.txt"))
        let renamed = try commit(repo, "rename")
        let followed = try collect(try GitClient.fileHistory(at: repo, path: "new.txt")).items
        XCTAssertEqual(followed.map(\.kind), [.renamed, .added])
        XCTAssertEqual(followed[0].path, "new.txt")
        XCTAssertEqual(followed[0].previousPath, "old.txt")
        XCTAssertEqual(followed[1].commit.id, added)
        XCTAssertEqual(followed[1].path, "old.txt")
        XCTAssertEqual(try GitClient.fileRevision(at: repo, commit: renamed, path: "new.txt"), .text("alpha beta gamma delta epsilon\n"))
        XCTAssertEqual(try GitClient.fileRevision(at: repo, commit: added, path: "old.txt"), .text("alpha beta gamma delta epsilon\n"))
        XCTAssertEqual(try GitClient.fileRevision(at: repo, commit: renamed, path: "old.txt"), .missing)

        try write(String(repeating: "z", count: 400), "replacement.txt", repo)
        try removeFromIndex(repo, path: "new.txt")
        _ = try commit(repo, "replace")
        let replacement = try collect(try GitClient.fileHistory(at: repo, path: "replacement.txt")).items
        XCTAssertEqual(replacement.map(\.kind), [.added])
        XCTAssertFalse(replacement.contains { $0.commit.id == added })
    }

    func testFirstParentHistoryOmitsChangesThatExistOnlyOnTheMergedBranch() throws {
        let repo = try repository()
        try write("base\n", "a.txt", repo)
        let base = try commit(repo, "base")
        try GitClient.createBranch(at: repo, name: "side", checkout: true)
        try write("from-side\n", "a.txt", repo)
        let side = try commit(repo, "side")
        try GitClient.checkout(at: repo, branch: "master")
        try write("other\n", "b.txt", repo)
        let master = try commit(repo, "master move")
        try GitClient.mergeBranch(at: repo, branch: "side", name: "Inspect Author", email: "inspect@example.invalid")
        let head = try GitClient.history(at: repo, limit: 1)[0]
        XCTAssertEqual(head.parents.first, master)
        XCTAssertTrue(head.parents.contains(side))
        let items = try collect(try GitClient.fileHistory(at: repo, path: "a.txt")).items
        XCTAssertEqual(items.map(\.commit.id), [head.id, base])
        XCTAssertEqual(items.map(\.kind), [.modified, .added])
        XCTAssertFalse(items.contains { $0.commit.id == side || $0.commit.id == master })
    }

    func testDeletionMissingBinaryLargeInvalidTextSymlinkAndDirectoryStates() throws {
        let repo = try repository()
        try write("keep\n", "a.txt", repo)
        let added = try commit(repo, "add")
        try removeFromIndex(repo, path: "a.txt")
        let deleted = try commit(repo, "delete")
        let history = try collect(try GitClient.fileHistory(at: repo, path: "a.txt")).items
        XCTAssertEqual(history.map(\.kind), [.deleted, .added])
        XCTAssertEqual(try GitClient.fileRevision(at: repo, commit: deleted, path: "a.txt"), .missing)
        XCTAssertEqual(try GitClient.fileRevision(at: repo, commit: added, path: "a.txt"), .text("keep\n"))

        try Data([0x00, 0x01, 0x02, 0x03]).write(to: repo.appendingPathComponent("binary.bin"))
        let binary = try commit(repo, "binary")
        XCTAssertEqual(try GitClient.fileRevision(at: repo, commit: binary, path: "binary.bin"), .binary)

        var invalid = Data("hello ".utf8)
        invalid.append(contentsOf: [0xC3, 0x28])
        invalid.append(contentsOf: " tail".utf8)
        try invalid.write(to: repo.appendingPathComponent("bad.txt"))
        let bad = try commit(repo, "bad text")
        XCTAssertEqual(try GitClient.fileRevision(at: repo, commit: bad, path: "bad.txt"), .notUTF8)

        let payload = Data(repeating: 0x61, count: FileInspection.maximumBytes + 1)
        try payload.write(to: repo.appendingPathComponent("big.txt"))
        let big = try commit(repo, "big")
        XCTAssertEqual(try GitClient.fileRevision(at: repo, commit: big, path: "big.txt"), .tooLarge)

        try "SECRET\n".write(to: repo.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: repo.appendingPathComponent("link.txt").path, withDestinationPath: "secret.txt")
        let linked = try commit(repo, "link")
        XCTAssertEqual(try GitClient.fileRevision(at: repo, commit: linked, path: "link.txt"), .symlink("secret.txt"))

        try write("nested\n", "dir/file.txt", repo)
        _ = try commit(repo, "directory")
        XCTAssertThrowsError(try GitClient.fileHistory(at: repo, path: "dir"))
    }

    func testMissingObjectIsReportedAndRejectedPathsDoNotEscape() throws {
        let repo = try repository()
        try write("object\n", "a.txt", repo)
        let oid = try commit(repo, "object")
        let blob = try blobIdentifier(repo, commit: oid, path: "a.txt")
        let loose = repo.appendingPathComponent(".git/objects/\(blob.prefix(2))/\(blob.dropFirst(2))")
        try FileManager.default.removeItem(at: loose)
        XCTAssertEqual(try GitClient.fileRevision(at: repo, commit: oid, path: "a.txt"), .missingObject)
        for path in ["../outside.txt", ".git/config", "a/../../a.txt", ""] {
            XCTAssertThrowsError(try GitClient.fileHistory(at: repo, path: path))
            XCTAssertThrowsError(try GitClient.fileRevision(at: repo, commit: oid, path: path))
            XCTAssertThrowsError(try GitClient.blame(at: repo, path: path))
        }
        XCTAssertThrowsError(try GitClient.fileRevision(at: repo, commit: "not-an-oid", path: "a.txt"))
    }

    func testReadsDoNotChangeHeadIndexOrWorktreeAndBlameSeparatesLocalLines() throws {
        let repo = try repository()
        try write("one\n", "a.txt", repo)
        let first = try commit(repo, "one")
        try write("other\n", "b.txt", repo)
        _ = try commit(repo, "other")
        try write("one\ntwo\n", "a.txt", repo)
        let second = try commit(repo, "two")
        try write("one\ntwo\nthree\n", "a.txt", repo)
        let head = try Data(contentsOf: repo.appendingPathComponent(".git/HEAD"))
        let index = try Data(contentsOf: repo.appendingPathComponent(".git/index"))
        let master = try Data(contentsOf: repo.appendingPathComponent(".git/refs/heads/master"))
        let worktree = try Data(contentsOf: repo.appendingPathComponent("a.txt"))
        _ = try collect(try GitClient.fileHistory(at: repo, path: "a.txt"))
        XCTAssertEqual(try GitClient.fileRevision(at: repo, commit: second, path: "a.txt"), .text("one\ntwo\n"))
        let spans = try GitClient.blame(at: repo, path: "a.txt")
        XCTAssertEqual(spans.map(\.commitID), [first, second, nil])
        XCTAssertEqual(spans.map(\.lines), [["one"], ["two"], ["three"]])
        XCTAssertEqual(try Data(contentsOf: repo.appendingPathComponent(".git/HEAD")), head)
        XCTAssertEqual(try Data(contentsOf: repo.appendingPathComponent(".git/index")), index)
        XCTAssertEqual(try Data(contentsOf: repo.appendingPathComponent(".git/refs/heads/master")), master)
        XCTAssertEqual(try Data(contentsOf: repo.appendingPathComponent("a.txt")), worktree)

        try write("only local\n", "new.txt", repo)
        let untracked = try GitClient.blame(at: repo, path: "new.txt")
        XCTAssertEqual(untracked.map(\.commitID), [nil])
        XCTAssertEqual(untracked.first?.lines, ["only local"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.deletingLastPathComponent().appendingPathComponent("outside.txt").path))
    }

    func testCancellationStopsBeforeAndAfterTheCursorIsCreated() throws {
        let repo = try repository()
        try write("a\n", "a.txt", repo)
        _ = try commit(repo, "add")
        let cancelled = SearchCancellation()
        cancelled.cancel()
        XCTAssertThrowsError(try GitClient.fileHistory(at: repo, path: "a.txt", cancellation: cancelled)) { XCTAssertTrue($0 is CancellationError) }
        let cursor = try GitClient.fileHistory(at: repo, path: "a.txt")
        cursor.cancel()
        XCTAssertThrowsError(try cursor.nextPage()) { XCTAssertTrue($0 is CancellationError) }
        let page = try GitClient.fileHistory(at: repo, path: "a.txt").nextPage()
        XCTAssertEqual(page.items.count, 1)
    }

    private func owners(_ spans: [BlameSpan]) -> [String] {
        spans.flatMap { span in span.lines.map { _ in (span.commitID ?? "local") + (span.historyLimited ? "!" : "") } }
    }

    private func moveBranch(_ repo: URL, _ name: String, to id: String) throws {
        try withRepo(repo) { raw in
            var oid = git_oid()
            XCTAssertEqual(git_oid_fromstr(&oid, id), 0)
            var reference: OpaquePointer?
            XCTAssertEqual(git_reference_create(&reference, raw, name, &oid, 1, "move for test"), 0)
            git_reference_free(reference)
        }
    }

    private func assertBlameFails(_ repo: URL, _ path: String, _ message: String?, line: UInt = #line) {
        XCTAssertThrowsError(try GitClient.blame(at: repo, path: path), line: line) { error in
            if let message { XCTAssertEqual((error as? GitFailure)?.message, message, line: line) }
        }
    }

    func testBlameChecksTheCommittedBlobEvenWhenTheWorktreeFileIsSmall() throws {
        let repo = try repository()
        try Data(repeating: 0x61, count: FileInspection.maximumBytes + 1).write(to: repo.appendingPathComponent("big.txt"))
        try Data([0x61, 0x00, 0x62, 0x0A]).write(to: repo.appendingPathComponent("blob.txt"))
        try write("SECRET\n", "secret.txt", repo)
        let link = repo.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "secret.txt")
        _ = try commit(repo, "large, binary, and linked")

        try write("small\n", "big.txt", repo)
        try write("text\n", "blob.txt", repo)
        try FileManager.default.removeItem(at: link)
        try write("plain\n", "link.txt", repo)
        assertBlameFails(repo, "big.txt", String(localized: "The committed version of this file is too large to blame."))
        assertBlameFails(repo, "blob.txt", String(localized: "This file is binary and cannot be blamed."))
        assertBlameFails(repo, "link.txt", String(localized: "Could not blame this file."))

        try Data([0x6F, 0x00, 0x0A]).write(to: repo.appendingPathComponent("secret.txt"))
        assertBlameFails(repo, "secret.txt", String(localized: "This file is binary and cannot be blamed."))
        let outside = repo.deletingLastPathComponent().appendingPathComponent("outside.txt")
        try "outside\n".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: repo.appendingPathComponent("secret.txt"))
        try FileManager.default.createSymbolicLink(atPath: repo.appendingPathComponent("secret.txt").path, withDestinationPath: outside.path)
        assertBlameFails(repo, "secret.txt", nil)
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "outside\n")
    }

    func testBlameCutsHistoryAtOversizedVersionsRenameCandidatesAndLimits() throws {
        let shrunkRepo = try repository()
        try Data(repeating: 0x61, count: FileInspection.maximumBytes + 1).write(to: shrunkRepo.appendingPathComponent("a.txt"))
        let huge = try commit(shrunkRepo, "huge")
        try write("one\n", "a.txt", shrunkRepo)
        let shrunk = try commit(shrunkRepo, "shrink")
        try write("one\ntwo\n", "a.txt", shrunkRepo)
        let grown = try commit(shrunkRepo, "grow")
        XCTAssertEqual(owners(try GitClient.blame(at: shrunkRepo, path: "a.txt")), [shrunk + "!", grown])
        // Only the header of the oversized version is consulted, so losing its object changes nothing.
        let blob = try blobIdentifier(shrunkRepo, commit: huge, path: "a.txt")
        try FileManager.default.removeItem(at: shrunkRepo.appendingPathComponent(".git/objects/\(blob.prefix(2))/\(blob.dropFirst(2))"))
        XCTAssertEqual(owners(try GitClient.blame(at: shrunkRepo, path: "a.txt")), [shrunk + "!", grown])

        let candidates = try repository()
        try write("one\n", "a.txt", candidates)
        try write("gone\n", "gone.txt", candidates)
        _ = try commit(candidates, "base")
        try write("one\ntwo\n", "a.txt", candidates)
        try removeFromIndex(candidates, path: "gone.txt")
        try Data(repeating: 0x62, count: FileInspection.maximumBytes + 1).write(to: candidates.appendingPathComponent("added.txt"))
        let mixed = try commit(candidates, "edit with a large rename candidate")
        XCTAssertEqual(owners(try GitClient.blame(at: candidates, path: "a.txt")), [mixed + "!", mixed + "!"])

        let long = try repository()
        var ids: [String] = []
        var text = ""
        for number in 1...4 {
            text += "line \(number)\n"
            try write(text, "a.txt", long)
            ids.append(try commit(long, "line \(number)"))
        }
        XCTAssertEqual(owners(try GitClient.blame(at: long, path: "a.txt")), ids)
        XCTAssertEqual(owners(try GitClient.blame(at: long, path: "a.txt", limits: .init(commits: 2, bytes: .max))),
                       [ids[2] + "!", ids[2] + "!", ids[2] + "!", ids[3]])
        XCTAssertEqual(owners(try GitClient.blame(at: long, path: "a.txt", limits: .init(commits: 100, bytes: text.utf8.count))),
                       Array(repeating: ids[3] + "!", count: 4))
    }

    func testBlameUsesTheHeadItReadEvenIfTheBranchMovesBeforeLibgit2Runs() throws {
        let repo = try repository()
        try write("one\n", "a.txt", repo)
        let first = try commit(repo, "one")
        try write("one\ntwo\n", "a.txt", repo)
        let second = try commit(repo, "two")
        var moves = 0
        let spans = try GitClient.blame(at: repo, path: "a.txt", beforeBlame: {
            moves += 1
            try self.moveBranch(repo, "refs/heads/master", to: first)
        })
        XCTAssertEqual(moves, 1)
        XCTAssertEqual(try GitClient.history(at: repo, limit: 1)[0].id, first)
        XCTAssertEqual(owners(spans), [first, second])
        // A fresh read of HEAD sees the moved branch, which is what an unpinned blame would have used.
        XCTAssertEqual(owners(try GitClient.blame(at: repo, path: "a.txt")), [first, "local"])
    }

    func testBlameCancellationIsCheckedOutsideTheSynchronousLibraryCall() throws {
        let repo = try repository()
        try write("one\n", "a.txt", repo)
        _ = try commit(repo, "one")
        let early = SearchCancellation()
        early.cancel()
        XCTAssertThrowsError(try GitClient.blame(at: repo, path: "a.txt", cancellation: early)) { XCTAssertTrue($0 is CancellationError) }
        let late = SearchCancellation()
        XCTAssertThrowsError(try GitClient.blame(at: repo, path: "a.txt", cancellation: late, beforeBlame: { late.cancel() })) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertEqual(try GitClient.blame(at: repo, path: "a.txt").map(\.lines), [["one"]])
    }

    func testBlamePreWalkStopsInsideOneLargeCommitWhenCancelledBeforeLibgit2Starts() throws {
        let repo = try repository()
        try write("one\n", "a.txt", repo)
        for number in 0..<200 { try write("old \(number)\n", "gone/\(number).txt", repo) }
        let base = try commit(repo, "base")
        try withRepo(repo) { raw in
            var index: OpaquePointer?
            XCTAssertEqual(git_repository_index(&index, raw), 0)
            defer { git_index_free(index) }
            XCTAssertEqual(git_index_remove_directory(index, "gone", 0), 0)
            XCTAssertEqual(git_index_write(index), 0)
        }
        try FileManager.default.removeItem(at: repo.appendingPathComponent("gone"))
        for number in 0..<200 { try write("new \(number)\n", "added/\(number).txt", repo) }
        try write("one\ntwo\n", "a.txt", repo)
        let large = try commit(repo, "edit a.txt, delete 200 files, add 200 files")

        var checks = 0
        XCTAssertEqual(owners(try GitClient.blame(at: repo, path: "a.txt", onCancellationCheck: { checks += 1 })), [base, large])
        // Only two commits are walked, so most checks fall between entries of the large one.
        XCTAssertGreaterThanOrEqual(checks, 800)

        let token = SearchCancellation()
        var seen = 0
        var started = false
        XCTAssertThrowsError(try GitClient.blame(at: repo, path: "a.txt", cancellation: token, beforeBlame: { started = true },
                                                 onCancellationCheck: {
            seen += 1
            if seen == checks / 2 { token.cancel() }
        })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(seen, checks / 2)
        XCTAssertFalse(started)
    }

    func testBlameCutsBeforeAFollowedNameWhoseDeletedVersionIsOversized() throws {
        // new.txt exists in the root, is deleted, and old.txt is later renamed onto it. Walking
        // past the deletion makes libgit2 load the root's new.txt as well as old.txt.
        func build(_ earlier: Data) throws -> (repo: URL, root: String, edited: String) {
            let repo = try repository()
            try write("one\n", "old.txt", repo)
            try earlier.write(to: repo.appendingPathComponent("new.txt"))
            let root = try commit(repo, "root")
            try removeFromIndex(repo, path: "new.txt")
            try write("one\ntwo\n", "old.txt", repo)
            let edited = try commit(repo, "delete new.txt and edit old.txt")
            try FileManager.default.moveItem(at: repo.appendingPathComponent("old.txt"), to: repo.appendingPathComponent("new.txt"))
            _ = try commit(repo, "rename old.txt to new.txt")
            return (repo, root, edited)
        }
        let small = try build(Data("one\n".utf8))
        XCTAssertEqual(owners(try GitClient.blame(at: small.repo, path: "new.txt")), [small.root, small.edited])
        let large = try build(Data(repeating: 0x63, count: FileInspection.maximumBytes + 1))
        XCTAssertEqual(owners(try GitClient.blame(at: large.repo, path: "new.txt")), [large.edited + "!", large.edited + "!"])
    }

    func testUnbornRepositoryHasNoFileHistory() throws {
        let repo = try repository()
        let page = try GitClient.fileHistory(at: repo, path: "a.txt").nextPage()
        XCTAssertTrue(page.items.isEmpty)
        XCTAssertFalse(page.hasMore)
        try write("local\n", "a.txt", repo)
        XCTAssertEqual(try GitClient.blame(at: repo, path: "a.txt").map(\.commitID), [nil])
    }

    func testHighlighterKeepsKeywordsOutOfStringsAndCommentsAndSkipsUnknownOrHugeText() throws {
        let source = "let value = \"let\"\n// let still\nlet count = 12\n"
        let spans = SyntaxHighlighter.spans(in: source, path: "Demo.swift")
        let text = source as NSString
        let slices = spans.map { text.substring(with: NSRange(location: $0.location, length: $0.length)) + " " + String(describing: $0.kind) }
        XCTAssertEqual(slices, [
            "let keyword",
            "\"let\" string",
            "// let still comment",
            "let keyword",
            "12 number",
        ])
        var cursor = 0
        for span in spans {
            XCTAssertGreaterThanOrEqual(span.location, cursor)
            cursor = span.location + span.length
        }
        XCTAssertTrue(SyntaxHighlighter.spans(in: "let value = 1\n", path: "notes.txt").isEmpty)
        let huge = String(repeating: "let ", count: (FileInspection.maximumBytes / 4) + 2)
        XCTAssertGreaterThan(huge.utf8.count, FileInspection.maximumBytes)
        XCTAssertTrue(SyntaxHighlighter.spans(in: huge, path: "Demo.swift").isEmpty)
        let python = "value = \"def\"\n'''\ndef hidden\n'''\ndef shown():\n    pass\n"
        let pythonText = python as NSString
        let pythonSpans = SyntaxHighlighter.spans(in: python, path: "sample.py").map {
            pythonText.substring(with: NSRange(location: $0.location, length: $0.length)) + " " + String(describing: $0.kind)
        }
        XCTAssertTrue(pythonSpans.contains("\"def\" string"))
        XCTAssertTrue(pythonSpans.contains { $0.contains("def hidden") && $0.hasSuffix(" string") })
        XCTAssertEqual(pythonSpans.filter { $0 == "def keyword" }.count, 1)
    }

    private func blobIdentifier(_ repo: URL, commit: String, path: String) throws -> String {
        var result = ""
        try withRepo(repo) { raw in
            var oid = git_oid()
            XCTAssertEqual(git_oid_fromstr(&oid, commit), 0)
            var commitPointer: OpaquePointer?
            XCTAssertEqual(git_commit_lookup(&commitPointer, raw, &oid), 0)
            defer { git_commit_free(commitPointer) }
            var tree: OpaquePointer?
            XCTAssertEqual(git_commit_tree(&tree, commitPointer), 0)
            defer { git_tree_free(tree) }
            var entry: OpaquePointer?
            XCTAssertEqual(git_tree_entry_bypath(&entry, tree, path), 0)
            defer { git_tree_entry_free(entry) }
            var blob = git_tree_entry_id(entry)!.pointee
            var bytes = [CChar](repeating: 0, count: 41)
            git_oid_tostr(&bytes, bytes.count, &blob)
            result = String(cString: bytes)
        }
        return result
    }
}

final class BlameQueueTests: XCTestCase {
    private struct TimedOut: Error {}
    private typealias BlameTask = Task<[BlameSpan], Error>

    private final class Probe: @unchecked Sendable {
        // Every property below is only touched while holding `lock`.
        private let lock = NSLock()
        private var running = 0
        private var highest = 0
        private var runs: [String: Int] = [:]
        private var cancelled: [String: Bool] = [:]
        private var stuck = false

        func enter(_ name: String) {
            lock.lock(); defer { lock.unlock() }
            running += 1
            highest = max(highest, running)
            runs[name, default: 0] += 1
        }

        func leave(_ name: String, _ token: SearchCancellation) {
            lock.lock(); defer { lock.unlock() }
            running -= 1
            cancelled[name] = (try? token.check()) == nil
        }

        func gateTimedOut() { lock.lock(); stuck = true; lock.unlock() }
        func count(_ name: String) -> Int { lock.lock(); defer { lock.unlock() }; return runs[name] ?? 0 }
        func wasCancelled(_ name: String) -> Bool? { lock.lock(); defer { lock.unlock() }; return cancelled[name] }
        var peak: Int { lock.lock(); defer { lock.unlock() }; return highest }
        var timedOut: Bool { lock.lock(); defer { lock.unlock() }; return stuck }
    }

    /// Tasks started by a test, so teardown can cancel and collect them after any failure.
    private final class Tasks: @unchecked Sendable {
        // `items` is only touched while holding `lock`.
        private let lock = NSLock()
        private var items: [BlameTask] = []
        func add(_ task: BlameTask) -> BlameTask { lock.lock(); items.append(task); lock.unlock(); return task }
        var all: [BlameTask] { lock.lock(); defer { lock.unlock() }; return items }
    }

    /// Hands one result to a continuation, whichever of the task and its timer finishes first.
    private final class Race<T>: @unchecked Sendable {
        // `continuation` is only touched while holding `lock`.
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?
        init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }
        func finish(_ result: Result<T, Error>) {
            lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
            pending?.resume(with: result)
        }
    }

    private static let gateTimeout: DispatchTimeInterval = .seconds(30)

    /// Awaits `task` for at most `seconds`. On timeout the task is cancelled and abandoned, so a
    /// continuation the queue never resumes fails the test instead of hanging it.
    private static func value(_ task: BlameTask, within seconds: Int = 5) async throws -> [BlameSpan] {
        try await withCheckedThrowingContinuation { continuation in
            let race = Race(continuation)
            let timer = Task {
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled else { return }
                task.cancel()
                race.finish(.failure(TimedOut()))
            }
            Task {
                let result = await task.result
                timer.cancel()
                race.finish(result)
            }
        }
    }

    /// Opens the gate standing in for libgit2, cancels every task, and waits for the serial worker
    /// to run a final job, so no blocked worker or pending waiter outlives the test.
    private static func release(_ queue: BlameQueue, _ gate: DispatchSemaphore, _ tasks: Tasks) async {
        gate.signal()
        for task in tasks.all { task.cancel() }
        for task in tasks.all { _ = try? await value(task) }
        let drained = BlameTask { try await queue.run(key("drain")) { _ in [] } }
        if (try? await value(drained)) == nil { XCTFail("The blame worker did not drain.") }
    }

    private static func key(_ path: String) -> BlameQueue.Key { .init(repo: "/repo", path: path, revision: 0) }

    private static func span(_ text: String) -> BlameSpan {
        BlameSpan(commitID: nil, summary: "", author: "", date: nil, startLine: 1, lineCount: 1, lines: [text], originPath: "a.txt")
    }

    private func key(_ path: String) -> BlameQueue.Key { Self.key(path) }

    private func waitUntil(_ condition: () -> Bool, line: UInt = #line) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        guard condition() else {
            XCTFail("Timed out waiting for the queue.", line: line)
            throw TimedOut()
        }
    }

    private func expectCancelled(_ task: BlameTask, line: UInt = #line) async throws {
        do {
            _ = try await Self.value(task)
            XCTFail("A cancelled blame must not deliver a result.", line: line)
        } catch is CancellationError {}
    }

    private func quick(_ queue: BlameQueue, _ probe: Probe, _ tasks: Tasks, _ path: String, as name: String) -> BlameTask {
        tasks.add(Task {
            try await queue.run(Self.key(path)) { token in
                probe.enter(name)
                probe.leave(name, token)
                return [Self.span(name)]
            }
        })
    }

    func testCancelledWaitersLeaveAtOnceWhileOneJobRunsAndRepeatsShareIt() async throws {
        let queue = BlameQueue()
        let probe = Probe()
        let gate = DispatchSemaphore(value: 0)
        let tasks = Tasks()
        addTeardownBlock { await Self.release(queue, gate, tasks) }
        // The blocked closure stands in for git_blame_file, which cannot be interrupted.
        let slow = tasks.add(Task {
            try await queue.run(Self.key("slow")) { token in
                probe.enter("slow")
                if gate.wait(timeout: .now() + Self.gateTimeout) == .timedOut { probe.gateTimedOut() }
                probe.leave("slow", token)
                return [Self.span("slow")]
            }
        })
        try await waitUntil { probe.count("slow") == 1 }
        slow.cancel()
        try await expectCancelled(slow)
        XCTAssertEqual(queue.waiterCount(key("slow")), 0)

        let again = quick(queue, probe, tasks, "slow", as: "slow-again")
        try await waitUntil { queue.waiterCount(key("slow")) == 1 }

        for _ in 0..<20 {
            let switched = quick(queue, probe, tasks, "switch", as: "switch")
            try await waitUntil { queue.waiterCount(key("switch")) == 1 }
            switched.cancel()
            try await expectCancelled(switched)
            XCTAssertEqual(queue.waiterCount(key("switch")), 0)
        }

        let first = quick(queue, probe, tasks, "shared", as: "shared")
        try await waitUntil { queue.waiterCount(key("shared")) == 1 }
        let second = quick(queue, probe, tasks, "shared", as: "unused")
        try await waitUntil { queue.waiterCount(key("shared")) == 2 }
        let third = quick(queue, probe, tasks, "shared", as: "unused")
        try await waitUntil { queue.waiterCount(key("shared")) == 3 }
        third.cancel()
        try await expectCancelled(third)
        XCTAssertEqual(queue.waiterCount(key("shared")), 2)

        gate.signal()
        let shared = try await Self.value(first)
        let repeated = try await Self.value(second)
        let restarted = try await Self.value(again)
        XCTAssertFalse(probe.timedOut)
        XCTAssertEqual(repeated, shared)
        XCTAssertEqual(shared.first?.lines, ["shared"])
        XCTAssertEqual(restarted.first?.lines, ["slow-again"])
        XCTAssertEqual(probe.count("slow"), 1)
        XCTAssertEqual(probe.wasCancelled("slow"), true)
        XCTAssertEqual(probe.count("slow-again"), 1)
        XCTAssertEqual(probe.count("switch"), 0)
        XCTAssertEqual(probe.count("shared"), 1)
        XCTAssertEqual(probe.wasCancelled("shared"), false)
        XCTAssertEqual(probe.count("unused"), 0)
        XCTAssertEqual(probe.peak, 1)
    }
}

@MainActor
final class FileInspectionLayoutTests: XCTestCase {
    func testSectionPickerStaysAtTheTopAndFitsDuoWidths() async throws {
        final class State: ObservableObject {
            @Published var section = FileInspectSection.contents
            @Published var phase = 0
            @Published var rendered = -1
            var header = CGRect.zero
        }
        struct HeaderFrame: PreferenceKey {
            static var defaultValue = CGRect.zero
            static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
                let next = nextValue()
                if next.height > 0 { value = next }
            }
        }
        struct Harness: View {
            @ObservedObject var state: State
            var body: some View {
                DiffPanelLayout {
                    FileInspectPicker(section: $state.section)
                        .background(GeometryReader { proxy in
                            Color.clear.preference(key: HeaderFrame.self, value: proxy.frame(in: .global))
                        })
                        .padding(.horizontal)
                } content: {
                    Group {
                        switch state.phase {
                        case 0: SourceStandIn(text: "let value = 1")
                        case 1: Text("No commits for this file on the current branch.").padding()
                        case 2: Text("Could not blame this file.").padding()
                        default: ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .task(id: state.phase) { state.rendered = state.phase }
                }
                .onPreferenceChange(HeaderFrame.self) { state.header = $0 }
            }
        }
        struct SourceStandIn: View {
            let text: String
            var body: some View { Text(text).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading) }
        }
        for size in [CGSize(width: 393, height: 852), CGSize(width: 346, height: 678), CGSize(width: 951, height: 669)] {
            let state = State()
            let host = UIHostingController(rootView: Harness(state: state))
            let window = UIWindow(frame: CGRect(origin: .zero, size: size))
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer { window.isHidden = true; window.rootViewController = nil }
            for _ in 0..<100 where state.rendered != 0 || state.header.height == 0 { try await Task.sleep(for: .milliseconds(10)) }
            let original = state.header.minY
            XCTAssertGreaterThan(state.header.height, 20)
            XCTAssertLessThan(original, 120)
            for phase in [1, 2, 3, 0] {
                state.section = phase == 1 ? .history : phase == 2 ? .blame : .contents
                state.phase = phase
                for _ in 0..<100 where state.rendered != phase { try await Task.sleep(for: .milliseconds(10)) }
                try await Task.sleep(for: .milliseconds(30))
                XCTAssertEqual(state.header.minY, original, accuracy: 1, "\(size) phase \(phase)")
                XCTAssertLessThan(state.header.minY, size.height / 4)
            }
        }
        for locale in ["en", "zh-Hans", "ja"] {
            for width: CGFloat in [240, 346, 466, 619, 951] {
                let picker = UIHostingController(rootView: FileInspectPicker(section: .constant(.blame))
                    .environment(\.locale, Locale(identifier: locale))
                    .environment(\.dynamicTypeSize, .accessibility3))
                let pickerSize = picker.sizeThatFits(in: CGSize(width: width, height: 10_000))
                XCTAssertLessThanOrEqual(pickerSize.width, width + 0.5)
                XCTAssertGreaterThan(pickerSize.height, 20)
                let footnote = UIHostingController(rootView: Text("History follows HEAD through first parents and similar-file renames.")
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .environment(\.locale, Locale(identifier: locale))
                    .environment(\.dynamicTypeSize, .accessibility3))
                let footnoteSize = footnote.sizeThatFits(in: CGSize(width: width, height: 10_000))
                XCTAssertLessThanOrEqual(footnoteSize.width, width + 0.5)
                XCTAssertGreaterThan(footnoteSize.height, 20)
                XCTAssertTrue(footnoteSize.height.isFinite)
            }
        }
    }
}
