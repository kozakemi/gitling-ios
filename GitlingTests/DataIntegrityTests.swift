import XCTest
@testable import Gitling

final class DataIntegrityTests: XCTestCase {
    func sandbox(_ body: (URL, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let name = "review-" + UUID().uuidString
        try GitClient.initialize(name: name, root: root)
        addTeardownBlock { WorktreeLink.remove(repoName: name) }
        let repo = root.appendingPathComponent(name)
        try "base\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try GitClient.stageAll(at: repo)
        try GitClient.commit(at: repo, message: "base", name: "Test", email: "test@example.com")
        try body(root, repo)
    }
    func testFailedCherryPickPreservesLocalChanges() throws {
        try sandbox { _, repo in
            try GitClient.createBranch(at: repo, name: "feature", checkout: true)
            try "feature\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            try GitClient.stageAll(at: repo)
            try GitClient.commit(at: repo, message: "feature", name: "Test", email: "test@example.com")
            let oid = try GitClient.history(at: repo)[0].id
            try GitClient.checkout(at: repo, branch: "master")
            try "UNSAVED\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            XCTAssertThrowsError(try GitClient.cherryPick(at: repo, commit: oid, name: "Test", email: "test@example.com"))
            XCTAssertEqual(try String(contentsOf: repo.appendingPathComponent("a.txt"), encoding: .utf8), "UNSAVED\n")
        }
    }
    func testLinkPreservesUncommittedFiles() throws {
        try sandbox { root, repo in
            try "UNSAVED\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            try "NEW\n".write(to: repo.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
            let folder = root.appendingPathComponent("vault")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let bookmark = try folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            try GitClient.link(at: repo, bookmark: bookmark)
            XCTAssertEqual(try GitClient.readText(at: repo, relative: "a.txt"), "UNSAVED\n")
            XCTAssertEqual(try GitClient.readText(at: repo, relative: "new.txt"), "NEW\n")
        }
    }
    func testLinkSameNamedFolderGetsTrackedFiles() throws {
        try sandbox { root, repo in
            let folder = root.appendingPathComponent("vault").appendingPathComponent(repo.lastPathComponent)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let bookmark = try folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            try GitClient.link(at: repo, bookmark: bookmark)
            XCTAssertEqual(try GitClient.readText(at: repo, relative: "a.txt"), "base\n")
        }
    }
    func testRootLFSPatternIsApplied() throws {
        try sandbox { _, repo in
            try "*.bin filter=lfs diff=lfs merge=lfs -text\n".write(to: repo.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
            let pointer = LFSPointer.make(oid: String(repeating: "a", count: 64), size: 1)
            try pointer.raw.write(to: repo.appendingPathComponent("asset.bin"), atomically: true, encoding: .utf8)
            let pointers = try LFSClient.clean(at: repo, remoteURL: "https://example.invalid/a.git", auth: nil)
            XCTAssertNotNil(pointers["asset.bin"])
        }
    }

    func testRejectedCherryPickPreservesStagedChanges() throws {
        try sandbox { _, repo in
            let head = try GitClient.history(at: repo)[0].id
            try "staged\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            try GitClient.stageAll(at: repo)
            try "unstaged\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            let before = try GitClient.status(at: repo)
            XCTAssertThrowsError(try GitClient.cherryPick(at: repo, commit: head, name: "Test", email: "test@example.com"))
            XCTAssertEqual(try GitClient.status(at: repo), before)
            XCTAssertEqual(try GitClient.readText(at: repo, relative: "a.txt"), "unstaged\n")
            XCTAssertEqual(try GitClient.history(at: repo)[0].id, head)
        }
    }

    func testConflictingCherryPickPausesAndExplicitAbortRestoresCleanBranch() throws {
        try sandbox { _, repo in
            try GitClient.createBranch(at: repo, name: "feature", checkout: true)
            try "feature\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            try GitClient.stageAll(at: repo)
            try GitClient.commit(at: repo, message: "feature", name: "Test", email: "test@example.com")
            let picked = try GitClient.history(at: repo)[0].id
            try GitClient.checkout(at: repo, branch: "master")
            try "master\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            try GitClient.stageAll(at: repo)
            try GitClient.commit(at: repo, message: "master", name: "Test", email: "test@example.com")
            let head = try GitClient.history(at: repo)[0].id
            try GitClient.cherryPick(at: repo, commit: picked, name: "Test", email: "test@example.com")
            XCTAssertEqual(try GitClient.operation(at: repo).kind, .cherryPick)
            XCTAssertEqual(try GitClient.operation(at: repo).conflicts.map(\.path), ["a.txt"])
            try GitClient.abortOperation(at: repo)
            XCTAssertEqual(try GitClient.history(at: repo)[0].id, head)
            XCTAssertEqual(try GitClient.readText(at: repo, relative: "a.txt"), "master\n")
            XCTAssertTrue(try GitClient.status(at: repo).isEmpty)
            // Also prove repository state was cleaned up by allowing a new commit.
            try "next\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            try GitClient.stageAll(at: repo)
            try GitClient.commit(at: repo, message: "next", name: "Test", email: "test@example.com")
        }
    }

    func testLinkCollisionLeavesBothWorktreesUntouched() throws {
        try sandbox { root, repo in
            try "local edit\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            try "new\n".write(to: repo.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
            let target = root.appendingPathComponent("vault").appendingPathComponent(repo.lastPathComponent)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try "external edit\n".write(to: target.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            let bookmark = try WorktreeLink.bookmark(for: target)
            XCTAssertThrowsError(try GitClient.link(at: repo, bookmark: bookmark))
            XCTAssertNil(GitClient.linkedFolderName(at: repo))
            XCTAssertEqual(try GitClient.readText(at: repo, relative: "a.txt"), "local edit\n")
            XCTAssertEqual(try GitClient.readText(at: repo, relative: "new.txt"), "new\n")
            XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("a.txt"), encoding: .utf8), "external edit\n")
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("new.txt").path))
        }
    }

    func testLinkPreservesIndexIgnoredFilesAndDeletions() throws {
        try sandbox { root, repo in
            try "ignored.txt\n".write(to: repo.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
            try "staged\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            try GitClient.stageAll(at: repo)
            try "unstaged\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            try "ignored\n".write(to: repo.appendingPathComponent("ignored.txt"), atomically: true, encoding: .utf8)
            let before = try GitClient.status(at: repo)
            let folder = root.appendingPathComponent("vault")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try GitClient.link(at: repo, bookmark: WorktreeLink.bookmark(for: folder))
            XCTAssertEqual(try GitClient.status(at: repo), before)
            XCTAssertEqual(try GitClient.readText(at: repo, relative: "ignored.txt"), "ignored\n")
            XCTAssertEqual(try GitClient.readText(at: repo, relative: "a.txt"), "unstaged\n")
            let external = folder.appendingPathComponent(repo.lastPathComponent)
            try FileManager.default.removeItem(at: external.appendingPathComponent("a.txt"))
            // Opening the repository must not recreate a deliberately deleted file.
            XCTAssertTrue(try GitClient.status(at: repo).contains { $0.path == "a.txt" && $0.unstaged })
            XCTAssertFalse(FileManager.default.fileExists(atPath: external.appendingPathComponent("a.txt").path))
        }
    }

    func testRelinkingCopiesCurrentExternalEditsAndKeepsOldFolder() throws {
        try sandbox { root, repo in
            let first = root.appendingPathComponent("first")
            let second = root.appendingPathComponent("second")
            for folder in [first, second] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
            try GitClient.link(at: repo, bookmark: WorktreeLink.bookmark(for: first))
            let original = first.appendingPathComponent(repo.lastPathComponent).appendingPathComponent("a.txt")
            try "external\n".write(to: original, atomically: true, encoding: .utf8)
            try GitClient.link(at: repo, bookmark: WorktreeLink.bookmark(for: second))
            XCTAssertEqual(try GitClient.readText(at: repo, relative: "a.txt"), "external\n")
            XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "external\n")
            try GitClient.unlink(at: repo)
            XCTAssertEqual(try GitClient.readText(at: repo, relative: "a.txt"), "external\n")
        }
    }

    func testLinkRejectsNestedDestinationWithoutRemovingSource() throws {
        try sandbox { _, repo in
            XCTAssertThrowsError(try GitClient.link(at: repo, bookmark: WorktreeLink.bookmark(for: repo)))
            let nested = repo.appendingPathComponent("nested")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            XCTAssertThrowsError(try GitClient.link(at: repo, bookmark: WorktreeLink.bookmark(for: nested)))
            XCTAssertEqual(try GitClient.readText(at: repo, relative: "a.txt"), "base\n")
            XCTAssertTrue(FileManager.default.fileExists(atPath: repo.appendingPathComponent(".git").path))
        }
    }

}
