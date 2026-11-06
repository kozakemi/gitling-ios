import XCTest
@testable import Gitling

final class WorkingTreeTests: XCTestCase {
    func testHidesGitAndRejectsUnsafePaths() throws {
        let root = try makeRoot()
        let repo = root.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try "hello".write(to: repo.appendingPathComponent("note.md"), atomically: true, encoding: .utf8)
        let repoID = WorkingTree.identifier(repo: "notes")

        let children = try WorkingTree.children(root: root, identifier: repoID)
        XCTAssertEqual(children.map(\.fileURL.lastPathComponent), ["note.md"])

        XCTAssertThrowsError(try WorkingTree.node(root: root, identifier: "repo:notes/.git"))
        XCTAssertThrowsError(try WorkingTree.node(root: root, identifier: "repo:notes/../notes/note.md"))
        XCTAssertThrowsError(try WorkingTree.create(
            root: root,
            parentIdentifier: repoID,
            name: ".git",
            isDirectory: true,
            contents: nil
        ))
    }

    func testCreateRenameAndProtectRepoRoot() throws {
        let root = try makeRoot()
        let repo = root.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let repoID = WorkingTree.identifier(repo: "notes")
        let created = try WorkingTree.create(
            root: root,
            parentIdentifier: repoID,
            name: "note.md",
            isDirectory: false,
            contents: Data("hello".utf8)
        )
        XCTAssertEqual(try String(contentsOf: repo.appendingPathComponent("note.md"), encoding: .utf8), "hello")

        let renamed = try WorkingTree.update(
            root: root,
            identifier: created,
            newName: "renamed.md",
            newParentIdentifier: nil,
            contents: nil
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.appendingPathComponent("renamed.md").path))
        XCTAssertThrowsError(try WorkingTree.delete(root: root, identifier: repoID))
        try WorkingTree.delete(root: root, identifier: renamed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent("renamed.md").path))
    }

    func testWriteIsRefusedWhileGitHoldsTheLock() throws {
        let root = try makeRoot()
        let repo = root.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let hold = try RepoWriteLock.holdExclusive(at: repo)
        defer { withExtendedLifetime(hold) {} }
        XCTAssertThrowsError(try WorkingTree.create(
            root: root,
            parentIdentifier: WorkingTree.identifier(repo: "notes"),
            name: "note.md",
            isDirectory: false,
            contents: Data("x".utf8)
        )) { error in
            XCTAssertEqual(error as? WorkingTreeError, .busy)
        }
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitling-tree-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
}
