import XCTest
@testable import Gitling

final class GitClientTests: XCTestCase {
    func testInitCommitCloneAndPush() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitling-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try GitClient.initialize(name: "remote", root: root, bare: true)
        try GitClient.initialize(name: "local", root: root)
        let local = root.appendingPathComponent("local")
        let remote = root.appendingPathComponent("remote")
        try GitClient.addRemote(at: local, url: remote.absoluteURL.absoluteString)

        try "hello\n".write(to: local.appendingPathComponent("note.md"), atomically: true, encoding: .utf8)
        let pending = try GitClient.status(at: local)
        XCTAssertEqual(pending.count, 1)
        XCTAssertTrue(pending[0].untracked)

        try GitClient.stageAll(at: local)
        let staged = try GitClient.status(at: local)
        XCTAssertTrue(staged[0].staged)
        try GitClient.unstageAll(at: local)
        XCTAssertFalse(try GitClient.status(at: local)[0].staged)

        try GitClient.stageAll(at: local)
        try GitClient.commit(at: local, message: "add note", name: "Test", email: "test@example.com")
        XCTAssertEqual(try GitClient.history(at: local).count, 1)
        XCTAssertTrue(try GitClient.status(at: local).isEmpty)
        XCTAssertEqual(try GitClient.readText(at: local, relative: "note.md"), "hello\n")

        try GitClient.push(at: local, username: "", secret: "")
        try GitClient.clone(url: remote.absoluteURL.absoluteString, name: "other", root: root, username: "", secret: "")
        let other = root.appendingPathComponent("other")
        XCTAssertEqual(try GitClient.readText(at: other, relative: "note.md"), "hello\n")

        try "more\n".write(to: local.appendingPathComponent("note.md"), atomically: true, encoding: .utf8)
        try GitClient.stageAll(at: local)
        try GitClient.commit(at: local, message: "edit note", name: "Test", email: "test@example.com")
        try GitClient.push(at: local, username: "", secret: "")
        try GitClient.pull(at: other, username: "", secret: "", name: "Test", email: "test@example.com")
        XCTAssertEqual(try GitClient.readText(at: other, relative: "note.md"), "more\n")
        XCTAssertEqual(try GitClient.history(at: other).count, 2)
    }

    func testLinkedFolderReceivesTheWorktreeWithoutGitMetadata() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitling-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try GitClient.initialize(name: "local", root: root)
        let local = root.appendingPathComponent("local")
        try "hello\n".write(to: local.appendingPathComponent("note.md"), atomically: true, encoding: .utf8)
        try GitClient.stageAll(at: local)
        try GitClient.commit(at: local, message: "add note", name: "Test", email: "test@example.com")

        let vault = root.appendingPathComponent("vault", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        try "keep\n".write(to: vault.appendingPathComponent("other.txt"), atomically: true, encoding: .utf8)
        let bookmark = try vault.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        try GitClient.link(at: local, bookmark: bookmark)

        let project = vault.appendingPathComponent("local")
        XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("note.md"), encoding: .utf8), "hello\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: vault.appendingPathComponent("note.md").path))
        XCTAssertEqual(try String(contentsOf: vault.appendingPathComponent("other.txt"), encoding: .utf8), "keep\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent(".git").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: local.appendingPathComponent("note.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: local.appendingPathComponent(".git").path))
        XCTAssertEqual(GitClient.linkedFolderName(at: local), "vault/local")
        XCTAssertEqual(try GitClient.readText(at: local, relative: "note.md"), "hello\n")
        XCTAssertTrue(try GitClient.entries(at: local, directory: "").contains { $0.name == "note.md" })

        try "edited\n".write(to: project.appendingPathComponent("note.md"), atomically: true, encoding: .utf8)
        let changed = try GitClient.status(at: local)
        XCTAssertEqual(changed.map(\.path), ["note.md"])

        try GitClient.unlink(at: local)
        XCTAssertEqual(try String(contentsOf: local.appendingPathComponent("note.md"), encoding: .utf8), "edited\n")
        XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("note.md"), encoding: .utf8), "edited\n")
        XCTAssertNil(GitClient.linkedFolderName(at: local))
    }

    func testRebaseAndCherryPick() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitling-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try GitClient.initialize(name: "local", root: root)
        let local = root.appendingPathComponent("local")
        try "a\n".write(to: local.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try GitClient.stageAll(at: local)
        try GitClient.commit(at: local, message: "base", name: "Test", email: "test@example.com")

        try GitClient.createBranch(at: local, name: "feature", checkout: true)
        try "b\n".write(to: local.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        try GitClient.stageAll(at: local)
        try GitClient.commit(at: local, message: "feature", name: "Test", email: "test@example.com")

        try GitClient.checkout(at: local, branch: "master")
        try "c\n".write(to: local.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)
        try GitClient.stageAll(at: local)
        try GitClient.commit(at: local, message: "master", name: "Test", email: "test@example.com")

        try GitClient.checkout(at: local, branch: "feature")
        try GitClient.rebase(at: local, onto: "master", name: "Test", email: "test@example.com")
        XCTAssertEqual(try GitClient.readText(at: local, relative: "b.txt"), "b\n")
        XCTAssertEqual(try GitClient.readText(at: local, relative: "c.txt"), "c\n")
        XCTAssertEqual(try GitClient.history(at: local).count, 3)

        try "d\n".write(to: local.appendingPathComponent("d.txt"), atomically: true, encoding: .utf8)
        try GitClient.stageAll(at: local)
        try GitClient.commit(at: local, message: "picked", name: "Test", email: "test@example.com")
        let picked = try GitClient.history(at: local)[0].id

        try GitClient.checkout(at: local, branch: "master")
        try GitClient.cherryPick(at: local, commit: picked, name: "Test", email: "test@example.com")
        XCTAssertEqual(try GitClient.readText(at: local, relative: "d.txt"), "d\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: local.appendingPathComponent("b.txt").path))
        let history = try GitClient.history(at: local)
        XCTAssertEqual(history.first?.summary, "picked")
        let master = history.first { $0.summary == "master" }?.id
        XCTAssertEqual(history.first?.parents, master.map { [$0] })
    }
}
