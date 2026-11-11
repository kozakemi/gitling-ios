import XCTest
@testable import Gitling

final class ProviderWorkspaceTests: XCTestCase {
    private func sandbox() throws -> (URL, URL, URL, URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repositories = base.appendingPathComponent("host/Documents/repositories")
        let metadata = base.appendingPathComponent("host/Library/Application Support")
        let group = base.appendingPathComponent("shared-group")
        for directory in [repositories, metadata, group] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        return (base, repositories, metadata, group)
    }

    func testProviderReadsHostDocumentsRatherThanExtensionSandbox() throws {
        let (base, root, metadata, group) = try sandbox()
        try GitClient.initialize(name: "sample", root: root)
        let repo = root.appendingPathComponent("sample")
        try "host edit\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let wrong = base.appendingPathComponent("extension/Documents/repositories/wrong")
        try FileManager.default.createDirectory(at: wrong, withIntermediateDirectories: true)
        try ProviderWorkspace.publish(repositories: root, metadata: metadata, sharedGroup: group)
        try ProviderWorkspace.withAccess(sharedGroup: group) { actualRoot, actualMetadata in
            XCTAssertEqual(actualRoot.resolvingSymlinksInPath(), root.resolvingSymlinksInPath())
            XCTAssertEqual(actualMetadata.resolvingSymlinksInPath(), metadata.resolvingSymlinksInPath())
            XCTAssertEqual(WorkingTree.repositories(in: actualRoot).map(\.repoName), ["sample"])
            let node = try WorkingTree.node(root: actualRoot, identifier: "repo:sample/a.txt")
            XCTAssertEqual(try String(contentsOf: node.fileURL, encoding: .utf8), "host edit\n")
        }
    }

    func testNewRepositoryAppearsInSharedRootChangesWithoutRepublishing() throws {
        let (_, root, metadata, group) = try sandbox()
        try ProviderWorkspace.publish(repositories: root, metadata: metadata, sharedGroup: group)
        let tracker = WorkingTreeChangeTracker()
        let anchor = try ProviderWorkspace.withAccess(sharedGroup: group) { actual, _ in
            tracker.record(container: "root", nodes: WorkingTree.repositories(in: actual))
        }
        try GitClient.initialize(name: "added-offline", root: root)
        try ProviderWorkspace.withAccess(sharedGroup: group) { actual, _ in
            let nodes = WorkingTree.repositories(in: actual)
            XCTAssertEqual(nodes.map(\.repoName), ["added-offline"])
            XCTAssertTrue(nodes.allSatisfy(\.isRepoRoot))
            let changes = try tracker.changes(container: "root", nodes: nodes, from: anchor)
            XCTAssertTrue(changes.hasChanges)
            XCTAssertTrue(changes.removed.isEmpty)
        }
    }

    func testPublishingDoesNotCopyOrChangeGitDataOrDirtyFiles() throws {
        let (_, root, metadata, group) = try sandbox()
        try GitClient.initialize(name: "sample", root: root)
        let repo = root.appendingPathComponent("sample")
        let file = repo.appendingPathComponent("a.txt")
        try "base\n".write(to: file, atomically: true, encoding: .utf8)
        try GitClient.stageAll(at: repo)
        try GitClient.commit(at: repo, message: "base", name: "Test", email: "test@example.invalid")
        try "staged\n".write(to: file, atomically: true, encoding: .utf8)
        try GitClient.stage(at: repo, path: "a.txt")
        try "unstaged\n".write(to: file, atomically: true, encoding: .utf8)
        let index = try Data(contentsOf: repo.appendingPathComponent(".git/index"))
        let head = try GitClient.history(at: repo)[0].id
        let status = try GitClient.status(at: repo)
        try ProviderWorkspace.publish(repositories: root, metadata: metadata, sharedGroup: group)
        try ProviderWorkspace.publish(repositories: root, metadata: metadata, sharedGroup: group)
        XCTAssertEqual(try Data(contentsOf: repo.appendingPathComponent(".git/index")), index)
        XCTAssertEqual(try GitClient.history(at: repo)[0].id, head)
        XCTAssertEqual(try GitClient.status(at: repo), status)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "unstaged\n")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: group.path), [ProviderWorkspace.filename])
    }

    func testUpdatedHostContainerIsResolvedWithoutCachingOldRoot() throws {
        let (base, root, metadata, group) = try sandbox()
        try ProviderWorkspace.publish(repositories: root, metadata: metadata, sharedGroup: group)
        let moved = base.appendingPathComponent("new-host/Documents/repositories")
        let movedMetadata = base.appendingPathComponent("new-host/Library/Application Support")
        for directory in [moved, movedMetadata] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        try ProviderWorkspace.publish(repositories: moved, metadata: movedMetadata, sharedGroup: group)
        try ProviderWorkspace.withAccess(sharedGroup: group) { actualRoot, actualMetadata in
            XCTAssertEqual(actualRoot.resolvingSymlinksInPath(), moved.resolvingSymlinksInPath())
            XCTAssertEqual(actualMetadata.resolvingSymlinksInPath(), movedMetadata.resolvingSymlinksInPath())
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: metadata.path))
    }

    func testMissingOrCorruptWorkspaceFailsInsteadOfCreatingAnEmptySandboxRoot() throws {
        let (_, root, metadata, group) = try sandbox()
        XCTAssertThrowsError(try ProviderWorkspace.withAccess(sharedGroup: group) { _, _ in XCTFail("Missing workspace must fail") })
        try Data("invalid".utf8).write(to: group.appendingPathComponent(ProviderWorkspace.filename))
        XCTAssertThrowsError(try ProviderWorkspace.withAccess(sharedGroup: group) { _, _ in XCTFail("Corrupt workspace must fail") })
        let record = ProviderWorkspace.Record(version: 999, repositories: Data(), metadata: Data())
        try JSONEncoder().encode(record).write(to: group.appendingPathComponent(ProviderWorkspace.filename))
        XCTAssertThrowsError(try ProviderWorkspace.withAccess(sharedGroup: group) { _, _ in XCTFail("Unknown workspace format must fail") })
        try ProviderWorkspace.publish(repositories: root, metadata: metadata, sharedGroup: group)
        try FileManager.default.removeItem(at: root)
        XCTAssertThrowsError(try ProviderWorkspace.withAccess(sharedGroup: group) { _, _ in XCTFail("Unavailable host root must fail") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testLinkedWorktreeUsesHostMetadataRatherThanExtensionMetadata() throws {
        let (base, root, metadata, group) = try sandbox()
        let repo = root.appendingPathComponent("sample")
        let external = base.appendingPathComponent("external/sample")
        for directory in [repo, external, metadata.appendingPathComponent("worktree-links")] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try "external file\n".write(to: external.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try WorktreeLink.bookmark(for: external).write(to: metadata.appendingPathComponent("worktree-links/sample.bookmark"))
        try ProviderWorkspace.publish(repositories: root, metadata: metadata, sharedGroup: group)
        try ProviderWorkspace.withAccess(sharedGroup: group) { actualRoot, actualMetadata in
            let access = try XCTUnwrap(WorktreeLink.begin(repoName: "sample", storageBase: actualMetadata))
            defer { access.stop() }
            let node = try WorkingTree.node(root: actualRoot, identifier: "repo:sample/a.txt", workRoot: access.url)
            XCTAssertEqual(try String(contentsOf: node.fileURL, encoding: .utf8), "external file\n")
        }
    }
}
